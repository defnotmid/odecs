# VP9 encoding

Native Odin VP9 profile 0 (8-bit 4:2:0), written from the VP9 Bitstream &
Decoding Process Specification v0.7. No codec library is linked or loaded.
The probability defaults, reconstruction, prediction, inverse transforms,
quantizers and filter are shared with [`codec/vp9`](../README.md).

```odin
import vp9e "../codec/vp9/encoder"

e: vp9e.Encoder
err := vp9e.init_encoder(&e, {
    width = width, height = height,
    base_q_idx = 100, keyframe_interval = 120,
    block_log2 = 5, tile_cols_log2 = 2, pool = pool,
})
packet, keyframe, err := vp9e.encode_frame(&e, planes, strides)
// Consume packet before the next encode call. No ownership transfer.
reconstructed, reconstructed_strides := vp9e.reconstruction(&e)
vp9e.destroy_encoder(&e)
```

- Input: three byte planes, strides in bytes. Chroma dimensions are
  `ceil(width/2)` by `ceil(height/2)`. Odd and non-block-aligned sizes work;
  edge samples are replicated for block analysis. Input is borrowed only
  during the synchronous call. Colour is already BT.709 limited-range YUV.
- `base_q_idx`: 0..255, **not** H.264/HEVC QP. Zero is exactly lossless.
- `keyframe_interval`: zero selects 120. Frame zero is a keyframe, followed
  by keyframes at multiples of the interval. No lookahead, delay or reorder.
- `block_log2`: zero selects 3 (8x8); 3, 4, 5 select fixed 8, 16, 32-pixel
  partitions. Edge constraints subdivide them. Lossy transforms use the
  block's largest legal size; lossless always uses 4x4 WHT.
- `search_range`: zero selects 16; otherwise 1..64 pixels. Coarse-to-fine
  integer diamond search, then half-/quarter-pixel refinement, using SAD
  with a simple quantizer-dependent vector penalty. LAST is the only ref.
- `tile_cols_log2`: clipped to the specification's width-dependent limits.
  Zero normally means one tile; 2 permits four at 1080p. Tiles run on the
  caller's `common.Work_Pool`. A nil pool executes exactly the same tile
  jobs serially, and produces identical bytes. The codec creates no threads.
- Loop-filter level is `(q + 4)/8`, capped at 63; lossless disables it.
  `disable_loop_filter` disables it explicitly. Filtering is currently serial.
- Init captures the allocator and allocates persistent buffers and tile
  scratch. Destroy uses that allocator. Destroy before reinitializing. Do
  not share an encoder between concurrent calls or mutate its configuration.
  Init can return `Out_Of_Memory`; invalid input returns `Invalid_Argument`
  without advancing the frame counter. Init pre-reserves bitstream space,
  so encoding normally does not allocate; if an append must grow and fails,
  `encode_frame` returns `Out_Of_Memory` with the reference frame and frame
  counter unchanged, and the same frame can be retried. Destroy resets it.

## Bitstream and analysis

Shown key/inter frames, single-reference motion (zero, nearest, new), and
DC/vertical/horizontal/true-motion keyframe prediction. Lossy luma uses
DCT/ADST 4..16 and DCT 32, chroma DCT; VP9 has no 32-point ADST. The shared
forward transform is a fixed-point transpose analysis basis made from the
normative synthesis constants; it is not a port of libvpx's encoder and
need not reproduce its coefficients. Lossless reverses the normative WHT's
lifting steps exactly. Reconstruction dequantizes the emitted coefficients
and applies the decoder's inverse transform, prediction and filter.

All probabilities remain the defaults. `error_resilient_mode=1` implies
`frame_parallel_decoding_mode=1`, so there is no backward adaptation or
previous-frame MV prediction to mirror. There are no forward probability
updates, segmentation, compound refs, alt-ref/lookahead, bitrate control,
RD partition selection or inter-frame intra decisions yet.
These omissions are important compression-efficiency limits, not syntax gaps.

### Planned: compression

Files are about 11x libvpx's (good preset, cpu-used 4) at matched PSNR on
the 320x180 animation clip, and a transparent 640x360 clip is about 3.5x the
H.265 straight-alpha file. In order of expected gain per effort, each
measured with `tests/vp9_quality_check.sh`:

1. Skip flags and zero residuals for inter blocks (static backgrounds are
   most of animation).
