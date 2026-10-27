`timescale 1ns/1ps
// ============================================================================
// tune_rom_player.v —— 片内旋律播放器（换图换曲 = 音视频联动）
// ============================================================================
// 【这个模块干什么（说明）】
//   像小时候的**八音盒**：芯片里提前"刻"好了 4 段小旋律，
//   你看第几张剪纸，它就唱哪一段 —— **画面换、音乐跟着换**，这就是"音视频联动"。
//
// 【为什么用片内 ROM 而不是 TF 卡】（重要的工程取舍，答辩可以讲）
//   常规的做法是"从 TF 卡流式读 WAV"。但那要求把 SD 卡控制器提到顶层、
//   图片和音频**分时抢占**同一个卡接口，而我们工程的 `sd_card_bmp`（820行）
//   已经把卡控制器包在里面了。20 号前动它 ⇒ **有把图片链路改坏的风险**。
//   ⇒ 本工程改用**片内 ROM**：
//        · 图片链路**一个字节都不碰**（零风险）
//        · 音频自带、不依赖 TF 卡（演示时更可靠，不会因为卡的问题没声音）
//        · 代价：只能放短旋律，靠**循环**变成背景音乐
//   ⇒ 对"音视频联动"这个赛题要求来说，**完全够用**。
//
// 【怎么发出声音】
//   用"方波合成"：对每个音符，按它的频率翻转输出电平。
//   方波虽然音色简单（像老式电子琴），但**电路最省**：
//   只需要一个"数到半个周期就翻转"的计数器，**不需要乘法器、不需要查表**。
//   旋律 = 一张"音符时长表"（每个音符持续多少个采样周期）。
//
// 【换图换曲怎么实现】
//   img_idx（当前第几张图 0~3）→ 选第几段旋律 → 播放。
//   图片一变，旋律立刻跟着变。
//
// 【软回退】ENABLE=1'b0 时本模块输出全 0、valid 拉低，等于没加过。
// ============================================================================
module tune_rom_player #(
    parameter integer CLK_FREQ_HZ = 25_000_000,   // 像素时钟 25MHz（本模块跑在 video_clk）
    parameter integer SAMPLE_HZ   = 48_000,       // 音频采样率 48kHz（HDMI 标准）
    parameter         ENABLE      = 1'b1
)(
    input  wire        clk,          // 像素时钟（25MHz）
    input  wire        rst_n,        // 低有效复位
    input  wire [1:0]  img_idx,      // 当前图片编号 0~3（换它 = 换曲子）
    output reg         out_valid,    // 输出有效
    output reg  signed [15:0] out_left,   // 左声道
    output reg  signed [15:0] out_right   // 右声道
);
    // ------------------------------------------------------------------
    // 1) 采样节拍：把 25MHz 分成 48kHz
    //    25_000_000 / 48_000 = 520.83 ⇒ 每 521 个时钟出一个样本
    // ------------------------------------------------------------------
    localparam integer TICK_DIV = CLK_FREQ_HZ / SAMPLE_HZ;   // = 520
    reg [15:0] tick_cnt;
    wire       sample_tick = (tick_cnt >= (TICK_DIV - 1));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            tick_cnt <= 16'd0;
        else if (sample_tick)
            tick_cnt <= 16'd0;
        else
            tick_cnt <= tick_cnt + 16'd1;
    end

    // ------------------------------------------------------------------
    // 2) 音符频率表（半周期对应的时钟数）= CLK_FREQ / (2 × 音符频率)
    //    我们用简谱的中音区，方便排"剪纸风"的五声音阶旋律（宫商角徵羽）
    //     这些常数在综合时就是**固定值**，不占乘法器。
    // ------------------------------------------------------------------
    // 频率(Hz):  262(C4) 294(D4) 330(E4) 349(F4) 392(G4) 440(A4) 494(B4) 523(C5) 587(D5) 659(E5) 784(G5)
    // 半周期(拍) = 25_000_000 / (2 × f)
    function [15:0] half_period;
        input [3:0] note;          // 0=休止, 1..11 = 上面 11 个音
        begin
            case (note)
                4'd0:  half_period = 16'd0;        // 休止符（不出声）
                4'd1:  half_period = 16'd47710;    // C4  262Hz
                4'd2:  half_period = 16'd42517;    // D4  294Hz
                4'd3:  half_period = 16'd37879;    // E4  330Hz
                4'd4:  half_period = 16'd35817;    // F4  349Hz
                4'd5:  half_period = 16'd31888;    // G4  392Hz
                4'd6:  half_period = 16'd28409;    // A4  440Hz
                4'd7:  half_period = 16'd25304;    // B4  494Hz
                4'd8:  half_period = 16'd23901;    // C5  523Hz
                4'd9:  half_period = 16'd21297;    // D5  587Hz
                4'd10: half_period = 16'd18968;    // E5  659Hz
                4'd11: half_period = 16'd15944;    // G5  784Hz
                default: half_period = 16'd0;
            endcase
        end
    endfunction

    // ------------------------------------------------------------------
    // 3) 旋律表：4 段，每段 16 个音符（每音符 1/8 秒 = 6000 个样本）
    //     用五声音阶（宫商角徵羽）排，听起来有中国味道 / 剪纸味道。
    //     每段都是"能自循环的小句子"，循环播放不突兀。
    //    音符编号见上面 half_period 的注释。
    // ------------------------------------------------------------------
    reg [3:0] note;              // 当前音符

    // 用 case 直接按 (img_idx, step) 查音符，省掉一个 ROM，资源最省
    reg [3:0] step;              // 段内第几个音符 0~15

    // 【音符时长】每 6000 个样本换一个音符（48kHz 下 = 1/8 秒）
    localparam integer NOTE_SAMPLES = 6000;
    reg [15:0] note_cnt;
    wire       note_done = (note_cnt >= (NOTE_SAMPLES - 1));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            note_cnt <= 16'd0;
        else if (sample_tick) begin
            if (note_done)
                note_cnt <= 16'd0;
            else
                note_cnt <= note_cnt + 16'd1;
        end
    end

    // step 递增（换音符）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            step <= 4'd0;
        else if (sample_tick && note_done)
            step <= step + 4'd1;      // 会自动回绕 0~15
    end

    // 【4 段旋律】剪纸主题：模仿《高山流水》意境的五声音阶
    //    这里**刻意不用嵌套 case**（case 里面再套 case）：
    //     TD 对"嵌套结构"支持不稳（我们之前踩过"嵌套 generate"的坑），
    //     所以改成"先把 4 段各自查出来，再用一个 case 按 img_idx 二选一" ——
    //     **扁平两层、结构清楚、TD 一定认**。
    reg [3:0] n0, n1, n2, n3;    // 4 段旋律在当前 step 上的音符
    reg [3:0] note_sel;          // 按当前图号选出来的音符

    always @* begin
        // ---- 段1：♩ 上行抒情（宫-角-徵-羽-宫），第1张图 ----
        case (step)
            4'd0:  n0 = 4'd1;   4'd1:  n0 = 4'd3;
            4'd2:  n0 = 4'd5;   4'd3:  n0 = 4'd6;
            4'd4:  n0 = 4'd8;   4'd5:  n0 = 4'd6;
            4'd6:  n0 = 4'd5;   4'd7:  n0 = 4'd3;
            4'd8:  n0 = 4'd5;   4'd9:  n0 = 4'd8;
            4'd10: n0 = 4'd10;  4'd11: n0 = 4'd8;
            4'd12: n0 = 4'd6;   4'd13: n0 = 4'd5;
            4'd14: n0 = 4'd3;   default: n0 = 4'd1;
        endcase
        // ---- 段2：♩ 上下起伏（像剪刀来回），第2张图 ----
        case (step)
            4'd0:  n1 = 4'd8;   4'd1:  n1 = 4'd6;
            4'd2:  n1 = 4'd8;   4'd3:  n1 = 4'd9;
            4'd4:  n1 = 4'd11;  4'd5:  n1 = 4'd9;
            4'd6:  n1 = 4'd8;   4'd7:  n1 = 4'd6;
            4'd8:  n1 = 4'd5;   4'd9:  n1 = 4'd3;
            4'd10: n1 = 4'd5;   4'd11: n1 = 4'd6;
            4'd12: n1 = 4'd8;   4'd13: n1 = 4'd6;
            4'd14: n1 = 4'd5;   default: n1 = 4'd8;
        endcase
        // ---- 段3：♩ 低回婉转（门神祈福味），第3张图 ----
        case (step)
            4'd0:  n2 = 4'd6;   4'd1:  n2 = 4'd5;
            4'd2:  n2 = 4'd3;   4'd3:  n2 = 4'd5;
            4'd4:  n2 = 4'd6;   4'd5:  n2 = 4'd5;
            4'd6:  n2 = 4'd3;   4'd7:  n2 = 4'd1;
            4'd8:  n2 = 4'd3;   4'd9:  n2 = 4'd5;
            4'd10: n2 = 4'd6;   4'd11: n2 = 4'd8;
            4'd12: n2 = 4'd6;   4'd13: n2 = 4'd5;
            4'd14: n2 = 4'd3;   default: n2 = 4'd6;
        endcase
        // ---- 段4：♩ 欢快明亮（"福满人间"），第4张图 ----
        case (step)
            4'd0:  n3 = 4'd8;   4'd1:  n3 = 4'd5;
            4'd2:  n3 = 4'd8;   4'd3:  n3 = 4'd10;
            4'd4:  n3 = 4'd8;   4'd5:  n3 = 4'd10;
            4'd6:  n3 = 4'd11;  4'd7:  n3 = 4'd10;
            4'd8:  n3 = 4'd8;   4'd9:  n3 = 4'd6;
            4'd10: n3 = 4'd8;   4'd11: n3 = 4'd5;
            4'd12: n3 = 4'd6;   4'd13: n3 = 4'd8;
            4'd14: n3 = 4'd10;  default: n3 = 4'd5;
        endcase
    end

    // 按当前是第几张图，从 4 段里选一段（**扁平的第二层**）
    always @* begin
        case (img_idx)
            2'd0:    note_sel = n0;
            2'd1:    note_sel = n1;
            2'd2:    note_sel = n2;
            default: note_sel = n3;
        endcase
    end

    // 在音符切换的那一拍，把选中的音符锁进 note（供方波合成用）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            note <= 4'd0;
        else if (sample_tick && note_done)
            note <= note_sel;
    end

    // ------------------------------------------------------------------
    // 4) 方波合成：数到"半个周期"就翻转一次电平
    //     全加减法，**没有乘法器、没有存储器**。
    // ------------------------------------------------------------------
    reg [15:0] phase_cnt;
    reg        wave;             // 当前方波电平

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase_cnt <= 16'd0;
            wave      <= 1'b0;
        end else if (sample_tick) begin
            if (half_period(note) == 16'd0) begin
                phase_cnt <= 16'd0;
                wave      <= 1'b0;          // 休止符：不出声
            end else if (phase_cnt >= half_period(note) - 16'd1) begin
                phase_cnt <= 16'd0;
                wave      <= ~wave;         // 到半个周期了，翻转
            end else begin
                phase_cnt <= phase_cnt + 16'd1;
            end
        end
    end

    // ------------------------------------------------------------------
    // 5) 输出：方波 → 16 位 PCM
    //     音量刻意做小（±4000 / 32767），因为方波听感很"冲"，
    //      调小一点不炸耳、也不容易过曝，配合画面讲解刚好。
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            out_left  <= 16'sd0;
            out_right <= 16'sd0;
        end else begin
            out_valid <= sample_tick && ENABLE;
            if (ENABLE)
                out_left <= wave ? 16'sd4000 : -16'sd4000;
            else
                out_left <= 16'sd0;
            out_right <= out_left;      // 左右声道一样（单声道听感）
        end
    end
endmodule
