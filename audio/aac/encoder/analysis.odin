package aac_encoder

import aac ".."
import "core:math"

@(private)
bandwidth_bands :: proc(offsets: []int, n, rate: int, hz: f64) -> int {
	cutoff := int(hz * f64(2 * n) / f64(rate))
	for i in 1 ..< len(offsets) do if offsets[i] >= cutoff do return i
	return len(offsets) - 1
}

@(private)
initialize_spreading :: proc(e: ^Encoder) {
	for short in 0 ..< 2 {
		offsets :=
			short == 0 ? aac.long_offsets(e.rate_index, e.frame_samples) : aac.short_offsets(e.rate_index, e.frame_samples)
		n := short == 0 ? e.frame_samples : e.frame_samples / 8
		bark: [64]f64
		for b in 0 ..< len(offsets) - 1 {
			hz := f64(offsets[b] + offsets[b + 1]) * f64(e.config.sample_rate) / f64(4 * n)
			bark[b] = 13 * math.atan(0.00076 * hz) + 3.5 * math.atan((hz / 7500) * (hz / 7500))
		}
		for b in 0 ..< len(offsets) - 1 do for source in 0 ..< len(offsets) - 1 {
			distance := bark[b] - bark[source]
			if b == source || abs(distance) > 4 do continue
			// Masking falls more rapidly toward lower frequencies. This
			// conservative energy envelope is our own band-domain model;
			// immutable weights are prepared once, shared by all channels.
			slope := distance > 0 ? 12.0 : 24.0
			value := 0.00015 * math.pow(10.0, -slope * abs(distance) / 10)
			if short == 0 {e.long_spread[b][source] = value} else {e.short_spread[b][source] = value}
		}
	}
}

@(private)
detect_attack :: proc(
	e: ^Encoder,
	pcm: []f32,
) -> (
	early_attack, late_attack: bool,
	energy, tail: [aac.MAX_CHANNELS]f64,
) {
	n, channels := e.frame_samples, e.config.channels
	step := n / 8
	for ch in 0 ..< channels {
		block: [8]f64
		previous := e.input_tail[ch]
		for w in 0 ..< 8 {
			for i in w * step ..< (w + 1) * step {
				value := f64(pcm[i * channels + ch])
				high := value - previous
				block[w] += high * high
				previous = value
			}
			block[w] /= f64(step)
		}
		mean: f64
		for value in block do mean += value / 8
		baseline := e.input_frames == 0 ? mean * 0.2 : e.input_energy[ch]
		for value, w in block {
			if !e.lfe[ch] && value > max(0.000001, baseline * 8) {
				if w < 5 {early_attack = true} else {late_attack = true}
			}
			// A low tail releases quickly; large attacks raise the history
			// gradually so the next attack is still visible.
			baseline = value < baseline ? 0.5 * (baseline + value) : 0.75 * baseline + 0.25 * value
		}
		energy[ch] = baseline; tail[ch] = previous
	}
	if e.options.disable_short_windows {early_attack = false; late_attack = false}
	return
}

@(private)
select_sequence :: proc(e: ^Encoder, next_short: bool) -> aac.Window_Sequence {
	if e.options.disable_short_windows do return .Long
	switch e.sequence {
	case .Start:
		return .Short
	case .Short:
		return e.pending_attack || next_short ? .Short : .Stop
	case .Long, .Stop:
		return next_short || (e.frames == 0 && e.pending_attack) ? .Start : .Long
	}
	return .Long
}

@(private)
select_groups :: proc(e: ^Encoder, sequence: aac.Window_Sequence) {
	e.group_length = {}; e.group_start = {}
	e.groups = 1; e.group_length[0] = 1
	e.stride = e.frame_samples; e.max_sfb = e.long_max_sfb
	if sequence != .Short do return
	e.stride = e.frame_samples / 8; e.max_sfb = e.short_max_sfb
	envelope: [8]f64
	offset := (e.frame_samples - e.stride) / 2
	for ch in 0 ..< e.config.channels do for w in 0 ..< 8 {
		total: f64
		for i in offset + w * e.stride ..< offset + (w + 2) * e.stride {
			value := i < e.frame_samples ? e.previous[ch][i] : e.pending[ch][i - e.frame_samples]
			total += value * value
		}
		envelope[w] = max(envelope[w], total)
	}
	for w in 1 ..< 8 {
		// Equal-energy windows share one set of scalefactors. An attack or
		// decay splits the data range; no task or temporary spectrum is made.
		similar :=
			max(envelope[w], envelope[w - 1]) <= max(1.0, min(envelope[w], envelope[w - 1]) * 1.8)
		if similar {e.group_length[e.groups - 1] += 1} else {
			e.group_start[e.groups] = w; e.group_length[e.groups] = 1; e.groups += 1
		}
	}
}

