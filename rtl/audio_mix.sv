//============================================================================
// Audio Mixer with Soft Limiter for MiSTer ZX Spectrum
//
// Features:
// - Wide accumulator mixing (no early clipping)
// - Piecewise linear soft limiter (transparent, no pumping)
// - Consistent loudness whether 1 or 2 AYs active
// - Proper headroom for all sources
//
// Signal flow:
//   [Sources] -> [Wide Mix] -> [Normalize] -> [Soft Limit] -> [Output]
//============================================================================

module audio_mix
(
    input             clk,
    input             reset,

    // Turbosound (2x AY mixed, 12-bit signed from turbosound.sv)
    // Note: turbosound.sv should be modified to not clip internally
    input signed [12:0] ts_l,      // Extended to 13-bit to handle 2x AY
    input signed [12:0] ts_r,

    // General Sound (15-bit signed)
    input signed [14:0] gs_l,
    input signed [14:0] gs_r,

    // SAA1099 (8-bit unsigned)
    input        [7:0] saa_l,
    input        [7:0] saa_r,

    // Beeper/tape (directly combined as 3-bit level)
    input        [2:0] beeper,     // ear_out + mic_out + tape_aud

    // Output (16-bit signed, soft-limited)
    output reg signed [15:0] out_l,
    output reg signed [15:0] out_r
);

// ============================================================================
// STAGE 1: Wide accumulator mixing with DC centering
// ============================================================================
// P0.1 FIX: All sources must be centered (zero DC) before mixing
// Otherwise the soft limiter works asymmetrically causing distortion

// Turbosound: 13-bit from turbosound.sv
// ts is unsigned PSG (0..1530) + signed FM
// PSG midpoint = 765, so center by subtracting 765<<5 = 24480
// After centering: range roughly [-24480, +24480] for PSG alone
localparam signed [17:0] TS_DC_OFFSET = 18'sd24480;  // 765 * 32

wire signed [17:0] ts_scaled_l = {ts_l, 5'b0} - TS_DC_OFFSET;
wire signed [17:0] ts_scaled_r = {ts_r, 5'b0} - TS_DC_OFFSET;

// General Sound: 15-bit signed - already centered, just sign-extend
wire signed [17:0] gs_scaled_l = {{3{gs_l[14]}}, gs_l};
wire signed [17:0] gs_scaled_r = {{3{gs_r[14]}}, gs_r};

// SAA1099: 8-bit unsigned -> center by subtracting midpoint
// Midpoint = 128, after <<8 = 32768
wire signed [17:0] saa_scaled_l = {2'b0, saa_l, 8'b0} - 18'sd32768;
wire signed [17:0] saa_scaled_r = {2'b0, saa_r, 8'b0} - 18'sd32768;

// Beeper: 3-bit unsigned (0-7) -> center by subtracting midpoint
// Midpoint = 3.5, use 4 for simplicity. After <<12 = 16384
// Range after centering: [-16384, +12288]
wire signed [17:0] beeper_scaled = ({3'b0, beeper, 12'b0} - 18'sd16384);

// Sum all sources (19 bits to handle overflow)
wire signed [18:0] sum_l = ts_scaled_l + gs_scaled_l + saa_scaled_l + beeper_scaled;
wire signed [18:0] sum_r = ts_scaled_r + gs_scaled_r + saa_scaled_r + beeper_scaled;

// ============================================================================
// STAGE 2: Normalize to 16-bit range
// ============================================================================
// Shift right by 2 to bring 18-bit range to 16-bit nominal
// Peaks may still exceed 16-bit, handled by soft limiter

wire signed [17:0] norm_l = sum_l[18:1];  // Divide by 2
wire signed [17:0] norm_r = sum_r[18:1];

// ============================================================================
// STAGE 3: Soft Limiter (piecewise linear)
// ============================================================================
// Transparent compression that catches peaks without pumping
//
// Knee points (in 16-bit positive range):
//   0 - 22937 (0.70): unity gain
//   22938 - 27852 (0.70-0.85): 2:1 ratio
//   27853 - 31129 (0.85-0.95): 4:1 ratio
//   31130+ (0.95+): hard limit at 32113 (0.98)
//
// Formula for 2:1 zone: out = 22937 + (in - 22937) / 2
// Formula for 4:1 zone: out = 27852 + (in - 27852) / 4

localparam signed [17:0] KNEE1 = 18'sd22937;   // 0.70 * 32767
localparam signed [17:0] KNEE2 = 18'sd27852;   // 0.85 * 32767
localparam signed [17:0] KNEE3 = 18'sd31129;   // 0.95 * 32767
localparam signed [17:0] LIMIT = 18'sd32113;   // 0.98 * 32767

// Output of 2:1 zone at KNEE2: 22937 + (27852-22937)/2 = 22937 + 2457 = 25394
localparam signed [17:0] OUT_K2 = 18'sd25394;
// Output of 4:1 zone at KNEE3: 25394 + (31129-27852)/4 = 25394 + 819 = 26213
localparam signed [17:0] OUT_K3 = 18'sd26213;

function signed [15:0] soft_limit;
    input signed [17:0] x;
    reg [17:0] abs_x;
    reg [17:0] abs_out;
    reg sign;
    begin
        sign = x[17];
        abs_x = sign ? -x : x;

        if (abs_x <= KNEE1) begin
            // Unity gain zone
            abs_out = abs_x;
        end
        else if (abs_x <= KNEE2) begin
            // 2:1 compression zone
            abs_out = KNEE1 + ((abs_x - KNEE1) >> 1);
        end
        else if (abs_x <= KNEE3) begin
            // 4:1 compression zone
            abs_out = OUT_K2 + ((abs_x - KNEE2) >> 2);
        end
        else begin
            // Hard limit zone (8:1 ratio, capped at LIMIT)
            abs_out = OUT_K3 + ((abs_x - KNEE3) >> 3);
            if (abs_out > LIMIT) abs_out = LIMIT;
        end

        // Apply sign and clamp to 16-bit
        soft_limit = sign ? -abs_out[15:0] : abs_out[15:0];
    end
endfunction

// ============================================================================
// OUTPUT
// ============================================================================

always @(posedge clk) begin
    if (reset) begin
        out_l <= 0;
        out_r <= 0;
    end
    else begin
        out_l <= soft_limit(norm_l);
        out_r <= soft_limit(norm_r);
    end
end

endmodule
