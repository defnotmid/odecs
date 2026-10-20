package opus

import "base:intrinsics"

// The range decoder (RFC 6716 4.1): symbols from the front of a frame, raw
// bits from its back. Positions are in bits; tell_frac in 1/8 bits.

BITRES :: 3 // tell_frac's resolution: 1/8 bit

@(private)
CODE_BITS :: 32
@(private)
SYM_BITS :: 8
@(private)
CODE_TOP :: u32(1) << (CODE_BITS - 1)
@(private)
CODE_BOT :: CODE_TOP >> SYM_BITS
@(private)
CODE_EXTRA :: (CODE_BITS - 2) % SYM_BITS + 1
@(private)
UINT_BITS :: 8

Range_Decoder :: struct {
	data:        []u8,
	offs:        int, // next byte from the front
	end_offs:    int, // bytes taken from the back
	end_window:  u32,
	nend_bits:   int,
	nbits_total: int,
	rng, val:    u32,
	ext:         u32, // the scale of the last decode()
	rem:         u32, // the last byte read, for its leftover bits
	error:       bool,
}

// Number of bits needed for x (0 for 0).
@(private)
ilog :: #force_inline proc "contextless" (x: u32) -> int {
	return 32 - int(intrinsics.count_leading_zeros(x))
}

range_init :: proc(r: ^Range_Decoder, data: []u8) {
	r^ = {
		data        = data,
		nbits_total = CODE_BITS + 1 - ((CODE_BITS - CODE_EXTRA) / SYM_BITS) * SYM_BITS,
		rng         = 1 << CODE_EXTRA,
	}
	r.rem = u32(read_byte(r))
	r.val = r.rng - 1 - (r.rem >> (SYM_BITS - CODE_EXTRA))
	normalize(r)
}

@(private)
read_byte :: #force_inline proc(r: ^Range_Decoder) -> u8 {
	if r.offs >= len(r.data) do return 0
	r.offs += 1
	return r.data[r.offs - 1]
}

@(private)
normalize :: #force_inline proc(r: ^Range_Decoder) {
	for r.rng <= CODE_BOT {
		r.nbits_total += SYM_BITS
		r.rng <<= SYM_BITS
		sym := r.rem
		r.rem = u32(read_byte(r))
		sym = (sym << SYM_BITS | r.rem) >> (SYM_BITS - CODE_EXTRA)
		r.val = ((r.val << SYM_BITS) + (0xFF & ~sym)) & (CODE_TOP - 1)
	}
}

// The cumulative frequency of the next symbol out of ft; update() must follow.
range_decode :: proc(r: ^Range_Decoder, ft: u32) -> u32 {
	r.ext = r.rng / ft
	s := r.val / r.ext
	return ft - min(s + 1, ft)
}

// As range_decode with ft = 1 << bits.
range_decode_bin :: proc(r: ^Range_Decoder, bits: uint) -> u32 {
	r.ext = r.rng >> bits
	s := r.val / r.ext
	return (u32(1) << bits) - min(s + 1, u32(1) << bits)
}

range_update :: proc(r: ^Range_Decoder, fl, fh, ft: u32) {
	s := r.ext * (ft - fh)
	r.val -= s
	r.rng = fl > 0 ? r.ext * (fh - fl) : r.rng - s
	normalize(r)
}

// A bit whose probability of being 1 is 1/2^logp.
range_bit_logp :: proc(r: ^Range_Decoder, logp: uint) -> bool {
	s := r.rng >> logp
	one := r.val < s
	if !one do r.val -= s
	r.rng = one ? s : r.rng - s
	normalize(r)
	return one
}

// A symbol from an inverse CDF table whose total is 1 << ftb.
range_icdf :: proc(r: ^Range_Decoder, icdf: []u8, ftb: uint) -> int {
	s := r.rng
	d := r.val
	q := s >> ftb
	k := -1
	t: u32
	for {
		k += 1
		t = s
		s = q * u32(icdf[k])
		if d >= s do break
	}
	r.val = d - s
	r.rng = t - s
	normalize(r)
	return k
}

// A uniform value in 0 ..< ft (ft > 1): the top 8 bits range coded, the
// rest raw.
range_uint :: proc(r: ^Range_Decoder, total: u32) -> u32 {
	ft := total - 1
	ftb := ilog(ft)
	if ftb > UINT_BITS {
		ftb -= UINT_BITS
		top := (ft >> uint(ftb)) + 1
		s := range_decode(r, top)
		range_update(r, s, s + 1, top)
		t := s << uint(ftb) | range_bits(r, uint(ftb))
		if t <= ft do return t
		r.error = true
		return ft
	}
	ft += 1
	s := range_decode(r, ft)
	range_update(r, s, s + 1, ft)
	return s
}

// Raw bits from the end of the frame, least significant first.
range_bits :: proc(r: ^Range_Decoder, bits: uint) -> u32 {
	window := r.end_window
	available := r.nend_bits
	if uint(available) < bits {
		for {
			b: u32
			if r.end_offs < len(r.data) {
				r.end_offs += 1
				b = u32(r.data[len(r.data) - r.end_offs])
			}
			window |= b << uint(available)
			available += SYM_BITS
			if available > 32 - SYM_BITS do break
		}
	}
	v := window & ((u32(1) << bits) - 1)
	window >>= bits
	available -= int(bits)
	r.end_window = window
	r.nend_bits = available
	r.nbits_total += int(bits)
	return v
}

// Bits used so far, rounded up.
range_tell :: #force_inline proc(r: ^Range_Decoder) -> int {
	return r.nbits_total - ilog(r.rng)
}

// Bits used so far in 1/8 bits.
range_tell_frac :: proc(r: ^Range_Decoder) -> int {
	@(static, rodata)
	CORRECTION := [8]u32{35733, 38967, 42495, 46340, 50535, 55109, 60097, 65535}
	nbits := r.nbits_total << BITRES
	l := ilog(r.rng)
	x := r.rng >> uint(l - 16)
	b := (x >> 12) - 8
	if x > CORRECTION[b] do b += 1
	return nbits - (l << 3 + int(b))
}

// The Laplace-distributed coarse energy residual (RFC 6716 4.3.2.1): fs is
// the probability of 0 in Q15, decay the ratio between neighbours in Q14.
range_laplace :: proc(r: ^Range_Decoder, p0: u32, decay: u32) -> int {
	MIN_P :: 1
	N_MIN :: 16
	fs := p0
	val := 0
	fm := range_decode_bin(r, 15)
	fl: u32
	if fm >= fs {
		val += 1
		fl = fs
		fs = ((32768 - MIN_P * (2 * N_MIN) - fs) * (16384 - decay) >> 15) + MIN_P
		for fs > MIN_P && fm >= fl + 2 * fs {
			fs *= 2
			fl += fs
			fs = ((fs - 2 * MIN_P) * decay >> 15) + MIN_P
			val += 1
		}
		if fs <= MIN_P {
			di := (fm - fl) >> 1 // log2(MIN_P) + 1
			val += int(di)
			fl += 2 * di * MIN_P
		}
		if fm < fl + fs {
			val = -val
		} else {
			fl += fs
		}
	}
	range_update(r, fl, min(fl + fs, 32768), 32768)
	return val
}
