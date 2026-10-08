//
// AY-3-8910 Tone Voicing (fixed tonal-balance EQ)
//
// Port of unreal-ng FilterVoicing: per profile up to three biquad sections
// (optional high-pass, optional peaking EQ, optional low-pass), run in that
// order on each channel. It sits between the FIR and the punch enhancer, as
// in unreal-ng (voicing before the character chain).
//
// Profiles (unreal-ng order and IDs):
//   0 Flat          no processing (exact bypass)
//   1 Classic       64.2 Hz 1st-order HPF + 106.9 Hz / +3.06 dB peak, Q 1
//                   (the bass balance of the old moving-average DC remover)
//   2 Headphones    Classic + 10 kHz low-pass (Q 0.5)
//   3 Warm          90 Hz 2nd-order HPF (Q 0.6) + 8 kHz low-pass (Q 0.5)
//   4 TV            130 Hz HPF + 6 kHz LPF (2nd-order Butterworth)
//   5 Small speaker 250 Hz HPF + 1.5 kHz / +3 dB peak + 4.5 kHz LPF
//
// The coefficients are unreal-ng's own design (FilterVoicing::design(),
// bilinear HPF, RBJ peak, magnitude-matched LPF) evaluated at the generator
// rate 218.75 kHz, in Q2.30. Unused sections are identity (b0 = 1.0).
// High-pass rows keep b1 = -(b0 + b2) exactly after quantisation, so their
// zeros stay at z = 1 (no DC leak).
//
// Each section computes, in direct form I:
//   y = b0 x + b1 x1 + b2 x2 - a1 y1 - a2 y2
// Ports are Q4.28. Inside, samples and section state are Q6.40 (46 bits): with
// poles near z = 1 (64 Hz at 218.75 kHz) the rounding noise of each section
// is amplified ~10^3 times, which at Q.28 reached ~0.9 LSB of the 16-bit
// output; 12 more fraction bits put it ~4000x lower. The accumulator keeps
// the full Q.70 sum of products and rounds once per section.
//
// One shared 32x32 multiplier: 6 clocks per section (5 MAC + round), three
// sections per channel, two channels: outputs are stable LATENCY clocks after
// ce. A profile change clears the filter state (as FilterVoicing::setPreset).
//
// Copyright (c) 2025 - Port from unreal-ng emulator
//

module ay_voicing
(
    input  wire        clk,
    input  wire        ce,             // input sample valid (generator rate)
    input  wire        reset,
    input  wire [2:0]  preset,         // 0..5, see above (6, 7 = Flat)

    input  wire signed [31:0] in_left,     // Q4.28
    input  wire signed [31:0] in_right,
    output reg  signed [31:0] out_left,    // Q4.28
    output reg  signed [31:0] out_right
);

localparam LATENCY = 40;   // clocks from ce to stable outputs (worst case 38)

