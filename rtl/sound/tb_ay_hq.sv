//
// Testbench for AY HQ Audio Pipeline
//
// Generates test vectors that can be compared against unreal-ng output.
//

`timescale 1ns / 1ps

module tb_ay_hq;

// Clock and reset
reg clk;
reg reset;

// PSG interface
reg bdir, bc;
reg [7:0] di;
wire [7:0] do_out;

// Configuration
reg mode;
reg [1:0] stereo_mode;
reg hq_enable;
reg punch_enable;
reg punch_preset;
reg [3:0] room_level;

// Outputs
wire [5:0] active;
wire audio_valid;
wire signed [15:0] audio_l, audio_r;
wire [7:0] channel_a, channel_b, channel_c;

// Clock generation: 56.75 MHz system clock
localparam CLK_PERIOD = 17.62;  // ~56.75 MHz
always #(CLK_PERIOD/2) clk = ~clk;

// PSG clock enable: 1.75 MHz = 56.75 / 32.43
reg [5:0] psg_div;
wire ce_psg = (psg_div == 0);
always @(posedge clk) begin
    if (reset)
        psg_div <= 0;
    else
        psg_div <= (psg_div == 31) ? 0 : psg_div + 1;
end

// DUT
ay_hq_top dut (
    .CLK          (clk),
    .CE_PSG       (ce_psg),
    .RESET        (reset),
    .BDIR         (bdir),
    .BC           (bc),
    .DI           (di),
    .DO           (do_out),
    .IOA_in       (8'hFF),
    .IOA_out      (),
    .IOB_in       (8'hFF),
    .IOB_out      (),
    .MODE         (mode),
    .STEREO_MODE  (stereo_mode),
    .HQ_ENABLE    (hq_enable),
    .PUNCH_ENABLE (punch_enable),
    .PUNCH_PRESET (punch_preset),
    .ROOM_LEVEL   (room_level),
    .ACTIVE       (active),
    .AUDIO_VALID  (audio_valid),
    .AUDIO_L      (audio_l),
    .AUDIO_R      (audio_r),
    .CHANNEL_A    (channel_a),
    .CHANNEL_B    (channel_b),
    .CHANNEL_C    (channel_c)
);

// Write to AY register
task ay_write;
    input [7:0] reg_addr;
    input [7:0] value;
    begin
        // Set address
        @(posedge clk);
        bdir <= 1; bc <= 1; di <= reg_addr;
        @(posedge clk);
        bdir <= 0; bc <= 0;
        @(posedge clk);
        // Write value
        bdir <= 1; bc <= 0; di <= value;
        @(posedge clk);
        bdir <= 0; bc <= 0;
        @(posedge clk);
    end
endtask

// Sample counter for audio output logging
integer sample_count;
integer audio_file;

initial begin
    $display("AY HQ Pipeline Testbench");
    $display("========================");

    // Initialize
    clk = 0;
    reset = 1;
    bdir = 0;
    bc = 0;
    di = 0;
    mode = 0;           // AY-3-8910 mode
    stereo_mode = 0;    // ABC stereo
    hq_enable = 1;      // Enable HQ pipeline
    punch_enable = 0;   // Disable punch for basic test
    punch_preset = 0;   // AY preset
    room_level = 0;     // No room crossfeed
    sample_count = 0;

    // Open output file
    audio_file = $fopen("ay_hq_output.txt", "w");
    if (audio_file == 0) begin
        $display("ERROR: Could not open output file");
        $finish;
    end
    $fdisplay(audio_file, "# AY HQ Audio Output");
    $fdisplay(audio_file, "# Sample, Left, Right");

    // Release reset
    #100;
    reset = 0;
    #100;

    // ========================================
    // Test 1: Simple tone on channel A
    // ========================================
    $display("\nTest 1: 440Hz tone on channel A");

    // Frequency = 1750000 / (16 * period)
    // For 440Hz: period = 1750000 / (16 * 440) = 248.58 ≈ 249
    ay_write(8'h00, 8'hF9);  // R0: Fine tune A = 0xF9
    ay_write(8'h01, 8'h00);  // R1: Coarse tune A = 0x00 (period = 249)
    ay_write(8'h07, 8'h3E);  // R7: Mixer - enable tone A only
    ay_write(8'h08, 8'h0F);  // R8: Volume A = max (15)

    // Run for 1000 audio samples (~22ms)
    repeat (1000) begin
        @(posedge audio_valid);
        $fdisplay(audio_file, "%d, %d, %d", sample_count, audio_l, audio_r);
        sample_count = sample_count + 1;
    end

    // ========================================
    // Test 2: All three channels
    // ========================================
    $display("\nTest 2: Three-channel chord (A=440Hz, B=550Hz, C=660Hz)");

    // Channel A: 440Hz (period 249)
    ay_write(8'h00, 8'hF9);
    ay_write(8'h01, 8'h00);

    // Channel B: 550Hz (period 199)
    ay_write(8'h02, 8'hC7);
    ay_write(8'h03, 8'h00);

    // Channel C: 660Hz (period 166)
    ay_write(8'h04, 8'hA6);
    ay_write(8'h05, 8'h00);

    // Enable all channels
    ay_write(8'h07, 8'h38);  // Mixer: all tones on, all noise off
    ay_write(8'h08, 8'h0F);  // Volume A = max
    ay_write(8'h09, 8'h0C);  // Volume B = 12
    ay_write(8'h0A, 8'h0A);  // Volume C = 10

    repeat (1000) begin
        @(posedge audio_valid);
        $fdisplay(audio_file, "%d, %d, %d", sample_count, audio_l, audio_r);
        sample_count = sample_count + 1;
    end

    // ========================================
    // Test 3: Envelope
    // ========================================
    $display("\nTest 3: Envelope (sawtooth)");

    ay_write(8'h0B, 8'h00);  // R11: Envelope fine = 0
    ay_write(8'h0C, 8'h10);  // R12: Envelope coarse = 16
    ay_write(8'h0D, 8'h0C);  // R13: Envelope shape = //// (continuous up)
    ay_write(8'h08, 8'h10);  // R8: Volume A = envelope mode

    repeat (2000) begin
        @(posedge audio_valid);
        $fdisplay(audio_file, "%d, %d, %d", sample_count, audio_l, audio_r);
        sample_count = sample_count + 1;
    end

    // ========================================
    // Test 4: Enable punch enhancement
    // ========================================
    $display("\nTest 4: With punch enhancement");
    punch_enable = 1;

    repeat (1000) begin
        @(posedge audio_valid);
        $fdisplay(audio_file, "%d, %d, %d", sample_count, audio_l, audio_r);
        sample_count = sample_count + 1;
    end

    // ========================================
    // Test 5: Enable room crossfeed
    // ========================================
    $display("\nTest 5: With room crossfeed (-14dB)");
    room_level = 2;  // -14dB

    repeat (1000) begin
        @(posedge audio_valid);
        $fdisplay(audio_file, "%d, %d, %d", sample_count, audio_l, audio_r);
        sample_count = sample_count + 1;
    end

    // Done
    $fclose(audio_file);
    $display("\n========================");
    $display("Test complete. %d samples written to ay_hq_output.txt", sample_count);
    $finish;
end

// Timeout
initial begin
    #100000000;  // 100ms timeout
    $display("ERROR: Simulation timeout");
    $finish;
end

endmodule
