# Opus

Opus (RFC 6716, with the RFC 8251 updates) decoding to 48 kHz `f32`, from
any container's packets. `video.Reader` reads it from Ogg (`.opus`, `.ogg`,
through [`ogg`](../../container/ogg)) and from WebM/Matroska
(`A_OPUS`).

```odin
import opus "../opus"

head, err := opus.parse_head(opus_head_bytes)  // OpusHead: channels, streams, mapping, pre-skip, gain
m: opus.Multistream
opus.init_multistream(&m, head)                 // any channel count; one stream for mono/stereo
defer opus.destroy_multistream(&m)
samples, err := opus.decode_multistream(&m, packet, pcm[:]) // interleaved, +-1
// pcm needs MAX_FRAME_SAMPLES * channels; discard head.pre_skip samples at the start
err = opus.decode_multistream_lost(&m, 960, pcm[:]) // a lost 20 ms packet, concealed
err = opus.decode_multistream_fec(&m, next_packet, 960, pcm[:]) // or recovered from the next packet's FEC
```

A single stream can be decoded directly too: `Decoder`, `init_decoder`,
`decode_packet`, `decode_lost` and `decode_fec`.

## Scope

- **All three modes:**
  - SILK (speech: voice notes, WebRTC), at 8, 12 and 16 kHz, mono and stereo, frames of 10 to 60 ms, resampled to 48 kHz;
  - CELT (music: most WebM audio, YouTube's included), frames of 2.5 to 20 ms;
  - hybrid (SILK below 8 kHz, CELT above);
  - up to 120 ms per packet;
  - switches between modes: with the encoder's redundancy frames, and without them, through concealment faded into the new mode as libopus does.
- **Packet loss and DTX:**
  - a lost packet (`decode_lost`, for the gap's duration) and a frame of at most one byte (DTX, discontinuous transmission) are concealed;
  - SILK concealment extrapolates pitch, LPC and noise and adds comfort noise, then fades the next good frame in;
  - CELT concealment repeats the last pitch period through an LPC fit; after 100 ms, and in hybrid frames, it fades to shaped noise.
  - Forward error correction (`decode_fec`, given the packet after the gap) restores the gap's last frame from that packet's LBRR copy, a low bit-rate re-encoding that SILK and hybrid encoders add when told to expect loss; the rest of the gap is concealed. A CELT packet, or one without LBRR data, is concealed instead.
- **Multistream (RFC 7845):**
  - channel mapping family 0 (mono/stereo);
  - family 1 (up to 8 channels in the Vorbis order: 5.1 is L, C, R, rear L, rear R, LFE);
  - families 2 (ambisonics without a demixing matrix) and 255;
  - output channels are in the stream's mapping order;
  - family 3 (ambisonics with a demixing matrix) returns `.Unsupported`.
- **Output:** the header's output gain and libopus's soft clipping are applied, as libopus's 16-bit API does; concealed packets are not soft-clipped.
- **Containers (`video.Reader`):**
  - pre-skip (Ogg) and `CodecDelay` (Matroska) are trimmed, and so is the end, by Ogg's last granule position;
  - seeks decode 80 ms ahead of the target (RFC 7845 4.6).

## Layout

The SILK, CELT and resampler tables are generated from libopus by
[`tools/tables`](../../tools/tables/README.md). Jagged tables (codebooks
of different sizes) are CSR: one flat array of values and one of row
offsets. SILK runs in libopus's exact fixed point, so it is bit-exact.
CELT runs in `f32`, so it matches libopus to rounding.

The MDCT tables are computed once at startup and shared by every decoder.

## Verification

`bash tests/opus_check.sh`, with fixtures from `bash tests/opus_fixtures.sh`. The fixture script fetches the RFC 8251 test vectors, builds libopus from `third_party/opus` (`opus_demo`, `opus_compare`, and the library the loss reference links), encodes DTX streams, and writes Ogg/WebM files with FFmpeg. The gate checks:

- **All 12 conformance vectors, stereo and mono output:**
  - every packet's final range matches the encoder's, so every symbol of every packet was decoded exactly;
  - `opus_compare` passes: 99.8–100% in stereo, 96.2–99.9% in mono, as libopus's own float build does;
  - SILK-only vectors 02–04 reach 100% (weighted error 0), because SILK output is identical to libopus's.
- **Packet loss:** a bursty pattern (8% of packets start a loss, half of losses continue) over every vector, against libopus concealing the same packets (`tests/opus_loss_ref.c`).
  - SILK vectors: identical to libopus, sample for sample.
  - Hybrid: within 1 LSB (105–115 dB SNR).
  - CELT: 44–81 dB. CELT's LPC fit stops at 30 dB of prediction gain, and a rounding-level difference can stop it one order earlier or later. Every concealment decision (noise or periodic, the pitch, the attenuations) matches libopus's.
- **Forward error correction:** each loss's last packet recovered from the next one, against libopus doing the same. Identical on SILK streams in 20, 40 and 60 ms packets, mono and stereo, and on a hybrid stream; identical on vectors 02 and 04, within the concealment's differences on 10 and 12.
- **DTX:** `opus_demo -dtx` streams. SILK and voip-tuned hybrid are identical to libopus; audio-tuned hybrid and CELT are within 1 LSB.
- **Containers through `video.Reader`:** Ogg and WebM files in each mode, and a 5.1 file (four streams, two coupled).
  - Sample counts are exact against FFmpeg's libopus decode, and the full decode is within 1.5e-5 (SILK: identical).
  - After 30 random seeks the decoder has re-converged in the pre-roll. Worst over every position: 0.007 for CELT and hybrid, 0.044 for SILK (exactly libopus restarted at the same packet), 0.02 for the surround tones. The surround LFE's 60 Hz onset in the first 250 ms is 0.118 off, as it is for libopus restarted at the same packet.
- **Fuzzing:** a pass under AddressSanitizer, with mutated packets and losses, mutated and random multistream packets with random layouts, and mutated Ogg files.

Decode speed on one core against libopus 1.6.1 (built with its SSE4.1 and AVX2
intrinsics; odecs uses none) and FFmpeg's `opus`, on music at 128 kb/s and on
speech-tuned streams at 16 and 32 kb/s, is in [BENCHMARKS.md](../../BENCHMARKS.md)
(`bash tests/compare.sh run decode/opus`).

The time went into data shape:
- **The FFT:** split real and imaginary arrays, a precomputed input permutation, and in-place stages with `[j][k]` twiddles, so every inner loop is contiguous. One butterfly stage is generic over a compile-time radix (`$P`, `#unroll`, `when`).
- **De-emphasis:** both channels per sample.
- **Soft clipping:** a single contiguous pass that returns early.
