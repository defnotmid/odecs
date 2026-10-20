package aac_decoder

import aac ".."
import "core:math"

Error :: aac.Error
Config :: aac.Config
read :: aac.read_bits
flag :: aac.read_flag

Ics :: struct {
	sequence:        aac.Window_Sequence,
	shape:           u8,
	max_sfb, groups: int,
	group_length:    [8]int,
	offsets:         []int,
}
Tns_Filter :: struct {
	length, order: int,
	reverse:       bool,
	reflection:    [20]f64,
}
Channel :: struct {
	ics:         Ics,
	codebook:    [8][64]u8,
	sf:          [8][64]int,
	spectrum:    [1024]f64,
	quant:       [1024]i32,
	tns:         [8][3]Tns_Filter,
	tns_count:   [8]int,
	tns_present: bool,
}

@(private)
Tuple_Tables :: struct {
	signed_quad:   [81][4]i8,
	unsigned_quad: [81][4]i8,
	signed_pair:   [81][2]i8,
	pair_8:        [64][2]i8,
	pair_13:       [169][2]i8,
	pair_17:       [289][2]i8,
}
#assert(size_of(Tuple_Tables) == 1854)

Decoder :: struct {
	config:                Config,
	rate_index:            int,
	frame_samples:         int,
	initialized:           bool,
	transform:             aac.Transform,
	huffman:               aac.Huffman_Tables,
	tuples:                Tuple_Tables,
	dequant:               [128]f64,
	scale:                 [256]f64,
	bank:                  [aac.MAX_CHANNELS]aac.Filterbank,
	channel:               [aac.MAX_CHANNELS]Channel,
	noise_seed:            u32,
	layout:                aac.Channel_Layout,
	program:               aac.Program_Config,
	explicit_layout:       bool,
	allow_in_band_program: bool,
	dynamic_range:         Dynamic_Range,
	drc_scratch:           [16]Dynamic_Range,
	frame:                 Frame_Info,
	coupling:              [16]Coupling_Channel,
	coupling_bank:         [16]aac.Filterbank,
	coupling_pcm:          [1024]f32,
	// Multiple ADTS blocks form one transaction. These retained destinations
	// are used only for that transport; ordinary access units render directly.
	pending_bank:          [aac.MAX_CHANNELS]aac.Filterbank,
	remapped_bank:         [aac.MAX_CHANNELS]aac.Filterbank,
	pending_coupling_bank: [16]aac.Filterbank,
	pending_pcm:           [64 * aac.MAX_CHANNELS * 1024]f32,
	latm:                  aac.LATM_State,
	latm_scratch:          [8191]u8,
}

@(private)
init_tuple_quads :: proc(out: ^[81][4]i8, bias: int) {
	for &tuple, symbol in out^ {
		index := symbol
		for i := 3; i >= 0; i -= 1 {
			tuple[i] = i8(index % 3 - bias)
			index /= 3
		}
	}
}

@(private)
init_tuple_pairs :: proc(out: [][2]i8, radix, bias: int) {
	for &tuple, symbol in out {
		tuple = {i8(symbol / radix - bias), i8(symbol % radix - bias)}
	}
}

@(private)
init_decoder_tables :: proc(d: ^Decoder) {
	// Book pairs share symbol digits; only their Huffman codewords differ.
	init_tuple_quads(&d.tuples.signed_quad, 1)
	init_tuple_quads(&d.tuples.unsigned_quad, 0)
	init_tuple_pairs(d.tuples.signed_pair[:], 9, 4)
	init_tuple_pairs(d.tuples.pair_8[:], 8, 0)
	init_tuple_pairs(d.tuples.pair_13[:], 13, 0)
	init_tuple_pairs(d.tuples.pair_17[:], 17, 0)
	for &v, magnitude in d.dequant do v = math.pow(f64(magnitude), 4.0 / 3)
	for &v, sf in d.scale do v = math.pow(2.0, f64(sf - 100) / 4)
}

