//
// AY-3-8910 High-Quality Audio Pipeline - Top Level
//
// Complete audio synthesis chain matching unreal-ng emulator:
// - Native clock rendering at 218.75 kHz
// - High-precision DAC (Q1.31)
// - Stereo panning (ABC/ACB/Mono)
// - DC offset removal
// - 96-tap FIR decimation to 44.1 kHz
// - Punch enhancement (transient designer)
// - Room crossfeed (headphone fatigue reduction)
//
// Copyright (c) 2025 - Port from unreal-ng emulator
//

module ay_hq_top
(
    input  wire        CLK,          // System clock
    input  wire        CE_PSG,       // PSG clock enable (1.75 MHz)
    input  wire        RESET,

    // AY register interface
    input  wire        BDIR,
    input  wire        BC,
    input  wire [7:0]  DI,
    output wire [7:0]  DO,

    // I/O ports
    input  wire [7:0]  IOA_in,
    output wire [7:0]  IOA_out,
    input  wire [7:0]  IOB_in,
    output wire [7:0]  IOB_out,

    // Configuration
    input  wire        MODE,         // 0 = AY-3-8910, 1 = YM2149
    input  wire [1:0]  STEREO_MODE,  // 0=ABC, 1=ACB, 2=Mono
    input  wire        HQ_ENABLE,    // Enable HQ pipeline (vs simple output)
    input  wire        PUNCH_ENABLE, // Enable punch enhancement
    input  wire        PUNCH_PRESET, // 0=AY (gentle), 1=Paula (strong)
    input  wire [3:0]  ROOM_LEVEL,   // 0=Off, 1-9 = -15dB to -1dB

    // Status
    output wire [5:0]  ACTIVE,       // Channel activity

    // Audio outputs
    output wire        AUDIO_VALID,  // Pulse at 44.1 kHz when sample ready
    output wire signed [15:0] AUDIO_L,  // 16-bit signed PCM
    output wire signed [15:0] AUDIO_R,

    // Legacy 8-bit outputs (direct from core)
    output wire [7:0]  CHANNEL_A,
    output wire [7:0]  CHANNEL_B,
    output wire [7:0]  CHANNEL_C
);

// ============================================================================
// Clock Enable Generation
// ============================================================================

// Generator clock: PSG_CLOCK / 8 = 218.75 kHz
reg [2:0] gen_div;
wire ce_gen = CE_PSG && (gen_div == 0);

always @(posedge CLK) begin
    if (RESET)
        gen_div <= 0;
    else if (CE_PSG)
        gen_div <= gen_div + 1;
end

// ============================================================================
// Core AY-3-8910 / YM2149 (HQ version with raw level outputs)
// ============================================================================

wire [4:0] raw_a, raw_b, raw_c;  // 5-bit amplitude levels
wire tone_a, tone_b, tone_c;     // Generator outputs
wire noise_out;
wire [4:0] envelope_out;

