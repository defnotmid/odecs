package png_encoder

import "core:bytes"
import "core:image"
import core_png "core:image/png"
import "core:testing"

@(test)
encode_round_trips_through_core_image :: proc(t: ^testing.T) {
	for size in ([][2]int{{1, 1}, {3, 2}, {67, 41}, {640, 9}}) {
		w, h := size[0], size[1]
		pixels := make([]u8, w * h * 4)
		defer delete(pixels)
		s := u32(w * 31 + h)
		for &v, i in pixels {s = s * 1664525 + 1013904223; v = i % 7 < 3 ? u8(s >> 24) : u8(i / 9)}
		data, err := encode(pixels, w, h)
		defer delete(data)
		testing.expect_value(t, err, Error.None)
		img, derr := core_png.load_from_bytes(data, {.alpha_add_if_missing})
		testing.expect_value(t, derr, nil)
		if derr != nil do continue
		defer image.destroy(img)
		testing.expect_value(t, img.width, w)
		testing.expect_value(t, img.height, h)
		testing.expect_value(t, img.channels, 4)
		testing.expect(t, bytes.equal(img.pixels.buf[:], pixels), "decoded pixels differ")
	}
	_, err := encode(nil, 1, 1)
	testing.expect_value(t, err, Error.Invalid_Argument)
}
