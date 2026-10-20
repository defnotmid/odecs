// Apple Lossless (ALAC) decoding: magic cookie parsing, adaptive Golomb-Rice
// entropy decoding, dynamic linear prediction and lossless mid/side stereo
// unmixing into planar i32 channel buffers.
//
// Restructured Odin port of Apple's reference ALAC decoder (Apache-2.0;
// copyright and conditions in LICENSE-alac.txt): ALACDecoder.cpp, ag_dec.c,
// dp_dec.c and matrix_dec.c.
package alac

import "base:intrinsics"
import "core:simd"
import common "../../common"

Error :: enum {
	None,
	Invalid_Data,
	Unsupported,
	Out_Of_Memory,
}

MAX_CHANNELS :: 8
MAX_FRAME_SAMPLES :: 65536
CONFIG_SIZE :: 24

// Parsed 24-byte ALACSpecificConfig (or a 36-byte cookie prefixed with the
// 12-byte format/alac header).
Config :: struct {
	frame_length: int,
	bit_depth:    int,
	pb, mb, kb:   u32,
	channels:     int,
	max_run:      u32,
	max_frame:    u32,
	avg_bit_rate: u32,
	sample_rate:  int,
}

// Decoder state: planar i32 channel buffers and shared predictor scratch.
Decoder :: struct {
	config:    Config,
	planes:    [MAX_CHANNELS][dynamic]i32,
	predictor: [dynamic]i32,
}

// A decoded ALAC frame. `planes[:channels]` are borrowed from the Decoder
// until the next `decode_frame` or `destroy_decoder`.
Frame :: struct {
	planes:      [MAX_CHANNELS][]i32,
	samples:     int,
	channels:    int,
	bit_depth:   int,
	sample_rate: int,
}

// ALAC stream element order (MPEG/AAC: C, L, R, Ls, Rs, LFE) to standard
// interleaved PCM order (L, R, C, LFE, Ls, Rs).
@(private, rodata)
CHANNEL_MAP := [MAX_CHANNELS][MAX_CHANNELS]u8{
	{0, 0, 0, 0, 0, 0, 0, 0}, // 1: C
	{0, 1, 0, 0, 0, 0, 0, 0}, // 2: L, R
	{2, 0, 1, 0, 0, 0, 0, 0}, // 3: C, L, R -> L, R, C
	{2, 0, 1, 3, 0, 0, 0, 0}, // 4: C, L, R, Cs -> L, R, C, Cs
	{2, 0, 1, 3, 4, 0, 0, 0}, // 5: C, L, R, Ls, Rs -> L, R, C, Ls, Rs
	{2, 0, 1, 4, 5, 3, 0, 0}, // 6: C, L, R, Ls, Rs, LFE -> L, R, C, LFE, Ls, Rs
	{2, 0, 1, 4, 5, 6, 3, 0}, // 7: C, L, R, Ls, Rs, Cs, LFE -> L, R, C, LFE, Ls, Rs, Cs
	{2, 6, 7, 0, 1, 4, 5, 3}, // 8: C, Lc, Rc, L, R, Ls, Rs, LFE -> L, R, C, LFE, Ls, Rs, Lc, Rc
}

// Parses a 24-byte ALACSpecificConfig or a 36-byte magic cookie (12-byte
// `frma`/`alac` header followed by the 24-byte config).
parse_config :: proc(cookie: []u8) -> (cfg: Config, err: Error) {
	data := cookie
	if len(data) >= 36 && data[4] == 'f' && data[5] == 'r' && data[6] == 'm' && data[7] == 'a' {
		data = data[12:]
	}
	if len(data) >= 28 && data[4] == 'a' && data[5] == 'l' && data[6] == 'a' && data[7] == 'c' {
		// FullBox header (size + 'alac' + version/flags) wrapping the 24-byte config.
		if len(data) < 36 do return {}, .Invalid_Data
		if data[8] != 0 do return {}, .Unsupported
		data = data[12:]
	}
	if len(data) < CONFIG_SIZE do return {}, .Invalid_Data
	frame_length := int(be_u32(data[0:4]))
	compatible_version := data[4]
	bit_depth := int(data[5])
	pb := u32(data[6])
	mb := u32(data[7])
	kb := u32(data[8])
	channels := int(data[9])
	max_run := u32(be_u16(data[10:12]))
	max_frame := be_u32(data[12:16])
	avg_bit_rate := be_u32(data[16:20])
	sample_rate := int(be_u32(data[20:24]))

	if compatible_version > 0 do return {}, .Unsupported
	if bit_depth != 16 && bit_depth != 20 && bit_depth != 24 && bit_depth != 32 do return {}, .Unsupported
	if channels < 1 || channels > MAX_CHANNELS do return {}, .Unsupported
	if frame_length <= 0 || frame_length > MAX_FRAME_SAMPLES do return {}, .Invalid_Data
	if sample_rate <= 0 || sample_rate > 384000 do return {}, .Invalid_Data
	if kb > 31 do return {}, .Invalid_Data

	return {
		frame_length = frame_length,
		bit_depth    = bit_depth,
		pb           = pb,
		mb           = mb,
		kb           = kb,
		channels     = channels,
		max_run      = max_run == 0 ? 255 : max_run,
		max_frame    = max_frame,
		avg_bit_rate = avg_bit_rate,
		sample_rate  = sample_rate,
	}, .None
}

