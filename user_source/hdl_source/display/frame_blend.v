`timescale 1ns/1ps

// ============================================================================
// 【第十课】帧混合模块（常规设计逐字采用，可选件）
//
//
//
// 一句话作用：把**两张画面**按比例"兑水"混在一起。
//             alpha=0 出 A 图，alpha=255 出 B 图，中间就是半透明的叠影。
//
//  重要提醒（常规设计自己写明了）
//   本工程是**单读口 SDRAM**（一个保鲜柜只有一扇门），一张图占满全部带宽，
//   根本没法同时把"旧图"和"新图"两路像素拿进来 ⇒ **本模块在本工程里不例化**，
//   只作为"以后升级成双SDRAM/双读口"时的参考件放在这里。
//   实际生效的淡入淡出走的是 video_fade_transition 的
//   "淡出到黑 → 换图 → 从黑淡入"方案（只需要一路像素）。
// ============================================================================
module frame_blend #(
    parameter integer ALPHA_STEP = 32   // 每帧alpha增量（255/32≈8帧完成）
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start_effect,  // 启动混合
    input  wire        frame_start,   // 帧边界
    input  wire [11:0] rgb_a,         // 画面A（旧帧，12位）
    input  wire [11:0] rgb_b,         // 画面B（新帧，12位）
    output reg  [11:0] rgb_out,       // 混合输出
    output reg  [7:0]  alpha,         // 当前alpha
    output reg         effect_active  // 混合进行中
);
    integer mix_r, mix_g, mix_b;

    // alpha时序逻辑：只在帧边界更新
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            alpha <= 8'd0;
            effect_active <= 1'b0;
        end else begin
            if (start_effect) begin
                alpha <= 8'd0;
                effect_active <= 1'b1;
            end else if (frame_start && effect_active) begin
                if (alpha + ALPHA_STEP >= 255) begin
                    alpha <= 8'd255;
                    effect_active <= 1'b0;   // 混合完成
                end else begin
                    alpha <= alpha + ALPHA_STEP;
                end
            end
        end
    end

    // 像素混合组合逻辑：每通道独立加权
    // +127是四舍五入，/255可以近似为/256（右移8位）
    always @* begin
        mix_r = (rgb_a[11:8] * (255-alpha) + rgb_b[11:8] * alpha + 127) / 255;
        mix_g = (rgb_a[7:4]  * (255-alpha) + rgb_b[7:4]  * alpha + 127) / 255;
        mix_b = (rgb_a[3:0]  * (255-alpha) + rgb_b[3:0]  * alpha + 127) / 255;
        rgb_out = {mix_r[3:0], mix_g[3:0], mix_b[3:0]};
    end
endmodule
