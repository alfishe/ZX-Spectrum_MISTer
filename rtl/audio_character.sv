//============================================================================
// Audio Character Processing for MiSTer ZX Spectrum
// Ported from unreal-ng audio_character_chain
//
// Provides:
// - Punch enhancement: transient designer + edge exciter
// - Room simulation: crossfeed for headphone listening
//
// Insert between audio mix and compressor in ZX-Spectrum.sv
//============================================================================

module audio_character
(
    input             clk,         // Audio clock (clk_aud / 56MHz)
    input             ce,          // Clock enable for ~48kHz processing
    input             reset,

    // Mode selection from OSD
    input       [1:0] mode,        // 0=Clean, 1=Punch, 2=Room, 3=Punch+Room
    input       [1:0] room_level,  // 0=-15dB, 1=-14dB, 2=-12dB, 3=-9dB

    // Audio I/O (16-bit signed)
    input      [15:0] in_l,
    input      [15:0] in_r,
    output reg [15:0] out_l,
    output reg [15:0] out_r
);

// Mode decode
wire punch_en = mode[0];
wire room_en  = mode[1];

// ============================================================================
// PUNCH ENHANCEMENT
// ============================================================================
// Hybrid transient designer + exciter for AY/beeper
// - Edge: constant +6dB/oct tilt via first difference
// - Transient: envelope-gated boost on attacks
//
// AY preset (gentler - square waves already have harmonics):
//   edgeBlend  = 0.03  -> (diff>>5) + (diff>>7) = 0.0391
//   transBoost = 0.1   -> (diff*env)>>3 + ((diff*env)>>5) = 0.125 + 0.03125
//   release    = 0.9995 -> env - (env>>11) = 0.99951

// Fixed-point: 16.16 for envelope, coefficients in shifts
reg signed [15:0] prev_l, prev_r;
reg signed [31:0] env_l, env_r;  // 16.16 fixed point envelope

wire signed [15:0] diff_l = $signed(in_l) - prev_l;
wire signed [15:0] diff_r = $signed(in_r) - prev_r;

// Magnitude (abs value)
wire [15:0] mag_l = diff_l[15] ? -diff_l : diff_l;
wire [15:0] mag_r = diff_r[15] ? -diff_r : diff_r;

// Edge component: ~0.03 blend -> (x>>5) ~= 0.03125
wire signed [15:0] edge_l = diff_l >>> 5;
wire signed [15:0] edge_r = diff_r >>> 5;

