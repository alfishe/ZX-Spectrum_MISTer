//============================================================================
//  Turbosound-FM with HQ Audio Pipeline
//
//  Copyright (C) 2018 Ilia Sharin
//  Copyright (C) 2018 Sorgelig
//  Copyright (C) 2025 HQ Audio Pipeline port from unreal-ng
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================

module turbosound_hq
(
    input         RESET,       // Chip RESET (active high)
    input         CLK,         // Global clock
    input         CE,          // YM2203 Master Clock enable

    input         ENABLE,
    input         PSG_MIX,
    input         PSG_TYPE,

    input         BDIR,        // Bus Direction (0 - read , 1 - write)
    input         BC,          // Bus control
    input   [7:0] DI,          // Data In
    output  [7:0] DO,          // Data Out

    input         HQ_ENABLE,   // Enable HQ audio pipeline
    input   [1:0] STEREO_MODE, // 0=ABC, 1=ACB, 2=Mono
    input         PUNCH_ENABLE,// Enable punch enhancement
    input         FIR_BYPASS,  // Bypass FIR filter (for debugging)
    input         DC_BYPASS,   // Bypass DC filter (for debugging)
    input   [3:0] ROOM_LEVEL,  // Room crossfeed level (0=off, 1-9)
    input   [2:0] VOICING,     // 0=Flat, 1=Classic, 2=Headphones, 3=Warm, 4=TV, 5=Small speaker
    input         LEGACY_AA,   // HQ off: band-limit the legacy output

    output [11:0] CHANNEL_L,
    output [11:0] CHANNEL_R,

    output        HQ_VALID,    // HQ sample strobe
    output signed [15:0] HQ_L,
    output signed [15:0] HQ_R
);


reg       RESET_s;
reg       BDIR_s;
reg       BC_s;
reg [7:0] DI_s;

always_ff @(posedge CLK) begin
    reg       RESET_d;
    reg       BDIR_d;
    reg       BC_d;
    reg [7:0] DI_d;

    RESET_d <= RESET;
    BDIR_d <= BDIR;
    BC_d <= BC;
    DI_d <= DI;

    RESET_s <= RESET_d;
    BDIR_s <= BDIR_d;
    BC_s <= BC_d;
    DI_s <= DI_d;
end


reg ay_select = 1;
reg stat_sel  = 1;
reg fm_ena    = 0;
reg ym_wr     = 0;
reg [7:0] ym_di;

always_ff @(posedge CLK or posedge RESET_s) begin
    reg old_BDIR = 0;
    reg ym_acc = 0;

    if (RESET_s) begin
        ay_select <= 1;
        stat_sel  <= 1;
        fm_ena    <= 0;
        ym_acc    <= 0;
        ym_wr     <= 0;
        old_BDIR  <= 0;
    end
    else begin
        ym_wr <= 0;
        old_BDIR <= BDIR_s;
        if (~old_BDIR & BDIR_s) begin
            if(BC_s & &DI_s[7:3]) begin
                ay_select <=  DI_s[0];
                stat_sel  <=  DI_s[1];
                fm_ena    <= ~DI_s[2];
                ym_acc    <= 0;
            end
            else if(BC_s) begin
                ym_acc <= !DI_s[7:4] || fm_ena;
                ym_wr  <= !DI_s[7:4] || fm_ena;
            end
            else begin
                ym_wr <= ym_acc;
            end
            ym_di <= DI_s;
        end
    end
end


wire  [7:0] psg_ch_a_0;
wire  [7:0] psg_ch_b_0;
wire  [7:0] psg_ch_c_0;
wire  [4:0] lvl_a_0, lvl_b_0, lvl_c_0;
wire [15:0] opn_0;
wire  [7:0] DO_0;

jt03 ym2203_0
(
    .rst(RESET_s),
    .clk(CLK),
    .cen(CE),
    .din(ym_di),
    .addr((BDIR_s|ym_wr) ? ~BC_s : stat_sel),
    .cs_n(ay_select),
    .wr_n(~ym_wr),
    .dout(DO_0),

    .psg_type(PSG_TYPE),
    .psg_A(psg_ch_a_0),
    .psg_B(psg_ch_b_0),
    .psg_C(psg_ch_c_0),
    .psg_lvl_A(lvl_a_0),
    .psg_lvl_B(lvl_b_0),
    .psg_lvl_C(lvl_c_0),

    .fm_snd(opn_0)
);

wire  [7:0] psg_ch_a_1;
wire  [7:0] psg_ch_b_1;
wire  [7:0] psg_ch_c_1;
wire  [4:0] lvl_a_1, lvl_b_1, lvl_c_1;
wire [15:0] opn_1;
wire  [7:0] DO_1;

jt03 ym2203_1
(
    .rst(RESET_s),
    .clk(CLK),
    .cen(CE),
    .din(ym_di),
    .addr((BDIR_s|ym_wr) ? ~BC_s : stat_sel),
    .cs_n(~ay_select),
    .wr_n(~ym_wr),
    .dout(DO_1),

    .psg_type(PSG_TYPE),
    .psg_A(psg_ch_a_1),
    .psg_B(psg_ch_b_1),
    .psg_C(psg_ch_c_1),
    .psg_lvl_A(lvl_a_1),
    .psg_lvl_B(lvl_b_1),
    .psg_lvl_C(lvl_c_1),

    .fm_snd(opn_1)
);