init_decoder :: proc(d: ^Decoder, config: Config) -> Error {
	if d == nil do return .Invalid_Config
	if e := aac.validate_config(config); e != .None do return e
	d^ = {}
	d.config = config
	d.rate_index = aac.sample_rate_index(config.sample_rate)
	d.frame_samples = aac.resolved_frame_samples(config)
	d.layout, _ = aac.resolve_channel_layout(config)
	d.program = config.program_config
	d.explicit_layout = config.use_pce && aac.program_config_present(&d.config.program_config)
	d.allow_in_band_program = config.use_pce && !d.explicit_layout
	aac.init_transform(&d.transform, d.frame_samples)
	aac.init_huffman(&d.huffman)
	init_decoder_tables(d)
	d.noise_seed = 1
	d.initialized = true
	return .None
}

reset_decoder :: proc(d: ^Decoder) {
	d.bank = {}; d.coupling_bank = {}; d.noise_seed = 1
	d.layout, _ = aac.resolve_channel_layout(d.config)
	d.program = d.config.program_config
	d.explicit_layout = d.config.use_pce && aac.program_config_present(&d.config.program_config)
	d.allow_in_band_program = d.config.use_pce && !d.explicit_layout
	d.dynamic_range = {}
	d.latm = {}
}

@(private)
ics_info :: proc(r: ^aac.Bit_Reader, rate: int, frame_samples: int = 1024) -> Ics {
	info: Ics
	if flag(r) {r.err = .Invalid_Data; return info}
	info.sequence = aac.Window_Sequence(read(r, 2))
	info.shape = u8(read(r, 1))
	info.groups = 1
	info.group_length[0] = 1
	if info.sequence == .Short {
		info.max_sfb = int(read(r, 4))
		info.offsets = aac.short_offsets(rate, frame_samples)
		for _ in 0 ..< 7 {
			if flag(r) {info.group_length[info.groups - 1] += 1} else {
				info.group_length[info.groups] = 1; info.groups += 1
			}
		}
	} else {
		info.max_sfb = int(read(r, 6))
		info.offsets = aac.long_offsets(rate, frame_samples)
		if flag(r) do r.err = .Unsupported_Profile
	}
	if info.max_sfb >= len(info.offsets) do r.err = .Invalid_Data
	return info
}

@(private)
read_tuple_shape_into :: #force_inline proc(
	$Count: int,
	$Signed: bool,
	$Escape: bool,
	r: ^aac.Bit_Reader,
	tables: ^aac.Huffman_Tables,
	plane: [][Count]i8,
	book: int,
	values: []i32,
) -> (
	count: int,
) {
	#assert(Count == 2 || Count == 4)
	#assert(!Escape || (Count == 2 && !Signed))
	count = Count
	assert(len(values) >= Count)
	index := aac.read_huffman(r, tables, book)
	digits := &plane[index]
	#unroll for i in 0 ..< Count do values[i] = i32(digits[i])
	when !Signed {
		#unroll for i in 0 ..< Count do if values[i] != 0 && flag(r) do values[i] = -values[i]
	}
	when Escape {
		#unroll for i in 0 ..< Count do if abs(values[i]) == 16 {
			n := 4
			for flag(r) && r.err == .None {
				n += 1
				if n > 12 {r.err = .Invalid_Data; return}
			}
			mag := i32(1 << uint(n)) + i32(read(r, n))
			values[i] = values[i] < 0 ? -mag : mag
		}
	}
	return
}

