`timescale 1ns/1ps
// ============================================================================
// audio_scope.v —— 【扩展项(5) 音频波形可视化】示波器波形 + 峰值条
// ============================================================================
// 【赛题原文】扩展要求(5)："尝试结合音频数据生成频谱或波形显示，**叠加于视频画面**，
//             增强交互展示效果。"
//
// ============================================================================
//
// ============================================================================
//   【为什么返工】我自己发明了一版"幅度柱"（32根柱子比高低），
//     结果上板是**三条横贯全屏的色带** —— 因为"第几根柱"的编号算错了，
//     所有横坐标都被判成同一根柱子，于是三段柱高颜色各占一整条横带。
//
//   ⇒【教训】**不要自己发明画法**。常规设计《_音频波形可视化.md》给了
//     一整套**验证过的**画法，的完赛工程就是用它：
//         rtl/display/promax_audio_waveform.v（140行）
//     本文件现在就是**按它的思路和结构重写的**。
//
// ----------------------------------------------------------------------------
// 【常规的做法是什么（说明）】
//   不是"比高低的柱子"，而是**像医院的心电图一样，把声音画成一条上下起伏的线**。
//
//   ┌────────────────────────────────────────┐  ← 波形区 (512×64)
//   │            ～～～╱╲～～～               │
//   │ ───────────╱   ╲────────────          │  ← 中间那条灰线 = 静音时的基准线
//   │        ╲╱                              │
//   └────────────────────────────────────────┘ [橙条] ← 右边一条橙色峰值条
//
//   · 横轴 = 时间：把最近 32 个声音采样点，**从左到右**依次画出来
//   · 纵轴 = 音量：采样值越大，那一点画得越高；越小，越低
//   · 中间灰线 = 静音基准线（0 值的位置）
//   · 右边橙条 = 这一段的最大音量（像专业调音台上的"峰值表"）
//
// ----------------------------------------------------------------------------
// 【三个关键技术（常规做法 / 2.3 / 2.4 节）】
//
//   ① 抽取（Decimation）—— "不能全画，太密了"
//      音频每秒 48000 个点，一帧只画 32 个点。如果全画，屏幕上就是一团糊。
//      ⇒ 每 12 个点里**只挑 1 个**画（DECIMATE=12）：
//          32 个点 × 12 = 384 个原始点 ≈ 半秒的声音
//      ⇒ 看起来"一屏差不多是半秒的波形"，不快不慢正合适。
//
//   ② 双缓冲（Ping-Pong）—— "别一边写一边读，会撕"
//      例：一边擦黑板一边写，学生看到的字就是"上半截新、下半截旧"。
//      解法：准备**两块黑板**（bank0 / bank1）。
//        · 一块正被"写"（采集声音）
//        · 另一块正被"看"（画到屏幕上）
//        每帧开始时**交换**一下。
//      ⇒ 读的人永远看的是**一整帧完整的**数据，绝不会看到半新半旧。
//
//   ③ 峰值检测 —— "顺手记下这一段最响到多少"
//      采集的过程中，一边比大小，记下这 32 个点里**绝对值最大的那个**。
//      ⇒ 画成右边那条橙色柱子，专业叫 VU 表。
//
// ----------------------------------------------------------------------------
// 【软回退】SCOPE_ENABLE = 1'b0 → 完全不贴，像素原样透传，等于没加过。
// ============================================================================
module audio_scope #(
    // ---- 波形区域（真实像素坐标）----
    parameter integer WAVE_X      = 64,    // 波形区左上角 X
    parameter integer WAVE_Y      = 400,   // 波形区左上角 Y
    parameter integer WAVE_WIDTH  = 512,   // 波形区宽度
    parameter integer WAVE_HEIGHT = 64,    // 波形区高度（含上下各32像素的摆动空间）
    // ---- 抽取参数 ----
    parameter integer DECIMATE    = 12,    // 每 12 个采样点取 1 个
    // ---- 软回退开关 ----
    parameter         SCOPE_ENABLE = 1'b1
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        frame_start,          // 帧起始脉冲（顶层给的 vs 下降沿）
    input  wire [11:0] pixel_x,              // 当前像素 X（真实坐标）
    input  wire [11:0] pixel_y,              // 当前像素 Y（真实坐标）
    input  wire        sample_valid,         // PCM 样本有效脉冲（48kHz 节拍）
    input  wire signed [15:0] sample_l,      // 左声道 16 位样本
    input  wire signed [15:0] sample_r,      // 右声道（本设计不用，保留兼容）
    input  wire        scope_on,             // 【新功能】运行时开关：1=显示波形 0=隐藏（KEY3 控制）
    output wire        hit,                  // 1 = 这个像素属于波形（要贴色）
    output wire [23:0] scope_rgb             // 贴上去的颜色
);
    // ------------------------------------------------------------------
    // 【新功能】参数开关 + 运行时开关 = 真正生效的开关
    //   SCOPE_ENABLE = 出厂总开关（**参数**，编译期定死，不能接运行信号）
    //   scope_on     = 用户按键开关（**端口**，运行时可变，KEY3 每按一次翻转）
    //   两个都为 1 才贴波形；任一为 0 ⇒ hit=0 ⇒ 像素原样透传（画面完全不受影响）
    //    为什么要拆成两个：TD 报过 "'scope_enable_use' is not a constant"，
    //     原因是把一根运行时信号接到了参数口上。参数只能接常量，必须走端口。
    // ------------------------------------------------------------------
    wire scope_active = SCOPE_ENABLE && scope_on;
    // ------------------------------------------------------------------
    // 常量换算（全在编译期算好，运行时不花任何资源）
    // ------------------------------------------------------------------
    localparam integer SAMPLE_COUNT   = 32;                        // 每帧画 32 个点
    localparam integer SAMPLE_SPACING = WAVE_WIDTH / SAMPLE_COUNT; // 512/32 = 16 像素/点
    localparam integer CENTER_Y       = WAVE_Y + WAVE_HEIGHT/2;    // 静音基准线 Y=432

    // ==================================================================
    // 一、采集侧：把声音"抄"到黑板上去
    // ==================================================================
    // 两块黑板：每块存 32 个采样点（只存高 8 位就够，因为波形高度只有 64 像素）
    reg signed [7:0] sample_bank0 [0:SAMPLE_COUNT-1];
    reg signed [7:0] sample_bank1 [0:SAMPLE_COUNT-1];

    reg        write_bank;      // 现在在写哪块（0=bank0, 1=bank1）
    reg        display_bank;    // 现在在看哪块（必须和 write_bank 相反！）
    reg        display_valid;   // 已经攒够一帧数据了吗
    reg [5:0]  capture_count;   // 这一帧已经存了几个点
    reg [7:0]  decimate_count;  // 抽取计数器（12→0 循环）

    reg [7:0]  peak_bank0;      // bank0 里这 32 个点的最大音量
    reg [7:0]  peak_bank1;
    reg [7:0]  display_peak;    // 正在显示的那块的最大音量（帧边界锁存）

    // 取绝对值：负数就"取反加一"（补码转绝对值），正数直接用
    //   取高 8 位：16 位样本 -32768~32767 ⇒ 高 8 位 -128~127，够画 64 像素高的波形
    wire [7:0] sample_abs = sample_l[15] ?
                            (~sample_l[15:8] + 8'd1) : sample_l[15:8];

    reg        frame_q;
    wire       frame_tick = frame_start && !frame_q;   // 帧起始上升沿

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_q        <= 1'b0;
            write_bank     <= 1'b0;
            display_bank   <= 1'b1;    // 初始值必须相反，否则第一帧读写撞车
            display_valid  <= 1'b0;
            capture_count  <= 6'd0;
            decimate_count <= 8'd0;
            peak_bank0     <= 8'd0;
            peak_bank1     <= 8'd0;
            display_peak   <= 8'd0;
        end else begin
            frame_q <= frame_start;

            if (frame_tick) begin
                // ---------- 帧开始：攒够了就"翻板" ----------
                if (capture_count == SAMPLE_COUNT) begin
                    display_bank  <= write_bank;                        // 刚写好的那块，交给"看"
                    display_valid <= 1'b1;
                    display_peak  <= write_bank ? peak_bank1 : peak_bank0;
                    write_bank    <= ~write_bank;                       // 换另一块继续写
                end
                capture_count  <= 6'd0;
                decimate_count <= 8'd0;
                // 把"接下来要写的那块"的峰值清零（正在写的这块不清）
                if (write_bank) peak_bank0 <= 8'd0;
                else            peak_bank1 <= 8'd0;
            end else if (sample_valid && capture_count < SAMPLE_COUNT) begin
                // ---------- 采样节拍：每 12 个点挑 1 个存进去 ----------
                if (decimate_count == 0) begin
                    if (write_bank)
                        sample_bank1[capture_count] <= sample_l[15:8];
                    else
                        sample_bank0[capture_count] <= sample_l[15:8];
                    capture_count  <= capture_count + 6'd1;
                    decimate_count <= DECIMATE[7:0] - 8'd1;
                    // 顺手更新峰值（只往上顶，不往下掉）
                    if (write_bank) begin
                        if (sample_abs > peak_bank1) peak_bank1 <= sample_abs;
                    end else begin
                        if (sample_abs > peak_bank0) peak_bank0 <= sample_abs;
                    end
                end else begin
                    decimate_count <= decimate_count - 8'd1;
                end
            end
        end
    end

    // ==================================================================
    // 二、显示侧：按当前像素坐标，决定这个点画什么颜色（纯组合逻辑）
    // ==================================================================
    integer sample_index;           // 这个像素对应第几个采样点
    integer sample_value;           // 那个采样点的值
    integer sample_y;               // 对应到屏幕上应该画在第几行
    integer peak_height;            // 峰值条的高度（像素）
    reg signed [7:0] selected_sample;
    reg wave_pixel;                 // 是不是波形线上的像素
    reg axis_pixel;                 // 是不是中间那条基准线
    reg peak_pixel;                 // 是不是右边的峰值条

    always @* begin
        sample_index    = 0;
        selected_sample = 8'sd0;
        sample_value    = 0;
        sample_y        = CENTER_Y;
        peak_height     = display_peak >> 2;      // 0~127 ÷4 ⇒ 0~31 像素高
        wave_pixel      = 1'b0;
        axis_pixel      = 1'b0;
        peak_pixel      = 1'b0;

        // ---- ① 先判断：这个像素在不在波形区域里 ----
        if (scope_active && pixel_x >= WAVE_X &&
            pixel_x <  WAVE_X + WAVE_WIDTH &&
            pixel_y >= WAVE_Y && pixel_y < WAVE_Y + WAVE_HEIGHT) begin

            // ---- ② 中间那条静音基准线（深灰，让人看清"零在哪"）----
            axis_pixel = (pixel_y == CENTER_Y);

            // ---- ③ 这个像素对应第几个采样点：横向偏移 ÷ 16 ----
            //      这里必须用**整数除法**：SAMPLE_SPACING=16 是 2 的幂，
            //       TD 会把它综合成**纯移位**，不产生除法器。
            sample_index = (pixel_x - WAVE_X) / SAMPLE_SPACING;

            if (display_valid && sample_index < SAMPLE_COUNT) begin
                // ---- ④ 从"正在看的那块黑板"取出这个采样点 ----
                selected_sample = display_bank ?
                                  sample_bank1[sample_index] : sample_bank0[sample_index];
                sample_value = $signed(selected_sample);
                // ---- ⑤ 换算成屏幕行号：值越大画得越高 ----
                //     除以 4：8位有符号 -128~127 ⇒ ÷4 得 -32~31
                //     正好覆盖 64 像素高的区域（中心上下各 32）
                sample_y = CENTER_Y - sample_value / 4;
                // ---- ⑥ 这一行就是波形线吗？----
                //     ±1 是为了把线**加粗到 3 像素**，1 像素太细看不见
                // 【本次改动】线宽从 ±1（3像素）加粗到 ±2（5像素）：
                //   原因同上——拍摄/投影时会损失细节，细线容易拍不出来，加粗后更显眼。
                wave_pixel = (pixel_y >= sample_y - 2) && (pixel_y <= sample_y + 2);
            end
        end

        // ---- ⑦ 峰值条：从底部往上画的"音量柱" ----
        // 【修复：右下角那个小黄方块】
        //   原来画在 x = WAVE_X + WAVE_WIDTH + 8 = 584 处（**屏幕最右侧**），
        //   颜色是橙黄 24'hffb020 ⇒ 看起来就是**右下角一个孤零零的小黄方块**，
        //   和剪纸画面格格不入，而且很扎眼。
        //   ⇒ 改到**波形区内部左侧**（WAVE_X 起 12 像素宽），当成"音量条"用，
        //     颜色也换成清亮的青色，和绿色波形分开但不突兀。
        if (scope_active && pixel_x >= WAVE_X &&
            pixel_x <  WAVE_X + 12 &&
            pixel_y >= WAVE_Y + WAVE_HEIGHT - peak_height &&
            pixel_y <  WAVE_Y + WAVE_HEIGHT)
            peak_pixel = 1'b1;
    end

    // ==================================================================
    // 三、颜色输出（常规设计第 6 点）
    // ==================================================================
    // 【本次改动：为什么换色】原来是亮绿 20ff90 + 亮青 40E0FF ——
    //   这两个属于"屏幕发光色"，深色背景上好看，但压在**红色白底的剪纸画面**上就糊了：
    //     · 亮绿与红、白底对比度都不够
    //     · 拍摄时机位稍有反光，浅色系直接"消失"
    //     · 手机拍屏幕还会再损失一层对比度
    //   ⇒ 全部换成**深色系**：
    //     波形用深藏蓝 0B3D91（白底上亮度差 10:1 以上，且与红互补不冲突，抗反光最好）
    //     峰值柱用深橙红 C0392B（呼应剪纸主色又深一档，能与白底拉开）
    //     基准线用中灰 707070（不抢眼）
    //   ⇒ 深色在白底上比浅色**更抗反光、更抗拍摄损失**，这是印在白色纸上的道理。
    // ==================================================================
    //   波形线  → 深藏蓝 (24'h0B3D91)
    //   峰值条  → 深橙红 (24'hC0392B)
    //   基准线  → 中灰   (24'h707070)
    //   其它    → 原视频像素（完全透明，图片原样透出来）
    assign hit       = scope_active && (wave_pixel || axis_pixel || peak_pixel);
    assign scope_rgb = wave_pixel ? 24'h0B3D91 :   // 深藏蓝（波形）
                       peak_pixel ? 24'hC0392B :   // 深橙红（峰值柱）
                       axis_pixel ? 24'h707070 :   // 中灰（基准线）
                                    24'h000000;
endmodule
