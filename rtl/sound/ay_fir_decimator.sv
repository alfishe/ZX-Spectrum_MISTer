//
// AY-3-8910 20 kHz FIR lowpass (full-rate)
//
// 96-tap FIR lowpass, Fc=20kHz @ Fs=218.75kHz, Kaiser window (beta=5).
// Same coefficients as unreal-ng FilterDecimator (Q1.31, sum to 1.0),
// but runs at the full generator rate - one output per input sample.
//
// Input:  Q4.28 signed at 218.75 kHz
// Output: Q4.28 signed at 218.75 kHz, band-limited to 20 kHz
//
// Copyright (c) 2025 - Port from unreal-ng emulator
//

module ay_fir_decimator
(
    input  wire        clk,
    input  wire        ce_in,        // Input clock enable (218.75 kHz)
    input  wire        reset,

    input  wire signed [31:0] in_sample,   // Q4.28 input from mixer

    output reg         out_valid,    // Pulse when output sample ready
    output reg  signed [31:0] out_sample   // Q4.28 output at 218.75 kHz
);

localparam FIR_TAPS = 96;

// NO DECIMATION: the filter runs at the full 218.75 kHz generator rate and
// produces one output per input sample. Unlike the software (which must
// decimate to feed a 44.1 kHz audio device), the MiSTer framework samples
// AUDIO_L/R asynchronously - any discrete low-rate ZOH output beats against
// the framework's independent audio clock and is heard as jitter/fuzz.
// A full-rate output changes in small smooth steps (like the legacy path)
// and carries the identical 20 kHz-limited spectrum.
// The 96-tap computation takes ~100 clk per sample; ce_in arrives every
// 256 clk (56 MHz / 218.75 kHz), so it always completes in time.

// Circular buffer for input samples (inferred as block RAM)
(* ram_style = "block" *) reg signed [31:0] buffer [0:FIR_TAPS-1];
reg [6:0] buffer_idx;  // 0-95

// FIR coefficient ROM (inferred as block RAM)
// Coefficients in Q1.31 format, sum to 1.0
// Matches unreal-ng FilterDecimator exactly
(* ram_style = "block" *) reg signed [31:0] coeff_rom [0:95];

