//============================================================================
// 96-tap FIR Decimator for MiSTer ZX Spectrum
// Exact port from unreal-ng filter_decimator.h
//
// Design: 96-tap lowpass, Fc=20kHz @ Fs=218.75kHz, Kaiser window (beta=5)
// Input: PSG generator rate (PSG_CLOCK/8 = ~218.75 kHz)
// Output: 48 kHz (MiSTer standard)
// Decimation ratio: ~4.557:1 (218750/48000)
//
// This provides identical aliasing characteristics to the software renderer.
//============================================================================

module fir_decimator
(
    input             clk,           // Audio clock (56MHz)
    input             reset,

    // Input at generator rate (~218.75kHz via CE)
    input             in_ce,         // Clock enable at PSG generator rate
    input      [15:0] in_l,
    input      [15:0] in_r,

    // Output (updated when decimation produces new sample)
    output reg        out_valid,
    output reg [15:0] out_l,
    output reg [15:0] out_r
);

// Decimation: 218750 Hz -> 48000 Hz = 4.557291... ratio
// Phase increment = 48000/218750 * 2^24 = 3679126.4
localparam [24:0] PHASE_INCR = 25'd3679126;
localparam [24:0] PHASE_MAX  = 25'h1000000;

// 96-tap FIR coefficients from unreal-ng filter_decimator.h
// Kaiser window, beta=5, Fc=20kHz @ 218.75kHz
// Scaled to 18-bit signed (x131072 = 2^17), sum = 131072 = unity gain
localparam signed [17:0] COEF [0:95] = '{
    18'sd27,     18'sd42,     18'sd45,     18'sd28,     -18'sd12,    -18'sd64,    -18'sd111,   -18'sd130,
    -18'sd102,   -18'sd23,    18'sd91,     18'sd206,    18'sd274,    18'sd256,    18'sd135,    -18'sd70,
    -18'sd301,   -18'sd477,   -18'sd517,   -18'sd374,   -18'sd60,    18'sd346,    18'sd715,    18'sd902,
    18'sd799,    18'sd384,    -18'sd257,   -18'sd936,   -18'sd1416,  -18'sd1481,  -18'sd1025,  -18'sd103,
    18'sd1049,   18'sd2068,   18'sd2559,   18'sd2230,   18'sd1009,   -18'sd885,   -18'sd2949,  -18'sd4500,
    -18'sd4835,  -18'sd3436,  -18'sd132,   18'sd4799,   18'sd10653,  18'sd16431,  18'sd21057,  18'sd23627,
    18'sd23627,  18'sd21057,  18'sd16431,  18'sd10653,  18'sd4799,   -18'sd132,   -18'sd3436,  -18'sd4835,
    -18'sd4500,  -18'sd2949,  -18'sd885,   18'sd1009,   18'sd2230,   18'sd2559,   18'sd2068,   18'sd1049,
    -18'sd103,   -18'sd1025,  -18'sd1481,  -18'sd1416,  -18'sd936,   -18'sd257,   18'sd384,    18'sd799,
    18'sd902,    18'sd715,    18'sd346,    -18'sd60,    -18'sd374,   -18'sd517,   -18'sd477,   -18'sd301,
    -18'sd70,    18'sd135,    18'sd256,    18'sd274,    18'sd206,    18'sd91,     -18'sd23,    -18'sd102,
    -18'sd130,   -18'sd111,   -18'sd64,    -18'sd12,    18'sd28,     18'sd45,     18'sd42,     18'sd27
};

// Delay line (circular buffer)
localparam TAPS = 96;
localparam TAP_BITS = 7;  // log2(128) > 96

reg signed [15:0] delay_l [0:TAPS-1];
reg signed [15:0] delay_r [0:TAPS-1];
reg [TAP_BITS-1:0] write_idx;

// Fractional phase accumulator for decimation
reg [24:0] phase_acc;
wire phase_wrap = (phase_acc + PHASE_INCR) >= PHASE_MAX;

