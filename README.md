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
- `image`: one decode path for PNG, JPEG, BMP, TGA, QOI, GIF and WebP to RGBA8, and PNG writing.
- `jpeg`: baseline and progressive JPEG, identical to libjpeg-turbo and as fast ([README](jpeg/README.md)).
- `gif`: GIF decoding, the first frame or the animation composited as browsers show it ([README](gif/README.md)).
- `bmp`: BMP decoding by stb_image's rules ([README](bmp/README.md)).
- `png/encoder`: PNG writing ([README](png/README.md)).
- `webp`: WebP lossy, lossless, alpha and animation to RGBA8 ([README](webp/README.md)).

Containers:
- `mp4`: MP4/M4A/MOV reading (including fragmented `moof`/`traf`) and writing ([README](mp4/README.md)).
- `webm`: WebM/Matroska reading, and VP9 WebM writing with alpha ([README](webm/README.md)).
- `ogg`: Ogg (for Ogg Opus) ([README](ogg/README.md)).
- `wav`: WAV, RF64 and RIFX reading; 16-bit PCM and float writing ([README](wav/README.md)).

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

## Decoding speed

Native decoding against FFmpeg n9.0.2, libvpx 1.17.0, libopus 1.6.1 and
libwebp 1.6.0, all built from their pinned sources. A ratio above 1 means
odecs is slower. Measured 2026-10-20 at v0.0.6 on one pinned core of a Ryzen 9
9900X3D. Each figure is the median of seven runs, with packets in memory, one
thread, and opening the decoder not timed. Other work kept the load average
at 2–3, and a repeat run agreed within about 2%.

| Input | odecs ms | Reference ms | Ratio | Reference |
| --- | --- | --- | --- | --- |
| AAC-LC, 128 kb/s stereo, 320 s | 140 | 78 | 1.80 | FFmpeg `aac` |
| FLAC, 16-bit stereo, 320 s | 228 | 138 | 1.66 | FFmpeg `flac` |
| VP9 profile 0, 1080p, 162 frames | 1271 | 796 | 1.60 | FFmpeg `vp9` (libvpx: 880 ms, 1.44) |
| VP9 profile 2, 10-bit | 1385 | 1003 | 1.38 | FFmpeg `vp9` (libvpx: 1221 ms, 1.13) |
| WebP lossy, 1920×1080 | 9.6 | 7.3 | 1.31 | libwebp |
| H.264 High, 8-bit, 1080p, 162 frames | 1370 | 1059 | 1.29 | FFmpeg `h264` |
| MP3, 192 kb/s stereo | 157 | 122 | 1.29 | FFmpeg `mp3float` |
| HEVC Main, 1080p | 1411 | 1113 | 1.27 | FFmpeg `hevc` |
| WebP lossy, 11158×2156 (`demo/media/bryce.webp`) | 209 | 168 | 1.24 | libwebp |
| H.264 High 4:2:2, 10-bit | 1670 | 1355 | 1.23 | FFmpeg `h264` |
| H.264 High 10, 4:2:0 | 1448 | 1178 | 1.23 | FFmpeg `h264` |
| HEVC Main 10 | 1534 | 1255 | 1.22 | FFmpeg `hevc` |
| Opus, 128 kb/s stereo | 394 | 327 | 1.20 | FFmpeg `opus` (libopus: 408 ms, 0.96) |
| ProRes 422 HQ, 1080p | 1784 | 1721 | 1.04 | FFmpeg `prores` |
| WebP lossless, 1920×1080 | 15.9 | 16.0 | 1.00 | libwebp |
| ALAC, 16-bit stereo | 375 | 425 | 0.88 | FFmpeg `alac` |
| ProRes 4444, 10-bit | 2472 | 3074 | 0.80 | FFmpeg `prores` |

The video is OpenH264's 1080p fixture looped three times. The audio is the
320 s of decoded RFC 8251 Opus test vectors. Both were encoded with x264,
x265, libvpx, `prores_ks` and FFmpeg's audio encoders. The H.264 High 10 row
was added once a 10-bit mb_qp_delta decoding bug was fixed, and the VP9 rows
were measured again after its decoder was restructured (3.40× and 2.99×
before). To rerun, use `tests/decode_benchmark.sh`.

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
