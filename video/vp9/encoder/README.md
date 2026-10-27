# VP9 encoding

Native Odin VP9 profile 0 (8-bit 4:2:0), written from the VP9 Bitstream &
Decoding Process Specification v0.7. No codec library is linked or loaded.
The probability defaults, reconstruction, prediction, inverse transforms,
quantizers and filter are shared with [`vp9`](../README.md).

```odin
import vp9e "../vp9/encoder"

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
- `block_log2`: zero selects 4 (16x16); 3, 4, 5, 6 permit partitions up to 8,
  16, 32, or 64 pixels, subdivided by quadrant SAD against the quantizer noise
  and edge constraints. Lossy transforms use the block's largest legal size, or
  4x4 on 8x8 blocks; lossless always uses 4x4 WHT.
- `search_range`: zero selects 16; otherwise 1..64 pixels. Spatial and
  co-located temporal predictors (`NEARESTMV`, `NEARMV`, `ZEROMV`, `NEWMV`),
  coarse-to-fine integer diamond search, then leaf-only half-/quarter-pixel
  8-tap refinement using SAD plus exact motion-vector bit cost from per-frame
  cost tables. LAST is the only ref.
- `tile_cols_log2`: clipped to the specification's width-dependent limits.
  Zero normally means one tile; 2 permits four at 1080p. Tiles run on the
  caller's `common.Work_Pool`. A nil pool executes exactly the same tile
  jobs serially, and produces identical bytes. The codec creates no threads.
- Loop-filter level is `(q + 4)/8`, capped at 63; lossless disables it.
  `disable_loop_filter` disables it explicitly. Filtering runs in wavefronts
  on `pool` when present.
- Init captures the allocator and allocates persistent buffers and tile
  scratch. Destroy uses that allocator. Destroy before reinitializing. Do
  not share an encoder between concurrent calls or mutate its configuration.
  Init can return `Out_Of_Memory`; invalid input returns `Invalid_Argument`
  without advancing the frame counter. Init pre-reserves bitstream space,
  so encoding normally does not allocate; if an append must grow and fails,
  `encode_frame` returns `Out_Of_Memory` with the reference frame and frame
  counter unchanged, and the same frame can be retried. Destroy resets it.

## Bitstream and analysis

Shown key/inter frames, single-reference motion (`ZEROMV`, `NEARESTMV`,
`NEARMV`, `NEWMV`), and DC/vertical/horizontal/true-motion keyframe prediction.
Lossy luma uses DCT/ADST 4..16 and DCT 32, chroma DCT; VP9 has no 32-point
ADST. The shared forward transform is a fixed-point transpose analysis basis
made from the normative synthesis constants; it is not a port of libvpx's
encoder and need not reproduce its coefficients. Lossless reverses the
normative WHT's lifting steps exactly. Reconstruction dequantizes the emitted
coefficients and applies the decoder's inverse transform, prediction and
filter.

Per-block state is stored in per-reader columnar grids matching the decoder:
`Motion` for 2-D spatial and co-located temporal motion vector prediction,
`Filter_Cell` for loop filtering, and 1-D `Edge_Context` along tile top and
superblock left edges for syntax context derivation. Tree codes and bit cost
tables are flat lookup tables built at init, with per-frame motion-vector
component cost tables updated once per inter frame.

Probabilities adapt as libvpx's do. With `error_resilient_mode=0` and
`refresh_frame_context=1`, each frame's symbol counts adapt the context
backward for the next frame (key frames restore the defaults). The
compressed header also sends forward updates for this frame (coefficient,
skip, transform size, inter mode, reference, intra mode, partition and
motion vector probabilities), each only where it pays for its own bits on
this frame's counts. Tiles stage their symbols, and code them in parallel
on the pool once the header has settled the probabilities. There is no
segmentation, compound refs, alt-ref/lookahead, bitrate control, RD
partition selection or inter-frame intra decisions yet.
These omissions are compression-efficiency limits, not syntax gaps.

### Planned: compression

Files are larger than libvpx's (good preset, cpu-used 4) at equal PSNR: the
BD-rate is in [BENCHMARKS.md](../../../BENCHMARKS.md). Remaining compression
work, measured with `bash tests/compare.sh run encode/vp9`:

1. Full rate-distortion partition search across 64x64..8x8 (including
   rectangular `PARTITION_HORZ` / `PARTITION_VERT` leaves).
2. Intra blocks in inter frames, and all ten intra directions.
3. Multiple references (`GOLDEN`, `ALTREF`) and compound prediction.
4. Alt-ref (hidden) frames and lookahead with temporal filtering.
5. Segmentation and adaptive per-segment quantizer deltas.

## Alpha and WebM

Alpha requires **two independent encoders**, not a codec-specific RGBA API.
Pass straight alpha as the second encoder's Y plane, and constant 128 U/V
planes. Its width, height, frame count and keyframe interval must match the
colour encoder; its quantizer may differ (zero is recommended for alpha).
Colour must already be un-premultiplied by the caller's shared preparation.
The encoders do not change alpha semantics or do colour conversion.

[`webm.Writer`](../../../container/webm/README.md) writes the colour packet plus
alpha packet as BlockAdditional ID 1, with AlphaMode 1. This is the libvpx
WebM mapping, not a second video track. Safari needs the separate HEVC path.

## Verification

```sh
bash tests/vp9_encode_check.sh
bash tests/compare.sh run encode/vp9   # size and speed against libvpx
# Optional real clip sanity check:
VP9_CAMERA=/path/to/clip.mov bash tests/vp9_encode_check.sh
```

The gate uses git-ignored `.work/`, including `.work/tmp` for Odin builds.
It runs `odin test` with `-vet -strict-style` on the encoder, shared VP9 and
WebM packages (Odin exposes vet as a flag, not an `odin vet` subcommand).
FFmpeg, libvpx, Chromium and Node are test oracles/tools only.

- Native unit matrix: eight sizes, seven quantizers spanning 0..255, four
  partition sizes, five frames each (including keyframe resets). Lossless
  equals source. Four-tile serial/pool packets are byte-identical; padded
  input strides are covered. A separate bool test checks 20,000 decisions
  against the specification's bit-at-a-time subdivision. Wrapping/negative
  strides are rejected, and injected allocation failures leave the encoder
  reusable with byte-identical output afterwards.
- Oracle matrix: 140 alpha cases, eight frames each: 1x1, 7x5, 17x19, 64x64,
  65x67, 257x73, 1025x67; q=0,1,32,100,255; blocks=8,16,32,64. Encoder
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

`bash tests/compare.sh run encode/vp9` measures the size against libvpx
(one worker, good/cpu-used 4, one-pass constant quality, no lag, GOP 120) as
BD-rate, the size change at equal PSNR, over four quantizers each: on
OpenH264's 1080p camera clip, and on 30 frames of a deterministic 320x180
vector-like fixture (grayscale gradient, moving flat rectangle, text-like
strokes; source SHA-256
`8697cb9ba0b5fe58a1716fe7a616541b012799a4f7e675341a5ad1a143af1147`), where
it also compares the two lossless sizes. The figures are in
[BENCHMARKS.md](../../../BENCHMARKS.md). PSNR is FFmpeg's sample-weighted
Y/U/V figure over decoded raw planes, which avoids millisecond WebM timestamp
rounding pairing different frames; payload bytes exclude the container.

## Performance

Time in the benchmark harness is only `encode_frame` (colour plus alpha when
present): it excludes initialization, source generation, PSNR, muxing,
decoding and I/O. The current figures, at one worker and four on the 1080p
synthetic animation and against libvpx on camera footage, are in
[BENCHMARKS.md](../../../BENCHMARKS.md) (`bash tests/compare.sh run encode/vp9`).

Key implementation details:

- Size-specialized inner loops and an exact early exit when the search reaches
  zero SAD.
- Each tile stages its input columns once per frame into an aligned,
  edge-replicated source plane. Pictures live inside an 80-sample replicated
  border, extended once after filtering. Block loops, intra costs and motion
  costs therefore read unclamped rows; integer motion costs read the
  reference directly through one portable `#simd` SAD kernel.
- The forward transform pairs reflected samples (DCT symmetry checked at
  init), runs the column pass on `#simd` rows in exact i32, and keeps exact
  i64 row sums, halving the products.
- Flat `BIT_COSTS`, `Tree_Code` and per-frame motion-vector component cost
  tables replace recursive tree walks and 16-step fixed-point probability
  loops; per-reader columnar `Motion`, `Filter_Cell` and `Edge_Context` grids
  replace the `Mode_Info` grid.
- Four tiles and wavefront loop filtering scale across the pool.

## Movie writer

`video.Writer` with `codec = .VP9` writes WebM through the native media
provider: one colour encoder and, with `transparency = .Straight`, a second
for the alpha stream (`Packet.alpha`). QP 0..51 maps to
`base_q_idx = 5 * qp`. Frame timestamps come from the rational frame rate in
nanoseconds, without accumulating rounded deltas, and the last frame gets
its actual duration. Audio is refused rather than dropped.
`tests/movie_alpha_write.odin` covers it; its WebM decodes in odecs
identically to libvpx and passes `tests/vp9_browser_check.sh`.
