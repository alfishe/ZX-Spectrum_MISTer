//
// AY-3-8910 DC Offset Filter
//
// One-pole RC high-pass at 5 Hz: the discrete model of the output coupling
// capacitor. Matches unreal-ng FilterDCBlocker (AY OUTPUT_HIGHPASS_HZ = 5):
//   y[n] = a * (y[n-1] + x[n] - x[n-1]),  a = RC / (RC + dt)
// computed as y = s - k*s with s = y[n-1] + x[n] - x[n-1], k = 1 - a.
//
// It replaces the 1024-sample moving-average remover (x - mean of the last
// 1024 samples), as unreal-ng did: that filter returned every burst as a
// delayed step one window (4.68 ms) later and cut the bass (-21 dB at 50 Hz,
// -10 dB at 100 Hz). The tonal balance of the old filter is now provided by
// the "Classic" voicing profile (ay_voicing), as in unreal-ng.
//
// Input:  Q4.28 unsigned (positive only, < 8.0)
// Output: Q4.28 signed
// State:  y kept with 16 extra fraction bits (Q.44): k is ~1.4e-4, so the
//         feedback needs more precision than the output to stay exact.
//
// Copyright (c) 2025 - Port from unreal-ng emulator
//

module ay_dc_filter
(
    input  wire        clk,
    input  wire        ce,           // Clock enable (at generator rate)
    input  wire        reset,

    input  wire [31:0] in_sample,          // Q4.28 unsigned input
    output reg  signed [31:0] out_sample   // Q4.28 signed output
);

// k = 1 - a for fc = 5 Hz at 218.75 kHz, Q0.40 (FilterDCBlocker::coefficient()
// at the generator rate: a = 0.999856404958, k = 1.435950416668e-04)
localparam signed [29:0] DC_K = 30'sd157884418;

reg signed [32:0] x1;            // previous input, Q4.28 (sign-extended)
reg signed [55:0] y;             // output state, Q.44
reg signed [55:0] s;             // y[n-1] + x[n] - x[n-1], Q.44
reg signed [85:0] ks;            // s * k, Q.84
reg        [1:0]  state;

localparam S_IDLE = 2'd0;
localparam S_MUL  = 2'd1;
localparam S_OUT  = 2'd2;

wire signed [32:0] x_in = $signed({1'b0, in_sample});
wire signed [55:0] y_new = s - $signed(ks[85:40]);
wire signed [55:0] y_rnd = y_new + 56'sd32768;   // round Q.44 -> Q.28

always @(posedge clk) begin
    if (reset) begin
        x1 <= 0;
        y <= 0;
        s <= 0;
        ks <= 0;
        out_sample <= 0;
        state <= S_IDLE;
    end
    else begin
        case (state)
            S_IDLE: begin
                if (ce) begin
                    s <= y + ($signed(x_in - x1) <<< 16);
                    x1 <= x_in;
                    state <= S_MUL;
                end
            end

            S_MUL: begin
                ks <= s * DC_K;
                state <= S_OUT;
            end

            S_OUT: begin
                y <= y_new;
                // Q.44 -> Q4.28 with rounding
                out_sample <= y_rnd[47:16];
                state <= S_IDLE;
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