initial begin
    // Q1.31 coefficients (unity gain)
    coeff_rom[ 0] = 32'h0006B9D9;  // +2.052603e-04
    coeff_rom[ 1] = 32'h000A84F4;  // +3.210251e-04
    coeff_rom[ 2] = 32'h000B435A;  // +3.437221e-04
    coeff_rom[ 3] = 32'h0006E94F;  // +2.109182e-04
    coeff_rom[ 4] = 32'hFFFD1CB6;  // -8.813008e-05
    coeff_rom[ 5] = 32'hFFF00A11;  // -4.870812e-04
    coeff_rom[ 6] = 32'hFFE44866;  // -8.458617e-04
    coeff_rom[ 7] = 32'hFFDF8FE0;  // -9.899287e-04
    coeff_rom[ 8] = 32'hFFE68253;  // -7.779214e-04
    coeff_rom[ 9] = 32'hFFFA4235;  // -1.752127e-04
    coeff_rom[10] = 32'h0016DCF8;  // +6.977284e-04
    coeff_rom[11] = 32'h003373F6;  // +1.570220e-03
    coeff_rom[12] = 32'h0044893E;  // +2.091556e-03
    coeff_rom[13] = 32'h00400451;  // +1.953639e-03
    coeff_rom[14] = 32'h0021AF59;  // +1.027983e-03
    coeff_rom[15] = 32'hFFEE7061;  // -5.359200e-04
    coeff_rom[16] = 32'hFFB4A0FC;  // -2.300145e-03
    coeff_rom[17] = 32'hFF88B62E;  // -3.640392e-03
    coeff_rom[18] = 32'hFF7EB865;  // -3.945304e-03
    coeff_rom[19] = 32'hFFA26B49;  // -2.855863e-03
    coeff_rom[20] = 32'hFFF0EDA6;  // -4.599512e-04
    coeff_rom[21] = 32'h00569870;  // +2.642683e-03
    coeff_rom[22] = 32'h00B2CE01;  // +5.456686e-03
    coeff_rom[23] = 32'h00E17976;  // +6.880934e-03
    coeff_rom[24] = 32'h00C7C91B;  // +6.096972e-03
    coeff_rom[25] = 32'h00600192;  // +2.929875e-03
    coeff_rom[26] = 32'hFFBFDA0A;  // -1.957650e-03
    coeff_rom[27] = 32'hFF16030D;  // -7.140750e-03
    coeff_rom[28] = 32'hFE9E1B99;  // -1.079993e-02
    coeff_rom[29] = 32'hFE8DAFAF;  // -1.130108e-02
    coeff_rom[30] = 32'hFEFFCE5A;  // -7.818418e-03
    coeff_rom[31] = 32'hFFE635FB;  // -7.870219e-04
    coeff_rom[32] = 32'h01064886;  // +8.004251e-03
    coeff_rom[33] = 32'h0204E546;  // +1.577440e-02
    coeff_rom[34] = 32'h027FAB6D;  // +1.952117e-02
    coeff_rom[35] = 32'h022D68F9;  // +1.701080e-02
    coeff_rom[36] = 32'h00FC2B39;  // +7.695582e-03
    coeff_rom[37] = 32'hFF22D1F6;  // -6.749873e-03
    coeff_rom[38] = 32'hFD1EAC9F;  // -2.250139e-02
    coeff_rom[39] = 32'hFB9B0625;  // -3.433154e-02
    coeff_rom[40] = 32'hFB472293;  // -3.689163e-02
    coeff_rom[41] = 32'hFCA512A1;  // -2.621238e-02
    coeff_rom[42] = 32'hFFDEF908;  // -1.007911e-03
    coeff_rom[43] = 32'h04AFB44D;  // +3.661207e-02
    coeff_rom[44] = 32'h0A674352;  // +8.127634e-02
    coeff_rom[45] = 32'h100BD3DC;  // +1.253609e-01
    coeff_rom[46] = 32'h14904FE9;  // +1.606541e-01
    coeff_rom[47] = 32'h1712D732;  // +1.802625e-01
    // Center tap (symmetric)
    coeff_rom[48] = 32'h1712D732;  // +1.802625e-01
    coeff_rom[49] = 32'h14904FE9;  // +1.606541e-01
    coeff_rom[50] = 32'h100BD3DC;  // +1.253609e-01
    coeff_rom[51] = 32'h0A674352;  // +8.127634e-02
    coeff_rom[52] = 32'h04AFB44D;  // +3.661207e-02
    coeff_rom[53] = 32'hFFDEF908;  // -1.007911e-03
    coeff_rom[54] = 32'hFCA512A1;  // -2.621238e-02
    coeff_rom[55] = 32'hFB472293;  // -3.689163e-02
    coeff_rom[56] = 32'hFB9B0625;  // -3.433154e-02
    coeff_rom[57] = 32'hFD1EAC9F;  // -2.250139e-02
    coeff_rom[58] = 32'hFF22D1F6;  // -6.749873e-03
    coeff_rom[59] = 32'h00FC2B39;  // +7.695582e-03
    coeff_rom[60] = 32'h022D68F9;  // +1.701080e-02
    coeff_rom[61] = 32'h027FAB6D;  // +1.952117e-02
    coeff_rom[62] = 32'h0204E546;  // +1.577440e-02
    coeff_rom[63] = 32'h01064886;  // +8.004251e-03
    coeff_rom[64] = 32'hFFE635FB;  // -7.870219e-04
    coeff_rom[65] = 32'hFEFFCE5A;  // -7.818418e-03
    coeff_rom[66] = 32'hFE8DAFAF;  // -1.130108e-02
    coeff_rom[67] = 32'hFE9E1B99;  // -1.079993e-02
    coeff_rom[68] = 32'hFF16030D;  // -7.140750e-03
    coeff_rom[69] = 32'hFFBFDA0A;  // -1.957650e-03
    coeff_rom[70] = 32'h00600192;  // +2.929875e-03
    coeff_rom[71] = 32'h00C7C91B;  // +6.096972e-03
    coeff_rom[72] = 32'h00E17976;  // +6.880934e-03
    coeff_rom[73] = 32'h00B2CE01;  // +5.456686e-03
    coeff_rom[74] = 32'h00569870;  // +2.642683e-03
    coeff_rom[75] = 32'hFFF0EDA6;  // -4.599512e-04
    coeff_rom[76] = 32'hFFA26B49;  // -2.855863e-03
    coeff_rom[77] = 32'hFF7EB865;  // -3.945304e-03
    coeff_rom[78] = 32'hFF88B62E;  // -3.640392e-03
    coeff_rom[79] = 32'hFFB4A0FC;  // -2.300145e-03
    coeff_rom[80] = 32'hFFEE7061;  // -5.359200e-04
    coeff_rom[81] = 32'h0021AF59;  // +1.027983e-03
    coeff_rom[82] = 32'h00400451;  // +1.953639e-03
    coeff_rom[83] = 32'h0044893E;  // +2.091556e-03
    coeff_rom[84] = 32'h003373F6;  // +1.570220e-03
    coeff_rom[85] = 32'h0016DCF8;  // +6.977284e-04
    coeff_rom[86] = 32'hFFFA4235;  // -1.752127e-04
    coeff_rom[87] = 32'hFFE68253;  // -7.779214e-04
    coeff_rom[88] = 32'hFFDF8FE0;  // -9.899287e-04
    coeff_rom[89] = 32'hFFE44866;  // -8.458617e-04
    coeff_rom[90] = 32'hFFF00A11;  // -4.870812e-04
    coeff_rom[91] = 32'hFFFD1CB6;  // -8.813008e-05
    coeff_rom[92] = 32'h0006E94F;  // +2.109182e-04
    coeff_rom[93] = 32'h000B435A;  // +3.437221e-04
    coeff_rom[94] = 32'h000A84F4;  // +3.210251e-04
    coeff_rom[95] = 32'h0006B9D9;  // +2.052603e-04
