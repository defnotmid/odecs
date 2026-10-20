package vorbis

import "core:mem"

// Decodes an audio packet into `pcm`, interleaved, returning the frames
// written: packet_frames(previous block size, this one), none for the first
// packet. `pcm` holds at least max_frames(d) * channels samples. A packet
// that is not audio returns no frames and leaves the state alone.
decode_packet :: proc(d: ^Decoder, packet: []u8, pcm: []f32) -> (frames: int, err: Error) #no_bounds_check {
	b := Bits{data = packet}
	if read(&b, 1) != 0 do return 0, .None
	s := &d.setup
	mode_index := int(read(&b, ilog(len(s.modes) - 1)))
	if b.overrun || mode_index >= len(s.modes) do return 0, .Invalid
	mode := s.modes[mode_index]
	n := d.blocksize[int(mode.long)]
	previous_long, next_long := true, true
	if mode.long {
		previous_long = read(&b, 1) == 1
		next_long = read(&b, 1) == 1
	}
	if b.overrun do return 0, .Invalid
	mapping := &s.mappings[mode.mapping]
	half, stride := n / 2, d.blocksize[1] / 2
	plane :: #force_inline proc(d: ^Decoder, ch, stride, half: int) -> []f32 {return d.spectra[ch * stride:][:half]}

	// Floors, channel by channel. An end of packet leaves the channel silent.
	for ch in 0 ..< d.channels {
		f := &s.floors[mapping.submap_floor[mapping.mux[ch]]]
		d.floor_used[ch] = decode_floor(s, f, &b, &d.floor_y[ch])
	}
	// A coupled pair is decoded if either of its channels is.
	decode_residue := d.floor_used[:d.channels]
	residue_wanted: [256]bool
	copy(residue_wanted[:d.channels], decode_residue)
	for k in 0 ..< mapping.couplings {
		m, a := mapping.magnitude[k], mapping.angle[k]
		if residue_wanted[m] || residue_wanted[a] do residue_wanted[m], residue_wanted[a] = true, true
	}
	// Residues, submap by submap, into the channels' planes.
	for sub in 0 ..< mapping.submaps {
		channels: [256]u8
		skip: [256]bool
		count := 0
		for ch in 0 ..< d.channels {
			if int(mapping.mux[ch]) != sub do continue
			channels[count], skip[count] = u8(ch), !residue_wanted[ch]
			count += 1
		}
		r := &s.residues[mapping.submap_residue[sub]]
		decode_residues(d, r, channels[:count], skip[:count], half, &b)
	}
	// Inverse coupling, last step first.
	for k := mapping.couplings - 1; k >= 0; k -= 1 {
		m := plane(d, int(mapping.magnitude[k]), stride, half)
		a := plane(d, int(mapping.angle[k]), stride, half)
		for i in 0 ..< half {
			mv, av := m[i], a[i]
			nm, na: f32
			if mv > 0 {
				if av > 0 {nm, na = mv, mv - av} else {nm, na = mv + av, mv}
			} else {
				if av > 0 {nm, na = mv, mv + av} else {nm, na = mv - av, mv}
			}
			m[i], a[i] = nm, na
		}
	}
	// Each channel: floor times residue, the inverse MDCT, the window, and
	// overlap-add with the previous block's right half.
	previous := d.previous
	frames = packet_frames(previous, n)
	short := d.blocksize[0]
	left_n := mode.long && !previous_long ? short / 2 : n / 2
	right_n := mode.long && !next_long ? short / 2 : n / 2
	left_start := n / 4 - left_n / 2
	right_start := n - n / 4 - right_n / 2
	left_slope := d.slopes[left_n == short / 2 ? 0 : 1]
	right_slope := d.slopes[right_n == short / 2 ? 0 : 1]
	for ch in 0 ..< d.channels {
		spectrum := plane(d, ch, stride, half)
		if d.floor_used[ch] {
			apply_floor(&s.floors[mapping.submap_floor[mapping.mux[ch]]], &d.floor_y[ch], spectrum)
		} else {
			mem.zero_slice(spectrum)
		}
		time := d.time[:n]
		imdct(&d.transforms[int(mode.long)], spectrum, time)
		// The window: zero, rising, one, falling, zero.
		mem.zero_slice(time[:left_start])
		for &v, i in time[left_start:][:left_n] do v *= left_slope[i]
		for i in 0 ..< right_n do time[right_start + i] *= right_slope[right_n - 1 - i]
		mem.zero_slice(time[right_start + right_n:])
		// From the previous block's centre to this block's.
		overlap := d.overlap[ch * stride:][:stride]
		if previous > 0 {
			shift := n / 4 - previous / 4 // this block's index of output sample 0
			for j in 0 ..< frames {
				v: f32
				if j < previous / 2 do v = overlap[j]
				if c := j + shift; c >= 0 do v += time[c]
				pcm[j * d.channels + ch] = v
			}
		}
		copy(overlap, time[n / 2:])
	}
	d.previous = n
	return frames, .None
}

