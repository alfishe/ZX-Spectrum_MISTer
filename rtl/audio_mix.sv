//============================================================================
// Audio Mixer with DC Blocker, Gain Staging, and Soft Limiter
// for MiSTer ZX Spectrum
//
// Features:
// - DC blocker (leaky integrator) for unipolar sources
// - Activity-dependent gain staging (no limiter pumping)
// - Wide accumulator mixing (no early clipping)
// - Piecewise linear soft limiter (emergency only)
//
// Signal flow:
//   [Sources] -> [Scale] -> [DC Block] -> [Activity Detect] ->
//   [Gain Stage] -> [Wide Mix] -> [Soft Limit] -> [Output]
//
// Relative levels matched to master:
//   TS:     <<5 (13-bit -> 18-bit)
//   GS:     sign-extend (15-bit -> 18-bit, effectively <<3)
//   SAA:    <<7 (8-bit -> 15-bit in 18-bit field)
//   Beeper: <<7 (7-bit boxcar sum -> 14-bit in 18-bit field)
//
// Note: Even in "Clean" mode (no punch/room), this mixer differs from
// master in two intentional ways:
// - DC blocker removes unipolar offset (master carries DC to framework)
// - Gain staging reduces level with multiple sources (master clips)
// These are improvements, not bugs. For A/B testing vs master:
// - Use single source only, or
// - Apply >10Hz HPF to both signals before comparison
//============================================================================

module audio_mix
(
    input             clk,
    input             reset,
    input             ce,          // 48kHz CE for gain smoothing

    // Turbosound (2x AY mixed, 13-bit signed from turbosound.sv)
    input signed [12:0] ts_l,
    input signed [12:0] ts_r,

    // General Sound (15-bit signed)
    input signed [14:0] gs_l,
    input signed [14:0] gs_r,

    // SAA1099 (8-bit unsigned)
    input        [7:0] saa_l,
    input        [7:0] saa_r,

    // Beeper (7-bit boxcar sum of 16 samples)
    input        [6:0] beeper,

    // Output (16-bit signed, soft-limited)
    output reg signed [15:0] out_l,
    output reg signed [15:0] out_r
);

// ============================================================================
// STAGE 1: Scale all sources (matched to master levels)
// ============================================================================