// MAC computation state
reg [1:0] state;
reg [6:0] tap_idx;  // 0-95
reg signed [35:0] acc_l, acc_r;

localparam S_IDLE = 0;
localparam S_MAC  = 1;
localparam S_OUT  = 2;

// Registered coefficient lookup
reg signed [17:0] coef_val;

always @(posedge clk) begin
    if (reset) begin
        write_idx <= 0;
        phase_acc <= 0;
        state <= S_IDLE;
        out_valid <= 0;
        out_l <= 0;
        out_r <= 0;
        acc_l <= 0;
        acc_r <= 0;
        tap_idx <= 0;
    end
    else begin
        out_valid <= 0;

        case (state)
            S_IDLE: begin
                if (in_ce) begin
                    // Push new sample into delay line
                    delay_l[write_idx] <= $signed(in_l);
                    delay_r[write_idx] <= $signed(in_r);
                    write_idx <= (write_idx == TAPS-1) ? 0 : write_idx + 1'd1;

                    // Update phase accumulator
                    if (phase_wrap) begin
                        phase_acc <= phase_acc + PHASE_INCR - PHASE_MAX;
                        // Start FIR computation
                        tap_idx <= 0;
                        acc_l <= 0;
                        acc_r <= 0;
                        state <= S_MAC;
                    end
                    else begin
                        phase_acc <= phase_acc + PHASE_INCR;
                    end
                end
            end

            S_MAC: begin
                // Continue accepting input samples during MAC
                if (in_ce) begin
                    delay_l[write_idx] <= $signed(in_l);
                    delay_r[write_idx] <= $signed(in_r);
                    write_idx <= (write_idx == TAPS-1) ? 0 : write_idx + 1'd1;

                    if (phase_wrap) begin
                        phase_acc <= phase_acc + PHASE_INCR - PHASE_MAX;
                    end
                    else begin
                        phase_acc <= phase_acc + PHASE_INCR;
                    end
                end

                // MAC operation
                begin
                    reg [TAP_BITS-1:0] read_idx;
                    reg signed [15:0] samp_l, samp_r;
                    reg signed [17:0] c;
                    reg signed [33:0] prod_l, prod_r;

                    // Read from delay line (oldest sample first)
                    // tap_idx=0 reads oldest, tap_idx=95 reads newest
                    read_idx = write_idx + tap_idx;
                    if (read_idx >= TAPS) read_idx = read_idx - TAPS;

                    samp_l = delay_l[read_idx];
                    samp_r = delay_r[read_idx];
                    c = COEF[tap_idx];

                    prod_l = samp_l * c;
                    prod_r = samp_r * c;

                    acc_l <= acc_l + {{2{prod_l[33]}}, prod_l};
                    acc_r <= acc_r + {{2{prod_r[33]}}, prod_r};
                end

                if (tap_idx == 95) begin
                    state <= S_OUT;
                end
                else begin
                    tap_idx <= tap_idx + 1'd1;
                end
            end

            S_OUT: begin
                // Continue accepting input
                if (in_ce) begin
                    delay_l[write_idx] <= $signed(in_l);
                    delay_r[write_idx] <= $signed(in_r);
                    write_idx <= (write_idx == TAPS-1) ? 0 : write_idx + 1'd1;

                    if (phase_wrap) begin
                        phase_acc <= phase_acc + PHASE_INCR - PHASE_MAX;
                    end
                    else begin
                        phase_acc <= phase_acc + PHASE_INCR;
                    end
                end

                // Output scaled result
                // Coefficients sum to ~1.0 scaled by 2^17
                // acc has product of 16-bit * 18-bit = 34 bits, accumulated 96 times
                // Shift right by 17 for coefficient scale
                out_l <= acc_l[32:17];
                out_r <= acc_r[32:17];
                out_valid <= 1;
                state <= S_IDLE;
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
