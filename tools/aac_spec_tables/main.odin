package main

import "core:fmt"
import "core:os"
import "core:strings"

// This tool reads the primary standard's text, not another codec's tables.
// Existing native source is read only after independent parsing/validation.
Error :: enum {
	None,
	Read_Input,
	Invalid_Standard,
	Missing_Row,
	Duplicate_Row,
	Invalid_Codebook,
	Value_Mismatch,
	Write_Output,
}
Code :: struct {
	length: u8,
	bits:   u32,
}
Band :: struct {
	number:            int,
	name:              string,
	long:              bool,
	count:             int,
	values, alternate: [53]int,
	seen:              [53]bool,
}
Tables :: struct {
	books:               [12][289]Code,
	seen:                [12][289]bool,
	bands:               [13]Band,
	tns_long, tns_short: [13]int,
	tns_seen:            [13]bool,
	low_rate_mapping:    bool,
}
BOOK_COUNTS := [12]int{121, 81, 81, 81, 81, 81, 81, 64, 64, 169, 169, 289}
RATES :: [13]int {
	96000,
	88200,
	64000,
	48000,
	44100,
	32000,
	24000,
	22050,
	16000,
	12000,
	11025,
	8000,
	7350,
}
LONG_BANDS :: [13]int{11, 11, 9, 0, 0, 2, 7, 7, 5, 5, 5, 3, 3}
SHORT_BANDS :: [13]int{12, 12, 10, 1, 1, 1, 8, 8, 6, 6, 6, 4, 4}

integer :: proc(text: string, base: u32) -> (value: u32, ok: bool) {
	if len(text) == 0 do return
	digits := text
	radix := base
	if strings.has_prefix(digits, "0x") {digits = digits[2:]; radix = 16}
	if len(digits) == 0 do return
	for c in digits {
		digit: u32
		switch {
		case c >= '0' && c <= '9':
			digit = u32(c - '0')
		case c >= 'a' && c <= 'f':
			digit = u32(c - 'a' + 10)
		case c >= 'A' && c <= 'F':
			digit = u32(c - 'A' + 10)
		case:
			return 0, false
		}
		if digit >= radix || value > (max(u32) - digit) / radix do return 0, false
		value = value * radix + digit
	}
	return value, true
}

fields :: proc(line: string, tokens: []string) -> int {
	remaining := line
	count := 0
	for {
		token, ok := strings.fields_iterator(&remaining)
		if !ok do break
		if count == len(tokens) do return -1
		tokens[count] = token
		count += 1
	}
	return count
}

table_number :: proc(line, prefix: string) -> int {
	if !strings.has_prefix(line, prefix) do return -1
	tail := line[len(prefix):]
	end := 0
	for end < len(tail) && tail[end] >= '0' && tail[end] <= '9' do end += 1
	if end == 0 || end == len(tail) || tail[end] != ' ' do return -1
	n, ok := integer(tail[:end], 10)
	return ok ? int(n) : -1
}

set_band :: proc(b: ^Band, index, value, alternate: int) -> Error {
	if index < 0 || index > b.count || value < 0 || alternate < 0 do return .Invalid_Standard
	if b.seen[index] do return .Duplicate_Row
	b.values[index], b.alternate[index], b.seen[index] = value, alternate, true
	return .None
}

parse_band_row :: proc(b: ^Band, tokens: []string) -> Error {
	if b.count <= 0 || len(tokens) == 0 do return .None
	_, numeric := integer(tokens[0], 10)
	if !numeric do return .None
	// Page footers and prose are not numeric-only table rows.
	for token in tokens {
		if strings.has_prefix(token, "(") && strings.has_suffix(token, ")") {
			_, ok := integer(token[1:len(token) - 1], 10)
			if !ok do return .None
		} else {
			_, ok := integer(token, 10)
			if !ok do return .None
		}
	}
	if len(tokens) < 2 do return .None
	main_end := b.long ? 1024 : 128
	for pos := 0; pos < len(tokens); {
		first, ok := integer(tokens[pos], 10)
		if !ok do return .Invalid_Standard
		pos += 1
		index, value := int(first), 0
		if index == main_end {
			index, value = b.count, main_end // Terminal offsets have no printed index.
		} else {
			if index >= b.count || pos == len(tokens) do return .Invalid_Standard
			parsed, value_ok := integer(tokens[pos], 10)
			if !value_ok do return .Invalid_Standard
			value = int(parsed)
			pos += 1
		}
		alternate := value
		if pos < len(tokens) && strings.has_prefix(tokens[pos], "(") {
			parsed, alternate_ok := integer(tokens[pos][1:len(tokens[pos]) - 1], 10)
			if !alternate_ok do return .Invalid_Standard
			alternate = int(parsed)
			pos += 1
		}
		if err := set_band(b, index, value, alternate); err != .None do return err
	}
	return .None
}