@(private)
prepare_tns :: proc(e: ^Encoder, ch: int, offsets: []int, short: bool) {
	if e.options.disable_tns do return
	end_band := min(e.max_sfb, aac.tns_max_bands(e.rate_index, short))
	start_band := 0
	for start_band < end_band && f64(offsets[start_band]) * f64(e.config.sample_rate) / f64(2 * e.stride) < 800 do start_band += 1
	if end_band - start_band < 3 do return
	start, end := offsets[start_band], offsets[end_band]
	for w in 0 ..< (short ? 8 : 1) {
		values := e.spectrum[ch][w * e.stride + start:w * e.stride + end]
		correlation: [5]f64
		for lag in 0 ..= 4 do for i in lag ..< len(values) do correlation[lag] += values[i] * values[i - lag]
		if correlation[0] < 1 do continue
		a, next: [5]f64
		reflection: [4]f64
		a[0] = 1
		error := correlation[0]
		order := 0
		for m in 1 ..= 4 {
			numerator := correlation[m]
			for j in 1 ..< m do numerator += a[j] * correlation[m - j]
			k := clamp(-numerator / max(error, 1.0), -0.92, 0.92)
			reflection[m - 1] = k
			for j in 1 ..< m do next[j] = a[j] + k * a[m - j]
			for j in 1 ..< m do a[j] = next[j]
			a[m] = k; error *= 1 - k * k; order = m
			if error < correlation[0] * 0.05 do break
		}
		if correlation[0] / max(error, 1.0) < 1.4 do continue
		filter := &e.tns[ch][w]
		filter.start_band = start_band; filter.order = order; filter.prediction[0] = 1
		// Quantize reflection coefficients using the decoder's normative
		// four-bit sine mapping, then derive the exact transmitted FIR.
		for j in 0 ..< order {
			best := 0; distance := max(f64)
			for q in -8 ..= 7 {
				k := e.tns_reflection[q + 8]
				if d := abs(k - reflection[j]); d < distance {best = q; distance = d}
			}
			filter.coefficient[j] = i8(best)
			k := e.tns_reflection[best + 8]
			m := j + 1
			for i in 1 ..< m do next[i] = filter.prediction[i] + k * filter.prediction[m - i]
			for i in 1 ..< m do filter.prediction[i] = next[i]
			filter.prediction[m] = k
		}
		history: [4]f64
		for &value in values {
			original := value
			for j in 0 ..< order do value += filter.prediction[j + 1] * history[j]
			for j := order - 1; j > 0; j -= 1 do history[j] = history[j - 1]
			history[0] = original
		}
		e.work_stats.tns_filters += 1
	}
}

@(private)
prepare_stereo :: proc(e: ^Encoder, offsets: []int) {
	for element in e.layout.elements[:e.layout.element_count] {
		if element.kind != .CPE do continue
		left, right := element.first_channel, element.first_channel + 1
		for g in 0 ..< e.groups do for b in 0 ..< e.max_sfb {
			l_energy, r_energy, cross: f64
			for w in e.group_start[g] ..< e.group_start[g] + e.group_length[g] do for k in offsets[b] ..< offsets[b + 1] {
				i := w * e.stride + k; l, r := e.spectrum[left][i], e.spectrum[right][i]
				l_energy += l * l; r_energy += r * r; cross += l * r
			}
			if l_energy < 1 || r_energy < 1 do continue
			hz := f64(offsets[b]) * f64(e.config.sample_rate) / f64(2 * e.stride)
			coherence := cross * cross / (l_energy * r_energy)
			if !e.options.disable_intensity && e.config.bit_rate / e.config.channels < 48000 && hz >= 6000 && coherence > 0.975 {
				scale := cross / l_energy
				position := int(math.round(-4 * math.log2(abs(scale))))
				if abs(position) <= 60 {
					e.tool[right][g][b] = scale < 0 ? 14 : 15
					e.base_sf[right][g][b] = position
					e.work_stats.intensity_bands += 1
					continue
				}
			}
			if e.options.disable_ms || coherence < 0.16 do continue
			mid := (l_energy + r_energy + 2 * cross) / 4
			side := (l_energy + r_energy - 2 * cross) / 4
			if min(mid, side) >= min(l_energy, r_energy) * 0.8 do continue
			e.ms[left][g][b] = true; e.work_stats.ms_bands += 1
			for w in e.group_start[g] ..< e.group_start[g] + e.group_length[g] do for k in offsets[b] ..< offsets[b + 1] {
				i := w * e.stride + k; l, r := e.spectrum[left][i], e.spectrum[right][i]
				e.spectrum[left][i] = (l + r) * 0.5; e.spectrum[right][i] = (l - r) * 0.5
			}
		}
	}
}