// Private compatibility entry for tuple callers/tests. Production selects
// this same tuple owner's shape and immutable digit plane once per band.
@(private)
read_tuple_into :: #force_inline proc(
	r: ^aac.Bit_Reader,
	tables: ^aac.Huffman_Tables,
	tuples: ^Tuple_Tables,
	book: int,
	values: []i32,
) -> (
	count: int,
) {
	switch book {
	case 1, 2:
		return read_tuple_shape_into(
			4,
			true,
			false,
			r,
			tables,
			tuples.signed_quad[:],
			book,
			values,
		)
	case 3, 4:
		return read_tuple_shape_into(
			4,
			false,
			false,
			r,
			tables,
			tuples.unsigned_quad[:],
			book,
			values,
		)
	case 5, 6:
		return read_tuple_shape_into(
			2,
			true,
			false,
			r,
			tables,
			tuples.signed_pair[:],
			book,
			values,
		)
	case 7, 8:
		return read_tuple_shape_into(2, false, false, r, tables, tuples.pair_8[:], book, values)
	case 9, 10:
		return read_tuple_shape_into(2, false, false, r, tables, tuples.pair_13[:], book, values)
	case 11:
		return read_tuple_shape_into(2, false, true, r, tables, tuples.pair_17[:], book, values)
	case:
		count = book <= 4 ? 4 : 2
		assert(len(values) >= count)
		// Preserve the previous invalid-book call/error/position order, including
		// book zero's Huffman read before the tuple-domain refusal.
		_ = aac.read_huffman(r, tables, book)
		r.err = .Invalid_Data
		return
	}
}

@(private)
dequantize :: #force_inline proc(d: ^Decoder, q: i32, scale: f64) -> f64 {
	magnitude := int(abs(q))
	value :=
		uint(magnitude) < uint(len(d.dequant)) ? d.dequant[magnitude] : math.pow(f64(magnitude), 4.0 / 3)
	// Escape magnitudes reach 8191; four pulses may add 60 to one position.
	// The fallback preserves that entire domain and the original operation order.
	return value * scale * (q < 0 ? -1 : 1)
}

@(private)
read_spectral_band :: #force_no_inline proc(
	$Direct: bool,
	$Count: int,
	$Signed: bool,
	$Escape: bool,
	d: ^Decoder,
	r: ^aac.Bit_Reader,
	c: ^Channel,
	plane: [][Count]i8,
	book, start, end, stride, windows: int,
	scale: f64,
) -> bool {
	// One real call owns the grouped band's windows. Book shape and plane are
	// invariant throughout; every tuple uses the same reader/sign/escape owner.
	when Direct {tuple: [Count]i32 = ---} // once-per-band scratch, which only Direct uses
	for w in 0 ..< windows {
		first, limit := start + w * stride, end + w * stride
		for k := first; k < limit; {
			when Direct {
				_ = read_tuple_shape_into(
					Count,
					Signed,
					Escape,
					r,
					&d.huffman,
					plane,
					book,
					tuple[:],
				)
			} else {
				_ = read_tuple_shape_into(
					Count,
					Signed,
					Escape,
					r,
					&d.huffman,
					plane,
					book,
					c.quant[k:limit],
				)
			}
			if r.err != .None || k + Count > limit {
				if r.err == .None do r.err = .Invalid_Data
				return false
			}
			when Direct {
				// No pulse needs the integer plane: decode directly into its final
				// spectral owner. Keep the existing dequantization arithmetic.
				#unroll for i in 0 ..< Count do c.spectrum[k + i] = dequantize(d, tuple[i], scale)
			}
			k += Count
		}
	}
	return true
}

