package png_encoder

import "core:encoding/endian"
import "core:hash"
import "core:os"

Error :: enum {
	None,
	Invalid_Argument, // no pixels, or fewer than width * height * 4 bytes
	IO_Error,
	Out_Of_Memory,
}

// Writes tightly packed top-down RGBA8 pixels as a PNG file: every row
// Paeth-filtered, deflated as runs of the previous byte (deflate.odin; on
// rendered frames several times faster than stb_image_write and smaller),
// streamed out as IDAT chunks of about PNG_CHUNK bytes.
write_file :: proc(path: string, pixels: []u8, width, height: int) -> Error {
	if !valid(pixels, width, height) do return .Invalid_Argument
	f, ferr := os.create(path)
	if ferr != nil do return .IO_Error
	defer os.close(f)
	return write(pixels, width, height, f, proc(f: rawptr, data: []u8) -> bool {
		_, err := os.write((^os.File)(f), data)
		return err == nil
	})
}

// write_file's encoding into memory: the PNG file's bytes.
encode :: proc(pixels: []u8, width, height: int, allocator := context.allocator) -> ([]u8, Error) {
	if !valid(pixels, width, height) do return nil, .Invalid_Argument
	out := make([dynamic]u8, allocator)
	err := write(pixels, width, height, &out, proc(out: rawptr, data: []u8) -> bool {
		_, err := append((^[dynamic]u8)(out), ..data)
		return err == nil
	})
	if err != .None {
		delete(out)
		return nil, .Out_Of_Memory
	}
	return out[:], .None
}

@(private)
valid :: proc(pixels: []u8, width, height: int) -> bool {
	return width > 0 && height > 0 && width <= int(max(u32)) && height <= int(max(u32)) && len(pixels) >= width * height * 4
}

@(private)
write :: proc(pixels: []u8, width, height: int, ctx: rawptr, sink: proc(ctx: rawptr, data: []u8) -> bool) -> Error {
	stride := width * 4
	ok := sink(ctx, {0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'})
	head: [8 + 13 + 4]u8
	ihdr := head[8:]
	endian.put_u32(ihdr[0:4], .Big, u32(width))
	endian.put_u32(ihdr[4:8], .Big, u32(height))
	copy(ihdr[8:13], []u8{8, 6, 0, 0, 0}) // 8 bits, RGBA, deflate, adaptive filtering, no interlace
	ok &&= chunk(head[:], "IHDR", ctx, sink)

	// The compressed stream builds up behind room for a chunk header, so
	// each IDAT goes out in place.
	z: Deflate
	deflate_init(&z, 8)
	defer deflate_destroy(&z)
	rows := make([]u8, stride * 2 + 1)
	defer delete(rows)
	zero, row := rows[:stride], rows[stride:]
	for y in 0 ..< height {
		cur := pixels[y * stride:][:stride]
		prev := y > 0 ? pixels[(y - 1) * stride:][:stride] : zero
		filter_paeth(row, cur, prev)
		deflate_write(&z, row)
		if len(z.out) - 8 >= CHUNK && ok {
			ok &&= idat(&z, ctx, sink)
		}
	}
	deflate_finish(&z)
	ok &&= idat(&z, ctx, sink)
	iend: [12]u8
	ok &&= chunk(iend[:], "IEND", ctx, sink)
	return ok ? .None : .IO_Error
}

// Sends `data`: its contents sit between 8 bytes of room for the length and
// type and 4 for the CRC, which are filled in here.
@(private = "file")
chunk :: proc(data: []u8, type: string, ctx: rawptr, sink: proc(ctx: rawptr, data: []u8) -> bool) -> bool {
	n := len(data) - 12
	endian.put_u32(data[0:4], .Big, u32(n))
	copy(data[4:8], type)
	endian.put_u32(data[8 + n:][:4], .Big, hash.crc32(data[4:8 + n]))
	return sink(ctx, data)
}

@(private = "file")
idat :: proc(z: ^Deflate, ctx: rawptr, sink: proc(ctx: rawptr, data: []u8) -> bool) -> bool {
	resize(&z.out, len(z.out) + 4)
	ok := chunk(z.out[:], "IDAT", ctx, sink)
	resize(&z.out, 8)
	return ok
}

@(private)
CHUNK :: 1 << 18

// PNG filter type 4: each byte minus whichever of left, up and up-left is
// nearest to left + up - up-left.
@(private)
filter_paeth :: proc "contextless" (dst, cur, prev: []u8) {
	dst[0] = 4
	for i in 0 ..< 4 {
		dst[1 + i] = cur[i] - prev[i]
	}
	for i in 4 ..< len(cur) {
		a, b, c := i32(cur[i - 4]), i32(prev[i]), i32(prev[i - 4])
		pa, pb, pc := abs(b - c), abs(a - c), abs(a + b - 2 * c)
		p := pa <= pb && pa <= pc ? a : pb <= pc ? b : c
		dst[1 + i] = cur[i] - u8(p)
	}
}
