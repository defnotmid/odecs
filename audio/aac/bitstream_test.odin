package aac

import "core:testing"

// Independent copies of the original scalar reader and tree walk. Expected
// values never call the optimized bit extractor or Huffman prefix lookup.
@(private)
bitstream_test_scalar_read :: proc(r: ^Bit_Reader, n: int) -> u32 {
	if r.err != .None do return 0
	if n < 0 || n > 32 || n > len(r.data) * 8 - r.pos {
		r.err = .Truncated
		return 0
	}
	value: u32
	for _ in 0 ..< n {
		value = value << 1 | u32((r.data[r.pos >> 3] >> uint(7 - (r.pos & 7))) & 1)
		r.pos += 1
	}
	return value
}

@(private)
bitstream_test_scalar_skip :: proc(r: ^Bit_Reader, n: int) {
	// Preserve the original distinction: skips can advance with a preexisting
	// error, and an invalid skip overwrites it with Truncated.
	if n < 0 || n > len(r.data) * 8 - r.pos {r.err = .Truncated; return}
	r.pos += n
}

@(private)
bitstream_test_scalar_huffman :: proc(r: ^Bit_Reader, tables: ^Huffman_Tables, book: int) -> int {
	if book < 0 || book >= 12 {r.err = .Invalid_Data; return 0}
	node := 0
	for _ in 0 ..< 20 {
		if tables.nodes[book][node].symbol >= 0 do return int(tables.nodes[book][node].symbol)
		node = int(tables.nodes[book][node].child[bitstream_test_scalar_read(r, 1)])
		if node < 0 || r.err != .None {r.err = r.err == .None ? .Invalid_Data : r.err; return 0}
	}
	r.err = .Invalid_Data
	return 0
}

@(private)
bitstream_test_state :: proc(
	t: ^testing.T,
	actual, expected: ^Bit_Reader,
	operation: string,
	case_index: int,
) {
	testing.expectf(
		t,
		actual.pos == expected.pos && actual.err == expected.err,
		"%s case=%d pos=%d expected=%d error=%v expected=%v",
		operation,
		case_index,
		actual.pos,
		expected.pos,
		actual.err,
		expected.err,
	)
}

@(private)
bitstream_test_random :: proc(state: ^u32) -> u32 {
	state^ ~= state^ << 13
	state^ ~= state^ >> 17
	state^ ~= state^ << 5
	return state^
}

@(test)
test_read_bits_scalar_oracle_all_offsets_and_boundaries :: proc(t: ^testing.T) {
	data := [6]u8{0x93, 0x51, 0xe7, 0x2a, 0xc8, 0x6d}
	case_index := 0
	for length in 0 ..= len(data) {
		for position in 0 ..= length * 8 + 2 {
			for n in -1 ..= 33 {
				for err in ([4]Error{.None, .Truncated, .Invalid_Data, .Unsupported_Tool}) {
					actual := Bit_Reader {
						data = data[:length],
						pos  = position,
						err  = err,
					}
					expected := actual
					got, want := read_bits(&actual, n), bitstream_test_scalar_read(&expected, n)
					testing.expectf(
						t,
						got == want,
						"read case=%d width=%d value=%08x expected=%08x",
						case_index,
						n,
						got,
						want,
					)
					bitstream_test_state(t, &actual, &expected, "read", case_index)
					case_index += 1
				}
			}
		}
	}
	// This 32-bit read crosses five actual bytes; no wide load may assume a
	// sixth byte or discard the low bits of the unaligned field.
	r := Bit_Reader {
		data = data[:5],
		pos  = 4,
	}
	testing.expect_value(t, read_bits(&r, 32), u32(0x351e72ac))
	testing.expect_value(t, r.pos, 36)
	testing.expect_value(t, r.err, Error.None)
}

