
// 模块接口
module sd_card_bmp #(
        parameter integer CLK_FREQ_HZ      = 100_000_000, // 时钟频率100MHz
        parameter [31:0] SCAN_START_SECTOR = 32'd0,       // 扫描起始扇区
        parameter [31:0] SCAN_MAX_SECTOR   = 32'd32768,       // 【改动九】扫描上限从64MB缩到16MB（够装4张图，避免"少认一张就蹭到天际"）
        parameter [2:0]  SCAN_TARGET_COUNT = 3'd4,        // 扫描目标图片数量=4
        parameter integer AUTO_PLAY_MS     = 3000,        // 【优化二】自动轮播间隔(毫秒), 默认3秒
        parameter integer LONG_PRESS_MS    = 1000,        // 【优化一】KEY2长按多久算"上一张"(毫秒)
        parameter integer LOAD_TIMEOUT_MS  = 8000,        // 【改动六·改动九已拆】这个参数现在只作兼容保留，加载看门狗已改成"两个阶段分开计时"
        parameter integer WRITE_GUARD_MS   = 200,         // 【改动六】源图读完后，最多再等这么久还没写完就算异常(毫秒)
        parameter integer SWITCH_GUARD_MS  = 50,          // 【改动七】提交后至少隔这么久才允许下一次加载(等显示侧换读缓冲)
        parameter integer COMMIT_WAIT_MS   = 5000,        // 【改动九·第十课】提交后"认图已画好"的最长等待(毫秒)。
                                                          //   正常几微秒就等到了，这个数只是**有界等待的保险丝**：
                                                          //   万一"画完"信号永远不来，最多等5秒就放行，
                                                          //   效果等于退回硬切，**绝不会卡死不动**。
        parameter        SDRAM_INIT_WAIT_EN = 1'b1,       // 1=等SDRAM初始化完成才扫描(有序启动) 0=退回原来的"复位一放就扫描"
        // ===== 【2026-09-30】按键长按门槛参数（满足赛题基础要求③提供的两种操作）=====
        //   丝印 KEY2 → 下一张 ／ 丝印 KEY4 → 短按=轮播开关、按住1秒=上一张、按住2秒=兜底下一张
        //    LONG_PRESS_MS 就是"上一张"的门槛（沿用上面的参数，不重复定义）
        parameter integer AUTO_TOGGLE_MS   = 2000,         // 【2026-09-30】按住到这个时长 = 兜底的一次"下一张"(毫秒)
        // ===== 【赛题基础要求(3)】自动轮播周期"可配置" =====
        //   1'b1 = 用板上拨码开关 SW1/SW2 在线选 4 档周期（2/3/5/8 秒），不用重编译
        //   1'b0 = 软回退，固定用 AUTO_PLAY_MS（老行为）
        parameter        AUTO_PERIOD_SEL_ENABLE = 1'b1
    )(
        input               clk,                 // 系统时钟100MHz
        input               rst,                 // 复位，高有效
        input               Sdr_init_done,       // SDRAM初始化完成(来自sdram控制器, 已跨域同步), 1=保鲜柜就绪
        // ===== 【赛题基础要求(3)】轮播周期选择用的两个拨码开关 =====
        input               sw1,                 // 拨码 SW1（低位）
        input               sw2,                 // 拨码 SW2（高位）
        input               key_next,            // KEY1按键输入（下一张）
        input               key_auto,            // KEY2按键输入（自动轮播开关）按下是0
        // ===== 【2026-09-30】按键长按分级：1秒长按脉冲从外面接进来 =====
        //   为什么要从外面接：有了它，"上一张"就可以由**别的键**（实测好用的丝印KEY4）来触发，
        //   不再死绑在 key_auto 的 1 秒长按上。不接（悬空）时内部自动补 0，行为不变。
        input               key_prev_pulse_i,
        output reg [3:0]    state_code,          // 【优化三】数码管显示当前图片编号(1~4)
        output              auto_play_en_o,      // 自动轮播状态引出(1=轮播中=A,0=手动=E)，给OSD字幕
output wire [5:0]   period_s_o,          // 【新功能】当前轮播周期（秒），给参数面板显示
        // 【第十课·转场】把"下一张"按键的单拍脉冲引出去，给转场控制器当作"切换请求"
        //   为什么不用顶层拿到的 key1：顶层 key1 是**没消抖的原始电平**，
        //   转场控制器要的是一个干净的"按了一下"脉冲，消抖在 sd_card_bmp 里已经做完了，
        //   直接借用最省事，而且这个脉冲本来就是驱动"下一张"逻辑的同一个信号，天然对齐。
        output              key_next_pulse_o,    // 【第十课】"下一张"按键消抖后的单拍脉冲
        // 【2026-09-30】长按分级脉冲引出给顶层（顶层再决定它们各自去干什么）
        output              key_long1_pulse_o,   // 1秒长按脉冲
        output              key_long2_pulse_o,   // 2秒长按脉冲
        input  [15:0]       bmp_width,           // BMP图片宽度
        input  [15:0]       bmp_height,          // BMP图片高度
        output reg          display_valid,       // 显示有效标志（首图提交前为0）

        input               write_finish_toggle, // SDRAM写完成信号（电平翻转，来自mem_clk域）
        output reg [1:0]    write_buf_idx,       // 写缓冲区编号（0或1）
        output reg [1:0]    disp_buf_idx,        // 显示缓冲区编号（0或1）

        output              write_req,           // 写请求
        input               write_req_ack,        // 写请求应答
        output              write_en,            // 写使能
        output [31:0]       write_data,          // 写数据（RGB+8bit填充）
        output              SD_nCS,              // SD卡片选（注意大小写要和顶层一致！）
        output              SD_DCLK,             // SD卡时钟
        output              SD_MOSI,             // SD卡主出从入[注：原文注释如此，实际MOSI为主入从出]
        input               SD_MISO              // SD卡主入从出[注：原文注释如此，实际MISO为主出从入]
    );


    wire key_next_press;
    wire key_auto_press;

    wire             sd_sec_read;
    wire [31:0]      sd_sec_read_addr;
    wire [7:0]       sd_sec_read_data;
    wire             sd_sec_read_data_valid;
    wire             sd_sec_read_end;
    wire             bmp_data_wr_en;
    wire [23:0]      bmp_data;
    wire             sd_init_done;
    wire             bmp_ready;
    wire             scan_done;
    wire             scan_found_valid;
    wire [31:0]      scan_found_sector;
    wire [2:0]       scan_found_total;

    reg              scan_start_pulse;
    reg              load_start_pulse;
    reg [31:0]       load_sector;
    reg              scan_kicked;
    reg              first_image_committed;
    reg              auto_play_en;
    reg [31:0]       auto_cnt;
    reg [2:0]        img_found_count;
    reg [1:0]        img_idx;              // 当前真正显示中的图片编号
    reg [1:0]        load_idx;             // 当前正在写入的图片编号
    reg [1:0]        pending_buf_idx;      // 当前正在写入的目标缓冲区
    reg [31:0]       img_sector0;
    reg [31:0]       img_sector1;
    reg [31:0]       img_sector2;
    reg [31:0]       img_sector3;
    reg              next_req_pending;
    reg              load_busy;
    // ===== 【优化一】KEY2长按=上一张：需要的寄存器 =====
    wire             key_auto_stable;      // KEY2消抖后的稳定状态（1=松开, 0=按下），由消抖模块输出驱动
    reg [31:0]       long_press_cnt;       // 长按计时器
    reg              long_press_marked;    // "已经触发过一次"的标记（防止按住不放连续跳张）
    reg              prev_press_pulse;     // 长按触发瞬间产生的一个单拍脉冲
    reg              prev_req_pending;     // "上一张"请求挂起（和 next_req_pending 对称）
    wire [1:0]       prev_from_current;

    // ===== 【改动五】治"自锁"：写完成脉冲锁存 + 加载看门狗 =====
    reg              write_finish_pending;  // 把"整帧写完"的单拍脉冲锁存下来，错开一拍也不会漏掉
    reg  [31:0]      load_watch_cnt;        // 这一张图已经加载了多久（用来判死等）
    reg              wd_hit;                // 看门狗抓到过自锁（数码管显示F提示）
    reg  [31:0]      wd_show_cnt;           // F 的显示计时（显示满1秒自动恢复显示图号）
    reg              src_seen_busy;         // 【改动六】本次加载确实见到过"源还在读"，用来把 source_done_seen 修正确
    reg  [31:0]      write_guard_cnt;       // 【改动六】"源读完之后"的计时

    // ===== 【改动七】切换守卫 + 看门狗报警原因 =====
    reg  [31:0]      switch_guard;          // 提交后的"切换守卫"倒计时
    reg  [1:0]       wd_reason;             // 【改动八】0=F(发了写请求但整帧写不完) 1=A(根本没发写请求=图或读脏) 2=E(整体8秒超时)
    reg              wr_req_seen;           // 【改动八】本次加载期间是否发出过写请求（区分 F 和 A 的依据）
    // ===== 【第十课·改动九 2026-09-30】"这一张图到底画出来没有"的确认位 =====
    //   背景（现场现象）：加上转场之后，KEY2 按下去完全没反应。
    //   真因：转场让下游变成"一帧才动一次"，而"画完"这件事**打不进流水线**了（详细推理见文件里那段长注释）。
    //   所以这里再加一道**有界等待**：
    //     commit_wait_cnt 从"图真的提交了"开始数，数满 COMMIT_WAIT_MS
    //     还没等到写完成 → 直接当作"这张已经画好了"，把忙碌标志放掉。
    //    为什么必须给它一个上限：不加，就是永久自锁（按什么都不动）；
    //     加了上限，最坏情况等于"退回原来的硬切"，**永远不会卡死**。
    //    为什么用 5000ms：正常整帧写完只要几微秒~几毫秒，给到 5 秒是留了三个数量级的余量，
    //     只有真出问题时才会兜底，正常流程永远是"信号先到、计时还没数到"。
    reg  [31:0]      commit_wait_cnt;       // 提交后的"等你画完"计时
    reg              commit_wait_busy;      // 正在等（=图已提交，还没确认画完）
    reg              commit_wait_timeout;   // 【改动九】这次是"等超时"才放行的（用来区分正常/兜底）

    wire [31:0]      switch_guard_cycles = (CLK_FREQ_HZ / 1000) * SWITCH_GUARD_MS;
    wire [31:0]      write_guard_cycles  = (CLK_FREQ_HZ / 1000) * WRITE_GUARD_MS;
    wire [31:0]      commit_wait_cycles  = (CLK_FREQ_HZ / 1000) * COMMIT_WAIT_MS;
    // 【改动九】读卡阶段的总上限：用 LOAD_TIMEOUT_MS 自己算，不再依赖被删掉的那根旧线
    wire [31:0]      load_timeout_cycles = (CLK_FREQ_HZ / 1000) * LOAD_TIMEOUT_MS;

    // 【改动九】把"看门狗"从"一整段 8 秒"改成"两个阶段各管各的"
    //    声明必须在使用之前（TD 的老规矩）：source_done_seen 下面好几根线都要用，所以先声明。
    // 源文件读取/送 FIFO 完成（= 读卡这一段干完了）
    reg              source_done_seen;

    //   为什么必须改：不改的话，**每一次正常换图都会误触发 8 秒看门狗**。
    //     原因：提交那一刻我们把 load_busy 放掉了，8 秒总计时器也跟着清零；
    //           而"确认这张已经画好了"这件事在新版里往往要等好几帧（甚至要等兜底超时）
    //           ⇒ 加载标记一直举着 ⇒ load_timeout_hit 一开火，就**把下一次换图吞掉**，
    //             表现就是"按了 KEY2 没反应"。
    //   改法（两段计时，各管各的事，互不干扰）：
    //     第一段 读卡阶段：从"开始加载"数到"源图读完"  → 上限 LOAD_TIMEOUT_MS（8秒）
    //     第二段 上屏阶段：从"源图读完"数到"整帧写完"  → 上限 WRITE_GUARD_MS（200毫秒）
    //   正常流程下这两段都是"信号先到、计时还差得远"，看门狗一辈子不开火。
    wire             src_phase_timeout = load_busy && !source_done_seen &&
                                         (load_watch_cnt >= load_timeout_cycles);
    wire             wr_phase_timeout  = load_busy && source_done_seen &&
                                         (write_guard_cnt >= write_guard_cycles);
    wire             load_timeout_hit  = src_phase_timeout || wr_phase_timeout;

    reg              src_phase_timeout_q;   // 上面两个信号打一拍，给状态机复用（避免多处算同一件事）
    reg              wr_phase_timeout_q;
    wire             comm_timeout = (commit_wait_cnt >= commit_wait_cycles);   // 【改动九】"等你画完"数满了
    // 【改动九】读卡段的"真卡住"单拍：8秒计时器**真的数满那一刻**，而且这次确实读卡读了
    //   为什么数满后还有回绕：计数器数满就锁住不再加，所以"数满"会一直是1（一圈以上）。
    //   直接用它既会重复开火、也会在下一次加载一开始就误开火 ⇒ 必须取"刚好数满"这一拍。
    //   做法：`load_watch_cnt == 上限-1` 打一拍，下一拍就是"刚好数满"。
    wire             src_cnt_at_max = (load_watch_cnt == (load_timeout_cycles - 32'd1));
    reg              src_cnt_at_max_q;
    reg              src_phase_armed;       // 这一次加载确实进到过"读卡阶段"
    wire             src_timeout_pulse = src_phase_timeout && src_cnt_at_max_q && src_phase_armed;
    // 【改动九】上屏段的"真卡住"单拍：同上一套，只是换了计时器
    wire             wr_cnt_at_max = (write_guard_cnt == (write_guard_cycles - 32'd1));
    reg              wr_cnt_at_max_q;
    reg              wr_phase_armed;        // 这一次加载确实进到过"上屏阶段"
    wire             wr_timeout_pulse = wr_phase_timeout && wr_cnt_at_max_q && wr_phase_armed;
    // 【改动九】把"真卡住"单拍传回看门狗那个 always 块
    //    必须是 wire（纯连线）：它只由下面一句 assign 驱动，看门狗那个 always 只读不写，
    //     一个信号只有一个司机，不会"抢方向盘"（多驱动）。
    wire             wd_to_main = src_timeout_pulse | wr_timeout_pulse;

    // 同步 mem_clk 域的 write_finish_toggle
    reg [2:0]        wrfin_tgl_sync;
    wire             write_finish_pulse;

    wire auto_tick;
    wire [1:0] next_from_current;

    assign write_en   = bmp_data_wr_en;
    assign write_data = {bmp_data[23:16], bmp_data[15:8], bmp_data[7:0], 8'b0};
    // 【优化二·常规设计标准】自动轮播间隔可配置
    // ------------------------------------------------------------------
    // 【赛题基础要求(3)】原文："…自动轮播周期**可配置**"。
    //   原来只能改 AUTO_PLAY_MS 这个参数**重新编译**才能换周期，不算"可配置"。
    //   现在改成：**用板上的拨码开关 SW1/SW2 在线选 4 档周期**，不用重编译。
//
    //   档位表（SW2 SW1 两位二进制）：
    //     SW2 SW1 = 0 0  →  2 秒     （快）
    //             0 1  →  3 秒     （默认，原来就是这个）
    //             1 0  →  5 秒
    //             1 1  →  8 秒     （慢，讲解用）
//
    //    软回退：AUTO_PERIOD_SEL_ENABLE = 1'b0 时，period_ms 恒等于 AUTO_PLAY_MS，
    //     完全退回"写死 3 秒"的老行为，一行老逻辑都不受影响。
    //    只影响"多久换一张"，不碰读卡、不碰显示，**零风险**。
    // ------------------------------------------------------------------
    wire [1:0] auto_period_sw = {sw2, sw1};      // SW2 是高位，SW1 是低位
    reg [31:0] period_ms;
    always @* begin
        if (!AUTO_PERIOD_SEL_ENABLE)
            period_ms = AUTO_PLAY_MS;            // 软回退：固定用参数值
        else case (auto_period_sw)
            2'd0:    period_ms = 32'd2000;       // 2 秒
            2'd1:    period_ms = 32'd3000;       // 3 秒（默认档）
            2'd2:    period_ms = 32'd5000;       // 5 秒
            default: period_ms = 32'd8000;       // 8 秒
        endcase
    end

    wire [31:0] auto_play_cycles = (CLK_FREQ_HZ / 1000) * period_ms;

// 【新功能】把毫秒换成秒（2000/3000/5000/8000 → 2/3/5/8），给面板显示
//    只有 4 种取值，用 case 查表，**不做除法**
reg [5:0] period_s_r;
always @* begin
    case (period_ms)
        32'd2000: period_s_r = 6'd2;
        32'd3000: period_s_r = 6'd3;
        32'd5000: period_s_r = 6'd5;
        default: period_s_r = 6'd8;
    endcase
end
assign period_s_o = period_s_r;
    assign auto_tick  = (auto_cnt == (auto_play_cycles - 1));

    // 【优化三·常规设计标准】bmp_read 原来的状态码先接到内部信号上（不再直接送数码管）
    wire [3:0] state_code_i;

    // 【优化三·常规设计标准】数码管显示"当前是第几张图"（1~4）
    //   img_idx 是从0开始数的，+1 之后就是观众习惯的"第1张、第2张…"
    //   （用一个独立的 always 块来驱动，不碰原来的主逻辑，最安全）
    always @(posedge clk or posedge rst) begin
        if (rst || !sd_init_done)
            state_code <= 4'd0;                      // 复位中/卡还没准备好 → 显示0
        else if (wd_hit)
            state_code <= (wd_reason == 2'd2) ? 4'hE : ((wd_reason == 2'd1) ? 4'hA : 4'hF);  // 【改动八】E=读卡超时 A=没发写请求 F=写了没写完
        else
            state_code <= {2'b0, img_idx} + 4'd1;    // 正常时 → 显示第1~4张
    end
    assign next_from_current = next_index_limited(img_idx, img_found_count);
    assign prev_from_current = prev_index_limited(img_idx, img_found_count);
    assign write_finish_pulse = wrfin_tgl_sync[2] ^ wrfin_tgl_sync[1];
    // 把内部的"自动轮播开关"引出去给OSD字幕显示 A/E（纯加法，不动原逻辑）
    assign auto_play_en_o = auto_play_en;

    // 【2026-09-30】下面三根"引出去"的线（key_next_pulse_o / key_long1_pulse_o /
    //   key_long2_pulse_o）是模块端口，已在端口列表里声明过了；
    //   但 key_long1_pulse / key_long2_pulse 是**内部寄存器**，
    //   它们要等下面"按键"那一段声明完才能 assign（满足 TD"用前先声明"的规矩）。

    key_press_debounce #(
                           .CLK_FREQ_HZ (CLK_FREQ_HZ),
                           .DEBOUNCE_MS (20)
                       ) u_key_next (
                           .clk        (clk),
                           .rst        (rst),
                           .button_in  (key_next),
                           .press_pulse(key_next_press)
                       );

    key_press_debounce #(
                           .CLK_FREQ_HZ (CLK_FREQ_HZ),
                           .DEBOUNCE_MS (20)
                       ) u_key_auto (
                           .clk        (clk),
                           .rst        (rst),
                           .button_in  (key_auto),
                           .press_pulse(key_auto_press),
                           .button_stable_out(key_auto_stable)   // 【优化一】接出消抖后的稳定状态
                       );

    // ===== 【优化一】KEY2长按检测 =====
    // 按住不放，数满 LONG_PRESS_MS 毫秒，就拉高一个单拍脉冲 prev_press_pulse（去挂起"上一张"请求）
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            long_press_cnt    <= 32'd0;
            long_press_marked <= 1'b0;
            prev_press_pulse  <= 1'b0;
        end else begin
            prev_press_pulse <= 1'b0;                      // 平时是0，只触发那一下拉高
            if (key_auto_stable == 1'b0) begin             // 按键被按住（0=按下）
                if (long_press_cnt < ((CLK_FREQ_HZ / 1000) * LONG_PRESS_MS - 1))
                    long_press_cnt <= long_press_cnt + 32'd1;
                else if (!long_press_marked) begin
                    long_press_marked <= 1'b1;             // 只触发一次，防连跳
                    prev_press_pulse  <= 1'b1;
                end
            end else begin                                 // 松开了
                long_press_cnt    <= 32'd0;
                long_press_marked <= 1'b0;
            end
        end
    end

    // ============================================================================
    // ===== 【2026-09-30 修正】两个键各司其职 —— 赛题基础要求(3) 必须满足 =====
    // ============================================================================
    // 【赛题原文】1.3 基础要求 (3)：**≥2 个按键**（"下一张" / "轮播开关"）+ 轮播周期可配置
    //   ⇒ 所以**绝对不能**把全部功能挤到一个键上！那属于直接不符合基础要求。
    //   （我上一版图省事把三个动作并到一个键上，是错的；现在改回来，并把教训记在这里。）
//
    // 【最终分工】
    //   丝印 KEY2（→ key1 端口 → 本模块 key_next）→ **下一张**
    //   丝印 KEY4（→ key2 端口 → 本模块 key_auto）→ 短按 = **轮播开关**
    //                                               按住 1 秒 = **上一张**
    //   ⇒ 两个键、三种操作，完全满足"≥2个按键"。
//
    // 【一层兜底】万一哪天丝印 KEY2 那条线又出问题，"下一张"也不会完全没有：
    //   丝印 KEY4 **按住 2 秒**也会触发一次"下一张"（和1秒不冲突：1秒=上一张、2秒=下一张）。
    //   这是**兜底**，正常演示请用 KEY2 —— 它才是赛题要求的那个"下一张"键。
    // ============================================================================
    wire long1_ok = (long_press_cnt >= ((CLK_FREQ_HZ / 1000) * LONG_PRESS_MS - 1));
    wire long2_ok = (long_press_cnt >= ((CLK_FREQ_HZ / 1000) * AUTO_TOGGLE_MS - 1));

    // 【2026-09-30】"上一张"的信号来源：外面接进来优先，没接就退回内部原来的 1 秒长按
    wire key_prev_for_prev = key_prev_pulse_i | prev_press_pulse;

    reg key_long1_pulse;     // 按住满 1 秒：一个单拍脉冲（→ 上一张）
    reg key_long2_pulse;     // 按住满 2 秒：一个单拍脉冲（→ 兜底的一次"下一张"）

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            key_long1_pulse <= 1'b0;
            key_long2_pulse <= 1'b0;
        end else begin
            key_long1_pulse <= 1'b0;                       // 平时都是0，只在跨过门槛那一拍拉高
            key_long2_pulse <= 1'b0;
            if (key_auto_stable == 1'b0) begin             // 正按着（0=按下）
                if (long1_ok && !long_press_marked)        // 刚好跨过 1 秒
                    key_long1_pulse <= 1'b1;
                if (long2_ok)                              // 刚好跨过 2 秒（长按标记那时早就是1了，所以只来一次）
                    key_long2_pulse <= 1'b1;
            end
        end
    end

    // 【2026-09-30】三根脉冲引出去给顶层（内部寄存器已在上方声明，这里才 assign）
    assign key_next_pulse_o  = key_next_press;     // 下一张 = 丝印 KEY2 的消抖脉冲（基础要求③）
    assign key_long1_pulse_o = key_long1_pulse;    // 1秒长按（丝印 KEY4）→ 上一张
    assign key_long2_pulse_o = key_long2_pulse;    // 2秒长按（丝印 KEY4）→ 兜底的一次"下一张"

    // ===== 【改动五】加载看门狗：加载超过 LOAD_TIMEOUT_MS 毫秒还没提交，就判定"死等"，强制放行 =====
    //   为什么必须有它：常规实现依赖一个"单拍脉冲"(write_finish)宣布整帧写完，
    //   一旦那一拍被错过，就会永远等下去（自锁），而常规实现本身缺少容错机制
    //   （常规设计第3章第5条也承认"没有错误处理、没有恢复机制"）。
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            load_watch_cnt <= 32'd0;
            wd_hit         <= 1'b0;
            wd_reason      <= 2'd0;
            wd_show_cnt    <= 32'd0;
        end else begin
            if (!load_busy)
                load_watch_cnt <= 32'd0;                       // 不忙就不计时
            else if (load_watch_cnt < load_timeout_cycles)
                load_watch_cnt <= load_watch_cnt + 32'd1;      // 忙就往上数（数满就锁住）
            // 【改动九·2026-09-30 关键修复】读卡这一段的计时**读到图就立刻清零**。
            //   不改会出的事：load_watch_cnt 原来只在"不忙"时才清零，而新版里
            //   "不忙"要等上屏确认（可能好几帧甚至几秒）⇒ 计数器一路数到 8 秒上限就锁死
            //   ⇒ 下一张图刚发起来 load_timeout_hit 立刻开火 ⇒ **每次换图都被吞掉**
            //   ⇒ 现场表现就是"按 KEY2 完全没反应"。这就是本次故障的直接原因，记录在此。
            if (load_busy && src_seen_busy && bmp_ready)
                load_watch_cnt <= 32'd0;

            // 【改动六】第二个计数器：只在"源图读完之后"才计时（正常这一段只有几微秒）
            if (!load_busy || !source_done_seen)
                write_guard_cnt <= 32'd0;
            else if (write_guard_cnt < write_guard_cycles)
                write_guard_cnt <= write_guard_cnt + 32'd1;

            if (wd_to_main) begin                              // 抓到自锁（改动九：只在计时器"刚好数满"那一拍来）
                wd_hit      <= 1'b1;
                // 【改动八】记下原因，把"三种病因"分开：
                //   0 = F：源读完了、也发过写请求，但整帧就是写不完（字数不足）
                //          【改动九补充】"源读完了却一直等不到整帧写完，最后靠5秒兜底放行"也归到 F，
                //          因为现象完全一样（图是画出来了，但那一刻我们没认出来）——用同一个码更好认。
                //   1 = A：源读完了，但**根本没发过写请求**（图头不合格/读脏 → 一个像素都没送）
                //   2 = E：整体超过 8 秒（读卡侧卡住）
                wd_reason   <= (source_done_seen && (commit_wait_timeout ||
                                                     (write_guard_cnt >= write_guard_cycles))) ? (wr_req_seen ? 2'd0 : 2'd1) : 2'd2;
                wd_show_cnt <= 32'd0;
            end else if (wd_hit) begin
                if (wd_show_cnt < 32'd100_000_000)             // F 显示1秒(=1亿拍)
                    wd_show_cnt <= wd_show_cnt + 32'd1;
                else
                    wd_hit <= 1'b0;                            // 1秒后自动恢复显示图号
            end
        end
    end

    function [1:0]  next_index_limited;
        input [1:0] cur;
        input [2:0] count;
        begin
            case (count)
                3'd0:
                    next_index_limited = 2'd0;
                3'd1:
                    next_index_limited = 2'd0;
                3'd2:
                    next_index_limited = (cur == 2'd1) ? 2'd0 : (cur + 2'd1);
                3'd3:
                    next_index_limited = (cur == 2'd2) ? 2'd0 : (cur + 2'd1);
                default:
                    next_index_limited = (cur == 2'd3) ? 2'd0 : (cur + 2'd1);
            endcase
        end
    endfunction

    // ===== 【优化一】新增：计算"上一张"的图片编号（和 next_index_limited 对称，减1）=====
    function [1:0] prev_index_limited;
        input [1:0] cur;
        input [2:0] count;
        begin
            case (count)
                3'd0:    prev_index_limited = 2'd0;
                3'd1:    prev_index_limited = 2'd0;
                3'd2:    prev_index_limited = (cur == 2'd0) ? 2'd1 : (cur - 2'd1);
                3'd3:    prev_index_limited = (cur == 2'd0) ? 2'd2 : (cur - 2'd1);
                default: prev_index_limited = (cur == 2'd0) ? 2'd3 : (cur - 2'd1);
            endcase
        end
    endfunction

    function [31:0] sector_lut;
        input [1:0] idx;
        begin
            case (idx)
                2'd0:
                    sector_lut = img_sector0;
                2'd1:
                    sector_lut = img_sector1;
                2'd2:
                    sector_lut = img_sector2;
                2'd3:
                    sector_lut = img_sector3;
                default:
                    sector_lut = img_sector0;
            endcase
        end
    endfunction

    function [1:0] next_buf_lut;
        input [1:0] cur_disp_buf;
        input       valid_now;
        begin
            if (!valid_now)
                next_buf_lut = 2'd0;                 // 首图固定写 buffer0
            else if (cur_disp_buf == 2'd0)
                next_buf_lut = 2'd1;
            else
                next_buf_lut = 2'd0;
        end
    endfunction

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            wrfin_tgl_sync        <= 3'b000;
            scan_start_pulse      <= 1'b0;
            load_start_pulse      <= 1'b0;
            load_sector           <= 32'd0;
            scan_kicked           <= 1'b0;
            first_image_committed <= 1'b0;
            auto_play_en          <= 1'b0;
            auto_cnt              <= 32'd0;
            img_found_count       <= 3'd0;
            img_idx               <= 2'd0;
            load_idx              <= 2'd0;
            pending_buf_idx       <= 2'd0;
            write_buf_idx         <= 2'd0;
            disp_buf_idx          <= 2'd0;
            img_sector0           <= 32'd0;
            img_sector1           <= 32'd0;
            img_sector2           <= 32'd0;
            img_sector3           <= 32'd0;
            next_req_pending      <= 1'b0;
            prev_req_pending      <= 1'b0;   // 【补丁】上一张请求位必须复位，否则上电初值随机
            write_finish_pending <= 1'b0;   // 【改动五】写完成锁存位一起清
            switch_guard        <= 32'd0;      // 【改动七】切换守卫清零
            load_busy             <= 1'b0;
            source_done_seen      <= 1'b0;
            display_valid         <= 1'b0;
        end
        else begin
            wrfin_tgl_sync   <= {wrfin_tgl_sync[1:0], write_finish_toggle};
            scan_start_pulse <= 1'b0;
            load_start_pulse <= 1'b0;

            if (!sd_init_done) begin
                scan_kicked           <= 1'b0;
                first_image_committed <= 1'b0;
                auto_play_en          <= 1'b0;
                auto_cnt              <= 32'd0;
                img_found_count       <= 3'd0;
                img_idx               <= 2'd0;
                load_idx              <= 2'd0;
                pending_buf_idx       <= 2'd0;
                write_buf_idx         <= 2'd0;
                disp_buf_idx          <= 2'd0;
                img_sector0           <= 32'd0;
                img_sector1           <= 32'd0;
                img_sector2           <= 32'd0;
                img_sector3           <= 32'd0;
                next_req_pending      <= 1'b0;
                prev_req_pending      <= 1'b0;   // 【补丁】上一张请求位必须复位，否则上电初值随机
                write_finish_pending <= 1'b0;   // 【改动五】写完成锁存位一起清
                switch_guard        <= 32'd0;      // 【改动七】切换守卫清零
                load_busy             <= 1'b0;
                source_done_seen      <= 1'b0;
                display_valid         <= 1'b0;
            end
            else begin
                // 扫描阶段缓存前 4 张图的起始 sector
                if (scan_found_valid) begin
                    case (img_found_count)
                        3'd0:
                            img_sector0 <= scan_found_sector;
                        3'd1:
                            img_sector1 <= scan_found_sector;
                        3'd2:
                            img_sector2 <= scan_found_sector;
                        3'd3:
                            img_sector3 <= scan_found_sector;
                        default:
                            ;
                    endcase

                    if (img_found_count < 3'd4)
                        img_found_count <= img_found_count + 3'd1;
                end

                // 【改动六】把 source_done_seen 修正确：必须"先看到源在忙，再看到源读完"才算数。
                //   原来的写法有隐藏时序坑：load_busy 刚拉高那一拍 bmp_read 还在 IDLE，
                //   bmp_ready 恰好是 1，于是"源已读完"被瞬间误判成真，"提交"就退化成
                //   "加载开始后遇到的第一个脉冲就提交"，很容易被上一帧残留的脉冲提前触发，
                //   控制侧与写侧就此错位（该写的 307200 个像素再也凑不满）→ 永久卡死。
                //   常规实现依赖时序巧合；我们改动后的时序打破了巧合，所以必须修。
                if (!load_busy)
                    src_seen_busy <= 1'b0;                     // 两次加载之间自动清零
                else if (!bmp_ready)
                    src_seen_busy <= 1'b1;                     // 第一步：确认源真的在忙

                // 【改动八】本次加载期间有没有发出过写请求（有=图被认下了；没有=图头不合格，一个像素都没送）
                if (!load_busy)
                    wr_req_seen <= 1'b0;
                else if (write_req)
                    wr_req_seen <= 1'b1;

                if (load_busy && src_seen_busy && bmp_ready)
                    source_done_seen <= 1'b1;                  // 第二步：确认源读完了

                // 【改动五·改动九】看门狗兜底：万一加载死等，强制清掉忙碌标志，绝不允许永久自锁
                //   （放在加载分支之前；如果同一拍正好有加载分支要启动，以加载分支为准）
                //    开火条件（改动九）：**只有计时器真数满那一刻**才开火（src_timeout_pulse / wr_timeout_pulse），
                //     绝不再用"计时器已经数满"这种电平，否则下一次加载一开始就被自己掐死。
                //    故意不清 next_req_pending / prev_req_pending：万一看门狗开火，
                //     用户刚按的那一下不会被吞掉，下一次会立刻执行
                // 【改动九】两个超时信号打一拍，下面几处判断统一用它俩
                src_phase_timeout_q <= src_phase_timeout;
                wr_phase_timeout_q  <= wr_phase_timeout;

                if (src_timeout_pulse || wr_timeout_pulse) begin
                    load_busy            <= 1'b0;
                    source_done_seen     <= 1'b0;
                    write_finish_pending <= 1'b0;
                    commit_wait_busy     <= 1'b0;                                   // 【改动九】等画完的计时也停
                    commit_wait_cnt      <= 32'd0;
                    commit_wait_timeout  <= wr_timeout_pulse;                       // 【改动九】上屏阶段开火 → 数码管显示F
                    // 【改动八】失败自动重试同一张图（img_idx 没变，所以重试就是重来这张）。
                    //   重试会重新拉 write_req → 写侧被 S_ACK 清零并清 FIFO → 拿到全新的 307200 字预算。
                    //   这样现场再遇到失败，用户**不用再按一次**，系统自己就把这次切换补上。
                    next_req_pending     <= 1'b1;
                end

                // 【改动九】 提交时机改成"**有界等待**"，绝不死等那个"整帧写完"的脉冲
                //   提交条件 = 源图读完了 且 （画完的脉冲/锁存来了 或者 等满 COMMIT_WAIT_MS）
                //   ⇒ 正常路：信号一到就提交（和以前一样快）
                //   ⇒ 兜底路：信号永远不来，最多等 5 秒也提交（效果=退回硬切，但**绝不卡死**）
                if (load_busy && source_done_seen &&
                    (write_finish_pulse || write_finish_pending || comm_timeout)) begin
                    load_busy             <= 1'b0;
                    source_done_seen      <= 1'b0;
                    write_finish_pending  <= 1'b0;
                    commit_wait_busy      <= 1'b0;                                  // 【改动九】等画完的计时停
                    commit_wait_cnt       <= 32'd0;
                    commit_wait_timeout   <= comm_timeout;                          // 【改动九】走了兜底就置1（给数码管F用）
                    disp_buf_idx          <= pending_buf_idx;
                    img_idx               <= load_idx;
                    display_valid         <= 1'b1;
                    first_image_committed <= 1'b1;
                    switch_guard          <= switch_guard_cycles;   // 【改动七】提交后启动"切换守卫"
                end
                // 【改动九】没到提交条件时，只管"等画完"的计时；到点了会自动走上一条提交
                else if (load_busy && source_done_seen) begin
                    if (!commit_wait_busy)
                        commit_wait_cnt <= 32'd0;
                    else
                        commit_wait_cnt <= commit_wait_cnt + 32'd1;
                    commit_wait_busy <= 1'b1;
                end
                else if (!load_busy) begin
                    commit_wait_busy    <= 1'b0;
                    commit_wait_cnt     <= 32'd0;
                end

                // 【改动七】切换守卫倒计时：只有在"不忙"的时候才递减
                //   为什么需要它：提交会立刻翻转 disp_buf_idx，但显示侧要等下一次 VSYNC
                //   才重新锁定读地址（中间 1~2 帧 = 16.7~33ms）。如果提交后马上发起新的加载，
                //   新图就会写到"显示侧还在读"的那块 buffer 里 ⇒ SDRAM 同 bank 行冲突、画面撕裂。
                if (!load_busy && (switch_guard != 32'd0))
                    switch_guard <= switch_guard - 32'd1;

                // 【改动九·2026-09-30 关键修复】看门狗**只在"真死了"的时候才能开火**。
                //    病根：原来无条件写 `if (load_timeout_hit)`。而 load_timeout_hit 只看
                //     "计数器有没有数到上限"，**不看这次是不是真死**。新流程里 load_watch_cnt
                //     会被一路数满并锁死 ⇒ 只要一发起新加载，看门狗立刻在同一拍开火，
                //     把 load_busy 清掉、还挂上一个 next_req_pending=1
                //     ⇒ 每一次换图都被自己掐死，**现场表现就是"按 KEY2 完全没反应"**。
                //    改法：分成两个明确的、**只在计时器真的数满那一刻**成立的单拍信号，
                //     并且必须是"这次加载确实进行到了那个阶段"才允许开火。
                //    两段计时各有各的上限：读卡段 8 秒、上屏段 200 毫秒。
                //    具体做法：把计时器"刚好数满"的那一拍（src_cnt_at_max_q / wr_cnt_at_max_q）
                //     接到看门狗那个 always 块里去出 F。两段计时不可能同时数满，所以一根线够用。
                //     （这根线 wd_to_main 是纯 wire，在上面声明时就用 assign 接好了，这里不用再驱动它。）

                // 【改动九】维护"阶段真卡住"的几个辅助位（每拍无条件更新，简单不容易错）
                src_phase_armed   <= load_busy && !source_done_seen;   // 进过读卡阶段：忙 且 还没读完
                src_cnt_at_max_q  <= src_cnt_at_max;                   // 8秒计时器"刚好数满"那一拍
                wr_phase_armed    <= load_busy && source_done_seen;    // 进过上屏阶段：忙 且 源已读完
                wr_cnt_at_max_q   <= wr_cnt_at_max;                    // 200毫秒计时器"刚好数满"那一拍

                // 【改动五】把"整帧写完成"的单拍脉冲先锁存：哪怕它和 source_done_seen 错开一拍，也不会漏
                //   加 load_busy 条件是为了只在"本次加载期间"生效，避免把上一张图残留的脉冲记进来
                if (write_finish_pulse && load_busy)
                    write_finish_pending <= 1'b1;
                //  提交动作已经挪到上面"有界等待"那一段（同一个 always 里只能有一处决定 load_busy 何时放掉）

                // 上电后自动发起一次“扫描前 4 张 BMP”
                // 常规做法：启动扫描的条件里加一个 && Sdr_init_done
                //   "有序启动"：复位释放 → SDRAM初始化完成 → 才允许开始扫TF卡 → 加载首图 → 出图
                //   为什么必须有它：SDRAM(保鲜柜)还没初始化好，搬运工就把菜往里塞，会整批塞丢。
                //   软回退：SDRAM_INIT_WAIT_EN=1'b0 → 这一项恒为1，条件退化回原来的 !scan_kicked && bmp_ready
                if (!scan_kicked && bmp_ready && (Sdr_init_done | ~SDRAM_INIT_WAIT_EN)) begin
                    scan_start_pulse      <= 1'b1;
                    scan_kicked           <= 1'b1;
                    first_image_committed <= 1'b0;
                    auto_play_en          <= 1'b0;
                    auto_cnt              <= 32'd0;
                    img_found_count       <= 3'd0;
                    img_idx               <= 2'd0;
                    load_idx              <= 2'd0;
                    pending_buf_idx       <= 2'd0;
                    write_buf_idx         <= 2'd0;
                    disp_buf_idx          <= 2'd0;
                    next_req_pending      <= 1'b0;
                    prev_req_pending      <= 1'b0;   // 【补丁】上一张请求位必须复位，否则上电初值随机
                    write_finish_pending <= 1'b0;   // 【改动五】写完成锁存位一起清
                    switch_guard        <= 32'd0;      // 【改动七】切换守卫清零
                    display_valid         <= 1'b0;
                    load_busy             <= 1'b0;
                    source_done_seen      <= 1'b0;
                end
                else begin
                    // 忙的时候也只记 1 次“下一张”请求，不会累积成连跳两张
                    // 【2026-09-30】两个来源合并：
                    //   ① 丝印 KEY2 的消抖脉冲（**赛题要求的那个"下一张"键**）
                    //   ② 丝印 KEY4 的 2 秒长按（兜底，防止 KEY2 那条线哪天又出问题）
                    if ((key_next_press || key_long2_pulse) &&
                        scan_done && (img_found_count > 3'd0))
                        next_req_pending <= 1'b1;

                    // 【优化一】1秒长按触发 → 挂起"上一张"请求（同样只记1次，防连跳）
                    // 【2026-09-30】来源：丝印 KEY4 的 1 秒长按（顶层从 key_prev_pulse_i 接进来），
                    //   没接就用内部原来那套（prev_press_pulse）。
                    if (key_prev_for_prev && scan_done && (img_found_count > 3'd0))
                        prev_req_pending <= 1'b1;

                    // 自动播放开/关（= 赛题说的"轮播开关"）
                    // 【2026-09-30】丝印 KEY4 **短按**触发：用"消抖脉冲 + 没进入长按"来判定短按。
                    //    这个判定是常规写法，最稳妥；之所以要加 !long_press_marked，
                    //     是为了"长按 1 秒去上一张"之后松手时，不再顺手把轮播开关也翻一下。
                    if (key_auto_press && !long_press_marked &&
                        scan_done && (img_found_count > 3'd1)) begin
                        auto_play_en <= ~auto_play_en;
                        auto_cnt     <= 32'd0;
                    end

                    // 自动播放 1s 计数：只有当前没有写图任务时才计时
                    if (scan_done && auto_play_en && display_valid && !load_busy && first_image_committed && (img_found_count > 3'd1)) begin
                        if (auto_tick)
                            auto_cnt <= 32'd0;
                        else
                            auto_cnt <= auto_cnt + 32'd1;
                    end
                    else begin
                        auto_cnt <= 32'd0;
                    end

                    // 首图自动加载到 buffer0
                    if (scan_done && !first_image_committed && bmp_ready && !load_busy && (img_found_count != 3'd0)) begin
                        load_idx         <= 2'd0;
                        load_sector      <= img_sector0;
                        pending_buf_idx  <= 2'd0;
                        write_buf_idx    <= 2'd0;
                        load_start_pulse <= 1'b1;
                        load_busy        <= 1'b1;
                        source_done_seen <= 1'b0;
                        next_req_pending <= 1'b0;
                        auto_cnt         <= 32'd0;
                    end
                    // 手动下一张优先：写到“非当前显示”的另一块 buffer
                    else if (scan_done && bmp_ready && display_valid && !load_busy && (switch_guard == 32'd0) && next_req_pending && (img_found_count != 3'd0)) begin
                        load_idx         <= next_from_current;
                        load_sector      <= sector_lut(next_from_current);
                        pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                        write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                        load_start_pulse <= 1'b1;
                        load_busy        <= 1'b1;
                        source_done_seen <= 1'b0;
                        next_req_pending <= 1'b0;
                        auto_cnt         <= 32'd0;
                    end
                    // 【优化一】上一张：只有"下一张"没有请求时才处理（下一张优先）
                    else if (scan_done && bmp_ready && display_valid && !load_busy && (switch_guard == 32'd0) && prev_req_pending && (img_found_count > 3'd0)) begin
                        load_idx         <= prev_from_current;
                        load_sector      <= sector_lut(prev_from_current);
                        pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                        write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                        load_start_pulse <= 1'b1;
                        load_busy        <= 1'b1;
                        source_done_seen <= 1'b0;
                        prev_req_pending <= 1'b0;
                        auto_cnt         <= 32'd0;
                    end
                    // 自动播放下一张：同样写到“非当前显示”的另一块 buffer
                    else if (scan_done && bmp_ready && display_valid && !load_busy && (switch_guard == 32'd0) && auto_play_en && auto_tick && (img_found_count > 3'd1)) begin
                        load_idx         <= next_from_current;
                        load_sector      <= sector_lut(next_from_current);
                        pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                        write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                        load_start_pulse <= 1'b1;
                        load_busy        <= 1'b1;
                        source_done_seen <= 1'b0;
                        auto_cnt         <= 32'd0;
                    end
                end
            end
        end
    end

    bmp_read bmp_read_m0(
                 .clk                    (clk),
                 .rst                    (rst),
                 .ready                  (bmp_ready),

                 .scan_start             (scan_start_pulse),
                 .scan_start_sector      (SCAN_START_SECTOR),
                 .scan_max_sector        (SCAN_MAX_SECTOR),
                 .scan_target_count      (SCAN_TARGET_COUNT),
                 .scan_done              (scan_done),
                 .scan_found_valid       (scan_found_valid),
                 .scan_found_sector      (scan_found_sector),
                 .scan_found_total       (scan_found_total),

                 .load_start             (load_start_pulse),
                 .load_sector            (load_sector),

                 .sd_init_done           (sd_init_done),
                 .state_code             (state_code_i),       // 【改动2】状态码改接到内部信号
                 .bmp_width              (bmp_width),
                 .bmp_height             (bmp_height),
                 .write_req              (write_req),
                 .write_req_ack          (write_req_ack),
                 .sd_sec_read            (sd_sec_read),
                 .sd_sec_read_addr       (sd_sec_read_addr),
                 .sd_sec_read_data       (sd_sec_read_data),
                 .sd_sec_read_data_valid (sd_sec_read_data_valid),
                 .sd_sec_read_end        (sd_sec_read_end),
                 .bmp_data_wr_en         (bmp_data_wr_en),
                 .bmp_data               (bmp_data)
             );

    sd_card_top sd_card_top_m0(
                    .clk                    (clk),
                    .rst                    (rst),
                    .SD_nCS                 (SD_nCS),
                    .SD_DCLK                (SD_DCLK),
                    .SD_MOSI                (SD_MOSI),
                    .SD_MISO                (SD_MISO),
                    .sd_init_done           (sd_init_done),
                    .sd_sec_read            (sd_sec_read),
                    .sd_sec_read_addr       (sd_sec_read_addr),
                    .sd_sec_read_data       (sd_sec_read_data),
                    .sd_sec_read_data_valid (sd_sec_read_data_valid),
                    .sd_sec_read_end        (sd_sec_read_end),
                    .sd_sec_write           (1'b0),
                    .sd_sec_write_addr      (32'd0),
                    .sd_sec_write_data      (),
                    .sd_sec_write_data_req  (),
                    .sd_sec_write_end       ()
                );

endmodule

module key_press_debounce #(
        parameter integer CLK_FREQ_HZ = 100_000_000,
        parameter integer DEBOUNCE_MS = 20
    )(
        input  wire clk,
        input  wire rst,
        input  wire button_in,    // 默认：松开=1，按下=0
        output reg  press_pulse,
        // ===== 【优化一】新增：消抖后的"稳定状态"输出（给长按检测用）=====
        output reg  button_stable_out
    );

    localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;

    reg button_sync0;
    reg button_sync1;
    reg button_stable;
    reg [31:0] cnt;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            button_sync0  <= 1'b1;
            button_sync1  <= 1'b1;
            button_stable     <= 1'b1;
            button_stable_out <= 1'b1;      // 【优化一】
            cnt               <= 32'd0;
            press_pulse       <= 1'b0;
        end
        else begin
            button_sync0 <= button_in;
            button_sync1 <= button_sync0;
            press_pulse  <= 1'b0;

            if (button_sync1 == button_stable) begin
                cnt <= 32'd0;
            end
            else begin
                if (cnt >= DEBOUNCE_CYCLES - 1) begin
                    if (button_stable && !button_sync1)
                        press_pulse <= 1'b1;
                    button_stable     <= button_sync1;
                    button_stable_out <= button_sync1;   // 【优化一】同步输出稳定状态
                    cnt               <= 32'd0;
                end
                else begin
                    cnt <= cnt + 32'd1;
                end
            end
        end
    end

endmodule
