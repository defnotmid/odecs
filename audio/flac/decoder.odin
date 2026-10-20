package flac

import "base:intrinsics"
import common "../../common"

// Frame decoding (section 9). Each subframe decodes into its channel's own
// plane, so channels stay planar (structure of arrays) from the bitstream to
// the final interleave. Arithmetic widths follow appendix A: residuals fit
// 32 bits; predictions use i32 accumulators only where the subframe depth,
// coefficient precision and order bound them to 32 bits, and i64 otherwise;
// a 32-bit stream's side channel needs 33 bits and decodes into an i64 plane.
// Integer overflow wraps in Odin, so out-of-spec input can only produce
// wrong samples, which the frame CRC-16 rejects.

Decoder :: struct {
	info:   Stream_Info, // for frame headers that defer to streaminfo
	planes: [MAX_CHANNELS][dynamic]i32,
	side:   [dynamic]i64, // the side subframe of 32-bit stereo
}

// A decoded frame: header.channels planes of header.block_size samples,
// borrowed until the next decode_frame.
Frame :: struct {
	header: Frame_Header,
	planes: [MAX_CHANNELS][]i32,
}

init_decoder :: proc(d: ^Decoder, info: Stream_Info) {
	d.info = info
}

destroy_decoder :: proc(d: ^Decoder) {
	for &p in d.planes do delete(p)
	delete(d.side)
	d^ = {}
}

// Decodes the frame at the start of data and returns the bytes it used.
decode_frame :: proc(d: ^Decoder, data: []u8) -> (f: Frame, used: int, err: Error) {
	h := parse_frame_header(data, d.info) or_return
	n := h.block_size
	for c in 0 ..< h.channels {
		if len(d.planes[c]) < n && resize(&d.planes[c], n) != nil do return f, 0, .Out_Of_Memory
		f.planes[c] = d.planes[c][:n]
	}
	wide_side := h.bits == 32 && h.assignment != .Independent
	if wide_side && len(d.side) < n && resize(&d.side, n) != nil do return f, 0, .Out_Of_Memory
	r := Bit_Reader {
		data = data[h.size:],
		left = (len(data) - h.size) * 8,
	}
	side := side_channel(h.assignment)
	for c in 0 ..< h.channels {
		if c == side {
			if wide_side {
				decode_subframe(&r, d.side[:n], h.bits + 1) or_return
			} else {
				decode_subframe(&r, f.planes[c], h.bits + 1) or_return
			}
		} else {
			decode_subframe(&r, f.planes[c], h.bits) or_return
		}
	}
	// Zero bits to the byte boundary, then the CRC-16 of the whole frame.
	end := h.size + len(r.data) - r.left / 8
	if end + 2 > len(data) || crc16(data[:end + 2]) != 0 do return f, 0, .Invalid_Data
	f.header = h
	if wide_side {
		restore_stereo(&f, d.side[:n])
	} else if side >= 0 {
		restore_stereo(&f, f.planes[side])
	}
	return f, end + 2, .None
}

// Interleaves a frame into out (at least block_size * kept channels values),
// keeping the first `channels` channels, or all of them for 0: as f32 in
// [-1, 1), sample / 2^(bits-1), which is exact for every depth, or as i16
// (common.scale_i16).
interleave :: proc {
	interleave_f32,
	interleave_i16,
}

interleave_f32 :: proc(f: Frame, out: []f32, channels := 0) {
	f := f
	common.interleave_i32_f32(f.planes[:common.kept_channels(f.header.channels, channels)], f.header.block_size, f.header.bits, out)
}

interleave_i16 :: proc(f: Frame, out: []i16, channels := 0) {
	f := f
	common.interleave_i32_i16(f.planes[:common.kept_channels(f.header.channels, channels)], f.header.block_size, f.header.bits, out)
}

// The coded side channel's index, or -1 for independent channels.
@(private)
side_channel :: proc(a: Channel_Assignment) -> int {
	switch a {
	case .Left_Side, .Mid_Side:
		return 1
	case .Side_Right:
		return 0
	case .Independent:
	}
	return -1
}

// Left and right from the coded pair (section 4.2), in i64: mid-side sums
// need one bit more than the side channel's 33.
@(private)
restore_stereo :: proc(f: ^Frame, side: []$S) #no_bounds_check {
	a, b := f.planes[0][:len(side)], f.planes[1][:len(side)]
	switch f.header.assignment {
	case .Left_Side:
		for s, i in side do b[i] = i32(i64(a[i]) - i64(s))
	case .Side_Right:
		for s, i in side do a[i] = i32(i64(s) + i64(b[i]))
	case .Mid_Side:
		for s, i in side {
			mid := i64(a[i]) << 1 | i64(s) & 1
			a[i], b[i] = i32((mid + i64(s)) >> 1), i32((mid - i64(s)) >> 1)
		}
	case .Independent:
	}
}