@(private)
prepare_bands :: proc(e: ^Encoder, offsets: []int, short: bool) {
	cursor := 0
	for g in 0 ..< e.groups do for b in 0 ..< e.max_sfb {
		e.band_start[g][b] = cursor
		cursor += (offsets[b + 1] - offsets[b]) * e.group_length[g]
	}
	for g in 0 ..< e.groups {
		peaks, derivative, kurtosis, tonal: [aac.MAX_CHANNELS][64]f64
		group_energy: [aac.MAX_CHANNELS]f64
		for ch in 0 ..< e.config.channels {
			if e.lfe[ch] do continue
			for b in 0 ..< e.max_sfb {
				if e.tool[ch][g][b] >= 14 {
					energy: f64
					for w in e.group_start[g] ..< e.group_start[g] + e.group_length[g] do for k in offsets[b] ..< offsets[b + 1] {
						value := e.spectrum[ch][w * e.stride + k]; energy += value * value
					}
					e.energy[ch][g][b] = energy
					group_energy[ch] += energy
					continue
				}
				stats: Band_Statistics
				packed := e.band_start[g][b]
				for w in e.group_start[g] ..< e.group_start[g] + e.group_length[g] {
					first, end := w * e.stride + offsets[b], w * e.stride + offsets[b + 1]
					count := end - first
					band_statistics_into(e.spectrum[ch][first:end], e.companded[ch][packed:packed + count], e.negative[ch][packed:packed + count], &stats)
					packed += count
				}
				energy, fourth, root, peak := stats.energy, stats.fourth, stats.root, stats.peak
				count := (offsets[b + 1] - offsets[b]) * e.group_length[g]
				e.energy[ch][g][b] = energy; peaks[ch][b] = peak; derivative[ch][b] = root * (4.0 / 27)
				group_energy[ch] += energy
				kurtosis[ch][b] = energy > 0 ? f64(count) * fourth / (energy * energy) : 0
				// Concentration is relative to this band's width: a four-bin
				// tone cannot attain the kurtosis of a sixteen-bin band.
				// Repeating the same spectrum across grouped short windows does
				// not change concentration within a frequency band.
				tonal[ch][b] = clamp((kurtosis[ch][b] - 1) / f64(max(4, offsets[b + 1] - offsets[b]) - 1), 0.0, 1.0)
			}
		}
		for element in e.layout.elements[:e.layout.element_count] do if element.kind == .CPE {
			left, right := element.first_channel, element.first_channel + 1
			pair_group := max(group_energy[left], group_energy[right])
			group_energy[left], group_energy[right] = pair_group, pair_group
		}
		for ch in 0 ..< e.config.channels {
			if e.lfe[ch] do continue
			for b in 0 ..< e.max_sfb {
				if e.tool[ch][g][b] >= 14 do continue
				// An energy envelope shared by the group keeps transform leakage
				// from receiving the same relative precision as its audible peak.
				// Its integrated noise allowance is bounded by group energy.
				count := (offsets[b + 1] - offsets[b]) * e.group_length[g]
				mean_energy := group_energy[ch] * f64(count) / f64(e.stride * e.group_length[g])
				effective := math.sqrt(e.energy[ch][g][b] * mean_energy)
				t := tonal[ch][b]
				threshold := max(1.0, effective * (0.0004 * (1 - t) + 0.00003 * t))
				threshold = max(threshold, mean_energy * 0.0002)
				e.threshold[ch][g][b] = threshold
			}
		}
		for element in e.layout.elements[:e.layout.element_count] do if element.kind == .CPE {
			left, right := element.first_channel, element.first_channel + 1
			for b in 0 ..< e.max_sfb do if e.ms[left][g][b] {
				shared := max(e.threshold[left][g][b], e.threshold[right][g][b])
				e.threshold[left][g][b], e.threshold[right][g][b] = shared, shared
			}
		}
		for ch in 0 ..< e.config.channels {
			if e.lfe[ch] do continue
			for b in 0 ..< e.max_sfb {
				if e.tool[ch][g][b] >= 14 do continue
				threshold := e.threshold[ch][g][b]
				for source in 0 ..< e.max_sfb do threshold += e.energy[ch][g][source] * (short ? e.short_spread[b][source] : e.long_spread[b][source])
				threshold *= 0.0625
				e.threshold[ch][g][b] = threshold
				peak := peaks[ch][b]
				sf := derivative[ch][b] > 0 ? int(math.floor(100 + (8.0 / 3) * math.log2(threshold / derivative[ch][b]))) : 100
				if peak > 0 do sf = max(sf, int(math.ceil(100 + 4 * math.log2(peak / 165113.494))))
				e.base_sf[ch][g][b] = clamp(sf, 0, 255)
				hz := f64(offsets[b]) * f64(e.config.sample_rate) / f64(2 * e.stride)
				width := offsets[b + 1] - offsets[b]
				if !e.options.disable_pns && e.config.bit_rate / e.config.channels < 48000 && hz >= 4000 && width >= 8 && kurtosis[ch][b] <= 5 && peak * peak * f64(width * e.group_length[g]) <= e.energy[ch][g][b] * 10 && e.energy[ch][g][b] > 1 {
					// A mid/side band must reconstruct before TNS; a single PNS
					// mid plane cannot carry the ordinary MS operation.
					ms_channel := ch
					for element in e.layout.elements[:e.layout.element_count] do if element.kind == .CPE && (ch == element.first_channel || ch == element.first_channel + 1) {ms_channel = element.first_channel; break}
					if !e.ms[ms_channel][g][b] {
						e.tool[ch][g][b] = 13
						e.base_sf[ch][g][b] = clamp(int(math.round(2 * math.log2(e.energy[ch][g][b] / f64(e.group_length[g])))), -100, 255)
						e.work_stats.pns_bands += 1
					}
				}
			}
		}
	}
}

