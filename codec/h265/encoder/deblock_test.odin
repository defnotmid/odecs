package h265_encoder

import common "../../common"
import "core:testing"

// Preserve the original CTU raster/band schedule independently of the new
// orientation/row traversal. The unchanged edge kernels own filter maths;
// this oracle isolates the dependency and publication-order change.
@(private)
deblock_test_raster_oracle :: proc(enc: ^Encoder, frame: ^Frame) {
	for cty in 0 ..< enc.ctu_rows do for ctx in 0 ..< enc.ctu_cols {
		x0, y0 := ctx * CTU_WIDTH, cty * CTU_WIDTH
		x_end := min(x0 + CTU_WIDTH, enc.coded_width)
		y_end := min(y0 + CTU_WIDTH, enc.coded_height)
		x_end2 := x_end == enc.coded_width ? x_end : x_end - 8
		for y := y0; y < y_end; y += 8 {
			for x := x0 > 0 ? x0 : 8; x < x_end; x += 8 {
				b0, b1 := deblock_strength(enc, x, y, true), deblock_strength(enc, x, y + 4, true)
				if b0 != 0 || b1 != 0 do deblock_edge_luma(frame.y, x, y, true, b0, b1, enc.qp, enc.bit_depth)
			}
			if y == 0 do continue
			for x := x0 > 0 ? x0 - 8 : 0; x < x_end2; x += 8 {
				b0, b1 := deblock_strength(enc, x, y, false), deblock_strength(enc, x + 4, y, false)
				if b0 != 0 || b1 != 0 do deblock_edge_luma(frame.y, x, y, false, b0, b1, enc.qp, enc.bit_depth)
			}
		}
		if !has_chroma(enc) do continue
		sw, sh := chroma_sub(enc.config.chroma_format)
		tc := deblock_chroma_tc_for(enc.qp, enc.config.chroma_format) * (i32(1) << uint(enc.bit_depth - 8))
		max_v := (i32(1) << uint(enc.bit_depth)) - 1
		for plane in ([2]Plane(Sample){frame.u, frame.v}) {
			seg := 4 * sh
			for y := y0; y < y_end; y += 2 * seg {
				for x := x0 > 0 ? x0 : 8 * sw; x < x_end; x += 8 * sw {
					b0 := deblock_strength(enc, x, y, true)
					b1 := y + seg < enc.coded_height ? deblock_strength(enc, x, y + seg, true) : 0
					if b0 == 2 || b1 == 2 do deblock_edge_chroma(plane, x / sw, y / sh, true, b0 == 2 ? tc : 0, b1 == 2 ? tc : 0, max_v)
				}
				if y == 0 do continue
				cx_end := x_end == enc.coded_width ? x_end : x_end - 8 * sw
				for x := x0 > 0 ? x0 - 8 * sw : 0; x < cx_end; x += 8 * sw {
					b0 := deblock_strength(enc, x, y, false)
					b1 := x + 4 * sw < enc.coded_width ? deblock_strength(enc, x + 4 * sw, y, false) : 0
					if b0 == 2 || b1 == 2 do deblock_edge_chroma(plane, x / sw, y / sh, false, b0 == 2 ? tc : 0, b1 == 2 ? tc : 0, max_v)
				}
			}
		}
	}
}

@(private)
Deblock_Test_Pool :: struct {
	work:  common.Work_Pool,
	mode:  int,
	calls: int,
}

@(private)
deblock_test_map :: proc(
	pool: ^common.Work_Pool,
	count: int,
	task: common.Range_Proc,
	data: rawptr,
) {
	p := cast(^Deblock_Test_Pool)pool.user
	p.calls += 1
	if p.mode == 0 {
		// Reverse every single-row lane. The horizontal lane can write above
		// its nominal CTU rectangle; the edge support proof must still hold.
		for row := count - 1; row >= 0; row -= 1 do task(data, row, row + 1)
	} else {
		// Unequal contiguous ranges, scheduled from right to left.
		mid := count / 2
		if mid < count do task(data, mid, count)
		if mid > 0 do task(data, 0, mid)
	}
}

DEBLOCK_TEST_SAMPLES :: 148 * 136 + 31

@(private)
Deblock_Test_Storage :: struct {
	initial, expected, actual: [3][DEBLOCK_TEST_SAMPLES]Sample,
	cells, cells_before:       [34 * 34]Cu_Info,
}