assign DO = ay_select ? DO_1 : DO_0;


reg  [8:0] sum_ch_a, sum_ch_b, sum_ch_c;
reg  [7:0] psg_a, psg_b, psg_c;
reg [11:0] psg_l, psg_r, opn_s;
reg [11:0] ch_l, ch_r;

always @(posedge CLK) begin
    sum_ch_a <= { 1'b0, psg_ch_a_1 } + { 1'b0, psg_ch_a_0 };
    sum_ch_b <= { 1'b0, psg_ch_b_1 } + { 1'b0, psg_ch_b_0 };
    sum_ch_c <= { 1'b0, psg_ch_c_1 } + { 1'b0, psg_ch_c_0 };

    psg_a <= sum_ch_a[8] ? 8'hFF : sum_ch_a[7:0];
    psg_b <= sum_ch_b[8] ? 8'hFF : sum_ch_b[7:0];
    psg_c <= sum_ch_c[8] ? 8'hFF : sum_ch_c[7:0];

    psg_l <= {3'b000,                   psg_a, 1'd0} + {4'b0000, PSG_MIX ? psg_c : psg_b};
    psg_r <= {3'b000, PSG_MIX ? psg_b : psg_c, 1'd0} + {4'b0000, PSG_MIX ? psg_c : psg_b};
    opn_s <= {{2{opn_0[15]}}, opn_0[15:6]} + {{2{opn_1[15]}}, opn_1[15:6]};

    ch_l <= ~ENABLE ? 12'd0 : fm_ena ? $signed(opn_s) + $signed(psg_l) : $signed(psg_l);
    ch_r <= ~ENABLE ? 12'd0 : fm_ena ? $signed(opn_s) + $signed(psg_r) : $signed(psg_r);
end

// HQ off + LEGACY_AA: band-limit the legacy output with the idle HQ FIR
wire legacy_aa = ~HQ_ENABLE & LEGACY_AA;

wire fir_valid_raw_l, fir_valid_raw_r;
wire signed [31:0] fir_raw_l, fir_raw_r;

function [11:0] sat12_round;          // Q4.28 -> signed 12-bit
    input signed [31:0] v;
    reg   signed [31:0] r;
    begin
        r = (v + 32'sd32768) >>> 16;
        sat12_round = (r > 32'sd2047) ? 12'h7FF : (r < -32'sd2048) ? 12'h800 : r[11:0];
    end
endfunction

reg [11:0] aa_l, aa_r;
always @(posedge CLK) begin
    if (fir_valid_raw_l) begin
        aa_l <= sat12_round(fir_raw_l);
        aa_r <= sat12_round(fir_raw_r);
    end
end

assign CHANNEL_L = legacy_aa ? aa_l : ch_l;
assign CHANNEL_R = legacy_aa ? aa_r : ch_r;


// generator rate: CE / 16 = 218.75 kHz
reg [3:0] gen_div;
wire ce_gen = CE && (gen_div == 0);

always @(posedge CLK) begin
    if (RESET_s)
        gen_div <= 0;
    else if (CE)
        gen_div <= gen_div + 1'd1;
end

// both chips summed unsaturated; the / 3 is folded into the pans
wire [31:0] dac_a, dac_b, dac_c;

ay_dac dac_ch_a (
    .clk     (CLK),
    .mode    (PSG_TYPE),
    .level_0 (lvl_a_0),
    .level_1 (lvl_a_1),
    .dac_out (dac_a)
);

ay_dac dac_ch_b (
    .clk     (CLK),
    .mode    (PSG_TYPE),
    .level_0 (lvl_b_0),
    .level_1 (lvl_b_1),
    .dac_out (dac_b)
);

ay_dac dac_ch_c (
    .clk     (CLK),
    .mode    (PSG_TYPE),
    .level_0 (lvl_c_0),
    .level_1 (lvl_c_1),
    .dac_out (dac_c)
);

wire [31:0] mixed_l, mixed_r;

ay_stereo_mixer stereo_mix (
    .clk         (CLK),
    .ce          (ce_gen),
    .stereo_mode (STEREO_MODE),
    .ch_a        (dac_a),
    .ch_b        (dac_b),
    .ch_c        (dac_c),
    .out_left    (mixed_l),
    .out_right   (mixed_r)
);

wire signed [31:0] dc_raw_l, dc_raw_r;

ay_dc_filter dc_filt_l (
    .clk       (CLK),
    .ce        (ce_gen),
    .reset     (RESET_s),
    .in_sample (mixed_l),
    .out_sample(dc_raw_l)
);

ay_dc_filter dc_filt_r (
    .clk       (CLK),
    .ce        (ce_gen),
    .reset     (RESET_s),
    .in_sample (mixed_r),
    .out_sample(dc_raw_r)
);

// bypass: subtract the typical mean (0.25)
wire signed [31:0] dc_filtered_l = DC_BYPASS ? $signed(mixed_l) - 32'sh04000000 : dc_raw_l;
wire signed [31:0] dc_filtered_r = DC_BYPASS ? $signed(mixed_r) - 32'sh04000000 : dc_raw_r;


// HQ off + LEGACY_AA: the legacy output (signed 12-bit) as value / 4096
wire signed [31:0] fir_in_l = legacy_aa ? {{4{ch_l[11]}}, ch_l, 16'd0} : dc_filtered_l;
wire signed [31:0] fir_in_r = legacy_aa ? {{4{ch_r[11]}}, ch_r, 16'd0} : dc_filtered_r;

ay_fir_decimator fir_l (
    .clk       (CLK),
    .ce_in     (ce_gen),
    .reset     (RESET_s),
    .in_sample (fir_in_l),
    .out_valid (fir_valid_raw_l),
    .out_sample(fir_raw_l)
);

ay_fir_decimator fir_r (
    .clk       (CLK),
    .ce_in     (ce_gen),
    .reset     (RESET_s),
    .in_sample (fir_in_r),
    .out_valid (fir_valid_raw_r),
    .out_sample(fir_raw_r)
);

wire fir_valid = FIR_BYPASS ? ce_gen : fir_valid_raw_l;
wire signed [31:0] fir_out_l = FIR_BYPASS ? dc_filtered_l : fir_raw_l;
wire signed [31:0] fir_out_r = FIR_BYPASS ? dc_filtered_r : fir_raw_r;

// stage strobes: voicing up to 40 clk, punch 18 clk, room 5 clk
reg [73:0] valid_sr;
always @(posedge CLK) begin
    if (RESET_s) valid_sr <= '0;
    else         valid_sr <= {valid_sr[72:0], fir_valid};
end
wire punch_ce  = valid_sr[42];
wire room_ce   = valid_sr[66];
wire out_latch = valid_sr[73];

wire signed [31:0] voiced_l, voiced_r;

ay_voicing voicing (
    .clk       (CLK),
    .ce        (fir_valid),
    .reset     (RESET_s),
    .preset    (VOICING),
    .in_left   (fir_out_l),
    .in_right  (fir_out_r),
    .out_left  (voiced_l),
    .out_right (voiced_r)
);

wire signed [31:0] punch_out_l, punch_out_r;

ay_punch_enhancer punch (
    .clk       (CLK),
    .ce        (punch_ce),
    .reset     (RESET_s),
    .enable    (PUNCH_ENABLE),
    .preset    (1'b0),
    .in_left   (voiced_l),
    .in_right  (voiced_r),
    .out_left  (punch_out_l),
    .out_right (punch_out_r)
);

wire [31:0] room_out_l, room_out_r;

ay_room_crossfeed room (
    .clk        (CLK),
    .ce         (room_ce),
    .reset      (RESET_s),
    .enable     (ROOM_LEVEL != 0),
    .room_level (ROOM_LEVEL),
    .in_left    (punch_out_l),
    .in_right   (punch_out_r),
    .out_left   (room_out_l),
    .out_right  (room_out_r)
);

// FM scaled to Q4.28
wire signed [31:0] fm_scaled = fm_ena ? {{4{opn_s[11]}}, opn_s, 16'd0} : 32'd0;
wire signed [31:0] final_l = room_out_l + fm_scaled;
wire signed [31:0] final_r = room_out_r + fm_scaled;

// Q4.28 -> int16, 1.0 = 16384
function signed [15:0] saturate;
    input signed [31:0] val;
    reg signed [18:0] extracted;
    begin
        extracted = val >>> 14;
        if (extracted > 19'sh07FFF)
            saturate = 16'sh7FFF;
        else if (extracted < -19'sh08000)
            saturate = 16'sh8000;
        else
            saturate = extracted[15:0];
    end
endfunction

// first-order hold across the 16 CE ticks of a generator sample
reg hq_valid_r;
reg signed [15:0] hq_l_r, hq_r_r;
reg signed [31:0] foh_l, foh_r;
reg signed [31:0] foh_dl, foh_dr;

always @(posedge CLK) begin
    if (RESET_s) begin
        hq_valid_r <= 0;
        hq_l_r <= 0;
        hq_r_r <= 0;
        foh_l <= 0; foh_r <= 0;
        foh_dl <= 0; foh_dr <= 0;
    end
    else begin
        hq_valid_r <= HQ_ENABLE ? out_latch : 1'b0;
        if (out_latch && HQ_ENABLE) begin
            foh_dl <= (($signed(ENABLE ? final_l : 32'sd0)) - foh_l) >>> 4;
            foh_dr <= (($signed(ENABLE ? final_r : 32'sd0)) - foh_r) >>> 4;
        end
        if (CE) begin
            foh_l <= foh_l + foh_dl;
            foh_r <= foh_r + foh_dr;
            hq_l_r <= saturate(foh_l + foh_dl);
            hq_r_r <= saturate(foh_r + foh_dr);
        end
    end
end

assign HQ_VALID = hq_valid_r;
assign HQ_L = hq_l_r;
assign HQ_R = hq_r_r;

endmodule