@(private)
read_grouped_spectral_band :: #force_inline proc(
	$Direct: bool,
	d: ^Decoder,
	r: ^aac.Bit_Reader,
	c: ^Channel,
	book, start, end, stride, windows: int,
	scale: f64,
) -> bool {
	switch book {
	case 1, 2:
		return read_spectral_band(
			Direct,
			4,
			true,
			false,
			d,
			r,
			c,
			d.tuples.signed_quad[:],
			book,
			start,
			end,
			stride,
			windows,
			scale,
		)
	case 3, 4:
		return read_spectral_band(
			Direct,
			4,
			false,
			false,
			d,
			r,
			c,
			d.tuples.unsigned_quad[:],
			book,
			start,
			end,
			stride,
			windows,
			scale,
		)
	case 5, 6:
		return read_spectral_band(
			Direct,
			2,
			true,
			false,
			d,
			r,
			c,
			d.tuples.signed_pair[:],
			book,
			start,
			end,
			stride,
			windows,
			scale,
		)
	case 7, 8:
		return read_spectral_band(
			Direct,
			2,
			false,
			false,
			d,
			r,
			c,
			d.tuples.pair_8[:],
			book,
			start,
			end,
			stride,
			windows,
			scale,
		)
	case 9, 10:
		return read_spectral_band(
			Direct,
			2,
			false,
			false,
			d,
			r,
			c,
			d.tuples.pair_13[:],
			book,
			start,
			end,
			stride,
			windows,
			scale,
		)
	case 11:
		return read_spectral_band(
			Direct,
			2,
			false,
			true,
			d,
			r,
			c,
			d.tuples.pair_17[:],
			book,
			start,
			end,
			stride,
			windows,
			scale,
		)
	case:
		r.err = .Invalid_Data; return false
	}
}

