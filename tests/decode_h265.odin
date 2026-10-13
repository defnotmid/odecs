package main

import h265 "../codec/h265/decoder"
import "core:fmt"
import "core:os"

// decode_h265 <in.265> <out.yuv>
//
// Decodes an Annex-B HEVC stream and writes the visible 4:2:0 frames in
// display order. Stage 3 understands intra pictures only.
main :: proc() {
	if len(os.args) < 3 {
		fmt.eprintln("usage: decode_h265 <in.265> <out.yuv>")
		os.exit(2)
	}

	data, err := os.read_entire_file(os.args[1], context.allocator)
	if err != nil {
		fmt.eprintln("cannot read", os.args[1])
		os.exit(1)
	}
	defer delete(data)

	pics, ok := h265.decode_annex_b(data)
	if !ok {
		fmt.eprintln("decode failed")
		os.exit(1)
	}

	out := make([dynamic]u8, 0, 4 * 1024 * 1024)
	defer delete(out)

	count := len(pics)

	for p in pics {
		h265.append_picture_display(p, &out)
		h265.destroy_picture(p)
		free(p)
	}
	delete(pics)

	if os.write_entire_file(os.args[2], out[:]) != nil {
		fmt.eprintln("cannot write output")
		os.exit(1)
	}

	fmt.printfln("%d frames, %d bytes", count, len(out))
}
