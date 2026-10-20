package audio

import ogg "../ogg"
import vorbis "../vorbis"
import "core:bytes"
import "core:mem"

// Ogg Vorbis: the packets indexed by the Ogg reader, the output sized
// before any decoding. Each audio packet's block size is in its first
// bits, which the index already holds, so the frames each packet returns
// are known; the granule positions then place them: the first page's
// granule tells where the stream starts (a negative start trims samples
// from the beginning) and the last page's where it ends (trimming the
// final block).
@(private)
decode_vorbis :: proc(data: []u8, allocator: mem.Allocator) -> (out: Audio, err: Error) {
	reader: bytes.Reader
	bytes.reader_init(&reader, data)
	r: ogg.Reader
	if ogg.open_stream(&r, bytes.reader_to_stream(&reader), "\x01vorbis") != .None do return out, .Invalid
	defer ogg.close(&r)
	if len(r.packets) < 3 do return out, .Invalid
	// The packets are borrowed until the next read: the identification copied.
	first, e1 := ogg.read_packet(&r, 0)
	if e1 != .None || len(first) > 64 do return out, .Invalid
	identification: [64]u8
	copy(identification[:], first)
	setup, e2 := ogg.read_packet(&r, 2)
	if e2 != .None do return out, .Invalid
	d: vorbis.Decoder
	if e := vorbis.init_decoder(&d, identification[:len(first)], setup, allocator); e != .None {
		return out, e == .Out_Of_Memory ? .Out_Of_Memory : e == .Unsupported ? .Unsupported : .Invalid
	}
	defer vorbis.destroy_decoder(&d)
	// The frames every packet returns, and the positions the pages give.
	produced := 0
	previous := 0
	first_granule, end := -1, -1 // granule positions: the first page's (with what it completes) and the last's
	first_produced := 0
	for i in 3 ..< len(r.packets) {
		lead := r.packets.lead[i]
		n := vorbis.packet_blocksize(&d, lead[:])
		if n > 0 {
			produced += vorbis.packet_frames(previous, n)
			previous = n
		}
		if g := int(r.packets.granule[i]); g >= 0 {
			if first_granule < 0 do first_granule, first_produced = g, produced
			end = g
		}
	}
	// The PCM position of output frame 0. A stream on one page has only an
	// end to trim.
	start := 0
	if first_granule >= 0 && first_granule != end do start = first_granule - first_produced
	// Output frame i is at position start + i; positions before 0 and from
	// the last granule on are dropped.
	first_kept := max(0, -start)
	last_kept := produced
	if end >= 0 do last_kept = clamp(end - start, first_kept, produced)
	frames := last_kept - first_kept
	channels := d.channels
	if frames * channels > MAX_SAMPLES do return out, .Unsupported
	samples, aerr := make([]f32, frames * channels, allocator)
	if aerr != nil do return out, .Out_Of_Memory
	scratch, serr := make([]f32, vorbis.max_frames(&d) * channels, allocator)
	if serr != nil {
		delete(samples, allocator)
		return out, .Out_Of_Memory
	}
	defer delete(scratch, allocator)
	at := 0 // output frames produced so far, before trimming
	for i in 3 ..< len(r.packets) {
		if at >= last_kept do break
		packet, pe := ogg.read_packet(&r, i)
		if pe != .None do break
		got, _ := vorbis.decode_packet(&d, packet, scratch)
		// Frames [at, at + got) of the untrimmed output; keep the overlap
		// with [first_kept, last_kept).
		lo, hi := max(at, first_kept), min(at + got, last_kept)
		if lo < hi do copy(samples[(lo - first_kept) * channels:], scratch[(lo - at) * channels:(hi - at) * channels])
		at += got
	}
	return {rate = d.rate, channels = channels, samples = samples}, .None
}
