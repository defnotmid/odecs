// The suite's one image path: the format from the first bytes, decoded to
// RGBA8 straight alpha, rows top-down, the bytes as stored (no gamma or
// colour profile applied, no EXIF orientation), as stb_image gives them; JPEG
// as libjpeg-turbo decodes it. PNG, TGA and QOI go through Odin's core:image;
// BMP, WebP, JPEG and GIF through odecs' own decoders (core:image's BMP drops
// alpha). Radiance HDR decodes to linear f32 through decode_float_into.
// Writing is PNG (png/encoder).
package odecs_image

import bmp "./bmp"
import common "../common"
import gif "./gif"
import hdr "./hdr"
import jpeg "./jpeg"
import png_encoder "./png/encoder"
import webp "./webp"
import "base:intrinsics"
import "base:runtime"
import core_image "core:image"
@(require) import "core:image/png"
@(require) import "core:image/qoi"
@(require) import "core:image/tga"

Format :: enum {
	Unknown,
	PNG,
	JPEG,
	GIF,
	BMP,
	TGA,
	QOI,
	WebP,
	HDR, // Radiance RGBE: decode_float_into
}

Error :: enum {
	None,
	Unsupported, // not an image this package decodes
	Invalid,     // malformed or truncated
	Out_Of_Memory,
}

Info :: struct {
	width, height: int,
	has_alpha:     bool, // the file stores alpha (a missing alpha decodes as 255)
	animated:      bool, // decode returns the first frame
	format:        Format,
}

// Tightly packed RGBA8 pixels, straight alpha, top-down rows.
Image :: struct {
	width, height: int,
	pixels:        []u8,
}

// The format from the file's first bytes, not its name.
format_of :: proc(data: []u8) -> Format {
	starts :: #force_inline proc(data: []u8, magic: string) -> bool {return len(data) >= len(magic) && string(data[:len(magic)]) == magic}
	switch {
	case starts(data, "\x89PNG\r\n\x1a\n"):
		return .PNG
	case starts(data, "\xff\xd8\xff"):
		return .JPEG
	case starts(data, "GIF87a") || starts(data, "GIF89a"):
		return .GIF
	case starts(data, "BM"):
		return .BMP
	case starts(data, "qoif"):
		return .QOI
	case len(data) >= 12 && starts(data, "RIFF") && string(data[8:12]) == "WEBP":
		return .WebP
	case starts(data, "#?RADIANCE\n") || starts(data, "#?RGBE\n"):
		return .HDR
	}
	// TGA has no magic; core:image recognises it from its header.
	if core_image.which_bytes(data) == .TGA do return .TGA
	return .Unknown
}

info :: proc(data: []u8) -> (i: Info, err: Error) {
	i.format = format_of(data)
	switch i.format {
	case .Unknown:
		return i, .Unsupported
	case .JPEG:
		ft, e := jpeg.get_features(data)
		if e != .None do return i, e == .Unsupported ? .Unsupported : .Invalid
		i.width, i.height = ft.width, ft.height
	case .GIF:
		ft, e := gif.get_features(data)
		if e != .None do return i, .Invalid
		i.width, i.height, i.has_alpha, i.animated = ft.width, ft.height, ft.has_alpha, ft.animated
	case .WebP:
		ft, e := webp.get_features(data)
		if e != .None do return i, .Invalid
		i.width, i.height, i.has_alpha, i.animated = ft.width, ft.height, ft.has_alpha, ft.animated
	case .BMP:
		b, e := bmp.info(data)
		if e != .None do return i, e == .Unsupported ? .Unsupported : .Invalid
		i.width, i.height, i.has_alpha = b.width, b.height, b.has_alpha
	case .HDR:
		h, e := hdr.info(data)
		if e != .None do return i, hdr_error(e)
		i.width, i.height = h.width, h.height
	case .PNG, .TGA, .QOI:
		img, e := core_image.load_from_bytes(data, {.info}, runtime.heap_allocator())
		defer if e == nil || i.format != .TGA do core_image.destroy(img, runtime.heap_allocator()) // see decode_core
		if e != nil do return i, .Invalid
		i.width, i.height, i.has_alpha = img.width, img.height, img.channels == 2 || img.channels == 4
	}
	return
}

// Decodes the image (an animation's first frame) to RGBA8 straight alpha,
// allocated with `allocator`; free it with destroy_image. HDR is float:
// decode_float_into.
decode :: proc(data: []u8, pool: ^common.Work_Pool = nil, allocator := context.allocator) -> (img: Image, err: Error) {
	i := info(data) or_return
	if i.format == .HDR do return img, .Unsupported
	pixels, aerr := make([]u8, i.width * i.height * 4, allocator)
	if aerr != nil do return img, .Out_Of_Memory
	if err = decode_into(data, pixels, pool); err != .None {
		delete(pixels, allocator)
		return {}, err
	}
	return {i.width, i.height, pixels}, .None
}