@(private)
deblock_test_frame :: proc(storage: ^[3][DEBLOCK_TEST_SAMPLES]Sample, enc: ^Encoder) -> Frame {
	w, h := enc.coded_width, enc.coded_height
	sw, _ := chroma_sub(enc.config.chroma_format)
	planes: [3]Plane(Sample)
	for component in 0 ..< 3 {
		width := component == 0 ? w : w / sw
		planes[component] = {
			data   = storage[component][:],
			stride = width + 7 + component,
			offset = 13 + component,
		}
	}
	if !has_chroma(enc) do planes[1], planes[2] = {}, {}
	return Frame {
		y = planes[0],
		u = planes[1],
		v = planes[2],
		width = enc.width,
		height = enc.height,
		coded_width = w,
		coded_height = h,
	}
}

@(private)
deblock_test_guards :: proc(
	t: ^testing.T,
	enc: ^Encoder,
	storage: ^Deblock_Test_Storage,
	frame: ^Frame,
) -> bool {
	planes := [3]Plane(Sample){frame.y, frame.u, frame.v}
	sw, sh := chroma_sub(enc.config.chroma_format)
	for plane, component in planes {
		w := component == 0 ? enc.coded_width : enc.coded_width / sw
		h := component == 0 ? enc.coded_height : enc.coded_height / sh
		for value, index in storage.expected[component] {
			r := index - plane.offset
			visible :=
				len(plane.data) != 0 && r >= 0 && r / plane.stride < h && r % plane.stride < w
			if !visible && value != storage.initial[component][index] {
				testing.expectf(
					t,
					false,
					"raster oracle changed deblock guard layout=%v plane=%d index=%d",
					enc.config.chroma_format,
					component,
					index,
				)
				return false
			}
		}
	}
	return true
}

@(private)
deblock_test_prepare :: proc(
	enc: ^Encoder,
	storage: ^Deblock_Test_Storage,
	shape: [2]int,
	layout: Chroma_Layout,
	depth, scenario, pattern: int,
) {
	enc.width, enc.height = shape[0], shape[1]
	enc.coded_width, enc.coded_height = (shape[0] + 7) / 8 * 8, (shape[1] + 7) / 8 * 8
	enc.ctu_cols, enc.ctu_rows = (enc.coded_width + 63) / 64, (enc.coded_height + 63) / 64
	enc.bit_depth = depth
	enc.config = {
		chroma_format = layout,
		rqt           = scenario == 1,
		intra_rqt     = scenario == 2,
		amp           = scenario == 3,
		pcm           = true,
		tiles_cols    = 2,
		tiles_rows    = 2,
	}
	// Filtering currently crosses tiles, and PCM loop-filter disabling is
	// signalled false. Do not invent no-filter semantics for these fixtures.
	enc.tiles_on = true
	enc.ref_poc[0][0], enc.ref_poc[0][1] = -3, -5
	enc.ref_poc[1][0], enc.ref_poc[1][1] = -5, -3
	cols, rows := enc.coded_width / 4, enc.coded_height / 4
	enc.cu = {
		cells = storage.cells[:cols * rows],
		cols  = cols,
	}
	for y in 0 ..< rows do for x in 0 ..< cols {
		i := y * cols + x
		intra := scenario == 0 || (x / 2 + y / 2) % 5 == 0
		enc.cu.cells[i] = {
			type    = intra ? .Intra : .Inter,
			depth   = 3,
			pcm     = intra && (x + y) % 7 == 0,
			cbf_y   = (x / 2 + 3 * (y / 2)) % 4 == 0,
			tu_v    = x % 2 == 0 && (x / 2 + y / 2) % 3 != 0,
			tu_h    = y % 2 == 0 && (x / 2 + y / 2) % 3 != 1,
			pu_v    = x % 2 == 0,
			pu_h    = y % 2 == 0,
			pred    = {true, (x / 2 + y / 2) % 3 != 0},
			ref_idx = {i8((x / 2) % 2), i8((y / 2) % 2)},
			mv      = {{i16((x / 2) % 3 * 4), i16((y / 2) % 3 * 4)}, {i16((y / 2) % 2 * 8), i16((x / 2) % 2 * 8)}},
		}
	}
	storage.cells_before = storage.cells
	for &plane, component in storage.initial do for &value, index in plane do value = Sample((index * 73 + component * 191 + 0xDA79) & 0xffff)
	frame := deblock_test_frame(&storage.initial, enc)
	planes := [3]Plane(Sample){frame.y, frame.u, frame.v}
	sw, sh := chroma_sub(layout)
	scale := 1 << uint(depth - 8)
	for plane, component in planes {
		if len(plane.data) == 0 do continue
		w := component == 0 ? enc.coded_width : enc.coded_width / sw
		h := component == 0 ? enc.coded_height : enc.coded_height / sh
		for y in 0 ..< h do for x in 0 ..< w {
			// Smooth steps exercise strong filtering. Alternating ramps keep
			// curvature low but defeat its p3/q3 condition at middle QPs.
			v := 64 + component * 11 + 2 * ((x / 8 + y / 8) % 7)
			if pattern == 1 do v = 64 + component * 11 + x % 8 + y % 8 + 16 * ((x / 8 + y / 8) % 2)
			plane.data[plane.offset + y * plane.stride + x] = Sample(v * scale)
		}
	}
}

