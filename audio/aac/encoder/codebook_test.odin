package aac_encoder

import aac ".."
import "core:testing"

// The reference retains the original generic tuple arithmetic and sums every
// book over the whole band, without production admission or partial pruning.
@(private)
Codebook_Test_Shape :: struct {
	radix, width: int,
	signed:       bool,
}

@(private)
codebook_test_shapes := [12]Codebook_Test_Shape {
	{},
	{3, 4, true},
	{3, 4, true},
	{3, 4, false},
	{3, 4, false},
	{9, 2, true},
	{9, 2, true},
	{8, 2, false},
	{8, 2, false},
	{13, 2, false},
	{13, 2, false},
	{17, 2, false},
}

@(private)
codebook_test_original_tuple :: proc(book: int, values: []i32) -> int {
	shape := codebook_test_shapes[book]
	maximum := shape.signed ? shape.radix / 2 : shape.radix - 1
	index, extra := 0, 0
	for value in values {
		magnitude := int(abs(value))
		if book != 11 && magnitude > maximum do return 1 << 20
		digit := shape.signed ? int(value) + maximum : min(magnitude, maximum)
		index = index * shape.radix + digit
		if !shape.signed && value != 0 do extra += 1
		if book == 11 && magnitude >= 16 {
			bits := 4
			for magnitude >= 1 << uint(bits + 1) do bits += 1
			extra += 2 * bits - 3
		}
	}
	return int(aac.CODEBOOKS[book][index].length) + extra
}

@(private)
codebook_test_original_selector :: proc(values: []i32) -> (selected: u8, costs: [12]int) {
	selected = 11
	best := max(int)
	for book in 1 ..= 11 {
		width := codebook_test_shapes[book].width
		for k := 0; k < len(values); k += width {
			costs[book] += codebook_test_original_tuple(book, values[k:k + width])
		}
		if costs[book] < best {selected, best = u8(book), costs[book]}
	}
	return
}

@(private)
codebook_test_pair_cost :: proc(values: []i32, first_book, limit: int) -> (first, second: int) {
	switch first_book {
	case 1:
		return paired_codebook_cost(3, true, 4, values, first_book, limit)
	case 3:
		return paired_codebook_cost(3, false, 4, values, first_book, limit)
	case 5:
		return paired_codebook_cost(9, true, 2, values, first_book, limit)
	case 7:
		return paired_codebook_cost(8, false, 2, values, first_book, limit)
	case 9:
		return paired_codebook_cost(13, false, 2, values, first_book, limit)
	}
	panic("invalid test pair")
}

@(private)
codebook_test_verify_band :: proc(t: ^testing.T, values: []i32) -> (has_tie: bool) {
	maximum := 0
	for v in values do maximum = max(maximum, int(abs(v)))
	want, costs := codebook_test_original_selector(values)
	testing.expectf(
		t,
		choose_codebook(values, maximum) == want,
		"band length=%d maximum=%d expected book=%d",
		len(values),
		maximum,
		want,
	)
	for first_book in ([5]int{1, 3, 5, 7, 9}) {
		shape := codebook_test_shapes[first_book]
		capacity := shape.signed ? shape.radix / 2 : shape.radix - 1
		if maximum > capacity do continue
		first, second := codebook_test_pair_cost(values, first_book, max(int))
		testing.expect_value(t, first, costs[first_book])
		testing.expect_value(t, second, costs[first_book + 1])
	}
	for book in int(want) + 1 ..= 11 do if costs[book] == costs[want] do has_tie = true
	return
}

@(test)
test_codebook_full_signed_unsigned_quad_grid :: proc(t: ^testing.T) {
	ties := 0
	// -2..2 includes every sign/zero variant of unsigned radix-3 quads and
	// every signed radix-3 tuple as its -1..1 subset.
	for a in i32(-2) ..= 2 {
		for b in i32(-2) ..= 2 {
			for c in i32(-2) ..= 2 {
				for d in i32(-2) ..= 2 {
					values := [4]i32{a, b, c, d}
					if codebook_test_verify_band(t, values[:]) do ties += 1
				}
			}
		}
	}
	testing.expect(t, ties > 0)
}