// Decodes into `pixels`, width * height * 4 bytes the caller owns (sized
// from info). Scratch comes from `allocator` and is freed before returning.
decode_into :: proc(data: []u8, pixels: []u8, pool: ^common.Work_Pool = nil, allocator := context.allocator) -> Error {
	switch format := format_of(data); format {
	case .Unknown:
		return .Unsupported
	case .JPEG:
		return codec_error(jpeg.decode_into(data, pixels, allocator))
	case .GIF:
		return codec_error(gif.decode_into(data, pixels))
	case .WebP:
		return codec_error(webp.decode_into(data, pixels, pool, allocator))
	case .BMP:
		return codec_error(bmp.decode_into(data, pixels))
	case .HDR:
		return .Unsupported // decode_float_into
	case .PNG, .TGA, .QOI:
		return decode_core(data, format, pixels)
	}
	return .Unsupported
}

// Decodes a Radiance HDR image into `pixels`, width * height * 4 floats the
// caller owns (sized from info): linear RGBA, alpha 1, rows top-down, as
// stb_image's stbi_loadf gives them. The other formats are 8-bit and decode
// with decode_into.
decode_float_into :: proc(data: []u8, pixels: []f32) -> Error {
	if format_of(data) != .HDR do return .Unsupported
	return hdr_error(hdr.decode_into(data, pixels))
}

@(private)
hdr_error :: proc(e: hdr.Error) -> Error {
	switch e {
	case .None:
		return .None
	case .Unsupported:
		return .Unsupported
	case .Invalid:
	}
	return .Invalid
}

// A codec's error: each names its own Unsupported, Out_Of_Memory, and
// Invalid (or its kinds of invalid).
@(private)
codec_error :: proc(e: $E) -> Error where intrinsics.type_is_enum(E) {
	#partial switch e {
	case .None:
		return .None
	case .Unsupported:
		return .Unsupported
	case .Out_Of_Memory:
		return .Out_Of_Memory
	}
	return .Invalid
}

destroy_image :: proc(img: ^Image, allocator := context.allocator) {
	delete(img.pixels, allocator)
	img^ = {}
}

// PNG writing, for the suite's frames, snapshots and exports.
encode_png :: png_encoder.encode
write_png :: png_encoder.write_file

// core:image's pixels to RGBA8 as stb_image gives them: gray replicated into
// R, G and B, a missing alpha as 255, 16-bit samples as their high byte.
// On failure core:image's PNG and QOI loaders return the half-built image for
// the caller to free; TGA has freed it already and returns the pointer anyway.
@(private)
decode_core :: proc(data: []u8, format: Format, pixels: []u8) -> Error {
	// core:image's buffers are scratch: on the heap and freed here, so the
	// caller's memory holds only the result.
	scratch := runtime.heap_allocator()
	src, e := core_image.load_from_bytes(data, {}, scratch)
	defer if e == nil || format != .TGA do core_image.destroy(src, scratch)
	if e != nil do return .Invalid
	n := src.width * src.height
	ch := src.channels
	if ch < 1 || ch > 4 || src.depth != 8 && src.depth != 16 || len(src.pixels.buf) < n * ch * src.depth / 8 do return .Invalid
	if len(pixels) < n * 4 do return .Invalid
	if src.depth == 8 {
		convert_samples(pixels[:n * 4], src.pixels.buf[:n * ch], ch)
	} else {
		convert_samples(pixels[:n * 4], (transmute([]u16)src.pixels.buf[:])[:n * ch], ch)
	}
	return .None
}

@(private)
convert_samples :: proc(dst: []u8, src: []$S, channels: int) #no_bounds_check {
	byte_of :: #force_inline proc "contextless" (v: S) -> u8 {
		when S == u16 {return u8(v >> 8)} else {return u8(v)}
	}
	// The layout is fixed for the image: one loop per channel count.
	out := ([^][4]u8)(raw_data(dst))[:len(dst) / 4]
	switch channels {
	case 1:
		for &p, i in out {v := byte_of(src[i]); p = {v, v, v, 255}}
	case 2:
		for &p, i in out {v := byte_of(src[i * 2]); p = {v, v, v, byte_of(src[i * 2 + 1])}}
	case 3:
		for &p, i in out do p = {byte_of(src[i * 3]), byte_of(src[i * 3 + 1]), byte_of(src[i * 3 + 2]), 255}
	case:
		for &p, i in out do p = {byte_of(src[i * 4]), byte_of(src[i * 4 + 1]), byte_of(src[i * 4 + 2]), byte_of(src[i * 4 + 3])}
	}
}
