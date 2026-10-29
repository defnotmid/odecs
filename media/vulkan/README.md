# Vulkan Video

This package uses Odin's `vendor:vulkan` definitions and loads the system Vulkan
loader (`libvulkan.so.1` on Linux, `vulkan-1.dll` on Windows) through `core:dynlib`. It links no codec library. FFmpeg and HM are used
only as optional test oracles. Use `media` for the
common provider API; `provider()` here is the Vulkan provider, and the
lower-level sessions in this package serve codec-specific callers.

The native codecs own bitstream syntax, POC, reference derivation and display
order. The Vulkan frontends reuse those facts to build StdVideo descriptors and
associate reference pictures with GPU DPB slots. Pixel reconstruction runs in
the driver; decoding through this package does not run the native pixel decoder.

| Operation | Implemented scope |
| --- | --- |
| H.264 encode | High, progressive 8-bit 4:2:0, constant QP, IDR/P pictures |
| H.264 decode | Baseline/Main/High, progressive 8-bit 4:2:0, admitted native syntax |
| HEVC encode | Main 8-bit / Main10 10-bit, progressive 4:2:0, constant QP, IDR/P pictures |
| HEVC decode | Main 8-bit / Main10 8 or 10-bit, progressive 4:2:0, admitted native syntax |
| AV1 decode | Main 8 or 10-bit 4:2:0, host output; syntax from `av1`; see [its scope](../../video/av1/README.md) |

Host decode keeps `DECODE_DEPTH` (3; `-define:ODECS_DECODE_DEPTH=n`) pictures
in flight, each with its own output image, bitstream and readback buffers.
`decode_picture` returns the picture submitted two calls earlier, and
`finish_decoder` returns the rest. The frontends keep a queue of what each
submission becomes, so display order is unchanged. Device output keeps one
picture, because its surface is borrowed until the next call.

Every frontend delivers `Decoder_Frame` (`H264_Frame`, `H265_Frame` and
`AV1_Frame` are aliases of it). Its host planes have `media.Video_Frame`'s
shape: bytes at 8 bits, LSB-aligned u16 above, strides in bytes, starting at
the crop origin. At 8 bits the luma plane is the readback buffer itself and
only the interleaved chroma is split; P010 is shifted down in one pass.
`append_frame_samples` writes a frame tightly (yuv420p/yuv420p10le).

Decode time per frame through `video.Reader`, one picture in flight against
three (`-define:ODECS_DECODE_DEPTH`), and against FFmpeg's Vulkan Video with
each frame downloaded, is in [BENCHMARKS.md](../../BENCHMARKS.md)
(`bash tests/compare.sh run gpu/decode`, `tests/movie_decode_timing.odin`).

