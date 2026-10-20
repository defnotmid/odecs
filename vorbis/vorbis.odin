// Vorbis I audio decoding, written from the Vorbis I specification: the
// identification and setup headers into flat tables, then audio packets to
// interleaved f32 PCM. libvorbis is the oracle (tests/vorbis_compare.odin).
//
// The data: the setup is read once. Codebooks keep their Huffman tables and
// unpacked VQ vectors in shared pools, each book an offset into them. Floors,
// residues, mappings and modes are small records. Everything a packet needs
// (spectra, overlap, the transform's tables, scratch) is allocated by
// init_decoder; decoding a packet allocates nothing. A packet runs as one
// dataflow: floor Y values per channel, residue vectors into per-channel
// spectra, inverse coupling, each floor rendered as a multiply over its
// spectrum, the inverse MDCT, the window, overlap-add into the caller's PCM.
// Floor type 0 (unused by encoders since 2001) is not decoded.
package vorbis

import "base:intrinsics"
import "core:mem"

Error :: enum {
	None,
	Invalid,     // malformed headers or packet
	Unsupported, // floor type 0, or tables too large
	Out_Of_Memory,
}

Info :: struct {
	channels:  int,
	rate:      int,
	blocksize: [2]int, // short and long blocks
	bitrate:   int, // nominal, bits per second; 0 if unset
}

Decoder :: struct {
	using info: Info,
	setup:      Setup,
	transforms: [2]Transform,
	slopes:     [2][]f32, // each block size's rising window half
	spectra:    []f32, // channels planes of blocksize[1] / 2
	overlap:    []f32, // channels planes of blocksize[1] / 2: the previous block's right half
	time:       []f32, // one block of transform output
	interleave: []f32, // residue type 2's single vector
	classes:    []u8, // residue classifications, channels * partitions
	floor_y:    [][MAX_FLOOR_POINTS]i32, // per channel
	floor_used: []bool, // per channel
	previous:   int, // the previous block's size, 0 before the first packet
	allocator:  mem.Allocator,
}

// The identification header (the first packet).
read_identification :: proc(packet: []u8) -> (info: Info, err: Error) {
	if len(packet) < 30 || packet[0] != 1 || string(packet[1:7]) != "vorbis" do return info, .Invalid
	b := Bits{data = packet[7:]}
	if read(&b, 32) != 0 do return info, .Invalid // vorbis_version
	info.channels = int(read(&b, 8))
	info.rate = int(read(&b, 32))
	read(&b, 32)
	info.bitrate = int(i32(read(&b, 32)))
	read(&b, 32)
	info.blocksize = {1 << read(&b, 4), 1 << read(&b, 4)}
	if info.bitrate < 0 do info.bitrate = 0
	switch {
	case info.channels == 0 || info.rate == 0:
		return info, .Invalid
	case info.blocksize[0] < 64 || info.blocksize[1] > 8192 || info.blocksize[0] > info.blocksize[1]:
		return info, .Invalid
	case read(&b, 1) != 1 || b.overrun:
		return info, .Invalid // framing
	}
	return info, .None
}

// Reads the identification and setup headers (the first and third
// packets; the comment header between them is not needed) and allocates
// everything decoding needs.
init_decoder :: proc(d: ^Decoder, identification, setup: []u8, allocator := context.allocator) -> (err: Error) {
	d^ = {allocator = allocator}
	defer if err != .None do destroy_decoder(d)
	d.info = read_identification(identification) or_return
	read_setup(&d.setup, d.info, setup, allocator) or_return
	half := d.blocksize[1] / 2
	maxp := 0
	for r in d.setup.residues {
		size := r.type == 2 ? half * d.channels : half
		maxp = max(maxp, (min(r.end, size) - min(r.begin, size)) / r.partition_size)
	}
	e: [9]mem.Allocator_Error
	d.spectra, e[0] = make([]f32, d.channels * half, allocator)
	d.overlap, e[1] = make([]f32, d.channels * half, allocator)
	d.time, e[2] = make([]f32, d.blocksize[1], allocator)
	d.interleave, e[3] = make([]f32, d.channels * half, allocator)
	d.classes, e[4] = make([]u8, d.channels * (maxp + 64), allocator)
	d.floor_y, e[5] = make([][MAX_FLOOR_POINTS]i32, d.channels, allocator)
	d.floor_used, e[6] = make([]bool, d.channels, allocator)
	d.slopes[0], e[7] = make([]f32, d.blocksize[0] / 2, allocator)
	d.slopes[1], e[8] = make([]f32, d.blocksize[1] / 2, allocator)
	for x in e do if x != nil do return .Out_Of_Memory
	for k in 0 ..< 2 {
		init_transform(&d.transforms[k], d.blocksize[k], allocator) or_return
		window_slope(d.slopes[k])
	}
	return .None
}

