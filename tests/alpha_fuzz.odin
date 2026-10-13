// Mutation fuzzing of the alpha-video input paths: the QuickTime and WebM
// demuxers, the ProRes and VP9 decoders on mutated packets, and movie.Reader
// end to end on mutated files. Every input must be accepted or refused with
// an error; a crash, bounds failure or sanitizer report fails the run.
//
//   odin build tests/alpha_fuzz.odin -file -o:speed -sanitize:address -out:/tmp/odecs-alpha-fuzz
//   /tmp/odecs-alpha-fuzz ITERATIONS FIXTURE...
package alpha_fuzz

import mp4 "../codec/container/mp4"
import flac "../codec/flac"
import mp3 "../codec/mp3"
import wav "../codec/container/wav"
import webm "../codec/container/webm"
import movie "../codec/movie"
import prores "../codec/prores/decoder"
import vp9 "../codec/vp9/decoder"
import "core:fmt"
import "core:math/rand"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"

// Flips bits, overwrites bytes with boundary values, truncates, or repeats
// a span; usually a few edits so most of the structure survives.
mutate :: proc(src: []u8, out: ^[dynamic]u8) {
	clear(out)
	append(out, ..src)
	if len(out) == 0 do return
	for _ in 0 ..< 1 + rand.int_max(4) {
		n := len(out)
		if n == 0 do return
		at := rand.int_max(n)
		switch rand.int_max(6) {
		case 0:
			out[at] ~= u8(1) << uint(rand.int_max(8))
		case 1:
			values := [?]u8{0, 1, 0x7F, 0x80, 0xFE, 0xFF}
			out[at] = values[rand.int_max(len(values))]
		case 2:
			resize(out, at) // truncate
		case 3:
			span: [64]u8 // copied first: injecting reallocates the array
			count := copy(span[:min(rand.int_max(64) + 1, n - at)], out[at:])
			inject_at_elems(out, rand.int_max(n), ..span[:count])
		case 4:
			out[at] = u8(rand.int_max(256))
		case 5:
			// Corrupt a 32-bit size field-sized run.
			for k in 0 ..< min(4, n - at) do out[at + k] = u8(rand.int_max(256))
		}
	}
}

