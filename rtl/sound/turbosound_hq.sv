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

    // HQ configuration
    input         HQ_ENABLE,   // Enable HQ audio pipeline
    input   [1:0] STEREO_MODE, // 0=ABC, 1=ACB, 2=Mono
    input         PUNCH_ENABLE,// Enable punch enhancement
    input         FIR_BYPASS,  // Bypass FIR filter (for debugging)
    input         DC_BYPASS,   // Bypass DC filter (for debugging)
    input   [3:0] ROOM_LEVEL,  // Room crossfeed level (0=off, 1-9)

    // 12-bit legacy output (compatible with existing design)
    output [11:0] CHANNEL_L,
    output [11:0] CHANNEL_R,

    // 16-bit HQ output
    output        HQ_VALID,    // Pulse at 44.1kHz when HQ sample ready
    output signed [15:0] HQ_L,
    output signed [15:0] HQ_R
);

// ============================================================================
// Input synchronization
// ============================================================================

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

// ============================================================================
// Chip selection and FM enable logic
// ============================================================================

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

// ============================================================================
// YM2203 chips (jt03)
// ============================================================================

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

// ============================================================================
// Legacy mixer (12-bit output, compatible with original)
// ============================================================================

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

assign CHANNEL_L = ch_l;
assign CHANNEL_R = ch_r;

// ============================================================================
// HQ Audio Pipeline
// ============================================================================

// Generator clock enable: CE / 16 = 218.75 kHz
// CE is 3.5 MHz. The embedded YM2149 SSG receives clk_en_ssg = CE/2 = 1.75 MHz
// and divides internally by 8 (SEL=0), so channel levels update at exactly
// 3.5 MHz / 16 = 218.75 kHz. This divider is frequency-locked to that rate,
// matching the unreal-ng software generator rate (AY clock 1.75 MHz / 8).
reg [3:0] gen_div;
wire ce_gen = CE && (gen_div == 0);

always @(posedge CLK) begin
    if (RESET_s)
        gen_div <= 0;
    else if (CE)
        gen_div <= gen_div + 1'd1;
end

// HQ DAC: exact unreal-ng amplitude tables, fed from the 5-bit pre-DAC
// levels of both chips. The two chips are summed here WITHOUT saturation
// (matching software TurboSound float addition); dac_* range is [0.0, 2.0)
// and the /3 folded into the pan coefficients keeps the final mix <= 1.0.
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

// Stereo mixer
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

// DC offset filter (optional bypass)
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

// DC filter bypass mux - when bypassed, subtract the typical signal mean.
// mixed range is [0, ~0.5] single-chip, so center around 0.25 (Q4.28).
// (The old constant 1.0 slammed the signal to -0.75 FS into the output
// compressor = severe distortion whenever the bypass was selected.)
wire signed [31:0] dc_filtered_l = DC_BYPASS ? $signed(mixed_l) - 32'sh04000000 : dc_raw_l;
wire signed [31:0] dc_filtered_r = DC_BYPASS ? $signed(mixed_r) - 32'sh04000000 : dc_raw_r;

// FIR decimator (218.75 kHz -> 44.1 kHz) - optional bypass
wire fir_valid_raw_l, fir_valid_raw_r;
wire signed [31:0] fir_raw_l, fir_raw_r;

ay_fir_decimator fir_l (
    .clk       (CLK),
    .ce_in     (ce_gen),
    .reset     (RESET_s),
    .in_sample (dc_filtered_l),
    .out_valid (fir_valid_raw_l),
    .out_sample(fir_raw_l)
);

ay_fir_decimator fir_r (
    .clk       (CLK),
    .ce_in     (ce_gen),
    .reset     (RESET_s),
    .in_sample (dc_filtered_r),
    .out_valid (fir_valid_raw_r),
    .out_sample(fir_raw_r)
);

