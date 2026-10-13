// Writes the generated codec tables from their reference sources: the C
// sources fetched into third_party/ by tools/fetch_third_party.sh, or a
// specification's text.
//
//	odin build tools/tables -out:.work/tables
//	.work/tables opus [third_party] > codec/opus/tables.odin
//
// See tools/tables/README.md for every table and its source.
package main

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:strings"

Generator :: struct {
	name:   string,
	run:    proc(out: ^strings.Builder, input: string),
	input:  string, // the default input, "" when it must be given
	output: string,
}

GENERATORS := [?]Generator {
	{"opus", opus_tables, "third_party", "codec/opus/tables.odin"},
	{"silk", silk_tables, "third_party", "codec/opus/silk_tables.odin"},
	{"webp", webp_tables, "third_party", "codec/webp/tables.odin"},
	{"mp3", mp3_tables, "third_party", "codec/mp3/tables.odin"},
	{"h265", h265_tables, "third_party", "codec/h265/scan_tables.odin"},
	{"vp9", vp9_tables, "", "codec/vp9/tables.odin"},
}

main :: proc() {
	generator := generator_for(os.args[1:])
	if generator == nil {
		fmt.eprintln("usage: tables GENERATOR [INPUT] > OUTPUT")
		for g in GENERATORS do fmt.eprintfln("  %-5s %-13s > %s", g.name, g.input == "" ? "SPEC.txt" : "[third_party]", g.output)
		os.exit(2)
	}
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do fail("out of memory")
	context.allocator = virtual.arena_allocator(&arena)
	defer virtual.arena_destroy(&arena)

	out := strings.builder_make()
	generator.run(&out, len(os.args) == 3 ? os.args[2] : generator.input)
	if _, err := os.write_string(os.stdout, strings.to_string(out)); err != nil do fail("writing the output failed")
}

generator_for :: proc(args: []string) -> ^Generator {
	if len(args) == 0 || len(args) > 2 do return nil
	for &g in GENERATORS {
		if g.name == args[0] && (len(args) == 2 || g.input != "") do return &g
	}
	return nil
}

fail :: proc(format: string, args: ..any) -> ! {
	fmt.eprint("tables: ")
	fmt.eprintfln(format, ..args)
	os.exit(1)
}

expect :: proc(ok: bool, what: string, loc := #caller_location) {
	if !ok do fail("%s: unexpected source (%v)", what, loc)
}

read :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do fail("cannot read %s: %v", path, err)
	return string(data)
}

is_space :: proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v'
}

