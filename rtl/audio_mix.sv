//============================================================================
// Audio Mixer with DC Blocker and Soft Limiter for MiSTer ZX Spectrum
//
// Features:
// - DC blocker (leaky integrator) for unipolar sources
// - Wide accumulator mixing (no early clipping)
// - Piecewise linear soft limiter (transparent, no pumping)
// - Consistent loudness whether 1 or 2 AYs active
//
// Signal flow:
//   [Sources] -> [Scale] -> [DC Block] -> [Wide Mix] -> [Soft Limit] -> [Output]
//============================================================================

module audio_mix
(
    input             clk,
    input             reset,

    // Turbosound (2x AY mixed, 13-bit signed from turbosound.sv)
    input signed [12:0] ts_l,
    input signed [12:0] ts_r,

    // General Sound (15-bit signed)
    input signed [14:0] gs_l,
    input signed [14:0] gs_r,

    // SAA1099 (8-bit unsigned)
    input        [7:0] saa_l,
    input        [7:0] saa_r,

    // Beeper/tape (directly combined as 3-bit level)
    input        [2:0] beeper,

    // Output (16-bit signed, soft-limited)
    output reg signed [15:0] out_l,
    output reg signed [15:0] out_r
);

// ============================================================================
// STAGE 1: Scale all sources to common 18-bit range
// ============================================================================

// Turbosound: 13-bit signed -> shift left 5 to use most of 18-bit range
wire signed [17:0] ts_scaled_l = {ts_l, 5'b0};
wire signed [17:0] ts_scaled_r = {ts_r, 5'b0};

// General Sound: 15-bit signed -> sign-extend to 18-bit
wire signed [17:0] gs_scaled_l = {{3{gs_l[14]}}, gs_l};
wire signed [17:0] gs_scaled_r = {{3{gs_r[14]}}, gs_r};

// SAA1099: 8-bit unsigned -> shift left 8, treat as unsigned for now
wire signed [17:0] saa_scaled_l = {2'b0, saa_l, 8'b0};
wire signed [17:0] saa_scaled_r = {2'b0, saa_r, 8'b0};

// Beeper: 3-bit unsigned -> shift left 12
wire signed [17:0] beeper_scaled = {3'b0, beeper, 12'b0};

// ============================================================================
// STAGE 2: DC Blocker (leaky integrator)
// ============================================================================
// One-pole highpass: y = x - avg; avg += (x - avg) >> K
// At clk_aud 56MHz: K=22 -> fc = 56e6/(2*pi*2^22) ~ 2.1 Hz
// This automatically centers any unipolar source regardless of activity level
//
// Each accumulator is 40-bit: [39:22] is the DC estimate, lower bits are fraction

// Turbosound DC blocker (PSG is unipolar 0..1530, FM is bipolar)
reg signed [39:0] ts_dc_acc_l, ts_dc_acc_r;
wire signed [17:0] ts_dc_l = ts_dc_acc_l[39:22];
wire signed [17:0] ts_dc_r = ts_dc_acc_r[39:22];
wire signed [17:0] ts_centered_l = ts_scaled_l - ts_dc_l;
wire signed [17:0] ts_centered_r = ts_scaled_r - ts_dc_r;

// SAA1099 DC blocker (unipolar 0..255)
reg signed [39:0] saa_dc_acc_l, saa_dc_acc_r;
wire signed [17:0] saa_dc_l = saa_dc_acc_l[39:22];
wire signed [17:0] saa_dc_r = saa_dc_acc_r[39:22];
wire signed [17:0] saa_centered_l = saa_scaled_l - saa_dc_l;
wire signed [17:0] saa_centered_r = saa_scaled_r - saa_dc_r;

// Beeper DC blocker (unipolar 0..7)
reg signed [39:0] beeper_dc_acc;
wire signed [17:0] beeper_dc = beeper_dc_acc[39:22];
wire signed [17:0] beeper_centered = beeper_scaled - beeper_dc;

// General Sound is already centered (signed), no DC blocker needed

// DC blocker update (leaky integrator with K=22)
always @(posedge clk) begin
    if (reset) begin
        ts_dc_acc_l <= 0;
        ts_dc_acc_r <= 0;
        saa_dc_acc_l <= 0;
        saa_dc_acc_r <= 0;
        beeper_dc_acc <= 0;
    end
    else begin
        // Update DC estimates: acc += (x - dc) = acc + x_centered
        // Sign-extend 18-bit centered value to 40-bit before adding
        ts_dc_acc_l <= ts_dc_acc_l + {{22{ts_centered_l[17]}}, ts_centered_l};
        ts_dc_acc_r <= ts_dc_acc_r + {{22{ts_centered_r[17]}}, ts_centered_r};
        saa_dc_acc_l <= saa_dc_acc_l + {{22{saa_centered_l[17]}}, saa_centered_l};
        saa_dc_acc_r <= saa_dc_acc_r + {{22{saa_centered_r[17]}}, saa_centered_r};
        beeper_dc_acc <= beeper_dc_acc + {{22{beeper_centered[17]}}, beeper_centered};
    end
end

// ============================================================================
// STAGE 3: Wide accumulator mixing
// ============================================================================

// Sum all DC-blocked sources (19 bits to handle overflow)
wire signed [18:0] sum_l = ts_centered_l + gs_scaled_l + saa_centered_l + beeper_centered;
wire signed [18:0] sum_r = ts_centered_r + gs_scaled_r + saa_centered_r + beeper_centered;

// ============================================================================
// STAGE 4: Normalize to 16-bit range
// ============================================================================
// Shift right by 2 to bring 18-bit range to 16-bit nominal

wire signed [17:0] norm_l = sum_l[18:1];
wire signed [17:0] norm_r = sum_r[18:1];

// ============================================================================
// STAGE 5: Soft Limiter (piecewise linear)
// ============================================================================
// Transparent compression that catches peaks without pumping
//
// Knee points (in 16-bit positive range):
//   0 - 22937 (0.70): unity gain
//   22938 - 27852 (0.70-0.85): 2:1 ratio
//   27853 - 31129 (0.85-0.95): 4:1 ratio
//   31130+ (0.95+): 8:1 ratio capped at 32113 (0.98)

localparam signed [17:0] KNEE1 = 18'sd22937;
localparam signed [17:0] KNEE2 = 18'sd27852;
localparam signed [17:0] KNEE3 = 18'sd31129;
localparam signed [17:0] LIMIT = 18'sd32113;

// Output of 2:1 zone at KNEE2: 22937 + (27852-22937)/2 = 25394
localparam signed [17:0] OUT_K2 = 18'sd25394;
// Output of 4:1 zone at KNEE3: 25394 + (31129-27852)/4 = 26213
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