init_decoder :: proc(d: ^Decoder, cfg: Config) -> Error {
	if cfg.channels < 1 || cfg.channels > MAX_CHANNELS || cfg.frame_length <= 0 || cfg.frame_length > MAX_FRAME_SAMPLES {
		return .Invalid_Data
	}
	d.config = cfg
	for c in 0 ..< cfg.channels {
		if resize(&d.planes[c], cfg.frame_length) != nil {
			destroy_decoder(d)
			return .Out_Of_Memory
		}
	}
	if resize(&d.predictor, cfg.frame_length) != nil {
		destroy_decoder(d)
		return .Out_Of_Memory
	}
	return .None
}

destroy_decoder :: proc(d: ^Decoder) {
	for &p in d.planes do delete(p)
	delete(d.predictor)
	d^ = {}
}

// Decodes one ALAC packet into `d`'s planar buffers and returns a borrowed
// `Frame` view.
decode_frame :: proc(d: ^Decoder, packet: []u8) -> (f: Frame, err: Error) {
	cfg := d.config
	if cfg.channels < 1 || cfg.channels > MAX_CHANNELS do return {}, .Invalid_Data
	r := common.Bit_Reader {
		data = packet,
		left = len(packet) * 8,
	}
	num_samples := cfg.frame_length
	channel_index := 0
	perm := CHANNEL_MAP[cfg.channels - 1]
	coefs: [2][32]i16

	loop: for {
		if r.left < 3 do return f, .Invalid_Data
		tag := common.read_bits(&r, 3)
		switch tag {
		case 0, 1, 3: // ID_SCE (1 ch), ID_CPE (2 ch), ID_LFE (1 ch)
			ch := tag == 1 ? 2 : 1
			if channel_index + ch > cfg.channels do return f, .Invalid_Data
			_ = common.read_bits(&r, 4) // element_instance_tag
			if common.read_bits(&r, 12) != 0 do return f, .Invalid_Data // unused header bits must be 0
			header_byte := common.read_bits(&r, 4)
			partial := header_byte >> 3 != 0
			bytes_shifted := int((header_byte >> 1) & 3)
			if bytes_shifted == 3 || bytes_shifted * 8 >= cfg.bit_depth do return f, .Invalid_Data
			escape := header_byte & 1 != 0
			if partial {
				n := int(common.read_bits(&r, 32))
				if n < 0 || n > MAX_FRAME_SAMPLES do return f, .Invalid_Data
				if channel_index > 0 && n != num_samples do return f, .Invalid_Data
				num_samples = n
				if ensure_buffers(d, num_samples) != .None do return f, .Out_Of_Memory
			}
			if r.left < 0 do return f, .Invalid_Data
			out: [2][]i32
			for c in 0 ..< ch do out[c] = d.planes[perm[channel_index + c]][:num_samples]
			if !escape {
				chan_bits := cfg.bit_depth - bytes_shifted * 8 + (ch - 1)
				if chan_bits > 32 do return f, .Invalid_Data
				mix_bits := common.read_bits(&r, 8)
				mix_res := i32(i8(u8(common.read_bits(&r, 8))))
				mode, den_shift, pb_factor: [2]u32
				num: [2]int
				for c in 0 ..< ch {
					mode_byte := common.read_bits(&r, 8)
					mode[c] = mode_byte >> 4
					den_shift[c] = mode_byte & 0xF
					pb_byte := common.read_bits(&r, 8)
					pb_factor[c] = pb_byte >> 5
					num[c] = int(pb_byte & 0x1F)
					for i in 0 ..< num[c] do coefs[c][i] = i16(u16(common.read_bits(&r, 16)))
				}
				if r.left < 0 do return f, .Invalid_Data

				shift_bits: common.Bit_Reader
				if bytes_shifted != 0 {
					shift_bits = r
					common.advance_bits(&r, bytes_shifted * 8 * ch * num_samples)
					if r.left < 0 do return f, .Invalid_Data
				}

				pred := d.predictor[:num_samples]
				for c in 0 ..< ch {
					ag := make_ag_params(cfg.mb, (cfg.pb * pb_factor[c]) / 4, cfg.kb, cfg.max_run)
					dyn_decomp(&ag, &r, pred, chan_bits) or_return
					if mode[c] == 0 {
						unpc_block(pred, out[c], coefs[c][:num[c]], chan_bits, den_shift[c])
					} else {
						unpc_block(pred, pred, nil, chan_bits, 0, true)
						unpc_block(pred, out[c], coefs[c][:num[c]], chan_bits, den_shift[c])
					}
				}
				if ch == 2 && mix_res != 0 {
					if mix_bits > 31 do return f, .Invalid_Data
					unmix_stereo(out[0], out[1], mix_res, uint(mix_bits))
				}
				if bytes_shifted != 0 {
					shift := uint(bytes_shifted * 8)
					#no_bounds_check for i in 0 ..< num_samples {
						for c in 0 ..< ch {
							out[c][i] = (out[c][i] << shift) | i32(common.read_bits(&shift_bits, int(shift)))
						}
					}
				}
			} else {
				for i in 0 ..< num_samples {
					for c in 0 ..< ch do out[c][i] = i32(common.read_signed_bits(&r, cfg.bit_depth))
				}
				if r.left < 0 do return f, .Invalid_Data
			}
			channel_index += ch

		case 4: // ID_DSE (data stream element)
			_ = common.read_bits(&r, 4)
			align := common.read_bits(&r, 1) != 0
			count := int(common.read_bits(&r, 8))
			if count == 255 do count += int(common.read_bits(&r, 8))
			if align do common.align_byte(&r)
			common.advance_bits(&r, count * 8)
			if r.left < 0 do return f, .Invalid_Data

		case 6: // ID_FIL (fill element)
			count := int(common.read_bits(&r, 4))
			if count == 15 do count += int(common.read_bits(&r, 8)) - 1
			if count < 0 do return f, .Invalid_Data
			common.advance_bits(&r, count * 8)
			if r.left < 0 do return f, .Invalid_Data

		case 7: // ID_END
			common.align_byte(&r)
			if r.left < 0 do return f, .Invalid_Data
			break loop

		case: // ID_CCE (2), ID_PCE (5)
			return f, .Invalid_Data
		}
	}

	if channel_index != cfg.channels do return f, .Invalid_Data
	f = {
		samples     = num_samples,
		channels    = cfg.channels,
		bit_depth   = cfg.bit_depth,
		sample_rate = cfg.sample_rate,
	}
	for c in 0 ..< cfg.channels do f.planes[c] = d.planes[c][:num_samples]
	return f, .None
}

