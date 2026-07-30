//
// AY-3-8910 / YM2149 DAC - exact port of unreal-ng amplitude tables
//
// Takes the 5-bit pre-DAC channel levels from BOTH TurboSound chips and
// returns the sum of the two software DAC table lookups in Q1.31.
// Summing here (instead of saturating 8-bit amplitudes upstream) matches
// unreal-ng SoundChip_TurboSound, which adds the two chips' mixed outputs
// in floating point without saturation. Output range is [0.0, 2.0).
//
// mode follows ym2149.sv volTable convention: 0 = YM2149, 1 = AY-3-8910.
// Table values are Q1.31 conversions of soundchip_ay8910.h
// AY_DAC_TABLE / YM_DAC_TABLE (32 entries each).
//
// SYNTHESIS-HARDENED STRUCTURE: each chip's lookup is a SEPARATE module
// instance (ay_dac_lut) with hierarchy preserved. An earlier single-module
// implementation reading one table array at two addresses was mapped by
// Quartus 17 onto a dual-port RAM with one port's address tied to zero
// (Warning 10030), silencing the second TurboSound chip in hardware while
// simulating correctly. Independent single-read instances make that class
// of transformation impossible.
//
// Copyright (c) 2025 - Port from unreal-ng emulator
//

module ay_dac_lut
(
    input  wire        clk,
    input  wire        mode,      // 0 = YM2149, 1 = AY-3-8910
    input  wire [4:0]  level,
    output reg  [31:0] value      // unsigned Q1.31 [0.0, 1.0]
);

// Registered input isolates this lookup cone from upstream logic
reg [4:0] level_r;
reg       mode_r;

always @(posedge clk) begin
    level_r <= level;
    mode_r  <= mode;

    if (mode_r) begin
        // AY-3-8910 curve (software AY_DAC_TABLE, paired entries)
        case (level_r)
            5'd0,  5'd1:  value <= 32'h00000000;
            5'd2,  5'd3:  value <= 32'h01478148;  // 0.00999465934
            5'd4,  5'd5:  value <= 32'h01D981DA;  // 0.01445029374
            5'd6,  5'd7:  value <= 32'h02B202B2;  // 0.02105745022
            5'd8,  5'd9:  value <= 32'h03EE03EE;  // 0.03070115206
            5'd10, 5'd11: value <= 32'h05D485D5;  // 0.04554818036
            5'd12, 5'd13: value <= 32'h08418842;  // 0.06449988556
            5'd14, 5'd15: value <= 32'h0DBE0DBE;  // 0.10736247807
            5'd16, 5'd17: value <= 32'h10341034;  // 0.12658884566
            5'd18, 5'd19: value <= 32'h1A3D1A3D;  // 0.20498970016
            5'd20, 5'd21: value <= 32'h25672567;  // 0.29221026932
            5'd22, 5'd23: value <= 32'h2FB92FB9;  // 0.37283894102
            5'd24, 5'd25: value <= 32'h3F0B3F0B;  // 0.49253070878
            5'd26, 5'd27: value <= 32'h51525152;  // 0.63532463569
            5'd28, 5'd29: value <= 32'h671D671D;  // 0.80558480201
            default:      value <= 32'h7FFFFFFF;  // 1.0 (30, 31)
        endcase
    end
    else begin
        // YM2149 curve (software YM_DAC_TABLE)
        case (level_r)
            5'd0,  5'd1:  value <= 32'h00000000;
            5'd2:  value <= 32'h00988099;  // 0.00465400168
            5'd3:  value <= 32'h00FD00FD;  // 0.00772106508
            5'd4:  value <= 32'h01670167;  // 0.01095597772
            5'd5:  value <= 32'h01C981CA;  // 0.01396200504
            5'd6:  value <= 32'h022D022D;  // 0.01699855039
            5'd7:  value <= 32'h02900290;  // 0.02001983673
            5'd8:  value <= 32'h031E831F;  // 0.02436865797
            5'd9:  value <= 32'h03CD03CD;  // 0.02969405661
            5'd10: value <= 32'h047D047D;  // 0.03506523232
            5'd11: value <= 32'h052B852C;  // 0.04039063096
            5'd12: value <= 32'h06368637;  // 0.04853894865
            5'd13: value <= 32'h07778778;  // 0.05833524071
            5'd14: value <= 32'h08B608B6;  // 0.06805523766
            5'd15: value <= 32'h09F489F5;  // 0.07777523461
            5'd16: value <= 32'h0BD78BD8;  // 0.09251544976
            5'd17: value <= 32'h0E380E38;  // 0.11108567941
            5'd18: value <= 32'h109B909C;  // 0.12974746319
            5'd19: value <= 32'h13019302;  // 0.14848554208
            5'd20: value <= 32'h169D169D;  // 0.17666895552
            5'd21: value <= 32'h1B141B14;  // 0.21155107958
            5'd22: value <= 32'h1F899F8A;  // 0.24638742657
            5'd23: value <= 32'h23FB23FB;  // 0.28110170138
            5'd24: value <= 32'h2AB7AAB8;  // 0.33373006790
            5'd25: value <= 32'h33413341;  // 0.40042725261
            5'd26: value <= 32'h3BD33BD3;  // 0.46738384070
            5'd27: value <= 32'h44684468;  // 0.53443198291
            5'd28: value <= 32'h514D514D;  // 0.63517204547
            5'd29: value <= 32'h61066106;  // 0.75800717174
            5'd30: value <= 32'h70A170A1;  // 0.87992675669
            default: value <= 32'h7FFFFFFF; // 1.0 (31)
        endcase
    end
end

endmodule


module ay_dac
(
    input  wire        clk,
    input  wire        mode,       // 0 = YM2149, 1 = AY-3-8910 (ym2149.sv convention)
    input  wire [4:0]  level_0,    // 5-bit channel level, chip 0
    input  wire [4:0]  level_1,    // 5-bit channel level, chip 1
    output reg  [31:0] dac_out     // unsigned Q1.31 sum [0.0, 2.0)
);

wire [31:0] val_0, val_1;

(* keep_hierarchy = "yes" *) ay_dac_lut lut_0 (.clk(clk), .mode(mode), .level(level_0), .value(val_0));
(* keep_hierarchy = "yes" *) ay_dac_lut lut_1 (.clk(clk), .mode(mode), .level(level_1), .value(val_1));

// Sum of both chips (max 0x7FFFFFFF + 0x7FFFFFFF = 0xFFFFFFFE, fits)
always @(posedge clk) begin
    dac_out <= val_0 + val_1;
end

endmodule
