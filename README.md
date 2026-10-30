# odecs

<img src="assets/logo.svg" width="128" alt="odecs: a pixel-art turntable">

Native Odin media codecs and containers: video, audio and image decoding and
encoding with no FFmpeg or other codec library at runtime. Hardware video
coding goes through Vulkan Video on Linux and Windows and VideoToolbox on macOS, with the
native codecs as the software path; native H.264 and H.265 are compiled in only
with `-define:ODECS_PATENTED=true` ([media](media/README.md)). MIT licensed ([LICENSE](LICENSE)).

## Packages

Video:
- `video/h264/{encoder,decoder}`: H.264, progressive 8-bit 4:2:0 encoding (Baseline/Main/High, CAVLC/CABAC, 4x4/8x8 transforms) and 4:0:0, 4:2:0, 4:2:2 or 4:4:4 decoding at 8 to 10 bits (including lossless transform bypass), with encoder checkpoints for editing ([README](video/h264/README.md)).
- `video/h265/{encoder,decoder}`: H.265 Main, Main 10 and range extensions; HEVC with an alpha layer, encoded and decoded ([README](video/h265/README.md)).
- `video/prores/decoder`: Apple ProRes 422 and 4444/XQ with alpha ([README](video/prores/README.md)).
- `video/vp9/{encoder,decoder}`: VP9 decoding, profiles 0–3 with alpha streams; encoding, profile 0 with alpha ([README](video/vp9/README.md)).
- `video/av1`: AV1 syntax for hardware decoding through Vulkan Video ([README](video/av1/README.md)).

Audio:
- `audio/aac/{encoder,decoder}`: AAC-LC, 1 to 8 channels ([README](audio/aac/README.md)).
- `audio/opus`: Opus decoding (SILK, hybrid, CELT), with loss concealment, FEC, DTX and surround ([README](audio/opus/README.md)).
- `audio/flac`: FLAC decoding, 4 to 32 bits ([README](audio/flac/README.md)).
- `audio/alac`: Apple Lossless (ALAC) decoding, 16/20/24/32-bit, 1 to 8 channels ([README](audio/alac/README.md)).
- `audio/mp3`: MPEG-1/2/2.5 Layer III decoding ([README](audio/mp3/README.md)).
- `audio/vorbis`: Vorbis I decoding ([README](audio/vorbis/README.md)).
- `audio/wav`: WAV, RF64 and RIFX reading; 16-bit PCM and float writing ([README](audio/wav/README.md)).

Images:
- `image`: one decode path for PNG, JPEG, BMP, TGA, QOI, GIF and WebP to RGBA8, Radiance HDR to linear f32, and PNG writing.
- `image/jpeg`: baseline and progressive JPEG, identical to libjpeg-turbo and as fast ([README](image/jpeg/README.md)).
- `image/gif`: GIF decoding, the first frame or the animation composited as browsers show it ([README](image/gif/README.md)).
- `image/bmp`: BMP decoding by stb_image's rules ([README](image/bmp/README.md)).
- `image/png/encoder`: PNG writing ([README](image/png/README.md)).
- `image/webp`: WebP lossy, lossless, alpha and animation to RGBA8 ([README](image/webp/README.md)).
- `image/hdr`: Radiance RGBE to linear RGBA f32, identical to stb_image's `stbi_loadf` ([README](image/hdr/README.md)).

Containers:
- `container/mp4`: MP4/M4A/MOV reading (including fragmented `moof`/`traf`) and writing ([README](container/mp4/README.md)).
- `container/webm`: WebM/Matroska reading, and VP9 WebM writing with alpha ([README](container/webm/README.md)).
- `container/ogg`: Ogg (for Ogg Opus and Ogg Vorbis) ([README](container/ogg/README.md)).

