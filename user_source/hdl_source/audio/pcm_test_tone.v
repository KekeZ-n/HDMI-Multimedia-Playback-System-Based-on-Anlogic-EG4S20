//============================================================================
// pcm_test_tone.v
//  HDMI音频输出基础 —— 正弦波测试音生成（16点正弦波查找表 LUT）
// 对应常规设计：3.2 pcm_test_tone 模块详解 / 4.1 新增文件
//
// 【为什么要这个模块】
//   常规做法是用相位累加器生成"方波"（只取相位最高位，
//   非正即负），谐波多，听感是"嘀嘀"的电子音。
//   本模块按常规设计改成 16 点正弦波查找表，音色明显更干净、更像"哔——"的测试音。
//
// 【怎么工作】分频计数 -> 每 521 拍产生一个 48kHz 样本 -> 查 16 点正弦表 -> 交给下游
//   时钟用像素时钟 25MHz（不是独立音频 PLL），SAMPLE_DIV = 25_000_000/48_000 ≈ 521
//============================================================================
module pcm_test_tone #(
    parameter integer SAMPLE_DIV = 521          // 25MHz / 48kHz ≈ 521 -> 48kHz 采样
)(
    input  wire               clk,              // 像素时钟 25MHz
    input  wire               rst,              // 高有效复位（本工程统一用 rst_all）
    input  wire               enable,           // 使能，1 = 开始出声
    output reg                sample_valid,     // 样本有效（1 拍脉冲，约 48kHz）
    input  wire               sample_ready,     // 下游就绪（本工程恒为 1）
    output reg  signed [15:0] sample_left,      // 左声道 16 位有符号样本
    output reg  signed [15:0] sample_right,     // 右声道 16 位有符号样本
    output wire [3:0]         rom_index         // 当前 LUT 索引（调试用）
);

    reg  [15:0] div_count;
    reg  [3:0]  idx;

    assign rom_index = idx;

    //------------------------------------------------------------------------
    // 16 点正弦波查找表（常规做法 原文数值，一字不改）
    // 幅值约 12000 ≈ 16 位满量程的 1/3，故意留余量避免爆音
    //------------------------------------------------------------------------
    function signed [15:0] sine_sample;
        input [3:0] index;
        begin
            case (index)
                4'd0:    sine_sample =  16'sd0;
                4'd1:    sine_sample =  16'sd4592;
                4'd2:    sine_sample =  16'sd8485;
                4'd3:    sine_sample =  16'sd11087;
                4'd4:    sine_sample =  16'sd12000;
                4'd5:    sine_sample =  16'sd11087;
                4'd6:    sine_sample =  16'sd8485;
                4'd7:    sine_sample =  16'sd4592;
                4'd8:    sine_sample =  16'sd0;
                4'd9:    sine_sample = -16'sd4592;
                4'd10:   sine_sample = -16'sd8485;
                4'd11:   sine_sample = -16'sd11087;
                4'd12:   sine_sample = -16'sd12000;
                4'd13:   sine_sample = -16'sd11087;
                4'd14:   sine_sample = -16'sd8485;
                default: sine_sample = -16'sd4592;
            endcase
        end
    endfunction

    //------------------------------------------------------------------------
    // 四步走：①分频计数 ②输出样本 ③握手清零 ④索引回绕
    //------------------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            div_count    <= 16'd0;
            idx          <= 4'd0;
            sample_valid <= 1'b0;
            sample_left  <= 16'sd0;
            sample_right <= 16'sd0;
        end
        else if (!enable) begin
            div_count    <= 16'd0;
            sample_valid <= 1'b0;
        end
        else begin
            // ① 分频计数：0 ~ SAMPLE_DIV-1 循环
            if (div_count >= SAMPLE_DIV - 1)
                div_count <= 16'd0;
            else
                div_count <= div_count + 16'd1;

            // ③ 握手机制：样本被下游收走后清 valid，并让 LUT 索引 +1
            if (sample_valid && sample_ready) begin
                sample_valid <= 1'b0;
                idx          <= idx + 4'd1;      // ④ 4 位自动回绕：0~15 循环
            end
            // ② 输出样本：每 SAMPLE_DIV 拍产生一个样本
            else if ((div_count >= SAMPLE_DIV - 1) && !sample_valid) begin
                sample_valid <= 1'b1;
                sample_left  <= sine_sample(idx);
                sample_right <= sine_sample(idx);
            end
        end
    end

    // 输出频率 = 48000 / 16 = 3000Hz（16 点表一个完整正弦周期）
endmodule
