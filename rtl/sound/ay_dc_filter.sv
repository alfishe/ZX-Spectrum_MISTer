//
// AY-3-8910 DC Offset Filter
//
// 1024-sample moving average high-pass filter.
// Matches unreal-ng FilterDC::filter():
//   sum += x - buf[i]; buf[i] = x; i = (i+1) & 1023;
//   y = x - sum/1024;
// The averaging window INCLUDES the current sample (x[n-1023]..x[n]).
//
// Input:  Q4.28 unsigned (positive only, < 8.0)
// Output: Q4.28 signed (centered around zero)
//
// The delay RAM is swept to zero after reset (S_CLEAR) so a warm reset
// cannot underflow the running sum with stale samples.
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

localparam BUFFER_SIZE = 1024;
localparam BUFFER_BITS = 10;  // log2(1024)

// Delay line buffer - explicitly inferred as block RAM
(* ram_style = "block" *) reg [31:0] delay_buffer [0:BUFFER_SIZE-1];

reg [BUFFER_BITS-1:0] wr_index;

// Running sum: 32-bit values * 1024 samples needs 42 bits
// Use 48 bits for safety, unsigned
reg [47:0] running_sum;

// Registered read from RAM
reg [31:0] oldest_sample;

// Pipeline state
reg [1:0] state;
reg [31:0] in_sample_r;

localparam S_CLEAR  = 2'd3;
localparam S_IDLE   = 2'd0;
localparam S_READ   = 2'd1;
localparam S_CALC   = 2'd2;

// Sum including the current sample - matches software window exactly
wire [47:0] new_sum = running_sum - {16'd0, oldest_sample} + {16'd0, in_sample_r};

always @(posedge clk) begin
    if (reset) begin
        wr_index <= 0;
        running_sum <= 0;
        out_sample <= 0;
        oldest_sample <= 0;
        state <= S_CLEAR;
        in_sample_r <= 0;
    end
    else begin
        case (state)
            S_CLEAR: begin
                // Sweep-clear the delay RAM (1024 cycles after reset)
                delay_buffer[wr_index] <= 32'd0;
                wr_index <= wr_index + 1'd1;
                if (wr_index == BUFFER_SIZE-1)
                    state <= S_IDLE;
            end

            S_IDLE: begin
                if (ce) begin
                    // Latch input and start read
                    in_sample_r <= in_sample;
                    // Read oldest sample (block RAM has 1 cycle latency)
                    oldest_sample <= delay_buffer[wr_index];
                    state <= S_READ;
                end
            end

            S_READ: begin
                // oldest_sample is now valid
                // Write new sample to buffer
                delay_buffer[wr_index] <= in_sample_r;
                state <= S_CALC;
            end

            S_CALC: begin
                // Update running sum: remove oldest, add new (current sample
                // included in the window, as in software)
                running_sum <= new_sum;

                // Output = input - average(window including current sample)
                out_sample <= $signed({1'b0, in_sample_r}) - $signed({1'b0, new_sum[41:10]});

                // Advance index
                wr_index <= wr_index + 1'd1;

                state <= S_IDLE;
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
