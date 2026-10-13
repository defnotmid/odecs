package opus

// Bit allocation (RFC 6716 4.3.3): the shape bits of every band in 1/8
// bits, its fine energy bits, and the band skipping, intensity and dual
// stereo decisions coded along the way.

@(private)
ALLOC_STEPS :: 6

@(private)
Allocation :: struct {
	pulses:        [NB_BANDS]int, // shape bits per band, 1/8 bit
	fine_quant:    [NB_BANDS]int, // fine energy bits per band and channel
	fine_priority: [NB_BANDS]int, // 0: first in the final energy pass
	coded_bands:   int,
	intensity:     int,
	dual_stereo:   bool,
	balance:       int,
}

@(private)
compute_allocation :: proc(a: ^Allocation, r: ^Range_Decoder, start, end: int, offsets, caps: ^[NB_BANDS]int, alloc_trim, total_bits, ch, lm: int) {
	total := max(total_bits, 0)
	skip_start := start
	skip_rsv := total >= 1 << BITRES ? 1 << BITRES : 0
	total -= skip_rsv
	intensity_rsv, dual_stereo_rsv := 0, 0
	if ch == 2 {
		intensity_rsv = int(LOG2_FRAC[end - start])
		if intensity_rsv > total {
			intensity_rsv = 0
		} else {
			total -= intensity_rsv
			dual_stereo_rsv = total >= 1 << BITRES ? 1 << BITRES : 0
			total -= dual_stereo_rsv
		}
	}
	thresh, trim_offset: [NB_BANDS]int
	for j in start ..< end {
		width := int(EBANDS[j + 1] - EBANDS[j])
		thresh[j] = max(ch << BITRES, (3 * width << uint(lm) << BITRES) >> 4)
		trim_offset[j] = ch * width * (alloc_trim - 5 - lm) * (end - j - 1) * (1 << uint(lm + BITRES)) >> 6
		// Single-coefficient bands get less shape resolution.
		if width << uint(lm) == 1 do trim_offset[j] -= ch << BITRES
	}
	vector_bits :: proc(q, j, ch, lm: int) -> int {
		return ch * int(EBANDS[j + 1] - EBANDS[j]) * int(BAND_ALLOCATION[q][j]) << uint(lm) >> 2
	}
	// The highest allocation vector that fits.
	lo, hi := 1, len(BAND_ALLOCATION) - 1
	for lo <= hi {
		done := false
		psum := 0
		mid := (lo + hi) >> 1
		for j := end - 1; j >= start; j -= 1 {
			bitsj := vector_bits(mid, j, ch, lm)
			if bitsj > 0 do bitsj = max(0, bitsj + trim_offset[j])
			bitsj += offsets[j]
			if bitsj >= thresh[j] || done {
				done = true
				psum += min(bitsj, caps[j])
			} else if bitsj >= ch << BITRES {
				psum += ch << BITRES
			}
		}
		if psum > total {
			hi = mid - 1
		} else {
			lo = mid + 1
		}
	}
	hi = lo
	lo -= 1
	bits1, bits2: [NB_BANDS]int
	for j in start ..< end {
		b1 := vector_bits(lo, j, ch, lm)
		b2 := hi >= len(BAND_ALLOCATION) ? caps[j] : vector_bits(hi, j, ch, lm)
		if b1 > 0 do b1 = max(0, b1 + trim_offset[j])
		if b2 > 0 do b2 = max(0, b2 + trim_offset[j])
		if lo > 0 do b1 += offsets[j]
		b2 += offsets[j]
		if offsets[j] > 0 do skip_start = j
		bits1[j] = b1
		bits2[j] = max(0, b2 - b1)
	}
	interpolate_bits(a, r, start, end, skip_start, &bits1, &bits2, &thresh, caps, total, skip_rsv, intensity_rsv, dual_stereo_rsv, ch, lm)
}

