//============================================================================
// pcm_media_tone.v
//  HDMI音频输出基础 —— 媒体音调联动（常规做法 pcm_media_tone）
//
// 【它干什么】"换图片就换音调"：每张图片（media_id = 0~3）对应一套 6 音符琶音，
//   切换图片的瞬间先响一个 1.5kHz 的"哔"（blip，100ms），然后循环播放该图的琶音
//   （每个音符 250ms）。答辩时一个很讨喜的细节：换图有听觉反馈。
//
// 【怎么发声】DDS：相位累加器 + 16 点正弦查找表（和 pcm_test_tone 同一张表）
//   相位增量（20 位）= 频率 × 2^20 / 48000 ≈ 频率 × 21.8453
//   C5(523Hz)→11426   E5(659Hz)→14396   G5(784Hz)→17127   C6(1046Hz)→22850
//============================================================================
module pcm_media_tone #(
    parameter integer SAMPLE_DIV   = 521,        // 25MHz / 48kHz ≈ 521
    parameter [19:0]  BLIP_INC     = 20'd32768,  // ~1500Hz 换图提示音（常规做法 原文）
    parameter integer BLIP_SAMPLES = 4800,       // 100ms 提示音时长（常规做法 原文）
    parameter integer NOTE_SAMPLES = 12000,      // 每个音符 250ms（常规做法 原文）
    parameter integer VOLUME_SHIFT = 0           // 音量缩放：右移位数，0=原始，1=减半
)(
    input  wire               clk,               // 像素时钟 25MHz
    input  wire               rst,               // 高有效复位
    input  wire               enable,
    input  wire [3:0]         media_id,          // 当前图片ID（0~3）
    output reg                sample_valid,
    input  wire               sample_ready,
    output reg  signed [15:0] sample_left,
    output reg  signed [15:0] sample_right,
    output wire [2:0]         note_index,        // 当前是6个音里的第几个（调试用）
    output wire [3:0]         rom_index          // 正弦表索引（调试用）
);

    reg  [15:0] div_count;
    reg  [19:0] phase_acc;
    reg  [15:0] note_cnt;
    reg  [2:0]  note_idx;
    reg  [15:0] blip_cnt;
    reg  [3:0]  media_id_d;

    assign note_index = note_idx;
    assign rom_index  = phase_acc[19:16];

    //------------------------------------------------------------------------
    // 16 点正弦波查找表（与 pcm_test_tone 同一张表）
    //------------------------------------------------------------------------
    function signed [15:0] sine_lut;
        input [3:0] index;
        begin
            case (index)
                4'd0:    sine_lut =  16'sd0;
                4'd1:    sine_lut =  16'sd4592;
                4'd2:    sine_lut =  16'sd8485;
                4'd3:    sine_lut =  16'sd11087;
                4'd4:    sine_lut =  16'sd12000;
                4'd5:    sine_lut =  16'sd11087;
                4'd6:    sine_lut =  16'sd8485;
                4'd7:    sine_lut =  16'sd4592;
                4'd8:    sine_lut =  16'sd0;
                4'd9:    sine_lut = -16'sd4592;
                4'd10:   sine_lut = -16'sd8485;
                4'd11:   sine_lut = -16'sd11087;
                4'd12:   sine_lut = -16'sd12000;
                4'd13:   sine_lut = -16'sd11087;
                4'd14:   sine_lut = -16'sd8485;
                default: sine_lut = -16'sd4592;
            endcase
        end
    endfunction

    //------------------------------------------------------------------------
    // 图片ID -> 6 音符琶音表（常规做法：C大调上行 / A小调 / 五声音阶 / 低-高摇摆）
    //------------------------------------------------------------------------
    function [19:0] note_inc_lut;
        input [3:0] mid;
        input [2:0] nidx;
        begin
            case (mid)
                4'd0: // C大调上行：C5-E5-G5-C6-G5-E5
                    case (nidx)
                        3'd0:    note_inc_lut = 20'd11426;   // C5 523Hz
                        3'd1:    note_inc_lut = 20'd14396;   // E5 659Hz
                        3'd2:    note_inc_lut = 20'd17127;   // G5 784Hz
                        3'd3:    note_inc_lut = 20'd22850;   // C6 1046Hz
                        3'd4:    note_inc_lut = 20'd17127;   // G5
                        default: note_inc_lut = 20'd14396;   // E5
                    endcase
                4'd1: // A小调：A4-C5-E5-A5-E5-C5
                    case (nidx)
                        3'd0:    note_inc_lut = 20'd9612;    // A4 440Hz
                        3'd1:    note_inc_lut = 20'd11426;   // C5
                        3'd2:    note_inc_lut = 20'd14396;   // E5
                        3'd3:    note_inc_lut = 20'd19224;   // A5 880Hz
                        3'd4:    note_inc_lut = 20'd14396;   // E5
                        default: note_inc_lut = 20'd11426;   // C5
                    endcase
                4'd2: // 五声音阶：C5-D5-E5-G5-A5-C5
                    case (nidx)
                        3'd0:    note_inc_lut = 20'd11426;   // C5
                        3'd1:    note_inc_lut = 20'd12823;   // D5 587Hz
                        3'd2:    note_inc_lut = 20'd14396;   // E5
                        3'd3:    note_inc_lut = 20'd17127;   // G5
                        3'd4:    note_inc_lut = 20'd19224;   // A5
                        default: note_inc_lut = 20'd11426;   // C5
                    endcase
                default: // media_id=3 低-高摇摆：C5-C6 交替
                    case (nidx)
                        3'd0:    note_inc_lut = 20'd11426;   // C5
                        3'd1:    note_inc_lut = 20'd22850;   // C6
                        3'd2:    note_inc_lut = 20'd11426;   // C5
                        3'd3:    note_inc_lut = 20'd22850;   // C6
                        3'd4:    note_inc_lut = 20'd11426;   // C5
                        default: note_inc_lut = 20'd22850;   // C6
                    endcase
            endcase
        end
    endfunction

    wire               tick         = (div_count >= SAMPLE_DIV - 1);
    wire               blipping     = (blip_cnt != 16'd0);
    wire               media_changed= (media_id != media_id_d);
    wire [19:0]        phase_inc    = blipping ? BLIP_INC : note_inc_lut(media_id_d, note_idx);
    wire signed [15:0] raw_sample   = sine_lut(phase_acc[19:16]);
    wire signed [15:0] scaled       = raw_sample >>> VOLUME_SHIFT;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            div_count    <= 16'd0;
            phase_acc    <= 20'd0;
            note_cnt     <= 16'd0;
            note_idx     <= 3'd0;
            blip_cnt     <= 16'd0;
            media_id_d   <= 4'd0;
            sample_valid <= 1'b0;
            sample_left  <= 16'sd0;
            sample_right <= 16'sd0;
        end
        else if (!enable) begin
            div_count    <= 16'd0;
            sample_valid <= 1'b0;
        end
        else begin
            // ① 48kHz 采样分频
            if (tick)
                div_count <= 16'd0;
            else
                div_count <= div_count + 16'd1;

            // ② 样本被下游收走：相位往前推一步，并处理换图提示音/音符计时
            if (sample_valid && sample_ready) begin
                sample_valid <= 1'b0;
                phase_acc    <= phase_acc + phase_inc;

                if (media_changed) begin
                    // 换图了：先响 100ms 提示音
                    media_id_d <= media_id;
                    blip_cnt   <= BLIP_SAMPLES - 1;
                    note_cnt   <= 16'd0;
                    note_idx   <= 3'd0;
                end
                else if (blipping) begin
                    blip_cnt <= blip_cnt - 16'd1;
                end
                else if (note_cnt >= NOTE_SAMPLES - 1) begin
                    // 一个音符放满 250ms，换下一个音
                    note_cnt <= 16'd0;
                    note_idx <= note_idx + 3'd1;
                end
                else begin
                    note_cnt <= note_cnt + 16'd1;
                end
            end
            // ③ 到了采样点就吐一个样本
            else if (tick && !sample_valid) begin
                sample_valid <= 1'b1;
                sample_left  <= scaled;
                sample_right <= scaled;
            end
        end
    end
endmodule