@(private)
read_channel :: proc(d: ^Decoder, r: ^aac.Bit_Reader, c: ^Channel, common: bool) {
	gain := int(read(r, 8))
	if !common do c.ics = ics_info(r, d.rate_index, d.frame_samples)
	if r.err != .None do return
	info := &c.ics
	short := info.sequence == .Short
	length_bits := short ? 3 : 5
	escape := (1 << uint(length_bits)) - 1
	for g in 0 ..< info.groups {
		band := 0
		for band < info.max_sfb && r.err == .None {
			cb := u8(read(r, 4))
			if cb == 12 {r.err = .Invalid_Data; return}
			length := 0
			for {
				v := int(read(r, length_bits)); length += v
				if r.err != .None || length > info.max_sfb - band {r.err = .Invalid_Data; return}
				if v != escape do break
			}
			if length == 0 {r.err = .Invalid_Data; return}
			for b in band ..< band + length do c.codebook[g][b] = cb
			band += length
		}
	}
	sf, noise, intensity := gain, gain - 90, 0
	first_noise := true
	for g in 0 ..< info.groups do for b in 0 ..< info.max_sfb {
		cb := c.codebook[g][b]
		switch cb {
		case 0:
			c.sf[g][b] = 0
		case 13:
			if first_noise {noise += int(read(r, 9)) - 256; first_noise = false} else {
				noise += aac.read_huffman(r, &d.huffman, 0) - 60
			}
			c.sf[g][b] = noise
		case 14, 15:
			intensity += aac.read_huffman(r, &d.huffman, 0) - 60
			c.sf[g][b] = intensity
		case:
			sf += aac.read_huffman(r, &d.huffman, 0) - 60
			if sf < 0 || sf > 255 {r.err = .Invalid_Data; return}
			c.sf[g][b] = sf
		}
		if abs(c.sf[g][b]) > 512 {r.err = .Invalid_Data; return}
	}
	pulse_count, pulse_start: int
	pulse_offset, pulse_amplitude: [4]int
	if flag(r) {
		if short {r.err = .Invalid_Data; return}
		pulse_count = int(read(r, 2)) + 1
		band := int(read(r, 6))
		if band >= len(info.offsets) - 1 {r.err = .Invalid_Data; return}
		pulse_start = info.offsets[band]
		for i in 0 ..< pulse_count {pulse_offset[i] = int(read(r, 5)); pulse_amplitude[i] = int(read(r, 4))}
	}
	c.tns_present = flag(r)
	if c.tns_present {
		for w in 0 ..< (short ? 8 : 1) {
			count := int(read(r, short ? 1 : 2))
			c.tns_count[w] = count
			resolution := 3
			if count > 0 do resolution += int(read(r, 1))
			for i in 0 ..< count {
				f := &c.tns[w][i]
				f.length = int(read(r, short ? 4 : 6))
				f.order = int(read(r, short ? 3 : 5))
				if f.order > (short ? 7 : 12) {r.err = .Invalid_Data; return}
				if f.order == 0 do continue
				f.reverse = flag(r)
				bits := resolution - int(read(r, 1))
				for j in 0 ..< f.order {
					v := int(read(r, bits))
					if v & (1 << uint(bits - 1)) != 0 do v -= 1 << uint(bits)
					divisor :=
						(f64(i32(1) << uint(resolution - 1)) + (v < 0 ? 0.5 : -0.5)) /
						(math.PI / 2)
					f.reflection[j] = math.sin(f64(v) / divisor)
				}
			}
		}
	}
	if flag(r) {r.err = .Unsupported_Tool; return}
	if r.err != .None do return
	// Only pulses consume the integer plane after parsing, including positions
	// outside coded bands. All other frames write spectral coefficients directly.
	if pulse_count != 0 do c.quant = {}
	window := 0
	stride := short ? d.frame_samples / 8 : d.frame_samples
	for g in 0 ..< info.groups {
		for band in 0 ..< info.max_sfb {
			cb := int(c.codebook[g][band])
			if cb == 0 || cb >= 13 do continue
			scale := d.scale[c.sf[g][band]]
			start, end :=
				window * stride + info.offsets[band], window * stride + info.offsets[band + 1]
			if pulse_count == 0 {
				if !read_grouped_spectral_band(true, d, r, c, cb, start, end, stride, info.group_length[g], scale) do return
			} else {
				if !read_grouped_spectral_band(false, d, r, c, cb, start, end, stride, info.group_length[g], scale) do return
			}
		}
		window += info.group_length[g]
	}
	if pulse_count == 0 do return
	for i in 0 ..< pulse_count {
		pulse_start += pulse_offset[i]
		if pulse_start >= d.frame_samples {r.err = .Invalid_Data; return}
		q := &c.quant[pulse_start]
		q^ += q^ > 0 ? i32(pulse_amplitude[i]) : -i32(pulse_amplitude[i])
	}
	window = 0
	for g in 0 ..< info.groups {
		for band in 0 ..< info.max_sfb {
			cb := c.codebook[g][band]
			// Pulse restoration precedes inverse quantization, including a
			// transmitted ZERO_HCB coefficient (its owned scalefactor is zero).
			if cb >= 13 do continue
			scale := d.scale[c.sf[g][band]]
			for w in 0 ..< info.group_length[g] {
				for k in info.offsets[band] ..< info.offsets[band + 1] {
					i := (window + w) * stride + k
					q := c.quant[i]
					c.spectrum[i] = dequantize(d, q, scale)
				}
			}
		}
		window += info.group_length[g]
	}
}

@(private)
noise_band :: proc(seed: ^u32, out: []f64, sf: int) {
	energy: f64
	for &v in out {
		seed^ = seed^ * 1664525 + 1013904223
		v = f64(i32(seed^)); energy += v * v
	}
	scale := math.pow(2.0, f64(sf) / 4) / math.sqrt(max(energy, 1))
	for &v in out do v *= scale
}

@(private)
stereo_and_noise :: proc(d: ^Decoder, common: bool, ms: ^[8][64]bool) {
	// Compatibility entry for the two-channel tool oracle. Production passes
	// each element's own channels and a transaction-local seed to this owner.
	n := d.frame_samples == 0 ? 1024 : d.frame_samples
	element_stereo_and_noise(d.channel[:d.config.channels], &d.noise_seed, common, ms, n)
}

