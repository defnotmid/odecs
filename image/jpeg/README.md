# JPEG

Baseline and progressive JPEG (8-bit, Huffman-coded, 1, 3 or 4 components) to
RGBA8. The output is exactly what libjpeg-turbo produces at its defaults:
- its default integer IDCT (Loeffler, Ligtenberg and Moschytz, 13-bit
  constants);
- "fancy" triangle upsampling for 2x ratios, with libjpeg's alternating
  rounding, and repeated samples for other whole ratios;
- its YCbCr constants;
- its choice of colour space from JFIF, the Adobe transform and the component
  IDs.

CMYK and YCCK become RGB as Adobe files store them (inverted): R = C × K / 255,
rounded.

```odin
import jpeg "../jpeg"

img, err := jpeg.decode(data)                 // RGBA8, alpha 255; jpeg.destroy_image(&img)
ft, e := jpeg.get_features(data)              // width, height, components, progressive
err = jpeg.decode_into(data, pixels)          // into width * height * 4 bytes you own
```

## Data layout

Samples live only as long as their rows are needed. Each component keeps a
ring of three bands, each one MCU row high: the band being converted and its
neighbours above and below, which fancy upsampling reads. For 1080p 4:2:0
that is about 140 KB instead of 3 MB of planes.

- **Single-scan images** stream: band m is decoded (Huffman, then each
  block's IDCT into the ring), then band m − 1 is converted to RGBA while
  still in cache.
- **Multi-scan images** (progressive, or one component per scan) keep every
  block's coefficients until the last scan, then make their bands by IDCT
  into the same ring and the same conversion.

The Huffman decoder reads through a 64-bit window. It takes eight bytes at a
time when none is 0xFF, and uses 9-bit lookup tables, which also resolve
small AC coefficients in one step. A scan's kind (sequential, DC or AC,
first or refining) is chosen once, so the block loop under it handles one
kind of block. The IDCT, the upsampling and the YCbCr conversion are
portable `#simd`:
- the IDCT runs eight columns, then eight rows, in 32-bit lanes, with
  dequantization folded in and a flat fill for DC-only blocks;
- upsampling and YCbCr each handle sixteen samples at a time.

## Not decoded

- **Arithmetic coding:** rare; stb_image refuses it too.
- **12-bit and lossless JPEG, and hierarchical files.**
- **A height given only by a DNL marker.**

These return `.Unsupported`.

libjpeg-turbo smooths the blocks of a progressive image whose scans stop
before refining the low AC coefficients. oicut does not, so such files
differ. Complete progressive files are identical.

## Verification

`tests/image_check.sh` fetches the pinned libjpeg-turbo, builds it into
`.work`, and runs `tests/jpeg_compare.odin` on each fixture. Every decodable
fixture is identical to libjpeg-turbo:
- baseline 4:2:0, 4:2:2, 4:4:4, 4:4:0 and 4:1:1;
- odd sizes, restart markers, optimized tables and quality 100;
- grayscale, RGB-named components, CMYK and YCCK;
- progressive, and progressive with restarts;
- libjpeg-turbo's own test images.

Against stb_image the same files are at least 58 dB PSNR. The fuzz pass
(AddressSanitizer) covers every fixture. `odin test jpeg`:
- checks an embedded baseline file and its progressive re-encoding against
  libjpeg-turbo's output;
- checks the SIMD IDCT against a scalar version of the same arithmetic;
- decodes every truncation of both files.

## Speed

1080p decode times on one core against libjpeg-turbo 3.1.2 with its SIMD
(AVX2), decoding into a reused buffer as `decode_into` does, with oicut built
for this machine (`-microarch:native`), for `x86-64-v3` (AVX2) and for any
x86-64, and against stb_image, are in [BENCHMARKS.md](../../BENCHMARKS.md)
(`bash tests/compare.sh run 'decode/(jpeg|stb)'`). Built for AVX2 only, the gap
to libjpeg-turbo is its hand-written 16-bit IDCT.
