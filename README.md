# odecs

<img src="assets/logo.svg" width="128" alt="odecs: a pixel-art turntable">

Native Odin media codecs and containers: video, audio and image decoding and
encoding with no FFmpeg or other codec library at runtime. Hardware video
coding goes through Vulkan Video on Linux and VideoToolbox on macOS, with the
native codecs as the software path. MIT licensed ([LICENSE](LICENSE)).

## Packages

Video:
- `h264/{encoder,decoder}`: H.264, progressive 8-bit 4:2:0 encoding and 4:2:0 or 4:2:2 decoding at 8 to 10 bits, with encoder checkpoints for editing ([README](h264/README.md)).
- `h265/{encoder,decoder}`: H.265 Main, Main 10 and range extensions; HEVC with an alpha layer, encoded and decoded ([README](h265/README.md)).
- `prores/decoder`: Apple ProRes 422 and 4444/XQ with alpha ([README](prores/README.md)).
- `vp9/{encoder,decoder}`: VP9 decoding, profiles 0–3 with alpha streams; encoding, profile 0 with alpha ([README](vp9/README.md)).
- `av1`: AV1 syntax for hardware decoding through Vulkan Video ([README](av1/README.md)).

Audio:
- `aac/{encoder,decoder}`: AAC-LC, 1 to 8 channels ([README](aac/README.md)).
- `opus`: Opus decoding (SILK, hybrid, CELT), with loss concealment, FEC, DTX and surround ([README](opus/README.md)).
- `flac`: FLAC decoding, 4 to 32 bits ([README](flac/README.md)).
- `alac`: Apple Lossless (ALAC) decoding, 16/20/24/32-bit, 1 to 8 channels ([README](alac/README.md)).
- `mp3`: MPEG-1/2/2.5 Layer III decoding ([README](mp3/README.md)).

Images:
- `webp`: WebP lossy, lossless, alpha and animation to RGBA8 ([README](webp/README.md)).

Containers:
- `mp4`: MP4/M4A/MOV reading (including fragmented `moof`/`traf`) and writing ([README](mp4/README.md)).
- `webm`: WebM/Matroska reading, and VP9 WebM writing with alpha ([README](webm/README.md)).
- `ogg`: Ogg (for Ogg Opus) ([README](ogg/README.md)).
- `wav`: WAV, RF64 and RIFX ([README](wav/README.md)).

Putting them together:
- `media`: one encode/decode API over the native codecs and the hardware ones, choosing what the machine supports ([README](media/README.md)).
- `media/vulkan`: the Vulkan Video provider, with its H.264, H.265 and AV1 sessions and the shared `Context` ([README](media/vulkan/README.md)).
- `media/videotoolbox`: the VideoToolbox provider, H.264 and HEVC hardware decoding and encoding on macOS ([README](media/videotoolbox/README.md)).
- `movie`: RGBA or planar frames and `f32` PCM from and to movie and audio files, with frame-accurate seeking; writes MP4/M4A (H.264, H.265, HEVC with alpha, AAC-LC) and WebM (VP9, with alpha) ([README](movie/README.md)).
- `viewer`: an SDL3 player for all of the above.

Each layer imports only the ones below it: `common`, then the codecs and
containers, then `media` with one provider package per backend under it, then
`movie`.

Parallel work runs on the caller's `common.Work_Pool`; the codecs never create
threads of their own.

## Using it

The packages import each other by relative path, so odecs can be vendored
into a project or used as a collection:

```sh
odin build . -collection:deps=path/to/parent-of-odecs
```

```odin
import movie "deps:odecs/movie"

config := movie.default_writer_config(1920, 1080, 30000, 1001)
w: movie.Writer
err := movie.create(&w, "out.mp4", config)
for frame in frames do err = movie.write_frame(&w, frame.rgba, frame.width * 4)
err = movie.finish(&w)
movie.destroy(&w)
```

Each package's README covers its API, limits and how it was verified.

Requirements:
- A recent Odin nightly; odecs is built and tested with `dev-2026-10`.
- For hardware video, a Vulkan driver with Vulkan Video (loaded at runtime;
  without one the native codecs are used) or macOS VideoToolbox.
- The viewer uses `vendor:sdl3`: `odin build viewer -o:speed && ./viewer.bin FILE`.
- The SPIR-V for the compute shaders is committed; `shaders/build.sh`
  rebuilds it with `slangc`.

Unit tests run with `odin test`, for example `odin test vp9/encoder`.
The `tests/` scripts compare odecs with reference decoders and encoders
(FFmpeg, libvpx, libwebp and others); they are development tools and need
those binaries installed.

## Platforms

The native codecs and containers are plain Odin and build for Linux, Windows
and macOS. Hardware video goes through Vulkan Video on Linux (Windows needs
only its Vulkan loader name added) and VideoToolbox on macOS, where H.264 and
HEVC decode and encode in hardware. AV1 decodes only in hardware, through
Vulkan Video.

## Sources and licenses

Some packages are ported from permissively licensed projects (libopus,
libwebp, Apple ALAC, minimp3, PDMP3, gen2brain/h265, oxideav-h265, Kvazaar,
OpenH264). Their notices are kept beside the code (each package's `LICENSE-*.txt`) and
[PROVENANCE.md](PROVENANCE.md) records what came from where. The reference
sources themselves are never committed: `bash tools/fetch_third_party.sh`
fetches them at the commits pinned in
[THIRD_PARTY_REFERENCES.md](THIRD_PARTY_REFERENCES.md). They and the `tests/`
scripts are for development only.

The [`demo/`](demo/README.md) is a script for
[onimite](https://github.com/defnotmid/onimite), an Odin + Lua video
framework built on odecs. It carries its own asset notices in
`demo/LICENSES/` (SIL OFL fonts, an MIT avatar clip).
