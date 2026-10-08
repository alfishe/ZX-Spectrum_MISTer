# AY-3-8910 / YM2149 HQ Audio Pipeline

Port of the unreal-ng AY output chain to the FPGA: the PSG is rendered at its
native generator rate and shaped exactly as the emulator does, so the core
sounds like unreal-ng with the same settings.

## Signal chain

All stages run at the generator rate, 218.75 kHz (AY clock 1.75 MHz / 8); there
is no decimation inside the core.

```
ym2149.sv (x2, TurboSound)   5-bit pre-DAC levels LEVEL_A/B/C per chip
        |                    (fixed volume 2v+1, envelope 0..31, gated)
ay_dac (x3)                  AY8910 or YM2149 amplitude table (Q1.31),
        |                    the two chips summed unsaturated
ay_stereo_mixer              ABC / ACB / Mono pans 0.9 / 0.5 / 0.1, then / 3
        |
ay_dc_filter                 5 Hz one-pole RC high-pass (coupling capacitor)
        |
ay_fir_decimator             96-tap Kaiser (beta 5) low-pass, 20 kHz, full rate
        |
ay_voicing                   tonal-balance EQ profile (default Classic)
        |
ay_punch_enhancer            edge + envelope-gated transient boost (AY preset)
        |
ay_room_crossfeed            2 ms delayed opposite-channel blend (default -9 dB)
        |
turbosound_hq output         Q4.28 -> int16 (>>> 14), first-order-hold
                             interpolation to the 3.5 MHz CE rate
```

`turbosound_hq.sv` wires the chain, the legacy output (optionally band-limited
by the FIR when HQ is off) and the TurboSound / TurboSound FM chip
select; `ZX-Spectrum.sv` sums the HQ output with the other sources
(sat16, x2 makeup gain) when HQ Audio is on.

## Correspondence with unreal-ng

| Stage | unreal-ng | Notes |
|---|---|---|
| Generators | `SoundChip_AY8910` tone / noise / envelope | 60-configuration co-simulation bit-exact |
| DAC, mixer | `AY_DAC_TABLE` / `YM_DAC_TABLE`, `updateMixer()` | |
| DC filter | `FilterDCBlocker`, `OUTPUT_HIGHPASS_HZ = 5` | same recurrence, state Q.44 |
| FIR | `FilterDecimator` (Reference quality, 20 kHz) | same 96-tap design |
| Voicing | `FilterVoicing` / `VoicingStage` | coefficients from unreal-ng's own design at 218.75 kHz |
| Punch, room | `AudioCharacterChain` (`PunchPreset::AY`) | time constants rate-converted as unreal-ng does (`coeff^(44100/fs)`, first difference x fs/44100) |

unreal-ng runs voicing and the character chain per TurboSound chip after
decimation; the core runs them once on the chip sum. All stages but punch are
linear, and the AY punch preset is gentle enough that per-chip and summed
punch differ by -57 dB.

## Options (OSD Audio page)

| Option | status bits | Default | Available |
|---|---|---|---|
| HQ Audio | 42 | On | always |
| PSG Anti-alias | 54 | On | HQ Audio Off only |
| HQ Punch | 43 | On | HQ Audio On only |
| HQ Room | 47:44 | -9 dB | HQ Audio On only |
| HQ FIR | 48 | On (Off = debug bypass) | HQ Audio On only |
| HQ DC Filter | 50 | On (Off = debug bypass, subtracts 0.25) | HQ Audio On only |
| HQ Voicing | 53:51 | Classic | HQ Audio On only |

Availability uses `status_menumask` bit 4 (= HQ Audio Off): the HQ options
carry `D4` (disabled while HQ is off), PSG Anti-alias carries `d4`.

With HQ Audio Off the core outputs the legacy PSG mix through the upstream
top-level compressor. PSG Anti-alias On band-limits that legacy output with
the (otherwise idle) HQ FIR before it leaves `turbosound_hq`: the raw square
edges otherwise alias at the framework's 48 kHz sampling, 28-39 dB below the
note from 440 Hz up; filtered, 57-68 dB, with the legacy tonal balance kept
(within 0.03 dB). PSG Anti-alias Off gives the upstream output sample for
sample.

The chip model (AY8910 / YM2149 DAC curve) and the ABC / ACB stereo follow the
core's existing PSG Model and PSG Stereo options.

Voicing profiles (unreal-ng IDs): Flat (no processing), Classic (64.2 Hz HPF +
106.9 Hz / +3.06 dB peak - the old moving-average DC filter's bass balance),
Headphones (Classic + 10 kHz low-pass), Warm, TV, Small speaker.

## Fixed-point formats

| Signal | Format |
|---|---|
| DAC output, mixer | Q1.31 / Q4.28 unsigned |
| Chain samples | Q4.28 signed |
| DC filter state | Q.44 (k = 1 - a ~ 1.4e-4 needs the extra bits) |
| Voicing coefficients / state | Q2.30 / Q6.40 |
| Output | int16, 1.0 = 16384 (x2 in the top level) |

## Resources (Quartus 17.0, whole core)

65% ALMs, 85 of 112 DSP blocks, timing met. The room delay lines are block
RAM (M10K); the 96-sample FIR history is in registers; the voicing engine
shares one multiplier (36 clocks per sample).
