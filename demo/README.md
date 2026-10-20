# odecs demo

A 26 second showcase of odecs, music included: 1920x1080, 60 fps, 120 BPM.
It is an [onimite](https://github.com/defnotmid/onimite) script (Odin + Lua
video framework, which decodes its clips and encodes its output with odecs),
not part of odecs' build. `demo.mp4` is the render.

onimite expects odecs checked out beside it. From the odecs directory:

```sh
git clone https://github.com/defnotmid/onimite ../onimite
cd ../onimite
odin build . -collection:deps=.. -o:speed -out:build/onimite_speed
build/onimite_speed render ../odecs/demo/video.lua -o ../odecs/demo/demo.mp4   # re-render
build/onimite_speed preview ../odecs/demo/video.lua                           # play, hot reload on save
```

| bars | scene | what |
| --- | --- | --- |
| 1-2 | Title | the codecs and containers odecs handles rain in on eighth notes, then the wordmark slams in |
| 3-5 | Alpha | the ProRes 4444 avatar and its VP9-alpha WebM, decoded on the frame clock and composited live over sliding stripes with a glow, each with its decode numbers |
| 6-7 | WebP | `bryce.webp` (11158×2156 lossy) panned across the frame, with its decode time |
| 8-10 | Encode | three charts a bar each: Vulkan Video decoding and encoding, whose bars shrink on beat 3 from one picture at a time to three in flight, then the pooled native H.264 encoder next to x264 |
| 11-13 | Outro | the wordmark over the soundtrack's spectrum |

## Facts on screen

Every number is in `facts.lua`, copied from odecs' docs; nothing was
measured for this video:

| on screen | source |
| --- | --- |
| ProRes 4444 + alpha, 1080p: 88 fps 1 thread, 322 fps 8 threads | `video/README.md`, Performance (frames through RGBA, file input) |
| VP9 + alpha stream, 1080p: 72 fps, 183 fps | same table |
| 11158 × 2156 lossy WebP: 223 ms on one core, libwebp 1.6.0 162 ms | `image/webp/README.md`, speed against libwebp |
| all 131 corpus files RGBA-identical to dwebp | `image/webp/README.md`, the gate checks |
| Vulkan Video decode, ms per frame, one at a time → three in flight: 1080p H.264 2.45 → 1.05, 1080p H.265 2.36 → 1.00, 720p 10-bit AV1 2.33 → 0.82 | `media/vulkan/README.md`, video.Reader on the RX 9070 XT |
| Vulkan Video encode, 900 1080p frames: H.264 3.64 → 2.01, HEVC 3.59 → 1.56 ms per frame | `media/vulkan/README.md`, three pictures in flight (`tests/movie_encode_timing.odin`) |
| native H.264 encoder: 144 fps at QP 26, x264 medium 221 fps | `video/h264/README.md`, 1080p, 16 slices on 16 workers |

## Files

`video.lua` sets up the video, the beat-synced glitch cuts and the HUD;
`scenes/` holds one file per scene; `track.lua` is the soundtrack, an
odawg `song{}` (an E minor broken beat, its sections named after the
scenes, its parts the pops and stutters the picture answers to);
`timeline.lua` reads from it on which beat everything happens; `beat.lua`
is the clock and easing on the song's beat.

Mix (`onimite audio analyze`): -15.1 LUFS integrated, -1.5 dBTP true
peak. Render: 1560 frames in 4.2 s wall, 309 MB peak RSS.

## Media

`transparent.mov` and `bryce.webp` are too large to commit, so they are not
in the repository; the scenes expect them in `media/`. Neither is the render,
`demo.mp4`.

- `transparent.mov`: ProRes 4444 with alpha, the avatar clip of fframes'
  audio-announce example (MIT, `LICENSES/fframes-MIT.txt`; copied from
  onimite's `examples/why_onimite`).
- `avatar_vp9_alpha.webm`: the same avatar as VP9 with an alpha stream,
  made with FFmpeg (fframes' MIT license, `LICENSES/fframes-MIT.txt`).
- `bryce.webp`: from libwebp's test corpus,
  https://chromium.googlesource.com/webm/libwebp-test-data at commit
  06ddd96e276c2c638a72d39d3c0f340afd61978c (the commit
  `tests/webp_fixtures.sh` pins); the WebM project's BSD-style license.
- Fonts, SIL Open Font License 1.1 (`LICENSES/OFL-1.1.txt`, with each
  font's copyright), copied from onimite's examples: Bebas Neue, Space
  Grotesk, JetBrains Mono.
- The soundtrack is composed by odawg from `track.lua`.
