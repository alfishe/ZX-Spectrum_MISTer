//============================================================================
// Audio Character Processing for MiSTer ZX Spectrum
// Ported from unreal-ng audio_character_chain
//
// Provides:
// - Punch enhancement: transient designer + edge exciter
// - Room simulation: crossfeed for headphone listening
//
// Parameters matched to unreal-ng AY preset for cross-verification:
// - edgeBlend  = 0.03125 (>>5)
// - transBoost = 0.0625  (>>4 on normalized envelope)
// - attack     = 0.3125  (>>2 + >>4)
// - release    = 0.9995  (1 - >>11)
//============================================================================

module audio_character
(
    input             clk,
    input             ce,
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
// Matched to unreal-ng AY preset coefficients

// Previous sample for difference calculation
reg signed [15:0] prev_l, prev_r;

// Envelope followers (16.16 fixed point)
reg signed [31:0] env_l, env_r;

// Difference: 17 bits to handle full range without overflow
wire signed [16:0] diff_l = $signed(in_l) - $signed(prev_l);
wire signed [16:0] diff_r = $signed(in_r) - $signed(prev_r);

// Magnitude (absolute value) - clamp to 15-bit to keep envelope math in 32-bit range
// Transients larger than half-scale saturate the envelope anyway
wire [16:0] mag_raw_l = diff_l[16] ? -diff_l : diff_l;
wire [16:0] mag_raw_r = diff_r[16] ? -diff_r : diff_r;
wire [15:0] mag_l = (mag_raw_l > 17'd32767) ? 16'd32767 : mag_raw_l[15:0];
wire [15:0] mag_r = (mag_raw_r > 17'd32767) ? 16'd32767 : mag_raw_r[15:0];

// Edge component: 0.03125 blend (>>5) - matches unreal-ng AY preset
wire signed [16:0] edge_l = diff_l >>> 5;
wire signed [16:0] edge_r = diff_r >>> 5;

// Envelope follower with correct 0.3125/0.6875 blend (sum = 1.0)
// Attack:  env = mag * 0.3125 + env * 0.6875
//        = (mag>>2) + (mag>>4) + (env>>1) + (env>>3) + (env>>4)
// Release: env = env * 0.9995 = env - (env>>11)
wire [31:0] mag_l_ext = {mag_l, 16'b0};
wire [31:0] mag_r_ext = {mag_r, 16'b0};

// Attack blend: 0.3125 * mag + 0.6875 * env
// 0.3125 = 1/4 + 1/16 = 0.25 + 0.0625
// 0.6875 = 1/2 + 1/8 + 1/16 = 0.5 + 0.125 + 0.0625
wire signed [31:0] env_attack_l = (mag_l_ext >>> 2) + (mag_l_ext >>> 4) +
                                  (env_l >>> 1) + (env_l >>> 3) + (env_l >>> 4);
wire signed [31:0] env_attack_r = (mag_r_ext >>> 2) + (mag_r_ext >>> 4) +
                                  (env_r >>> 1) + (env_r >>> 3) + (env_r >>> 4);

// Release: 0.9995 = 1 - 1/2048
wire signed [31:0] env_release_l = env_l - (env_l >>> 11);
wire signed [31:0] env_release_r = env_r - (env_r >>> 11);

// Transient component: diff * normalized_env * 0.0625
// env[31:16] is integer part (0..32767 after clamp), multiply by diff, then >>4
wire signed [32:0] trans_mult_l = diff_l * $signed({1'b0, env_l[31:16]});
wire signed [32:0] trans_mult_r = diff_r * $signed({1'b0, env_r[31:16]});
wire signed [16:0] trans_l = trans_mult_l[32:16] >>> 4;
wire signed [16:0] trans_r = trans_mult_r[32:16] >>> 4;

// Punch output: input + edge + transient with saturation
wire signed [18:0] punch_sum_l = $signed({{3{in_l[15]}}, in_l}) +
                                 $signed({{2{edge_l[16]}}, edge_l}) +
                                 $signed({{2{trans_l[16]}}, trans_l});
wire signed [18:0] punch_sum_r = $signed({{3{in_r[15]}}, in_r}) +
                                 $signed({{2{edge_r[16]}}, edge_r}) +
                                 $signed({{2{trans_r[16]}}, trans_r});

// Saturate 19-bit to 16-bit
function [15:0] saturate;
    input signed [18:0] val;
    begin
        if (val > 19'sd32767)
            saturate = 16'sd32767;
        else if (val < -19'sd32768)
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
// 2ms delay = 96 samples @ 48kHz, no lowpass (preserves AY square wave harmonics)

localparam DELAY_SAMPLES = 96;
localparam DELAY_BITS = 7;

// Delay lines
reg signed [15:0] delay_l [0:127];
reg signed [15:0] delay_r [0:127];
reg [DELAY_BITS-1:0] delay_idx;

// Get delayed opposite channel
wire [DELAY_BITS-1:0] delayed_idx = delay_idx - DELAY_SAMPLES[DELAY_BITS-1:0];
wire signed [15:0] delayed_l = delay_r[delayed_idx];
wire signed [15:0] delayed_r = delay_l[delayed_idx];

// Room level selection
// -15dB = 0.178 ~ (>>3) + (>>5) = 0.15625
// -14dB = 0.20  ~ (>>3) + (>>4) = 0.1875
// -12dB = 0.25  ~ (>>2) = 0.25
// -9dB  = 0.35  ~ (>>2) + (>>4) = 0.3125
reg signed [15:0] room_contrib_l, room_contrib_r;
always @(*) begin
    case (room_level)
        2'd0: begin
            room_contrib_l = (delayed_l >>> 3) + (delayed_l >>> 5);
            room_contrib_r = (delayed_r >>> 3) + (delayed_r >>> 5);
        end
        2'd1: begin
            room_contrib_l = (delayed_l >>> 3) + (delayed_l >>> 4);
            room_contrib_r = (delayed_r >>> 3) + (delayed_r >>> 4);
        end
        2'd2: begin
            room_contrib_l = delayed_l >>> 2;
            room_contrib_r = delayed_r >>> 2;
        end
        2'd3: begin
            room_contrib_l = (delayed_l >>> 2) + (delayed_l >>> 4);
            room_contrib_r = (delayed_r >>> 2) + (delayed_r >>> 4);
        end
    endcase
end

// ============================================================================
// PROCESSING PIPELINE
// ============================================================================

// Select input to room stage
wire signed [15:0] room_in_l = punch_en ? punch_out_l : $signed(in_l);
wire signed [15:0] room_in_r = punch_en ? punch_out_r : $signed(in_r);

// Room output with saturation
wire signed [17:0] room_sum_l = $signed({{2{room_in_l[15]}}, room_in_l}) +
                                $signed({{2{room_contrib_l[15]}}, room_contrib_l});
wire signed [17:0] room_sum_r = $signed({{2{room_in_r[15]}}, room_in_r}) +
                                $signed({{2{room_contrib_r[15]}}, room_contrib_r});

// Saturate 18-bit to 16-bit
function [15:0] saturate18;
    input signed [17:0] val;
    begin
        if (val > 18'sd32767)
            saturate18 = 16'sd32767;
        else if (val < -18'sd32768)
            saturate18 = -16'sd32768;
        else
            saturate18 = val[15:0];
    end
endfunction

wire signed [15:0] room_out_l = saturate18(room_sum_l);
wire signed [15:0] room_out_r = saturate18(room_sum_r);

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

        // Envelope follower: attack if magnitude exceeds envelope, else release
        if (mag_l_ext > env_l[31:0])
            env_l <= env_attack_l;
        else
            env_l <= env_release_l;

        if (mag_r_ext > env_r[31:0])
            env_r <= env_attack_r;
        else
            env_r <= env_release_r;

        // Update delay line
        delay_l[delay_idx] <= room_in_l;
        delay_r[delay_idx] <= room_in_r;
        delay_idx <= delay_idx + 1'd1;

        // Output selection: combinational bypass for Clean mode
        if (room_en)
            {out_l, out_r} <= {room_out_l, room_out_r};
        else if (punch_en)
            {out_l, out_r} <= {punch_out_l, punch_out_r};
        else
            {out_l, out_r} <= {in_l, in_r};
    end
end

endmodule
