`timescale 1ns/1ps

// ============================================================================
// OSD字幕叠加 —— 24位RGB封装器
//
//
//
// 干两件事：
//   1) 自己数"当前是第几行"(line_y)：因为我们的视频时序模块不输出Y坐标，
//      就盯着 vsync 和 de 两个信号自己数（vsync 低电平清零，每行 de 结束 +1）
//   2) 把 24位彩色图 砍成 12位 交给字幕模块画字（省资源），
//      画完再把 12位 OSD 颜色"复制两份"还原成 24位贴回去
//
// 输出 rgb_out 是纯组合逻辑，不加流水线延迟，所以不会打乱视频时序。
//
// ---------------------------------------------------------------------------
// 【汉字字幕升级】这个文件现在挂着"两条字幕路线"，用一个开关二选一：
//   CN_TEXT_ENABLE = 1 → 走 osd_cn_text（两行中文，16×16点阵，框 96×32）
//   CN_TEXT_ENABLE = 0 → 走 status_osd_overlay（原来的数字/字母，框 32×8）
// 两条路都例化着、都在算，只是最后出图的时候二选一。
// 好处：status_osd_overlay.v 一个字都没改，随时可以回去对照。
// ---------------------------------------------------------------------------
module osd_overlay_24 #(
    parameter integer OSD_X = 8,           // 【数字/字母路线】OSD区域左上角X坐标
    parameter integer OSD_Y = 8,           // 【数字/字母路线】OSD区域左上角Y坐标
    parameter integer OSD_SCALE = 1,       // 【放大】坐标缩小倍数(=字幕放大倍数)，1=原始大小
    parameter integer OSD_X_CN = 8,        // 【汉字路线】中文框左上角X（缩小后的坐标）
    parameter integer OSD_Y_CN = 200,      // 【汉字路线】中文框左上角Y（缩小后的坐标）
    parameter         CN_TEXT_ENABLE = 1'b1, // 【汉字路线总开关】1=两行中文 0=退回原数字/字母
    // ========================================================================
    // 【第十课·兼容增强】放下面的"外部像素Y坐标"用不用——两个都是**纯加法**，
    //   默认值 = 原行为，一行老代码都不受影响。
    //   背景：本模块原来自己数 pixel_y(line_y)，方法是在 vsync 低电平清零、
    //        在每个 de 下降沿 +1。这个方法在 640×480 上确实是对的，
    //        但"数行"和"抓帧起始"是两套独立判据，遇到转场那种
    //        "一个 vs 周期里像素来源变了"的场景就有错一拍的风险。
    //   现在顶层把 osd_pixel_y / osd_frame_start 直接喂进来（和转场用的是**同一个**判据），
    //   ⇒ 字幕和转场的帧边界严格同拍，不会互相差一帧。
    //   EXT_Y_ENABLE = 1'b0 → 完全退回原来"自己数行"的做法。
    parameter         EXT_Y_ENABLE = 1'b0,
    // ========================================================================
    // 【扩展项(1) 补全】平滑滚动字幕开关（透传给 osd_cn_text）
    //   赛题扩展要求(1) 原文："叠加动态文字…探索多图层混合与**平滑滚动**效果"
    //   ⇒ SCROLL_ENABLE=1'b1 时，标题在**固定的框里**往左换字（跑马灯）。
    //    全部实现在 osd_cn_text 内部，本模块只负责把开关透传下去。
    //    SCROLL_ENABLE=1'b0 → 完全退回静止标题，与原版逐字一致。
    parameter         SCROLL_ENABLE = 1'b1,
    parameter integer SCROLL_STEP   = 1       // 每帧往左走几格（1 格 = 16 像素）
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vsync,       // 场同步（低有效）
    input  wire        de,          // 数据使能
    input  wire [23:0] rgb_in,      // 输入24位RGB
    input  wire [9:0]  pixel_x,     // 当前像素X坐标
    input  wire [1:0]  active_index,// 当前图片编号（0-3）
    input  wire        auto_enabled,// 自动轮播使能
    input  wire [7:0]  error_code,  // 错误码
    // 【第十课·兼容增强】外部直接给的Y坐标与帧起始（EXT_Y_ENABLE=1 时才用）
    input  wire [11:0] ext_pixel_y,     // 顶层给的当前像素Y坐标（0~479）
    input  wire        ext_frame_start, // 顶层给的帧开始（vs下降沿），和转场同一个
    // 【新功能】字幕运行时开关：1=显示字幕  0=隐藏（KEY3 控制，上电默认关闭）
    //    为什么不能直接用 CN_TEXT_ENABLE：那是**参数**，编译期定死，接不了运行时信号。
    //     所以参数管"走哪条路线"，这个端口管"显不显示"，两级开关。
    input  wire        cn_show,
    output wire [23:0] rgb_out,     // 输出24位RGB
    output wire        de_out,
    output wire        osd_active   // OSD像素标志
);
    // ---- Y坐标重建：从vsync/de信号恢复pixel_y ----
    reg [11:0] line_y;   // 当前行号
    reg de_q;            // de打一拍，用于检测下降沿
    reg vs_q;            // vsync打一拍，用于检测下降沿（帧开始）
    wire frame_start_int = vs_q && !vsync;  // vsync下降沿=帧开始

    // 【第十课·兼容增强】统一出口：EXT_Y_ENABLE=0 时完全等于原来的 frame_start / line_y
    wire        frame_start = EXT_Y_ENABLE ? ext_frame_start : frame_start_int;
    wire [11:0] pixel_y_use = EXT_Y_ENABLE ? ext_pixel_y     : line_y;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            line_y <= 12'd0;
            de_q <= 1'b0;
            vs_q <= 1'b1;
        end else begin
            de_q <= de;
            vs_q <= vsync;
            // vsync低电平时行计数器清零（场消隐期间）
            if (!vsync)
                line_y <= 12'd0;
            // de下降沿=一行有效像素结束，行号+1
            else if (de_q && !de)
                line_y <= line_y + 1'b1;
        end
    end

    // ---- 例化12位OSD核心（原来的"数字/字母"路线，CN_TEXT_ENABLE=0 时才出图）----
    wire [11:0] osd_rgb12;
    wire osd_hit;

    // 【转场修复 2026-09-30】帧起点锁存：整帧的字幕严格用**同一帧起点**的图片编号
    //   本工程 EXT_Y_ENABLE=1'b1（用顶层给的判据）和 0（模块自己数）用的是**同一个 vs 下降沿**，
    //   所以锁存的内容完全一样 ⇒ 这是**纯加法**，EXT_Y_ENABLE=0 时行为与原始版本逐字一致。
    //   那为什么要多这一级？
    //     顶层给过来的 active_index 是"当前显示第几张图"，它在换图那一瞬间会变。
    //     转场（淡入淡出）过程中，如果这个编号正好在某一帧的**中间**翻掉，
    //     这一帧就会"上半帧第一张图的字、下半帧第二张图的字" ⇒ 肉眼看到的就是一闪。
    //     锁存之后：整帧字幕用同一个编号 ⇒ 不可能出现半帧切换。
    //    它只影响"字幕取哪一张图的字库"，不碰像素数据通路，不可能造成黑屏。
    reg [1:0] osd_idx_lat;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            osd_idx_lat <= 2'd0;
        else if (frame_start)
            osd_idx_lat <= active_index;
    end

    status_osd_overlay #(
        .OSD_X(OSD_X),
        .OSD_Y(OSD_Y)
    ) u_osd (
        .clk(clk), .rst_n(rst_n),
        .frame_start(frame_start),
        .active_index(osd_idx_lat), .auto_enabled(auto_enabled),
        .error_code(error_code),
        .in_de(de),
        // 24位截断为12位：每通道取高4位
        .in_rgb({rgb_in[23:20], rgb_in[15:12], rgb_in[7:4]}),
        // 坐标除以放大倍数：字模一个点 = 屏幕上一块 N×N 方块
        //   （只改这两根连线，status_osd_overlay 内部一行都没动）
        .pixel_x({2'b00, pixel_x} / OSD_SCALE),
        .pixel_y(pixel_y_use / OSD_SCALE),
        .out_rgb(osd_rgb12),
        .out_de(),
        .osd_pixel(osd_hit)
    );

    // ---- 例化【汉字双行字幕】路线（新加，CN_TEXT_ENABLE=1 时出图）----
    //   汉字路线只要"当前是第几张图"这一样信息，A/E 和错误码它不用
    wire [11:0] cn_rgb12;
    wire        cn_hit;

    // ========================================================================
    // 【上板后回退：满屏都是字】
    //   【现象】屏幕上"到处都是字" —— 同一条字幕在画面里重复出现很多遍。
    //   【根因】我曾经加过一版"平滑滚动"：在把 pixel_x 喂给汉字模块之前
    //           加了一个每帧递增的偏移量，想让字条往左跑。
    //           结果：字条框的位置**也跟着一起挪**了，一帧里字条出现在一个
    //           新位置 ⇒ 屏幕上出现"到处是字"的残影。
    //   【决定】**整段删除**，不做滚动。
    //           理由：我们的字幕是"每张图一个固定标题"，本来就**不需要滚动**。
    //           赛题扩展(1) 说的是"淡入淡出、滑动切换、缩略图、多窗口**至少一种**"
    //           —— 我们的**剪纸开窗转场**已经完全满足这一条，不靠滚动字幕。
    //   【回退后】pixel_x 直接除缩放送进去，与原版**逐字一致**。
    // ========================================================================

    osd_cn_text #(
        .OSD_X         (OSD_X_CN),      // 中文框的左上角（缩小后坐标）
        .OSD_Y         (OSD_Y_CN),
        .SCROLL_ENABLE (SCROLL_ENABLE), // 【扩展(1)】跑马灯滚动（框不动、字在里面走）
        .SCROLL_STEP   (SCROLL_STEP)
    ) u_osd_cn_text (
        .clk          (clk),
        .rst_n        (rst_n),
        .frame_start  (frame_start),
        .active_index (osd_idx_lat),      // 【转场修复】用帧起点锁存后的编号，避免半帧换字
        .in_de        (de),
        .in_rgb       ({rgb_in[23:20], rgb_in[15:12], rgb_in[7:4]}),  // 同样砍成12位
        .pixel_x      ({2'b00, pixel_x} / OSD_SCALE),   // 【回退】直接除缩放，无任何偏移
        .pixel_y      (pixel_y_use / OSD_SCALE),
        .out_rgb      (cn_rgb12),
        .out_de       (),
        .osd_pixel    (cn_hit)
    );

    // ---- 两条路线二选一（开关就是 CN_TEXT_ENABLE）----
    // 【新功能】再叠加一层运行时开关 cn_show：
    //     CN_TEXT_ENABLE = 参数，决定"走汉字路线还是数字路线"（编译期定死）
    //     cn_show        = 端口，决定"到底显不显示字幕"（KEY3 运行时切换）
    //   ⇒ 汉字路线下：cn_show=0 时 cn_hit 拉低 ⇒ 画面原样透出，字幕完全消失
    wire [11:0] osd_rgb12_sel = CN_TEXT_ENABLE ? cn_rgb12 : osd_rgb12;
    wire        osd_hit_sel   = CN_TEXT_ENABLE ? (cn_hit && cn_show) : osd_hit;

    // ---- 12位OSD颜色扩展为24位 ----
    // 非OSD像素透传原始24位值；OSD像素把12位高亮色扩展为24位
    // 扩展方法：每个4位通道复制两份，如4'hF→8'hFF，4'h4→8'h44
    assign rgb_out = osd_hit_sel ?
        {osd_rgb12_sel[11:8], osd_rgb12_sel[11:8],   // R高4位复制
         osd_rgb12_sel[7:4],  osd_rgb12_sel[7:4],    // G高4位复制
         osd_rgb12_sel[3:0],  osd_rgb12_sel[3:0]}    // B高4位复制
        : rgb_in;
    assign de_out = de;
    assign osd_active = osd_hit_sel;
endmodule