@(private)
analyze_block :: proc(e: ^Encoder, sequence: aac.Window_Sequence) {
	select_groups(e, sequence)
	e.tool = {}; e.ms = {}; e.tns = {}; e.work_stats = {
		sequence = sequence,
	}
	offsets :=
		sequence == .Short ? aac.short_offsets(e.rate_index, e.frame_samples) : aac.long_offsets(e.rate_index, e.frame_samples)
	for ch in 0 ..< e.config.channels {
		copy(e.time[:e.frame_samples], e.previous[ch][:e.frame_samples])
		copy(e.time[e.frame_samples:2 * e.frame_samples], e.pending[ch][:e.frame_samples])
		aac.analysis(
			&e.transform,
			e.lfe[ch] ? .Long : sequence,
			e.lfe[ch] ? 0 : e.previous_shape,
			e.lfe[ch] ? 0 : e.options.window_shape,
			e.time[:2 * e.frame_samples],
			e.spectrum[ch][:e.frame_samples],
		)
		if !e.lfe[ch] do prepare_tns(e, ch, offsets, sequence == .Short)
	}
	prepare_stereo(e, offsets)
	prepare_bands(e, offsets, sequence == .Short)
	long := aac.long_offsets(e.rate_index, e.frame_samples)
	for ch in 0 ..< e.config.channels do if e.lfe[ch] {
		for i in 12 ..< e.frame_samples do e.spectrum[ch][i] = 0
		for b in 0 ..< e.lfe_max_sfb {
			stats: Band_Statistics
			band_statistics_into(e.spectrum[ch][long[b]:long[b + 1]], e.companded[ch][long[b]:long[b + 1]], e.negative[ch][long[b]:long[b + 1]], &stats)
			energy, derivative, peak := stats.energy, stats.root * (4.0 / 27), stats.peak
			threshold := max(1.0, energy * 0.0004)
			sf := derivative > 0 ? int(math.floor(100 + (8.0 / 3) * math.log2(threshold / derivative))) : 100
			if peak > 0 do sf = max(sf, int(math.ceil(100 + 4 * math.log2(peak / 165113.494))))
			e.base_sf[ch][0][b] = clamp(sf, 0, 255); e.energy[ch][0][b] = energy; e.threshold[ch][0][b] = threshold
		}
	}
}