Putting them together:
- `media`: one encode/decode API over the native codecs, system codecs and hardware ones, choosing what the machine supports ([README](media/README.md)).
- `media/vulkan`: the Vulkan Video provider, with its H.264, H.265 and AV1 sessions and the shared `Context` ([README](media/vulkan/README.md)).
- `media/videotoolbox`: the VideoToolbox provider, H.264 and HEVC hardware decoding and encoding on macOS ([README](media/videotoolbox/README.md)).
- `media/avcodec`: the runtime-loaded `libavcodec` system provider for H.264 and H.265 ([README](media/avcodec/README.md)).
- `media/mediafoundation`: the Windows Media Foundation system provider, H.264 and H.265 decoding and encoding through the transforms Windows ships (H.265 with the HEVC Video Extensions) ([README](media/mediafoundation/README.md)).
- `media/audiotoolbox`: the macOS AudioToolbox system provider, AAC-LC, HE-AAC and HE-AAC v2 decoding and AAC-LC encoding ([README](media/audiotoolbox/README.md)).
- `audio`: any file's first audio track (AAC, PCM, FLAC, MP3, Opus, ALAC, Vorbis in MP4, Matroska, WAV, FLAC, MP3 or Ogg) as interleaved `f32` in WAVE channel order, with seeking; `decode` for a file in memory ([README](audio/README.md)).
- `video`: RGBA or planar frames and `f32` PCM from and to movie files (its audio through `audio`), with frame-accurate seeking; writes MP4/M4A (H.264, H.265, HEVC with alpha, AAC-LC) and WebM (VP9, with alpha) ([README](video/README.md)).
- `viewer`: an SDL3 player for all of the above.

Each layer imports only the ones below it: `common`, then the codecs and
containers, then `audio` (the audio decoders behind one dispatch), then
`media` with one provider package per backend under it (its native provider
decodes audio through `audio`), then `video`. `image` stands on the image
codecs alone. Neither facade imports the other or anything of video's, so an
audio-only or image-only program links no video codec.

Parallel work runs on the caller's `common.Work_Pool`; the codecs never create
threads of their own.

## Using it

The packages import each other by relative path, so odecs can be vendored
into a project or used as a collection:

```sh
odin build . -collection:deps=path/to/parent-of-odecs
```

```odin
import video "deps:odecs/video"

config := video.default_writer_config(1920, 1080, 30000, 1001)
w: video.Writer
err := video.create(&w, "out.mp4", config)
for frame in frames do err = video.write_frame(&w, frame.rgba, frame.width * 4)
err = video.finish(&w)
video.destroy(&w)
```

Each package's README covers its API, limits and how it was verified.

Requirements:
- A recent Odin nightly; odecs is built and tested with `dev-2026-10`.
- For hardware video, a Vulkan driver with Vulkan Video (loaded at runtime;
  without one the native codecs are used) or macOS VideoToolbox. Without
  `-define:ODECS_PATENTED=true`, H.264 and H.265 have only these.
- The viewer uses `vendor:sdl3`: `odin build viewer -o:speed && ./viewer.bin FILE`.
- The SPIR-V for the compute shaders is committed; `shaders/build.sh`
  rebuilds it with `slangc`.

Unit tests run with `odin test`, for example `odin test video/vp9/encoder`.
The `tests/` scripts compare odecs with reference decoders and encoders
(FFmpeg, libvpx, libwebp and others); they are development tools and need
those binaries installed.

## Speed and size against the references

`bash tests/compare.sh` measures each native decoder and encoder against its
references, on one pinned core unless a case says otherwise: FFmpeg n9.0.2
(with its Vulkan Video decoding and encoding), libvpx, libopus, libwebp,
libjpeg-turbo, libvorbis, dav1d, x264 and x265, all built from their pinned
sources, and Odin's vendored stb_image. Encoders are also compared by size at
equal quality (BD-rate). Every figure, with its date, revision, machine and
load, is in [BENCHMARKS.md](BENCHMARKS.md), which the script writes;
`bash tests/compare.sh run REGEX` measures one case again.

## Platforms

The native codecs and containers are plain Odin and build for Linux, Windows
and macOS. Hardware video goes through Vulkan Video on Linux (Windows needs
only its Vulkan loader name added) and VideoToolbox on macOS, where H.264 and
HEVC decode and encode in hardware. AV1 decodes only in hardware, through
Vulkan Video.

## Sources and licenses

Some packages are ported from permissively licensed projects (libopus,
libwebp, Apple ALAC, minimp3, PDMP3, gen2brain/h265, oxideav-h265, Kvazaar,
OpenH264). Their notices are kept beside the code (each package's
`LICENSE-*.txt`) and [PROVENANCE.md](PROVENANCE.md) records what came from
where. The reference
sources themselves are never committed: `bash tools/fetch_third_party.sh`
fetches them at the commits pinned in
[THIRD_PARTY_REFERENCES.md](THIRD_PARTY_REFERENCES.md). They and the `tests/`
scripts are for development only.

The [`demo/`](demo/README.md) is a script for
[onimite](https://github.com/defnotmid/onimite), an Odin + Lua video
framework built on odecs. It carries its own asset notices in
`demo/LICENSES/` (SIL OFL fonts, an MIT avatar clip).