// Envelope follower attack/release
// Attack: env = mag * 0.3 + env * 0.7 when mag > env
//       -> ({mag,16'b0}>>2) + (env>>1) + (env>>3)  = 0.25 + 0.5 + 0.125 = 0.875 (too high)
//       -> better: (mag<<15) + (env>>1) ~= 50% attack
// Release: env = env * 0.9995 ~= env - (env>>11)
wire signed [31:0] mag_l_ext = {mag_l, 16'b0};
wire signed [31:0] mag_r_ext = {mag_r, 16'b0};

wire signed [31:0] env_attack_l = (mag_l_ext >>> 2) + (env_l >>> 1) + (env_l >>> 2);
wire signed [31:0] env_attack_r = (mag_r_ext >>> 2) + (env_r >>> 1) + (env_r >>> 2);
wire signed [31:0] env_release_l = env_l - (env_l >>> 11);
wire signed [31:0] env_release_r = env_r - (env_r >>> 11);

// Transient component: diff * env * ~0.1
// env is 16.16, we want result in 16-bit
// (diff * env[31:16]) >> 3 ~= 0.125 boost
wire signed [31:0] trans_mult_l = diff_l * env_l[31:16];
wire signed [31:0] trans_mult_r = diff_r * env_r[31:16];
wire signed [15:0] trans_l = trans_mult_l[31:16] >>> 3;
wire signed [15:0] trans_r = trans_mult_r[31:16] >>> 3;

// Punch output with saturation
wire signed [17:0] punch_sum_l = $signed({in_l[15], in_l[15], in_l}) + $signed({edge_l[15], edge_l[15], edge_l}) + $signed({trans_l[15], trans_l[15], trans_l});
wire signed [17:0] punch_sum_r = $signed({in_r[15], in_r[15], in_r}) + $signed({edge_r[15], edge_r[15], edge_r}) + $signed({trans_r[15], trans_r[15], trans_r});

// Saturate to 16-bit
function [15:0] saturate;
    input signed [17:0] val;
    begin
        if (val > 18'sd32767)
            saturate = 16'sd32767;
        else if (val < -18'sd32768)
            saturate = -16'sd32768;
        else
            saturate = val[15:0];
    end
endfunction

wire signed [15:0] punch_out_l = saturate(punch_sum_l);
wire signed [15:0] punch_out_r = saturate(punch_sum_r);

// ============================================================================
// ROOM SIMULATION
// ============================================================================
// Delayed opposite-channel crossfeed for headphone listening
// Reduces stereo fatigue from hard L-R panning (AY ABC/ACB)
//
// Parameters for AY (preserve square wave harmonics):
// - 2ms delay = 96 samples @ 48kHz (no lowpass - AY needs harmonics)
// - Level: -15dB to -9dB selectable

localparam DELAY_SAMPLES = 96;  // 2ms @ 48kHz
localparam DELAY_BITS = 7;      // log2(128) covers 96

// Delay lines (single M10K BRAM)
reg signed [15:0] delay_l [0:127];
reg signed [15:0] delay_r [0:127];
reg [DELAY_BITS-1:0] delay_idx;

// Get delayed opposite channel
wire [DELAY_BITS-1:0] delayed_idx = delay_idx - DELAY_SAMPLES[DELAY_BITS-1:0];
wire signed [15:0] delayed_l = delay_r[delayed_idx];  // R->L crossfeed
wire signed [15:0] delayed_r = delay_l[delayed_idx];  // L->R crossfeed

// Room level selection (linear coefficients as shifts)
// -15dB = 0.178 ~= 1/6 ~= (x>>3) + (x>>5) = 0.125 + 0.03125 = 0.15625
// -14dB = 0.20  ~= 1/5 ~= (x>>3) + (x>>4) = 0.125 + 0.0625 = 0.1875
// -12dB = 0.25  ~= 1/4 ~= (x>>2) = 0.25
// -9dB  = 0.35  ~= 1/3 ~= (x>>2) + (x>>4) = 0.25 + 0.0625 = 0.3125

reg signed [15:0] room_contrib_l, room_contrib_r;
always @(*) begin
    case (room_level)
        2'd0: begin  // -15dB
            room_contrib_l = (delayed_l >>> 3) + (delayed_l >>> 5);
            room_contrib_r = (delayed_r >>> 3) + (delayed_r >>> 5);
        end
        2'd1: begin  // -14dB (recommended)
            room_contrib_l = (delayed_l >>> 3) + (delayed_l >>> 4);
            room_contrib_r = (delayed_r >>> 3) + (delayed_r >>> 4);
        end
        2'd2: begin  // -12dB
            room_contrib_l = delayed_l >>> 2;
            room_contrib_r = delayed_r >>> 2;
        end
        2'd3: begin  // -9dB
            room_contrib_l = (delayed_l >>> 2) + (delayed_l >>> 4);
            room_contrib_r = (delayed_r >>> 2) + (delayed_r >>> 4);
        end
    endcase
end

// ============================================================================
// PROCESSING PIPELINE
// ============================================================================

// Select input to room stage (punch output if enabled, else raw input)
wire signed [15:0] room_in_l = punch_en ? punch_out_l : $signed(in_l);
wire signed [15:0] room_in_r = punch_en ? punch_out_r : $signed(in_r);

// Room output with saturation
wire signed [17:0] room_sum_l = $signed({room_in_l[15], room_in_l[15], room_in_l}) + $signed({room_contrib_l[15], room_contrib_l[15], room_contrib_l});
wire signed [17:0] room_sum_r = $signed({room_in_r[15], room_in_r[15], room_in_r}) + $signed({room_contrib_r[15], room_contrib_r[15], room_contrib_r});

wire signed [15:0] room_out_l = saturate(room_sum_l);
wire signed [15:0] room_out_r = saturate(room_sum_r);

always @(posedge clk) begin
    if (reset) begin
        prev_l <= 0;
        prev_r <= 0;
        env_l <= 0;
        env_r <= 0;
        delay_idx <= 0;
        out_l <= 0;
        out_r <= 0;
    end
    else if (ce) begin
        // Update punch state
        prev_l <= $signed(in_l);
        prev_r <= $signed(in_r);

        // Envelope follower
        if (mag_l_ext > env_l)
            env_l <= env_attack_l;
        else
            env_l <= env_release_l;

        if (mag_r_ext > env_r)
            env_r <= env_attack_r;
        else
            env_r <= env_release_r;

        // Update delay line
        delay_l[delay_idx] <= room_in_l;
        delay_r[delay_idx] <= room_in_r;
        delay_idx <= delay_idx + 1'd1;

        // Output selection
        if (room_en)
            {out_l, out_r} <= {room_out_l, room_out_r};
        else if (punch_en)
            {out_l, out_r} <= {punch_out_l, punch_out_r};
        else
            {out_l, out_r} <= {in_l, in_r};
    end
end

endmodule
