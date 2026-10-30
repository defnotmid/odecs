# GIF

GIF87a/89a to RGBA8. The stream is parsed once into frame records (rectangle,
colour table, graphic control extension, where the LZW data starts). Decoding
a frame turns LZW codes into colour indices, then indices into pixels on a
canvas.

The LZW decoder keeps no string tables. A new entry is the previous code's
string plus one byte, and those bytes already lie together in the output, so
an entry is just an offset and a length, and decoding copies from earlier
output, as LZ77 does. Interlaced frames are decoded in stream order, and their
rows are put in display order afterwards.

```odin
import gif "../gif"

img, err := gif.decode(data)          // the first frame, RGBA8; gif.destroy_image(&img)
ft, e := gif.get_features(data)       // width, height, has_alpha, animated, frame_count, loop_count

a: gif.Animation
gif.init_animation(&a, data) or_return
defer gif.destroy_animation(&a)
for _ in 0 ..< a.frame_count {
	frame := gif.next_frame(&a) or_return // frame.pixels: the canvas, until the next call; start, duration in ms
}
```

- **`decode`:** the first frame as stb_image gives it, the suite's reference.
  Where the frame doesn't reach and the background index is above zero, the
  background colour is filled in. stb swaps red and blue there; oicut writes
  the colour from the table.
- **`Animation`:** frames composited as browsers show them. The canvas starts
  transparent. A Background disposal clears the frame's rectangle to
  transparent, and Previous restores what the frame covered. The background
  colour is ignored, as Chromium and Firefox ignore it. stb's animation path
  is not a reference: its dispose-3 reads before its buffer.

`tests/image_check.sh` runs these checks:
- every GIF fixture's first frame against stb_image: identical;
- every animation frame against Chromium's `ImageDecoder` (each disposal on
  partial transparent frames, local and global tables): identical;
- a fuzz pass under AddressSanitizer.

Speed on a 1080p 256-colour frame against stb_image is in
[BENCHMARKS.md](../../BENCHMARKS.md) (`bash tests/compare.sh run decode/stb`).
`odin test gif` covers each disposal, interlacing, a code table growing to
10 bits, and every truncation of a file.
