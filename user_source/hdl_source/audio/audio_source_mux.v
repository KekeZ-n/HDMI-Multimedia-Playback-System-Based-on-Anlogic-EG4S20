//============================================================================
// audio_source_mux.v
//  HDMI音频输出基础 —— 音频源选择（常规做法 音频源选择架构）
//
// 【原始设计照抄，一字未改】常规做法 给出了本模块的完整代码。
// 本工程只用到"媒体音调"这一路，WAV 那一路按常规设计接 0（才接 WAV）。
//
// 【它解决什么问题】
//   以后会有多个音源（测试音 / WAV 播放 / 媒体音调）抢同一个输出口。
//   用 valid/ready 握手：ready 只回给"被选中"的那一路，
//   没被选中的那一路看到 ready=0，它内部的 FIFO 不会被消耗、数据不会丢、切换不爆音。
//============================================================================
module audio_source_mux (
    // 音源A：WAV流
    input  wire               wav_valid,
    output wire               wav_ready,
    input  wire signed [15:0] wav_left, wav_right,
    input  wire               wav_active,     // WAV正在播放（level）

    // 音源B：琶音合成（pcm_media_tone）
    input  wire               arp_valid,
    output wire               arp_ready,
    input  wire signed [15:0] arp_left, arp_right,

    // 强制选择：拨码开关或菜单可以强制用琶音
    input  wire               force_arpeggio,

    // 输出到 m06_pcm_contract_adapter
    output wire               out_valid,
    input  wire               out_ready,
    output wire signed [15:0] out_left, out_right
);
    wire use_wav = wav_active && !force_arpeggio;
    assign out_valid = use_wav ? wav_valid : arp_valid;
    assign out_left  = use_wav ? wav_left  : arp_left;
    assign out_right = use_wav ? wav_right : arp_right;
    assign wav_ready = use_wav ? out_ready : 1'b0;
    assign arp_ready = use_wav ? 1'b0      : out_ready;
endmodule