destroy_decoder :: proc(d: ^Decoder) {
	a := d.allocator
	destroy_setup(&d.setup, a)
	for &t in d.transforms do destroy_transform(&t, a)
	delete(d.slopes[0], a)
	delete(d.slopes[1], a)
	delete(d.spectra, a)
	delete(d.overlap, a)
	delete(d.time, a)
	delete(d.interleave, a)
	delete(d.classes, a)
	delete(d.floor_y, a)
	delete(d.floor_used, a)
	d^ = {}
}

// Forgets the previous block, as after a seek: the next packet primes again
// and returns nothing.
reset :: proc(d: ^Decoder) {
	d.previous = 0
}

// The most frames one packet returns.
max_frames :: proc(d: ^Decoder) -> int {
	return d.blocksize[1] / 2
}

// An audio packet's block size, from its first bits; 0 if it is not one.
packet_blocksize :: proc(d: ^Decoder, packet: []u8) -> int {
	b := Bits{data = packet}
	if read(&b, 1) != 0 do return 0
	mode := int(read(&b, ilog(len(d.setup.modes) - 1)))
	if b.overrun || mode >= len(d.setup.modes) do return 0
	return d.blocksize[int(d.setup.modes[mode].long)]
}

// The frames a packet of block size `current` returns after one of size
// `previous` (0: none, the first packet returns nothing).
packet_frames :: proc(previous, current: int) -> int {
	return previous == 0 ? 0 : previous / 4 + current / 4
}

// A packet's bits, least significant first, through a 64-bit window. Past
// the end zeros are read and `overrun` is set: the specification's
// end-of-packet condition.
@(private)
Bits :: struct {
	data:    []u8,
	at:      int, // the next byte to load
	window:  u64,
	count:   int, // bits in the window
	overrun: bool,
}

@(private)
refill :: #force_inline proc "contextless" (b: ^Bits) #no_bounds_check {
	if b.at + 8 <= len(b.data) {
		// Bits past the whole bytes taken are the stream's own next bits:
		// loading them again later leaves the window as it is.
		b.window |= u64(intrinsics.unaligned_load((^u64le)(&b.data[b.at]))) << uint(b.count)
		n := (63 - b.count) >> 3
		b.at += n
		b.count += n * 8
		return
	}
	for b.count <= 56 && b.at < len(b.data) {
		b.window |= u64(b.data[b.at]) << uint(b.count)
		b.at += 1
		b.count += 8
	}
}

// n bits (up to 32) as an unsigned value.
@(private)
read :: #force_inline proc "contextless" (b: ^Bits, n: int) -> u32 {
	if b.count < n do refill(b)
	if b.count < n {
		b.overrun = true
		b.window, b.count = 0, 0
		return 0
	}
	v := u32(b.window & (1 << uint(n) - 1))
	b.window >>= uint(n)
	b.count -= n
	return v
}

// The bits needed for x: ilog(0) = 0, ilog(1) = 1, ilog(4) = 3.
@(private)
ilog :: proc "contextless" (x: int) -> int {
	return x <= 0 ? 0 : 64 - int(intrinsics.count_leading_zeros(u64(x)))
}