2. Rate-distortion partition choice instead of fixed block sizes.
3. Probability adaptation: forward updates or backward adaptation.
4. Intra blocks in inter frames, and all ten intra directions.
5. Later: alt-ref (hidden) frames and compound prediction, which need
   lookahead and reordering.

Items 1 to 3 should close most of the gap.

## Alpha and WebM

Alpha requires **two independent encoders**, not a codec-specific RGBA API.
Pass straight alpha as the second encoder's Y plane, and constant 128 U/V
planes. Its width, height, frame count and keyframe interval must match the
colour encoder; its quantizer may differ (zero is recommended for alpha).
Colour must already be un-premultiplied by the caller's shared preparation.
The encoders do not change alpha semantics or do colour conversion.

[`webm.Writer`](../../container/webm/README.md) writes the colour packet plus
alpha packet as BlockAdditional ID 1, with AlphaMode 1. This is the libvpx
WebM mapping, not a second video track. Safari needs the separate HEVC path.

## Verification

```sh
bash tests/vp9_encode_check.sh
bash tests/vp9_quality_check.sh
bash tests/vp9_encode_timing.sh
# Optional real clip sanity check:
VP9_CAMERA=/path/to/clip.mov bash tests/vp9_encode_check.sh
```

The gate uses git-ignored `.work/`, including `.work/tmp` for Odin builds.
It runs `odin test` with `-vet -strict-style` on the encoder, shared VP9 and
WebM packages (Odin exposes vet as a flag, not an `odin vet` subcommand).
FFmpeg, libvpx, Chromium and Node are test oracles/tools only.

- Native unit matrix: eight sizes, seven quantizers spanning 0..255, three
  partition sizes, five frames each (including keyframe resets). Lossless
  equals source. Four-tile serial/pool packets are byte-identical; padded
  input strides are covered. A separate bool test checks 20,000 decisions
  against the specification's bit-at-a-time subdivision. Wrapping/negative
  strides are rejected, and injected allocation failures leave the encoder
  reusable with byte-identical output afterwards.
- Oracle matrix: 105 alpha cases, eight frames each: 1x1, 7x5, 17x19, 64x64,
  65x67, 257x73, 1025x67; q=0,1,32,100,255; blocks=8,16,32. Encoder
  reconstruction equals native VP9, movie planar output, FFmpeg native VP9
  and libvpx colour decode byte for byte. FFmpeg decodes both the standalone
  alpha stream and actual WebM BlockAdditional alpha, matching reconstruction.
  Additional flat/noise, non-alpha cases exercise SimpleBlock and zero EOBs.
- 1080p, eight frames with alpha, q=100 and q=0 (run by hand, not in the
  gate): one-worker and four-worker WebM files are byte-identical, and the
  reconstruction equals native, movie, FFmpeg and libvpx decodes and libvpx's
  BlockAdditional alpha; q=0 equals the source.
- Container tests verify metadata, timestamps, alpha additions, keyframe
  flags, cluster rollover, completed Segment/Cluster sizes, all three
  SeekHead targets, error latching and finish idempotence. ffprobe checks
  dimensions, BT.709 limited range, AlphaMode, duration and frame counts.
- Headless Chromium seeks through eight lossless-alpha frames, draws each
  onto a transparent canvas and composites over two known RGB backgrounds.
  On Chromium here: alpha error 0, maximum composite-channel error 1;
  transparent, fractional and opaque pixels all present. Firefox/Edge have
  not been separately tested.
- The gate's `VP9_CAMERA` branch was run with the one available ProRes avatar
  clip, scaled to 320x180, eight frames: q=100, 23,122 bytes, 43.40 dB, and
  FFmpeg equals reconstruction. This is not a broad camera-footage corpus;
  `VP9_CAMERA` supplies one without putting third-party media in the repo.

## Size and quality

30 frames of a deterministic 320x180 vector-like fixture: grayscale gradient,
moving flat rectangle, text-like strokes. The source SHA-256 is
`8697cb9ba0b5fe58a1716fe7a616541b012799a4f7e675341a5ad1a143af1147`.
PSNR is the sample-weighted Y/U/V MSE, not the average of per-frame dB.
Container overhead and alpha bytes are excluded from the payload comparison.

