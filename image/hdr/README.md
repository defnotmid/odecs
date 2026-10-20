# HDR

Radiance RGBE (`.hdr`) to linear RGBA `f32`, alpha 1, rows top-down, as
stb_image's `stbi_loadf` reads it, the suite's reference:
- **Header:** the `#?RADIANCE` or `#?RGBE` signature, `FORMAT=32-bit_rle_rgbe`
  and the standard `-Y height +X width` orientation. Other header lines
  (`EXPOSURE`, `GAMMA`, comments) are ignored, as stb ignores them.
- **Scanlines:** RLE (widths 8 to 32767) and flat, decided per scanline.
- **Samples:** each mantissa times 2^(exponent − 136). `f32` holds every RGBE
  value exactly, so the decode is lossless. An exponent of 0 is black.
- **Refused, as stb refuses them:** XYZE, a missing `FORMAT` line and the other
  seven orientations. Old-style RLE (repeat counts in `1, 1, 1` pixels) is
  read as pixels, as stb and most readers do.

RLE scanlines expand into the last quarter of their own output row, which
the conversion then overwrites from the front. So the decode allocates
nothing: the caller's buffer is the only memory it touches. `info` refuses a
file too short for the size it claims, before a caller sizes anything from it.

```odin
import hdr "../hdr"

i, err := hdr.info(data)                      // width, height
pixels := make([]f32, i.width * i.height * 4)
err = hdr.decode_into(data, pixels)           // RGBA, linear, alpha 1
```

Through the facade, `image.info` reports `.HDR` and `image.decode_float_into`
decodes it. The 8-bit `decode` and `decode_into` refuse HDR rather than tone
map it.

`tests/image_check.sh` compares ImageMagick's and ffmpeg's `.hdr` files (RLE
and flat, narrow and 32768 wide, and the `#?RGBE` signature) with
`stbi_loadf`: all are bit-identical, and the decode is 2 to 10 times faster.
`odin test image/hdr` covers both scanline kinds, every exponent and the
refusals.
