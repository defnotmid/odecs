# Native AAC-LC

Native Odin encoder and decoder, with no codec library dependency. AAC-LC
supports 960- or 1024-sample frames, one through eight output channels, and all
13 standard sample rates from 7350 through 96000 Hz. These are implemented
features; bounded tests and interoperability controls do not establish complete
conformance or perceptual quality parity.

## API

Import `codec/aac/encoder` or `codec/aac/decoder` relative to your package.
Initialize fresh state before use; destroy an encoder before initializing it
again. Allocate the large codec states outside a small thread stack. Shared
`Config.frame_samples=0` resolves to 1024; otherwise choose 960 or 1024.
`Config.bit_rate` is the encoder's total target rate, defaulting to 64000 per
channel. At low sample rates choose a rate within the admitted LC buffer limit;
an excessive target returns `Invalid_Config`.

- Encoder: `init_encoder(state, config, transport=.ADTS, options={})`,
  `encode_frame`, `flush_encoder`, `reset_encoder`, `destroy_encoder`. Input is
  exactly `N * channels` interleaved finite `f32` samples in [-1,1].
  `Transport` selects `ADTS`, `Raw` or `LOAS`. ADTS cannot signal 960 samples;
  requesting that combination returns `Unsupported_Transport` during init.
  Appending output uses caller-owned `[dynamic]u8` storage. `encode_frame_to`
  uses a selected byte slice; `encode_frame_borrowed` returns at most one
  AU/frame from retained storage, valid until the next codec call.
- Decoder: `init_decoder`, `decode_frame` for one exact raw AAC AU,
  `decode_frame_prefix` for a byte-aligned AU prefix, `decode_adts_frame`,
  `decode_loas_frame` and `decode_latm_frame`. Output is caller-owned interleaved
  `f32`; sample counts are per channel. Raw calls need `N * channels` values;
  ADTS batches need up to `4 * N * channels`, LATM up to `64 * N * channels`.
  ADTS and LOAS calls also report consumed bytes. Pass a slice of larger
  retained storage to select the destination. Decoder state has no dynamic
  allocations; `reset_decoder` resets histories and mux state.
- Shared config/transport: ASC/PCE readers/writers, `parse_adts`, `adts_config`,
  `append_adts`, `append_adts_blocks`, `parse_loas`, `parse_latm`, `append_loas`
  and `append_loas_blocks`. The compact `audio_specific_config` returns two
  bytes for predefined channel layouts; `append_audio_specific_config` handles
  PCE layouts. ASC parsing accepts a backward-compatible sync extension that
  explicitly signals SBR absent (as FFmpeg writes) as plain LC; present
  SBR/PS remains unsupported. APIs return typed errors. Late syntax, CRC or coupling failures
  preserve committed histories, metadata and caller PCM; each multi-AU transport
  unit is one transaction.

Canonical output follows AAC element order: front, side, back, then LFE, with
left/right order within each CPE. Standard layouts are:

| Channels | Interleaved order |
| --- | --- |
| 1 | C |
| 2 | L, R |
| 3 | C, L, R |
| 4 | C, L, R, back C |
| 5 | C, L, R, back L, back R |
| 6 | C, L, R, back L, back R, LFE |
| 7 | C, L, R, side L, side R, back L, back R |
| 8 | C, center-front L, center-front R, outside-front L, outside-front R, back L, back R, LFE |

Channel configuration 7 means eight-channel **wide 7.1**: C, FLC, FRC, FL, FR,
BL, BR, LFE in AAC syntax order. Seven output channels
use a PCE. Set `Config.use_pce` and `program_config` for an explicit LC program;
the decoder maps element tags into that program order. An outside program takes
precedence over consumed in-band PCEs. `adts_config` resolves a leading PCE when
ADTS channel configuration is zero; callers may instead supply known config
before decoding.

ADTS parsing/writing covers CRC-protected frames and one through four raw data
blocks. The protected writer takes syntax-owner CRC ranges; the encoder's
normal ADTS output is single-block and unprotected. LC LATM/LOAS supports one
program/layer, synchronous framing, one through 64 AUs, configuration reuse,
CRC, and variable/fixed payload lengths. Multiple programs/layers, asynchronous
chunk muxing and unrelated transports return typed refusals.

`codec/common.pack_s16le` packs a caller-owned `[]f32` into a caller-owned
`[]u8`, without allocation. Reserve two bytes per sample; larger buffers keep
their unused tail. Input and output storage must not overlap. Finite samples
saturate to s16 and half ties round away from zero. Insufficient capacity returns
`Output_Too_Small` before writing; `Non_Finite` reports the packed finite-prefix
length and leaves the bad sample and remaining bytes untouched.

For raw access units, a frame can land directly in a selected sample range:

```odin
frame := sample_storage[sample_offset:sample_offset + N * channels]
samples, err := decoder.decode_frame(&state, access_unit, frame)
if err == .None {
    bytes := byte_storage[byte_offset:byte_offset + 2 * len(frame)]
    packed, pack_err := common.pack_s16le(frame, bytes)
    // Handle pack_err; samples is per channel, packed is interleaved samples.
}
```

Encoding uses one input frame of lookahead: the first accepted input emits no
AU, and later calls emit the preceding input. Presentation priming is **N
samples per channel**, reported by `encoder_delay`, independently of lookahead.
`flush_encoder_next_borrowed` or `flush_encoder_next_to` emits the pending AU,
then the final overlap AU, then an empty result; drain until empty. The appending
`flush_encoder` performs that loop. Repeated completed flushes are harmless.
Pad partial input yourself and retain its original unpadded sample count;
discard initial N samples and trim to that length for gapless playback.