@(test)
test_read_skip_align_random_sequences_and_direct_positions :: proc(t: ^testing.T) {
	control_data := [1]u8{0x93}
	control := Bit_Reader {
		data = control_data[:],
		pos  = 3,
		err  = .Unsupported_Tool,
	}
	skip_bits(&control, 2)
	testing.expect_value(t, control.pos, 5)
	testing.expect_value(t, control.err, Error.Unsupported_Tool)
	skip_bits(&control, 4)
	testing.expect_value(t, control.pos, 5)
	testing.expect_value(t, control.err, Error.Truncated)
	align_reader(&control)
	testing.expect_value(t, control.pos, 8)
	testing.expect_value(t, control.err, Error.Truncated)
	seed: u32 = 0x9a713b5d
	data: [32]u8
	for case_index in 0 ..< 1024 {
		for &v in data do v = u8(bitstream_test_random(&seed))
		length := int(bitstream_test_random(&seed) % 33)
		actual := Bit_Reader {
			data = data[:length],
			pos  = int(bitstream_test_random(&seed) % u32(length * 8 + 3)),
		}
		if case_index % 7 == 0 do actual.err = .Invalid_Data
		expected := actual
		for step in 0 ..< 24 {
			if step % 8 == 7 {
				// pos is an existing public field. A directly selected position
				// must select the current data, independently of previous reads.
				actual.pos = int(bitstream_test_random(&seed) % u32(length * 8 + 3))
				actual.err = .None
				expected = actual
			}
			switch bitstream_test_random(&seed) % 3 {
			case 0:
				n := int(bitstream_test_random(&seed) % 36) - 2
				testing.expect_value(
					t,
					read_bits(&actual, n),
					bitstream_test_scalar_read(&expected, n),
				)
			case 1:
				n := int(bitstream_test_random(&seed) % u32(length * 8 + 5)) - 2
				skip_bits(&actual, n)
				bitstream_test_scalar_skip(&expected, n)
			case 2:
				align_reader(&actual)
				bitstream_test_scalar_skip(&expected, -expected.pos & 7)
			}
			bitstream_test_state(t, &actual, &expected, "read/skip/align", case_index * 24 + step)
		}
	}
}

@(private)
bitstream_test_put_code :: proc(data: []u8, position: int, bits: u32, count: int) {
	for i in 0 ..< count {
		bit := (bits >> uint(count - 1 - i)) & 1
		p := position + i
		mask := u8(1 << uint(7 - (p & 7)))
		if bit != 0 {data[p >> 3] |= mask} else {data[p >> 3] &= ~mask}
	}
}

@(test)
test_huffman_all_symbols_all_offsets_and_exact_positions :: proc(t: ^testing.T) {
	tables: Huffman_Tables
	init_huffman(&tables)
	case_index := 0
	for codes, book in CODEBOOKS {
		for code, symbol in codes {
			for offset in 0 ..< 8 {
				data := [8]u8{0xa5, 0x3c, 0x96, 0x69, 0xf0, 0x0f, 0x5a, 0xc3}
				width := int(code.length)
				bitstream_test_put_code(data[:], offset, code.bits, width)
				actual := Bit_Reader {
					data = data[:(offset + width + 7) / 8],
					pos  = offset,
				}
				expected := actual
				testing.expect_value(t, read_huffman(&actual, &tables, book), symbol)
				testing.expect_value(
					t,
					bitstream_test_scalar_huffman(&expected, &tables, book),
					symbol,
				)
				bitstream_test_state(t, &actual, &expected, "symbol", case_index)
				testing.expect_value(t, actual.pos, offset + width)
				testing.expect_value(t, actual.err, Error.None)
				case_index += 1
			}
		}
	}
}

@(test)
test_huffman_every_code_truncation_at_exact_bit_end :: proc(t: ^testing.T) {
	tables: Huffman_Tables
	init_huffman(&tables)
	case_index := 0
	for codes, book in CODEBOOKS {
		for code in codes {
			width := int(code.length)
			for kept in 0 ..< width {
				for leading_bytes in 0 ..< 2 {
					// Put all padding BEFORE the truncated code. The last kept bit
					// is the physical last bit of the slice, including 0..7-bit tails.
					offset := leading_bytes * 8 + ((8 - (kept & 7)) & 7)
					data: [8]u8
					prefix := code.bits >> uint(width - kept)
					bitstream_test_put_code(data[:], offset, prefix, kept)
					actual := Bit_Reader {
						data = data[:(offset + kept) / 8],
						pos  = offset,
					}
					expected := actual
					testing.expect_value(
						t,
						read_huffman(&actual, &tables, book),
						bitstream_test_scalar_huffman(&expected, &tables, book),
					)
					bitstream_test_state(t, &actual, &expected, "truncated symbol", case_index)
					testing.expect_value(t, actual.pos, offset + kept)
					testing.expect_value(t, actual.err, Error.Truncated)
					case_index += 1
				}
			}
		}
	}
}

