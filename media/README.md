# Common codec API

`media` owns provider selection, streaming calls, borrowing and drain state.
The `native`, `vulkan` and `videotoolbox` child packages are explicit providers.
They use our own Odin codecs, Odin's `vendor:vulkan` bindings (Vulkan is loaded
with `core:dynlib` at runtime), and Apple's VideoToolbox through
[`videotoolbox`](videotoolbox/README.md); no external codec library is
linked. The VideoToolbox provider reports itself unavailable off Apple
platforms, so it can be listed everywhere.

| Operation | Native provider | Vulkan provider | VideoToolbox provider |
| --- | --- | --- | --- |
| H.264 encode | Progressive 8-bit 4:2:0, constant QP, periodic IDR/P | High, 8-bit 4:2:0, constant QP, periodic IDR/P | High, 8-bit 4:2:0, constant QP, periodic IDR/P (I420 or NV12) |
| H.264 decode | Supported progressive tools; 4:2:0 or 4:2:2, 8 to 10 bits (High 10, High 4:2:2) | Baseline/Main/High, progressive 8-bit 4:2:0 | Baseline/Main/High, progressive 8-bit 4:2:0, host output |
| HEVC encode | 8/10-bit, 4:2:0/4:2:2/4:4:4/mono, periodic IDR/P | Main/Main10, 8/10-bit 4:2:0, periodic IDR/P | Main, 8-bit 4:2:0, constant QP, periodic IDR/P (I420 or NV12) |
| HEVC decode | Implemented Main/Main10 and RExt tools | Main/Main10 4:2:0, 8/10-bit | Main/Main10 4:2:0, 8/10-bit, host output |
| AAC encode/decode | AAC-LC, 1..8 channels, 960/1024 samples, standard 7350..96000-Hz rates | Unsupported; selects native in Automatic mode | Unsupported |
| ProRes decode | 422 Proxy/LT/Standard/HQ (10-bit), 4444/XQ (12-bit) with alpha, interlaced | Unsupported | Unsupported |
| VP9 decode | Profiles 0–3, 8/10/12-bit, 4:2:0/4:2:2/4:4:4/sRGB, alpha stream | Unsupported | Unsupported |
| FLAC decode | RFC 9639: 4–32-bit, 1–8 channels, every subframe type and stereo mode | Unsupported | Unsupported |
| ALAC decode | 16/20/24/32-bit, 1–8 channels (MPEG/AAC canonical order); see [`alac`](../audio/alac/README.md) | Unsupported | Unsupported |
| MP3 decode | MPEG-1/2/2.5 Layer III, mono/stereo (Layers I/II and free format refused) | Unsupported | Unsupported |
| Opus decode | SILK, hybrid and CELT at 48 kHz, DTX, multistream up to 255 channels (Opus mapping order); see [`opus`](../audio/opus/README.md) | Unsupported | Unsupported |
| AV1 decode | Unsupported (hardware only) | Main 4:2:0, 8/10-bit, host output; see [`av1`](../video/av1/README.md) | Unsupported |

Hardware capabilities depend on the actual device, driver, dimensions, profile,
bit depth, formats and queue operations. Driver support is separate from
implemented Annex-B support. Vulkan Video has no AAC codec operation.

```odin
import media "../media"
import native "../media/native"
import vulkan "../media/vulkan"

providers := []media.Provider{native.provider(), vulkan.provider()}
config := media.default_config(.H264, .Encode)
config.width, config.height = 1920, 1080
// Default video GOP is 15: IDR followed by P pictures. GOP 1 is all-intra.
session: media.Session
err := media.open(&session, config, providers)
// Check err. session.backend/provider_name identify the selected implementation.
defer media.close(&session)

err = media.encode_video(&session, frame, {packet=write_packet,user=&output})
// Check each call, drain at end, then close.
err = media.drain(&session, {packet=write_packet,user=&output})
```

`Automatic` tries implemented hardware providers before native ones regardless
of array order. `Require_Hardware` returns an error when hardware admission
fails; `Native` bypasses hardware. In automatic mode `hardware_error` records
the admission failure when native is selected. Both providers retain temporal
encoding for an explicit GOP request. Vulkan's GOP range is 1..32768; native
HEVC's advanced API keeps its existing unbounded low-delay behavior when
`idr_period=0`, independently of the common API's default.

Fallback happens at initialization. For video decoding, supply indexed source
width, height, chroma and bit depth; native also accepts unspecified dimensions.
Optional `profile_idc` is source metadata for hardware admission (AVC 66/77/100;
HEVC 1/2, or 4 for RExt). A known RExt source selects native before stream input.
Unknown SPS tools, DPB requirements, reordering or resource changes can still
produce a typed refusal when parsed. A stream failure requires a new session
and replay from a random-access point; the API never switches codec history
after consuming input. `error_detail` carries the native codec diagnostic where
available. A failed session rejects further calls until close/reopen.

