//
// AY-3-8910 Punch Enhancer
//
// Exact port of unreal-ng AudioCharacterChain punch stage:
//   diff = in - prev
//   mag  = |diff|
//   env  = (mag > env) ? mag*attack + env*(1-attack) : env*release
//   out  = in + diff*edgeBlend + diff*env*transBoost
//   prev = in
//
// Presets (preset input): 0 = AY (edge 0.03, boost 0.1, release 0.9995)
//                         1 = Paula/Beeper (edge 0.08, boost 0.2, release 0.998)
// Attack = 0.3 for both. Coefficients are Q1.31.
//
// Single shared 32x32 signed multiplier. Operands are loaded in one state
// and the combinational product is consumed in the NEXT state (registered
// operand -> valid product timing, one product per state pair).
//
// Samples: signed Q4.28 in/out at 44.1 kHz (ce). ~18 clk cycles per sample.
// When disabled, input passes through registered and prev/env are frozen,
// matching the software's enable gate.
//
// Copyright (c) 2025 - Port from unreal-ng emulator
//

module ay_punch_enhancer
(
    input  wire        clk,
    input  wire        ce,           // Sample clock enable (44.1 kHz)
    input  wire        reset,
    input  wire        enable,
    input  wire        preset,       // 0 = AY, 1 = Paula/Beeper

    input  wire signed [31:0] in_left,    // Q4.28
    input  wire signed [31:0] in_right,
    output reg  signed [31:0] out_left,   // Q4.28
    output reg  signed [31:0] out_right
);

// Coefficients (Q1.31), RATE-RESCALED for 218.75 kHz operation so the
// time-domain response matches unreal-ng's 44.1 kHz design (r = 4.9603):
//   attack'  = 1-(1-a)^(1/r), release' = rel^(1/r)  (same real-time envelope)
//   edge'    = edge * r          (diff is 1/r smaller per sample)
//   boost'   = boost * r^2       (diff AND env each scale by 1/r);
//              boost' > 1.0 so it is held as mantissa * 2^shift
localparam signed [31:0] ATTACK           = 32'h08E17CB6;  // 0.06938132
localparam signed [31:0] ONE_MINUS_ATTACK = 32'h771E834A;  // 0.93061868
localparam signed [31:0] RELEASE_AY       = 32'h7FFCB242;  // 0.99989918
localparam signed [31:0] RELEASE_PB       = 32'h7FF2C702;  // 0.99959648
localparam signed [31:0] EDGE_AY          = 32'h130C30C3;  // 0.14880952
localparam signed [31:0] EDGE_PB          = 32'h32CB2CB3;  // 0.39682540
localparam signed [31:0] BOOST_MANT       = 32'h4EBC35EC;  // 0.61511873

wire signed [31:0] release_coef = preset ? RELEASE_PB : RELEASE_AY;
wire signed [31:0] edge_coef    = preset ? EDGE_PB    : EDGE_AY;
wire signed [31:0] boost_coef   = BOOST_MANT;
wire [1:0]         boost_shift  = preset ? 2'd3 : 2'd2;  // *8 (PB) / *4 (AY)

// State machine
reg [4:0] state;
localparam S_IDLE          = 5'd0;
localparam S_DIFF          = 5'd1;
localparam S_MAG           = 5'd2;
localparam S_ENVL_LOAD     = 5'd3;
localparam S_ENVL_C1       = 5'd4;
localparam S_ENVL_C2       = 5'd5;
localparam S_ENVR_LOAD     = 5'd6;
localparam S_ENVR_C1       = 5'd7;
localparam S_ENVR_C2       = 5'd8;
localparam S_EDGEL_LOAD    = 5'd9;
localparam S_EDGER_LOAD    = 5'd10;
localparam S_TRANSL_LOAD   = 5'd11;
localparam S_TRANSL_C      = 5'd12;
localparam S_TRANSL_B_LOAD = 5'd13;
localparam S_TRANSR_LOAD   = 5'd14;
localparam S_TRANSR_C      = 5'd15;
localparam S_TRANSR_B_LOAD = 5'd16;
localparam S_OUT           = 5'd17;

// Working registers
reg signed [31:0] in_l_r, in_r_r;
reg signed [31:0] prev_l, prev_r;      // previous INPUT (as software)
reg signed [31:0] diff_l, diff_r;
reg signed [31:0] mag_l, mag_r;
reg signed [31:0] env_l, env_r;        // envelope followers (>= 0)
reg signed [31:0] edge_l, edge_r;
reg signed [31:0] trans_l;
reg signed [31:0] t1;
reg att_l, att_r;

// Single shared multiplier: operands registered, product combinational
reg signed [31:0] mult_a, mult_b;
wire signed [63:0] mult_result = mult_a * mult_b;

// Product rescaling:
//  Q4.28 * Q1.31 -> Q4.28: >> 31  = bits [62:31]
//  Q4.28 * Q4.28 -> Q4.28: >> 28  = bits [59:28]
wire signed [31:0] res31 = mult_result[62:31];
wire signed [31:0] res28 = mult_result[59:28];

