# AV1

AV1 decodes in hardware only, through Vulkan Video (`VK_KHR_video_decode_av1`).
This package parses the syntax and keeps the reference state that the
hardware needs as data:

- OBUs in the low-overhead format;
- the sequence header;
- the uncompressed frame header, with `set_frame_refs`, `setup_past_independence`/`load_previous`, segmentation, loop filter, CDEF, loop restoration, global motion and film grain parameters;
- tile groups.

Field names follow the *AV1 Bitstream & Decoding Process Specification*,
and so match Vulkan's `StdVideoAV1*` structures.
[`media/vulkan/av1_frontend.odin`](../media/vulkan/av1_frontend.odin) maps the eight
reference frames to DPB slots and hands each frame to the driver. There is
no software pixel decoder.

```odin
import av1 "../av1"

p: av1.Parser
frames: [dynamic]av1.Frame
tiles: [dynamic]av1.Tile
err := av1.parse_temporal_unit(&p, unit, &frames, &tiles) // one temporal unit
// frames in decode order: each header, its OBU offset and its tiles'
// offsets and sizes within `unit`; reference state updated after each (7.20)
```

Through the common API, AV1 is `media.Codec.AV1`, one temporal unit per
`.Frame` packet. Only the Vulkan provider admits it, for host output.
`video.Reader` reads it from MP4 (`av01`/`av1C`) and Matroska (`V_AV1`).

## Scope

- Main profile, 4:2:0, 8 and 10 bits. Monochrome and the High and Professional profiles are refused (Unsupported).
- Every Main tool the driver implements is supported:
  - superres, film grain (applied by the driver, or skipped on request or when the device cannot apply it);
  - segmentation, several tiles and tile groups;
  - scaled references, error resilience and frame ids.
- Hidden frames shown later (`show_existing_frame`) are served from a host copy, because the DPB image can't be read back.
- Scalable streams (`operating_point_idc` ≠ 0), large-scale tile lists and frames shown twice are refused.
- **RADV limitation:** on Mesa 26.2 with VCN 5 (RX 9070 XT), predicting a frame of **odd height** from a reference of a **different size** faults the GPU. The decode reports success, then the device is lost and the kernel resets the ring.
  - The frontend refuses such frames before submitting them.
  - FFmpeg's Vulkan decoder handles the same stream. Comparing the two submissions field by field, slot map included, against FFmpeg 9.0's `vulkan_av1.c` and Mesa's `radv_video.c` found no difference, so the cause is still open.
  - Odd widths, odd heights without scaling, and scaling at even heights all decode exactly.

## Verification

`bash tests/av1_check.sh` uses fixtures from `bash tests/av1_fixtures.sh`, written by:

- SVT-AV1: hidden ALTREFs shown again, 10-bit, superres, film grain;
- libaom: 4 tiles, 3 tile groups per frame, error resilience, segmentation, and key frames sized differently from inter frames (references scaled down 352→235, an odd width, and up 176→235);
- rav1e.

It checks three things:

1. **Headers.** Every frame header element that FFmpeg's `trace_headers` prints must equal ours, frame by frame.
2. **Raw decode.** Decoding each raw OBU stream must give exactly libdav1d's output, film grain included.
3. **Containers.** The MP4 and Matroska copies, read through `video.Reader`'s planar output, must also equal libdav1d's output.

The gate also confirms that the RADV case above is refused.

A real 10-bit 720p60 file (7650 frames) decodes to an MD5 identical to libdav1d's. On the RX 9070 XT, the first 1500 frames take (best of five, on a loaded machine):

| decoder | ms/frame |
|---|---|
| `video.Reader`, planar, 3 frames in flight, native-width planes | 0.82 |
| `video.Reader`, one at a time, u16 planes | 2.33 |
| FFmpeg Vulkan with download (whole file) | 1.24 |
| dav1d, one thread | 1.6 |
| dav1d, all threads (3.6 cores busy) | 0.93 |