parse_standard :: proc(text: string, t: ^Tables) -> Error {
	t.bands = {
		{number = 73, name = "SWB_OFFSET_LONG_44100_48000", long = true},
		{number = 74, name = "SWB_OFFSET_SHORT_32000_44100_48000"},
		{number = 75, name = "SWB_OFFSET_LONG_32000", long = true},
		{number = 76, name = "SWB_OFFSET_LONG_8000", long = true},
		{number = 77, name = "SWB_OFFSET_SHORT_8000"},
		{number = 78, name = "SWB_OFFSET_LONG_11025_12000_16000", long = true},
		{number = 79, name = "SWB_OFFSET_SHORT_11025_12000_16000"},
		{number = 80, name = "SWB_OFFSET_LONG_22050_24000", long = true},
		{number = 81, name = "SWB_OFFSET_SHORT_22050_24000"},
		{number = 82, name = "SWB_OFFSET_LONG_64000", long = true},
		{number = 83, name = "SWB_OFFSET_SHORT_64000"},
		{number = 84, name = "SWB_OFFSET_LONG_88200_96000", long = true},
		{number = 85, name = "SWB_OFFSET_SHORT_88200_96000"},
	}
	book, band := -1, -1
	tns, mapping := false, false
	remaining := text
	line_number := 0
	for {
		line, ok := strings.split_lines_iterator(&remaining)
		if !ok do break
		line_number += 1
		line = strings.trim_space(line)
		if strings.has_prefix(line, "Table ") {
			book, band, tns, mapping = -1, -1, false, false
			if number := table_number(line, "Table 4.A.");
			   number >= 1 && number <= 12 && strings.contains(line, "Codebook") {
				book = number - 1
			} else if table := table_number(line, "Table 4."); table >= 0 {
				for b, i in t.bands do if b.number == table do band = i
				tns, mapping = table == 103, table == 55
			}
			continue
		}
		tokens: [12]string
		count := fields(line, tokens[:])
		if count <= 0 do continue
		if mapping && strings.contains(line, "9391 > f") && tokens[count - 1] == "8000" do t.low_rate_mapping = true
		if book >= 0 && (count == 3 || count == 6) {
			valid := true
			for pos := 0; pos < count; pos += 3 {
				_, a := integer(tokens[pos], 10)
				_, b := integer(tokens[pos + 1], 10)
				_, c := integer(tokens[pos + 2], 16)
				valid = valid && a && b && c
			}
			if !valid do continue
			for pos := 0; pos < count; pos += 3 {
				index, _ := integer(tokens[pos], 10)
				length, _ := integer(tokens[pos + 1], 10)
				bits, _ := integer(tokens[pos + 2], 16)
				if int(index) >= BOOK_COUNTS[book] || length == 0 || length > 32 || (length < 32 && bits >= u32(1) << length) do return .Invalid_Codebook
				if t.seen[book][index] do return .Duplicate_Row
				t.books[book][index], t.seen[book][index] = Code{u8(length), bits}, true
			}
		}
		if band >= 0 {
			b := &t.bands[band]
			if strings.contains(line, "num_swb_") {
				value, is_number := integer(tokens[count - 1], 10)
				if is_number {
					if value == 0 || value > 52 do return .Invalid_Standard
					b.count = int(value)
				}
			} else if err := parse_band_row(b, tokens[:count]); err != .None {
				fmt.eprintfln(
					"SWB parse error at primary text line %d, table 4.%d: %s",
					line_number,
					b.number,
					line,
				)
				return err
			}
		}
		if tns && count == 5 {
			rate, a := integer(tokens[0], 10)
			long, b := integer(tokens[1], 10)
			short, c := integer(tokens[2], 10)
			if !(a && b && c) do continue
			for expected, i in RATES {
				if i == 12 do break
				if int(rate) != expected do continue
				if t.tns_seen[i] do return .Duplicate_Row
				t.tns_long[i], t.tns_short[i], t.tns_seen[i] = int(long), int(short), true
			}
		}
	}
	if !t.low_rate_mapping do return .Missing_Row
	t.tns_long[12], t.tns_short[12], t.tns_seen[12] =
		t.tns_long[11], t.tns_short[11], t.tns_seen[11]
	for count, index in BOOK_COUNTS {
		for i in 0 ..< count do if !t.seen[index][i] {fmt.eprintfln("missing primary Huffman book=%d symbol=%d", index, i); return .Missing_Row}
		for i in 0 ..< count {
			for j in i + 1 ..< count {
				a, b := t.books[index][i], t.books[index][j]
				if a.length > b.length do a, b = b, a
				if b.bits >> uint(b.length - a.length) == a.bits do return .Invalid_Codebook
			}
		}
	}
	for b in t.bands {
		if b.count == 0 do return .Missing_Row
		for i in 0 ..= b.count {
			if !b.seen[i] do return .Missing_Row
			if i == 0 && (b.values[i] != 0 || b.alternate[i] != 0) do return .Invalid_Standard
			if i > 0 && (b.values[i] <= b.values[i - 1] || b.alternate[i] < b.alternate[i - 1]) do return .Invalid_Standard
			if b.values[i] % 4 != 0 || b.alternate[i] % 4 != 0 do return .Invalid_Standard
		}
		if b.values[b.count] != (b.long ? 1024 : 128) || b.alternate[b.count] != (b.long ? 960 : 120) do return .Invalid_Standard
	}
	for seen in t.tns_seen do if !seen do return .Missing_Row
	return .None
}

