# H.264

Native H.264 (AVC) encoding (progressive 8-bit 4:2:0) and decoding (progressive 4:2:0 and 4:2:2, 8 to 10 bits).

- `h264`: shared frame storage, syntax types, bitstream helpers, tables, transforms, prediction, macroblock neighbours and CPU deblocking.
- `video/h264/encoder`: Baseline-style I/P encoding with CAVLC, motion search, rate control, slices on workers, checkpoints for editing, and optional Vulkan compute deblocking.
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

- **Profiles:** Constrained Baseline, Main, High, High 10 and High 4:2:2, progressive, 4:2:0 or 4:2:2 at 8 to 10 bits (luma and chroma at one depth). Pictures above 8 bits store u16 samples (`YUV_Buffer.high_depth`) and decode with i32 levels; 4:2:2 chroma planes are full height (`chroma_422`). Interlaced coding (fields, MBAFF), lossless (transform bypass), 4:0:0 and 4:4:4, slice groups, SP/SI slices and data partitioning are refused explicitly (`Unsupported_*` errors) rather than decoded wrongly. The hardware frontends take 8-bit 4:2:0 only (`sequence_parameter_set_error` without `high_formats`).
- **Tools:** CABAC and CAVLC, all intra and inter partitions, B pictures with spatial and temporal direct, weighted prediction, multiple slices, long-term references, 8x8 transforms and scaling matrices.

## Encoder

```odin
import h264 "../h264/encoder"

h264.init_encoder(&encoder, {width = 1920, height = 1080, qp = 26,
	gop_size = 15, num_ref_frames = 3, slice_count = 11, checkpoint_capacity = 8})
// encode_frame, or begin_encode_frame / advance_encode_frame / commit_encode_frame
```

- **Bitstream:** I and P pictures, CAVLC, constant QP or bitrate control, periodic IDRs, a fixed number of slices (`slice_count`, default 4) independent of the worker count.
- **Search:** integer motion search, then half- and quarter-sample refinement on reference planes interpolated once per picture; intra 4x4 and 16x16 chosen before residual coding; candidates compared by reconstruction distortion and actual CAVLC bits.

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

Encoder speed, 1080p, 16 slices on 16 workers (Ryzen 9 9900X3D, 2026-09-10):
144 fps at QP 26, against 221 fps for x264 `medium` with the same tools. x264
also used 21% fewer bytes at about the same PSNR, so rate/distortion
efficiency is the open work.