// {b0, b1, b2, a1, a2} in Q2.30 per (profile, section): generated from
// unreal-ng FilterVoicing at 218750 Hz
function [159:0] voicing_coef;
    input [4:0] row;
    begin
        case (row)
            5'd0: voicing_coef = {32'sd1073741824, 32'sd0, 32'sd0, 32'sd0, 32'sd0}; // flat (identity)
            5'd1: voicing_coef = {32'sd1073741824, 32'sd0, 32'sd0, 32'sd0, 32'sd0}; // flat (identity)
            5'd2: voicing_coef = {32'sd1073741824, 32'sd0, 32'sd0, 32'sd0, 32'sd0}; // flat (identity)
            5'd3: voicing_coef = {32'sd1072752732, -32'sd1072752732, 32'sd0, -32'sd1071763640, 32'sd0}; // classic HPF
            5'd4: voicing_coef = {32'sd1074324827, -32'sd2144712642, 32'sd1070397925, -32'sd2144712642, 32'sd1070980928}; // classic peak
            5'd5: voicing_coef = {32'sd1073741824, 32'sd0, 32'sd0, 32'sd0, 32'sd0}; // classic (identity)
            5'd6: voicing_coef = {32'sd1072752732, -32'sd1072752732, 32'sd0, -32'sd1071763640, 32'sd0}; // headphones HPF
            5'd7: voicing_coef = {32'sd1074324827, -32'sd2144712642, 32'sd1070397925, -32'sd2144712642, 32'sd1070980928}; // headphones peak
            5'd8: voicing_coef = {32'sd52849607, 32'sd14077846, 32'sd0, -32'sd1611338874, 32'sd604524502}; // headphones LPF
            5'd9: voicing_coef = {32'sd1071431917, -32'sd2142863834, 32'sd1071431917, -32'sd2142860253, 32'sd1069125589}; // warm HPF
            5'd10: voicing_coef = {32'sd35719397, 32'sd9534832, 32'sd0, -32'sd1706614695, 32'sd678127100}; // warm LPF
            5'd11: voicing_coef = {32'sd1073741824, 32'sd0, 32'sd0, 32'sd0, 32'sd0}; // warm (identity)
            5'd12: voicing_coef = {32'sd1070910491, -32'sd2141820982, 32'sd1070910491, -32'sd2141813516, 32'sd1068086624}; // tv HPF
            5'd13: voicing_coef = {32'sd22263872, 32'sd5968138, 32'sd0, -32'sd1887003624, 32'sd841493810}; // tv LPF
            5'd14: voicing_coef = {32'sd1073741824, 32'sd0, 32'sd0, 32'sd0, 32'sd0}; // tv (identity)
            5'd15: voicing_coef = {32'sd1068303580, -32'sd2136607160, 32'sd1068303580, -32'sd2136579616, 32'sd1062892878}; // small_speaker HPF
            5'd16: voicing_coef = {32'sd1081625397, -32'sd2107306343, 32'sd1027638348, -32'sd2107306343, 32'sd1035521920}; // small_speaker peak
            5'd17: voicing_coef = {32'sd12911340, 32'sd3460416, 32'sd0, -32'sd1951731704, 32'sd894361636}; // small_speaker LPF
            default: voicing_coef = {32'sd1073741824, 32'sd0, 32'sd0, 32'sd0, 32'sd0};
        endcase
    end
endfunction

// Section state, index = channel * 3 + section
reg signed [45:0] x1 [0:5];
reg signed [45:0] x2 [0:5];
reg signed [45:0] y1 [0:5];
reg signed [45:0] y2 [0:5];

reg  [2:0]  preset_r;
reg  [1:0]  state;
reg         ch;
reg  [1:0]  sec;
reg  [2:0]  term;
reg signed [45:0] v;            // current section input, Q6.40
reg signed [31:0] in_r_hold;    // right input, latched at ce
reg signed [81:0] acc;          // Q.70

localparam S_IDLE = 2'd0;
localparam S_MAC  = 2'd1;
localparam S_FIN  = 2'd2;

wire [2:0]   prof = (preset_r > 3'd5) ? 3'd0 : preset_r;
wire [4:0]   row  = prof * 3 + sec;
wire [159:0] coefs = voicing_coef(row);
wire [2:0]   idx  = {1'b0, sec} + (ch ? 3'd3 : 3'd0);

wire signed [31:0] c_term = (term == 3'd0) ? $signed(coefs[159:128]) :
                            (term == 3'd1) ? $signed(coefs[127:96])  :
                            (term == 3'd2) ? $signed(coefs[95:64])   :
                            (term == 3'd3) ? $signed(coefs[63:32])   :
                                             $signed(coefs[31:0]);
wire signed [45:0] op     = (term == 3'd0) ? v :
                            (term == 3'd1) ? x1[idx] :
                            (term == 3'd2) ? x2[idx] :
                            (term == 3'd3) ? y1[idx] :
                                             y2[idx];
wire signed [77:0] prod = c_term * op;

// Round Q.70 -> Q6.40 (section output / state) and saturate to 46 bits
wire signed [81:0] acc_rnd = acc + 82'sd536870912;
wire signed [51:0] y_full  = acc_rnd[81:30];
wire signed [45:0] y_sat   = (y_full > 52'sh001FFFFFFFFFFF) ? 46'sh1FFFFFFFFFFF :
                             (y_full < -52'sh00200000000000) ? -46'sh200000000000 :
                             y_full[45:0];

// Port output: Q6.40 -> Q4.28, rounded and saturated to 32 bits
wire signed [45:0] y_out_rnd = y_sat + 46'sd2048;
wire signed [33:0] y_out_full = y_out_rnd[45:12];
wire signed [31:0] y_out = (y_out_full > 34'sh07FFFFFFF) ? 32'sh7FFFFFFF :
                           (y_out_full < -34'sh080000000) ? -32'sh80000000 :
                           y_out_full[31:0];

wire signed [45:0] in_l_wide = {{2{in_left[31]}}, in_left, 12'd0};
wire signed [45:0] in_r_wide = {{2{in_r_hold[31]}}, in_r_hold, 12'd0};

integer k;
always @(posedge clk) begin
    if (reset) begin
        state <= S_IDLE;
        preset_r <= 3'd0;
        out_left <= 0;
        out_right <= 0;
        acc <= 0;
        for (k = 0; k < 6; k = k + 1) begin
            x1[k] <= 0; x2[k] <= 0; y1[k] <= 0; y2[k] <= 0;
        end
    end
    else begin
        case (state)
            S_IDLE: begin
                if (ce) begin
                    // A profile change restarts the filters from a clear state
                    if (preset != preset_r) begin
                        for (k = 0; k < 6; k = k + 1) begin
                            x1[k] <= 0; x2[k] <= 0; y1[k] <= 0; y2[k] <= 0;
                        end
                    end
                    preset_r <= preset;
                    v <= in_l_wide;
                    in_r_hold <= in_right;
                    ch <= 1'b0;
                    sec <= 2'd0;
                    term <= 3'd0;
                    acc <= 0;
                    state <= S_MAC;
                end
            end

            S_MAC: begin
                // terms 0-2: + b * x, terms 3-4: - a * y
                if (term < 3'd3) acc <= acc + prod;
                else             acc <= acc - prod;
                if (term == 3'd4) state <= S_FIN;
                term <= term + 1'd1;
            end

            S_FIN: begin
                x2[idx] <= x1[idx];
                x1[idx] <= v;
                y2[idx] <= y1[idx];
                y1[idx] <= y_sat;
                acc <= 0;
                term <= 3'd0;
                if (sec == 2'd2) begin
                    if (!ch) begin
                        out_left <= y_out;
                        v <= in_r_wide;
                        ch <= 1'b1;
                        sec <= 2'd0;
                        state <= S_MAC;
                    end
                    else begin
                        out_right <= y_out;
                        state <= S_IDLE;
                    end
                end
                else begin
                    v <= y_sat;
                    sec <= sec + 1'd1;
                    state <= S_MAC;
                end
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