H.265 binds every picture its RPS keeps, the Foll sets included, as FFmpeg
does. RADV's firmware loses what an unbound slot held, and the leading
(RASL) pictures of a mid-stream CRA reference pictures the CRA itself does
not; before, they decoded wrong in open-GOP streams (x265's default).
`bash tests/gpu_check.sh` writes fixtures and runs the hardware tests,
such a stream among them (`hevc_test.odin`).

Encoding supports GOP lengths 1 through 32768, with one preceding reference.
GOP 1 is all-intra; larger GOPs insert IDRs at picture 0, GOP, 2×GOP, and so on.
Each IDR packet carries driver-generated parameter sets. Input can be host
planar data or a same-device NV12/P010 `Surface`. Byte and 16-bit input bounds, sample depth,
device limits and feedback ranges are checked. `encode_frame`, `encode_frame16`
and `encode_surface` return owned packets; delete each packet after use.
`encode_frame_borrowed`, `encode_frame16_borrowed` and `encode_surface_borrowed`
publish into retained encoder storage, valid until the next encode call or
destruction. Consume borrowed packets before encoding again and do not delete
them. Owned and borrowed entrypoints share validation, GPU submissions, history
and packet packaging. The common Vulkan media adapter uses borrowed publication
only during its callback. Capacity grows only when a packet exceeds the retained
capacity; the contiguous parameter-set/body copy is still required.
An invalid input leaves the encoder usable; a failed submission poisons it and
requires a new session.

`Config.frames_in_flight` (up to `MAX_FRAMES_IN_FLIGHT`) pipelines encoding.
Zero or one keeps each call synchronous: it returns its own packet. With N,
each picture gets its own input image, staging buffer, bitstream buffer, query
and command buffers; uploads and encodes chain through two timeline semaphores
with no host wait, and a call returns the oldest packet once N pictures are
queued (nil before that). After the last picture, call `flush_encoder` or
`flush_encoder_borrowed` until it returns nil. Host planes are copied before
the call returns, and Surface input waits only for its GPU copy, so both input
borrows still end with the call. The bitstream is identical at every depth.
The common Vulkan media adapter uses three pictures in flight and flushes them
in `drain` (`-define:ODECS_ENCODE_DEPTH` sets the depth). When it came in, 900 1080p I420 frames through `video.Writer` on an RX 9070 XT
(`tests/movie_encode_timing.odin`): H.264 3.64 → 2.01 ms/frame, HEVC 3.59 →
1.56 ms/frame, with identical MP4 bytes; the hardware encoder became the bound
(the encoding thread about 30% busy). The current figures at depths 1 and 3
are in [BENCHMARKS.md](../../BENCHMARKS.md) (`bash tests/compare.sh run gpu/encode`).

Host pixel staging is allocated only on the first validated host encode. A
surface-only encoder has no mapped raw-pixel upload buffer. Device decoding also
allocates no host pixel/readback buffer. Compressed packet storage remains on
the host because the API returns Annex-B packets to the caller.

`probe` checks codec profiles, operation queues, extents, synchronization2,
timeline semaphores, required image usages/formats and decode output layouts.
Device output also requires mutable sampled plane views and a compute queue.
`driver_supported` describes the driver profile;
`annex_b_implemented` describes the supported frontend/profile/DPB route. Final
initialization also checks image formats, reference bounds and session features.
A positive probe is not a substitute for checking initialization and stream
errors. Explicit unsupported syntax or resource layouts return `Unsupported`.
No codec history is switched after a submission fails.

Decode currently requires distinct output/DPB pictures and separate DPB images.
Drivers requiring a single DPB image are refused by the decode route. Encoding
supports both separate DPB images and one layered DPB image. A real integrated
GPU test exposed the previous unconditional separate-image encoder allocation:
it violated a driver capability requirement and faulted the GPU. The encoder
now uses one two-layer image when `SEPARATE_REFERENCE_IMAGES` is absent, and the
same integrated GPU passed the 37-picture GOP-15 gate after the fix.

The public common API subsequently passed 37-picture GOP-15 roundtrips for
H.264 320×240, HEVC8 320×240 and HEVC10 322×242, with exact native/GPU decoded
pixels. The HEVC encodes used the integrated GPU and therefore exercised the
layered-DPB path, including Main10 SPS cropping. `tests/media_surface.odin`
then consumed all three through only the public media API and exported Surface
dispatch: 37 sampled-plane Slang pictures matched planar reference pixels
exactly (4,262,400, 4,262,400 and 8,649,564 bytes respectively).

## Resident output

`Host` output reads back pixels and can retain reordered pictures for display.
`Device` output skips readback, requires a compute-capable queue and zero
bitstream reorder depth, and emits a borrowed `Surface` in each frame callback.
`H264_Decoder_Config.no_reordering` asserts a reorder depth of zero for streams
whose SPS leaves it implied (the caller knows from its container).
The surface provides the device, physical device, sampled Y/UV views, coded
extent, layout, compute queue/family and timeline readiness semaphore/value.
Visible dimensions and crop origin belong to the frontend frame. The exported
plane views cover the coded picture; apply the frame's crop when sampling.

`device_api` is the device owner's borrowed `vk.Device_VTable`;
`get_memory_properties` allows an external consumer to allocate on that device
without global Vulkan dispatch tables or another loader. The device, dispatch
and queue remain valid until decoder close for a private device, or until shared
Context close when borrowed from that Context. Keep active decoders at stable
addresses. Device output refuses coded shape, depth, profile or DPB changes
that would replace the exported device.

Wait for `ready_semaphore` to reach `ready_value` before sampling, using the
exported compute queue. Leave the output image in the exported `GENERAL` layout.
Submit and finish consumer work before returning from the callback; do not
retain the image/views for later frames. The next decode also waits for exposed
compute-queue work before reusing the output image. Use an application-owned
copy when longer retention is necessary. Calls and queue submissions have one
owner; simultaneous queue use needs caller synchronization.

`shaders/video_readback.slang` is a real consumer gate: it samples both exposed
planes on that queue after the timeline wait and writes planar integer pixels
into a test-owned storage buffer. The test reads that result to compare exact
bytes. It validates decode-to-compute use; it is not a codec implemented in a
shader.

## Shared device and resident encoding

`init_context` chooses one physical device supporting the union of requested
codec profiles, operations and planned extents. It enables the union of required
Vulkan extensions and deduplicates decode, encode and compute queue families.
All sessions borrow the same device and one owned dispatch table:

```odin
requests := []vulkan.Request{
    {codec=.H265, operation=.Decode, width=400, height=256,
     bit_depth=10, require_compute=true},
    {codec=.H265, operation=.Encode, width=386, height=242, bit_depth=10},
}
shared: vulkan.Context
err := vulkan.init_context(&shared, {requests=requests, device_index=-1})
// Check err; keep shared at this address until every session is closed.
providers := []media.Provider{vulkan.provider(&shared)}
// Open decode/encode sessions with these providers; decode uses Device output.
// Close every session before checking vulkan.destroy_context(&shared).
```

Low-level encoder/decoder configs accept `shared_context: ^Context`; omitting
it preserves the independent device path. `probe_capabilities(request, &shared)` checks only
that Context's physical device. Declared requests establish the enabled codec
operations; each actual session still checks its profile, extents and resources.
The entire union must fit one GPU. For example, this machine's discrete HEVC
encoder has minimum width 384, while its integrated decoder lacks the admitted
DPB layout; combining 320-wide HEVC decode and encode into one Context returns
`Unsupported` rather than selecting different devices.

`context_descriptor` borrows the device, dispatch, memory-property function and
actual compute queue/family until Context close. It does not retain the Context
or own external consumer resources. Destroy consumer resources before closing
the Context. `destroy_context` returns `Busy` without changing any handles while
sessions are alive, including lazy frontends that have not received an SPS.
Sessions release their holds at close. Empty Context close is idempotent.
Context and sessions must remain at stable addresses. One submitting owner
serializes all host access to Context queues, including exported raw compute
queue use. No lock is held through callbacks; a decode callback may synchronously
encode or compute using the shared device.

`encode_surface(encoder, surface, crop_x, crop_y)` synchronously borrows the
source image and returns an owned Annex-B packet. It requires the same `VkDevice`,
matching NV12/P010 format and bit depth, `TRANSFER_SRC` usage, `GENERAL` or
`TRANSFER_SRC_OPTIMAL` layout, and accessibility on the Context compute family.
Source extents are positive/even and bounded by the physical device limits;
crop origins are even and the visible encoder rectangle must fit the source.
Caller-supplied metadata must describe a genuine live image and the queue family
on which it is accessible. The source cannot be the encoder input image or alias
its backing memory; arbitrary image-memory aliasing cannot be introspected here.
Readiness is either a timeline semaphore with a positive value or both fields
zero when the caller has already completed producer work on the exposed queue.
The source image layout stays unchanged.

The encoder copies each plane and clamped edge padding into its encode input
image on the GPU. It reuses retained copy-region scratch and consumes both the
source readiness timeline and its preceding binary encode completion. Host and
Surface input can therefore alternate within one encoder history. Invalid
geometry, foreign devices, unsupported formats/usages/layouts and malformed
readiness pairs return typed errors before command recording or history changes.
This path has no CPU pixel transfer; it uses a GPU image copy rather than binding
the decoder image directly as encoder input.

## Validation

Ordinary tests do not require a GPU. Hardware flags request actual execution
and fail when the required hardware is unavailable.

```sh
odin test media/vulkan -o:speed -define:ODECS_PATENTED=true
odin test media/vulkan -o:speed -define:ODECS_PATENTED=true -define:ODIN_TEST_THREADS=1 -define:ODECS_GPU_TEST=true \
  -define:ODECS_GPU_CODEC=h265 -define:ODECS_GPU_WIDTH=384 \
  -define:ODECS_GPU_HEIGHT=240 -define:ODECS_GPU_DEPTH=10 \
  -define:ODECS_GPU_QP=26 -define:ODECS_GPU_GOP=15 \
  -define:ODECS_GPU_FRAMES=37
ffmpeg -v error -i /tmp/odecs-gpu-h265.265 -f null -
```

Encoder gate flags are `ODECS_GPU_TEST`, `ODECS_GPU_CODEC` (`h264`/`h265`),
`ODECS_GPU_WIDTH`, `ODECS_GPU_HEIGHT`, `ODECS_GPU_DEPTH`, `ODECS_GPU_QP`,
`ODECS_GPU_GOP` and `ODECS_GPU_FRAMES`. Output is
`/tmp/odecs-gpu-h264.264` or `/tmp/odecs-gpu-h265.265`.
`ODECS_GPU_TRACE=true` prints the selected encoder device and decoder failure
stage. The environment must expose a real Vulkan device; device discovery from
a sandbox without `/dev/dri` does not validate execution.

For the resident shader gate, provide a low-delay HEVC fixture, optionally also
a low-delay H.264 fixture:

```sh
odin test media/vulkan -o:speed -define:ODECS_PATENTED=true -define:ODIN_TEST_THREADS=1 -define:ODECS_GPU_SURFACE_TEST=true \
  -define:ODECS_GPU_SURFACE_FIXTURE=/absolute/low-delay.265 \
  -define:ODECS_GPU_AVC_SURFACE_FIXTURE=/absolute/low-delay.264
```

Compare `/tmp/odecs-gpu-surface.yuv` and
`/tmp/odecs-gpu-avc-surface.yuv` with planar reference decodes using the fixture's
bit depth. P010 results are little-endian 16-bit samples with values 0..1023.

The shared-device gate generates 37 pictures and compares an all-host reference
encoder with one encoder alternating Host/Surface/Host input. It also exercises
a real second Context, lazy-frontend `Busy`, constructor refusal rollback and
surface preflight without consuming history:

```sh
odin test media/vulkan -o:speed -define:ODECS_PATENTED=true -define:ODIN_TEST_THREADS=1 \
  -define:ODECS_GPU_CONTEXT_TEST=true -define:ODECS_GPU_CODEC=h265 \
  -define:ODECS_GPU_DEPTH=10 -define:ODECS_GPU_WIDTH=386 \
  -define:ODECS_GPU_HEIGHT=242 -define:ODECS_GPU_GOP=15
```

Use `h264`/8, `h265`/8 and `h265`/10 to cover all encode formats. Mixed streams
are saved to `/tmp/odecs-context-mixed.264` or `.265`.
All three 386×242 gates passed: 25 surface frames and 12 host frames per stream
matched the all-host encoded bitstream exactly. Each also passed real foreign
Context and self-image refusal, below-device-minimum decoder constructor
rollback, lazy pixel-upload allocation and borrowed-owner close controls.
`tests/media_pipeline.odin` tests the public provider route with resident decode
feeding surface encode, and compares complete output bitstreams and pixels with
native decode plus host upload:

```sh
odin build tests/media_pipeline.odin -file -o:speed -out:/tmp/odecs-media-pipeline
/tmp/odecs-media-pipeline /absolute/low-delay.265 h265 400 256 10 \
  /tmp/odecs-device-crop 6 4 386 242
```

The final public matrix passed twelve 37-picture cases: six direct cases and
six real Slang compute-producer cases, each covering H.2648/HEVC8/HEVC10 at
384×240 and a 400×256 source cropped at (6,4) to 386×242. Complete output
bitstreams and decoded pixels matched the same-GPU host oracle exactly. Each
direct case also passed eleven typed refusals without poisoning the encoder.
`tests/media_compute_pipeline.odin` uses only public Context/Surface APIs: an
external Slang producer samples decode output, copies its device buffer into a
caller-owned NV12/P010 image and feeds resident encode. Each compute case
reported zero host pixel transfers, one already-completed readiness input and
36 timeline-readiness inputs. The three mixed-input package gates above provide
the additional alternating-input and owner-lifetime controls.

Verified on RX 9070 XT/RADV GFX1201: H.264 18 feature cases plus 54-picture
1080p streams; HEVC 22 Main/Main10 feature cases, including weighted prediction,
TMVP, WPP, reordered/hierarchical B pictures, scaling lists and combined tools;
the original twelve-picture 3840×3840 X5 stream; and exact sampled-plane shader
output for H.264 and HEVC10 37-picture GOP-15 streams. Valid HEVC RExt RDPCM
fixtures return `Unsupported` through Vulkan while native output matches the
reference. Separate encoder gates validate H.2648/HEVC8/HEVC10 IDR/P streams,
periodic IDRs, cropped dimensions and planar reference decodes. These are
driver-specific correctness gates, not portable throughput measurements.

## Remaining integration

The shared Context and Surface encode path allow caller-owned compute pipelines
to operate between decode and encode on one GPU. A complete stitching/viewer
pipeline remains application work. Resident reordered decode output needs
retained images with explicit release rather than the current one-callback surface.
Persistent decoder checkpoints, resumable packet fragments, rate control and
B-picture encoding remain outside this backend. Native codec APIs remain the
first-class route for their broader supported profiles and options.
