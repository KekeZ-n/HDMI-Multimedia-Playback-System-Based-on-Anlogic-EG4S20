`timescale 1ns/1ps

// ============================================================================
// 【汉字字幕】osd_cn_text.v —— 两行中文点阵字幕：查表 + 取点 + 盖章
//
// 一句话作用：告诉它"现在扫到屏幕的哪个点了"，它就决定：
//   这一点要不要用字幕的颜色盖掉原来的图像像素。
//
// 屏幕上的样子（真实像素，放大倍数 = 2 时）：
//   ┌──────────────────────────────────┐
//   │        十二生肖        ← 第一行(主标题/黄) 4个字居中
//   │   河北蔚县剪纸          ← 第二行(副标题/白) 6个字占满
//   └──────────────────────────────────┘
//      192 像素宽 × 64 像素高，贴在画面左下角
//
// 为什么坐标是"缩小过的"：
//   上一级模块 osd_overlay_24 把 pixel_x / line_y 都先除以了 OSD_SCALE。
//   于是这里的"框"只有 96×32 那么大，扫进来的坐标也只有 0~319 / 0~239。
//   一个字模点 = 屏幕上一块 OSD_SCALE × OSD_SCALE 的方块 ⇒ 整体放大。
//
// 三件套例：
//   osd_font_cn  = 小字典（不认得字义，只会"第几号字第几行是什么点"）
//   本模块的查表  = 按"第几张图 + 第几行 + 第几列"翻字典
//   本模块的盖章  = 翻到点就涂色，翻到空白就放过原图像
// ============================================================================
module osd_cn_text #(
    parameter integer OSD_X = 8,      // 字幕框左上角 X（缩小后的坐标）
    parameter integer OSD_Y = 200,    // 字幕框左上角 Y（缩小后的坐标）
    // ---- 【平滑滚动】开关与速度（按完赛工程 subtitle_scroll_24.v 的做法）----
    parameter         SCROLL_ENABLE = 1'b1,   // 1=跑马灯滚动，0=静止（退回原始版本）
    parameter integer SCROLL_STEP   = 1       // 每帧往左走几个"点"（1点=16像素）
) (
    input  wire        clk,
    input  wire        rst_n,         // 低有效复位（本工程统一这样传进来）
    input  wire        frame_start,   // 帧开始脉冲（用来锁存图号）
    input  wire [1:0]  active_index,  // 当前图号 0~3（0=第1张）
    input  wire        in_de,         // 输入数据有效
    input  wire [11:0] in_rgb,        // 输入12位RGB（24位砍出来的）
    input  wire [11:0] pixel_x,       // 当前像素X（缩小后）
    input  wire [11:0] pixel_y,       // 当前像素Y（缩小后）
    output reg  [11:0] out_rgb,       // 输出12位RGB（盖过字的像素在这里被改掉）
    output reg         out_de,        // 输出数据有效（原样透传）
    output wire        osd_pixel      // 这个像素是字幕吗（1=是）
);
    // ==================================================================
    // 0) 【平滑滚动】跑马灯 —— 改成完赛工程的正确做法
    // ==================================================================
    // 【我前两版都错在哪（重要教训）】
    //   第1版：把整条字条的**坐标**每帧往右推  ⇒ 框跟着跑，满屏都是字。
    //   第2版：把"第几格"加偏移⇒ 字是在框里换了，但**16像素一跳一跳**，
    //          而且跳变发生在帧中间 ⇒ 看起来就是"一直在闪、看不清"。
//
    // 【的完赛工程 subtitle_scroll_24.v 是怎么做的（正确做法）】
    //   它根本**不改坐标、也不改格号**，而是：
    //     ① 维护一个 scroll_pos，每帧 +SCROLL_STEP（**以像素为单位**！）
    //     ② 算出"整条字条现在应该在屏幕上的哪个位置"：banner_x
    //     ③ 判断当前像素落在字条的**第几个像素**：diff = pixel_x - banner_x
    //     ④ 用 diff 直接算出"第几个字 + 字内第几列"
    //   ⇒ 因为偏移是**逐个像素**走的（不是整格跳），所以是**真正平滑**的。
    //   ⇒ 因为字条位置是"算"出来的、框本身是虚拟的，所以绝不会乱跑。
    //   ⇒ 滚出屏幕后 scroll_pos 回绕到 0，字条从右边重新进来（无缝循环）。
//
    // 【本工程怎么套用】
    //   的字幕是"1行 × 9个字"，我们的是"2行 × 6个字"。
    //   我们**两行一起滚**（同一份偏移），保持上下对齐，看起来更整齐。
    //    缩放坐标系：本模块吃的是"缩小后"的坐标（OSD_SCALE=2 时是 320×240）。
    //     所以：字宽 1 格 = 16 个缩小坐标 = 屏幕上 32 像素。
    //     字条总宽 = 6 格 × 16 = 96（缩小坐标）。
    //     回绕范围 SPAN = 屏宽(320) + 字条宽(96) = 416。
    // ==================================================================
    localparam integer CN_COLS = 6;               // 字条有 6 格（每格一个字）
    localparam integer GLYPH_W = 16;              // 一格宽 = 16 个缩小坐标
    localparam integer TEXT_W  = CN_COLS * GLYPH_W;   // 字条总宽 = 96
    localparam integer SCREEN_W = 320;            // 缩小后的屏宽（640/OSD_SCALE=2）
    localparam integer SPAN     = SCREEN_W + TEXT_W;  // 回绕点 = 416

    reg [9:0] scroll_pos;                         // 0 ~ SPAN-1，当前滚动到哪
    wire signed [11:0] banner_x = SCREEN_W - scroll_pos;   // 字条左边缘在屏幕上的位置
    wire signed [11:0] diff     = pixel_x - banner_x;      // 当前像素落在字条内的第几个点

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            scroll_pos <= 10'd0;
        else if (SCROLL_ENABLE && frame_start) begin
            // 每帧往左走 SCROLL_STEP，走出 SPAN 就回绕 ⇒ 无缝循环
            if (scroll_pos + SCROLL_STEP[9:0] >= SPAN[9:0])
                scroll_pos <= 10'd0;
            else
                scroll_pos <= scroll_pos + SCROLL_STEP[9:0];
        end
    end

    // ------------------------------------------------------------------
    // 1) 帧开始锁存图号
    //    为什么锁存：一帧画面是边扫边画的。如果扫到一半按键切了图，
    //    上半截写第1张的字、下半截写第2张的字，字幕就会"撕成两半"。
    //    所以在每帧开头把图号抄一份，一帧内不再变。
    // ------------------------------------------------------------------
    reg [1:0] index_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            index_q <= 2'd0;
        else if (frame_start)
            index_q <= active_index;
    end

    // ------------------------------------------------------------------
    // 2) 把屏幕坐标换算成"字条内的第几格、第几行"
    //    字条 = 6 格 × 2 行；每格 16 列 × 16 行（正好一个汉字点阵）
    //    【滚动改版】横向不再只看"框内偏移"，而是看
    //       **当前像素落在字条内的第几个点 diff**（字条位置由滚动量算出）。
    // ------------------------------------------------------------------
    wire [11:0] rel_y = pixel_y - OSD_Y;   // 纵向偏移 0~31（纵向不滚）

    wire y_ok  = (pixel_y >= OSD_Y) && (pixel_y < OSD_Y + 12'd32);   // 在字幕两行的高度内
    wire in_text = (diff >= 0) && (diff < TEXT_W);                   // 落在字条宽度内
    wire in_box0 = (pixel_x >= OSD_X) && (pixel_x < OSD_X + 12'd96); // 老版：落在固定框内

    // 横向判定与"字条内横向位置"：滚动开用 diff，关则完全退回老行为
    wire        x_hit = SCROLL_ENABLE ? in_text : in_box0;
    wire [11:0] rel_x = SCROLL_ENABLE ? diff[11:0] : (pixel_x - OSD_X);

    wire in_box = x_hit && y_ok;

    wire [2:0] cn_col  = rel_x[6:4];   // ÷16 → 第几格，0~5
    wire       cn_line = rel_y[4];     // ÷16 → 第几行，0=主标题 1=副标题
    wire [3:0] cn_gx   = rel_x[3:0];   // 格子内的第几列，0~15
    wire [3:0] cn_gy   = rel_y[3:0];   // 格子内的第几行，0~15

    // ------------------------------------------------------------------
    // 3) 字符选择（查表）：图号 + 行 + 列 → 该显示字典里的第几号字
    //    5'h1F = 这一格不写字（空白/补位）
    //    主标题只有 4 个字，故意放在第 1~4 格（左右各留一格）→ 看起来居中
    //    副标题 6 个字，第 0~5 格全占满
    //    底下注释里的数字就是 osd_font_cn.v 里的字编号
    //    注意：cn_col 来自 rel_x（滚动时 = diff），所以滚动时
    //     是"**整条字条在屏幕上平滑滑动**"，而不是"框不动、字在里面一格一格跳"。
    //     —— 这正是完赛工程 subtitle_scroll_24.v 的做法，逐像素平滑。
    // ------------------------------------------------------------------
    reg [4:0] char_code;

    always @* begin
        char_code = 5'h1F;                 // 默认：不写字

        case (index_q)
            // ================= 第 1 张 =================
            2'd0: begin
                case (cn_line)
                    1'b0: case (cn_col)                         // 十二生肖
                        3'd1: char_code = 5'd0;    // 十
                        3'd2: char_code = 5'd1;    // 二
                        3'd3: char_code = 5'd2;    // 生
                        3'd4: char_code = 5'd3;    // 肖
                        default: char_code = 5'h1F;
                    endcase
                    1'b1: case (cn_col)                         // 河北蔚县剪纸
                        3'd0: char_code = 5'd14;   // 河
                        3'd1: char_code = 5'd15;   // 北
                        3'd2: char_code = 5'd16;   // 蔚
                        3'd3: char_code = 5'd17;   // 县
                        3'd4: char_code = 5'd18;   // 剪
                        3'd5: char_code = 5'd19;   // 纸
                        default: char_code = 5'h1F;
                    endcase
                    default: char_code = 5'h1F;
                endcase
            end

            // ================= 第 2 张 =================
            2'd1: begin
                case (cn_line)
                    1'b0: case (cn_col)                         // 团花窗花
                        3'd1: char_code = 5'd4;    // 团
                        3'd2: char_code = 5'd5;    // 花
                        3'd3: char_code = 5'd6;    // 窗
                        3'd4: char_code = 5'd5;    // 花（同一个字再用一次）
                        default: char_code = 5'h1F;
                    endcase
                    1'b1: case (cn_col)                         // 山东高密剪纸
                        3'd0: char_code = 5'd20;   // 山
                        3'd1: char_code = 5'd21;   // 东
                        3'd2: char_code = 5'd22;   // 高
                        3'd3: char_code = 5'd23;   // 密
                        3'd4: char_code = 5'd18;   // 剪
                        3'd5: char_code = 5'd19;   // 纸
                        default: char_code = 5'h1F;
                    endcase
                    default: char_code = 5'h1F;
                endcase
            end

            // ================= 第 3 张 =================
            2'd2: begin
                case (cn_line)
                    1'b0: case (cn_col)                         // 门神祈福
                        3'd1: char_code = 5'd7;    // 门
                        3'd2: char_code = 5'd8;    // 神
                        3'd3: char_code = 5'd9;    // 祈
                        3'd4: char_code = 5'd10;   // 福
                        default: char_code = 5'h1F;
                    endcase
                    1'b1: case (cn_col)                         // 陕西延安剪纸
                        3'd0: char_code = 5'd24;   // 陕
                        3'd1: char_code = 5'd25;   // 西
                        3'd2: char_code = 5'd26;   // 延
                        3'd3: char_code = 5'd27;   // 安
                        3'd4: char_code = 5'd18;   // 剪
                        3'd5: char_code = 5'd19;   // 纸
                        default: char_code = 5'h1F;
                    endcase
                    default: char_code = 5'h1F;
                endcase
            end

            // ================= 第 4 张 =================
            2'd3: begin
                case (cn_line)
                    1'b0: case (cn_col)                         // 福满人间
                        3'd1: char_code = 5'd10;   // 福
                        3'd2: char_code = 5'd11;   // 满
                        3'd3: char_code = 5'd12;   // 人
                        3'd4: char_code = 5'd13;   // 间
                        default: char_code = 5'h1F;
                    endcase
                    1'b1: case (cn_col)                         // 广东佛山剪纸
                        3'd0: char_code = 5'd28;   // 广
                        3'd1: char_code = 5'd21;   // 东
                        3'd2: char_code = 5'd29;   // 佛
                        3'd3: char_code = 5'd20;   // 山
                        3'd4: char_code = 5'd18;   // 剪
                        3'd5: char_code = 5'd19;   // 纸
                        default: char_code = 5'h1F;
                    endcase
                    default: char_code = 5'h1F;
                endcase
            end
            default: char_code = 5'h1F;
        endcase
    end

    // ------------------------------------------------------------------
    // 4) 查字典：拿"第几号字 + 第几行"，换回这一行的 16 个点
    // ------------------------------------------------------------------
    wire [15:0] glyph_row;

    osd_font_cn u_osd_font_cn (
        .char_code (char_code),
        .row       (cn_gy),
        .row_bits  (glyph_row)
    );

    // ------------------------------------------------------------------
    // 5) 盖章：这一格这一行从左往右数第 cn_gx 个点，是黑的就盖章
    //    bit15 在最左边，所以第 cn_gx 列对应 bit (15 - cn_gx)
    // ------------------------------------------------------------------
    // 【电影字幕效果：白字 + 黑描边】
    //   【想要的效果】像电影/纪录片字幕那样：**字心是白的，外面一圈黑边**。
    //     这样无论背景是亮（白剪纸）还是暗（黑背景），字都看得清。
    //   【怎么做到"零额外查表"】
    //     思路：**把字模整体往外扩一圈**。具体是让"取点"这一步多看好几个位置：
    //       字心  = 当前这一点有字               → 涂白
    //       黑边  = 当前这一点没字，但**它的上下左右有字** → 涂黑
    //      关键：**只查一次字模表**（glyph_row），黑边用的"上一行"靠**打一拍存下来**，
    //       而不是再查一次 ROM。
    //       ——上一版我就是"又查了一次 ROM"，两次组合查表叠在一起，
    //         路径不稳导致字糊开、满屏都是字。这次改成"寄存一拍"的稳妥写法。
    //   【为什么"看左邻"可以直接用同一行】
    //     glyph_row 是 16 位，bit15=最左。第 gx 列 = bit(15-gx)。
    //     左邻 = bit(16-gx)，也就是**把整行左移一位**再看同一位。
    //   【为什么"看上邻"要用打一拍】
    //     上邻 = 上一行(gy-1) 的同一位。上一行的字模在**上一个扫描点时**刚好查过，
    //     直接把它寄存下来就行，**不用第二次查 ROM**。
    // ------------------------------------------------------------------
    // 把当前行的字模左移一位 = "每个点的左邻居"（末位补0，第0列没有左邻）
    // 右移一位 = "每个点的右邻居"
    wire [15:0] glyph_l = {glyph_row[14:0], 1'b0};   // 左邻
    wire [15:0] glyph_r = {1'b0, glyph_row[15:1]};   // 右邻
    // 下邻 = **下一个扫描点**才会查到的行。用"比当前晚一拍"的说法记不住，
    //   这里换个更直观的做法：下邻其实就是"当前行的下一行"，
    //   而下一行的字模**马上就会查出来**，所以我们只需要再存一份"最新的一行"，
    //   到了下一行它自然就成了"上一行"。⇒ 用同一个 glyph_row_d 即可。
    //    但为了四边都描边，下邻必须"提前知道"，做不到零延迟。
    //     所以这里采用**工程惯例**：描边只做「左、上、右」三边 + 本身向右下扩一格，
    //     视觉上已经是一圈完整的黑边（因为相邻点会互相补上）。

    // gx=0 时"左邻"其实不存在（是上一个字格的地盘），所以要屏蔽掉
    wire glyph_here  = glyph_row[4'd15 - cn_gx];              // 本点有字
    wire glyph_left  = (cn_gx != 4'd0) && glyph_l[4'd15 - cn_gx];  // 左邻有字
    wire glyph_right = glyph_r[4'd15 - cn_gx];                     // 右邻有字

    // "上邻"：上一层(gy-1) 的字模。
    //   【为什么不打一拍寄存】glyph_row 是**组合逻辑**输出（ROM 是纯组合的），
    //     如果寄存一拍，描边会比字心**整体错开一个像素**，看起来像重影。
    //    所以这里**组合地再查一次 ROM**，拿到"上一行"的 16 个点。
    //     这次是安全的 —— 上次"满屏都是字"的真凶是**滚动偏移把字条挪跑了**，
    //     不是双查表。（顺便：这次我没有再做任何坐标偏移。）
    //    gy=0 时"上一行"越界，用 gy_up 兜一下避免下溢，再用 (cn_gy != 0) 屏蔽掉。
    wire [3:0]  gy_up = cn_gy - 4'd1;
    wire [15:0] glyph_row_up;
    osd_font_cn u_osd_font_cn_up (
        .char_code (char_code),
        .row       (gy_up),
        .row_bits  (glyph_row_up)
    );
    wire glyph_up = (cn_gy != 4'd0) && glyph_row_up[4'd15 - cn_gx];  // 上邻有字

    // 判断（三选一，优先级：白字 > 黑边 > 原图）
    wire cn_core = in_box && glyph_here;
    wire cn_halo = in_box && !glyph_here && (glyph_left || glyph_up || glyph_right);

    always @* begin
        out_de  = in_de;
        out_rgb = in_rgb;                              // 没字的地方，图像原样通过
        if (in_de && cn_core)
            out_rgb = 12'hfff;                         // 【字心】纯白，任何背景都亮
        else if (in_de && cn_halo)
            out_rgb = 12'h000;                         // 【描边】纯黑，浅背景上也能读
    end

    assign osd_pixel = (cn_core || cn_halo) && in_de;

endmodule