main :: proc() {
	if len(os.args) < 3 {fmt.eprintln("usage: alpha_fuzz ITERATIONS FIXTURE..."); os.exit(2)}
	iterations, _ := strconv.parse_int(os.args[1])
	rand.reset(0x5EED)
	buffer: [dynamic]u8
	for path in os.args[2:] {
		file, err := os.read_entire_file(path, context.allocator)
		if err != nil {fmt.eprintln("cannot read", path); os.exit(2)}
		// Matroska (.mkv) shares the WebM demuxer; its H.264/H.265 packets
		// are not mutated here, but movie.Reader runs on it more often.
		is_mkv := strings.has_suffix(path, ".mkv")
		is_webm := is_mkv || strings.has_suffix(path, ".webm")
		is_wav := strings.has_suffix(path, ".wav")
		is_flac := strings.has_suffix(path, ".flac")
		is_mp3 := strings.has_suffix(path, ".mp3")
		flac_info: flac.Stream_Info
		// Valid packets of the file, to mutate one at a time.
		packets: [dynamic][]u8
		alphas: [dynamic][]u8
		if is_mp3 {
			r: mp3.Reader
			if mp3.open(&r, path) == .None {
				for i in 0 ..< len(r.frames) {
					p, _ := mp3.read_frame(&r, i)
					c := make([]u8, len(p))
					copy(c, p)
					append(&packets, c)
				}
				mp3.close(&r)
			}
		} else if is_flac {
			r: flac.Reader
			if flac.open(&r, path) == .None {
				flac_info = r.info
				for {
					p, e := flac.read_frame(&r)
					if e != .None do break
					c := make([]u8, len(p.data))
					copy(c, p.data)
					append(&packets, c)
				}
				flac.close(&r)
			}
		} else if is_webm {
			r: webm.Reader
			if webm.open(&r, path) == .None {
				if r.tracks[0].codec == .VP9 do for i in 0 ..< len(r.tracks[0].samples) {
					p, _ := webm.read_sample(&r, 0, i)
					c := make([]u8, len(p.data))
					copy(c, p.data)
					append(&packets, c)
					a := make([]u8, len(p.additional))
					copy(a, p.additional)
					append(&alphas, a)
				}
				webm.close(&r)
			}
		} else {
			r: mp4.Reader
			if mp4.open(&r, path) == .None {
				for t, ti in r.tracks do if t.codec == .ProRes {
					for i in 0 ..< len(t.samples) {
						p, _ := mp4.read_sample(&r, ti, i)
						c := make([]u8, len(p.data))
						copy(c, p.data)
						append(&packets, c)
					}
					break
				}
				mp4.close(&r)
			}
		}
		refused := [3]int{}
		leaked := 0
		parent := context.allocator
		for it in 0 ..< iterations {
			// Everything the code under test allocates in a round must be
			// released by its close/destroy calls.
			track: mem.Tracking_Allocator
			mem.tracking_allocator_init(&track, parent)
			context.allocator = mem.tracking_allocator(&track)
			defer {
				context.allocator = parent
				leaked += len(track.allocation_map)
				mem.tracking_allocator_destroy(&track)
			}
			// The mutation buffer belongs to the harness.
			buffer.allocator = parent
			// 1. Container parsing on a mutated file.
			mutate(file, &buffer)
			m := mp4.Memory_Stream{data = buffer}
			if is_mp3 {
				r: mp3.Reader
				if mp3.open_stream(&r, mp4.memory_stream(&m)) == .None {
					d := new(mp3.Decoder)
					for i in 0 ..< min(len(r.frames), 256) {
						if p, e := mp3.read_frame(&r, i); e == .None do mp3.decode_frame(d, p)
					}
					free(d)
					mp3.close(&r)
				} else {
					refused[0] += 1
				}
			} else if is_flac {
				r: flac.Reader
				if flac.open_stream(&r, mp4.memory_stream(&m)) == .None {
					d: flac.Decoder
					flac.init_decoder(&d, r.info)
					for _ in 0 ..< 256 {
						p, e := flac.read_frame(&r)
						if e != .None do break
						flac.decode_frame(&d, p.data)
					}
					flac.seek(&r, i64(rand.int_max(1 << 20)))
					flac.read_frame(&r)
					flac.destroy_decoder(&d)
					flac.close(&r)
				} else {
					refused[0] += 1
				}
			} else if is_wav {
				r: wav.Reader
				if wav.open_stream(&r, mp4.memory_stream(&m)) == .None {
					for first: i64 = 0; first < r.frames; first += 1000 do wav.read_frames(&r, first, 1000)
					wav.close(&r)
				} else {
					refused[0] += 1
				}
			} else if is_webm {
				r: webm.Reader
				if webm.open_stream(&r, mp4.memory_stream(&m)) == .None {
					for &t, ti in r.tracks do for i in 0 ..< len(t.samples) do webm.read_sample(&r, ti, i)
					webm.close(&r)
				} else {
					refused[0] += 1
				}
			} else {
				r: mp4.Reader
				if mp4.open_stream(&r, mp4.memory_stream(&m)) == .None {
					for &t, ti in r.tracks do for i in 0 ..< len(t.samples) do mp4.read_sample(&r, ti, i)
					mp4.close(&r)
				} else {
					refused[0] += 1
				}
			}
			// 2. A decoder fed the valid packets with one mutated.
			if len(packets) > 0 {
				target := rand.int_max(len(packets))
				if is_mp3 {
					// The frames in order, one mutated: the reservoir carries
					// the damage into the frames after it.
					d := new(mp3.Decoder)
					for p, i in packets {
						data := p
						if i == target {mutate(p, &buffer); data = buffer[:]}
						if _, e := mp3.decode_frame(d, data); e != .None && i == target do refused[1] += 1
					}
					free(d)
				} else if is_flac {
					d: flac.Decoder
					flac.init_decoder(&d, flac_info)
					mutate(packets[target], &buffer)
					if _, _, e := flac.decode_frame(&d, buffer[:]); e != .None do refused[1] += 1
					flac.destroy_decoder(&d)
				} else if is_webm {
					d, a: vp9.Decoder
					vp9.init_decoder(&d)
					vp9.init_decoder(&a)
					for p, i in packets {
						data := p
						if i == target {mutate(p, &buffer); data = buffer[:]}
						if _, _, e := vp9.decode_packet(&d, data); e != .None {refused[1] += 1; break}
						if len(alphas[i]) > 0 do vp9.decode_packet(&a, alphas[i])
					}
					vp9.destroy_decoder(&d)
					vp9.destroy_decoder(&a)
				} else {
					d: prores.Decoder
					prores.init_decoder(&d)
					mutate(packets[target], &buffer)
					if _, e := prores.decode_frame(&d, buffer[:]); e != .None do refused[1] += 1
					prores.destroy_decoder(&d)
				}
			}
			// 3. movie.Reader end to end on a mutated file, every few rounds.
			if it % (is_mkv || is_wav || is_flac || is_mp3 ? 2 : 8) == 0 {
				mutate(file, &buffer)
				m2 := mp4.Memory_Stream{data = buffer}
				r: movie.Reader
				if movie.open_reader_stream(&r, mp4.memory_stream(&m2), {preference = .Native}) == .None {
					if r.video_index >= 0 do for _ in 0 ..< 64 {
						_, e := movie.next_frame(&r)
						if e == .End_Of_Stream do break
						if e != .None {refused[2] += 1; break}
					}
					movie.frame_at(&r, 0.1)
					pcm: [4096]f32
					for _ in 0 ..< 16 do if n, _ := movie.read_audio(&r, pcm[:]); n == 0 do break
					movie.seek_audio(&r, 1.5)
					movie.read_audio(&r, pcm[:])
					movie.close_reader(&r)
				} else {
					refused[2] += 1
				}
			}
		}
		fmt.printfln("%s: %d iterations; refused containers %d, packets %d, readers %d; leaked allocations %d", path, iterations, refused[0], refused[1], refused[2], leaked)
	}
}