## Implemented scope

The encoder switches long/start/short/stop windows using retained lookahead,
supports sine/KBD windows, adaptive masking/band allocation, all spectral
Huffman books, serialized rate search and a bit reservoir. It can emit TNS,
PNS, mid/side and intensity stereo within channel pairs. `Options` can disable
those tools, short-window switching or the reservoir, and request constant-rate
fill. These native heuristics need further rate/quality and listening controls;
their presence does not establish parity with a mature encoder.

The decoder handles long/start/short/stop windows, sine/KBD windows, spectral
Huffman and escape coding, pulse, TNS, PNS, mid/side and intensity stereo, plus
multichannel/PCE mapping and dependent/independent CCE. CCE is decoder-only.
Signed coupling gains accumulate the transmitted differences before extracting
sign and exponent, following the 2009 edition's grouping rather than the older
per-difference split. The inverse-exponent convention is checked by literal
blackbox controls; the printed positive-base coupling equations disagree with
the observed common-gain controls. The full published coupling corrigendum was
not obtained. These bounded checks do not establish exhaustive gain conformance
to [ISO/IEC 14496-3:2009](https://ossrs.net/lts/zh-cn/assets/files/ISO_IEC_14496-3-AAC-2009-90cda427e845cc176293bffee3f92f99.pdf)
or [ISO/IEC 13818-7:2006/Cor 1:2009](https://www.iso.org/standard/52338.html).
`Decoder.dynamic_range` exposes DRC metadata and exclusions; PCM retains its
full dynamic range. Playback gain/interpolation is an explicit caller decision.
PNS noise phase is implementation-specific; cross-decoder PNS controls compare
length and energy when PNS is actually present, rather than exact sample phase.

The shared MDCT/IMDCT uses 512/64-point complex FFTs for 1024/128 windows and
480/60-point mixed-radix FFTs for 960/120 windows, with separate real/imaginary
planes and generic Odin SIMD. Transforms allocate no memory. The decoder uses
bounded byte reads, a native Huffman prefix table, shared tuple digits,
band-owned tuple shapes and cached powers. Pulse-free frames decode directly
into spectral storage; pulse frames retain the quantized plane. Long synthesis
uses contiguous SIMD and masked channel stores while updating overlap;
overlapping exported storage preserves scalar publication order.

The encoder retains its analysis/quantization planes and compressed output
capacity. Borrowed AU output adds no output merge; caller-owned appending
output may grow when capacity is insufficient. AAC overlap/noise histories
keep each stream serial. Schedule independent states concurrently through
caller-owned persistent data ranges when aggregate throughput is needed.

HE-AAC/SBR/PS and Main/SSR/LTP profiles remain outside AAC-LC support. The CLIs
accept raw PCM for encoding and ADTS/LOAS for decoding; they do not demux MP4 or
WebM. Raw encoder output requires retained AU boundaries and ASC.

## Validation and examples

The resident-input benchmark is `bash tests/aac_benchmark.sh`; its optional
FFmpeg API oracle is development-only. Native timing, signal generation and PCM
quality tools use Odin. Seven fresh-state rounds check output determinism.
Persistent shared `common.Static_Pool` slots own contiguous independent-stream
ranges; initialization remains on the caller. One stream remains serial.
Setup and file I/O are excluded from codec timing. Optional
`AAC_SLOT_CPUS_<count>` assigns initially permitted, distinct CPUs to fixed slots
in both wrappers; production codecs set no affinity.

In the last measurement (2026-10-04), native encode is 5.7–8.3 times
faster than the installed FFmpeg API at those operating points, with unequal
emitted bitrates. Stereo transient SNR trails by
about 5 dB at the nominal targets and by 0.894 dB in the auxiliary comparison at
nearby emitted byte rates. These bounded measurements do not establish general
quality parity. Compare setup, stream count, transport, actual bitrate, tools
and quality alongside timing.

```sh
odin test codec/aac
odin test codec/aac/encoder
odin test codec/aac/decoder
bash tests/aac_check.sh
odin build tests/encode_aac.odin -file -o:speed -out:/tmp/encode-aac
odin build tests/decode_aac.odin -file -o:speed -out:/tmp/decode-aac
/tmp/encode-aac input.s16le 48000 2 128000 output.aac
/tmp/encode-aac input.s16le 48000 7 448000 output.loas --frame-samples 960 --transport loas
/tmp/decode-aac output.aac decoded.s16le
```

The interoperability gate cross-decodes native and reference tones, transients
and noise. Without PNS the complete PCM tolerance is at most two s16 units.
The [feature gate](../../tests/aac_lc_features_check.sh) consumes prepared
fixtures/binaries without building: deterministic multichannel, 960/1024,
PCE and CCE/TNS PCM is compared after explicit channel reordering. Paired
DRC/no-DRC streams discriminate reference gain application. Those fixtures
require PNS to be absent. These controls are bounded coverage, not a complete
AAC conformance suite or perceptual listening test.

AAC Huffman codewords, scale-factor-band offsets, TNS limits and rate mappings
are generated directly from the [ISO/IEC 14496-3:2001 primary standard](https://ossrs.net/lts/zh-cn/assets/files/ISO_IEC_14496-3-AAC-2001-7f4d0b3622b322cb72c78f85d91c449f.pdf).
The native [table generator](../../tools/aac_spec_tables/README.md) parses and
validates the standard's table rows before comparing them with current source.
It constructs output from those normative rows; its README lists table numbers
and reproducible extraction commands.