@(test)
test_huffman_concatenated_codes_keep_next_symbol_position :: proc(t: ^testing.T) {
	tables: Huffman_Tables
	init_huffman(&tables)
	for codes, book in CODEBOOKS {
		for offset in 0 ..< 8 {
			data: [4096]u8
			end := offset
			for code in codes {
				bitstream_test_put_code(data[:], end, code.bits, int(code.length))
				end += int(code.length)
			}
			actual := Bit_Reader {
				data = data[:(end + 7) / 8],
				pos  = offset,
			}
			expected := actual
			position := offset
			for code, symbol in codes {
				testing.expect_value(t, read_huffman(&actual, &tables, book), symbol)
				testing.expect_value(
					t,
					bitstream_test_scalar_huffman(&expected, &tables, book),
					symbol,
				)
				position += int(code.length)
				testing.expect_value(t, actual.pos, position)
				bitstream_test_state(t, &actual, &expected, "concatenated symbol", symbol)
			}
		}
	}
}

@(test)
test_huffman_byte_prefixes_random_tails_invalid_books_and_errors :: proc(t: ^testing.T) {
	tables: Huffman_Tables
	init_huffman(&tables)
	case_index := 0
	// Every 8-bit prefix, including continuation/invalid entries if present,
	// is checked against the tree, both at EOF and with another actual byte.
	for book in 0 ..< 12 {
		for prefix in 0 ..< 256 {
			for length in 1 ..= 2 {
				for offset in 0 ..< 8 {
					data := [2]u8{u8(prefix), u8(prefix ~ 0xa7)}
					actual := Bit_Reader {
						data = data[:length],
						pos  = offset,
					}
					expected := actual
					testing.expect_value(
						t,
						read_huffman(&actual, &tables, book),
						bitstream_test_scalar_huffman(&expected, &tables, book),
					)
					bitstream_test_state(t, &actual, &expected, "byte prefix", case_index)
					case_index += 1
				}
			}
		}
	}
	seed: u32 = 0x34719abd
	data: [8]u8
	for book in -1 ..= 12 {
		for _ in 0 ..< 128 {
			for &v in data do v = u8(bitstream_test_random(&seed))
			length := int(bitstream_test_random(&seed) % 9)
			position := int(bitstream_test_random(&seed) % u32(length * 8 + 3))
			for err in ([4]Error{.None, .Truncated, .Invalid_Data, .Unsupported_Tool}) {
				actual := Bit_Reader {
					data = data[:length],
					pos  = position,
					err  = err,
				}
				expected := actual
				for _ in 0 ..< 3 {
					testing.expect_value(
						t,
						read_huffman(&actual, &tables, book),
						bitstream_test_scalar_huffman(&expected, &tables, book),
					)
					bitstream_test_state(
						t,
						&actual,
						&expected,
						"random/sticky Huffman",
						case_index,
					)
					case_index += 1
				}
			}
		}
	}
	control := Bit_Reader {
		data = data[:],
		pos  = 3,
		err  = .Unsupported_Tool,
	}
	testing.expect_value(t, read_huffman(&control, &tables, 0), 0)
	testing.expect_value(t, control.pos, 3)
	testing.expect_value(t, control.err, Error.Unsupported_Tool)
	testing.expect_value(t, read_huffman(&control, &tables, -1), 0)
	testing.expect_value(t, control.pos, 3)
	testing.expect_value(t, control.err, Error.Invalid_Data)
}

@(test)
test_huffman_prefix_metadata_matches_tree :: proc(t: ^testing.T) {
	tables := new(Huffman_Tables)
	defer free(tables)
	init_huffman(tables)
	leaves, continuations := 0, 0
	for book in 0 ..< 12 {
		for prefix in 0 ..< 256 {
			// The uncompressed tree supplies logical metadata independently of
			// the prefix representation and the production eight-bit extractor.
			node, depth := 0, 0
			for depth < 8 && node >= 0 && tables.nodes[book][node].symbol < 0 {
				bit := (prefix >> uint(7 - depth)) & 1
				node = int(tables.nodes[book][node].child[bit])
				depth += 1
			}
			leaf := node >= 0 && tables.nodes[book][node].symbol >= 0
			target := leaf ? int(tables.nodes[book][node].symbol) : node
			entry := tables.prefix[book][prefix]
			testing.expect_value(t, int(entry.target), target)
			testing.expect_value(t, int(entry.bits), depth)
			testing.expect_value(t, entry.leaf, leaf)
			if leaf {leaves += 1} else {continuations += 1}
		}
	}
	testing.expect(t, leaves > 0 && continuations > 0)
}