alternate_values :: proc(b: ^Band, output: []int) -> int {
	count := 0
	for value in b.alternate[:b.count + 1] {
		if count > 0 && value == output[count - 1] do continue
		output[count] = value
		count += 1
	}
	return count
}

alternate_name :: proc(b: ^Band) -> string {
	prefix := b.long ? "SWB_OFFSET_LONG_" : "SWB_OFFSET_SHORT_"
	return fmt.tprintf("SWB_OFFSET_%d_%s", b.long ? 960 : 120, b.name[len(prefix):])
}

array_body :: proc(source, name: string) -> (body: string, ok: bool) {
	start := strings.index(source, fmt.tprintf("%s :=", name))
	if start < 0 do return
	tail := source[start:]
	first := strings.index(tail, "{")
	if first < 0 do return
	depth := 0
	for i := first; i < len(tail); i += 1 {
		if tail[i] == '{' do depth += 1
		if tail[i] == '}' {
			depth -= 1
			if depth == 0 do return tail[first + 1:i], true
		}
	}
	return
}

source_numbers :: proc(body: string, output: []u32) -> (count: int, ok: bool) {
	for i := 0; i < len(body); {
		if body[i] < '0' || body[i] > '9' {i += 1; continue}
		end := i + 1
		for end < len(body) && ((body[end] >= '0' && body[end] <= '9') || (body[end] >= 'a' && body[end] <= 'f') || (body[end] >= 'A' && body[end] <= 'F') || body[end] == 'x') do end += 1
		if count == len(output) do return 0, false
		value, parsed := integer(body[i:end], 10)
		if !parsed do return 0, false
		output[count] = value
		count += 1
		i = end
	}
	return count, true
}

compare_values :: proc(source, name: string, expected: []int) -> bool {
	body, found := array_body(source, name)
	values: [106]u32
	count, parsed := source_numbers(body, values[:])
	if !found ||
	   !parsed ||
	   count !=
		   len(
			   expected,
		   ) {fmt.eprintfln("array mismatch %s: source count=%d expected=%d", name, count, len(expected)); return false}
	matched := true
	for want, i in expected {
		if values[i] == u32(want) do continue
		fmt.eprintfln("value mismatch %s[%d]: current=%d normative=%d", name, i, values[i], want)
		matched = false
	}
	return matched
}