always @(posedge clk) begin
    if (reset) begin
        state <= S_IDLE;
        out_left <= 0;
        out_right <= 0;
        in_l_r <= 0; in_r_r <= 0;
        prev_l <= 0; prev_r <= 0;
        diff_l <= 0; diff_r <= 0;
        mag_l <= 0;  mag_r <= 0;
        env_l <= 0;  env_r <= 0;
        edge_l <= 0; edge_r <= 0;
        trans_l <= 0;
        t1 <= 0;
        att_l <= 0; att_r <= 0;
        mult_a <= 0; mult_b <= 0;
    end
    else begin
        case (state)
            S_IDLE: begin
                if (ce) begin
                    in_l_r <= in_left;
                    in_r_r <= in_right;
                    if (enable) begin
                        state <= S_DIFF;
                    end
                    else begin
                        // Bypass: pass through, freeze prev/env (as software)
                        out_left  <= in_left;
                        out_right <= in_right;
                    end
                end
            end

            S_DIFF: begin
                diff_l <= in_l_r - prev_l;
                diff_r <= in_r_r - prev_r;
                state <= S_MAG;
            end

            S_MAG: begin
                mag_l <= diff_l[31] ? -diff_l : diff_l;
                mag_r <= diff_r[31] ? -diff_r : diff_r;
                state <= S_ENVL_LOAD;
            end

            // --- Left envelope ---
            S_ENVL_LOAD: begin
                att_l <= (mag_l > env_l);
                if (mag_l > env_l) begin
                    mult_a <= mag_l;  mult_b <= ATTACK;
                end
                else begin
                    mult_a <= env_l;  mult_b <= release_coef;
                end
                state <= S_ENVL_C1;
            end

            S_ENVL_C1: begin
                if (att_l) begin
                    t1 <= res31;                       // mag_l * attack
                    mult_a <= env_l;  mult_b <= ONE_MINUS_ATTACK;
                    state <= S_ENVL_C2;
                end
                else begin
                    env_l <= res31;                    // env_l * release
                    state <= S_ENVR_LOAD;
                end
            end

            S_ENVL_C2: begin
                env_l <= t1 + res31;                   // + env_l*(1-attack)
                state <= S_ENVR_LOAD;
            end

            // --- Right envelope ---
            S_ENVR_LOAD: begin
                att_r <= (mag_r > env_r);
                if (mag_r > env_r) begin
                    mult_a <= mag_r;  mult_b <= ATTACK;
                end
                else begin
                    mult_a <= env_r;  mult_b <= release_coef;
                end
                state <= S_ENVR_C1;
            end

            S_ENVR_C1: begin
                if (att_r) begin
                    t1 <= res31;                       // mag_r * attack
                    mult_a <= env_r;  mult_b <= ONE_MINUS_ATTACK;
                    state <= S_ENVR_C2;
                end
                else begin
                    env_r <= res31;                    // env_r * release
                    state <= S_EDGEL_LOAD;
                end
            end

            S_ENVR_C2: begin
                env_r <= t1 + res31;                   // + env_r*(1-attack)
                state <= S_EDGEL_LOAD;
            end

            // --- Edge blend ---
            S_EDGEL_LOAD: begin
                mult_a <= diff_l;  mult_b <= edge_coef;
                state <= S_EDGER_LOAD;
            end

            S_EDGER_LOAD: begin
                edge_l <= res31;                       // diff_l * edgeBlend
                mult_a <= diff_r;  mult_b <= edge_coef;
                state <= S_TRANSL_LOAD;
            end

            // --- Transient boost: diff * env * transBoost ---
            S_TRANSL_LOAD: begin
                edge_r <= res31;                       // diff_r * edgeBlend
                mult_a <= diff_l;  mult_b <= env_l;    // Q4.28 * Q4.28
                state <= S_TRANSL_C;
            end

            S_TRANSL_C: begin
                t1 <= res28;                           // diff_l * env_l
                state <= S_TRANSL_B_LOAD;
            end

            S_TRANSL_B_LOAD: begin
                mult_a <= t1;  mult_b <= boost_coef;
                state <= S_TRANSR_LOAD;
            end

            S_TRANSR_LOAD: begin
                trans_l <= res31 <<< boost_shift;      // (diff_l*env_l)*boost'
                mult_a <= diff_r;  mult_b <= env_r;    // Q4.28 * Q4.28
                state <= S_TRANSR_C;
            end

            S_TRANSR_C: begin
                t1 <= res28;                           // diff_r * env_r
                state <= S_TRANSR_B_LOAD;
            end

            S_TRANSR_B_LOAD: begin
                mult_a <= t1;  mult_b <= boost_coef;
                state <= S_OUT;
            end

            S_OUT: begin
                out_left  <= in_l_r + edge_l + trans_l;
                out_right <= in_r_r + edge_r + (res31 <<< boost_shift);  // *boost'
                prev_l <= in_l_r;
                prev_r <= in_r_r;
                state <= S_IDLE;
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