is_word :: proc(c: u8) -> bool {
	return c == '_' || (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

is_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

skip_space :: proc(s: string, i: int) -> int {
	i := i
	for i < len(s) && is_space(s[i]) do i += 1
	return i
}

// The matching close of the brace before `start`, and the text between them.
braced :: proc(s: string, start: int) -> (body: string, end: int) {
	depth := 1
	for end = start; depth > 0; end += 1 {
		if end >= len(s) do fail("unbalanced braces")
		switch s[end] {
		case '{': depth += 1
		case '}': depth -= 1
		}
	}
	return s[start:end - 1], end
}

// The braces' contents of the first C definition `name[...]... = { ... }` in
// source, comments included.
initializer :: proc(source, name: string) -> string {
	from := 0
	for {
		at := strings.index(source[from:], name)
		if at < 0 do fail("table %s not found", name)
		at += from
		from = at + 1
		if at > 0 && is_word(source[at - 1]) do continue
		i := skip_space(source, at + len(name))
		if i >= len(source) || source[i] != '[' do continue
		for i < len(source) && source[i] == '[' {
			close := strings.index_byte(source[i:], ']')
			if close < 0 do break
			i += close + 1
		}
		i = skip_space(source, i)
		if i >= len(source) || source[i] != '=' do continue
		i = skip_space(source, i + 1)
		if i >= len(source) || source[i] != '{' do continue
		body, _ := braced(source, i + 1)
		return body
	}
}

// s without its /* */ and // comments.
strip_comments :: proc(s: string) -> string {
	out := strings.builder_make()
	for i := 0; i < len(s); {
		if strings.has_prefix(s[i:], "/*") {
			end := strings.index(s[i + 2:], "*/")
			if end < 0 do break
			i += 2 + end + 2
		} else if strings.has_prefix(s[i:], "//") {
			end := strings.index_byte(s[i:], '\n')
			if end < 0 do break
			i += end
		} else {
			strings.write_byte(&out, s[i])
			i += 1
		}
	}
	return strings.to_string(out)
}

// The non-empty items of s between any of the separator characters, with
// surrounding white space removed.
items :: proc(s: string, separators: string) -> []string {
	out := make([dynamic]string)
	start := 0
	for i in 0 ..= len(s) {
		if i < len(s) && strings.index_byte(separators, s[i]) < 0 do continue
		item := strings.trim_space(s[start:i])
		if item != "" do append(&out, item)
		start = i + 1
	}
	return out[:]
}

C_SEPARATORS :: " \t\n\r\f\v,{}"

// The values of a C initializer as written, comments removed.
c_items :: proc(source, name: string) -> []string {
	return items(strip_comments(initializer(source, name)), C_SEPARATORS)
}

// A C integer literal: decimal or 0x hexadecimal, with an optional U suffix.
c_int :: proc(text: string) -> i64 {
	s := strings.trim_suffix(text, "U")
	negative := strings.has_prefix(s, "-")
	if negative do s = s[1:]
	base := 10
	if strings.has_prefix(s, "0x") || strings.has_prefix(s, "0X") {
		s, base = s[2:], 16
	}
	value, ok := strconv.parse_i64_of_base(s, base)
	if !ok || s == "" do fail("not an integer: %q", text)
	return negative ? -value : value
}

c_ints :: proc(source, name: string) -> []i64 {
	values := c_items(source, name)
	out := make([]i64, len(values))
	for v, i in values do out[i] = c_int(v)
	return out
}

c_float :: proc(text: string) -> f64 {
	value, ok := strconv.parse_f64(strings.trim_right(text, "fF"))
	if !ok do fail("not a number: %q", text)
	return value
}

c_floats :: proc(source, name: string) -> []f64 {
	values := c_items(source, name)
	out := make([]f64, len(values))
	for v, i in values do out[i] = c_float(v)
	return out
}

// An integer constant expression: literals, names (looked up in `names`),
// unary and binary + - * / and parentheses.
evaluate :: proc(text: string, names: map[string]i64) -> i64 {
	Parser :: struct {
		s:     string,
		i:     int,
		names: map[string]i64,
	}
	peek :: proc(p: ^Parser) -> u8 {
		p.i = skip_space(p.s, p.i)
		return p.i < len(p.s) ? p.s[p.i] : 0
	}
	sum :: proc(p: ^Parser) -> i64 {
		value := product(p)
		for {
			switch peek(p) {
			case '+': p.i += 1; value += product(p)
			case '-': p.i += 1; value -= product(p)
			case: return value
			}
		}
	}
	product :: proc(p: ^Parser) -> i64 {
		value := unary(p)
		for {
			switch peek(p) {
			case '*': p.i += 1; value *= unary(p)
			case '/':
				p.i += 1
				d := unary(p)
				if d == 0 do fail("division by zero in %q", p.s)
				value /= d
			case: return value
			}
		}
	}
	unary :: proc(p: ^Parser) -> i64 {
		switch peek(p) {
		case '-': p.i += 1; return -unary(p)
		case '+': p.i += 1; return unary(p)
		case '(':
			p.i += 1
			value := sum(p)
			if peek(p) != ')' do fail("unbalanced parentheses in %q", p.s)
			p.i += 1
			return value
		}
		start := p.i
		for p.i < len(p.s) && is_word(p.s[p.i]) do p.i += 1
		word := p.s[start:p.i]
		switch {
		case word == "": fail("bad expression %q", p.s)
		case is_digit(word[0]): return c_int(word)
		}
		value, known := p.names[word]
		if !known do fail("unknown name %s in %q", word, p.s)
		return value
	}
	p := Parser{text, 0, names}
	value := sum(&p)
	if peek(&p) != 0 do fail("bad expression %q", text)
	return value
}

// v with the shortest digits that read back as v: fixed notation for
// 1e-4 <= |v| < 1e16 (with ".0" on whole numbers), otherwise d.ddde±XX.
write_float :: proc(out: ^strings.Builder, v: f64) {
	buf: [64]u8
	s := string(strconv.write_float(buf[:], v, 'e', -1, 64)) // ±d.ddde±XX
	e := strings.index_byte(s, 'e')
	digits_buf: [32]u8
	n := 0
	for c in transmute([]u8)s[1:e] {
		if c != '.' {digits_buf[n] = c; n += 1}
	}
	digits := string(digits_buf[:n])
	exponent := 0
	for c in transmute([]u8)s[e + 2:] do exponent = exponent * 10 + int(c - '0')
	if s[e + 1] == '-' do exponent = -exponent

	if s[0] == '-' do strings.write_byte(out, '-')
	switch {
	case exponent < -4 || exponent >= 16:
		strings.write_byte(out, digits[0])
		if n > 1 {
			strings.write_byte(out, '.')
			strings.write_string(out, digits[1:])
		}
		fmt.sbprintf(out, "e%c%02d", exponent < 0 ? '-' : '+', abs(exponent))
	case exponent < 0:
		strings.write_string(out, "0.")
		for _ in 0 ..< -exponent - 1 do strings.write_byte(out, '0')
		strings.write_string(out, digits)
	case n <= exponent + 1:
		strings.write_string(out, digits)
		for _ in 0 ..< exponent + 1 - n do strings.write_byte(out, '0')
		strings.write_string(out, ".0")
	case:
		strings.write_string(out, digits[:exponent + 1])
		strings.write_byte(out, '.')
		strings.write_string(out, digits[exponent + 1:])
	}
}

write_value :: proc(out: ^strings.Builder, v: $T) {
	when T == f64 {
		write_float(out, v)
	} else {
		fmt.sbprint(out, v)
	}
}

write_list :: proc(out: ^strings.Builder, values: []$T) {
	for v, i in values {
		if i > 0 do strings.write_string(out, ", ")
		write_value(out, v)
	}
}

write_comment :: proc(out: ^strings.Builder, lines: []string) {
	for line in lines do fmt.sbprintfln(out, "// %s", line)
}

// A table in rows: `per_line` values to a line for one dimension; for two or
// three, one braced row (of braced rows) to a line.
table :: proc(out: ^strings.Builder, name, kind: string, values: []$T, per_line := 16, shape: []int = nil, comment: []string = nil) {
	write_comment(out, comment)
	fmt.sbprintf(out, "@(rodata)\n%s := ", name)
	if shape == nil {
		fmt.sbprintfln(out, "[%d]%s{{", len(values), kind)
		for k := 0; k < len(values); k += per_line {
			strings.write_byte(out, '\t')
			write_list(out, values[k:min(k + per_line, len(values))])
			strings.write_string(out, ",\n")
		}
	} else {
		count := 1
		for d in shape {
			fmt.sbprintf(out, "[%d]", d)
			count *= d
		}
		fmt.sbprintfln(out, "%s{{", kind)
		expect(len(values) == count, name)
		row := count / shape[0]
		for r in 0 ..< shape[0] {
			strings.write_string(out, "\t{")
			if len(shape) == 2 {
				write_list(out, values[r * row:][:row])
			} else {
				inner := shape[2]
				for s := 0; s < row; s += inner {
					if s > 0 do strings.write_string(out, ", ")
					strings.write_byte(out, '{')
					write_list(out, values[r * row + s:][:inner])
					strings.write_byte(out, '}')
				}
			}
			strings.write_string(out, "},\n")
		}
	}
	strings.write_string(out, "}\n\n")
}

// An Odin compound literal of values in shape: one level of braces to a line,
// the innermost on one line when it holds 16 values or fewer, else in lines
// of 16.
write_nested :: proc(out: ^strings.Builder, values: []i64, shape: []int, indent: int) {
	tabs :: proc(out: ^strings.Builder, n: int) {
		for _ in 0 ..< n do strings.write_byte(out, '\t')
	}
	if len(shape) == 1 && len(values) <= 16 {
		strings.write_byte(out, '{')
		write_list(out, values)
		strings.write_byte(out, '}')
		return
	}
	strings.write_string(out, "{\n")
	if len(shape) == 1 {
		for k := 0; k < len(values); k += 16 {
			tabs(out, indent + 1)
			write_list(out, values[k:min(k + 16, len(values))])
			strings.write_string(out, ",\n")
		}
	} else {
		step := len(values) / shape[0]
		for k in 0 ..< shape[0] {
			tabs(out, indent + 1)
			write_nested(out, values[k * step:][:step], shape[1:], indent + 1)
			strings.write_string(out, ",\n")
		}
	}
	tabs(out, indent)
	strings.write_byte(out, '}')
}

nested_table :: proc(out: ^strings.Builder, attributes, name, kind: string, values: []i64, shape: []int, comment: []string = nil) {
	count := 1
	for d in shape do count *= d
	expect(len(values) == count, name)
	write_comment(out, comment)
	fmt.sbprintf(out, "@(%s)\n%s := ", attributes, name)
	for d in shape do fmt.sbprintf(out, "[%d]", d)
	strings.write_string(out, kind)
	write_nested(out, values, shape, 0)
	strings.write_string(out, "\n\n")
}