@(private)
unmix_stereo :: proc(u, v: []i32, mix_res: i32, mix_bits: uint) #no_bounds_check {
	n := len(u)
	i := 0
	mr := simd.i32x8(mix_res)
	mb := simd.u32x8(u32(mix_bits))
	for ; i + 8 <= n; i += 8 {
		uv := intrinsics.unaligned_load((^simd.i32x8)(&u[i]))
		vv := intrinsics.unaligned_load((^simd.i32x8)(&v[i]))
		lv := uv + vv - simd.shr(mr * vv, mb)
		rv := lv - vv
		intrinsics.unaligned_store((^simd.i32x8)(&u[i]), lv)
		intrinsics.unaligned_store((^simd.i32x8)(&v[i]), rv)
	}
	for ; i < n; i += 1 {
		vt := v[i]
		l := u[i] + vt - ((mix_res * vt) >> mix_bits)
		u[i] = l
		v[i] = l - vt
	}
}

// Interleaves a decoded frame into `out` (at least f.samples * kept channels
// values), keeping the first `channels` channels, or all of them for 0: as
// f32 in [-1, 1), sample / 2^(bit_depth - 1), or as i16 (common.scale_i16).
interleave :: proc {
	interleave_f32,
	interleave_i16,
}

interleave_f32 :: proc(f: Frame, out: []f32, channels := 0) {
	f := f
	common.interleave_i32_f32(f.planes[:common.kept_channels(f.channels, channels)], f.samples, f.bit_depth, out)
}

