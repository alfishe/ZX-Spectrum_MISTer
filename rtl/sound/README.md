# AY-3-8910 HQ Audio Pipeline for MiSTer

Port of unreal-ng's high-quality AY sound synthesis to FPGA.

## Goal

Bit-exact match with unreal-ng software emulator audio output.

## Architecture Overview

```
PSG_CLOCK (1.75 MHz)
       │
       ▼
┌─────────────────┐
│ Tone/Noise/Env  │  Internal ÷8 prescaler → 218.75 kHz generator rate
│   Generators    │
└─────────────────┘
       │
       ▼
┌─────────────────┐
│   DAC Lookup    │  5-bit → 32-entry table (AY8910 or YM2149 curve)
│   (double→Q32)  │
└─────────────────┘
       │
       ▼
┌─────────────────┐
│  Stereo Mixer   │  ABC/ACB/Mono panning with coefficients
└─────────────────┘
       │
       ▼
┌─────────────────┐
│   DC Filter     │  1024-sample moving average (removes DC offset)
└─────────────────┘
       │
       ▼
┌─────────────────┐
│  FIR Decimator  │  96-tap polyphase, 218.75 kHz → 44.1 kHz
└─────────────────┘
       │
       ▼
┌─────────────────┐
│ Punch Enhancer  │  Transient designer + edge boost
└─────────────────┘
       │
       ▼
┌─────────────────┐
│ Room Crossfeed  │  2ms delay + opposite channel blend
└─────────────────┘
       │
       ▼
   44.1 kHz Stereo Output
```

## Precision Requirements

### unreal-ng Data Types

| Stage | Type | Bits | Notes |
|-------|------|------|-------|
| Generator counters | uint16_t | 16 | Tone period 12-bit, noise 5-bit |
| DAC table | double | 64 | Normalized [0.0, 1.0] |
| Mixer output | double | 64 | Per-channel floating point |
| FIR coefficients | double | 64 | 96 symmetric taps |
| FIR accumulator | double | 64 | Sum of products |
| DC filter sum | double | 64 | 1024-sample running sum |
| Punch envelope | float | 32 | Attack/release follower |
| Room delay line | float | 32 | 88-sample circular buffer |

### FPGA Fixed-Point Mapping

For bit-exact matching, we need sufficient precision:

| Stage | Fixed-Point | Bits | Fractional |
|-------|-------------|------|------------|
| DAC table | Q1.31 | 32 | 31 bits |
| Mixer output | Q4.28 | 32 | 28 bits |
| FIR coefficients | Q1.31 | 32 | 31 bits |
| FIR accumulator | Q8.40 | 48 | 40 bits |
| DC filter sum | Q12.36 | 48 | 36 bits |
| Punch envelope | Q4.28 | 32 | 28 bits |
| Room delay line | Q4.28 | 32 | 28 bits |

## Clock Domains

- **CLK_SYS**: System clock (directly from PLL, typically 56.75 MHz for ZX-128)
- **CE_PSG**: AY clock enable at 1.75 MHz (PSG_CLOCK_RATE)
- **CE_GEN**: Generator clock enable at 218.75 kHz (PSG_CLOCK_RATE / 8)
- **CE_AUDIO**: Audio sample clock at 44.1 kHz

## Constants (from unreal-ng)

```
CPU_CLOCK_RATE      = 3,500,000 Hz
PSG_CLOCK_RATE      = 1,750,000 Hz (CPU / 2)
AUDIO_SAMPLING_RATE = 44,100 Hz
FRAMES_PER_SECOND   = 50
SAMPLES_PER_FRAME   = 882

Generator rate      = PSG_CLOCK_RATE / 8 = 218,750 Hz
Decimation ratio    = 218,750 / 44,100 ≈ 4.9603

FIR_TAPS           = 96
DC_FILTER_SIZE     = 1024
ROOM_DELAY_SAMPLES = 88 (2ms @ 44.1kHz)
```

## DAC Tables (Q1.31 format)

### AY-3-8910 (stepped logarithmic)
```
0x00000000, 0x00000000,  // 0, 1
0x0147AE14, 0x0147AE14,  // 2, 3   (0.00999...)
0x01D9C034, 0x01D9C034,  // 4, 5   (0.01445...)
...
0x7FFFFFFF, 0x7FFFFFFF   // 30, 31 (1.0)
```

### YM2149 (smoother curve)
```
0x00000000, 0x00000000,
0x00989680, 0x00FD1A60,
...
```

## FIR Coefficients

96-tap Kaiser β=5 lowpass, Fc=20kHz @ Fs=218.75kHz.
Symmetric, so only 48 unique values needed.

## Module Hierarchy

```
ay_hq_top
├── ay_core                 # Existing ym2149.sv (modified)
│   ├── tone_gen[3]
│   ├── noise_gen
│   └── envelope_gen
├── ay_dac                  # DAC lookup with model select
├── ay_stereo_mixer         # ABC/ACB/Mono panning
├── ay_dc_filter            # 1024-sample DC removal
├── ay_fir_decimator        # 96-tap polyphase FIR
├── ay_punch_enhancer       # Transient designer
└── ay_room_crossfeed       # Headphone crossfeed
```

## Resource Estimates (Cyclone V)

| Module | ALMs | DSP18x18 | M10K | Notes |
|--------|------|----------|------|-------|
| ay_core | ~200 | 0 | 0 | Existing logic |
| ay_dac | ~50 | 0 | 1 | 32x32 ROM |
| ay_stereo_mixer | ~100 | 2 | 0 | 2 multipliers |
| ay_dc_filter | ~200 | 0 | 2 | 1024x32 buffer |
| ay_fir_decimator | ~300 | 4 | 1 | 96 coeffs, MAC |
| ay_punch_enhancer | ~250 | 4 | 0 | Envelope + multiply |
| ay_room_crossfeed | ~150 | 2 | 1 | 88-sample delay |
| **Total** | ~1250 | 12 | 5 | |

DE10-Nano has 41,910 ALMs, 112 DSP blocks, 553 M10K blocks.
This uses ~3% ALMs, ~11% DSP, ~1% memory.

## Implementation Phases

### Phase 1: Core + DAC + Mixer
- Modify ym2149.sv to output raw 5-bit levels
- Add high-precision DAC lookup
- Add configurable stereo panning

### Phase 2: FIR Decimator
- Implement 96-tap symmetric FIR
- Fractional phase accumulator for 4.96:1 ratio
- Verify against unreal-ng coefficients

### Phase 3: DC Filter
- 1024-sample moving average
- Circular buffer with running sum

### Phase 4: Punch Enhancement
- First-difference calculation
- Envelope follower (attack/release)
- Parameterized blend coefficients

### Phase 5: Room Crossfeed
- 88-sample delay line per channel
- Cross-channel mixing with level control
- Optional lowpass (disabled for AY)

## Verification Strategy

1. **Unit tests**: Each module vs unreal-ng reference vectors
2. **Integration**: Full pipeline vs captured .wav output
3. **Bit-exact**: Compare sample-by-sample with software

Generate test vectors by adding logging to unreal-ng:
- Input: Register writes with timestamps
- Output: Per-stage intermediate values + final samples