compare_map :: proc(source, name: string, expected: []string) -> bool {
	body, found := array_body(source, name)
	if !found do return false
	parts := strings.split(body, ",")
	defer delete(parts)
	count := 0
	matched := true
	for part in parts {
		entry := strings.trim_space(part)
		if len(entry) == 0 do continue
		if count >= len(expected) ||
		   entry != fmt.tprintf("%s[:]", expected[min(count, len(expected) - 1)]) {
			fmt.eprintfln("map mismatch %s[%d]: %s", name, count, entry)
			matched = false
		}
		count += 1
	}
	return matched && count == len(expected)
}

compare_native :: proc(source: string, t: ^Tables) -> Error {
	matched := true
	book_names: [12]string
	for count, book in BOOK_COUNTS {
		name := fmt.tprintf("HCB_%d", book)
		book_names[book] = name
		body, found := array_body(source, name)
		values: [578]u32
		n, parsed := source_numbers(body, values[:])
		if !found ||
		   !parsed ||
		   n !=
			   2 *
				   count {fmt.eprintfln("Huffman array mismatch %s count=%d expected=%d", name, n / 2, count); matched = false; continue}
		for i in 0 ..< count {
			want := t.books[book][i]
			if values[2 * i] == u32(want.length) && values[2 * i + 1] == want.bits do continue
			fmt.eprintfln(
				"Huffman mismatch book=%d symbol=%d current=(%d,0x%x) normative=(%d,0x%x)",
				book,
				i,
				values[2 * i],
				values[2 * i + 1],
				want.length,
				want.bits,
			)
			matched = false
		}
	}
	matched = compare_map(source, "CODEBOOKS", book_names[:]) && matched
	for &b in t.bands {
		matched = compare_values(source, b.name, b.values[:b.count + 1]) && matched
		alternate: [53]int
		count := alternate_values(&b, alternate[:])
		matched = compare_values(source, alternate_name(&b), alternate[:count]) && matched
	}
	for alternate in ([2]bool{false, true}) {
		long_names, short_names: [13]string
		for index, i in LONG_BANDS do long_names[i] = alternate ? alternate_name(&t.bands[index]) : t.bands[index].name
		for index, i in SHORT_BANDS do short_names[i] = alternate ? alternate_name(&t.bands[index]) : t.bands[index].name
		matched =
			compare_map(source, alternate ? "SWB_LONG_960" : "SWB_LONG", long_names[:]) && matched
		matched =
			compare_map(source, alternate ? "SWB_SHORT_120" : "SWB_SHORT", short_names[:]) &&
			matched
	}
	_, global_long := array_body(source, "TNS_LONG_MAX")
	_, global_short := array_body(source, "TNS_SHORT_MAX")
	matched =
		compare_values(source, global_long ? "TNS_LONG_MAX" : "long_max", t.tns_long[:]) && matched
	matched =
		compare_values(source, global_short ? "TNS_SHORT_MAX" : "short_max", t.tns_short[:]) &&
		matched
	return matched ? .None : .Value_Mismatch
}

emit_offsets :: proc(out: ^strings.Builder, name: string, values: []int) {
	fmt.sbprintf(out, "%s := [?]int", name)
	strings.write_string(out, "{")
	for value, i in values do fmt.sbprintf(out, "%s%d", i == 0 ? "" : ", ", value)
	strings.write_string(out, "}\n")
}