@(test)
test_codebook_full_pair_grids_and_escape_extremes :: proc(t: ^testing.T) {
	// This grid contains the complete signed radix-9 and unsigned radix-8,
	// radix-13, and clamped radix-17 pair alphabets, with all sign variants.
	for a in i32(-16) ..= 16 {
		for b in i32(-16) ..= 16 {
			values := [4]i32{a, b, 0, 0}
			codebook_test_verify_band(t, values[:])
		}
	}
	extremes := [?]i32 {
		0,
		1,
		-1,
		12,
		-12,
		15,
		-15,
		16,
		-16,
		17,
		-17,
		31,
		-31,
		32,
		-32,
		255,
		-255,
		256,
		-256,
		4095,
		-4095,
		4096,
		-4096,
		8190,
		-8190,
		8191,
		-8191,
	}
	for a in extremes {
		for b in extremes {
			values := [4]i32{a, b, -a, -b}
			codebook_test_verify_band(t, values[:])
		}
	}
}

@(private)
codebook_test_random :: proc(state: ^u32) -> u32 {
	state^ ~= state^ << 13
	state^ ~= state^ >> 17
	state^ ~= state^ << 5
	return state^
}

@(test)
test_codebook_random_bands_all_admitted_lengths :: proc(t: ^testing.T) {
	state: u32 = 0x9473e1b9
	values: [1024]i32
	for length in ([13]int{4, 8, 12, 16, 24, 32, 48, 64, 96, 128, 256, 512, 1024}) {
		for maximum in ([9]int{1, 2, 4, 7, 12, 16, 31, 255, 8191}) {
			for _ in 0 ..< 8 {
				for &v in values[:length] {
					r := codebook_test_random(&state)
					v = r & 3 == 0 ? 0 : i32(r % u32(2 * maximum + 1)) - i32(maximum)
				}
				codebook_test_verify_band(t, values[:length])
			}
		}
	}
}

@(test)
test_codebook_pair_partial_cost_refusal_and_strict_ties :: proc(t: ^testing.T) {
	values: [1024]i32
	want, _ := codebook_test_original_selector(values[:])
	testing.expect_value(t, want, u8(1))
	testing.expect_value(t, choose_codebook(values[:], 0), want)
	observed_pruning := false
	for first_book in ([5]int{1, 3, 5, 7, 9}) {
		shape := codebook_test_shapes[first_book]
		capacity := shape.signed ? shape.radix / 2 : shape.radix - 1
		for pattern in 0 ..< 2 {
			for &v, i in values {
				v =
					pattern == 0 || i % 4 == 0 ? 0 : (i % 4 == 1 ? i32(capacity) : (i % 4 == 2 ? -i32(capacity) : i32(capacity / 2)))
			}
			codebook_test_verify_band(t, values[:])
			_, pair_costs := codebook_test_original_selector(values[:])
			full_first, full_second := pair_costs[first_book], pair_costs[first_book + 1]
			for limit in ([6]int{1, full_first, full_second, max(1, min(full_first, full_second) - 1), max(full_first, full_second) + 1, max(int)}) {
				first, second := codebook_test_pair_cost(values[:], first_book, limit)
				if full_first < limit {
					testing.expect_value(t, first, full_first)
				} else {
					testing.expectf(
						t,
						first >= limit,
						"pair=%d first cost must refuse limit=%d",
						first_book,
						limit,
					)
				}
				if full_second < limit {
					testing.expect_value(t, second, full_second)
				} else {
					testing.expectf(
						t,
						second >= limit,
						"pair=%d second cost must refuse limit=%d",
						first_book,
						limit,
					)
				}
				if first < full_first || second < full_second do observed_pruning = true
			}
		}
	}
	testing.expect(t, observed_pruning)
}

@(test)
test_codebook_long_band_width_admission_all_rates :: proc(t: ^testing.T) {
	for offsets, rate_index in aac.SWB_LONG {
		testing.expectf(t, len(offsets) >= 2, "rate index=%d needs long bands", rate_index)
		testing.expect_value(t, offsets[0], 0)
		testing.expect_value(t, offsets[len(offsets) - 1], 1024)
		for b in 1 ..< len(offsets) {
			width := offsets[b] - offsets[b - 1]
			testing.expectf(
				t,
				width > 0 && width <= 1024 && width % 4 == 0,
				"rate index=%d band=%d width=%d must admit pair and quad coding",
				rate_index,
				b - 1,
				width,
			)
		}
	}
}
