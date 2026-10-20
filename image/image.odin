// The suite's one image path: the format from the first bytes, decoded to
// RGBA8 straight alpha, rows top-down, the bytes as stored (no gamma or
// colour profile applied, no EXIF orientation), as stb_image gives them; JPEG
// as libjpeg-turbo decodes it. PNG, TGA and QOI go through Odin's core:image;
// BMP, WebP, JPEG and GIF through odecs' own decoders (core:image's BMP drops
// alpha).
// Writing is PNG (png/encoder).
package odecs_image

import bmp "../bmp"
import common "../common"
import gif "../gif"
import jpeg "../jpeg"
import png_encoder "../png/encoder"
import webp "../webp"
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
	case .PNG, .TGA, .QOI:
		img, e := core_image.load_from_bytes(data, {.info})
		defer if e == nil || i.format != .TGA do core_image.destroy(img) // see decode_core
		if e != nil do return i, .Invalid
		i.width, i.height, i.has_alpha = img.width, img.height, img.channels == 2 || img.channels == 4
	}
	return
}

// Decodes the image (an animation's first frame) to RGBA8 straight alpha,
// allocated with `allocator`; free it with destroy_image.
decode :: proc(data: []u8, pool: ^common.Work_Pool = nil, allocator := context.allocator) -> (img: Image, err: Error) {
	switch format := format_of(data); format {
	case .Unknown:
		return img, .Unsupported
	case .JPEG:
		j, e := jpeg.decode(data, allocator)
		switch e {
		case .None:
			return {j.width, j.height, j.pixels}, .None
		case .Unsupported:
			return img, .Unsupported
		case .Out_Of_Memory:
			return img, .Out_Of_Memory
		case .Invalid:
		}
		return img, .Invalid
	case .GIF:
		g, e := gif.decode(data, allocator)
		if e != .None do return img, e == .Out_Of_Memory ? .Out_Of_Memory : .Invalid
		return {g.width, g.height, g.pixels}, .None
	case .WebP:
		w, e := webp.decode(data, pool, allocator)
		if e != .None do return img, .Invalid
		return {w.width, w.height, w.pixels}, .None
	case .BMP:
		pixels, w, h, e := bmp.decode(data, allocator)
		switch e {
		case .None:
			return {w, h, pixels}, .None
		case .Unsupported:
			return img, .Unsupported
		case .Out_Of_Memory:
			return img, .Out_Of_Memory
		case .Invalid:
		}
		return img, .Invalid
	case .PNG, .TGA, .QOI:
		return decode_core(data, format, allocator)
	}
	return img, .Unsupported
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
decode_core :: proc(data: []u8, format: Format, allocator := context.allocator) -> (img: Image, err: Error) {
	src, e := core_image.load_from_bytes(data, {}, allocator)
	defer if e == nil || format != .TGA do core_image.destroy(src, allocator)
	if e != nil do return img, .Invalid
	n := src.width * src.height
	ch := src.channels
	if ch < 1 || ch > 4 || src.depth != 8 && src.depth != 16 || len(src.pixels.buf) < n * ch * src.depth / 8 do return img, .Invalid
	pixels, aerr := make([]u8, n * 4, allocator)
	if aerr != nil do return img, .Out_Of_Memory
	if src.depth == 8 {
		convert_samples(pixels, src.pixels.buf[:n * ch], ch)
	} else {
		convert_samples(pixels, (transmute([]u16)src.pixels.buf[:])[:n * ch], ch)
	}
	return {src.width, src.height, pixels}, .None
}

@(private)
convert_samples :: proc(dst: []u8, src: []$S, channels: int) #no_bounds_check {
	byte_of :: #force_inline proc "contextless" (v: S) -> u8 {
		when S == u16 {return u8(v >> 8)} else {return u8(v)}
	}
	for i in 0 ..< len(dst) / 4 {
		s := src[i * channels:]
		r, g, b, a: u8
		switch channels {
		case 1:
			r = byte_of(s[0]); g, b, a = r, r, 255
		case 2:
			r = byte_of(s[0]); g, b, a = r, r, byte_of(s[1])
		case 3:
			r, g, b, a = byte_of(s[0]), byte_of(s[1]), byte_of(s[2]), 255
		case:
			r, g, b, a = byte_of(s[0]), byte_of(s[1]), byte_of(s[2]), byte_of(s[3])
		}
		dst[i * 4], dst[i * 4 + 1], dst[i * 4 + 2], dst[i * 4 + 3] = r, g, b, a
	}
}
