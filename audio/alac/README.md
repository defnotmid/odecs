# ALAC (Apple Lossless)

Native Odin Apple Lossless decoding, restructured from Apple's reference ALAC
decoder ([`LICENSE-alac.txt`](LICENSE-alac.txt), Apache-2.0). The package
imports only Odin `base`/`core`.

```odin
import alac "../alac"

cfg, err := alac.parse_config(magic_cookie)
d: alac.Decoder
err = alac.init_decoder(&d, cfg)
f, de := alac.decode_frame(&d, packet_bytes) // f.planes[c][:f.samples]
alac.interleave(f, pcm)                      // pcm: []f32 or []i16; optional leading-channel count; or the i32 planes
alac.destroy_decoder(&d)
```

- **Scope:** 16, 20, 24 and 32 bits per sample, 1 to 8 channels, compressed
  frames (adaptive Golomb-Rice entropy coding, dynamic FIR linear prediction
  with unrolled order-4 and order-8 fast paths, shifted LSBs, lossless mid/side
  stereo matrixing) and uncompressed escape frames, partial frame lengths, and
  DSE/FIL elements.
- **Data-oriented layout:** every channel decodes directly into its own planar
  `i32` buffer (`Frame.planes[c][:f.samples]`) in standard WAV/SMPTE channel
  order (`L, R, C, LFE, ...`), with no intermediate packed-byte conversions.
- **Containers:** [`mp4`](../../container/mp4/README.md) reads the
  `alac` sample entry and magic cookie; [`media`](../../media/README.md)
  exposes codec `.ALAC`; [`video`](../../video/README.md) plays `.m4a` and
  `.mov`/`.mp4` files with ALAC tracks.

```sh
odin test audio/alac
```