@(test)
test_deblock_orientation_row_schedule_and_guards :: proc(t: ^testing.T) {
	enc := new(Encoder)
	storage := new(Deblock_Test_Storage)
	defer free(enc)
	defer free(storage)
	pool_state: Deblock_Test_Pool
	pool_state.work = {
		run  = deblock_test_map,
		user = &pool_state,
	}
	shapes := [8][2]int {
		{1, 1},
		{7, 9},
		{9, 7},
		{15, 17},
		{63, 65},
		{65, 63},
		{130, 70},
		{129, 131},
	}
	layouts := [4]Chroma_Layout{.Monochrome, .YUV_420, .YUV_422, .YUV_444}
	changed: [2]bool
	for shape in shapes do for layout in layouts do for depth in ([2]int{8, 10}) do for scenario in 0 ..< 4 do for pattern in 0 ..< 2 {
		deblock_test_prepare(enc, storage, shape, layout, depth, scenario, pattern)
		for qp in ([3]i32{0, 26, 51}) {
			enc.qp = qp
			storage.expected = storage.initial
			want := deblock_test_frame(&storage.expected, enc)
			deblock_test_raster_oracle(enc, &want)
			if !deblock_test_guards(t, enc, storage, &want) do return
			for mode in 0 ..< 3 {
				storage.actual = storage.initial
				got := deblock_test_frame(&storage.actual, enc)
				pool_state.calls, pool_state.mode = 0, mode - 1
				enc.config.pool = mode == 0 ? nil : &pool_state.work
				deblock_frame_on(enc, &got)
				testing.expect_value(t, pool_state.calls, mode == 0 ? 0 : 2)
				for plane, component in storage.actual do for value, index in plane {
					if value != storage.expected[component][index] {
						testing.expectf(t, false, "deblock shape=%v layout=%v depth=%d scenario=%d pattern=%d qp=%d schedule=%d plane=%d index=%d", shape, layout, depth, scenario, pattern, qp, mode, component, index)
						return
					}
					if value != storage.initial[component][index] do changed[pattern] = true
				}
			}
			for value, index in storage.cells do testing.expect_value(t, value, storage.cells_before[index])
		}
	}
	testing.expectf(
		t,
		changed[0] && changed[1],
		"fixtures must exercise filtering rather than only zero-strength/threshold returns",
	)
}

@(test)
test_deblock_caller_static_pool_matches_raster :: proc(t: ^testing.T) {
	enc := new(Encoder)
	storage := new(Deblock_Test_Storage)
	defer free(enc)
	defer free(storage)
	pool: common.Static_Pool
	common.init_static_pool(&pool, 2)
	defer common.destroy_static_pool(&pool)
	for layout in ([4]Chroma_Layout{.Monochrome, .YUV_420, .YUV_422, .YUV_444}) do for depth in ([2]int{8, 10}) do for scenario in 0 ..< 4 do for pattern in 0 ..< 2 {
		deblock_test_prepare(enc, storage, {129, 131}, layout, depth, scenario, pattern)
		enc.qp = 26
		storage.expected, storage.actual = storage.initial, storage.initial
		want, got := deblock_test_frame(&storage.expected, enc), deblock_test_frame(&storage.actual, enc)
		deblock_test_raster_oracle(enc, &want)
		enc.config.pool = &pool.work_pool
		deblock_frame_on(enc, &got)
		for plane, component in storage.actual do for value, index in plane {
			if value != storage.expected[component][index] {
				testing.expectf(t, false, "pooled deblock layout=%v depth=%d scenario=%d pattern=%d plane=%d index=%d", layout, depth, scenario, pattern, component, index)
				return
			}
		}
		for value, index in storage.cells do testing.expect_value(t, value, storage.cells_before[index])
	}
}
