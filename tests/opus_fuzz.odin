// Fuzzes the Opus parsers under AddressSanitizer: mutated packets from an
// opus_demo .bit stream into the decoder, with losses (some recovered by
// FEC) between them;
// mutated multistream packets of a surround file, and random ones with
// random layouts, into the multistream decoder; mutated copies of an Ogg
// Opus file into ogg.Reader and the packet/head parsers.
//
//   odin build tests/opus_fuzz.odin -file -sanitize:address -debug -out:fuzz
//   fuzz VECTOR.bit FILE.opus SURROUND.opus [ROUNDS]
package main

import ogg "../ogg"
import opus "../opus"
import "core:bytes"
import "core:fmt"
import "core:io"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:strconv"

mutate :: proc(data: []u8) {
	if len(data) == 0 do return
	switch rand.int_max(3) {
	case 0:
		for _ in 0 ..< 1 + rand.int_max(4) do data[rand.int_max(len(data))] ~= u8(1 << uint(rand.int_max(8)))
	case 1:
		data[rand.int_max(len(data))] = u8(rand.int_max(256))
	case 2:
		at := rand.int_max(len(data))
		for i in at ..< min(len(data), at + 8) do data[i] = u8(rand.int_max(256))
	}
}

main :: proc() {
	if len(os.args) < 4 {fmt.eprintln("usage: fuzz VECTOR.bit FILE.opus SURROUND.opus [ROUNDS]"); os.exit(2)}
	rounds := 2000
	if len(os.args) > 4 do rounds, _ = strconv.parse_int(os.args[4])
	bit, e1 := os.read_entire_file(os.args[1], context.allocator)
	file, e2 := os.read_entire_file(os.args[2], context.allocator)
	if e1 != nil || e2 != nil do os.exit(1)
	// The surround file's head and packets.
	surround: [dynamic][]u8
	head: opus.Head
	{
		r: ogg.Reader
		if ogg.open(&r, os.args[3], "OpusHead") != .None do os.exit(1)
		h, _ := ogg.read_packet(&r, 0)
		he: opus.Error
		head, he = opus.parse_head(h)
		if he != .None do os.exit(1)
		// read_packet reuses its buffer: keep copies.
		for i in 2 ..< len(r.packets) do if data, e := ogg.read_packet(&r, i); e == .None do append(&surround, slice.clone(data))
		ogg.close(&r)
	}
	packets: [dynamic][]u8
	for at := 0; at + 8 <= len(bit); {
		size := int(u32(bit[at]) << 24 | u32(bit[at + 1]) << 16 | u32(bit[at + 2]) << 8 | u32(bit[at + 3]))
		at += 8
		if size > len(bit) - at do break
		append(&packets, bit[at:][:size])
		at += size
	}
	pcm := make([]f32, opus.MAX_FRAME_SAMPLES * 255)
	scratch := make([]u8, 1500 * 8)
	decoded, refused := 0, 0
	for round in 0 ..< rounds {
		// A run of packets, some mutated, through one decoder.
		d: opus.Decoder
		opus.init_decoder(&d, 1 + round % 2)
		start := rand.int_max(len(packets))
		for k in 0 ..< 40 {
			p := packets[(start + k) % len(packets)]
			q := scratch[:len(p)]
			copy(q, p)
			if rand.int_max(4) == 0 do mutate(q)
			if rand.int_max(16) == 0 do q = q[:rand.int_max(len(q) + 1)]
			gap := 120 * (1 + rand.int_max(48))
			switch rand.int_max(10) {
			case 0:
				opus.decode_lost(&d, gap, pcm)
			case 1:
				opus.decode_fec(&d, q, gap, pcm)
			}
			_, err := opus.decode_packet(&d, q, pcm)
			if err == .None {decoded += 1} else {refused += 1}
		}
		// Surround packets, some mutated or lost.
		{
			m: opus.Multistream
			opus.init_multistream(&m, head)
			at := rand.int_max(len(surround))
			for k in 0 ..< 20 {
				p := surround[(at + k) % len(surround)]
				q := scratch[:len(p)]
				copy(q, p)
				if rand.int_max(3) == 0 do mutate(q)
				if rand.int_max(16) == 0 do q = q[:rand.int_max(len(q) + 1)]
				if rand.int_max(10) == 0 {
					opus.decode_multistream_lost(&m, 120 * (1 + rand.int_max(48)), pcm)
				} else if rand.int_max(10) == 0 {
					opus.decode_multistream_fec(&m, q, 120 * (1 + rand.int_max(48)), pcm)
				} else if _, err := opus.decode_multistream(&m, q, pcm); err == .None {decoded += 1} else {refused += 1}
			}
			opus.destroy_multistream(&m)
		}
		// Random bytes through a random layout.
		{
			h: opus.Head
			h.streams = 1 + rand.int_max(4)
			h.coupled = rand.int_max(h.streams + 1)
			h.channels = 1 + rand.int_max(8)
			for &c in h.mapping[:h.channels] do c = rand.int_max(8) == 0 ? 255 : u8(rand.int_max(h.streams + h.coupled))
			m: opus.Multistream
			if opus.init_multistream(&m, h) == .None {
				junk := scratch[:rand.int_max(200)]
				for &b in junk do b = u8(rand.int_max(256))
				opus.decode_multistream(&m, junk, pcm)
				opus.destroy_multistream(&m)
			}
		}
		// Random bytes as a packet and as a head.
		junk := scratch[:rand.int_max(64)]
		for &b in junk do b = u8(rand.int_max(256))
		opus.decode_packet(&d, junk, pcm)
		opus.parse_packet(junk, true)
		opus.parse_head(junk)
		opus.packet_samples(junk)
		// A mutated Ogg file.
		f := make([]u8, len(file))
		copy(f, file)
		for _ in 0 ..< 1 + rand.int_max(6) {
			rest := f[rand.int_max(len(f)):]
			mutate(rest[:min(len(rest), 64)])
		}
		if rand.int_max(8) == 0 do f = f[:rand.int_max(len(f) + 1)]
		buf: bytes.Reader
		stream := bytes.reader_init(&buf, f)
		r: ogg.Reader
		if ogg.open_stream(&r, io.Stream(stream), "OpusHead") == .None {
			for i in 0 ..< len(r.packets) do if data, e := ogg.read_packet(&r, i); e == .None do opus.packet_samples(data)
			ogg.close(&r)
		}
		delete(f)
	}
	fmt.printfln("%d rounds: %d packets decoded, %d refused; no faults", rounds, decoded, refused)
}