interleave_i16 :: proc(f: Frame, out: []i16, channels := 0) {
	f := f
	common.interleave_i32_i16(f.planes[:common.kept_channels(f.channels, channels)], f.samples, f.bit_depth, out)
}

@(private)
ensure_buffers :: proc(d: ^Decoder, n: int) -> Error {
	for c in 0 ..< d.config.channels {
		if len(d.planes[c]) < n && resize(&d.planes[c], n) != nil do return .Out_Of_Memory
	}
	if len(d.predictor) < n && resize(&d.predictor, n) != nil do return .Out_Of_Memory
	return .None
}

// ---- Adaptive Golomb-Rice decoding (ag_dec.c) -------------------------------

@(private)
QBSHIFT :: 9
@(private)
QB :: u32(1 << QBSHIFT)
@(private)
MMULSHIFT :: 2
@(private)
MDENSHIFT :: QBSHIFT - MMULSHIFT - 1
@(private)
MOFF :: u32(1 << (MDENSHIFT - 2))
@(private)
BITOFF :: 24
@(private)
MAX_PREFIX :: 9
@(private)
MAX_DATATYPE_BITS_16 :: 16
@(private)
N_MAX_MEAN_CLAMP :: 0xffff
@(private)
N_MEAN_CLAMP_VAL :: 0xffff

@(private)
AG_Params :: struct {
	mb0, pb, kb, wb: u32,
	max_run:         u32,
}

@(private)
make_ag_params :: #force_inline proc(m, p, k, max_run: u32) -> AG_Params {
	return {
		mb0     = m,
		pb      = p,
		kb      = k,
		wb      = (u32(1) << k) - 1,
		max_run = max_run,
	}
}

@(private)
lead :: #force_inline proc(m: u32) -> u32 {
	return intrinsics.count_leading_zeros(m)
}

@(private)
lg3a :: #force_inline proc(x: u32) -> u32 {
	return 31 - intrinsics.count_leading_zeros(x + 3)
}

@(private)
dyn_get :: #force_inline proc(r: ^common.Bit_Reader, m, k: u32, max_bits: int) -> u32 {
	common.refill_bits(r)
	pre := u32(intrinsics.count_leading_zeros(~r.cache))
	if pre >= MAX_PREFIX {
		common.skip_bits(r, MAX_PREFIX)
		return common.read_bits(r, max_bits)
	}
	common.skip_bits(r, int(pre + 1))
	if k <= 1 do return pre * m
	v := u32(r.cache >> (64 - k))
	if v >= 2 {
		common.skip_bits(r, int(k))
		return pre * m + v - 1
	}
	common.skip_bits(r, int(k - 1))
	return pre * m
}

@(private)
dyn_decomp :: proc(params: ^AG_Params, r: ^common.Bit_Reader, out: []i32, max_size: int) -> Error #no_bounds_check {
	num_samples := len(out)
	mb, pb, kb, wb := params.mb0, params.pb, params.kb, params.wb
	zmode: u32 = 0
	c := 0
	for c < num_samples {
		if r.left <= 0 do return .Invalid_Data
		m := mb >> QBSHIFT
		k := min(lg3a(m), kb)
		m = (u32(1) << k) - 1

		n := dyn_get(r, m, k, max_size)
		ndecode := n + zmode
		mag := i32((u64(ndecode) + 1) >> 1)
		out[c] = ndecode & 1 != 0 ? -mag : mag
		c += 1

		mb = pb * ndecode + mb - ((pb * mb) >> QBSHIFT)
		if n > N_MAX_MEAN_CLAMP do mb = N_MEAN_CLAMP_VAL
		zmode = 0

		if (mb << MMULSHIFT) < QB && c < num_samples {
			zmode = 1
			nz_k := lead(mb) - BITOFF + ((mb + MOFF) >> MDENSHIFT)
			mz := ((u32(1) << nz_k) - 1) & wb
			run := int(dyn_get(r, mz, nz_k, MAX_DATATYPE_BITS_16))
			if c + run > num_samples do return .Invalid_Data
			for j in 0 ..< run do out[c + j] = 0
			c += run
			if run >= 65535 do zmode = 0
			mb = 0
		}
	}
	if r.left < 0 do return .Invalid_Data
	return .None
}

// ---- Dynamic linear predictor (dp_dec.c) ------------------------------------

@(private)
sign_of_int :: #force_inline proc(x: i32) -> i32 {
	return i32(x > 0) - i32(x < 0)
}

