package aac_decoder

import aac ".."
import "core:math"

@(private)
Coupling_Target :: struct {
	kind:                  aac.Element_Kind,
	tag:                   u8,
	left_list, right_list: int, // -1 means that side is not coupled
	channel:               int, // resolved encounter-order channel, after complete syntax
}

@(private)
Coupling_Gain :: struct {
	common: bool,
	value:  f64,
	band:   [8][64]f64,
}

@(private)
Coupling_Channel :: struct {
	tag:                      u8,
	independent, after_tns:   bool,
	target_count, list_count: int,
	target:                   [8]Coupling_Target,
	gain:                     [16]Coupling_Gain,
	channel:                  Channel,
}

// ISO/IEC 13818-7:2004, Table22 and §12.3. The first gain list is
// implicit unity; other lists share one gain or carry grouped band gains.
@(private)
read_coupling :: proc(d: ^Decoder, r: ^aac.Bit_Reader, cc: ^Coupling_Channel) {
	cc.tag = u8(read(r, 4))
	cc.independent = flag(r)
	cc.target_count = int(read(r, 3)) + 1
	cc.list_count = 0
	for &target, i in cc.target[:cc.target_count] {
		target.kind = flag(r) ? aac.Element_Kind.CPE : aac.Element_Kind.SCE
		target.tag = u8(read(r, 4))
		target.left_list, target.right_list = -1, -1
		for old in cc.target[:i] {
			if old.kind == target.kind && old.tag == target.tag {r.err = .Invalid_Data; return}
		}
		if target.kind == .SCE {
			target.left_list = cc.list_count; cc.list_count += 1
		} else {
			left, right := flag(r), flag(r)
			if !left && !right {
				target.left_list, target.right_list = cc.list_count, cc.list_count
				cc.list_count += 1
			} else {
				if left {target.left_list = cc.list_count; cc.list_count += 1}
				if right {target.right_list = cc.list_count; cc.list_count += 1}
			}
		}
	}
	cc.after_tns = flag(r)
	signed_gain := flag(r)
	scale := int(read(r, 2))
	cc.channel.spectrum = {}; cc.channel.tns_count = {}
	read_channel(d, r, &cc.channel, false)
	if r.err != .None do return
	// An embedded SCE has no intensity-stereo partner.
	for g in 0 ..< cc.channel.ics.groups do for b in 0 ..< cc.channel.ics.max_sfb {
		if cc.channel.codebook[g][b] >= 14 {r.err = .Invalid_Data; return}
	}
	step := 1.0 / f64(int(8) >> uint(scale))
	cc.gain[0].common, cc.gain[0].value = true, 1
	for list in 1 ..< cc.list_count {
		gain := &cc.gain[list]
		gain.common = cc.independent || flag(r)
		if gain.common {
			exponent := aac.read_huffman(r, &d.huffman, 0) - 60
			// Transmitted coupling gains use the inverse exponent. Literal
			// codeword controls cover this interoperability convention; printed
			// ISO coupling pseudocode editions disagree on its sign.
			gain.value = math.pow(2.0, -f64(exponent) * step)
		} else {
			accumulator := 0
			for g in 0 ..< cc.channel.ics.groups do for b in 0 ..< cc.channel.ics.max_sfb {
				gain.band[g][b] = 0
				if cc.channel.codebook[g][b] == 0 do continue
				delta := aac.read_huffman(r, &d.huffman, 0) - 60
				accumulator += delta
				negative := signed_gain && accumulator & 1 != 0
				exponent := accumulator
				if signed_gain {
					// ISO14496-3:2009 splits the accumulated raw gain, not each
					// delta. Arithmetic half stays defined for negative odd totals.
					exponent = accumulator < 0 ? -((-accumulator + 1) / 2) : accumulator / 2
				}
				value := math.pow(2.0, -f64(exponent) * step)
				if math.is_inf(value) || math.is_nan(value) {r.err = .Invalid_Data; return}
				gain.band[g][b] = negative ? -value : value
			}
		}
		if r.err != .None do return
	}
}

@(private)
resolve_coupling :: proc(d: ^Decoder) -> Error {
	f := &d.frame
	for &cc in d.coupling[:f.coupling_count] {
		for &target in cc.target[:cc.target_count] {
			found := false
			for element in f.element[:f.element_count] {
				if element.kind != target.kind || element.tag != target.tag do continue
				target.channel = element.first_channel; found = true
				break
			}
			if !found do return .Invalid_Data
			if !cc.independent {
				for side in 0 ..< (target.kind == .CPE ? 2 : 1) {
					list := side == 0 ? target.left_list : target.right_list
					if list < 0 do continue
					info := &d.channel[target.channel + side].ics
					if info.sequence != cc.channel.ics.sequence || info.shape != cc.channel.ics.shape do return .Invalid_Data
				}
			}
		}
		if f.explicit_layout {
			declared := false
			for entry in f.program.coupling[:f.program.coupling_count] {
				if entry.tag == cc.tag {
					if entry.independent != cc.independent do return .Invalid_Data
					declared = true; break
				}
			}
			if !declared do return .Invalid_Data
		}
	}
	return .None
}

@(private)
couple_spectrum :: proc(cc: ^Coupling_Channel, target: ^Channel, list, frame_samples: int) {
	gain := &cc.gain[list]
	info := &cc.channel.ics
	stride := info.sequence == .Short ? frame_samples / 8 : frame_samples
	window := 0
	for g in 0 ..< info.groups {
		for band in 0 ..< info.max_sfb {
			if cc.channel.codebook[g][band] == 0 do continue
			value := gain.common ? gain.value : gain.band[g][band]
			for w in 0 ..< info.group_length[g] {
				for k in info.offsets[band] ..< info.offsets[band + 1] {
					i := (window + w) * stride + k
					target.spectrum[i] += cc.channel.spectrum[i] * value
				}
			}
		}
		window += info.group_length[g]
	}
}

@(private)
couple_before_or_after_tns :: proc(d: ^Decoder, after_tns: bool) {
	for &cc in d.coupling[:d.frame.coupling_count] {
		if cc.independent || cc.after_tns != after_tns do continue
		for target in cc.target[:cc.target_count] {
			if target.left_list >= 0 do couple_spectrum(&cc, &d.channel[target.channel], target.left_list, d.frame_samples)
			if target.right_list >= 0 do couple_spectrum(&cc, &d.channel[target.channel + 1], target.right_list, d.frame_samples)
		}
	}
}