@(private)
element_stereo_and_noise :: proc(
	channels: []Channel,
	seed: ^u32,
	common: bool,
	ms: ^[8][64]bool,
	frame_samples: int,
) {
	left := &channels[0]
	// Channels may have independent grouping when common_window is zero.
	for ch in 0 ..< len(channels) {
		c := &channels[ch]
		window := 0
		stride := c.ics.sequence == .Short ? frame_samples / 8 : frame_samples
		for g in 0 ..< c.ics.groups {
			for b in 0 ..< c.ics.max_sfb {
				if c.codebook[g][b] != 13 do continue
				for w in 0 ..< c.ics.group_length[g] {
					start, end :=
						(window + w) * stride +
						c.ics.offsets[b],
						(window + w) * stride +
						c.ics.offsets[b + 1]
					if ch == 1 && common && ms[g][b] && left.codebook[g][b] == 13 {
						scale := math.pow(2.0, f64(c.sf[g][b] - left.sf[g][b]) / 4)
						for k in start ..< end do c.spectrum[k] = left.spectrum[k] * scale
					} else {noise_band(seed, c.spectrum[start:end], c.sf[g][b])}
				}
			}
			window += c.ics.group_length[g]
		}
	}
	if !common || len(channels) != 2 do return
	right := &channels[1]
	window := 0
	stride := left.ics.sequence == .Short ? frame_samples / 8 : frame_samples
	for g in 0 ..< left.ics.groups {
		for b in 0 ..< left.ics.max_sfb {
			cb := right.codebook[g][b]
			intensity := cb == 14 || cb == 15
			use_ms := ms[g][b] && cb != 13 && left.codebook[g][b] != 13
			// A band with neither tool has no spectral work. In particular,
			// ordinary stereo no longer computes an unused intensity scale or
			// revisits every coefficient just to select an empty branch.
			if !intensity && !use_ms do continue
			if intensity {
				scale := math.pow(2.0, -f64(right.sf[g][b]) / 4)
				if cb == 14 do scale = -scale
				if ms[g][b] do scale = -scale
				for w in 0 ..< left.ics.group_length[g] do for k in left.ics.offsets[b] ..< left.ics.offsets[b + 1] {
					i := (window + w) * stride + k
					right.spectrum[i] = left.spectrum[i] * scale
				}
			} else {
				for w in 0 ..< left.ics.group_length[g] do for k in left.ics.offsets[b] ..< left.ics.offsets[b + 1] {
					i := (window + w) * stride + k
					l, r := left.spectrum[i], right.spectrum[i]
					left.spectrum[i], right.spectrum[i] = l + r, l - r
				}
			}
		}
		window += left.ics.group_length[g]
	}
}

@(private)
apply_tns :: proc(c: ^Channel, rate: int, frame_samples: int = 1024) {
	short := c.ics.sequence == .Short
	stride := short ? frame_samples / 8 : frame_samples
	max_band := min(c.ics.max_sfb, aac.tns_max_bands(rate, short))
	for w in 0 ..< (short ? 8 : 1) {
		bottom := len(c.ics.offsets) - 1
		for &f in c.tns[w][:c.tns_count[w]] {
			top := bottom
			bottom = max(0, top - f.length)
			if f.order == 0 do continue
			a, tmp: [21]f64
			a[0] = 1
			for m in 1 ..= f.order {
				k := f.reflection[m - 1]
				for j in 1 ..< m do tmp[j] = a[j] + k * a[m - j]
				for j in 1 ..< m do a[j] = tmp[j]
				a[m] = k
			}
			start, end := c.ics.offsets[min(bottom, max_band)], c.ics.offsets[min(top, max_band)]
			history: [20]f64
			for i in 0 ..< end - start {
				p := w * stride + (f.reverse ? end - 1 - i : start + i)
				v := c.spectrum[p]
				for j in 0 ..< f.order do v -= a[j + 1] * history[j]
				for j := f.order - 1; j > 0; j -= 1 do history[j] = history[j - 1]
				history[0] = v; c.spectrum[p] = v
			}
		}
	}
}
