# BMP

Windows bitmaps to RGBA8, decoded by stb_image's rules, the suite's
reference:
- **Headers:** OS/2 12-byte and Windows 40, 56, 108 and 124-byte.
- **Pixels:** 1, 4 and 8-bit palettes; 24-bit; 16 and 32-bit with the default or
  `BI_BITFIELDS` masks, each channel scaled to 8 bits by bit replication. An
  alpha channel that is zero everywhere is taken as opaque.
- **Refused, as stb refuses them:** RLE and embedded JPEG/PNG.

Odin's `core:image/bmp` returns three channels whatever the file holds, so
it isn't used.

```odin
import bmp "../bmp"

pixels, width, height, err := bmp.decode(data)   // RGBA8, top-down; delete(pixels)
info, e := bmp.info(data)                         // width, height, has_alpha
```

`tests/image_check.sh` compares every BMP variant ImageMagick writes with
stb_image: all identical. `odin test bmp` covers top-down rows and the OS/2
header.
