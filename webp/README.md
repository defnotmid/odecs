# WebP

WebP decoding (RFC 9649) from memory to RGBA8 with straight alpha:
- lossy images (VP8 key frames, RFC 6386);
- lossless images (VP8L);
- alpha (ALPH, raw or lossless-compressed, with its three filters);
- the extended format (VP8X);
- animation (ANIM/ANMF), composited frame by frame.

```odin
import webp "../webp"

img, err := webp.decode(data)            // a still image, or an animation's first frame
defer webp.destroy_image(&img)           // img.pixels: width * height * 4, RGBA
ft, _ := webp.get_features(data)         // size, alpha, animated, frame and loop counts

a: webp.Animation
webp.init_animation(&a, data) or_return
defer webp.destroy_animation(&a)
for _ in 0 ..< a.features.frame_count {
	frame := webp.next_frame(&a) or_return // frame.pixels: the whole canvas; frame.start, frame.duration (ms)
}

// Lossy images as decoded, for conversion on the GPU (like movie.Reader's
// planar output): 4:2:0 planes sized to whole macroblocks, and alpha.
yuv, alpha, e := webp.decode_yuva(data)
```

`decode` and `init_animation` take an optional `^common.Work_Pool`. The
conversion of lossy images to RGBA runs on it, row by row.

## Scope

- **Every coding tool of both bitstreams:**
  - lossy: segments, the simple and normal loop filters and their sharpness, multiple token partitions, and every intra mode;
  - lossless: all four transforms (predictor, cross-colour, subtract-green, colour indexing with pixel packing), colour caches up to 11 bits, and meta prefix codes per block.
- **Colour:** RGB is BT.601 studio range with libwebp's fixed-point constants, and chroma is upsampled with libwebp's "fancy" 9-3-3-1 filter. Output is identical to `dwebp`'s.
- **Animation:**
  - frames overwrite or alpha-blend (libwebp's integer non-premultiplied blend) and dispose to transparent;
  - the canvas starts transparent, and `ANIM`'s background colour is reported (`Features.background`) but not painted, as libwebp does.
- **Not read:** ICC profiles (sRGB is assumed), EXIF and XMP. Raw VP8/VP8L bitstreams without the RIFF container are not accepted.
- **Damaged input:**
  - a truncated lossy partition decodes as zeros, as a damaged frame would;
  - a truncated lossless stream is refused (`.Invalid`).

## Layout

- **VP8:** macroblocks are predicted and reconstructed in a small bordered workspace. The loop filter then runs over the whole frame: each edge is 16 lanes, each with the 8 pixels across it, computed branch-free so the compiler vectorizes it. Vertical edges use one transposed copy of the macroblock.
- **VP8L:**
  - prefix codes decode through 8-bit root tables stored flat, one offset per code;
  - groups whose red, blue and alpha codes have a single symbol skip those reads;
  - groups whose codes are all short decode a whole pixel with one 6-bit lookup;
  - predictors run per block run, the per-channel ones on `#simd[4]i16` lanes.
- **Colour conversion:** 16 pixels at a time in 16-bit lanes.
- **Tables:** `tables.odin` is generated from libwebp by [`tools/tables`](../tools/tables/README.md).

## Verification

`bash tests/webp_check.sh`, with fixtures from `bash tests/webp_fixtures.sh`. The fixture script:
- fetches libwebp's test corpus at a pinned commit;
- builds libwebp's tools from `third_party/libwebp`;
- writes `dwebp`'s decodes of every file;
- encodes animations from FFmpeg frames.

The gate checks:
- **All 131 corpus files** (88 lossy, among them the 61 VP8 conformance streams; 43 lossless): RGBA identical to `dwebp -pam`, and for lossy files the Y, U, V and alpha planes identical to `dwebp -pgm`. This covers odd sizes (1×1, 13×1), every alpha filter and compression method, and an 11158×2156 lossy image.
- **The 11158×2156 lossy image on 8 threads:** identical.
- **Animations** (lossless, lossy, mixed, opaque, and one that blends semi-transparent frames over a frame disposed to transparent): every canvas identical to `anim_dump`'s. `anim_dump` writes fully transparent pixels as transparent black, so ours are compared the same way.
- **Fuzzing:** 3,000 rounds of mutated and truncated files through every entry point, under AddressSanitizer with leak checking.

Speed against libwebp 1.6.0 (`WebPDecodeRGBA`, `-O3`, its SSE2/SSE4.1/AVX2 code), on one core, over the corpus:

| | Ours | libwebp |
| --- | --- | --- |
| 43 lossless files | 60.7 ms | 54.8 ms (ours faster on 34) |
| 88 lossy files | 276 ms | 201 ms |
| 11158×2156 lossy | 223 ms | 162 ms |
| 2048×2048 lossless, random alpha | 55 ms | 48 ms |

Lossy decoding is bound by the boolean entropy decoder, as libwebp's scalar
code is. Most of the remaining gap is libwebp's SIMD inverse transforms and
predictors.
