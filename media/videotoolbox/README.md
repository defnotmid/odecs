# VideoToolbox

H.264 and HEVC decoding and encoding on Apple platforms through VideoToolbox:
the hardware codecs, or Apple's software codecs where there is no hardware
(unless `require_hardware` is set, as `media`'s `Require_Hardware` does).
Most callers use it through [`media`](../README.md)'s
`media_videotoolbox.provider()`, which `video` lists before Vulkan Video.
Off Apple platforms the package builds with a stub session that reports
`.Unavailable`, so it can be imported everywhere.

```odin
import vt "../media/videotoolbox"

d: vt.H265_Decoder
if vt.init_h265_decoder(&d) == .None { // require_hardware = true: .Unavailable without hardware HEVC decoding
	defer vt.destroy_h265_decoder(&d)
	// for each NAL unit (no start code): vt.decode_h265_nal(&d, nal, receive, user)
	// at the end: vt.flush_h265_decoder(&d, receive, user)
}
```

- **H.264:** Baseline, Main and High, progressive 8-bit 4:2:0.
- **HEVC:** Main and Main 10, 4:2:0, the base layer.
- Frames arrive in display order as planar 4:2:0: bytes at 8 bits, little-endian `u16` at 10.

## Encoding

`encoder_create` / `encoder_encode` / `encoder_destroy` run a compression
session (on the hardware encoder when `require_hardware` is set, else
whichever VideoToolbox picks): H.264 High or HEVC Main, 8-bit
4:2:0, BT.709 limited range, I and P pictures (no reordering), a keyframe
every `keyframe_interval` frames. `qp` is held constant by setting the
minimum and maximum frame QP to it (macOS 13 and later; the M4 honours
it), else it maps to the quality setting. Input is I420 or NV12, copied by
rows into a pixel buffer from the session's pool. Each call completes its
frame; the packet is Annex B, with the format description's parameter
sets before each keyframe.

On the M4 at 1080p through `video.Writer`: H.264 about 164 fps and HEVC
about 154 fps from I420 or NV12 (`tests/videotoolbox_encode_check.odin`),
both decoded by odecs' native decoders and FFmpeg; QP 18, 30 and 40 give
49.7, 43.6 and 37.8 dB (H.264, 720p).

## How it works

- **Our parsers lead.** The native parsers (`video/h264/decoder`, `video/h265/decoder`) split the stream into pictures and derive POC and reference marking. Display order is the H.264 decoder's output queue, and H.265's bumping process (C.5.2) over a DPB of picture descriptions. VideoToolbox gets one whole picture at a time, as length-prefixed NAL units, and keeps its own references.
- **Synchronous sessions.** Each picture is decoded synchronously, so pictures return in decode order. They are held, copied, until their turn.
- **Output formats.** The session always asks for a documented layout, in the stream's range: NV12 at 8 bits, and P010-style `x420`/`xf20` at 10. A decoder's own format can differ between chips, and the M4's at 10 bits is a private packed one.
- **Cropping.** VideoToolbox sizes its output to an SPS's cropping but takes it from the picture's top-left corner, ignoring left and top offsets. It is therefore given SPSs with cropping removed (`parameters.odin`) and returns whole coded pictures, which are cropped while they are copied.
- **Admission.** With `Preference.Require_Hardware`, `probe` admits a codec only when `VTIsHardwareDecodeSupported` says so and sessions require hardware acceleration; in `Automatic` mode VideoToolbox uses hardware when present and falls back to Apple's software codecs otherwise. A stream VideoToolbox refuses mid-way fails the session. `media` never switches decoders after input.

## Verification

- `odin test media/videotoolbox`, on any platform, tests the SPS rewriting (whole-SPS equality apart from the crop, VUI included) and the semi-planar copy.
- On a Mac with FFmpeg, `bash tests/conformance_check.sh` decodes every OpenH264 reference stream (`bash tools/fetch_third_party.sh openh264`) and the JCT-VC HEVC v1 conformance streams (`bash tests/hevc_conformance.sh`) with hardware required. It compares the output with the conformance MD5s, or with FFmpeg where a stream has none.
- On an M4 (macOS 27.0.1, 2026-10-11), 196 streams were bit-exact: 50 H.264 and all 146 HEVC streams FFmpeg can read.
  - Refused: 3 (unequal luma/chroma depths, a stream without an IDR, and one FFmpeg cannot read).
  - VideoToolbox limits: 3. Two streams reference deliberately lost pictures, which FFmpeg's VideoToolbox path rejects too. The third has 8160 slices in one picture; 255 decode fine.
- `tests/movie_backends.odin FILE` checks that `video.Reader` gives every frame, and seeks, identically through hardware and native decoding.

Speed on the M4, 240 frames, raw decode with frames copied to memory:

| Stream | VideoToolbox | Native |
| --- | --- | --- |
| H.264 1080p | 582 fps | 261 fps |
| HEVC 1080p | 703 fps | 225 fps |
| H.264 2160p | 152 fps | 63 fps |
| HEVC 2160p | 195 fps | 58 fps |

## Provenance

Written from Apple's CoreMedia, CoreVideo and VideoToolbox headers and
documentation, and from H.264 and H.265. The bindings declare only what the
decoder calls.
