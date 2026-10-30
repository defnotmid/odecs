# oicut demo

A 28 second showcase of oicut, music included: 1920x1080, 60 fps, 112 BPM.
It is an [onimite](https://github.com/defnotmid/onimite) script (Odin + Lua
video framework, which decodes its clips and encodes its output with oicut),
not part of oicut's build.

| bars | scene | what |
| --- | --- | --- |
| 1-2 | Title | the codecs and containers oicut handles land one on each note of the marimba hook, then the wordmark slams in on the timpani |
| 3-5 | Alpha | the ProRes 4444 avatar and its VP9-alpha WebM, decoded on the frame clock and composited live over sliding stripes with a glow, each with its decode numbers |
| 6-7 | WebP | `bryce.webp` (11158×2156 lossy) panned across the frame, with its decode time |
| 8-10 | Encode | three charts a bar each: Vulkan Video decoding and encoding, whose bars shrink on beat 3 (a pizzicato note) from one picture at a time to three in flight, then the pooled native H.264 encoder next to x264 |
| 11-13 | Outro | the wordmark over the soundtrack's spectrum |

## Render

With an [onimite release](https://github.com/defnotmid/onimite/releases)
on the PATH, from the oicut directory:

```sh
sh demo/fetch.sh && onimite render demo/video.lua --qp 22 -o demo/demo.mp4
```

`fetch.sh` downloads the clips the repository doesn't hold (below), once;
`onimite preview demo/video.lua` plays the video with hot reload. Neither
the clips nor `demo.mp4` are committed.

Mix (`onimite audio analyze`, v0.0.59): -14.4 LUFS integrated, -2.0 dBTP
true peak, the limiter's default ceiling, which leaves the AAC encode room
under -1.

## Facts on screen

`facts.lua` reads every measured number from `BENCHMARKS.tsv` at load, the
file `bash tests/compare.sh run` writes (BENCHMARKS.md shows the same rows);
nothing is copied by hand or measured for this video. A missing row stops the
render with the case to run.

| on screen | BENCHMARKS.tsv rows |
| --- | --- |
| ProRes 4444 + alpha and VP9 + alpha stream, 1080p, frames per second at 1 and 8 threads | `alpha/prores4444/fps-1t`, `-8t`; `alpha/vp9-alpha/fps-1t`, `-8t` |
| 11158 × 2156 lossy WebP on one core, against libwebp 1.6.0 | `decode/webp-bryce` |
| all 131 corpus files RGBA-identical to dwebp | `image/webp/README.md`, the gate checks (not a measurement) |
| Vulkan Video decode, ms per frame, one picture in flight → three: 1080p H.264, 1080p H.265, 720p 10-bit AV1 | `gpu/decode-h264`, `-h265`, `-av1`, `/depth1` and `/depth3` |
| Vulkan Video encode, 900 1080p frames, the same: H.264, HEVC | `gpu/encode-h264`, `-h265`, `/depth1` and `/depth3` |
| native H.264 encoder, 16 slices on 16 workers, QP 27, against x264 medium with the same tools | `encode/h264-16/speed` |

## The soundtrack

`track.lua` is an odawg `song{}`, composed for the video: a West London
broken beat after Bugz in the Attic's "Booty La La" (a live kit whose
snare leaves the backbeat every other bar, swung sixteenth hats with
ghosts, a fingered bass locked to the kick, jazz-funk chords on keys), in F
minor at 112 BPM. The hook is a marimba zig-zag up the chord tones; the
picture answers to the song's own notes (timpani at the slam and the
outro, a xylophone note under each fact, a pizzicato note as each chart
shrinks, the kick). Every part names its `role` in the mix.

## Files

`video.lua` sets up the video, the beat-synced glitch cuts and the HUD;
`scenes/` holds one file per scene; `track.lua` is the soundtrack, its
sections named after the scenes; `timeline.lua` reads from it on which beat
everything happens; `beat.lua` is the clock and easing on the song's beat;
`facts.lua` the numbers on screen; `ui.lua` the palette and type.

## Credits and licences

- `transparent.mov` (fetched): ProRes 4444 with alpha, the avatar clip of
  fframes' audio-announce example, MIT (`media/fframes-MIT.txt`).
- `avatar_vp9_alpha.webm` (fetched, an asset of oicut's v0.0.12 release):
  the same avatar as VP9 with an alpha stream, made from it with FFmpeg;
  fframes' MIT licence.
- `bryce.webp` (fetched): from libwebp's test corpus,
  https://chromium.googlesource.com/webm/libwebp-test-data at commit
  06ddd96e276c2c638a72d39d3c0f340afd61978c (the commit
  `tests/webp_fixtures.sh` pins); the WebM project's BSD-style licence.
- Fonts, SIL Open Font License 1.1 (`media/OFL.txt`, with each font's
  copyright), copied from onimite's examples: Bebas Neue, Space Grotesk,
  JetBrains Mono.
- The soundtrack's instruments, all CC0 1.0: Virtuosity Drums (Versilian
  Studios and Karoryfer Samples), Growlybass (Karoryfer Samples), VCSL's
  upright piano and VS Chamber Orchestra 2: Community Edition (Versilian
  Studios) for the marimba, xylophone, timpani and strings. odawg fetches
  the samples a note reaches on first use, each checked against a pinned
  SHA-256 (VS Chamber Orchestra 2's in `media/pins/vsco.pins`); none are in
  the repository.