emit_tables :: proc(t: ^Tables, output: string) -> Error {
	out: strings.Builder
	defer strings.builder_destroy(&out)
	strings.write_string(
		&out,
		"package aac\n\n// Generated directly from ISO/IEC 14496-3:2001 normative tables.\n// Run tools/aac_spec_tables; do not edit values by hand.\n// Huffman: 4.A.1–4.A.12; SWB: 4.73–4.85; TNS: 4.103; rates: 4.55.\n\nHuffman_Code :: struct {length: u8, bits: u32}\n\n",
	)
	for count, book in BOOK_COUNTS {
		fmt.sbprintf(&out, "HCB_%d := [?]Huffman_Code ", book)
		strings.write_string(&out, "{\n")
		for code in t.books[book][:count] {
			strings.write_string(&out, "\t{")
			fmt.sbprintf(&out, "%d, 0x%x", code.length, code.bits)
			strings.write_string(&out, "},\n")
		}
		strings.write_string(&out, "}\n")
	}
	strings.write_string(&out, "CODEBOOKS := [12][]Huffman_Code {\n")
	for book in 0 ..< 12 do fmt.sbprintf(&out, "\tHCB_%d[:],\n", book)
	strings.write_string(&out, "}\n")
	for &b in t.bands {
		emit_offsets(&out, b.name, b.values[:b.count + 1])
		alternate: [53]int
		count := alternate_values(&b, alternate[:])
		emit_offsets(&out, alternate_name(&b), alternate[:count])
	}
	for alternate in ([2]bool{false, true}) {
		fmt.sbprintf(&out, "%s := [13][]int ", alternate ? "SWB_LONG_960" : "SWB_LONG")
		strings.write_string(&out, "{\n")
		for index in LONG_BANDS do fmt.sbprintf(&out, "\t%s[:],\n", alternate ? alternate_name(&t.bands[index]) : t.bands[index].name)
		strings.write_string(&out, "}\n")
		fmt.sbprintf(&out, "%s := [13][]int ", alternate ? "SWB_SHORT_120" : "SWB_SHORT")
		strings.write_string(&out, "{\n")
		for index in SHORT_BANDS do fmt.sbprintf(&out, "\t%s[:],\n", alternate ? alternate_name(&t.bands[index]) : t.bands[index].name)
		strings.write_string(&out, "}\n")
	}
	emit_offsets(&out, "TNS_LONG_MAX", t.tns_long[:])
	emit_offsets(&out, "TNS_SHORT_MAX", t.tns_short[:])
	strings.write_string(
		&out,
		"\nlong_offsets :: proc(rate_index, frame_samples: int) -> []int {\n\tassert(rate_index >= 0 && rate_index < 13 && (frame_samples == 1024 || frame_samples == 960))\n\treturn frame_samples == 960 ? SWB_LONG_960[rate_index] : SWB_LONG[rate_index]\n}\nshort_offsets :: proc(rate_index, frame_samples: int) -> []int {\n\tassert(rate_index >= 0 && rate_index < 13 && (frame_samples == 1024 || frame_samples == 960))\n\treturn frame_samples == 960 ? SWB_SHORT_120[rate_index] : SWB_SHORT[rate_index]\n}\ntns_max_bands :: proc(rate_index: int, short: bool) -> int {\n\tassert(rate_index >= 0 && rate_index < 13)\n\treturn short ? TNS_SHORT_MAX[rate_index] : TNS_LONG_MAX[rate_index]\n}\n",
	)
	if os.write_entire_file(output, transmute([]u8)strings.to_string(out)) != nil do return .Write_Output
	return .None
}

main :: proc() {
	if len(os.args) !=
	   4 {fmt.eprintln("usage: aac_spec_tables ISO14496-3.txt codec/aac/tables.odin generated.odin"); os.exit(2)}
	text, err := os.read_entire_file(os.args[1], context.allocator)
	if err != nil {fmt.eprintln(Error.Read_Input, os.args[1]); os.exit(1)}
	defer delete(text)
	t: Tables
	if error := parse_standard(string(text), &t); error != .None {fmt.eprintln(error); os.exit(1)}
	if error := emit_tables(&t, os.args[3]); error != .None {fmt.eprintln(error); os.exit(1)}
	native, native_error := os.read_entire_file(os.args[2], context.allocator)
	if native_error != nil {fmt.eprintln(Error.Read_Input, os.args[2]); os.exit(1)}
	defer delete(native)
	if error := compare_native(string(native), &t);
	   error !=
	   .None {fmt.eprintln(error, "independent normative output:", os.args[3]); os.exit(1)}
	fmt.printfln(
		"AAC primary-table verification: 12 codebooks / 1362 symbols, 26 SWB arrays / 52 mapped rate tables, 26 TNS limits; all values exact; independent output=%s",
		os.args[3],
	)
}