@(private)
unpc_block :: proc(pc1, out: []i32, coefs: []i16, chan_bits: int, den_shift: u32, special_31 := false) #no_bounds_check {
	num := len(out)
	if num == 0 do return
	chanshift := uint(32 - chan_bits)
	out[0] = pc1[0]
	if special_31 {
		prev := out[0]
		for j in 1 ..< num {
			del := pc1[j] + prev
			prev = (del << chanshift) >> chanshift
			out[j] = prev
		}
		return
	}
	num_active := len(coefs)
	if num_active == 0 {
		if raw_data(pc1) != raw_data(out) do copy(out[1:], pc1[1:])
		return
	}
	if den_shift > 31 do return
	den_half := den_shift > 0 ? i32(1) << (den_shift - 1) : 0
	warm := min(num_active + 1, num)
	for j in 1 ..< warm {
		del := pc1[j] + out[j - 1]
		out[j] = (del << chanshift) >> chanshift
	}
	lim := num_active + 1
	switch num_active {
	case 4:
		a := [4]i16{coefs[0], coefs[1], coefs[2], coefs[3]}
		for j in lim ..< num {
			top := out[j - 5]
			b := [4]i32{top - out[j - 1], top - out[j - 2], top - out[j - 3], top - out[j - 4]}
			sum1 := (den_half - i32(a[0]) * b[0] - i32(a[1]) * b[1] - i32(a[2]) * b[2] - i32(a[3]) * b[3]) >> den_shift
			del := pc1[j]
			del0 := del
			sg := sign_of_int(del)
			out[j] = ((del + top + sum1) << chanshift) >> chanshift
			if sg != 0 {
				for k := 3; k >= 0; k -= 1 {
					sgn := sign_of_int(b[k]) * sg
					a[k] -= i16(sgn)
					if k > 0 {
						del0 -= i32(4 - k) * ((sgn * b[k]) >> den_shift)
						if del0 * sg <= 0 do break
					}
				}
			}
		}
		for k in 0 ..< 4 do coefs[k] = a[k]

	case 8:
		a := [8]i16{coefs[0], coefs[1], coefs[2], coefs[3], coefs[4], coefs[5], coefs[6], coefs[7]}
		for j in lim ..< num {
			top := out[j - 9]
			b := [8]i32{
				top - out[j - 1], top - out[j - 2], top - out[j - 3], top - out[j - 4],
				top - out[j - 5], top - out[j - 6], top - out[j - 7], top - out[j - 8],
			}
			sum1 := (den_half - i32(a[0]) * b[0] - i32(a[1]) * b[1] - i32(a[2]) * b[2] - i32(a[3]) * b[3] -
				i32(a[4]) * b[4] - i32(a[5]) * b[5] - i32(a[6]) * b[6] - i32(a[7]) * b[7]) >> den_shift
			del := pc1[j]
			del0 := del
			sg := sign_of_int(del)
			out[j] = ((del + top + sum1) << chanshift) >> chanshift
			if sg != 0 {
				for k := 7; k >= 0; k -= 1 {
					sgn := sign_of_int(b[k]) * sg
					a[k] -= i16(sgn)
					if k > 0 {
						del0 -= i32(8 - k) * ((sgn * b[k]) >> den_shift)
						if del0 * sg <= 0 do break
					}
				}
			}
		}
		for k in 0 ..< 8 do coefs[k] = a[k]

	case:
		for j in lim ..< num {
			top := out[j - lim]
			sum1: i32
			for k in 0 ..< num_active do sum1 += i32(coefs[k]) * (out[j - 1 - k] - top)
			del := pc1[j]
			del0 := del
			sg := sign_of_int(del)
			out[j] = ((del + top + ((sum1 + den_half) >> den_shift)) << chanshift) >> chanshift
			if sg != 0 {
				for k := num_active - 1; k >= 0; k -= 1 {
					dd := top - out[j - 1 - k]
					sgn := sign_of_int(dd) * sg
					coefs[k] -= i16(sgn)
					del0 -= i32(num_active - k) * ((sgn * dd) >> den_shift)
					if del0 * sg <= 0 do break
				}
			}
		}
	}
}

@(private)
be_u16 :: #force_inline proc(b: []u8) -> u16 {
	return u16(b[0]) << 8 | u16(b[1])
}

@(private)
be_u32 :: #force_inline proc(b: []u8) -> u32 {
	return u32(b[0]) << 24 | u32(b[1]) << 16 | u32(b[2]) << 8 | u32(b[3])
}
