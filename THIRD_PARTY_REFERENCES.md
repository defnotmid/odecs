# Reference sources

Reference implementations studied, ported or used as development oracles,
each pinned to an exact commit. `bash tools/fetch_third_party.sh [name...]`
fetches them into `third_party/` (a shallow fetch of that commit, or the
whole history where the host refuses one, then a detached checkout; existing
trees are left as they are). `third_party/` is never committed. What odecs
took from each, and under which license, is in [PROVENANCE.md](PROVENANCE.md).

| Reference | Used for | Local path | Commit | Commit date | License |
| --- | --- | --- | --- | --- | --- |
| [libopus](https://gitlab.xiph.org/xiph/opus) v1.6.1 | ported: `opus`; oracle | `third_party/opus` | `22244de5a79bd1d6d623c32e72bf1954b56235be` | 2026-01-13 | BSD-3-Clause |
| [libwebp](https://chromium.googlesource.com/webm/libwebp) v1.6.0 | ported: `webp`; oracle | `third_party/libwebp` | `4fa21912338357f89e4fd51cf2368325b59e9bd9` | 2025-07-07 | BSD-3-Clause + patent grant |
| [gen2brain/h265](https://github.com/gen2brain/h265) | ported: H.265 decoder | `third_party/h265` | `5138267a04330b8f0e36ddeabbcf6f49b664fa88` | 2026-08-30 | MIT |
| [oxideav-h265](https://github.com/OxideAV/oxideav-h265) | cross-reference: H.265 decoder | `third_party/oxideav-h265` | `a1ecd6adceedeefd83740f6537946cc3ee8ab3ec` | 2026-09-05 | MIT |
| [Kvazaar](https://github.com/ultravideo/kvazaar) | ported: H.265 encoder parts | `third_party/kvazaar` | `2b06691bb5844404c0e703f12a5d7b0fee914ec7` | 2026-09-14 | BSD-3-Clause |
| [OpenH264](https://github.com/cisco/openh264) | ported: H.264 CABAC tables; fixtures | `third_party/openh264` | `9d974972d9f1ef572b87d8d774af8f8c304ad3e1` | 2026-09-04 | BSD-2-Clause |
| [minimp3](https://github.com/lieff/minimp3) | ported: `mp3` | `third_party/minimp3` | `ea99364f61c14656440e8d77e9c233ccf3124633` | 2026-07-27 | CC0 1.0 |
| [PDMP3](https://github.com/technosaurus/PDMP3) | ported: MP3 synthesis window | `third_party/PDMP3` | `2a206a3ada78ec4d13434847f05f50097c60c36a` | 2017-08-12 | public domain (Unlicense) |
| [dr_libs](https://github.com/mackron/dr_libs) | read: `dr_mp3.h` | `third_party/dr_libs` | `dfe8377631000664666519fdb83da193fd8037f4` | 2026-09-01 | Unlicense or MIT-0 |
| [edge264](https://github.com/tvlabs/edge264) | read: H.264 decoder study | `third_party/edge264` | `2c2ab95d63c1ad89c5687f9e50b57cad772c871b` | 2026-07-28 | BSD-3-Clause |
| [hevc.js](https://github.com/lid-labs/hevc.js) | read: HEVC decoder study | `third_party/hevc.js` | `fa6c1bb2a58fbc1e425030555ef57121717de746` | 2026-10-01 | MIT |
| [Glint](https://github.com/CrispStrobe/glint) | read: AAC study | `third_party/glint` | `77738f3ed9b15f627196cc5bbd7f6406814ba2fb` | 2026-08-19 | MIT |
| [Apple ALAC](https://github.com/macosforge/alac) | ported: `alac` | `third_party/alac` | `c38887c5c5e64a4b31108733bd79ca9b2496d987` | 2011-10-26 | Apache-2.0 |
| [FFmpeg](https://github.com/FFmpeg/FFmpeg) n9.0.2 | oracle: decode reference and speed baseline (`tests/decode_benchmark.sh` builds it decoders-only, LGPL) | `third_party/ffmpeg` | `946fcce07b6dcd0331c8cc609192aeff5e1924f8` | 2026-09-18 | LGPL-2.1-or-later |
| [libvpx](https://github.com/webmproject/libvpx) v1.17.0 | oracle: VP9 decode reference and speed baseline | `third_party/libvpx` | `6df3ec34557879fff673706f4a1d9fbd0f3a6f0e` | 2026-08-20 | BSD-3-Clause + patent grant |

Submodules and dependencies are not fetched (Kvazaar's optional `greatest`
test submodule is not recreated). hevc.js's notices also name BSD-3-Clause
mp4box.js and CC-BY-3.0 Big Buck Bunny media, which odecs does not use.

## License file hashes

SHA-256 of the license files at the pinned commits, to check a fetched tree
against.

| File | SHA-256 |
| --- | --- |
| `third_party/opus/COPYING` | `01e1167d54a096d123cf6dfbbeb19587278845c6481d2d66d545669846079551` |
| `third_party/libwebp/COPYING` | `5aec868f669e384a22372a4e8a1a6cd7d44c64cd451f960ca69cc170d1e13acf` |
| `third_party/libwebp/PATENTS` | `cc3273e0694ea5896145e0677699b53471b03ea43021ddc50e7923fbb9f5023c` |
| `third_party/h265/LICENSE` | `a53831ee9730340d31a911148e69fdd15cc7d1c408b06f3a923b170c4578634d` |
| `third_party/oxideav-h265/LICENSE` | `4ecae6b086e0d2663c8629e7d3d7ab7d8b39958e8853f9e1371159499a0c3bf2` |
| `third_party/kvazaar/LICENSE` | `3c1dc3d7f8a3d08c14f4fbe9942f45764d8a21a3296e8d83446f33fd65f21c38` |
| `third_party/openh264/LICENSE` | `dd5c1c9668512530fa5a96e4c29ac4033d70a7eeb0eed7a42fddb6dd794ebdbb` |
| `third_party/minimp3/LICENSE` | `6a1ee543e5282cd9061881edf462e6fdab181f328da71fc2c9a6950a80e94d01` |
| `third_party/PDMP3/README.md` | `0e8c478e76ca79b445c2a6bcfa314b1768b61d8919504f55098cda690e985721` |
| `third_party/dr_libs/LICENSE` | `dd1c647e6f767f8ff4b2dfae0fed314726600a01e0cf1ef556afddd5fa96ff15` |
| `third_party/edge264/LICENSE_BSD.txt` | `3566842dee53b6a1457f334185060793286bb567fd0510889de8ca8303aa4167` |
| `third_party/hevc.js/LICENSE` | `9b3c1a02861d51028709ff474e32154ab9d759494f6072c1eb30a17adb80c975` |
| `third_party/glint/LICENSE` | `ab08fb7ec4a030bd27a9a0d1fb60a39b832f7779fb11d0f2753e85593f6f944e` |
| `third_party/alac/LICENSE` | `a337314dd82d26791112c1e5a85725b2eb92f5b7e6f9102fa4eaa2903f77518f` |
| `third_party/ffmpeg/LICENSE.md` | `2e1d16c72fd74e12063776371da757322f8b77589386532f4fd8634bde7de1af` |
| `third_party/ffmpeg/COPYING.LGPLv2.1` | `246041b6ecf9bc32d718a62c57877c78b5eb397b6467e74ed7ae2626ab189c30` |
| `third_party/libvpx/LICENSE` | `8267348d5af1262c11d1a08de2f5afc77457755f1ac658627dd9acf71011d615` |
| `third_party/libvpx/PATENTS` | `cc3273e0694ea5896145e0677699b53471b03ea43021ddc50e7923fbb9f5023c` |
