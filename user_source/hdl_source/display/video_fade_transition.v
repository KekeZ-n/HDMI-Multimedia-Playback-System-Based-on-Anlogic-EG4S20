`timescale 1ns/1ps

// ============================================================================
// 【第十课】图片转场特效 —— 转场控制器（常规设计逐字采用）
//
//
//           （常规设计正文那一大段 ```verilog ... ``` 就是本文件，一行未改）
//
// 一句话作用：站在"按键"和"真正换图"中间当**舞台监督**。
//   手动按键 → 先把旧图调暗到全黑（淡出）→ 通知后台换图 → 再把新图慢慢调亮（淡入）
//   自动轮播 → 换图已经发生，就用"拉幕布"的方式把新图从左往右揭出来（Wipe）
//   FADE_FRAMES=0 → 整体旁路，什么都不做，行为等同于硬切
//
// 内部有**两个时钟域**：
//   ctrl_clk（本工程 = sd_card_clk 100MHz）：管按键请求
//   pix_clk （本工程 = video_clk 25MHz）  ：管帧边界、alpha、Wipe
//   两边用"翻转开关（toggle）+ 两级触发器"互相通知，这是跨时钟域的标准做法。
// ============================================================================
module video_fade_transition #(
    parameter integer FADE_FRAMES = 0   // 淡入淡出帧数，0=旁路
) (
    // 控制域接口
    input  wire       ctrl_clk,
    input  wire       ctrl_rst_n,
    input  wire       next_event_in,    // 切换请求输入
    output wire       next_event_out,   // 全黑时输出给控制层
    output wire       fade_busy,        // 转场忙
    // 像素域接口
    input  wire       pix_clk,
    input  wire       pix_rst_n,
    input  wire       player_active,
    input  wire       frame_start,      // 帧开始
    input  wire       index_commit,     // 图片索引已切换
    input  wire [1:0] active_index,
    output wire [7:0] alpha_out,        // Alpha值0-255
    output wire       fade_active,      // 转场进行中
    output wire       wipe_active,      // Wipe揭示中
    output wire [4:0] ramp_out,         // Wipe边界计数
    output wire [1:0] transition_kind   // 转场类型
);
    generate
        if (FADE_FRAMES == 0) begin : g_bypass
            // 旁路模式：不启用转场
            assign next_event_out  = next_event_in;
            assign fade_busy       = 1'b0;
            assign alpha_out       = 8'd255;
            assign fade_active     = 1'b0;
            assign wipe_active     = 1'b0;
            assign ramp_out        = 5'd0;
            assign transition_kind = 2'd0;
        end else begin : g_fade
            localparam integer STEP = 256 / FADE_FRAMES;
            localparam integer CNT_W = (FADE_FRAMES <= 2) ? 2
                                      : $clog2(FADE_FRAMES + 1);

            localparam [1:0] S_IDLE = 2'd0;
            localparam [1:0] S_OUT  = 2'd1;
            localparam [1:0] S_HOLD = 2'd2;
            localparam [1:0] S_IN   = 2'd3;

            // 跨时钟域共享寄存器
            reg req_toggle;
            reg ack_seen;
            reg commit_sync1, commit_sync2;
            reg busy_sync1, busy_sync2;

            // 像素域寄存器
            reg [1:0] state;
            reg [CNT_W-1:0] ramp;
            reg req_sync1, req_sync2, req_seen;
            reg commit_toggle;
            reg wipe_mode;
            reg [1:0] wipe_kind;

            wire fade_running = (state != S_IDLE);
            assign fade_active = fade_running;
            assign ramp_out = {{(5-CNT_W){1'b0}}, ramp};
            assign wipe_active = (state == S_IN) && wipe_mode;
            assign transition_kind = wipe_kind;

            // alpha计算
            wire [CNT_W+8:0] ramp_alpha = ramp * STEP;
            wire [7:0] ramp_alpha8 = ramp_alpha[7:0];
            assign alpha_out = ((state == S_IDLE) ||
                                ((state == S_IN) && wipe_mode)) ? 8'd255 :
                                (state == S_HOLD) ? 8'd0 :
                                (ramp == FADE_FRAMES) ? 8'd255
                                                      : ramp_alpha8;

            // ========== 像素域状态机 ==========
            always @(posedge pix_clk or negedge pix_rst_n) begin
                if (!pix_rst_n) begin
                    state <= S_IDLE;
                    ramp <= {CNT_W{1'b0}};
                    req_sync1 <= 1'b0; req_sync2 <= 1'b0; req_seen <= 1'b0;
                    commit_toggle <= 1'b0;
                    wipe_mode <= 1'b0; wipe_kind <= 2'd0;
                end else begin
                    req_sync1 <= req_toggle;
                    req_sync2 <= req_sync1;

                    case (state)
                    S_IDLE: begin
                        if (req_sync2 != req_seen) begin
                            // 手动切换请求
                            req_seen <= req_sync2;
                            if (player_active) begin
                                state <= S_OUT;
                                ramp <= FADE_FRAMES[CNT_W-1:0];
                            end
                        end else if (index_commit && player_active) begin
                            // 自动轮播：切换已发生，用Wipe揭示新图
                            state <= S_IN;
                            ramp <= {CNT_W{1'b0}};
                            wipe_mode <= 1'b1;
                            wipe_kind <= active_index;
                        end
                    end

                    S_OUT: begin
                        if (frame_start) begin
                            if (ramp == 0) begin
                                // 淡出完成→全黑，发切换确认
                                state <= S_HOLD;
                                commit_toggle <= ~commit_toggle;
                            end else begin
                                ramp <= ramp - 1'b1;
                            end
                        end
                        if (req_sync2 != req_seen)
                            req_seen <= req_sync2;
                    end

                    S_HOLD: begin
                        // 全黑等待控制层切换完成
                        if (index_commit) begin
                            state <= S_IN;
                            ramp <= {CNT_W{1'b0}};
                            wipe_mode <= 1'b0;
                        end
                    end

                    S_IN: begin
                        if (req_sync2 != req_seen)
                            req_seen <= req_sync2;
                        if (frame_start) begin
                            if (ramp >= FADE_FRAMES - 1)
                                state <= S_IDLE;       // 淡入完成
                            else
                                ramp <= ramp + 1'b1;
                        end
                    end
                    endcase
                end
            end

            // ========== 控制域握手 ==========
            assign fade_busy = busy_sync2;
            assign next_event_out = (commit_sync2 != ack_seen);

            always @(posedge ctrl_clk or negedge ctrl_rst_n) begin
                if (!ctrl_rst_n) begin
                    req_toggle <= 1'b0;
                    ack_seen <= 1'b0;
                    commit_sync1 <= 1'b0; commit_sync2 <= 1'b0;
                    busy_sync1 <= 1'b0; busy_sync2 <= 1'b0;
                end else begin
                    busy_sync1 <= fade_running;
                    busy_sync2 <= busy_sync1;
                    commit_sync1 <= commit_toggle;
                    commit_sync2 <= commit_sync1;
                    // 转场忙时丢弃新请求
                    if (next_event_in && !busy_sync2)
                        req_toggle <= ~req_toggle;
                    if (commit_sync2 != ack_seen)
                        ack_seen <= commit_sync2;
                end
            end
        end
    endgenerate
endmodule
