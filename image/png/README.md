# PNG

Native PNG writing: tightly packed top-down RGBA8 pixels become an RGBA PNG
with every row Paeth-filtered and the zlib stream deflated as runs of the
previous byte (`deflate.odin`, like zlib's `Z_RLE` strategy, one dynamic
Huffman block per 32768 symbols), written as IDAT chunks of about 256 KiB.
Rendered frames compress well this way and encode several times faster than
stb_image_write. Decoding PNG goes through Odin's `core:image`; the package is
`png_encoder` so a program can import both.

```odin
import png "../png/encoder"

data, err := png.encode(pixels, width, height)   // the file's bytes; delete when done
err = png.write_file("frame.png", pixels, width, height)
```

`pixels` holds at least `width * height * 4` bytes; anything else returns
`Invalid_Argument`.

## Verification

- Moved from ovg (`image_io.odin` and `deflate.odin`) unchanged: on the
  1080p and 11158×2156 WebP decodes, a flat rendered frame and random RGBA,
  its output is byte-identical to ovg's `encode_png` at the same speed
  (20.8 ms for 1920×1080, 482 ms for 11158×2156 on one Ryzen 9 9900X3D core).
- `odin test image/png/encoder`: encodes of several sizes decode through
  `core:image/png` to the same pixels.