end

// FIR computation state machine
reg [6:0] tap_idx;
reg signed [63:0] accumulator;
reg [1:0] state;

localparam S_IDLE    = 2'd0;
localparam S_COMPUTE = 2'd1;
localparam S_OUTPUT  = 2'd2;

// Registered ROM/buffer outputs for timing
reg signed [31:0] coeff_reg;
reg signed [31:0] sample_reg;
reg signed [63:0] mac_result;

// Sample index calculation - registered
reg [6:0] sample_idx_reg;

integer i;

always @(posedge clk) begin
    if (reset) begin
        buffer_idx <= 0;
        tap_idx <= 0;
        accumulator <= 0;
        state <= S_IDLE;
        out_valid <= 0;
        out_sample <= 0;
        coeff_reg <= 0;
        sample_reg <= 0;
        mac_result <= 0;
        sample_idx_reg <= 0;
        for (i = 0; i < FIR_TAPS; i = i + 1) begin
            buffer[i] <= 0;
        end
    end
    else begin
        out_valid <= 0;

        case (state)
            S_IDLE: begin
                if (ce_in) begin
                    // Store input sample in circular buffer
                    buffer[buffer_idx] <= in_sample;
                    buffer_idx <= (buffer_idx == FIR_TAPS-1) ? 7'd0 : buffer_idx + 1'd1;

                    // Compute an output for EVERY input sample (no decimation)
                    state <= S_COMPUTE;
                    tap_idx <= 0;
                    accumulator <= 0;
                    // Newest sample is the one being written this cycle
                    // at buffer_idx; the window is x[n]..x[n-95] with
                    // coeff[0] applied to x[n] (matches software filtering).
                    sample_idx_reg <= buffer_idx;
                end
            end

            S_COMPUTE: begin
                // Pipeline stage 1: Read coefficient and sample from ROM/RAM
                coeff_reg <= coeff_rom[tap_idx];
                sample_reg <= buffer[sample_idx_reg];

                // Update sample index for next tap (wrapping subtract)
                if (sample_idx_reg == 0)
                    sample_idx_reg <= FIR_TAPS - 1;
                else
                    sample_idx_reg <= sample_idx_reg - 1'd1;

                // Pipeline stage 2: Multiply (infers DSP block)
                // Q4.28 * Q1.31 = Q5.59 (64 bits)
                mac_result <= $signed(sample_reg) * $signed(coeff_reg);

                // Pipeline stage 3: Accumulate (skip first 2 cycles due to pipeline)
                if (tap_idx >= 2) begin
                    accumulator <= accumulator + mac_result;
                end

                tap_idx <= tap_idx + 1'd1;

                // Check completion (account for 2-stage pipeline delay)
                if (tap_idx == FIR_TAPS + 1) begin
                    state <= S_OUTPUT;
                    // Add final MAC result
                    accumulator <= accumulator + mac_result;
                end
            end

            S_OUTPUT: begin
                state <= S_IDLE;
                out_valid <= 1;
                // Input is Q4.28 (4 integer, 28 fraction)
                // Coefficients are Q1.31 (1 sign/integer, 31 fraction)
                // Product is Q5.59 (5 integer bits [63:59], 59 fraction bits [58:0])
                // Sum of coefficients = 1.0, so no gain adjustment needed
                // To convert Q5.59 back to Q4.28: shift right by 31 bits
                // Take bits [62:31] for the result (bit 63 is sign extension)
                out_sample <= accumulator[62:31];
            end
        endcase
    end
end

endmodule
