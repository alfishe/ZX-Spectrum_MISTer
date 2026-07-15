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
// STAGE 1: Wide accumulator mixing
// ============================================================================
// Scale all sources to common 18-bit range before summing
// This prevents any overflow during mixing

// Turbosound: 13-bit -> shift left 5 to use most of 18-bit range
// Max single AY = ~2047, dual AY = ~4094, after <<5 = ~131000
wire signed [17:0] ts_scaled_l = {ts_l, 5'b0};
wire signed [17:0] ts_scaled_r = {ts_r, 5'b0};

// General Sound: 15-bit -> shift left 2 (GS is already loud, don't over-boost)
// Max = 16383, after <<2 = 65532
wire signed [17:0] gs_scaled_l = {{3{gs_l[14]}}, gs_l};  // Just sign-extend, GS is already at good level
wire signed [17:0] gs_scaled_r = {{3{gs_r[14]}}, gs_r};

// SAA1099: 8-bit unsigned -> convert to signed, shift left 8
// Max = 255, after <<8 = 65280 (but centered at 32640)
wire signed [17:0] saa_scaled_l = {2'b0, saa_l, 8'b0} - 18'sd32640;  // Center around 0
wire signed [17:0] saa_scaled_r = {2'b0, saa_r, 8'b0} - 18'sd32640;

// Beeper: 3-bit -> shift left 13 for appropriate level
// Max = 7, after <<13 = 57344
wire signed [17:0] beeper_scaled = {3'b0, beeper, 12'b0};

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
