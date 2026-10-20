package audio

import "core:strconv"
import "core:strings"

// LOOPSTART and LOOPLENGTH, in frames, from a Vorbis comment block (a
// vendor string, then count-prefixed KEY=value fields, lengths little-
// endian), as Vorbis, Opus and FLAC carry it after their own prefixes.
// None unless both are there, LOOPSTART is at least zero and LOOPLENGTH
// more than zero.
@(private)
comment_loop :: proc(block: []u8) -> Maybe(Loop) {
	at := 0
	field :: proc(block: []u8, at: ^int) -> (s: string, ok: bool) {
		if len(block) - at^ < 4 do return
		b := block[at^:]
		n := int(b[0]) | int(b[1]) << 8 | int(b[2]) << 16 | int(b[3]) << 24
		if n > len(b) - 4 do return
		at^ += 4 + n
		return string(b[4:][:n]), true
	}
	if _, ok := field(block, &at); !ok do return nil // the vendor
	if len(block) - at < 4 do return nil
	b := block[at:]
	count := int(b[0]) | int(b[1]) << 8 | int(b[2]) << 16 | int(b[3]) << 24
	at += 4
	start, length: i64 = -1, -1
	for _ in 0 ..< count {
		s, ok := field(block, &at)
		if !ok do break
		key, _, value := strings.partition(s, "=")
		if strings.equal_fold(key, "LOOPSTART") {
			if v, vok := strconv.parse_i64_of_base(value, 10); vok do start = v
		} else if strings.equal_fold(key, "LOOPLENGTH") {
			if v, vok := strconv.parse_i64_of_base(value, 10); vok do length = v
		}
	}
	if start < 0 || length <= 0 || length > max(i64) - start do return nil
	return Loop{start, start + length}
}

// The loop in a Vorbis comment header: "\x03vorbis", then the block.
@(private)
vorbis_comment_loop :: proc(header: []u8) -> Maybe(Loop) {
	if len(header) < 7 || string(header[:7]) != "\x03vorbis" do return nil
	return comment_loop(header[7:])
}
