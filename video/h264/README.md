# H.264

Native H.264 (AVC) encoding (progressive 8-bit 4:2:0, Baseline, Main and High profiles) and decoding (progressive 4:0:0, 4:2:0, 4:2:2 and 4:4:4, 8 to 10 bits, including lossless transform bypass).

- `h264`: shared frame storage, syntax types, bitstream helpers, tables, transforms, prediction, macroblock neighbours and CPU deblocking.
- `video/h264/encoder`: Baseline, Main and High profile I/P encoding with CAVLC or CABAC, 4x4 and 8x8 transforms, motion search, rate control, slices on workers, checkpoints for editing, and optional Vulkan compute deblocking.
- `video/h264/decoder`: parameter sets, slices, CAVLC and CABAC, the decoded-picture buffer and output order.

The encoder and decoder do not import each other. Hardware H.264 (Vulkan
Video) is in [`media/vulkan`](../../media/vulkan/README.md), and [`media`](../../media/README.md)
picks between them.

## Decoder

```odin
import h264d "../h264/decoder"

d: h264d.Decoder_State
h264d.init_decoder(&d)
defer h264d.destroy_decoder(&d)
// for each NAL unit: h264d.decode_nal(&d, nal); then drain h264d.next_output_frame(&d)
// at the end: h264d.flush_decoder(&d), then drain again
```

- **Profiles:** Constrained Baseline, Main, High, High 10, High 4:2:2 and High 4:4:4 Predictive, progressive, 4:0:0, 4:2:0, 4:2:2 or 4:4:4 (`separate_colour_plane_flag == 0`) at 8 to 10 bits (luma and chroma at one depth), including lossless `qpprime_y_zero_transform_bypass_flag`. Pictures above 8 bits store u16 samples (`YUV_Buffer.high_depth`) and decode with i32 levels; 4:2:2 chroma planes are full height (`chroma_422`), 4:4:4 chroma planes are full width and height (`chroma_444`), and 4:0:0 omits chroma (`chroma_400`). Interlaced coding (fields, MBAFF), separate colour planes (`separate_colour_plane_flag == 1`), slice groups, SP/SI slices and data partitioning are refused explicitly (`Unsupported_*` errors) rather than decoded wrongly. The hardware frontends take 8-bit 4:2:0 only (`sequence_parameter_set_error` without `high_formats`).
- **Tools:** CABAC and CAVLC, all intra and inter partitions, B pictures with spatial and temporal direct, weighted prediction, multiple slices, long-term references, 8x8 transforms, lossless transform bypass and scaling matrices.

## Encoder

```odin
import h264 "../h264/encoder"

h264.init_encoder(&encoder, {width = 1920, height = 1080, qp = 26,
	gop_size = 15, num_ref_frames = 3, slice_count = 11, checkpoint_capacity = 8,
	cabac = true, transform_8x8 = true})
// encode_frame, or begin_encode_frame / advance_encode_frame / commit_encode_frame
```

- **Bitstream:** I and P pictures, CAVLC (Baseline) or CABAC (`cabac = true`, Main/High) with optional 8x8 transforms (`transform_8x8 = true`, High), constant QP or bitrate control, periodic IDRs, a fixed number of slices (`slice_count`, default 4) independent of the worker count.
- **Search:** integer motion search from the neighbours' and the previous macroblock's vectors (a poorly predicted macroblock also descends from a grid out to three search radii, for pans faster than the radius), then half- and quarter-sample refinement on reference planes interpolated once per picture; intra 4x4, 8x8 (`transform_8x8`) and 16x16 chosen before residual coding; candidates compared by reconstruction distortion and actual CAVLC/CABAC bits.
- **Speed:** `ultrafast` searches one reference and 16x16 motion only, and settles on inter sooner: 0.55-0.58 of the time for 1% smaller to 32% larger output at equal quality.

### Editing: checkpoints

The supported edit is: change source frame N, restore a retained checkpoint before N, and re-encode forward. Encoded output after the checkpoint is discarded. Rate-control history, references, frame and IDR counters and the output offset are restored together.

```odin
initial, err := h264.capture_encoder_checkpoint(&encoder, &stream) // keep, to edit frame 0
point, err := h264.capture_encoder_checkpoint(&encoder)            // at committed boundaries
restart, err := h264.rewind_encoder_to_edit(&encoder, n)           // then feed frames restart.. again
h264.release_encoder_checkpoint(&encoder, point)
```

Checkpoints pin immutable picture slots; they don't clone images.
`checkpoint_capacity` bounds them (0 disables), and capture fails explicitly
when it is full. `advance_encode_frame` codes a bounded number of macroblocks
per slice and returns; `cancel_encode_frame` abandons a frame before commit.

### Optional GPU deblocking

`init_compute_device` creates a Vulkan compute device and
`attach_encoder_compute` attaches it before the first frame. Boundary
strengths and filtering then run as Slang shaders (`shaders/deblock_*.slang`)
on one persistent allocation shared between CPU and GPU through buffer device
addresses, with no per-frame uploads. It is opt-in: it matches the CPU filter
exactly but is not faster than it on its own. It needs Vulkan 1.2 with buffer
device addresses (Linux and Windows loaders).

## Verification

- `odin run tests/test_kernels.odin -file -o:speed`, `tests/test_encoder_kernels.odin`, `tests/test_rd.odin`, `tests/test_state.odin`, `tests/test_checkpoint.odin`, `tests/test_parallel.odin`: scalar oracles for every intra direction, transform and quantizer QP, SAD/SSD, coefficient scans and quarter-sample positions; RD scoring; checkpoint, edit and cancel through 270 frames (frame-number wrap, IDRs, multiple references, rate control); exact parallel reconstruction.
- `tests/test_compute.odin`: GPU boundary strengths and every filtered pixel against the CPU filter.
- `bash tests/x264_matrix.sh`, `bash tests/encoder_matrix.sh`, `bash tests/vectors.sh`: x264 streams over the supported features, including High 10 and High 4:2:2 at 8 and 10 bits (and the expected refusals), our encoder's streams, and reference vectors, decoded pixel-identically to FFmpeg.

Speed against x264 `medium` with the same tools (one core, and 16 slices on 16
workers) and size at equal quality (BD-rate over QP 22 to 37) are in
[BENCHMARKS.md](../../BENCHMARKS.md) (`bash tests/compare.sh run encode/h264`).