@(private)
interpolate_bits :: proc(a: ^Allocation, r: ^Range_Decoder, start, end, skip_start: int, bits1, bits2, thresh, caps: ^[NB_BANDS]int, total_bits, skip_rsv, intensity_reserve, dual_stereo_reserve, ch, lm: int) {
	total := total_bits
	intensity_rsv := intensity_reserve
	dual_stereo_rsv := dual_stereo_reserve
	alloc_floor := ch << BITRES
	stereo := ch > 1 ? 1 : 0
	log_m := lm << BITRES
	// Bisect the interpolation between the two vectors.
	lo, hi := 0, 1 << ALLOC_STEPS
	for _ in 0 ..< ALLOC_STEPS {
		mid := (lo + hi) >> 1
		psum := 0
		done := false
		for j := end - 1; j >= start; j -= 1 {
			tmp := bits1[j] + (mid * bits2[j] >> ALLOC_STEPS)
			if tmp >= thresh[j] || done {
				done = true
				psum += min(tmp, caps[j])
			} else if tmp >= alloc_floor {
				psum += alloc_floor
			}
		}
		if psum > total {
			hi = mid
		} else {
			lo = mid
		}
	}
	bits := &a.pulses
	psum := 0
	done := false
	for j := end - 1; j >= start; j -= 1 {
		tmp := bits1[j] + (lo * bits2[j] >> ALLOC_STEPS)
		if tmp < thresh[j] && !done {
			tmp = tmp >= alloc_floor ? alloc_floor : 0
		} else {
			done = true
		}
		tmp = min(tmp, caps[j])
		bits[j] = tmp
		psum += tmp
	}
	// Skip bands from the top while the coded flag says so.
	coded := end
	for ;; coded -= 1 {
		j := coded - 1
		if j <= skip_start {
			// Never skip the first band nor a boosted one; the reserve returns.
			total += skip_rsv
			break
		}
		left := total - psum
		percoeff := left / int(EBANDS[coded] - EBANDS[start])
		left -= int(EBANDS[coded] - EBANDS[start]) * percoeff
		rem := max(left - int(EBANDS[j] - EBANDS[start]), 0)
		band_width := int(EBANDS[coded] - EBANDS[j])
		band_bits := bits[j] + percoeff * band_width + rem
		// The flag is coded only above the band's threshold; below it, skipped.
		if band_bits >= max(thresh[j], alloc_floor + 1 << BITRES) {
			if range_bit_logp(r, 1) do break
			psum += 1 << BITRES
			band_bits -= 1 << BITRES
		}
		psum -= bits[j] + intensity_rsv
		if intensity_rsv > 0 do intensity_rsv = int(LOG2_FRAC[j - start])
		psum += intensity_rsv
		if band_bits >= alloc_floor {
			psum += alloc_floor
			bits[j] = alloc_floor
		} else {
			bits[j] = 0
		}
	}
	a.coded_bands = coded
	a.intensity = intensity_rsv > 0 ? start + int(range_uint(r, u32(coded + 1 - start))) : 0
	if a.intensity <= start {
		total += dual_stereo_rsv
		dual_stereo_rsv = 0
	}
	a.dual_stereo = dual_stereo_rsv > 0 ? range_bit_logp(r, 1) : false
	// The rest spread evenly over the coded bands.
	left := total - psum
	percoeff := left / int(EBANDS[coded] - EBANDS[start])
	left -= int(EBANDS[coded] - EBANDS[start]) * percoeff
	for j in start ..< coded do bits[j] += percoeff * int(EBANDS[j + 1] - EBANDS[j])
	for j in start ..< coded {
		tmp := min(left, int(EBANDS[j + 1] - EBANDS[j]))
		bits[j] += tmp
		left -= tmp
	}
	// Split each band's bits between fine energy and shape.
	ebits := &a.fine_quant
	balance := 0
	j := start
	for ; j < coded; j += 1 {
		n0 := int(EBANDS[j + 1] - EBANDS[j])
		n := n0 << uint(lm)
		bit := bits[j] + balance
		excess: int
		if n > 1 {
			excess = max(bit - caps[j], 0)
			bits[j] = bit - excess
			den := ch * n + (ch == 2 && n > 2 && !a.dual_stereo && j < a.intensity ? 1 : 0)
			nc_log_n := den * (int(LOG_N[j]) + log_m)
			// log2(N)/2 + FINE_OFFSET off the fair share of total/N.
			offset := (nc_log_n >> 1) - den * FINE_OFFSET
			if n == 2 do offset += den << BITRES >> 2
			// Second and third fine bits.
			if bits[j] + offset < den * 2 << BITRES {
				offset += nc_log_n >> 2
			} else if bits[j] + offset < den * 3 << BITRES {
				offset += nc_log_n >> 3
			}
			ebits[j] = max(0, bits[j] + offset + (den << (BITRES - 1)))
			ebits[j] = (ebits[j] / den) >> BITRES
			if ch * ebits[j] > bits[j] >> BITRES do ebits[j] = bits[j] >> uint(stereo) >> BITRES
			ebits[j] = min(ebits[j], MAX_FINE_BITS)
			// Rounded down or capped: a candidate for the final pass.
			a.fine_priority[j] = ebits[j] * (den << BITRES) >= bits[j] + offset ? 1 : 0
			bits[j] -= ch * ebits[j] << BITRES
		} else {
			excess = max(0, bit - (ch << BITRES))
			bits[j] = bit - excess
			ebits[j] = 0
			a.fine_priority[j] = 1
		}
		// What is over the cap goes to fine energy here.
		if excess > 0 {
			extra_fine := min(excess >> uint(stereo + BITRES), MAX_FINE_BITS - ebits[j])
			ebits[j] += extra_fine
			extra_bits := extra_fine * ch << BITRES
			a.fine_priority[j] = extra_bits >= excess - balance ? 1 : 0
			excess -= extra_bits
		}
		balance = excess
	}
	a.balance = balance
	for ; j < end; j += 1 {
		ebits[j] = bits[j] >> uint(stereo) >> BITRES
		bits[j] = 0
		a.fine_priority[j] = ebits[j] < 1 ? 1 : 0
	}
}
