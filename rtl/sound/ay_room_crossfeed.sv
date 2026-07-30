//
// AY-3-8910 Room Crossfeed
//
// Reduces headphone fatigue from hard L-R panning.
// Delayed opposite-channel blend simulates room reflections.
//
// For AY: 2ms delay, NO lowpass (preserve square wave harmonics)
// Levels: -15dB to -1dB configurable
//
// Optimized: Single multiplier, delay line in block RAM
//
// Matches unreal-ng AudioCharacterChain room simulation.
//
// Copyright (c) 2025 - Port from unreal-ng emulator
//

module ay_room_crossfeed
(
    input  wire        clk,
    input  wire        ce,           // Clock enable (at 44.1kHz)
    input  wire        reset,
    input  wire        enable,       // Bypass when disabled

    // Room level selection (0-9 maps to modes in unreal-ng)
    // 0=Off, 1=-15dB, 2=-14dB, 3=-13dB, 4=-12dB, 5=-9dB, 6=-6dB, 7=-3dB, 8=-2dB, 9=-1dB
    input  wire [3:0]  room_level,

    input  wire signed [31:0] in_left,    // Q4.28 input
    input  wire signed [31:0] in_right,
    output reg  signed [31:0] out_left,   // Q4.28 output
    output reg  signed [31:0] out_right
);

// Delay line parameters
// AY uses 2ms delay: int(0.002 * 218750) = 437 samples at the full
// 218.75 kHz processing rate (software formula int(0.002*fs))
localparam DELAY_SAMPLES = 437;
localparam DELAY_BITS = 9;  // log2(512) > 437

// Delay line buffers (inferred as block RAM)
// Use initial block instead of reset loop for RAM initialization
(* ram_style = "block" *) reg signed [31:0] delay_l [0:511];
(* ram_style = "block" *) reg signed [31:0] delay_r [0:511];

// Initialize RAM to zero (synthesis will create MIF)
integer i;
initial begin
    for (i = 0; i < 512; i = i + 1) begin
        delay_l[i] = 0;
        delay_r[i] = 0;
    end
end

reg [DELAY_BITS-1:0] delay_idx;

// Room level coefficients - use case statement instead of ROM for small table
function signed [31:0] get_room_coef;
    input [3:0] level;
    begin
        case (level)
            4'd0:    get_room_coef = 32'h00000000;  // Off
            4'd1:    get_room_coef = 32'h16C8B439;  // 0.178 (-15dB)
            4'd2:    get_room_coef = 32'h19999999;  // 0.20  (-14dB)
            4'd3:    get_room_coef = 32'h1CAC0831;  // 0.224 (-13dB)
            4'd4:    get_room_coef = 32'h20000000;  // 0.25  (-12dB)
            4'd5:    get_room_coef = 32'h2CCCCCCD;  // 0.35  (-9dB)
            4'd6:    get_room_coef = 32'h40000000;  // 0.50  (-6dB)
            4'd7:    get_room_coef = 32'h5AE147AE;  // 0.71  (-3dB)
            4'd8:    get_room_coef = 32'h6528F5C3;  // 0.79  (-2dB)
            4'd9:    get_room_coef = 32'h71EB851F;  // 0.89  (-1dB)
            default: get_room_coef = 32'h00000000;
        endcase
    end
endfunction

// State machine
reg [2:0] state;
localparam S_IDLE   = 3'd0;
localparam S_READ   = 3'd1;
localparam S_MULT_L = 3'd2;
localparam S_MULT_R = 3'd3;
localparam S_OUTPUT = 3'd4;

// Working registers
reg signed [31:0] in_left_r, in_right_r;
reg signed [31:0] delayed_l, delayed_r;
reg signed [31:0] crossfeed_l;
reg signed [31:0] room_coef;

// Single shared multiplier
reg signed [31:0] mult_a, mult_b;
wire signed [63:0] mult_result = $signed(mult_a) * $signed(mult_b);

// Read index calculation
wire [DELAY_BITS-1:0] read_idx = (delay_idx >= DELAY_SAMPLES) ?
                                  (delay_idx - DELAY_SAMPLES) :
                                  (delay_idx + 9'd512 - DELAY_SAMPLES);

always @(posedge clk) begin
    if (reset) begin
        delay_idx <= 0;
        state <= S_IDLE;
        out_left <= 0;
        out_right <= 0;
        in_left_r <= 0;
        in_right_r <= 0;
        delayed_l <= 0;
        delayed_r <= 0;
        crossfeed_l <= 0;
        room_coef <= 0;
        mult_a <= 0;
        mult_b <= 0;
        // DO NOT reset RAM contents - let initial block handle it
    end
    else begin
        case (state)
            S_IDLE: begin
                if (ce) begin
                    // Latch inputs
                    in_left_r <= in_left;
                    in_right_r <= in_right;

                    // Read coefficient using function
                    room_coef <= get_room_coef(room_level);

                    // Store new samples in delay line
                    delay_l[delay_idx] <= in_left;
                    delay_r[delay_idx] <= in_right;

                    // Read delayed samples (R->L, L->R for crossfeed)
                    // Block RAM has 1 cycle latency
                    state <= S_READ;
                end
            end

            S_READ: begin
                // Read from block RAM (crossfeed: R->L, L->R)
                delayed_l <= delay_r[read_idx];
                delayed_r <= delay_l[read_idx];

                // Advance index after read
                delay_idx <= (delay_idx + 1) & 9'h1FF;

                if (!enable || room_level == 0) begin
                    // Bypass
                    out_left <= in_left_r;
                    out_right <= in_right_r;
                    state <= S_IDLE;
                end
                else begin
                    state <= S_MULT_L;
                end
            end

            S_MULT_L: begin
                // Start L crossfeed multiply
                mult_a <= delayed_l;
                mult_b <= room_coef;
                state <= S_MULT_R;
            end

            S_MULT_R: begin
                // Store L result, start R multiply
                // Q4.28 * Q1.31 -> product has 59 fraction bits;
                // Q4.28 result = product >> 31 = bits [62:31]
                crossfeed_l <= mult_result[62:31];
                mult_a <= delayed_r;
                mult_b <= room_coef;
                state <= S_OUTPUT;
            end

            S_OUTPUT: begin
                // Output with crossfeed
                out_left  <= in_left_r  + crossfeed_l;
                out_right <= in_right_r + mult_result[62:31];
                state <= S_IDLE;
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