// Floor 1's Y values for a channel; false if the channel is unused this
// packet (or the packet ended).
@(private)
decode_floor :: proc(s: ^Setup, f: ^Floor, b: ^Bits, y: ^[MAX_FLOOR_POINTS]i32) -> bool {
	if read(b, 1) == 0 do return false
	@(static, rodata) ranges := [4]int{256, 128, 86, 64}
	width := ilog(ranges[f.multiplier - 1] - 1)
	y[0], y[1] = i32(read(b, width)), i32(read(b, width))
	at := 2
	for class in f.partition_class[:f.partitions] {
		dims, subs := int(f.class_dims[class]), uint(f.class_subs[class])
		cval := 0
		if subs > 0 {
			cval = decode_entry(s, &s.books[f.class_master[class]], b)
			if cval < 0 do return false
		}
		for j in 0 ..< dims {
			book := f.subclass_books[class][cval & (1 << subs - 1)]
			cval >>= subs
			y[at + j] = 0
			if book >= 0 {
				v := decode_entry(s, &s.books[book], b)
				if v < 0 do return false
				y[at + j] = i32(v)
			}
		}
		at += dims
	}
	return !b.overrun
}

// The floor curve from its Y values (the specification's two steps: the
// values unwrapped against each point's prediction, then lines between the
// points in X order), multiplied into the spectrum as it is drawn.
@(private)
apply_floor :: proc(f: ^Floor, y: ^[MAX_FLOOR_POINTS]i32, spectrum: []f32) #no_bounds_check {
	@(static, rodata) ranges := [4]i32{256, 128, 86, 64}
	limit := ranges[f.multiplier - 1]
	final: [MAX_FLOOR_POINTS]i32
	drawn: [MAX_FLOOR_POINTS]bool
	final[0], final[1] = y[0], y[1]
	drawn[0], drawn[1] = true, true
	for i in 2 ..< f.points {
		lo, hi := int(f.low[i]), int(f.high[i])
		predicted := render_point(f.x[lo], final[lo], f.x[hi], final[hi], f.x[i])
		v := y[i]
		high_room, low_room := limit - predicted, predicted
		room := 2 * min(high_room, low_room)
		if v == 0 {
			final[i] = predicted
			continue
		}
		drawn[lo], drawn[hi], drawn[i] = true, true, true
		switch {
		case v >= room:
			final[i] = high_room > low_room ? v - low_room + predicted : predicted - v + high_room - 1
		case v & 1 == 1:
			final[i] = predicted - (v + 1) / 2
		case:
			final[i] = predicted + v / 2
		}
	}
	for &v in final[:f.points] do v = clamp(v, 0, limit - 1)
	n := i32(len(spectrum))
	mul := i32(f.multiplier)
	lx, ly := i32(0), final[f.sorted[0]] * mul
	hx, hy := lx, ly
	for k in 1 ..< f.points {
		i := f.sorted[k]
		if !drawn[i] do continue
		hx, hy = f.x[i], final[i] * mul
		render_line(lx, ly, hx, hy, spectrum)
		lx, ly = hx, hy
	}
	if hx < n do render_line(hx, hy, n, hy, spectrum)
}

@(private)
render_point :: #force_inline proc(x0, y0, x1, y1, x: i32) -> i32 {
	dy, adx := y1 - y0, x1 - x0
	off := abs(dy) * (x - x0) / adx
	return dy < 0 ? y0 - off : y0 + off
}

