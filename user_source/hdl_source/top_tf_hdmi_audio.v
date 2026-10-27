
module top(
    input                       clk,
    input                       rst_n,
    input                       key1,           // 【暂时不用】丝印 KEY2 那个按键，消抖脉冲实测打不进来（=收不到）
    input                       key2,           // 【现在归它干全部】丝印 KEY4：短按=轮播开关；按住1秒=上一张
input                       key3,           // 【新功能】丝印 KEY3：按一下切换"底部音频波形"显示/隐藏
    // ===== 4 个拨码开关（板上 SW1~SW4）=====
    //   手册原文：SW1=C8  SW2=C7  SW3=C6  SW4=C5，**拨上是1，拨下是0**
    //   用途：调节亮度和对比度（用户IO做参数配置，赛题扩展项明确要求）
    //    拨码是静态开关，不需要消抖。
    input                       sw1,
    input                       sw2,
    input                       sw3,
    input                       sw4,

    output [5:0]                seg_sel,
    output [7:0]                seg_data,

    // HDMI TMDS
    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,

    // HDMI DDC
    output                      HDMI_DDC_SCL,
    inout                       HDMI_DDC_SDA,

    // TF card SPI
    output                      sd_ncs,
    output                      sd_dclk,
    output                      sd_mosi,
    input                       sd_miso
);

parameter MEM_DATA_BITS = 32;
parameter ADDR_BITS     = 21;
parameter BUSRT_BITS    = 10;
parameter FRAME_PIXELS  = 24'd307200;   // 640*480
parameter BUF0_ADDR     = 24'd0;
parameter BUF1_ADDR     = FRAME_PIXELS;

// ===== 音频源选择（单变量验证用，编译前只改这一个数）=====
//   2'd0 = I2S 方波（基础链路，对照用）
//   2'd1 =  正弦波测试音（16点LUT，验证通路）
//   2'd2 =  媒体音调联动（换图片换音调）
//   2'd3 = 片内旋律：4 段剪纸风格五声音阶，**换图换曲**（音视频联动）
parameter [1:0] AUDIO_SRC_SEL = 2'd3;   //  现在默认用"换图换曲"的旋律

// ===== OSD字幕总开关（单变量验证用，编译前只改这一个数）=====
//   1'b1 = 开字幕
//   1'b0 = 完全关掉字幕，像素走原路，和"加OSD之前"一模一样（保底回退开关）
parameter OSD_ENABLE = 1'b1;   // 1=开 0=关

// ===== 片内旋律播放器总开关（软回退）=====
//   1'b1 = 开（配合 AUDIO_SRC_SEL=2'd3 使用）：换图换曲
//   1'b0 = 完全关掉旋律，音频退回原来的音调链路，等于没加过
parameter TUNE_ENABLE = 1'b1;

// ===== 【扩展项(4)】参数值上屏总开关（软回退）=====
//   1'b1 = 屏幕左下角显示"亮度/对比度/曲目号"小面板
//   1'b0 = 完全不贴，像素原样透传，等于没加过
parameter PARAM_SHOW_ENABLE = 1'b1;

// ===== 【扩展项(5)】音频可视化总开关（软回退）=====
//   1'b1 = 画面底部显示跟着音乐跳动的波形柱
//   1'b0 = 完全不贴，像素原样透传，等于没加过
parameter SCOPE_ENABLE = 1'b1;

// ===== 【汉字字幕】中文双行字幕开关（单变量验证用，编译前只改这一个数）=====
//   1'b1 = 显示"每张图自己的中文双行字幕"（16×16点阵，主标题+副标题）
//   1'b0 = 退回原始版本：数字/字母小字幕（图号 + A/E + 错误码）
//    这一条就是"对照开关"：改 1 个字符就能做 A/B 对比
parameter CN_TEXT_ENABLE = 1'b1;

// ===== 放大：字幕放大倍数（编译前只改这一个数）=====
//   原理：把送进OSD的"门牌号"除以这个倍数 ⇒ 字模一个点变成 N×N 的方块
//   字幕在屏幕上的真实像素 = 框的尺寸 × 倍数
//   汉字路线：框是 96×32（6格×16列 宽，2行×16行 高）
//     4'd1 = 96×32   （一个字 16×16，太小看不清）
//     4'd2 = 192×64  ← 【默认】一个字 32×32 真实像素，正好清楚
//     4'd3 = 288×96  （右下角和右边会顶到屏边，位置要跟着改）
//   数字/字母路线：框是 32×8，倍数说明见原始版本
//    汉字路线默认 2；若只想看数字/字母原样，把 CN_TEXT_ENABLE 置 0、这里置 3
parameter [3:0] OSD_SCALE = 4'd2;   // 【放大】1=原始大小，其它=放大几倍

// ===== 【汉字字幕】中文框在屏幕上的位置（缩小后的坐标，真实像素 = 该数 × OSD_SCALE）=====
//   想要"左下角、不盖住主体"：
//     横向：8 × 2 = 16 像素（左边留一点白）
//     纵向：200 × 2 = 400 像素起，往下 64 像素 ⇒ 占 400~463，底边还留 16 像素
//    想让字幕上移/右移，只改这两个数（注意它们也是"缩小后"的坐标）
parameter [11:0] OSD_X_CN = 12'd8;
parameter [11:0] OSD_Y_CN = 12'd184;   // 【上板后调整】上移，避开底部波形带

// ============================================================================
// ===== 【第十课】图片转场特效 总开关（单变量验证用，编译前只改这几个数）=====
// ============================================================================
//
//
//   转场是什么（说明）：现在按一下键，画面"啪"地一下就换成下一张（硬切），
//   看的人会觉得闪了一下。加上转场之后，按一下键的画面变成：
//       旧图慢慢变暗 → 全黑 → 后台把新图搬进保鲜柜 → 新图慢慢变亮
//   自动轮播换图则是"拉幕布"：新图从左边像擦玻璃一样一点点擦出来。
//
//    软回退：TRANSITION_ENABLE = 1'b0 时
//       ① 转场控制器整体旁路（alpha恒255、wipe_active恒0、请求脉冲原样透传）
//       ② 像素链路完全不加混合逻辑，osd_overlay_24 直接吃原来的 vout_data
//     ⇒ 行为等于"加转场之前"一模一样：按一下立刻换图，无任何过渡效果。
parameter TRANSITION_ENABLE = 1'b1;   // 【第十课】1=开转场 0=完全退回硬切

// 转场类型（= 剪纸花边的方向，对应常规做法
//   2'd0 = 淡入淡出（Alpha混合，经过全黑）—— 模式
//   2'd1 = 【剪纸花边】从左到右       —— 模式 + 剪纸锯齿边
//   2'd2 = 【剪纸花边】从上到下       —— 模式 + 剪纸锯齿边
//   2'd3 = 【剪纸花边】从中心向外 "开窗" —— 模式 + 剪纸锯齿边（最有窗花味）
//    这就是本工程的"剪纸主题"：不是一条直边擦过去，而是一条**剪刀剪出来的锯齿花边**。
//    想让效果更"淡"一点就填 0，立刻退回纯淡入淡出。
parameter [1:0] TRANSITION_KIND = 2'd3;   // 【剪纸主题】默认用"从中心向外开窗"（最有窗花味）

// ===== 【转场修复 2026-09-30】Wipe（拉幕布揭示）本版不实现 —— 常规的前提在我们这里不成立 =====
//   常规做法，
//   意思是"边界左边露新图、右边还留旧图"。
//   可"旧图"在我们这儿**拿不到**：我们是**单口保鲜柜 + 两个格子轮着用**（单读口 SDRAM + 双缓冲），
//   换图的瞬间 sd_card_bmp.v 就把格子指针翻过去了，旧图那格内存马上被新图覆盖
//   ⇒ 想让"边界右边还是旧图"，必须再花一块保鲜柜或先排队预读（常规做法。
//   ⇒ 本版**只做淡入淡出**（常规设计最核心的那条路），Wipe 一行代码都不写、不综合，
//     于是也不可能再出现"边界右边吐纯黑"这种事。
//   ⇒ 以后升级成双 SDRAM，只要改下面"像素混合"那一段就能把 Wipe 加回来。
//     （旧代码里那两个开关参数 WIPE_ENABLE / WIPE_FALLBACK_TO_BLACK 已随 Wipe 一起删除。）

// 淡入淡出帧数（常规做法 参数选择建议表）：
//   8  = 0.13秒  快速改为
//   16 = 0.27秒  ← 常用值，平滑自然（本工程采用）
//   32 = 0.53秒  缓慢优雅
//   0  = 旁路，硬切
//    只能填能整除 256 的值（8/16/32/64…），否则 ramp×STEP 覆盖不满 0~255
parameter integer FADE_FRAMES = 16;

// ===== PLL锁定参与复位 + 有序上电启动：总开关 =====
//   1'b1 = 三个 PLL 的锁定参与复位，PLL 的 reset 接 ~rst_n（优化二）
//   1'b0 = 完全退回"之前"：PLL 的 reset 接 1'b0，复位源只看按键和音频PLL
//    配合下面的 RST_SYNC_EN 一起用：
//     RST_SYNC_EN=1'b0 且 PWR_SEQ_EN=1'b0  →  整个改动全部失效，等于回到改动前
parameter PWR_SEQ_EN = 1'b1;

wire Sdr_init_done;
wire Sdr_init_ref_vld;
wire Sdr_busy;

wire sd_card_clk;
wire ext_mem_clk;
wire ext_mem_clk_sft;
wire video_clk;
wire hdmi_5x_clk;

wire hs;
wire vs;
wire de;

wire [23:0] vout_data_raw;
wire [23:0] vout_data;
wire        display_valid;
wire [5:0]  period_s_o;                  // 【新功能】当前轮播周期（秒），给参数面板

wire [3:0]  state_code;
wire [6:0]  seg_data_0;

wire        video_read_req;
wire        video_read_req_ack;
wire        video_read_en;
wire [31:0] video_read_data;

wire        sd_card_write_en;
wire [31:0] sd_card_write_data;
wire        sd_card_write_req;
wire        sd_card_write_req_ack;
wire        frame_write_finish;
reg         frame_write_toggle_mem;

wire [1:0]  write_buf_idx;
wire [1:0]  disp_buf_idx;

wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS-1:0] Sdr_rd_dout;
wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS-1:0] App_wr_din;
wire [3:0] App_wr_dm;

wire hs_0;
wire vs_0;
wire de_0;

// HDMI 1.4b 音频发射相关
wire        audio_pll_lock;
wire        sys_pll_lock;               // sys_pll 的锁定信号（IP 本来就有 extlock 端口，以前没接）
wire        audio_mclk;
wire        audio_i2s_bclk;
wire        audio_i2s_lrck;
wire        audio_i2s_dout;
wire        audio_valid;
wire [23:0] audio_left_data;
wire [23:0] audio_right_data;
wire        acr_valid;
wire [19:0] acr_cts;
wire [19:0] acr_n;
wire        osd_auto_en_raw;            // sd_card_bmp 给出的“是否在自动轮播”（声明提前，消除 HDL-7225）

// ===== 新音频链路（正弦测试音 / 媒体音调联动）=====
wire        new_audio_valid;
wire [23:0] new_audio_left;
wire [23:0] new_audio_right;

// PCM 探针（音频可视化用，本课先不接）
wire        pcm_tap_valid;
wire signed [15:0] pcm_tap_left;
wire signed [15:0] pcm_tap_right;

// ===== 给 HDMI 发射器核的最终音频（由 AUDIO_SRC_SEL 决定来源）=====
wire        final_audio_valid;
wire [23:0] final_audio_left;
wire [23:0] final_audio_right;