@(test)
test_huffman_uninitialized_custom_trees_eof_errors_and_depth_limit :: proc(t: ^testing.T) {
	tables := new(Huffman_Tables)
	defer free(tables)
	case_index := 0
	for mode in 0 ..< 6 {
		tables^ = {}
		for book in 0 ..< 12 {
			// Even a plausible prefix entry must be ignored without readiness.
			for &entry in tables.prefix[book] do entry = {
				target = 577,
				bits   = 8,
				leaf   = true,
			}
			switch mode {
			case 0: // Default root is a zero leaf, including empty/error readers.
			case 1:
				tables.nodes[book][0].symbol = i16(book * 17 + 9)
			case 2:
				tables.nodes[book][0] = {
					child  = {1, -1},
					symbol = -1,
				}
				tables.nodes[book][1].symbol = i16(book + 19)
			case:
				depth := mode == 3 ? 19 : 20
				for node in 0 ..< depth {
					tables.nodes[book][node] = {
						child  = {i16(node + 1), -1},
						symbol = -1,
					}
				}
				tables.nodes[book][depth] = {
					child  = {-1, -1},
					symbol = mode == 4 ? i16(-1) : i16(book + 71),
				}
			}
		}
		testing.expect(t, !tables.prefix_ready)
		if mode >= 3 {
			zeros: [3]u8
			for book in 0 ..< 12 {
				control := Bit_Reader {
					data = zeros[:],
				}
				symbol := read_huffman(&control, tables, book)
				testing.expect_value(t, symbol, mode == 3 ? book + 71 : 0)
				testing.expect_value(t, control.pos, mode == 3 ? 19 : 20)
				testing.expect_value(t, control.err, mode == 3 ? Error.None : Error.Invalid_Data)
			}
		}
		for byte in ([2]u8{0, 0xff}) {
			data := [3]u8{byte, byte, byte}
			for book in -1 ..= 12 {
				for length in 0 ..= 3 {
					for position in 0 ..< (length * 8 + 3) {
						for err in ([4]Error{.None, .Truncated, .Invalid_Data, .Unsupported_Tool}) {
							actual := Bit_Reader {
								data = data[:length],
								pos  = position,
								err  = err,
							}
							expected := actual
							testing.expect_value(
								t,
								read_huffman(&actual, tables, book),
								bitstream_test_scalar_huffman(&expected, tables, book),
							)
							bitstream_test_state(t, &actual, &expected, "custom tree", case_index)
							case_index += 1
						}
					}
				}
			}
		}
		if mode <= 1 {
			// Root leaves require no physical read, even with a negative public
			// position. Moving a generic reader/EOF check before that leaf is wrong.
			for book in -1 ..= 12 {
				for err in ([4]Error{.None, .Truncated, .Invalid_Data, .Unsupported_Tool}) {
					actual := Bit_Reader {
						pos = -1,
						err = err,
					}
					expected := actual
					testing.expect_value(
						t,
						read_huffman(&actual, tables, book),
						bitstream_test_scalar_huffman(&expected, tables, book),
					)
					bitstream_test_state(t, &actual, &expected, "root leaf/no read", case_index)
					case_index += 1
				}
			}
		}
	}
}

@(test)
test_huffman_prefix_missing_edges_keep_consumed_depth_and_negative_target :: proc(t: ^testing.T) {
	tables := new(Huffman_Tables)
	defer free(tables)
	case_index := 0
	data := [2]u8{0xa5, 0x6b}
	for missing_depth in ([3]int{1, 4, 8}) {
		tables^ = {}
		// This test owns a custom chain whose two edges agree at each level;
		// every eight-bit prefix reaches a missing edge at the declared depth.
		for book in 0 ..< 12 {
			for node in 0 ..< missing_depth {
				target := node + 1 == missing_depth ? i16(-1) : i16(node + 1)
				tables.nodes[book][node] = {
					child  = {target, target},
					symbol = -1,
				}
			}
			for &entry in tables.prefix[book] do entry = {
				target = -1,
				bits   = u8(missing_depth),
				leaf   = false,
			}
		}
		tables.prefix_ready = true
		for book in -1 ..= 12 {
			for length in 0 ..= 2 {
				for position in 0 ..< (length * 8 + 3) {
					for err in ([4]Error{.None, .Truncated, .Invalid_Data, .Unsupported_Tool}) {
						actual := Bit_Reader {
							data = data[:length],
							pos  = position,
							err  = err,
						}
						expected := actual
						testing.expect_value(
							t,
							read_huffman(&actual, tables, book),
							bitstream_test_scalar_huffman(&expected, tables, book),
						)
						bitstream_test_state(
							t,
							&actual,
							&expected,
							"prefix missing edge",
							case_index,
						)
						case_index += 1
					}
				}
			}
		}
	}
}
