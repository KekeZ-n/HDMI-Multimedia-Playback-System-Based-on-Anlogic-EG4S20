//============================================================================
// media_hdmi_audio_bridge.v
//  HDMI音频输出基础 —— HDMI 音频桥接（常规做法 / 4.2 顶层新增的那个实例）
//
// 【它是谁】音频侧的"总装车间"：把音源选出来 -> 按契约适配 -> 交给 HDMI 发射器。
//   常规做法 的原始架构是：
//     media_id -> pcm_media_tone -> m06_pcm_contract_adapter -> hdmi_audio_symbol_core
//     -> channel0/1/2_symbol -> HDMI发射器
//
// 【本工程的适配（重要，答辩要说清）】
//   本工程的 HDMI 发射器核 hdmi_1_4b_transmitter_core_wrapper 内部已经自带了
//   "音频包封装(音频采样包/InfoFrame/ACR) + 音视频复用 + TMDS 输出"，
//   也就是常规做法里 hdmi_audio_symbol_core 干的活它一个人全干了。
//   所以本工程的桥接模块做到"PCM 契约"这一层就交给发射器核，
//   不再自己产生 channel0/1/2_symbol（重复造轮子反而会破坏发射器核内部时序）。
//   它的输出口 = 发射器核的音频输入口：
//     O_audio_valid / O_audio_left_data[23:0] / O_audio_right_data[23:0]
//
// 【时钟】用 25MHz 像素时钟分频出 48kHz 采样脉冲，不需要独立音频 PLL（常规做法 决策 1）
// 【探针】pcm_tap_* 引出去给音频可视化用（常规做法 决策 2）
//============================================================================
module media_hdmi_audio_bridge #(
    parameter integer SAMPLE_DIV   = 521,       // 25MHz / 48kHz ≈ 521
    parameter integer VOLUME_SHIFT = 0          // 音量缩放：0=原始，1=减半
)(
    input  wire               clk,              // 像素时钟 25MHz
    input  wire               rst,              // 高有效复位
    input  wire               enable,           // 音频总使能
    input  wire [3:0]         media_id,         // 当前图片ID（0~3）—— 音调联动的钥匙
    input  wire [1:0]         source_sel,       // 0=正弦测试音  1=音源选择mux（媒体音调/WAV）

    // WAV 流音源（接入，本课全部接 0）
    input  wire               wav_valid,
    output wire               wav_ready,
    input  wire signed [15:0] wav_left,
    input  wire signed [15:0] wav_right,
    input  wire               wav_active,
    input  wire               force_arpeggio,   // 1 = 强制用媒体音调（常规做法）

    // 输出：PCM 契约（接到 HDMI 发射器核的音频输入口）
    output wire               o_audio_valid,
    output wire [23:0]        o_audio_left,
    output wire [23:0]        o_audio_right,

    // PCM 探针输出（音频可视化用，本课先不接）
    output wire               pcm_tap_valid,
    output wire signed [15:0] pcm_tap_left,
    output wire signed [15:0] pcm_tap_right
);

    //------------------------------------------------------------------------
    // 各音源的样本线
    //------------------------------------------------------------------------
    wire               test_valid;
    wire signed [15:0] test_left, test_right;

    wire               arp_valid;
    wire               arp_ready;
    wire signed [15:0] arp_left, arp_right;

    wire               mux_valid;
    wire signed [15:0] mux_left, mux_right;

    wire               ctr_ready;       // 契约适配器永远就绪(=1)

    // 音源二选一：测试音 还是 音源选择mux 的输出
    wire use_test = (source_sel == 2'd0);

    wire               sel_valid = use_test ? test_valid : mux_valid;
    wire signed [15:0] sel_left  = use_test ? test_left  : mux_left;
    wire signed [15:0] sel_right = use_test ? test_right : mux_right;

    //------------------------------------------------------------------------
    // 音源①：正弦波测试音（验证 HDMI 音频链路是否通）
    //------------------------------------------------------------------------
    pcm_test_tone #(
        .SAMPLE_DIV           (SAMPLE_DIV)
    ) u_pcm_test_tone (
        .clk                  (clk),
        .rst                  (rst),
        .enable               (enable),
        .sample_valid         (test_valid),
        .sample_ready         (use_test ? ctr_ready : 1'b0),   // ready 只回给被选中的音源
        .sample_left          (test_left),
        .sample_right         (test_right),
        .rom_index            ()
    );

    //------------------------------------------------------------------------
    // 音源②：媒体音调（换图片换音调，常规做法）
    //------------------------------------------------------------------------
    pcm_media_tone #(
        .SAMPLE_DIV           (SAMPLE_DIV),
        .VOLUME_SHIFT         (VOLUME_SHIFT)
    ) u_pcm_media_tone (
        .clk                  (clk),
        .rst                  (rst),
        .enable               (enable),
        .media_id             (media_id),
        .sample_valid         (arp_valid),
        .sample_ready         (arp_ready),
        .sample_left          (arp_left),
        .sample_right         (arp_right),
        .note_index           (),
        .rom_index            ()
    );

    //------------------------------------------------------------------------
    // 音源选择（常规做法 原文模块，内含 WAV 那一路，本课接 0）
    //------------------------------------------------------------------------
    audio_source_mux u_audio_source_mux (
        .wav_valid            (wav_valid),
        .wav_ready            (wav_ready),
        .wav_left             (wav_left),
        .wav_right            (wav_right),
        .wav_active           (wav_active),

        .arp_valid            (arp_valid),
        .arp_ready            (arp_ready),
        .arp_left             (arp_left),
        .arp_right            (arp_right),

        .force_arpeggio       (force_arpeggio),

        .out_valid            (mux_valid),
        .out_ready            (use_test ? 1'b0 : ctr_ready),   // ready 只回给被选中的音源
        .out_left             (mux_left),
        .out_right            (mux_right)
    );

    //------------------------------------------------------------------------
    // PCM 契约适配：16位->24位、valid 变 1 拍脉冲（常规做法 子模块）
    //------------------------------------------------------------------------
    m06_pcm_contract_adapter u_m06_pcm_contract_adapter (
        .clk                  (clk),
        .rst                  (rst),
        .i_valid              (sel_valid),
        .o_ready              (ctr_ready),
        .i_left               (sel_left),
        .i_right              (sel_right),
        .o_valid              (o_audio_valid),
        .o_left               (o_audio_left),
        .o_right              (o_audio_right),
        .tap_left             (pcm_tap_left),
        .tap_right            (pcm_tap_right),
        .tap_valid            (pcm_tap_valid)
    );

endmodule