// The specification's integer line from (x0, y0) up to x1, each sample of
// the spectrum multiplied by the amplitude at its Y; samples past the
// spectrum are left out.
@(private)
render_line :: proc(x0, y0, x1, y1: i32, spectrum: []f32) #no_bounds_check {
	dy, adx := y1 - y0, x1 - x0
	ady := abs(dy)
	base := dy / adx
	sy := dy < 0 ? base - 1 : base + 1
	ady -= abs(base) * adx
	end := min(x1, i32(len(spectrum)))
	if x0 >= end do return
	y, err := y0, i32(0)
	spectrum[x0] *= INVERSE_DB[clamp(y, 0, 255)]
	for x in x0 + 1 ..< end {
		err += ady
		if err >= adx {
			err -= adx
			y += sy
		} else {
			y += base
		}
		spectrum[x] *= INVERSE_DB[clamp(y, 0, 255)]
	}
}

// A submap's residue vectors into the channels' planes (zero where not
// coded). Type 2 decodes one interleaved vector, then spreads it.
@(private)
decode_residues :: proc(d: ^Decoder, r: ^Residue, channels: []u8, skip: []bool, half: int, b: ^Bits) {
	stride := d.blocksize[1] / 2
	for ch in channels do mem.zero_slice(d.spectra[int(ch) * stride:][:half])
	if r.type != 2 {
		vectors: [256][]f32
		for ch, k in channels do vectors[k] = d.spectra[int(ch) * stride:][:half]
		residue_partitions(d, r, vectors[:len(channels)], skip, half, b)
		return
	}
	any := false
	for s in skip do any ||= !s
	if !any do return
	size := half * len(channels)
	v := d.interleave[:size]
	mem.zero_slice(v)
	vectors := [1][]f32{v}
	none := [1]bool{}
	residue_partitions(d, r, vectors[:], none[:], size, b)
	// Spread: vector element i * channels + k is channel k's element i.
	count := len(channels)
	for ch, k in channels {
		out := d.spectra[int(ch) * stride:][:half]
		for i in 0 ..< half do out[i] = v[i * count + k]
	}
}

// The partitions of one residue, pass by pass: the classifications are read
// in the first pass, then each pass decodes the partitions whose class has
// a book in it. An end of packet keeps what was decoded.
@(private)
residue_partitions :: proc(d: ^Decoder, r: ^Residue, vectors: [][]f32, skip: []bool, size: int, b: ^Bits) #no_bounds_check {
	s := &d.setup
	begin, end := min(r.begin, size), min(r.end, size)
	if end <= begin do return
	partitions := (end - begin) / r.partition_size
	classbook := &s.books[r.classbook]
	per_word := classbook.dimensions
	stride := len(d.classes) / d.channels
	if partitions > stride do return
	for pass in 0 ..< 8 {
		for p := 0; p < partitions; {
			if pass == 0 {
				for k in 0 ..< len(vectors) {
					if skip[k] do continue
					word := decode_entry(s, classbook, b)
					if word < 0 do return
					classes := d.classes[k * stride:]
					for i := per_word - 1; i >= 0; i -= 1 {
						if p + i < partitions do classes[p + i] = u8(word % r.classifications)
						word /= r.classifications
					}
				}
			}
			for i := 0; i < per_word && p < partitions; i += 1 {
				for v, k in vectors {
					if skip[k] do continue
					book := r.books[d.classes[k * stride + p]][pass]
					if book < 0 do continue
					if !decode_partition(s, &s.books[book], r.type, v, begin + p * r.partition_size, r.partition_size, b) do return
				}
				p += 1
			}
		}
	}
}

// One partition's VQ vectors added into v from offset: type 0 interleaves
// each vector's values by n / dimensions, types 1 and 2 lay them in order.
@(private)
decode_partition :: proc(s: ^Setup, c: ^Codebook, type: int, v: []f32, offset, n: int, b: ^Bits) -> bool #no_bounds_check {
	dims := c.dimensions
	values := s.values[c.values:]
	if type == 0 {
		step := n / dims
		for i in 0 ..< step {
			e := decode_entry(s, c, b)
			if e < 0 do return false
			for j in 0 ..< dims do if at := offset + i + j * step; at < len(v) do v[at] += values[e * dims + j]
		}
		return true
	}
	for i := 0; i < n; {
		e := decode_entry(s, c, b)
		if e < 0 do return false
		vec := values[e * dims:][:dims]
		for x in vec {
			if offset + i < len(v) do v[offset + i] += x
			i += 1
		}
	}
	return true
}