Keep sessions at stable addresses and close before reuse. Calls and callbacks
execute on the caller's thread. Re-entry returns `Busy`. The selected allocator
owns session allocations, including when a different ambient allocator is
active at close. The API does not create playback threads or service audio.
Serialize calls on each session; `Busy` is a re-entry guard, not a cross-thread
lock. Native H.264 encoder/decoder APIs return their typed `Error` enums,
including encoder initialization, cancellation and checkpoint release.
`error_description` and `error_detail` are diagnostics; branch on the error enum
or the decoder's `is_unsupported` predicate.

Native video scheduling is an explicit provider binding:

```odin
import common "../common"

pool: common.Static_Pool
common.init_static_pool(&pool, 2)
defer common.destroy_static_pool(&pool) // after every bound session closes
options := native.Options{
    pool=&pool.work_pool,
    h264_slice_count=4,
    h265_tile_cols=2, h265_tile_rows=2,
}
providers := []media.Provider{native.provider(&options), vulkan.provider()}
```

Keep the provider binding alive while probing/opening. Each native session
snapshots the scalar geometry and borrows the pool through close. A zero slice
count preserves H.264's four-slice default; zero tile dimensions preserve
untiled HEVC. Probe validates geometry for the corresponding encode operation.
H.264 slice coding/interpolation and HEVC tile search run synchronous disjoint
ranges over retained codec state. Pool size does not change slice/tile geometry.
Use one submitting owner per pool; do not run concurrent or nested codec calls
through the same pool. Native decoders and AAC do not use this binding for
within-stream parallelism.

Host video input is planar Y/U/V, with byte strides and explicit `storage_bits`.
Native HEVC host output uses bytes for 8-bit video and 16-bit storage for deeper
video; Vulkan HEVC host output uses 16-bit storage even for 8-bit video; native
AVC uses bytes. Decoder outputs are cropped views. Callbacks borrow
frame/packet/sample storage only until they return; copy data you need to retain.
Native HEVC promptly releases display pictures while preserving DPB references.
Native HEVC borrows aligned 16-bit input with positive even byte strides and
equal chroma strides, validating every active sample before advancing history.
It copies/pads into the codec-owned source during the synchronous call; the
adapter adds no packing pass for this input. Byte input, unaligned/odd strides
and unequal chroma strides use retained conversion scratch. Input planes may be
released after the call returns.

Native H.264 publishes one complete Annex-B NAL per packet callback, in bitstream
order: IDR parameter sets followed by slice lanes. These callbacks borrow the
codec's lane storage directly, without concatenating slices into an adapter
frame buffer. The common provider uses zero checkpoint capacity. Codec-specific
`encode_frame_lanes` cannot share a seekable contiguous output history or retain
checkpoints; use the contiguous encoder API when those features are required.
Vulkan packet callbacks instead borrow one contiguous packet from retained
encoder storage; capacity grows only when needed. Vulkan keeps three pictures
in flight: the first two calls publish nothing, each later call publishes the
picture two calls back, and drain publishes the rest. Both publication modes retain
the common callback-only lifetime.

For GPU image processing, set `output_storage=.Device` before opening. During
the video callback, `vulkan.surface(frame)` returns the typed `vulkan.Surface`:
its Vulkan device, dispatch table, compute queue, sampled Y/UV views and a
readiness timeline semaphore/value. Wait on that timeline in the submitted
compute work and complete it before returning. Preserve the exported image
layout. With a provider-owned device, destroy consumer Vulkan objects before
closing the decoder. Its device/dispatch stay stable until close; a shared
Context keeps them alive until Context destruction. The picture is borrowed only
for the callback. Device output currently requires no display reordering and refuses
resource reconfiguration. Host output supports reordered frames. An H.264 SPS
without a bitstream-restriction reorder bound implies the full DPB as reorder
depth; when the container shows presentation order equals decode order (no
composition offsets), set `Config.no_reordering` on the decoder so pictures are
output as they complete and Device output is admitted. Encoders refuse it.

For multiple sessions and external compute, initialize a stable `vulkan.Context`
with the required decode/encode `vulkan.Request` list, then supply
`vulkan.provider(&shared)` to `media.open`. Probing and opening use that Context's
physical device and dispatch; they do not select another GPU. `Provider.user`
is the borrowed binding passed to both provider callbacks. The common `Config`
stays independent of backend types. Lazy decoder frontends retain the Context
before the first SPS; `vulkan.destroy_context` returns `Busy` while sessions hold
it. Close every bound session and destroy external Vulkan objects before
destroying the Context. `vulkan.context_descriptor` exports the shared device,
dispatch, memory query and compute queue for caller-owned processing resources.
Serialize common API calls and external submissions on these queues.