| Encoder | Setting | Payload bytes | PSNR (dB) |
| --- | --- | ---: | ---: |
| Native | q=100, 32x32 blocks | 77,596 | 40.574 |
| libvpx | good, cpu-used=4, CRF 50 | 7,071 | 40.885 |
| libvpx | good, cpu-used=4, CRF 51 | 6,772 | 40.410 |
| Native | q=0, lossless | 58,114 | infinity |
| libvpx | lossless | 19,235 | infinity |

Libvpx's two lossy points bracket native quality: the native size gap is
**11.0–11.5x** there, not a claim that CRF and q are equivalent. The exactly
matched lossless gap is **3.02x**. Libvpx uses one worker, GOP 120, no lag,
one-pass CQ and good/cpu-used 4. Comparisons decode to raw planes before
PSNR to avoid millisecond WebM timestamp rounding pairing different frames.
Lossless happens to be smaller than native lossy on this fixture; neither
result should be generalized to camera footage.

## Performance

AMD Ryzen 9 9900X3D, Odin `dev-2026-10-nightly:84bc3fc21`, `-o:speed`, four
bitstream tile columns, 32x32 partitions, search radius 16, GOP 120. The
fixture is generated outside the timed region. Time is only `encode_frame`
(colour plus alpha when present): excludes initialization, source generation,
PSNR, muxing, decoding and I/O. These are codec throughput, not end-to-end
render/export numbers. Best of three after a warmup, 1080p, unpinned workers;
`tests/vp9_encode_timing.sh` prints every trial.

How the encoder got there, every step byte-identical to the previous output
across 8 sizes x 4 quantizers x 3 partitions, flat/noise and 1080p:

- Size specialization: 16-frame q=100 instructions from 88.7 to 70.8
  billion, cycles from 15.4 to 12.7 billion.
- An exact exit when the search reaches zero cost (no candidate can improve
  it): eight-frame lossless colour+alpha instructions from 35.7 to 10.4
  billion, cycles from 6.78 to 2.38 billion.
- Each tile stages its input columns once per frame into an aligned,
  edge-replicated source plane. Pictures live inside an 80-sample replicated
  border, extended once after filtering. Block loops, intra costs and motion
  costs therefore read unclamped rows; integer motion costs read the
  reference directly through one portable `#simd` SAD kernel.
- The forward transform pairs reflected samples (DCT symmetry checked at
  init), runs the column pass on `#simd` rows in exact i32, and keeps exact
  i64 row sums, halving the products.

| 1080p, one worker | instructions | cycles | fps |
| --- | ---: | ---: | ---: |
| q=100, before | 71.1 G | 12.7 G | 7.12 |
| q=100, staged source + bordered reference | 45.8 G | 8.22 G | 11.24 |
| q=100, paired SIMD forward transform | 33.8 G | 6.03 G | 15.79 |
| q=0 colour+alpha, before | 10.5 G | 2.29 G | 21.79 |
| q=0 colour+alpha, final | 8.29 G | 1.96 G | 26.01 |

(`perf stat` counts are whole-process, including source generation/PSNR.)
One worker versus caller + three pool threads (four tiles):

| 1080p workload | 1 worker | 4 workers |
| --- | ---: | ---: |
| q=100 colour, 16 frames | 15.78 fps | 48.52 fps |
| q=0 lossless colour + alpha, 8 frames | 26.01 fps | 72.77 fps |

Four-worker lossless varied 60.4–72.8 fps between trials. Four tiles cap the
pool speedup, and the loop filter is serial.

For scale, on the same 8-frame 1080p source with one thread, libvpx
realtime/cpu-used 8 ran at about 78 fps (43.2 dB, 427 KB at CRF 40) and
good/cpu-used 4 at about 10.7 fps (48.7 dB, 172 KB). Native q=60 gives 44.7 dB
in 935 KB. Native output is still several times larger than libvpx's.

## Movie writer

`movie.Writer` with `codec = .VP9` writes WebM through the native media
provider: one colour encoder and, with `transparency = .Straight`, a second
for the alpha stream (`Packet.alpha`). QP 0..51 maps to
`base_q_idx = 5 * qp`. Frame timestamps come from the rational frame rate in
nanoseconds, without accumulating rounded deltas, and the last frame gets
its actual duration. Audio is refused rather than dropped.
`tests/movie_alpha_write.odin` covers it; its WebM decodes in odecs
identically to libvpx and passes `tests/vp9_browser_check.sh`.
