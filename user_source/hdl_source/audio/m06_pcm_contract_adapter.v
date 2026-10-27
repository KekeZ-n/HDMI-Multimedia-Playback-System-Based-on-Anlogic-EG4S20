//============================================================================
// m06_pcm_contract_adapter.v
//  HDMI音频输出基础 —— PCM 契约适配器（常规做法 子模块）
//
// 【为什么叫"契约"】就是"接口规格说明书"：谁来都必须按这套规矩交样本。
//   规矩有三条：① 16 位有符号样本 → 24 位有符号（HDMI 发射器要 24 位）
//              ② sample_valid 必须是"1 拍脉冲"，约 48kHz（发射器按拍数取样本）
//              ③ 位宽扩展用"左移 8 位"而不是补符号位，保证满量程比例不变、不削波
//   16 位满量程 = 32767，24 位满量程 = 8388607，正好差 256 倍 = 左移 8 位。
//   我们的正弦表最大 12000，×256 = 3,072,000 < 8,388,607，所以永远不会爆音。
//============================================================================
module m06_pcm_contract_adapter (
    input  wire               clk,
    input  wire               rst,              // 高有效复位
    input  wire               i_valid,          // 上游样本有效（高电平直到被接收）
    output wire               o_ready,          // 本模块永远就绪
    input  wire signed [15:0] i_left,           // 上游 16 位有符号左声道
    input  wire signed [15:0] i_right,          // 上游 16 位有符号右声道
    output reg                o_valid,          // 下游：1 拍脉冲（48kHz）
    output reg  [23:0]        o_left,           // 下游：24 位左声道
    output reg  [23:0]        o_right,          // 下游：24 位右声道
    output wire signed [15:0] tap_left,         // PCM 探针（音频可视化用）
    output wire signed [15:0] tap_right,
    output wire               tap_valid
);

    // 本工程下游是 HDMI 发射器核，每拍都能收，所以永远返回 ready=1
    assign o_ready   = 1'b1;

    // PCM 探针：把 16 位原始样本直接引出去做波形显示，不占额外资源
    assign tap_left  = i_left;
    assign tap_right = i_right;
    assign tap_valid = i_valid;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            o_valid <= 1'b0;
            o_left  <= 24'd0;
            o_right <= 24'd0;
        end
        else begin
            // 打一拍寄存：valid 和样本同时对齐后交给下游
            o_valid <= i_valid;
            o_left  <= {i_left,  8'd0};     // 16 位 → 24 位（左移 8 位 = ×256）
            o_right <= {i_right, 8'd0};
        end
    end
endmodule
