# VP9 encoding

Native Odin VP9 profiles 0–3 (8/10/12-bit, 4:2:0 / 4:2:2 / 4:4:0 / 4:4:4), written
from the VP9 Bitstream & Decoding Process Specification v0.7. No codec library
is linked or loaded. The probability defaults, reconstruction, prediction,
inverse transforms, quantizers and filter are shared with [`vp9`](../README.md).

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

- Input: three sample planes (`encode_frame` / `reconstruction` for 8-bit `u8`,
  `encode_frame16` / `reconstruction16` for 10/12-bit `u16`), strides in samples.
  `subsampling` selects `.YUV420` (default), `.YUV422`, `.YUV440`, or `.YUV444`;
  `bit_depth` selects `8` (default), `10`, or `12`. Odd and non-block-aligned
  sizes work; edge samples are replicated for block analysis. Input is borrowed
  only during the synchronous call. Colour is already BT.709 limited-range YUV.
- `base_q_idx`: 0..255, **not** H.264/HEVC QP. Zero (with zero `delta_q_*`) is
  exactly lossless; lossy keyframes with `keyframe_interval > 1` scale the AC
  quantizer step to 45%, and high-skip streams modulate an 8-frame golden-frame
  group around `base_q_idx`. `delta_q_y_dc`, `delta_q_uv_dc`, and `delta_q_uv_ac`
  (-15..15) apply per-plane quantizer index deltas.
- `keyframe_interval`: zero selects 120. Frame zero is a keyframe, followed
  by keyframes at multiples of the interval. Unshown alt-ref frames and 1-byte
  `show_existing_frame` packets are supported via `encode_altref_frame` /
  `encode_altref_frame16` and `encode_existing_frame`, with 4-slot probability
  contexts (`contexts[0..3]`, selected by `frame_context_idx`).
- `block_log2`: zero selects 6 (64x64); 3, 4, 5, 6 permit partitions up to 8,
  16, 32, or 64 pixels. By default (`ultrafast = false`), 32x32, 16x16, and 8x8
  blocks that exceed the homogeneity threshold compare `PARTITION_NONE`,
  rectangular `PARTITION_HORZ` / `PARTITION_VERT`, and `PARTITION_SPLIT`
  (including sub-8x8 `BLOCK_8X4`, `BLOCK_4X8`, `BLOCK_4X4`) by exact
  rate-distortion cost (reconstruction SSE plus staged symbol bits);
  `ultrafast = true` splits in a single top-down pass. Lossy frames signal
  `TX_MODE_SELECT` and choose 4x4..32x32 transforms per block with
  transform-domain RDO refinement; lossless always uses 4x4 WHT.
- `search_range`: zero selects 16; otherwise 1..64 pixels. Spatial and
  co-located temporal predictors (`NEARESTMV`, `NEARMV`, `ZEROMV`, `NEWMV`),
  coarse-to-fine integer diamond search, then leaf-only half-/quarter-/eighth-pixel
  (`allow_high_precision_mv`) 8-tap refinement using SAD plus exact motion-vector
  bit cost from per-frame cost tables. Inter frames reference `LAST_FRAME`
  (slot 0), `GOLDEN_FRAME` (slot 1, refreshed on keyframes and every 8 frames),
  and `ALTREF_FRAME` (slot 2), plus `COMPOUND_REFERENCE` (`LAST + GOLDEN` or
  `LAST + ALTREF` averaged prediction) and `SWITCHABLE` 8-tap interpolation
  filters (`EIGHTTAP`, `EIGHTTAP_SMOOTH`, `EIGHTTAP_SHARP`) when `ultrafast = false`,
  with an intra fallback across all ten intra modes when inter residual is high.
- `ultrafast`: when true, uses single-pass top-down partition decisions,
  fixed `EIGHTTAP` interpolation, `ZEROMV`-only golden checks, and the four basic
  intra modes (`DC`, `V`, `H`, `TM`).
- `tile_cols_log2`: clipped to the specification's width-dependent limits.
  Zero normally means one tile; 2 permits four at 1080p. Tiles run on the
  caller's `common.Work_Pool`. A nil pool executes exactly the same tile
  jobs serially, and produces identical bytes. The codec creates no threads.
- Loop-filter level follows libvpx's AC-quantizer curve (`0.316 * ac_q + 3.87`,
  minus 4 on keyframes), capped at 63; lossless disables it.
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

Shown key/inter frames, single- and compound-reference motion (`ZEROMV`,
`NEARESTMV`, `NEARMV`, `NEWMV` over `LAST_FRAME` and `GOLDEN_FRAME`), switchable
8-tap interpolation filters (`EIGHTTAP`, `EIGHTTAP_SMOOTH`, `EIGHTTAP_SHARP`),
and all ten luma and chroma intra prediction modes (`DC_PRED ..= TM_PRED`).
Lossy luma uses DCT/ADST 4..16 and DCT 32, chroma DCT; VP9 has no 32-point
ADST. The shared forward transform uses separable fixed-point butterfly stages
transposed from the normative synthesis constants; it is not a port of libvpx's
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
skip, transform size, inter mode, switchable filter, reference mode, single
and compound reference, intra mode, partition and motion vector probabilities),
each only where it pays for its own bits on this frame's counts. Tiles stage
their symbols, and code them in parallel on the pool once the header has settled
the probabilities. Inter-frame coefficients are pruned in scan order by
rate-distortion EOB truncation against the frame's adapted token probabilities.
Segmentation (`SEG_LVL_ALT_Q`, `SEG_LVL_ALT_L`, `SEG_LVL_REF_FRAME`, `SEG_LVL_SKIP`)
with direct or temporal segment-map updates, per-plane quantizer deltas, and
loop-filter reference/mode deltas are supported.

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
- The forward DCT and ADST transforms run separable butterfly stages on `#simd`
  i32 lanes, keeping 4x4 and 8x8 2-D transforms in registers.
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