// FIR bypass: pass the DC-filtered stream straight through at full rate.
// (No decimation anywhere, so bypassing the FIR is a pure filter A/B.)
wire fir_valid = FIR_BYPASS ? ce_gen : fir_valid_raw_l;
wire signed [31:0] fir_out_l = FIR_BYPASS ? dc_filtered_l : fir_raw_l;
wire signed [31:0] fir_out_r = FIR_BYPASS ? dc_filtered_r : fir_raw_r;

// Stage handoff timing: the punch FSM needs up to 18 clk after fir_valid,
// the room FSM 5 clk. Delay each downstream stage's clock enable so it
// consumes the CURRENT upstream sample instead of the previous one.
reg [30:0] valid_sr;
always @(posedge CLK) begin
    if (RESET_s) valid_sr <= '0;
    else         valid_sr <= {valid_sr[29:0], fir_valid};
end
wire room_ce   = valid_sr[23];  // punch settled (18 clk) + margin
wire out_latch = valid_sr[30];  // room settled (+5 clk) + margin

// Punch enhancement
wire signed [31:0] punch_out_l, punch_out_r;

ay_punch_enhancer punch (
    .clk       (CLK),
    .ce        (fir_valid),
    .reset     (RESET_s),
    .enable    (PUNCH_ENABLE),
    .preset    (1'b0),  // AY preset (gentle)
    .in_left   (fir_out_l),
    .in_right  (fir_out_r),
    .out_left  (punch_out_l),
    .out_right (punch_out_r)
);

// Room crossfeed
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

// Output conversion: Q4.28 to 16-bit signed
// The room_out is in Q4.28 format. We need to extract 16 bits.
// For Q4.28: bits [30:15] give us a 16-bit value with 2 integer bits headroom
//
// Add FM sound if enabled - scale FM to match Q4.28
// opn_s is 12-bit signed, scale it to Q4.28: shift left 16 bits
wire signed [31:0] fm_scaled = fm_ena ? {{4{opn_s[11]}}, opn_s, 16'd0} : 32'd0;
wire signed [31:0] final_l = room_out_l + fm_scaled;
wire signed [31:0] final_r = room_out_r + fm_scaled;

// Saturation and output extraction
// The ZX top level feeds this into compr(), a 2x-gain compressor with its
// knee at |14044|. The HQ signal must stay below the knee to remain linear:
// single-chip |mixed| <= 0.5, so scale 1.0 -> 16384 (>>> 14) giving peaks
// of +/-8192 - comfortably linear, and compr's 2x restores the loudness.
// (>>> 13 put envelope-bass peaks at 16384, straddling the knee: 4:1
// crush above / 2x below = the audible "squeaking" distortion.)
function signed [15:0] saturate;
    input signed [31:0] val;
    reg signed [18:0] extracted;
    begin
        extracted = val >>> 14;  // Q4.28 -> int16 with 1.0 = 16384
        if (extracted > 19'sh07FFF)
            saturate = 16'sh7FFF;
        else if (extracted < -19'sh08000)
            saturate = 16'sh8000;
        else
            saturate = extracted[15:0];
    end
endfunction

// Output stage with first-order-hold interpolation to the CE rate.
// The 218.75 kHz zero-order-hold output carried spectral images around
// 218.75 kHz attenuated only ~20 dB by the ZOH sinc; the framework's
// asynchronous 48 kHz sampler folded them into the audio band (audible
// aliasing vs the software, whose FIR decimator suppresses images >80 dB).
// Linear interpolation across the 16 CE ticks per generator sample squares
// the sinc: images drop to ~-40 dB while in-band droop at 20 kHz is only
// -0.24 dB. delta = (target - current)/16 is exact (16 CE per gen tick).
reg hq_valid_r;
reg signed [15:0] hq_l_r, hq_r_r;
reg signed [31:0] foh_l, foh_r;          // interpolator state (Q4.28)
reg signed [31:0] foh_dl, foh_dr;        // per-CE increment

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
            // New target: step toward it over the next 16 CE ticks
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