YM2149_HQ ay_core
(
    .CLK      (CLK),
    .CE       (CE_PSG),
    .RESET    (RESET),
    .BDIR     (BDIR),
    .BC       (BC),
    .DI       (DI),
    .DO       (DO),
    .CHANNEL_A(CHANNEL_A),
    .CHANNEL_B(CHANNEL_B),
    .CHANNEL_C(CHANNEL_C),
    .RAW_A    (raw_a),
    .RAW_B    (raw_b),
    .RAW_C    (raw_c),
    .TONE_A   (tone_a),
    .TONE_B   (tone_b),
    .TONE_C   (tone_c),
    .NOISE    (noise_out),
    .ENVELOPE (envelope_out),
    .SEL      (1'b0),  // Standard clock divider
    .MODE     (MODE),
    .ACTIVE   (ACTIVE),
    .IOA_in   (IOA_in),
    .IOA_out  (IOA_out),
    .IOB_in   (IOB_in),
    .IOB_out  (IOB_out)
);

// ============================================================================
// High-Precision DAC Lookup
// ============================================================================

wire [31:0] dac_a, dac_b, dac_c;

ay_dac dac_ch_a (
    .clk     (CLK),
    .mode    (MODE),
    .level   (raw_a),
    .dac_out (dac_a)
);

ay_dac dac_ch_b (
    .clk     (CLK),
    .mode    (MODE),
    .level   (raw_b),
    .dac_out (dac_b)
);

ay_dac dac_ch_c (
    .clk     (CLK),
    .mode    (MODE),
    .level   (raw_c),
    .dac_out (dac_c)
);

// ============================================================================
// Stereo Mixer
// ============================================================================

wire [31:0] mixed_l, mixed_r;

ay_stereo_mixer stereo_mix (
    .clk         (CLK),
    .ce          (ce_gen),
    .stereo_mode (STEREO_MODE),
    .ch_a        (dac_a),
    .ch_b        (dac_b),
    .ch_c        (dac_c),
    .out_left    (mixed_l),
    .out_right   (mixed_r)
);

// ============================================================================
// DC Offset Filter
// ============================================================================

wire [31:0] dc_filtered_l, dc_filtered_r;

ay_dc_filter dc_filt_l (
    .clk       (CLK),
    .ce        (ce_gen),
    .reset     (RESET),
    .in_sample (mixed_l),
    .out_sample(dc_filtered_l)
);

ay_dc_filter dc_filt_r (
    .clk       (CLK),
    .ce        (ce_gen),
    .reset     (RESET),
    .in_sample (mixed_r),
    .out_sample(dc_filtered_r)
);

// ============================================================================
// FIR Decimator (218.75 kHz -> 44.1 kHz)
// ============================================================================

wire fir_valid_l, fir_valid_r;
wire [31:0] fir_out_l, fir_out_r;

ay_fir_decimator fir_l (
    .clk       (CLK),
    .ce_in     (ce_gen),
    .reset     (RESET),
    .in_sample (dc_filtered_l),
    .out_valid (fir_valid_l),
    .out_sample(fir_out_l)
);

ay_fir_decimator fir_r (
    .clk       (CLK),
    .ce_in     (ce_gen),
    .reset     (RESET),
    .in_sample (dc_filtered_r),
    .out_valid (fir_valid_r),
    .out_sample(fir_out_r)
);

// Both channels should have valid at same time
wire fir_valid = fir_valid_l;  // Use left channel's valid

// ============================================================================
// Punch Enhancement
// ============================================================================

wire [31:0] punch_out_l, punch_out_r;

ay_punch_enhancer punch (
    .clk       (CLK),
    .ce        (fir_valid),
    .reset     (RESET),
    .enable    (PUNCH_ENABLE),
    .preset    (PUNCH_PRESET),
    .in_left   (fir_out_l),
    .in_right  (fir_out_r),
    .out_left  (punch_out_l),
    .out_right (punch_out_r)
);

// ============================================================================
// Room Crossfeed
// ============================================================================

wire [31:0] room_out_l, room_out_r;

ay_room_crossfeed room (
    .clk        (CLK),
    .ce         (fir_valid),
    .reset      (RESET),
    .enable     (ROOM_LEVEL != 0),
    .room_level (ROOM_LEVEL),
    .in_left    (punch_out_l),
    .in_right   (punch_out_r),
    .out_left   (room_out_l),
    .out_right  (room_out_r)
);

// ============================================================================
// Output Stage
// ============================================================================

// Convert Q4.28 to 16-bit signed PCM
// Take bits [27:12] for 16-bit output with saturation
wire signed [31:0] final_l = HQ_ENABLE ? room_out_l : {16'd0, CHANNEL_A, 8'd0} - 32'h00800000;
wire signed [31:0] final_r = HQ_ENABLE ? room_out_r : {16'd0, CHANNEL_C, 8'd0} - 32'h00800000;

// Saturation logic
function signed [15:0] saturate;
    input signed [31:0] val;
    begin
        if (val > 32'sh0FFFFFFF)
            saturate = 16'sh7FFF;
        else if (val < -32'sh10000000)
            saturate = 16'sh8000;
        else
            saturate = val[27:12];
    end
endfunction

// Register outputs
reg audio_valid_r;
reg signed [15:0] audio_l_r, audio_r_r;

always @(posedge CLK) begin
    if (RESET) begin
        audio_valid_r <= 0;
        audio_l_r <= 0;
        audio_r_r <= 0;
    end
    else begin
        audio_valid_r <= HQ_ENABLE ? fir_valid : CE_PSG;
        if (HQ_ENABLE ? fir_valid : CE_PSG) begin
            audio_l_r <= saturate(final_l);
            audio_r_r <= saturate(final_r);
        end
    end
end

assign AUDIO_VALID = audio_valid_r;
assign AUDIO_L = audio_l_r;
assign AUDIO_R = audio_r_r;

endmodule