// Turbosound: 13-bit signed -> <<5 to 18-bit
wire signed [17:0] ts_scaled_l = {ts_l, 5'b0};
wire signed [17:0] ts_scaled_r = {ts_r, 5'b0};

// General Sound: 15-bit signed -> sign-extend to 18-bit (<<3 effective)
wire signed [17:0] gs_scaled_l = {{3{gs_l[14]}}, gs_l};
wire signed [17:0] gs_scaled_r = {{3{gs_r[14]}}, gs_r};

// SAA1099: 8-bit unsigned -> <<7 (was <<8, -6dB to match master)
wire signed [17:0] saa_scaled_l = {3'b0, saa_l, 7'b0};
wire signed [17:0] saa_scaled_r = {3'b0, saa_r, 7'b0};

// Beeper: 7-bit boxcar sum -> <<7 (was 3-bit <<12, now 7-bit <<7 = same range)
// boxcar gives 16x, so <<7 instead of <<11 to match master's <<10 for raw 3-bit
wire signed [17:0] beeper_scaled = {4'b0, beeper, 7'b0};

// ============================================================================
// STAGE 2: DC Blocker (leaky integrator)
// ============================================================================
// One-pole highpass at ~2.1 Hz (K=22 at 56MHz)
// Automatically centers unipolar sources regardless of activity

reg signed [39:0] ts_dc_acc_l, ts_dc_acc_r;
wire signed [17:0] ts_dc_l = ts_dc_acc_l[39:22];
wire signed [17:0] ts_dc_r = ts_dc_acc_r[39:22];
wire signed [17:0] ts_centered_l = ts_scaled_l - ts_dc_l;
wire signed [17:0] ts_centered_r = ts_scaled_r - ts_dc_r;

reg signed [39:0] saa_dc_acc_l, saa_dc_acc_r;
wire signed [17:0] saa_dc_l = saa_dc_acc_l[39:22];
wire signed [17:0] saa_dc_r = saa_dc_acc_r[39:22];
wire signed [17:0] saa_centered_l = saa_scaled_l - saa_dc_l;
wire signed [17:0] saa_centered_r = saa_scaled_r - saa_dc_r;

reg signed [39:0] beeper_dc_acc;
wire signed [17:0] beeper_dc = beeper_dc_acc[39:22];
wire signed [17:0] beeper_centered = beeper_scaled - beeper_dc;

// GS is already centered (signed)

always @(posedge clk) begin
    if (reset) begin
        ts_dc_acc_l <= 0;
        ts_dc_acc_r <= 0;
        saa_dc_acc_l <= 0;
        saa_dc_acc_r <= 0;
        beeper_dc_acc <= 0;
    end
    else begin
        ts_dc_acc_l <= ts_dc_acc_l + {{22{ts_centered_l[17]}}, ts_centered_l};
        ts_dc_acc_r <= ts_dc_acc_r + {{22{ts_centered_r[17]}}, ts_centered_r};
        saa_dc_acc_l <= saa_dc_acc_l + {{22{saa_centered_l[17]}}, saa_centered_l};
        saa_dc_acc_r <= saa_dc_acc_r + {{22{saa_centered_r[17]}}, saa_centered_r};
        beeper_dc_acc <= beeper_dc_acc + {{22{beeper_centered[17]}}, beeper_centered};
    end
end

// ============================================================================
// STAGE 3: Activity Detection
// ============================================================================
// Peak follower with slow decay (~0.5s at 48kHz)
// Detects actual signal activity, not just "enabled in OSD"

localparam [17:0] ACT_THRESH = 18'd512;  // ~-40dB relative to full scale

// Magnitude of centered signals (for activity detection)
wire [17:0] ts_mag_l = ts_centered_l[17] ? -ts_centered_l : ts_centered_l;
wire [17:0] ts_mag_r = ts_centered_r[17] ? -ts_centered_r : ts_centered_r;
wire [17:0] ts_mag = (ts_mag_l > ts_mag_r) ? ts_mag_l : ts_mag_r;

wire [17:0] gs_mag_l = gs_scaled_l[17] ? -gs_scaled_l : gs_scaled_l;
wire [17:0] gs_mag_r = gs_scaled_r[17] ? -gs_scaled_r : gs_scaled_r;
wire [17:0] gs_mag = (gs_mag_l > gs_mag_r) ? gs_mag_l : gs_mag_r;

wire [17:0] saa_mag_l = saa_centered_l[17] ? -saa_centered_l : saa_centered_l;
wire [17:0] saa_mag_r = saa_centered_r[17] ? -saa_centered_r : saa_centered_r;
wire [17:0] saa_mag = (saa_mag_l > saa_mag_r) ? saa_mag_l : saa_mag_r;

wire [17:0] beeper_mag = beeper_centered[17] ? -beeper_centered : beeper_centered;

// Activity envelopes (peak followers)
reg [17:0] ts_env, gs_env, saa_env, beeper_env;

// Guaranteed decrement: (env>>15)+1 ensures decay reaches zero
// Without +1, env < 32768 gives decrement=0 and envelope freezes forever
wire [17:0] ts_dec = (ts_env >> 15) + 18'd1;
wire [17:0] gs_dec = (gs_env >> 15) + 18'd1;
wire [17:0] saa_dec = (saa_env >> 15) + 18'd1;
wire [17:0] beeper_dec = (beeper_env >> 15) + 18'd1;

always @(posedge clk) begin
    if (reset) begin
        ts_env <= 0;
        gs_env <= 0;
        saa_env <= 0;
        beeper_env <= 0;
    end
    else if (ce) begin
        // Attack instant, release ~0.5s with guaranteed decay to zero
        ts_env <= (ts_mag > ts_env) ? ts_mag : ((ts_env > ts_dec) ? ts_env - ts_dec : 18'd0);
        gs_env <= (gs_mag > gs_env) ? gs_mag : ((gs_env > gs_dec) ? gs_env - gs_dec : 18'd0);
        saa_env <= (saa_mag > saa_env) ? saa_mag : ((saa_env > saa_dec) ? saa_env - saa_dec : 18'd0);
        beeper_env <= (beeper_mag > beeper_env) ? beeper_mag : ((beeper_env > beeper_dec) ? beeper_env - beeper_dec : 18'd0);
    end
end

// Activity flags
wire ts_active = (ts_env > ACT_THRESH);
wire gs_active = (gs_env > ACT_THRESH);
wire saa_active = (saa_env > ACT_THRESH);
wire beeper_active = (beeper_env > ACT_THRESH);

// ============================================================================
// STAGE 4: Gain Staging
// ============================================================================
// Target gain based on active source count
// Goal: nominal sum of active sources fits in ~0.9 FS
//
// Worst-case amplitudes (18-bit scaled, centered):
//   TS alone:     ~49000 (2x AY full)
//   TS+GS:        ~65000
//   TS+GS+SAA:    ~81000
//   All four:     ~97000
//
// Target gains (16.16 fixed point, 1.0 = 65536):
//   1 source:  1.0    = 65536  (>>0)
//   2 sources: 0.625  = 40960  (>>1 + >>3)
//   3 sources: 0.5    = 32768  (>>1)
//   4 sources: 0.375  = 24576  (>>2 + >>3)

reg [16:0] gain_target;
wire [2:0] active_count = {2'b0, ts_active} + {2'b0, gs_active} +
                          {2'b0, saa_active} + {2'b0, beeper_active};

always @(*) begin
    case (active_count)
        3'd0: gain_target = 17'd65536;  // Unity (nothing active = pass through)
        3'd1: gain_target = 17'd65536;  // Unity
        3'd2: gain_target = 17'd40960;  // 0.625
        3'd3: gain_target = 17'd32768;  // 0.5
        default: gain_target = 17'd24576;  // 0.375 (4 sources)
    endcase
end

// Smoothed gain (one-pole, tau ~85ms at 48kHz)
// gain_cur is unsigned 17-bit (0..65536 = 0.0..1.0 in 16.16 fixed point)
reg [16:0] gain_cur;
wire signed [17:0] gain_delta = $signed({1'b0, gain_target}) - $signed({1'b0, gain_cur});

always @(posedge clk) begin
    if (reset) begin
        gain_cur <= 17'd65536;  // Start at unity
    end
    else if (ce) begin
        // Rounding: +2048 ensures upward slew reaches target exactly
        // Without it, positive delta < 4096 gives shift result 0
        gain_cur <= gain_cur + ((gain_delta + 18'sd2048) >>> 12);
    end
end

// ============================================================================
// STAGE 5: Wide accumulator mixing with gain
// ============================================================================

// Raw sum (19 bits)
wire signed [18:0] sum_raw_l = ts_centered_l + gs_scaled_l + saa_centered_l + beeper_centered;
wire signed [18:0] sum_raw_r = ts_centered_r + gs_scaled_r + saa_centered_r + beeper_centered;

// Apply gain (19 * 17 = 36 bits)
// gain_cur is 16.16 fixed point, so divide by 2^16 to get result
// Take [34:17] for 18-bit result (sum * gain / 2^16 / 2 = sum * gain / 2^17)
// This matches master's /2 normalization at unity gain
wire signed [35:0] sum_gained_l = sum_raw_l * $signed({1'b0, gain_cur});
wire signed [35:0] sum_gained_r = sum_raw_r * $signed({1'b0, gain_cur});

wire signed [17:0] norm_l = sum_gained_l[34:17];
wire signed [17:0] norm_r = sum_gained_r[34:17];

// ============================================================================
// STAGE 6: Soft Limiter (emergency only)
// ============================================================================
// With proper gain staging, signals rarely hit the knees
// Limiter catches transient peaks that slip through

localparam signed [17:0] KNEE1 = 18'sd22937;  // 0.70
localparam signed [17:0] KNEE2 = 18'sd27852;  // 0.85
localparam signed [17:0] KNEE3 = 18'sd31129;  // 0.95
localparam signed [17:0] LIMIT = 18'sd32113;  // 0.98

localparam signed [17:0] OUT_K2 = 18'sd25394;
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
            abs_out = abs_x;
        end
        else if (abs_x <= KNEE2) begin
            abs_out = KNEE1 + ((abs_x - KNEE1) >> 1);
        end
        else if (abs_x <= KNEE3) begin
            abs_out = OUT_K2 + ((abs_x - KNEE2) >> 2);
        end
        else begin
            abs_out = OUT_K3 + ((abs_x - KNEE3) >> 3);
            if (abs_out > LIMIT) abs_out = LIMIT;
        end

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