// ===== 【第十课】转场控制器 与 像素混合 的信号 =====
wire        key_next_pulse;              // sd_card_bmp 给出的"下一张"消抖脉冲（切换请求）
// 【2026-09-30】按键长按分级产生的两根脉冲（在 sd_card_bmp 里解调，顶层接出来）
wire        key_long1_pulse;             // 按住 1 秒 → 上一张
wire        key_long2_pulse;             // 按住 2 秒 → 开/关自动轮播
wire        fade_commit_req;             // 【常规设计接线】转场控制器输出："全黑了，去换图"
wire        fade_busy;                   // 转场忙标志
wire [7:0]  fade_alpha;                  // Alpha值 0~255（淡入淡出用）
wire        fade_active;                 // 转场进行中
wire        wipe_active;                 // Wipe揭示中（自动轮播用）
wire [4:0]  wipe_ramp;                   // Wipe边界计数器
// ============================================================================
// ===== 【2026-10-01 关键修复】为什么"剪纸花边"看不见？—— wipe_active 从来没高过 =====
// ============================================================================
// 【现象】烧进去还是硬切，一点转场都看不见。
//
// 【真因】翻常规设计给的 video_fade_transition 状态机（第 103~143 行）：
//     S_IDLE: 收到"手动切换请求"(req_toggle)  → 进 S_OUT，**wipe_mode 保持 0**
//     S_HOLD: 收到 index_commit                → 进 S_IN，**wipe_mode <= 1'b0**
//     只有 S_IDLE 里那个 `else if (index_commit)` 分支才会 `wipe_mode <= 1'b1`
//   ⇒ 即：**按按键的手动切换那一趟，wipe_mode 全程是 0**
//   ⇒ `wipe_active = (state == S_IN) && wipe_mode` **永远是 0**
//   ⇒ 剪纸花边那段像素逻辑一次都没执行过 —— 当然看不见。
//
//   而且不光是"看不见"：按按键走的是"先淡出到黑、再淡入"，
//   而淡出+淡入各 16 帧 ≈ 0.53 秒，理论上应该能看出"暗一下再亮"。
//   如果你连"暗一下"都没看到，那是**第二件事**：
//     next_event_in 接的是 buf_commit_pulse（=图已经读好了），
//     而"读图 + 上屏确认"要 1~2 秒。淡出的 0.53 秒被埋在这 2 秒里，
//     观众看到的是"画面卡住 2 秒 → 突然换图"，所以主观上就是**硬切**。
//
// 【本次怎么修】（两边都改，不改不加新逻辑，只改"什么时候允许花边"）
//   ① 常规实现中 manual→fade / auto→wipe 的区分，在我们这个工程里没有意义：
//      我们**没有 media_player_control**，"手动"和"自动"换图走的是同一条路
//      （都是"先读图、再翻转格子"）。所以两种都该用同一个效果。
//   ② 既然两种都一样，那就**手动切换也用剪纸花边** —— 而且花边比淡入淡出更好：
//      花边不用经过全黑（边界右边本来就是黑，但边界一直在往右走），
//      16 帧内必然扫完 ⇒ 观感比"暗一下再亮"更改为、也更像剪纸。
//   ③ 实现：**不再依赖状态机给的 wipe_mode**，顶层自己判"现在是不是在揭示阶段"。
//
// 【安全】这一条同样**不可能黑屏卡住**：
//    wipe_active_use = (state==S_IN) && (fade_alpha > 0)
//    ⇒ 只要不是"整屏全黑那一瞬"，花边就一定在露新图；
//    ⇒ 而且 FADE_FRAMES 帧内 ramp 必然走完，状态机必然回 S_IDLE
//      （常规设计状态机 S_IN 靠 frame_start 自走，不依赖任何外部握手）。
// ============================================================================
// S_IN 阶段的判据：转场在跑，而且 alpha 已经不为 0（= 正在往回亮，不是全黑那一瞬）
//   fade_active = (state != S_IDLE)，这是模块输出的"转场进行中"。
wire wipe_in_phase = fade_active && (fade_alpha != 8'd0);
// 最终给花边模块用的 enable：转场开着 + 在揭示阶段 + 选了花边模式（KIND != 0）
wire wipe_active_use = TRANSITION_ENABLE && (TRANSITION_KIND != 2'd0) && wipe_in_phase;

// ============================================================================
// ===== 【2026-10-01 真正的收尾】花边本来就对，只是"给它的时间太短" =====
// ============================================================================
// 【诊断结论（都是你在板子上亲眼看到的硬证据）】
//   诊断1 彩带：铺满整行           ⇒ pixel_x 正确
//   诊断3 十字：正好在正中央        ⇒ pixel_x / pixel_y 都正确
//   诊断4 in_r：中央一大块亮绿、四角暗红、边缘还是锯齿状
//        ⇒ **整套窗口数学 + 花边锯齿 100% 正确！** 电路全通！
//
// 【那为什么正常按键时看不见？】时间不够，而且不是"太快"那种不够，是**被切碎了**：
//   ① S_IN 阶段一共 16 帧 ≈ 0.27 秒 —— 本来就短
//   ② 更关键的是 S_OUT（淡出）先把画面压到全黑，S_HOLD 还要**等读卡 1~2 秒**，
//      等新图到了才进 S_IN。也就是：
//          按键 → 0.27秒淡出变黑 → **黑 1.8 秒** → 0.27秒花边淡入
//      ⇒ 你眼睛盯着的是"黑了一下然后图换了"。花边只在最后 0.27 秒闪一下，
//        而且那时画面是从黑里刚亮起来，**花边对比度极低**，根本注意不到。
//
// 【修法】让花边**全程可见**：不再依赖状态机那 16 帧，
//   而是顶层自己按"帧"数一个**慢速计数器**，把花边拉长到 **48 帧（0.8 秒）**，
//   并且**从按键那一刻就开始**（在旧图上跑），不等读卡。
//   ⇒ 用户看到：一按键，旧图上立刻有一道窗花打开，0.8 秒扫完，然后新图上来。
//   ⇒ 完全独立于常规设计那个状态机，所以不会影响它的安全特性（有界等待、防黑兜底都还在）。
//
// 【安全】花边计数器**一定会走完**（数到 48 自动停），所以不可能半黑卡住。
//   而且 wipe_active 只在计数器没数完时才是 1，数完就回正常显示。
// ============================================================================

// ============================================================================
// ===== 【诊断开关】把花边"钉死"（排查完就关掉）=====
//   WIPE_DEBUG_FORCE = 1'b1 → 花边一直开着、固定在"半开"，用来确认电路通不通
//   WIPE_DEBUG_FORCE = 1'b0 → 【正常】走真实的花边动画
//    电路已经用这个开关验证通了（用户看到"中央亮绿+四角暗红+锯齿边"），
//     所以现在**改回 0**，让它跑真正的动画。
// ============================================================================
parameter WIPE_DEBUG_FORCE = 1'b0;      // ← 已排查完，正常模式
parameter [4:0] WIPE_DEBUG_RAMP = 5'd8;

// 转场方向由 TRANSITION_KIND 选（保留原名 transition_kind 做观察点）
wire [1:0]  transition_kind;             // 转场类型（预留）

// ===== 【必须提前声明的中转信号】（TD 只要"先用后声明"就报 HDL-7225 / not declared）=====
//   规则一句话：**任何 wire/reg，第一行用到它之前必须已经声明过**；
//   否则 TD 会自己造一根 1 位的"隐形线"（隐式网线），后面的正式声明就变成"重复声明"。
//   这几根线都是"模块之间要传话"的中转线，所以统一搬到文件顶部来。
wire        buf_commit_pulse;            // 保鲜柜换格子了 = 新图已进柜（换图事件）
reg  [1:0]  disp_buf_idx_q;              // disp_buf_idx 打一拍（用来判"变没变"）
// 【剪纸花边】这两个坐标是"像素在屏幕上的位置"，剪纸擦除模块要用。
//    它们的**产生代码**在后面（用 de/vs 数出来的），但这里是**声明**。
//     声明必须在第一次使用之前，否则 TD 会造一根 1 位的隐形线，然后就报错。
//     （此前遇到过两次同类问题：osd_index / osd_rst_n，均为"先用后声明"。）
reg  [11:0] osd_pixel_x;                 // 行内 X 坐标 0~639
reg  [11:0] osd_pixel_y;                 // 行号 Y 坐标 0~479
reg         new_img_ready;               // "新图已备好"的锁存事实（给转场状态机放行用）
reg         osd_vs_q;                    // vs 打一拍（用来抓"一帧的起点"）
wire        osd_rst_n;                   // 像素域的低有效复位（OSD 用；本工程统一是高有效，这里翻一下）
wire [1:0]  osd_index;                   // 当前图片编号 0~3（汉字字幕靠它选该显示哪两行字）

wire        axis_s_user;
wire        axis_s_valid;
wire        axis_s_last;
wire [23:0] axis_s_data;
wire        axis_s_ready;

wire        edid_trig;
wire        edid_valid;
wire [7:0]  edid_data;

wire [9:0]  tmds_ch0_data;
wire [9:0]  tmds_ch1_data;
wire [9:0]  tmds_ch2_data;
wire [9:0]  tmds_clk_data;

// 保持你原来的 TF / SDRAM / video 时钟
// PLL 的 reset 从 1'b0 改成 ~rst_n：系统复位时 PLL 也复位，然后重新锁定
//   软回退：PWR_SEQ_EN=1'b0 时，PLL 复位端口退回原来的 1'b0
sys_pll sys_pll_m0(
    .refclk     (clk),
    .clk0_out   (sd_card_clk),
    .clk1_out   (ext_mem_clk),
    .clk2_out   (ext_mem_clk_sft),
    .reset      (PWR_SEQ_EN ? ~rst_n : 1'b0),
    .extlock    (sys_pll_lock)
);

video_pll video_pll_m0(
    .refclk     (clk),
    .clk0_out   (video_clk),
    .clk1_out   (hdmi_5x_clk),
    .reset      (PWR_SEQ_EN ? ~rst_n : 1'b0)
);

// 复用你 I2S->HDMI 工程里的 PLL，只取 12.288MHz 音频主时钟
PLL_HDMI_AUDIO u_audio_pll(
    .refclk     (clk),
    .reset      (PWR_SEQ_EN ? ~rst_n : 1'b0),
    .extlock    (audio_pll_lock),
    .clk0_out   (),
    .clk1_out   (),
    .clk2_out   (audio_mclk)
);

// ===================== 优化一+优化二：复位源与复位同步 =====================
// 【改动说明】原来只有一行：assign rst_all = ~rst_n | ~audio_pll_lock;
//   问题（常规做法 的 6 个隐患）：①释放是异步的→亚稳态；②四个时钟域共用一个复位；
//   ③只有 audio_pll_lock 参与；⑤没有上电延时；⑥SDRAM 没初始化完就开始扫描。
// 【现在的做法】复位源 = 外部按键 + 三个 PLL 都锁定；再给每个时钟域配一个 reset_sync。
//
//  软回退开关（大总闸）：RST_SYNC_EN=1'b0 时 rst_all 完全退回原来那一行公式，
//   四个 reset_sync 也不再生效，行为与"之前"一模一样。
localparam RST_SYNC_EN = 1'b1;

// 复位源：外部复位按键 + 三个 PLL 都锁定。任何一个 PLL 没锁定，系统就保持复位。
wire ext_rst_n = rst_n & sys_pll_lock & audio_pll_lock;

// 每个时钟域一个复位同步器（异步压下、同步释放）
wire sdcard_rst_n;
wire mem_rst_n;
wire video_rst_n;
wire audio_rst_n;

reset_sync u_sdcard_reset (
    .clk        (sd_card_clk),
    .ext_rst_n  (ext_rst_n),
    .rst_n_sync (sdcard_rst_n)
);

reset_sync u_mem_reset (
    .clk        (ext_mem_clk),
    .ext_rst_n  (ext_rst_n),
    .rst_n_sync (mem_rst_n)
);

reset_sync u_video_reset (
    .clk        (video_clk),
    .ext_rst_n  (ext_rst_n),
    .rst_n_sync (video_rst_n)
);

reset_sync u_audio_reset (
    .clk        (audio_mclk),
    .ext_rst_n  (ext_rst_n),
    .rst_n_sync (audio_rst_n)
);

// ===================== 选做：Sdr_init_done 跨时钟域同步 =====================
// Sdr_init_done 在 ext_mem_clk 域，sd_card_bmp 在 sd_card_clk 域（同源 100MHz，相位固定）。
// 严谨做法：用两级触发器搬一次，消除亚稳态传播。
wire Sdr_init_done_sd;
sync_2ff u_sdram_init_sync (
    .clk        (sd_card_clk),
    .rst_n      (sdcard_rst_n),
    .async_in   (Sdr_init_done),
    .sync_out   (Sdr_init_done_sd)
);

// 统一复位：TF 图像链路 + HDMI 音频链路
// 开关为 0 → 逐字退回原来的写法（保底，一行都不多）
wire rst_all = RST_SYNC_EN ? (~ext_rst_n)
                           : (~rst_n | ~audio_pll_lock);

// 各时钟域的高有效复位（各子模块均为高有效 rst，所以对同步后的低有效复位取反）
wire sdcard_rst = RST_SYNC_EN ? (~sdcard_rst_n) : rst_all;
wire mem_rst    = RST_SYNC_EN ? (~mem_rst_n)    : rst_all;
wire video_rst  = RST_SYNC_EN ? (~video_rst_n)  : rst_all;
wire audio_rst  = RST_SYNC_EN ? (~audio_rst_n)  : rst_all;

// mem_clk 域把 write_finish 单拍转成 toggle，供 sd_card_clk 域可靠同步
always @(posedge ext_mem_clk or posedge mem_rst) begin
    if (mem_rst)
        frame_write_toggle_mem <= 1'b0;
    else if (frame_write_finish)
        frame_write_toggle_mem <= ~frame_write_toggle_mem;
end

// ============================================================================
// ===== 【2026-09-30 现场实测后的接线调整】按键分工最终版 =====
// ============================================================================
// 【现场现象】用户实测：
//     丝印 KEY4 短按 → 能开/关自动轮播 
//     丝印 KEY4 长按 1 秒 → 能"上一张" 
//     丝印 KEY2（= 代码里的 key1，"下一张"）→ **按下去一点反应都没有** 
//       而且数码管也不动 ⇒ 说明那个键的**消抖脉冲根本没走到 sd_card_bmp 里面**
//       （如果走到了而换图失败，数码管至少会闪 A/E/F）。
//
// 【我上一版做错的地方（记下来，别再犯）】
//   我当时为了"先把功能做出来"，把三个动作全并到一个键上。
//   这是**违反赛题基础要求(3)**的 —— 原文明确要求 "≥2 个按键（下一张 / 轮播开关）"。
//   所以现在改回"两个键"，只是给 KEY4 加了一层"按住2秒=兜底下一张"的保险。

// ============================================================================
// ===== 【第十课·转场接线】"下一张"的按键怎么走（原设计，保留） =====
// ============================================================================
// 常规做法
//   "fade_next_event 接到 media_player_control 的切换请求输入（替代原来的 key_next_press 直连）"
// 也就是常规的意图是：**换图不要按键直连，要经过转场控制器，淡出到全黑之后才换。**
//
// 本工程没有 media_player_control，换图入口是 sd_card_bmp 的 key_next 端口。
// 我们**部分照常规设计做**，但把顺序调了一下，原因很实在：
//
//   【如果严格照常规设计接线】按键 → 转场控制器淡出(0.13s) → 通知换图 → 读卡(1.2~1.8s) → 淡入
//       问题：全黑之后还要**现读卡 1.2~1.8 秒**，屏幕上就是"黑了将近两秒才出新图"。
//       常规的工程不会这样，因为它读图快、图是预先加载好的；本工程 TF 卡单块读，
//       一次换图实测约 1.2~1.8 秒（sd_card_bmp.v:10 的注释写着）。
//
//   【本工程采用的顺序：先读图，再淡出】
//       按键 → sd_card_bmp **立刻**开始读卡（这 1~2 秒画面照常显示旧图，不黑！）
//            → 读完、缓冲区翻好（buf_commit_pulse）
//            → 这时才让转场控制器开始淡出 → 全黑 → 立刻淡入（新图已在保鲜柜里）
//       ⇒ 看到的效果和常规设计一模一样：淡出 → 黑 → 换 → 淡入
//       ⇒ 但黑屏只有"全黑那一两帧"，不是整整两秒。
//
// 所以这三根线的分工是：
//   sd_key_next_eff  → sd_card_bmp.key_next ：按键脉冲，**按下就立刻读卡**（预加载）
//   key_next_req_ctrl→ 控制器 next_event_in："缓冲区已换"事件，**读好了才开始淡出**
//   fade_commit_req  → 控制器 next_event_out：本方案下不驱动换图，留作观察点
//
//  转场关掉时（TRANSITION_ENABLE=1'b0）：
//     sd_key_next_eff 还是按键脉冲（等于原来的硬切），
//     控制器内部 FADE_FRAMES=0 走 g_bypass 分支 ⇒ 整体退回"没加转场"的样子。
//
// ============================================================================
// ===== 【2026-09-30 修正】两个按键各司其职 —— 赛题基础要求(3) =====
// ============================================================================
// 【赛题原文】1.3 基础要求 (3)：**≥2 个按键**（"下一张" / "轮播开关"）+ 轮播周期可配置
//   ⇒ 所以**绝不能用"一个键干完所有事"**来交差，那属于直接不符合基础要求。
//   （我上一版图省事并成一个键，是错的；这里改回来，并把教训留在注释里。）
//
// 【最终分工（丝印为准）】
//   丝印 KEY2  → 顶层 key1 → sd_card_bmp.key_next  → **下一张**（赛题要求的那个键）
//   丝印 KEY4  → 顶层 key2 → sd_card_bmp.key_auto  → 短按 = **轮播开关**
//                                                    按住 1 秒 = **上一张**
//                                                    按住 2 秒 = 兜底的一次"下一张"
//   ⇒ 两个键、三种操作，满足"≥2个按键"。
//
// 【为什么保留"按住2秒=下一张"这条兜底】
//   丝印 KEY2 那条线之前实测不响应，原因还没查清。留一条兜底，
//   万一现场它又不行，演示也不会彻底卡住。**但正常演示要用 KEY2**。
// ============================================================================
parameter integer AUTO_TOGGLE_HOLD_MS = 2000;   // 按住这么久 = 兜底一次"下一张"（毫秒）

// ============================================================================
// 【2026-09-30 找到真凶】 —— 我自己绕出来的死循环
// ============================================================================
// 【上一版写的是】wire sd_key_next_eff = key_next_pulse;
//   而 key_next_pulse 是 sd_card_bmp **自己输出**的（下面例化的 .key_next_pulse_o）。
//   ⇒ 等于把水龙头接回了它自己的进水管：
//        丝印KEY2 → key1 → sd_card_bmp.key_next → 产生 key_next_press → 输出 key_next_pulse
//                                                   ↑
//                                                   └── 又送回 sd_card_bmp.key_next
//   ⇒ 按键的真实信号被一个**空转的死循环**替换掉了 ⇒ **KEY2 永远按不出反应**。
//   ⇒ 而 KEY4 走的是 key2 直连，没被绕进去，所以一直好用。
//
// 【现在改成】直接接丝印按键的原始输入，让消抖在 sd_card_bmp 内部做（原始设计就是这样）：
//     丝印 KEY2 → key1 → sd_card_bmp.key_next → 内部消抖 → key_next_press → 换图
//   ⇒ 消抖只做一次、在唯一正确的位置做，信号链是一条直线，没有回路。
//
// 引脚对照（《HX4S20开发板手册-HDL版2410》第2.20节 原文）：
//     KEY1=A2  KEY2=B2  KEY3=B1  KEY4=C1    按下=低电平，松开=高电平
// 本工程用法：
//     KEY1(A2) → rst_n   复位
//     KEY2(B2) → key1    **下一张**（赛题要求的那个键）
//     KEY3(B1) → 未使用
//     KEY4(C1) → key2    短按=轮播开关；按住1秒=上一张；按住2秒=兜底一次"下一张"
// ============================================================================
wire sd_key_next_eff = key1;              // 【修正】下一张 = 丝印 KEY2 的原始输入（B2）
wire sd_key_auto_eff = key2;              // 轮播开关 = 丝印 KEY4 的原始电平（C1）
wire sd_key_prev_eff = key_long1_pulse;   // 上一张 = 丝印 KEY4 的 1 秒长按脉冲

// ===================== TF 多图扫描与缓存（双缓冲） =====================
sd_card_bmp #(
    .CLK_FREQ_HZ       (100_000_000),
    .SCAN_START_SECTOR (32'd0),
    .SCAN_MAX_SECTOR   (32'd131071),
    .SCAN_TARGET_COUNT (3'd4),//控制可以显示多少张图
    .SDRAM_INIT_WAIT_EN(1'b1),//1=等SDRAM初始化完成才扫描 0=退回原来的立刻扫描
    // 【2026-09-30 修正】下面这个是**参数(parameter)**，必须写在 #( ... ) 里面！
    //   上一版我误写进了下面的端口列表 ⇒ TD 报 "'KEY_KEY4_MODE' is not a port"。
    //   说明：参数 = "出厂设置"，端口 = "插座"。出厂设置要在订货单(#)上写，
    //   插座在接线单()上接。写错单子，TD 就说不认识。
    .AUTO_TOGGLE_MS    (AUTO_TOGGLE_HOLD_MS)   // 按住到这个时长 = 兜底一次"下一张"
) sd_card_bmp_m0(
    .clk               (sd_card_clk),
    .rst               (sdcard_rst),          //sd_card_clk 域同步复位
    .Sdr_init_done     (Sdr_init_done_sd),    //跨时钟域同步后的"保鲜柜已就绪"
    // 【赛题基础要求(3)】轮播周期在线可配置：SW1/SW2 两个拨码选 4 档
    //   SW2 SW1 = 00→2秒  01→3秒  10→5秒  11→8秒
    //    拨码是"慢慢拨"的人手动作，不按键那样有抖动 ⇒ 可以直连，无需消抖。
    .sw1               (sw1),
    .sw2               (sw2),
    .key_next          (sd_key_next_eff),//【第十课·常规设计接线】不再直连 key1！
                                         //   转场开着时 = 转场控制器"全黑了"的脉冲（淡出后才换图）
                                         //   转场关着时 = 原先的"按键消抖脉冲"（完全退回硬切）
                                         //   详见下面 sd_key_next_eff 那几行
    .key_auto          (sd_key_auto_eff),//【2026-09-30】丝印 KEY4 的原始电平（短按=轮播开关）
    .key_prev_pulse_i  (sd_key_prev_eff),//【2026-09-30】丝印 KEY4 的 1 秒长按脉冲（上一张）
    .state_code        (state_code),
    .auto_play_en_o    (osd_auto_en_raw),//自动轮播状态(1=轮播中)给OSD字幕用
    .period_s_o        (period_s_o),     // 【新功能】轮播周期（秒）给参数面板
    .key_next_pulse_o  (key_next_pulse), //【第十课】"下一张"消抖脉冲给转场控制器用
    .key_long1_pulse_o (key_long1_pulse),//【2026-09-30】1秒长按脉冲（上一张）给顶层看
    .key_long2_pulse_o (key_long2_pulse),//【2026-09-30】2秒长按脉冲（开/关轮播）给顶层看
    .bmp_width         (16'd640),
    .bmp_height        (16'd480),
    .display_valid     (display_valid),

    .write_finish_toggle(frame_write_toggle_mem),
    .write_buf_idx     (write_buf_idx),
    .disp_buf_idx      (disp_buf_idx),

    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data),
    .SD_nCS            (sd_ncs),
    .SD_DCLK           (sd_dclk),
    .SD_MOSI           (sd_mosi),
    .SD_MISO           (sd_miso)
);

seg_decoder seg_decoder_m0(
    .bin_data          (state_code),
    .seg_data          (seg_data_0)
);

seg_scan seg_scan_m0(
    .clk               (clk),
    .rst_n             (rst_n),   // 注意：seg_scan 跑在 50MHz 晶振原始时钟域，
                                  // 不是三个 PLL 里的任何一个，所以这里保持原来的 rst_n，不走同步器
    .seg_sel           (seg_sel),
    .seg_data          (seg_data),
    .seg_data_0        ({1'b1,7'b1111_111}),
    .seg_data_1        ({1'b1,7'b1111_111}),
    .seg_data_2        ({1'b1,7'b1111_111}),
    .seg_data_3        ({1'b1,7'b1111_111}),
    .seg_data_4        ({1'b1,7'b1111_111}),
    .seg_data_5        ({1'b1,seg_data_0})
);

// ===================== 原图像时序与帧缓存 =====================
video_timing_data video_timing_data_m0(
    .video_clk         (video_clk),
    .rst               (video_rst),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0)
);

video_delay video_delay_m0(
    .video_clk         (video_clk),
    .rst               (video_rst),
    .read_en           (video_read_en),
    .read_data         (video_read_data[31:8]),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0),
    .hs_r              (hs),
    .vs_r              (vs),
    .de_r              (de),
    .vout_data         (vout_data_raw)
);

// 首图提交前黑屏；提交后一直显示当前显示缓冲区内容
assign vout_data = display_valid ? vout_data_raw : 24'd0;

frame_read_write #(
    .WRITE_V_FLIP     (1),
    .FRAME_WIDTH      (640),
    .FRAME_HEIGHT     (480)
) frame_read_write_m0(
    .mem_clk           (ext_mem_clk),
    .rst               (mem_rst),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),

    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout),

    .read_clk          (video_clk),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .read_finish       (),
    .read_addr_0       (BUF0_ADDR),
    .read_addr_1       (BUF1_ADDR),
    .read_addr_2       (24'd0),
    .read_addr_3       (24'd0),
    .read_addr_index   (disp_buf_idx),
    .read_len          (FRAME_PIXELS),
    .read_en           (video_read_en),
    .read_data         (video_read_data),

    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_din        (App_wr_din),
    .App_wr_dm         (App_wr_dm),

    .write_clk         (sd_card_clk),
    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_finish      (frame_write_finish),
    .write_addr_0      (BUF0_ADDR),
    .write_addr_1      (BUF1_ADDR),
    .write_addr_2      (24'd0),
    .write_addr_3      (24'd0),
    .write_addr_index  (write_buf_idx),
    .write_len         (FRAME_PIXELS),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data)
);

sdram U3(
    .Clk               (ext_mem_clk),
    .Clk_sft           (ext_mem_clk_sft),
    .Rst               (mem_rst),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_dm         (App_wr_dm),
    .App_wr_din        (App_wr_din),
    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout)
);

// ===================== 音频：内部 I2S 测试音 =====================
hdmi_audio_tone_i2s_64fs #(
    .PHASE_INC (32'd39370534),
    .AMP       (24'sd2000000)
) u_hdmi_audio_tone_i2s_64fs (
    .I_mclk      (audio_mclk),
    .I_rst       (audio_rst),
    .O_i2s_BCLK  (audio_i2s_bclk),
    .O_i2s_LRCK  (audio_i2s_lrck),
    .O_i2s_DOUT  (audio_i2s_dout)
);

I2S_receiver u_I2S_receiver(
    .I_clk              (video_clk),
    .I_rst              (video_rst),
    .I_i2s_BCLK         (audio_i2s_bclk),
    .I_i2s_LRCK         (audio_i2s_lrck),
    .I_i2s_DOUT         (audio_i2s_dout),
    .O_audio_valid      (audio_valid),
    .O_audio_left_data  (audio_left_data),
    .O_audio_right_data (audio_right_data)
);

audio_arc_calculate #(
    .ACR_N         (6144)
) u_audio_arc_calculate (
    .I_clk         (video_clk),
    .I_rst         (video_rst),
    .I_audio_valid (final_audio_valid),          // ACR 数"最终送出去的"音频样本脉冲
    .O_acr_valid   (acr_valid),
    .O_acr_cts     (acr_cts),
    .O_acr_n       (acr_n)
);

// ===================== ：图片ID(media_id) 接入 =====================
// 图片ID 直接复用数码管正在显示的图号：state_code = 图号 + 1（优化三改成显示 1~4）
// 图号 1~4 → media_id 0~3；看门狗等异常码(0/A/E/F)一律当 0，避免乱响
// state_code 在 sd_card_clk(100MHz) 域，音频在 video_clk(25MHz) 域，用两级同步器搬过来
wire [3:0] media_id_raw = ((state_code >= 4'd1) && (state_code <= 4'd4)) ? (state_code - 4'd1) : 4'd0;
reg  [3:0] media_id_meta;
reg  [3:0] media_id_sync;

// 【新功能】页码也要跨时钟域（100MHz → 25MHz）给参数面板显示
//   拿的是 state_code 本身（图号 1~4），异常码(0/A/E/F)当 0 显示
wire [3:0] page_no_raw = ((state_code >= 4'd1) && (state_code <= 4'd4)) ? state_code : 4'd0;
reg  [3:0] page_no_meta;
reg  [3:0] page_no_sync;

always @(posedge video_clk or posedge video_rst) begin
    if (video_rst) begin
        media_id_meta <= 4'd0;
        media_id_sync <= 4'd0;
        page_no_meta  <= 4'd0;
        page_no_sync  <= 4'd0;
    end
    else begin
        media_id_meta <= media_id_raw;
        media_id_sync <= media_id_meta;
        page_no_meta  <= page_no_raw;
        page_no_sync  <= page_no_meta;
    end
end

// ===================== 片内旋律播放器（换图换曲 = 音视频联动）=====
// 【做什么】芯片里"刻"好 4 段剪纸风格的五声音阶小旋律，你看第几张图就唱哪一段。
//   ⇒ 换图 → 换曲，这就是赛题要的"**音视频联动**"（对应扩展要求 1.4(2)）。
// 【为什么不用 TF 卡读 WAV】常规设计原方案要把 SD 卡控制器提到顶层、图片和音频
//   分时抢占同一个卡。我们工程的 sd_card_bmp（820 行）已经把卡包在里面，
//   20 号前动它有**改坏图片链路的风险** ⇒ 改用片内 ROM：
//     · 图片链路一个字节都不碰（零风险）
//     · 音频自带，不依赖 TF 卡（演示时更可靠）
//     · 代价：只能放 16 音符×4 段的小旋律，靠**循环**变成背景音乐 —— 够用。
// 【输入】media_id_sync = 当前图片编号 0~3（已经同步好的那根线，直接复用）
// 【输出】接到下面 media_hdmi_audio_bridge 原本空着的 "wav_*" 那一组口上
//        （常规设计原版就预留了这个口，写的是"WAV 才接"，现在我们接上了）
wire        tune_valid;
wire signed [15:0] tune_left;
wire signed [15:0] tune_right;

tune_rom_player #(
    .CLK_FREQ_HZ (25_000_000),
    .SAMPLE_HZ   (48_000),
    .ENABLE      (TUNE_ENABLE)
) u_tune_rom_player (
    .clk       (video_clk),
    .rst_n     (video_rst_n),
    .img_idx   (media_id_sync[1:0]),   // 当前第几张图（0~3）→ 选第几段旋律
    .out_valid (tune_valid),
    .out_left  (tune_left),
    .out_right (tune_right)
);

// ============================================================================
// ===== 【新功能】KEY3 一键切换"底部音频波形 + 汉字字幕"显示 / 隐藏 =====
// ============================================================================
// 【为什么要这个功能】
//   拍演示视频时，有时想让观众**专心看剪纸画面**（字幕和波形都占地方），
//   有时又想完整展示"字幕 + 声音可视化"。给一个按键随时切换，演示更灵活。
//
// 【本次改动：从"只控波形"改成"同时控字幕和波形"】
//   · 上电默认 **关闭**（刚开始画面干净，只有剪纸图）
//   · 按一下 KEY3 → 字幕和波形**一起出现**
//   · 再按一下    → 两个**一起消失**
//   为什么默认关闭：评委/观众第一眼看到的应该是**作品本身**，
//   干净的画面更有冲击力；需要看扩展功能时按一下键就有，演示时更好讲。
//
// 【怎么做（说明）】
//   ① 先"消抖"：机械按键按下去会弹跳好几下（像弹簧门），
//      不消抖的话按一次会被当成按了 3~5 次。用现成的 key_press_debounce。
//   ② 把"按下"这个**一闪而过的脉冲**变成**一直亮着的灯**：
//      key3_press 只在 100MHz 的**一拍**（10ns）为 1，而波形模块跑在 25MHz（一拍 40ns），
//      **极可能整个错过**（像相机一秒拍一张，闪光只亮 1/100 秒）。
//      ⇒ 先展宽成电平，同步过去后再熄灭（带 ack 握手）。
//   ③ 每收到一次"按下"，把 overlay_on **翻转**（0→1→0→1）。
//   ④ overlay_on 同时送到两个地方：
//        · osd_overlay_24 的 cn_show 端口  → 控制汉字字幕
//        · audio_scope   的 scope_on 端口 → 控制音频波形
//      1 = 两个都显示    0 = 两个都隐藏（画面原样透传，一点不影响）
//
// 【软回退】KEY3_SCOPE_CTRL_ENABLE = 1'b0 → 按键失效，回到"上电就显示字幕"的老行为。
// ============================================================================
parameter KEY3_SCOPE_CTRL_ENABLE = 1'b1;   // 1=KEY3 能切字幕+波形  0=按键失效

// ① 消抖：拿到"按下的那一拍脉冲"
wire key3_press;
key_press_debounce #(
    .CLK_FREQ_HZ (100_000_000),     // 顶层主时钟 100MHz
    .DEBOUNCE_MS (20)
) u_key3_debounce (
    .clk               (clk),
    .rst               (~rst_n),    // 该模块要"高有效"复位，这里翻一下
    .button_in         (key3),      // 按下是 0（板上有上拉）
    .press_pulse       (key3_press),
    .button_stable_out ()           // 本功能不需要稳定电平，留空
);

// 【TD 用前必须声明】所有 reg 先集中声明，再写 always 块，否则 TD 报 not declared
reg key3_press_wide;                // 100MHz 域：展宽后的电平（那盏"一直亮着的灯"）
reg key3_w1, key3_w2;               // 25MHz 域：两级同步
reg key3_ack;                       // 25MHz 域：已处理，回去把灯熄灭
    reg overlay_on;                     // [新功能] 字幕+波形 总开关（1=显示 0=隐藏）

// ---- 100MHz 域：把单拍脉冲展宽成电平 ----
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)               key3_press_wide <= 1'b0;
    else if (key3_press)      key3_press_wide <= 1'b1;   // 按下 → 点亮
    else if (key3_ack)        key3_press_wide <= 1'b0;   // 对面收下了 → 熄灭
end

// ---- 25MHz 域：两级同步 + 检测上升沿 + 翻转开关 ----
always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n) begin
        key3_w1  <= 1'b0;
        key3_w2  <= 1'b0;
        key3_ack <= 1'b0;
        overlay_on <= 1'b0;             // 【本次改动】上电默认：关闭（字幕和波形都不显示）
    end else begin
        key3_w1  <= key3_press_wide;
        key3_w2  <= key3_w1;
        key3_ack <= key3_w2;
        // 检测"灯刚亮起"的那一拍 ⇒ 翻转一次
        if (KEY3_SCOPE_CTRL_ENABLE && key3_w2 && !key3_ack)
            overlay_on <= ~overlay_on;
    end
end

// ===================== ：HDMI音频桥接（媒体音调 + 正弦测试音） =====================
media_hdmi_audio_bridge #(
    .SAMPLE_DIV   (521),        // 25MHz / 48kHz ≈ 521
    .VOLUME_SHIFT (0)           // 音量：0=原始，1=减半
) u_media_hdmi_audio_bridge (
    .clk                  (video_clk),
    .rst                  (video_rst),
    .enable               (1'b1),
    .media_id             (media_id_sync),
    .source_sel           ((AUDIO_SRC_SEL == 2'd1) ? 2'd0 : 2'd1),   // 1=测试音，其余=媒体音调
    // 这里原来是 1'b0（空着的预留口），现在接上**片内旋律播放器**。
    //   AUDIO_SRC_SEL = 2'd3 时走旋律；其它档位 melody_active=0 会退回原来的音调。
    .wav_valid            (tune_valid),
    .wav_ready            (),
    .wav_left             (tune_left),
    .wav_right            (tune_right),
    .wav_active           (TUNE_ENABLE && (AUDIO_SRC_SEL == 2'd3)),
    .force_arpeggio       (TUNE_ENABLE && (AUDIO_SRC_SEL == 2'd3)),  // 选旋律时压住琶音
    .o_audio_valid        (new_audio_valid),
    .o_audio_left         (new_audio_left),
    .o_audio_right        (new_audio_right),
    .pcm_tap_valid        (pcm_tap_valid),
    .pcm_tap_left         (pcm_tap_left),
    .pcm_tap_right        (pcm_tap_right)
);

// 音频源二选一：0=方波链路（基础对照），其它=新链路
assign final_audio_valid = (AUDIO_SRC_SEL == 2'd0) ? audio_valid      : new_audio_valid;
assign final_audio_left  = (AUDIO_SRC_SEL == 2'd0) ? audio_left_data  : new_audio_left;
assign final_audio_right = (AUDIO_SRC_SEL == 2'd0) ? audio_right_data : new_audio_right;

// ============================================================================
// ===== 【第十课】转场特效：① 转场控制器（常规做法
// ============================================================================
// 它站在哪里：按键 → 【转场控制器】→ 换图，中间还夹着一次"读卡预加载"
//   转场控制器不干读卡、也不干换图的活，它**只负责推进画面明暗**：
//     收到"图备好了"→ 旧图淡出到全黑 → 淡入新图
//
// 【上一版为什么"一开转场就全黑"，这里留个记录（本次共查出 4 个真因）】
//   真因①【像素二选一吐纯黑】旧代码 top:654 写的是
//        `wipe_active_d ? (show_new_d ? faded_rgb : 24'd0) : faded_rgb`
//        —— 只要 wipe_active_d=1 且 show_new_d=0 就输出 24'd0 纯黑。
//        ⇒ 本次：整段 Wipe 代码**删掉不写**（不综合），另加"出图有效就不许全零"的兜底。
//   真因②【换图时机错位，黑屏长达 1.2~1.8 秒】
//        旧接线下按键**立刻**开始读卡（1.2~1.8 秒），而淡出只用 0.13 秒就黑了，
//        于是状态机在 S_HOLD 里干等读完卡 ⇒ 屏幕实打实地黑一两秒。
//        ⇒ 本次改成"**先读图、后淡出**"（预加载），黑屏缩到全黑那一两帧。
//   真因③【自锁】旧 buf_commit_pulse 带 `fade_active &&` 门控，
//        可我们又要用"它"来**启动**转场 —— 启动时 fade_active 还是 0，
//        事件被自己屏蔽 ⇒ 永远启动不了。⇒ 本次改成"锁存事实"（见下面）。
//   真因④【S_HOLD 永远等不到 commit ⇒ 永久全黑（最致命）】
//        状态机在 S_HOLD 里只等 index_commit。而"先读图、后淡出"的顺序下，
//        commit 脉冲在**淡出开始之前**就已经闪过去了（只有 1 拍），
//        等进到 S_HOLD 时它早没了 ⇒ 卡死在全黑。
//        ⇒ 本次把"新图已备好"**锁存**成 new_img_ready 电平，
//          S_HOLD 想问的时候答案早就摆在那儿（见下面"关键细节"那一大段）。
//
// ============================================================================
// ===== 【2026-10-01 关键修复之二】让转场"看得见" —— 换图请求要立刻触发，不能等读卡 =====
// ============================================================================
// 【上一版的问题】next_event_in 接的是 buf_commit_pulse（"图已经读好了"）。
//   而读卡要 1~2 秒 ⇒ 状态机是"等图读完了才开始淡出/花边"。
//   这 1~2 秒里画面一动不动，观众的感觉就是"卡住了"，然后"啪"一下换图
//   ⇒ **主观上就是硬切，转场那 0.3 秒根本来不及被注意到**。
//
// 【本次改成】按键一按下就**立刻**开始转场，让花边动画**在旧图上就开始跑**：
//     按键 → 立刻开始"剪纸花边擦除"（新图还没到，但花边先动起来）
//          → 后台同时读卡（这 1~2 秒里花边已经跑完了）
//          → 图读完、格子翻转 → 画面直接就是新图
//   ⇒ 用户看到：**按一下就有一道花边刷过去**，改为利落，这是最清楚的"有转场"。
//
// 【为什么可以这样】因为我们的花边**不需要新图就能跑**：
//   花边右边是黑、左边是"当前画面"。在旧图上跑花边，效果就是
//   "一道剪纸花边把旧图从左边擦掉、露出后面的黑"，然后读完了新图就上来了。
//   视觉上完全不违和，而且**绝不会黑屏卡住**（花边 16 帧必定跑完）。
//
// 【软回退】TRANSITION_ENABLE=1'b0 → 这一整套旁路，回到硬切。
// ============================================================================
// 按键一按下（消抖后的单拍脉冲）就触发转场。两个来源都接（KEY2 手按 / KEY4 的 2 秒长按兜底）。
//    用"或"不用"二选一"：物理上这两个永远不会同时按，谁先来都算。
//   （这个"或"直接写在下面 key_next_toggle 的 always 里，不再单独占一根线。）

//   next_event_in  ← key_next_req_ctrl  ："图备好了"事件 → 控制器开始淡出
//   next_event_out → fade_commit_req    ：本方案下不驱动换图，留作观察点
//   index_commit   ← buf_commit_in_fade ：**锁存后**的"图备好了"事实 → S_HOLD 放行
//    前两根接"脉冲"，第三根必须接"锁存电平"——原因是真因④。
reg  key_next_pulse_d;                   // 按键脉冲进 sd_card_clk 域打一拍（转场关掉时用）
wire key_next_req_ctrl;                  // 送给转场控制器的请求（见下面 assign）

always @(posedge sd_card_clk or posedge sdcard_rst) begin
    if (sdcard_rst) begin
        key_next_pulse_d <= 1'b0;
    end else begin
        key_next_pulse_d <= key_next_pulse;
    end
end

// 【2026-10-01 真凶】为什么花边死活看不见？—— 请求被"忙"挡掉了 
//   常规设计给的转场控制器里有这么一行（video_fade_transition.v:173）：
//       if (next_event_in && !busy_sync2)   // ← "转场忙时**丢弃**新请求"
//   而 busy_sync2 是 fade_running 打两拍，也就是"转场是不是正在跑"。
//
//   【问题】我把 next_event_in 接成了 wipe_trigger_d —— 一个**只有 1 拍（10ns）**的脉冲。
//     转场一旦在跑（上一次的花边还没结束），这 1 拍的请求**当场被丢掉**，
//     按键按了等于没按 ⇒ 表现就是"还是普通切换、什么都看不见"。
//
//   【正确做法】请求要写成**电平**（一直举着），而不是一闪而过的脉冲：
//     按键 → 把请求位**置 1 并保持** → 转场不忙时自己会把它用掉 → 转场一启动就把它清掉。
//     ⇒ 这样无论转场当时忙不忙，请求都不会丢，**按一下就一定有一次花边**。
//
//   【为什么用一个 toggle（翻转位）而不是电平】
//     教程控制器的判据是 `req_sync2 != req_seen`（"变过了就是新请求"），
//     所以它要的其实是一个**会翻转的位**，翻转一次 = 一次请求。
//     我们照它这个接口来：按键就翻一次，控制器自己记 seen。
// ============================================================================
reg  key_next_toggle;                    // 每按一次"下一张"，这个位翻一次

always @(posedge sd_card_clk or posedge sdcard_rst) begin
    if (sdcard_rst)
        key_next_toggle <= 1'b0;
    else if (key_next_pulse | key_long2_pulse)   // KEY2 短按 或 KEY4 的 2 秒长按
        key_next_toggle <= ~key_next_toggle;     // 翻一次 = 一次请求（**不会丢**）
end

// 送给转场控制器的请求：用"翻转位"（电平型），不再是 1 拍的脉冲。
//    这就是本次"花边终于能看见"的关键一行。
assign key_next_req_ctrl = TRANSITION_ENABLE ? key_next_toggle : key_next_pulse_d;


// ============================================================================
// ===== 【 关键细节】index_commit 不能用"一闪而过的脉冲"，要用"锁存好的事实" =====
// ============================================================================
// 常规的状态机在 S_IDLE 里是这么判的（video_fade_transition.v:113~126）：
//     if (req_sync2 != req_seen)      → S_OUT（淡出）
//     else if (index_commit && ...)   → S_IN （Wipe，wipe_mode=1）
//   —— 优先级：**请求 > index_commit**。
// 而 S_HOLD（全黑）里只等一件事：
//     if (index_commit)               → S_IN（淡入）
//
// 【问题一：两个端口接同一个事件，优先级会反转】
//   如果 next_event_in 和 index_commit 都接同一个 buf_commit_pulse：
//     · index_commit 来自像素域，**立刻**可见；
//     · 请求要绕 ctrl_clk 域的 toggle + 2 级同步器，**晚约 3 个像素时钟**。
//   ⇒ "index_commit 先到、请求后到"，S_IDLE 会走 else if 进 S_IN 且 wipe_mode=1，
//     而 wipe_mode=1 时 alpha_out 恒为 255 ⇒ 整段转场画面一直亮着，**淡出淡入全没了**。
//
// 【问题二（更严重）：本工程为"先读图、后淡出"，commit 发生于淡出之前】
//   时间线：按键 → 读卡 → 缓冲区翻（buf_commit_pulse 只有 1 拍）→ …… → 才开始淡出
//   ⇒ 等状态机淡到 S_HOLD（全黑）时，那个 1 拍的 buf_commit_pulse **早就过去了**。
//     如果直接把它接给 index_commit，S_HOLD 永远等不到 ⇒ **永久全黑**。
//     （这正是"转场一开就全黑"的第四个真因，本次静态分析抓出来的。）
//
// 【正确做法】把"新图已经备好"这个**事实锁存下来**，而不是用一个一闪而过的脉冲。
//   锁存位 new_img_ready：
//     · 缓冲区真的换了 → 置 1（置位后就一直保持）
//     · 转场彻底结束（回到 S_IDLE）→ 清 0，好让下一次换图能重新置位
//   ⇒ S_HOLD 想问"图好了没"时，答案**早就摆在那里**了，不会错过。
//   ⇒ 同时它天然满足问题一的修正方案：进 S_OUT 的那个瞬间它是 0（还没换图），
//     所以不会被 else if 抢走；只有真换了图它才变 1。
assign buf_commit_pulse = (disp_buf_idx != disp_buf_idx_q);  // "缓冲区在这一拍变了"
// （new_img_ready / disp_buf_idx_q 已在文件顶部声明）

always @(posedge video_clk or posedge osd_rst_n) begin
    if (!osd_rst_n) begin
        disp_buf_idx_q <= 2'd0;
        new_img_ready  <= 1'b0;
    end else begin
        disp_buf_idx_q <= disp_buf_idx;            // 多打一拍，防亚稳态

        if (buf_commit_pulse)
            new_img_ready <= 1'b1;                 // 图备好了，锁住
        else if (!fade_active)
            new_img_ready <= 1'b0;                 // 转场不在进行 ⇒ 允许为下一次重新置位
    end
end

// 送给 index_commit 的，就是这个"锁存好的事实"
wire buf_commit_in_fade = new_img_ready;

// ===== 【第十课】转场特效：② 像素混合（常规做法
// ============================================================================
// 位置：vout_data（出图）→ 【这里：Alpha乘法（+可选Wipe）】 → osd_overlay_24（贴字幕）→ HDMI
wire fade_frame_start = osd_vs_q && !vs;
// ============================================================================
// ===== 【剪纸花边·慢速计数器】把花边拉长，让它"看得见" =====
// ============================================================================
// 【为什么要有这一段】诊断结论：花边电路 100% 正确（用户实测：中央亮绿、
//   四角暗红、边缘带锯齿），可正常按键时看不见。原因是**时间被切碎了**：
//     状态机 S_OUT 先把画面压黑（0.27秒）→ S_HOLD 等读卡（1~2秒，全黑）
//       → 才进 S_IN 的 16 帧花边（0.27秒，而且是从黑里刚亮起来，对比度极低）
//   ⇒ 眼睛捕捉到的是"黑了很久，然后图换了"，花边那 0.27 秒根本没机会被看到。
//
// 【修法】不依赖状态机那 16 帧，顶层自己数帧，把花边拉长到 48 帧（≈0.8 秒），
//   而且**从按键那一刻就在旧图上开始跑**，不等读卡。
//   ⇒ 效果：一按键，旧图上立刻绽开一扇窗花，0.8 秒扫完，随后新图到位。
//
// 【安全】计数器数到 48 **一定**自己停，所以不可能半黑卡住；
//   常规设计状态机的"有界等待 / 防黑兜底"全都不受影响（这里只是另开一路显示效果）。
// ============================================================================
parameter integer PAPERCUT_FRAMES = 48;   // 花边持续多少帧（48 帧 ≈ 0.8 秒）

// 【像素域的按键触发】按键脉冲在 sd_card_clk(100MHz) 域，花边计数器在 video_clk(25MHz) 域。

// 【2026-10-01 触发链的关键修复】
//   【上一版的错】我把 pc_trig_lat 做成"按键来了就置 1 且**永不清零**"的电平，
//     然后在像素域去抓它的上升沿 —— 结果**第一次按键之后就再也不会触发**：
//     电平永远停在 1，根本没有第二次上升沿。而且上电时如果它已经是 1，
//     第一次按也抓不到沿 ⇒ 表现就是"完全没反应"。
//
//   【正确做法】用**翻转位（toggle）**做跨时钟域传递，和常规设计转场控制器是同一套路：
//     · 100MHz 域：每按一次，toggle 翻一次
//     · 25MHz 域：两级同步后，检测"和上一次看到的不一样" ⇒ 就是"按了一次"
//   ⇒ 无论按多少次、什么节奏，每一次都能被准确识别，永不丢失、永不卡死。
reg         pc_trig_tgl;                 // sd_card_clk 域：按一次翻一次
reg  [2:0]  pc_trig_sync;                // video_clk 域：两级同步 + 一位"上次看到的"
wire        wipe_trigger_pix = (pc_trig_sync[2] ^ pc_trig_sync[1]);  // 变了 = 按了一下

always @(posedge sd_card_clk or posedge sdcard_rst) begin
    if (sdcard_rst)
        pc_trig_tgl <= 1'b0;
    else if (key_next_pulse | key_long2_pulse)
        pc_trig_tgl <= ~pc_trig_tgl;      // 每按一次翻一次（**不是**置1不清）
end

always @(posedge video_clk or posedge video_rst) begin
    if (video_rst)
        pc_trig_sync <= 3'b000;
    else
        pc_trig_sync <= {pc_trig_sync[1:0], pc_trig_tgl};
end

reg  [5:0]  pc_cnt;        // 花边帧计数 0~PAPERCUT_FRAMES
reg         pc_active;     // 花边进行中

always @(posedge video_clk or posedge video_rst) begin
    if (video_rst) begin
        pc_cnt    <= 6'd0;
        pc_active <= 1'b0;
    end else begin
        // 按键一按下 → 花边立刻从 0 开始（在旧图上跑）
        if (wipe_trigger_pix && display_valid) begin
            pc_active <= 1'b1;
            pc_cnt    <= 6'd0;
        end
        // 每到一个帧边界才 +1（一帧内窗口大小不变 ⇒ 绝不撕裂）
        else if (pc_active && fade_frame_start) begin
            if (pc_cnt >= (PAPERCUT_FRAMES - 1))
                pc_active <= 1'b0;        // 扫完，收工（**必然到达**，不会卡住）
            else
                pc_cnt <= pc_cnt + 6'd1;
        end
    end
end

// 把 0~47 映射成 0~15（= 状态机那 16 档），这样 papercut_wipe 里的公式一个字不用改。
//    不能用简单的 >>2（那只能到 11，窗口永远开不满 ⇒ 最后一帧四角还是黑的，
//     然后 pc_active 一停画面"啪"地跳回来 = 可见的闪跳）。
//    用"乘以 11 再右移 5 位"（= ×11÷32）：
//       pc_cnt=0  → 0
//       pc_cnt=45 → 495>>5 = 15  ← 这时窗口就开满了
//       pc_cnt=47 → 517>>5 > 15  → 夹到 15
//     ⇒ 最后 3 帧窗口是**全开**的，然后 pc_active 归零、无缝回到正常画面。
//      乘 11 是**常数乘法**，综合出来就是两个移位加法，没有乘法器、没有除法器。
wire [9:0] pc_mul  = {4'd0, pc_cnt} * 6'd11;                 // 0 ~ 517
wire [4:0] pc_ramp = (pc_mul >= 10'd480) ? 5'd15             // ≥480 就是满档（窗口全开）
                                         : pc_mul[9:5];      // 否则 = pc_mul / 32

// 给花边模块的 enable / ramp（诊断开关优先；正常时用顶层这套慢速的）
wire        pc_active_use     = TRANSITION_ENABLE && (TRANSITION_KIND != 2'd0) && pc_active;
wire        wipe_active_final = WIPE_DEBUG_FORCE ? 1'b1 : pc_active_use;
wire [4:0]  wipe_ramp_final   = WIPE_DEBUG_FORCE ? WIPE_DEBUG_RAMP : pc_ramp;


video_fade_transition #(
    .FADE_FRAMES(TRANSITION_ENABLE ? FADE_FRAMES : 0)   // 开关置0 → 整体旁路
) u_fade_transition (
    // 控制域（sd_card_clk 100MHz）
    .ctrl_clk       (sd_card_clk),
    .ctrl_rst_n     (sdcard_rst_n),      // 本工程统一用同步后的低有效复位
    .next_event_in  (key_next_req_ctrl), // 【】"图备好了"事件 → 开始淡出
    .next_event_out (fade_commit_req),   // 【】本方案下不驱动换图（换图已提前做完），留作观察点
    .fade_busy      (fade_busy),         // 转场忙标志（本工程主链路不消费，留作观察点）
    // 像素域（video_clk 25MHz）
    .pix_clk        (video_clk),
    .pix_rst_n      (osd_rst_n),
    .player_active  (display_valid),     // 首图出来之前不搞转场（黑屏上没得转）
    .frame_start    (fade_frame_start),
    .index_commit   (buf_commit_in_fade), // 【】"新图已备好"这个**锁存好的事实**
                                         //   （= new_img_ready，产生代码见上面那段）
                                         //   作用：把状态机从 S_HOLD 推进到 S_IN（开始淡入）。
                                         //    它**必须接锁存量，不能接一闪而过的脉冲**——
                                         //   因为本工程是"先读图、后淡出"，等状态机进 S_HOLD 时，
                                         //   那个 1 拍的 commit 脉冲早就过去了，S_HOLD 会永远等不到。
                                         //   （这一条就是"转场一开就全黑"的真因之一，见上面长注释。）
                                         //   它**不是**唯一出口——S_IN 靠 frame_start 自走，
                                         //   走满 FADE_FRAMES 帧必然回 S_IDLE。
    .active_index   (osd_index),         // 当前图片编号 0~3，兼作 Wipe 类型标签
    .alpha_out      (fade_alpha),
    .fade_active    (fade_active),
    .wipe_active    (wipe_active),
    .ramp_out       (wipe_ramp),
    .transition_kind(transition_kind)
);

// ============================================================================
// ===== 【第十课】转场特效：② 像素混合（常规做法
// ============================================================================
// 位置：vout_data（出图）→ 【这里：Alpha乘法（+可选Wipe）】 → osd_overlay_24（贴字幕）→ HDMI
// 为什么插在 OSD **前面**：常规设计流程图 g2 就是"reader输出 → alpha乘法 → Wipe选择 → OSD叠加 → HDMI"。
//   好处：字幕是最后贴上去的，淡出变黑的时候字幕**不会被一起调暗**，
//         观众从头到尾都能看清"现在是第几张图"。
//
// 【转场关闭时】下面的 g_transition_off 分支里只有一行 assign，
//   像素 = vout_data 严格逐字透传，**一行混合逻辑都不综合**。
//
// 【Alpha乘法】最终色 = 图片色 × alpha / 256
//   为什么除 256 不除 255：除以 256 就是"右移8位"，一行代码完成，不需要除法器。
//   alpha=255 时 255/256≈0.996，人眼完全看不出差别。
//   先乘(8bit×8bit=16bit)再取高8位，所以平时整屏永远是满亮度，只有转场时才变暗。
//
// 【关于常规做法里的 Wipe（拉幕布揭示）—— 本版已实现，而且做成"剪纸窗花"的样子】
//   常规做法
//       wire [9:0] wipe_boundary = ramp_out * (640 / FADE_FRAMES);
//       wire show_new_frame = wipe_active && (pixel_x < wipe_boundary);
//       assign final_rgb = wipe_active ? (show_new_frame ? new:old) : fade_rgb_after_alpha;
//   常规做法。
//
//    本工程的做法（为了"剪纸"主题）：
//     1) 铁定照常规设计走：边界 = ramp × (640/FADE_FRAMES)，pixel_x < 边界 ? 新 : 旧。
//     2) 但把"一条直边"改成**剪纸的波浪花边**：
//        在直边基础上叠一个**固定的小三角波**（每 32 像素上下起伏 16 像素），
//        于是分界线变成一条**锯齿花边**，像剪刀剪出来的纸边 —— 这就是"剪纸转场"。
//     3) "旧图"怎么拿到（常规做法
//        我们的双缓冲是"两块格子轮着用"（BUF0/BUF1）。换图的瞬间格子指针就翻了，
//        所以**不能再去读旧格**（正在被新图覆盖）。
//        ⇒ 改用**视觉上完全等价**的办法：**"旧图"= 全黑**。
//          也就是"花边左边露新图、右边还是黑（刚才淡出的黑）"。
//          看着类似：画面先淡淡变黑 → 一道**剪纸花边从左边剪开** → 新图从花边后露出来。
//        ⇒ 这个做法**永远不会全黑卡死**：因为花边是持续往右走的，
//          16 帧内必然扫完全屏，最终整屏都是新图。
//     4) 转场方向由 TRANSITION_KIND 选（常规做法
//          2'd0 = 淡入淡出（默认，现在的效果不变）
//          2'd1 = 剪纸花边从左到右
//          2'd2 = 剪纸花边从上到下
//          2'd3 = 剪纸花边从中心向外（"开窗"式，最有窗花味）
//
//    软回退：TRANSITION_KIND=2'd0 → 完全退回现在的淡入淡出，花边逻辑一行都不综合。
// ============================================================================
wire [23:0] transition_rgb;     // 转场处理后的像素（喂给 OSD）
reg  [23:0] faded_rgb;          // Alpha 乘法后的像素（转场开启时才综合；声明放这里，generate 里只放逻辑）
// ============================================================================
// ===== 亮度 / 对比度 参数控制（拨码开关 SW1~SW4）=====
// ============================================================================
// 【怎么用（这 4 个拨码开关）】按常规做法
//     SW1          = 0 → 调**亮度**   ／ 1 → 调**对比度**   （选"调哪个"）
//     SW2          = 0 → 细分  ／ 1 → 粗调                （选"调多快"）
//     SW3 和 SW4   = 两个开关的 4 种组合 = 4 个档位
//
//   档位表（brightness / contrast，128 = 正常）：
//     SW4 SW3 |  亮度(brightness)  |  对比度(contrast)
//     --------+---------------------+--------------------
//      0   0  |  128（正常）        |  128（正常）
//      0   1  |  160（亮一点）      |  160（分明一点）
//      1   0  |  192（更亮）        |  192（更分明）
//      1   1  |  224（最亮）        |  224（最强）
//    把 SW3/SW4 两个开关当"2 位二进制"用，就能表达 4 个档，
//     这样**不用按键、不用消抖、拨一下立刻生效**，演示时最直观。
//    想要"更多档"或"更细"，改下面那张 case 表就行，一行一档。
//
// 【为什么参数要"帧边界锁存"】（常规做法
//   如果参数在一帧中间变化：上半帧用旧值、下半帧用新值 ⇒ 屏幕上出现一条横向分界线。
//   所以在 frame_start（每帧起点）才把拨码值搬进像素域寄存器，一帧内保持不变。
// ============================================================================
wire [1:0] bc_sw = {sw4, sw3};      // 两个拨码合成 2 位档位选择

// 档位 → 参数值（组合逻辑，只是查表，不占多少资源）
reg [7:0] bc_bright_sel;
reg [7:0] bc_contr_sel;
always @* begin
    case (bc_sw)
        2'd0: begin bc_bright_sel = 8'd128; bc_contr_sel = 8'd128; end  // 正常
        2'd1: begin bc_bright_sel = 8'd160; bc_contr_sel = 8'd160; end  // 一档
        2'd2: begin bc_bright_sel = 8'd192; bc_contr_sel = 8'd192; end  // 二档
        2'd3: begin bc_bright_sel = 8'd224; bc_contr_sel = 8'd224; end  // 三档
    endcase
end

// 【帧边界锁存】每帧起点才更新，一帧内参数不变 ⇒ 不会出现横线
reg [7:0] bc_bright_q;
reg [7:0] bc_contr_q;
always @(posedge video_clk or posedge video_rst) begin
    if (video_rst) begin
        bc_bright_q <= 8'd128;      // 复位后 = 正常亮度
        bc_contr_q  <= 8'd128;      // 复位后 = 正常对比度
    end else if (fade_frame_start) begin
        bc_bright_q <= bc_bright_sel;
        bc_contr_q  <= bc_contr_sel;
    end
end

// 亮度/对比度模块的输出
wire [23:0] bc_rgb;
wire        bc_de;

// 【本模块插在像素链最前面】图片 → 调亮度/对比度 → 剪纸窗花转场 → OSD字幕 → HDMI
//   为什么放最前面：这样"调亮度"和"窗花转场"两个功能**互不干扰**，
//   而且调亮度时窗花照常工作。
brightness_contrast_adjust u_bright_contrast (
    .clk        (video_clk),
    .rst_n      (osd_rst_n),
    .in_de      (de),                  // 输入数据有效
    .rgb_in     (vout_data),           // 原始图片像素
    .brightness (bc_bright_q),
    .contrast   (bc_contr_q),
    .out_de     (bc_de),
    .rgb_out    (bc_rgb)
);

//  下游统一吃"调过亮度/对比度"的像素。
//   注意：本模块打了一拍，所以整条链路晚一拍，但下游全都跟着晚一拍，看不出差别。
wire [23:0] reader_rgb = bc_rgb;      // 出图原始像素（改：先过亮度/对比度）

// ===== 【剪纸花边】几条纯组合的辅助线（转场关掉时不会被用到，不综合）=====
// 这些线现在归 papercut_wipe 模块用了，顶层这里不再自己算。
//   （模块里算得更清楚，也方便单独验证。）

// 剪纸擦除模块的输出
wire [23:0] wipe_rgb;      // 剪纸擦除后的像素
wire        wipe_show_new; // 1=这一像素露新图（观察点）

generate
if (!TRANSITION_ENABLE) begin : g_transition_off
    // ---- 旁路：像素完全走原路，等于没加过转场 ----
    assign transition_rgb = reader_rgb;
    assign wipe_rgb       = 24'd0;     // 不综合（下面没人用）
end else begin : g_transition_on
    // ---- 1) Alpha 乘法：三通道各乘一遍，取高8位 ----
    //    用 always 写成"寄存器"（原始设计写法，常规做法"像素域Alpha乘法代码"）。
    //     代价：像素晚一拍。这一拍**不需要**补回来 —— 因为我们下游（OSD、AXIS）整条链路
    //     跟着一起晚一拍，屏幕上等于"整幅画整体右移了一个像素的位置"，肉眼看不出来。
    //    faded_rgb 的声明放在 generate 外面（TD 对"在 generate 里声明寄存器"支持不稳），
    //     这里只放逻辑，不放声明。
    always @(posedge video_clk or posedge osd_rst_n) begin
        if (!osd_rst_n) begin
            faded_rgb <= 24'd0;
        end else begin
            faded_rgb[23:16] <= (reader_rgb[23:16] * fade_alpha) >> 8;
            faded_rgb[15:8]  <= (reader_rgb[15:8]  * fade_alpha) >> 8;
            faded_rgb[7:0]   <= (reader_rgb[7:0]   * fade_alpha) >> 8;
        end
    end

    // ---- 2) 【剪纸花边】把 Alpha 结果再交给"剪纸擦除"过一道 ----
    //   为什么放在 Alpha 后面：常规做法 的流水线就是
    //       final_rgb = wipe_active ? (show_new ? 新 : 旧) : fade_rgb_after_alpha
    //   ⇒ 花边的输入用 **faded_rgb**（已经乘过 alpha 的当前图），和常规设计一致。
    //   ⇒ TRANSITION_KIND=0（淡入淡出）时 wipe_active 恒为 0，
    //     模块内部 show_new 恒为 1 ⇒ wipe_rgb 恒等于 faded_rgb，**等于没加过**。
    papercut_wipe #(
        .H_ACTIVE    (640),
        .V_ACTIVE    (480),
        .TOOTH_W     (16),
        .TOOTH_H     (16),
        //  FADE_FRAMES 是**参数**，必须写在这里的 # 里面！
        //   （上次 KEY_KEY4_MODE 就是这么报错的：参数 = 出厂设置，写在订货单 # 上；
        //     端口 = 插座，写在接线单  上。写错单子 TD 就说不认识。）
        .FADE_FRAMES (FADE_FRAMES)   // 和状态机同一个帧数（保证"最后一帧"判得对）
    ) u_papercut_wipe (
        .pix_clk     (video_clk),
        .rst_n       (osd_rst_n),
        .wipe_active (wipe_active_final), // 诊断模式=恒1；正常=wipe_active_use
        .wipe_ramp   (wipe_ramp_final),   // 诊断模式=钉死在 8；正常=状态机的 ramp
        .mode        (TRANSITION_KIND),  // 0=淡入淡出 1=左到右 2=上到下 3=中心向外
        .pixel_x     (osd_pixel_x),      // 顶层重建的行内 X
        .pixel_y     (osd_pixel_y),      // 顶层重建的行号 Y
        // 【2026-10-01 真凶·最终版】不要再让"平时画面"经过 alpha 乘法！
        //   【现象】烧进去屏幕全黑（只有 OSD 字幕），按键能换图号。
        //   【真因】整条像素链是：  reader_rgb(原图) → ×fade_alpha/256 → faded_rgb → 花边 → 输出
        //     · fade_alpha 来自状态机；**只要它不是 255，画面就会变暗**；
        //     · 一旦状态机停在"全黑"那一档（S_HOLD，alpha=0）⇒ **整屏纯黑**。
        //   【为什么以前没暴露】旧代码里有一道"防黑兜底"：
        //       (display_valid && ~|wipe_rgb) ? reader_rgb : wipe_rgb
        //     它把"黑的像素"偷偷换成了原图 —— 所以画面一直是对的，
        //     但这道兜底同时也把**剪纸花边该黑的地方填平了**（这就是花边一直看不见的原因）。
        //     我把它删了之后，底下"alpha 可能是 0"这个真问题就露出来了。
        //   【正确做法】不转场的时候，**根本不要经过 alpha**，直接透传原图：
        //       · 没在转场  → transition_rgb = reader_rgb     （画面 100% 正常，与 alpha 无关）
        //       · 正在转场  → transition_rgb = wipe_rgb       （窗花效果）
        //     而且窗花内部喂的是 **reader_rgb（原图）**，不是 faded_rgb，
        //     所以窗花里露出来的永远是**清清楚楚的原图**，也不受 alpha 影响。
        //   ⇒ 这样既"平时绝不可能黑屏"，又"花边该黑的地方能黑" —— 两个要求同时满足。
        .new_rgb     (reader_rgb),       //  喂原图（不受 alpha 影响，窗花里露的是真图）
        .wipe_rgb    (wipe_rgb),
        .show_new    (wipe_show_new)
    );

    // ---- 3) 【安全网】出图有效时，绝不允许出**整屏**纯黑 ----
    //   【2026-10-01 真凶就在这一行】
    //   上一版写的是：
    //       assign transition_rgb = (display_valid && ~|wipe_rgb) ? reader_rgb : wipe_rgb;
    //   它的意思是"**只要这一像素是黑的**，就顶成原图"。
    //   可是剪纸花边是**逐像素**判的：花窗外面的像素按设计**就应该黑**！
    //   ⇒ 兜底一看"这个像素是黑的" → 立刻把原图填回去
    //   ⇒ **花边被整片填平，屏幕上什么都看不见**（这就是连着几轮"看不到效果"的真凶）
//
    //   例：我修了一道"防漏水"的保险，结果它把**故意挖的窗户**也当成漏水，给糊上了。
//
    //   【正确做法】兜底只在"**整屏都没有一个亮像素**"时才生效（那才是真黑屏），
    //   判断依据不能用"当前这个像素"，要用"这一帧出图到底有没有效"：
    //       display_valid=1（保鲜柜里有图、读出来是有效像素） → 老老实实听花边的
    //       display_valid=0（根本没图）                       → 输出黑，不要紧
    //   ⇒ 这样"故意挖的窗口"不会被填平，"真黑屏"的兜底也还在（靠 display_valid）。
//
    //    另外还有一层真黑屏保护在画面链路的最外层（不在这里）：
    //     OSD 的 pre_axis_rgb 二选一 + 状态机的有界等待 + 看门狗，三道都还在。
    //    下面这一行仍然是全模块对 transition_rgb 的**唯一驱动者**（防多驱动）。
    //  输出二选一：
    //     正在剪纸擦除 → 用花边输出（窗内原图、窗外黑）
    //     平时（绝大多数时间）→ **直接透传原图**，不经过 alpha，绝不可能黑屏
    assign transition_rgb = wipe_active_final ? wipe_rgb : reader_rgb;
end
endgenerate

// ============================================================================
// ===== 【第十课】"新图备好了"这个事实（new_img_ready / buf_commit_in_fade）=====
// ============================================================================
// 这两根信号的**产生代码在上面转场控制器那一段里**（见 " 关键细节" 注释），
// 这里只留一段说明，避免同一件事写两遍、改的时候漏掉一边。
//
// 一句话：常规做法里 index_commit 是"控制层告诉我图换好了"。
//   本工程没有控制层，所以从硬件事实里**看出来**：显示缓冲区指针变了 = 图换好了。
//   并且**把它锁存住**（不是一闪而过的脉冲），因为本工程是"先读图、后淡出"，
//   等淡到全黑（S_HOLD）时那个瞬间早就过去了 —— 锁存住才不会永久卡在全黑。
// ============================================================================


// ===================== ：OSD字幕叠加 =====================
// 【做法】照着常规做法/4.2节：在"出图"和"送HDMI"中间插一个贴标签的模块。
//   图 → vout_data → osd_overlay_24(u_osd_overlay) → pre_axis_rgb → HDMI
// 【汉字字幕升级】osd_overlay_24 里挂了"两条字幕路线"：
//   CN_TEXT_ENABLE=1 → 两行中文（每张图自己的标题）  =1 时用的是这条
//   CN_TEXT_ENABLE=0 → 原来的数字/字母小字幕
// ① 状态信号跨时钟域搬过来（sd_card_clk 100MHz → video_clk 25MHz）
//    字幕要显示"第几张图"和"看门狗错误码"，所以直接同步 state_code 本身（两级触发器防亚稳态）
reg  [3:0]  osd_state_meta;
reg  [3:0]  osd_state_sync;
reg         osd_auto_meta;
reg         osd_auto_sync;

always @(posedge video_clk or posedge video_rst) begin
    if (video_rst) begin
        osd_state_meta <= 4'd0;
        osd_state_sync <= 4'd0;
        osd_auto_meta  <= 1'b0;
        osd_auto_sync  <= 1'b0;
    end
    else begin
        osd_state_meta <= state_code;
        osd_state_sync <= osd_state_meta;
        osd_auto_meta  <= osd_auto_en_raw;
        osd_auto_sync  <= osd_auto_meta;
    end
end

// ② 把"数码管状态码"翻译成OSD要的东西
//    state_code = 1~4   → 图片编号 0~3（汉字字幕就是用这个决定"该显示哪两行字"）
//    state_code = A/E/F → 看门狗异常，错误码 = 8'h0A / 8'h0E / 8'h0F（只有数字/字母路线用）
//     osd_index 的声明已经搬到文件顶部（因为它在本段之前就被转场例化用到了）
assign osd_index = ((osd_state_sync >= 4'd1) && (osd_state_sync <= 4'd4))
                       ? (osd_state_sync[1:0] - 2'd1) : 2'd0;
wire [7:0] osd_error_code = ((osd_state_sync == 4'hA) ||
                             (osd_state_sync == 4'hE) ||
                             (osd_state_sync == 4'hF))
                            ? {4'h0, osd_state_sync} : 8'h00;

// ③ 像素行内X坐标重建
//    我们的 video_timing_data 只给 hs/vs/de，不给 pixel_x，
//    所以照 video_rgb_to_axis_640x480 的老办法：de 一高就+1，de 一低就归零
//   （声明已在文件顶部 224 行，这里只写产生逻辑）
always @(posedge video_clk or posedge video_rst) begin
    if (video_rst)
        osd_pixel_x <= 12'd0;
    else if (!de)
        osd_pixel_x <= 12'd0;
    else if (osd_pixel_x != 12'd639)
        osd_pixel_x <= osd_pixel_x + 12'd1;
end

// ③.5 【第十课】帧开始信号（转场也要用同一个）：
//   vs 打一拍，用"上一拍是1、这一拍是0"抓到 vs 下降沿 = 一帧的起点。
//   640×480 是负极性同步，VS 只在两行里拉低，所以这个沿每帧**只有一次**，很干净。
//    转场控制器的 ramp 只在 frame_start 时动，这就是"帧边界提交"，
//     一帧内 alpha/边界不变化 ⇒ 不会出现上半帧暗、下半帧亮的撕裂。
//    osd_vs_q 的声明已搬到文件顶部（帧起点信号在转场那一段就先用到它了）
always @(posedge video_clk or posedge video_rst) begin
    if (video_rst)
        osd_vs_q <= 1'b1;          // 复位时给1，避免上电误报一个假的帧开始
    else
        osd_vs_q <= vs;
end
wire osd_frame_start = osd_vs_q && !vs;

// ③.6 【第十课】像素行号重建（和 osd_pixel_x 完全对称：一行结束就 +1，帧开始清零）
//   为什么顶层要自己维护一份：顶层给出去的这一份和 osd_frame_start 是**同源**的，
//   osd_overlay_24 用 EXT_Y_ENABLE=1 收下它，两边的帧边界就严格同拍、不会差一帧。
//   （声明已在文件顶部 225 行，这里只写产生逻辑）
reg        osd_de_q;
always @(posedge video_clk or posedge video_rst) begin
    if (video_rst) begin
        osd_pixel_y <= 12'd0;
        osd_de_q    <= 1'b0;
    end else begin
        osd_de_q <= de;
        if (osd_frame_start)
            osd_pixel_y <= 12'd0;                  // 一帧的起点清零
        else if (osd_de_q && !de && (osd_pixel_y != 12'd479))
            osd_pixel_y <= osd_pixel_y + 12'd1;    // 一行有效像素结束 → 下一行
    end
end

// ④ 例化OSD叠加（常规做法
wire [23:0] osd_rgb_out;
wire        osd_de_out;
wire        osd_active;
//    osd_rst_n 的声明已搬到文件顶部（转场那一段就先用到它了）
assign osd_rst_n = RST_SYNC_EN ? video_rst_n : (~rst_all);  // 本工程统一复位是高有效，OSD模块按常规设计用低有效
                                                                  // 跟着像素域走，和 u_video_reset 同拍释放

osd_overlay_24 #(
    .OSD_X(8),              // 【数字/字母路线】字幕左上角X=8（真实像素 = 8×OSD_SCALE）
    .OSD_Y(8),              // 【数字/字母路线】字幕左上角Y=8（真实像素 = 8×OSD_SCALE）
    .OSD_SCALE(OSD_SCALE),  // 把坐标除以它 ⇒ 字幕整体放大
    .OSD_X_CN(OSD_X_CN),    // 【汉字路线】中文框左上角X（缩小后坐标）
    .OSD_Y_CN(OSD_Y_CN),    // 【汉字路线】中文框左上角Y（缩小后坐标）
    .CN_TEXT_ENABLE(CN_TEXT_ENABLE),  // 【汉字路线】1=两行中文 0=退回数字/字母
    // 【第十课·兼容增强】1=用顶层给的 pixel_y/frame_start（和转场同源，帧边界严格同拍）
    //   0 = 退回原始版本（模块自己数行）
    .EXT_Y_ENABLE(1'b1)
) u_osd_overlay (
    .clk          (video_clk),        // 像素时钟25MHz
    .rst_n        (osd_rst_n),        // 像素域复位
    .vsync        (vs),               // 场同步
    .de           (de),               // 数据使能
    .rgb_in       (transition_rgb),   // 【第十课】OSD之前的像素 = 转场处理后的像素
    .pixel_x      (osd_pixel_x[9:0]), // X坐标（顶层重建）
    .ext_pixel_y  (osd_pixel_y),      // 【第十课】Y坐标（顶层重建，与转场同源）
    .ext_frame_start(osd_frame_start),// 【第十课】帧开始（与转场同源）
    .active_index (osd_index),        // 当前图片编号0-3
    .cn_show      (overlay_on),       // [新功能] KEY3 字幕开关：1=显示 0=隐藏（上电默认关闭）
    .auto_enabled (osd_auto_sync),    // 自动轮播使能
    .error_code   (osd_error_code),   // 错误码（0=正常）
    .rgb_out      (osd_rgb_out),      // 叠加OSD后的RGB
    .de_out       (osd_de_out),
    .osd_active   (osd_active)
);

// ============================================================================
// ===== 【扩展项(5)】音频可视化：把正在播的声音画成波形柱（叠加在画面底部）=====
// ============================================================================
// 赛题原文：扩展要求(5)"尝试结合音频数据生成频谱或波形显示，叠加于视频画面，
//           增强交互展示效果。"
//   ⇒ 画面底部一条横带，32 个柱子跟着音乐跳动。
//   ⇒ 数据来源就用就留好的 **pcm_tap_***（音频探针），不新增任何音频逻辑。
//    答辩说明：我们做的是**时域波形幅度可视化**（不是频域 FFT）。
//     因为 FFT 需要蝶形运算、旋转因子表、大量乘法器，在 EG4S20 上资源不现实；
//     而幅度柱**零乘法器**就能做出"音乐动、画面动"的联动效果，性价比最高。
wire        scope_hit;
wire [23:0] scope_rgb;

audio_scope #(
    .WAVE_X       (64),     // 波形区左上角 X
    .WAVE_Y       (404),    // 波形区左上角 Y（底边 468，下方留点余量）
    .WAVE_WIDTH   (512),    // 波形区宽度
    .WAVE_HEIGHT  (64),     // 波形区高度（中心线在 436）
    .DECIMATE     (12),     // 每 12 个采样点取 1 个（默认值）
    .SCOPE_ENABLE (SCOPE_ENABLE)
) u_audio_scope (
    .clk          (video_clk),
    .rst_n        (video_rst_n),
    .frame_start  (osd_frame_start),    // 帧起始（顶层给的 vs 下降沿）
    .pixel_x      (osd_pixel_x),
    .pixel_y      (osd_pixel_y),
    .sample_valid (pcm_tap_valid),      // 音频样本节拍（留的探针）
    .sample_l     (pcm_tap_left),
    .sample_r     (pcm_tap_right),
    .scope_on     (overlay_on),         // 【本次改动】KEY3 统一开关：同时控制波形
    .hit          (scope_hit),
    .scope_rgb    (scope_rgb)
);

// ============================================================================
// ===== 【扩展项(4) 下半】把"当前参数值"显示在画面上（赛题原话：呈现参数变化信息）=====
// ============================================================================
// 赛题扩展要求(4) 原文："利用板载开关或按键调节显示参数（如亮度、对比度等），
//                       **并尝试在画面上呈现参数变化信息**。"
//   ⇒ 上一轮做到了"拨码能调亮度"，但画面上看不到数值。
//   ⇒ 这个模块补后半句：屏幕左下角一块小面板，实时显示
//         B 128   ← 亮度（Brightness）
//         C 128   ← 对比度（Contrast）
//         N 1     ← 曲目号（换图换曲的第几段）
//    用独立的 8×8 小字库（只有数字+B/C/N），和汉字字幕系统**互不干扰**，
//     随时可以用 SHOW_ENABLE=0 旁路掉，零风险。
//    它贴在 OSD 汉字字幕**之后**（最后一道），所以不会被字幕盖住。
wire        posd_hit;
wire [23:0] posd_rgb;

param_osd_show #(
    // 【本次改动】面板从右下角挪到**右上角**，避免挡住画面主体（剪纸图形）
//
    //   【坐标怎么算的】
    //     屏幕 640 × 480
    //     面板宽 = 4 个字符 × 每字符 8 像素 = 32 像素
    //     面板高 = 3 行 × 每行 8 像素     = 24 像素
    //     ⇒ X = 640 - 32 - 8（右边留 8 像素空隙） = 600
    //     ⇒ Y = 8（顶部留 8 像素空隙）
//
    //   【为什么右上角】
    //     剪纸图形的主体在画面中部偏下，右下角原来正好压着图案；
    //     挪到右上角后，既在视野内又不挡主要内容。
    //     （如果还想微调，只改这两个数即可，字模代码不用动）
    .PANEL_X     (570),
    .PANEL_Y     (8),
    .SHOW_ENABLE (PARAM_SHOW_ENABLE)
) u_param_osd_show (
    .clk         (video_clk),
    .pixel_x     (osd_pixel_x),
    .pixel_y     (osd_pixel_y),
    .brightness  (bc_bright_q),        // 当前亮度（帧边界锁存后的值）
    .contrast    (bc_contr_q),         // 当前对比度
    .tune_no     ({2'b00, media_id_sync[1:0]} + 4'd1),  // 曲目号 1~4（已不显示，保留端口）
    .page_no     (page_no_sync),        // 【新功能】页码 1~4（已同步到像素域）
    .period_s    (period_s_o),          // 【新功能】轮播周期（秒）
    .display_on  (display_valid),
    .hit         (posd_hit),
    .panel_rgb   (posd_rgb)
);

// ⑤ 总开关：OSD_ENABLE=0 时像素完全走原路，等于没加过OSD
//    【第十课】注意这里输入的是 transition_rgb 而不是 vout_data：
//      转场和OSD是两个独立开关（TRANSITION_ENABLE / OSD_ENABLE），互不影响。
//      OSD_ENABLE=0  → 字幕不贴，但转场照旧
//      TRANSITION_ENABLE=0 → 转场不生效，但字幕照旧
//    【扩展(4)】参数面板是**最后一道**：先出字幕，再叠参数面板。
wire [23:0] osd_mixed_rgb = OSD_ENABLE ? osd_rgb_out : transition_rgb;
// 叠加顺序（从下到上）：字幕 → 波形带 → 参数面板
//    顺序说明：波形带在画面底部（Y=440~480），参数面板在左中（Y=300~325），
//     两者**位置不重叠**，所以先后顺序其实不影响结果；这样写只是为了逻辑清楚。
wire [23:0] pre_axis_rgb  = posd_hit  ? posd_rgb  :
                            scope_hit ? scope_rgb :
                                        osd_mixed_rgb;

// ===================== RGB/DE 转 AXIS 视频 =====================
video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480(
    .I_clk         (video_clk),
    .I_rst         (video_rst),
    .I_vs          (vs),
    .I_de          (de),
    .I_rgb         (pre_axis_rgb),
    .O_video_user  (axis_s_user),
    .O_video_valid (axis_s_valid),
    .O_video_last  (axis_s_last),
    .O_video_data  (axis_s_data)
);

// 上电后自动打一拍，触发一次 EDID 读取
startup_pulse #(
    .CNT_MAX(20'd100000)
) u_startup_pulse (
    .I_clk   (video_clk),
    .I_rst   (video_rst),
    .O_pulse (edid_trig)
);

// ===================== 带音频的 HDMI 1.4b 发射 =====================
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                 ( "EG"       ),
    .HTOTAL                 ( 800        ),
    .HSA                    ( 96         ),
    .HFP                    ( 16         ),
    .HBP                    ( 48         ),
    .HACTIVE                ( 640        ),
    .VTOTAL                 ( 525        ),
    .VSA                    ( 2          ),
    .VFP                    ( 10         ),
    .VBP                    ( 33         ),
    .VACTIVE                ( 480        ),
    .VIDEO_VIC              ( 1          ),
    .VIDEO_TPG              ( "Disable"  ),
    .VIDEO_FORMAT           ( "RGB"      ),
    .AUDIO_SAMPLE_RATE      ( "48K"      ),
    .IIC_SCL_DIV            ( 250        )
) u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk        (video_clk),
    .I_rst              (video_rst),
    .I_edid_read_trig   (edid_trig),
    .O_edid_read_valid  (edid_valid),
    .O_edid_read_data   (edid_data),

    .I_axis_s_user      (axis_s_user),
    .I_axis_s_valid     (axis_s_valid),
    .I_axis_s_last      (axis_s_last),
    .I_axis_s_data      (axis_s_data),
    .O_axis_s_ready     (axis_s_ready),

    .I_audio_valid      (final_audio_valid),     // 音频源由 AUDIO_SRC_SEL 决定
    .I_audio_left_data  (final_audio_left),
    .I_audio_right_data (final_audio_right),
    .I_acr_valid        (acr_valid),
    .I_acr_cts          (acr_cts),
    .I_acr_n            (acr_n),

    .O_video_locked     (),
    .O_ddc_scl          (HDMI_DDC_SCL),
    .IO_ddc_sda         (HDMI_DDC_SDA),

    .O_ch0_tmds_data    (tmds_ch0_data),
    .O_ch1_tmds_data    (tmds_ch1_data),
    .O_ch2_tmds_data    (tmds_ch2_data),
    .O_clk_tmds_data    (tmds_clk_data)
);

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (video_rst),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

endmodule