Vulkan encoding also accepts `storage=.Device` with a same-device NV12/P010
`vulkan.Surface` in `frame.surface`. Match the encoder's bit depth, provide accurate
image extents and even visible crop coordinates, and preserve the declared
`GENERAL` or `TRANSFER_SRC_OPTIMAL` layout. The image needs `TRANSFER_SRC` usage
and must be accessible on the exported compute queue family. A decoder surface or a
generic caller-owned transfer image can supply it; video image usage/profile
metadata is not required for the input. Supply a timeline readiness semaphore
and positive value for pending producer work, or leave both zero after completing
the producer on that queue. Encoding copies visible samples and clamped edge
padding entirely on the GPU, then borrows the compressed host packet to the
callback. Native encoding refuses Device input before consuming codec state.

The public [shader-consumer gate](../tests/media_surface.odin) uses this API
and the exported dispatch to sample decoded pictures; downloading its results
is only pixel verification. The [shared-device gate](../tests/media_pipeline.odin)
compares direct resident decode/encode with host upload on the same GPU. The
[compute-producer gate](../tests/media_compute_pipeline.odin) packs sampled
planes with Slang into a device-local transfer buffer, copies them to a generic
caller-owned image and passes it to Device encoding. Its resident branch has no
pixel download/upload; it compares the resulting bitstream and decoded pixels
against the same-GPU host path. These gates use no private GPU resource helpers.

ProRes, VP9, AV1 (a temporal unit) and FLAC take one container sample per
packet with `Framing.Frame`; AV1's `av1C` configuration OBUs may be sent
first as a packet of their own (MP3 likewise, one frame per packet; a stream that switches
between mono and stereo frames is delivered at the session's channel count,
and a frame whose bit reservoir is missing after a seek decodes as
silence). A FLAC session needs `Config.extradata` with the stream's
metadata (Matroska CodecPrivate, MP4 `dfLa`, or a bare streaminfo block);
its audio frames are interleaved `f32` at sample / 2^(bits-1), positioned
by the packet's `sample_index` when `sample_rate` is set, else by the frame
header. `is_audio` tells AAC, FLAC and MP3 from the video codecs.
HEVC with an auxiliary alpha layer (H.265 Annex F: a second layer whose
VPS extension gives it AuxId 1, as Apple's "HEVC with alpha" and x265
`--alpha` write) decodes natively: the VPS starts a second decoder for that
layer, each decoder ignores the other layer's NAL units, and each base
picture is delivered with the alpha picture of the same POC as
`Video_Frame.alpha`. Other second layers (MV-HEVC's second view) are
ignored, and Vulkan Video, which decodes the base layer only, is not used
for alpha streams. Alpha layers that signal a POC LSB in IDR slices or the
multilayer SPS form are refused until a sample with them is available.
For VP9, `Packet.alpha` carries the alpha stream's frame (WebM
`BlockAdditional` 1). The session decodes it with its own decoder and returns
its luma as `Video_Frame.alpha`, with the luma's size, depth and storage.
ProRes 4444 alpha arrives the same way. ProRes frames are 16-bit storage at
10 bits (4:2:2) or 12 bits (4:4:4). VP9 frames are bytes at 8 bits and
16-bit storage otherwise. Both decode synchronously: a packet's picture is
delivered during its `decode` call, and a VP9 packet holding only hidden
frames delivers none. `Video_Frame.color` reports the bitstream's colour
description; matrix 0 (identity) marks VP9 sRGB stored as G, B, R planes.
The native options' pool runs ProRes slices, VP9 tile columns and loop
filter waves. Neither codec has an encoder.

`decode` accepts complete NAL units or complete Annex-B units/streams, and AAC
ADTS, raw AAC or LOAS packets. Packet fragments, container demuxing and muxing
are outside this layer: [`mp4`](../container/mp4/README.md)
muxes/demuxes MP4, and [`video`](../video/README.md) joins both for
RGBA/PCM files. POC describes codec picture order; video timestamps, time
bases and source/edit metadata belong to the caller. Do not treat POC as a
continuous timestamp across random-access resets.