@(private)
decode_subframe :: proc(r: ^Bit_Reader, out: []$T, coded_depth: int) -> Error {
	header := read(r, 8)
	if header & 0x80 != 0 do return .Invalid_Data
	kind := int(header >> 1)
	wasted := 0
	if header & 1 != 0 {
		k := read_unary(r) + 1
		if k >= u64(coded_depth) do return .Invalid_Data
		wasted = int(k)
	}
	depth := coded_depth - wasted
	n := len(out)
	switch {
	case kind == 0:
		v := T(read_signed(r, depth))
		for &x in out do x = v
	case kind == 1:
		for &x in out do x = T(read_signed(r, depth))
	case kind >= 8 && kind <= 12:
		order := kind - 8
		if order > n do return .Invalid_Data
		for &x in out[:order] do x = T(read_signed(r, depth))
		decode_residual(r, out, order) or_return
		// Fixed order k sums 2^k samples' worth (table 26).
		if size_of(T) == 4 && depth + order <= 32 {
			restore_fixed(out, order, i32)
		} else {
			restore_fixed(out, order, i64)
		}
	case kind >= 32:
		order := kind - 31
		if order > n do return .Invalid_Data
		for &x in out[:order] do x = T(read_signed(r, depth))
		precision := int(read(r, 4)) + 1
		shift := read_signed(r, 5)
		if precision == 16 || shift < 0 do return .Invalid_Data // forbidden patterns
		coefficients: [32]i32
		for &c in coefficients[:order] do c = i32(read_signed(r, precision))
		decode_residual(r, out, order) or_return
		// Appendix A.3: depth + precision + ceil(log2(order)) bits.
		log2_order := order == 1 ? 0 : 64 - int(intrinsics.count_leading_zeros(u64(order - 1)))
		if size_of(T) == 4 && depth + precision + log2_order <= 32 {
			restore_lpc(out, coefficients[:order], uint(shift), i32, 1)
		} else {
			restore_lpc(out, coefficients[:order], uint(shift), i64, 1)
		}
	case:
		return .Invalid_Data // reserved subframe type
	}
	if r.left < 0 do return .Invalid_Data
	if wasted > 0 do for &x in out do x <<= uint(wasted)
	return .None
}

// Partitioned Rice residual (section 9.2.7) into out[order:].
@(private)
decode_residual :: proc(r: ^Bit_Reader, out: []$T, order: int) -> Error {
	method := read(r, 2)
	if method > 1 do return .Invalid_Data
	parameter_bits := 4 + int(method)
	escape := u32(1) << uint(parameter_bits) - 1
	partition_order := uint(read(r, 4))
	n := len(out)
	per := n >> partition_order
	if per << partition_order != n || per < order do return .Invalid_Data
	at := order
	for p in 1 ..= 1 << partition_order {
		end := p * per
		k := read(r, parameter_bits)
		if k == escape {
			bits := int(read(r, 5))
			for &x in out[at:end] do x = T(read_signed(r, bits))
		} else {
			read_rice(r, out[at:end], uint(k))
		}
		if r.left < 0 do return .Invalid_Data
		at = end
	}
	return .None
}

// Rice codewords, unfolded. The unary part is bounded by the frame's bits,
// so the folded value is formed in u64 without overflow and must then fit
// the 32 bits the residual is limited to. A codeword that is already in the
// cache (nearly all of them) is taken with one refill.
@(private)
read_rice :: proc(r: ^Bit_Reader, out: []$T, k: uint) #no_bounds_check {
	for &x in out {
		refill(r)
		z := uint(intrinsics.count_leading_zeros(r.cache))
		folded: u64
		if z + 1 + k <= uint(r.count) {
			folded = u64(z) << k | (r.cache << (z + 1)) >> (64 - k) // a shift by 64 is 0 in Odin
			skip(r, int(z + 1 + k))
		} else {
			folded = read_unary(r) << k | u64(read(r, int(k)))
		}
		if folded > u64(max(u32)) {r.left = -1; return}
		u := u32(folded)
		x = T(i32(u >> 1) ~ -i32(u & 1))
	}
}

// The residuals in out[order:] become samples: residual + prediction.
@(private)
restore_fixed :: proc(out: []$T, order: int, $A: typeid) #no_bounds_check {
	switch order {
	case 1:
		for i in 1 ..< len(out) do out[i] = T(A(out[i]) + A(out[i - 1]))
	case 2:
		for i in 2 ..< len(out) do out[i] = T(A(out[i]) + 2 * A(out[i - 1]) - A(out[i - 2]))
	case 3:
		for i in 3 ..< len(out) do out[i] = T(A(out[i]) + 3 * (A(out[i - 1]) - A(out[i - 2])) + A(out[i - 3]))
	case 4:
		for i in 4 ..< len(out) do out[i] = T(A(out[i]) + 4 * (A(out[i - 1]) + A(out[i - 3])) - 6 * A(out[i - 2]) - A(out[i - 4]))
	}
}

// Linear prediction: coefficient j weighs the sample j+1 before. Orders
// up to 12 (the streamable subset's limit at 48 kHz and below) get a body
// unrolled at compile time, picked by recursing over $N; higher orders
// share the loop over the coefficients.
@(private)
restore_lpc :: proc(out: []$T, coefficients: []i32, shift: uint, $A: typeid, $N: int) #no_bounds_check {
	when N > 12 {
		order := len(coefficients)
		for i in order ..< len(out) {
			sum: A
			for c, j in coefficients do sum += A(c) * A(out[i - 1 - j])
			out[i] = T(A(out[i]) + sum >> shift)
		}
	} else {
		if len(coefficients) != N {
			restore_lpc(out, coefficients, shift, A, N + 1)
			return
		}
		c: [N]A
		for j in 0 ..< N do c[j] = A(coefficients[j])
		for i in N ..< len(out) {
			sum: A
			// The newest sample last: the loop-carried dependency is then one
			// multiply and add, not the whole sum (wrapping adds, the same result).
			#unroll for j in 0 ..< N do sum += c[N - 1 - j] * A(out[i - N + j])
			out[i] = T(A(out[i]) + sum >> shift)
		}
	}
}
