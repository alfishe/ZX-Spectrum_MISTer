//
// AY-3-8910 Stereo Mixer
//
// Configurable stereo panning with ABC/ACB/Mono modes.
// Pan coefficients match unreal-ng exactly.
//
// Input: Q1.31 unsigned DAC values (0.0 to 1.0)
// Output: Q4.28 unsigned (not centered, DC filter handles that)
//
// Copyright (c) 2025 - Port from unreal-ng emulator
//

module ay_stereo_mixer
(
    input  wire        clk,
    input  wire        ce,           // Clock enable
    input  wire [1:0]  stereo_mode,  // 0=ABC, 1=ACB, 2=Mono

    // Per-channel DAC values (Q1.31 unsigned, 0.0 to 1.0)
    input  wire [31:0] ch_a,
    input  wire [31:0] ch_b,
    input  wire [31:0] ch_c,

    // Stereo output (Q4.28 unsigned - DC filter will center it)
    output reg  [31:0] out_left,
    output reg  [31:0] out_right
);

// Pan coefficients in Q1.31 format, with the software's final /3 folded in.
// unreal-ng updateMixer(): mixed += dac * pan; then mixed /= 3.0
// So effective per-channel gains are 0.9/3, 0.5/3, 0.1/3.
localparam [31:0] PAN_LEFT   = 32'h26666666;  // 0.9/3 = 0.300000
localparam [31:0] PAN_CENTER = 32'h15555555;  // 0.5/3 = 0.166667
localparam [31:0] PAN_RIGHT  = 32'h04444444;  // 0.1/3 = 0.033333

// Pan coefficients selected by mode
reg [31:0] pan_a_l, pan_a_r;
reg [31:0] pan_b_l, pan_b_r;
reg [31:0] pan_c_l, pan_c_r;

// Select panning based on mode
always @(*) begin
    case (stereo_mode)
        2'd0: begin // ABC: A=Left, B=Center, C=Right
            pan_a_l = PAN_LEFT;   pan_a_r = PAN_RIGHT;
            pan_b_l = PAN_CENTER; pan_b_r = PAN_CENTER;
            pan_c_l = PAN_RIGHT;  pan_c_r = PAN_LEFT;
        end
        2'd1: begin // ACB: A=Left, C=Center, B=Right
            pan_a_l = PAN_LEFT;   pan_a_r = PAN_RIGHT;
            pan_b_l = PAN_RIGHT;  pan_b_r = PAN_LEFT;
            pan_c_l = PAN_CENTER; pan_c_r = PAN_CENTER;
        end
        default: begin // Mono: All center
            pan_a_l = PAN_CENTER; pan_a_r = PAN_CENTER;
            pan_b_l = PAN_CENTER; pan_b_r = PAN_CENTER;
            pan_c_l = PAN_CENTER; pan_c_r = PAN_CENTER;
        end
    endcase
end

// Pipeline stage 1: Multiply channels by pan coefficients
// ch is Q1.31 (1 integer bit, 31 fraction bits, unsigned)
// pan is Q1.31
// product is Q2.62 (2 integer bits, 62 fraction bits)
// Max product: 1.0 * 0.9 = 0.9, represented as 0.9 * 2^62
reg [63:0] prod_a_l, prod_a_r;
reg [63:0] prod_b_l, prod_b_r;
reg [63:0] prod_c_l, prod_c_r;

always @(posedge clk) begin
    if (ce) begin
        prod_a_l <= ch_a * pan_a_l;
        prod_a_r <= ch_a * pan_a_r;
        prod_b_l <= ch_b * pan_b_l;
        prod_b_r <= ch_b * pan_b_r;
        prod_c_l <= ch_c * pan_c_l;
        prod_c_r <= ch_c * pan_c_r;
    end
end

// Pipeline stage 2: Sum products
// Q1.31 * Q1.31 = 64-bit result
// If we consider Q1.31 as having 1 integer bit (bit 31) and 31 fraction bits:
// Product has 2 integer bits (bits 63:62) and 62 fraction bits (bits 61:0)
// To get Q2.30: take 2 integer bits + 30 fraction bits = bits [63:32]
// Actually simpler: divide by 2^32 (take upper 32 bits)
// Sum of 3 Q2.30 values needs 2 extra bits for overflow
reg [33:0] sum_l, sum_r;

always @(posedge clk) begin
    if (ce) begin
        // Take upper 32 bits [63:32] - equivalent to dividing by 2^32
        // This converts Q2.62 to Q2.30 (losing 32 bits of fraction precision)
        sum_l <= {2'b0, prod_a_l[63:32]} + {2'b0, prod_b_l[63:32]} + {2'b0, prod_c_l[63:32]};
        sum_r <= {2'b0, prod_a_r[63:32]} + {2'b0, prod_b_r[63:32]} + {2'b0, prod_c_r[63:32]};
    end
end

// Pipeline stage 3: Convert Q2.30 to Q4.28
// Q2.30 has 2 integer bits, 30 fraction bits
// Q4.28 has 4 integer bits, 28 fraction bits
// To convert: shift right by 2 (lose 2 fraction bits)
// sum_l is 34 bits with max value ~1.5 in Q2.30
// After shift right 2: max value ~1.5 in Q4.28 = 0x18000000
always @(posedge clk) begin
    if (ce) begin
        // Shift right 2 to convert Q2.30 -> Q4.28
        out_left  <= sum_l[33:2];
        out_right <= sum_r[33:2];
    end
end

endmodule