Encoders write `Config.color` (ITU-T H.273 primaries/transfer/matrix and
range) into the SPS VUI, so players convert to RGB as intended; BT.709
limited range is `{1, 1, 1, false}`. The zero value leaves the VUI as before,
byte-identical. Native H.264 then also signals zero reordering in the VUI
bitstream restriction. Optional `frame_rate_num/frame_rate_den` select the
level for the frame rate (native H.264 above 30 fps, native HEVC at any rate)
and the HEVC VUI timing.

AAC input is exactly N interleaved finite `f32` samples per channel in [-1,1].
Set `Config.frame_samples` to 960 or 1024; zero resolves to 1024. Configure a
standard sample rate and 1..8 channels before opening. Output follows canonical
AAC front/side/back/LFE element order, with left/right within each CPE. Standard
eight-channel configuration 7 is wide 7.1; seven channels use a PCE. See the
[native AAC API](../audio/aac/README.md) for each standard layout and further tools.

`Config.audio_transport` selects encoder `ADTS`, `Raw` or `LOAS` framing.
ADTS encoding with N=960 returns `Unsupported` during admission; Raw/LOAS can
signal that frame size through ASC. Decoder input uses `Packet.framing` values
`ADTS`, `Raw_AAC` or `LOAS`. Optional `Config.extradata` is a borrowed ASC read
only during open; its parsed program is copied into codec state and must match
the configured sample rate, channels and resolved N. ADTS supports CRC and up
to four AUs per transport frame; native LOAS supports one synchronous program/
layer and up to 64 AUs. Native output is full-range PCM; parsed DRC remains
metadata. HE-AAC/SBR/PS and Main/SSR/LTP profiles remain unsupported.

The first accepted encoder input retains lookahead and emits no packet. Later
calls publish at most one AU/frame directly from native retained packet storage.
Drain publishes the pending AU and final overlap AU as separate callbacks,
then completes; repeating drain emits nothing. AAC packet callbacks carry
`sample_rate`, `duration_samples=N` and `sample_index`, measured per channel in
the input PCM timeline. Priming begins at `sample_index=-N`; discarding N decoded
samples places input sample zero at time zero. Preserve the original unpadded
input length separately for final trimming. There is no container gapless
metadata in this API.

Audio callbacks publish one N-sample AU view even when the transport contained
multiple AUs. Their `sample_index` follows explicit incoming packet timing when
`Packet.sample_rate` is nonzero; otherwise the session advances its default
timeline from -N. All PCM and packet views borrow storage only until the
callback returns. AAC decoder sessions retain a bounded 64-AU PCM area; encoder
callbacks add no output concatenation or per-AU allocation. Each stream's
overlap/noise history remains ordered. Schedule independent sessions
concurrently for aggregate throughput, retaining one owner per stream.

Use codec-specific APIs for further native options, hierarchical GOPs, rate
control and native H.264 checkpoints. Hardware sessions can pause
while their resources stay alive. Durable resume/rewind belongs in an export
layer using independently decodable GOP/chunk boundaries, saved edit recipes
and mux timestamps. The common API has no persistent checkpoint facility.

Validation:

```sh
odin test media -o:speed
odin test media/native -o:speed
odin test media/vulkan -o:speed
odin build tests/media_gpu.odin -file -o:speed -out:/tmp/odecs-media-gpu
/tmp/odecs-media-gpu --hardware /tmp/odecs-media h264 8 15 37
ffmpeg -v error -i /tmp/odecs-media.264 -f rawvideo -pix_fmt yuv420p -y /tmp/odecs-media-reference.yuv
cmp /tmp/odecs-media.yuv /tmp/odecs-media-reference.yuv
odin build tests/media_surface.odin -file -o:speed -out:/tmp/odecs-media-surface
/tmp/odecs-media-surface /tmp/odecs-media.264 h264 320 240 8 /tmp/odecs-media-shader.yuv
cmp /tmp/odecs-media-shader.yuv /tmp/odecs-media-reference.yuv
odin build tests/media_pipeline.odin -file -o:speed -out:/tmp/odecs-media-pipeline
/tmp/odecs-media-pipeline /tmp/odecs-media.264 h264 320 240 8 /tmp/odecs-media-pipeline
odin build tests/media_compute_pipeline.odin -file -o:speed -out:/tmp/odecs-media-compute-pipeline
/tmp/odecs-media-compute-pipeline /tmp/odecs-media.264 h264 320 240 8 /tmp/odecs-media-compute
```

`media_gpu` also accepts `h265`, depth 8/10, GOP/frame count and optional width/
height. The hardware gate requires both encode and decode, checks multiple IDRs
and the final drained picture, and compares native/GPU pixels. Run without
`--hardware` in a software-only environment to verify automatic fallback.
FFmpeg and HM are optional validation oracles, never runtime dependencies.
