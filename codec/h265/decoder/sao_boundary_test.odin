package h265_decoder

import "core:testing"

// Original per-sample availability, independently expressed in CTB addresses.
// This deliberately has no range cache or geometry partition shared with the
// new boundary owner. Direction matters: the neighbour's slice flag is read.
@(private)
sao_boundary_filter_oracle :: proc(d: ^Ctu_Decoder($Sample), x, y, nx, ny: int) -> bool {
	size, columns := int(d.s.ctb_size_y), int(d.s.pic_width_in_ctbs)
	current := y / size * columns + x / size
	neighbour := ny / size * columns + nx / size
	if current == neighbour do return true
	if d.p.tiles_enabled &&
	   !d.p.loop_filter_across_tiles &&
	   d.grids.tile_id[d.grids.rs_to_ts[current]] != d.grids.tile_id[d.grids.rs_to_ts[neighbour]] {
		return false
	}
	if d.grids.ctb_slice_addr[current] != d.grids.ctb_slice_addr[neighbour] &&
	   !d.grids.slice_filters[d.grids.ctb_slice_addr[neighbour]].loop_filter_across {
		return false
	}
	return true
}

@(private)
sao_boundary_pixel_oracle :: proc(
	d: ^Ctu_Decoder($Sample),
	dst, source: []Sample,
	stride, x, y, width, height, sx, sy: int,
	p: ^Sao_Params,
	depth: int,
) {
	index :=
		(y * sy / (1 << uint(d.grids.min_tb_log2))) * d.grids.min_tb_width +
		x * sx / (1 << uint(d.grids.min_tb_log2))
	if d.grids.no_filter[index] do return
	value := i32(source[y * stride + x])
	maximum := i32(1 << uint(depth)) - 1
	if p.type_idx == SAO_BAND {
		band := (int(value >> uint(depth - 5)) - p.band + 32) % 32
		if band < 4 do dst[y * stride + x] = Sample(clamp(value + p.offset[band], 0, maximum))
		return
	}
	if p.type_idx != SAO_EDGE do return
	a, b: [2]int
	switch p.class {
	case 0:
		a, b = {-1, 0}, {1, 0}
	case 1:
		a, b = {0, -1}, {0, 1}
	case 2:
		a, b = {-1, -1}, {1, 1}
	case 3:
		a, b = {1, -1}, {-1, 1}
	}
	ax, ay, bx, by := x + a[0], y + a[1], x + b[0], y + b[1]
	if ax < 0 || ax >= width || ay < 0 || ay >= height || bx < 0 || bx >= width || by < 0 || by >= height do return
	if !sao_boundary_filter_oracle(d, x * sx, y * sy, ax * sx, ay * sy) ||
	   !sao_boundary_filter_oracle(d, x * sx, y * sy, bx * sx, by * sy) {
		return
	}
	category := 0
	av, bv := source[ay * stride + ax], source[by * stride + bx]
	if value > i32(av) do category += 1
	if value < i32(av) do category -= 1
	if value > i32(bv) do category += 1
	if value < i32(bv) do category -= 1
	map_index := [5]int{0, 1, -1, 2, 3}
	if selected := map_index[category + 2]; selected >= 0 {
		dst[y * stride + x] = Sample(clamp(value + p.offset[selected], 0, maximum))
	}
}

@(private)
sao_boundary_cases :: proc(t: ^testing.T) {
	// Coded geometry is cropped at right/bottom CTBs. Monochrome, 420, 422,
	// 444, min-TB4/8 and depth8/10/12 exercise different run/subsampling grids.
	configs := [][6]int {
		{35, 33, 16, 0, 8, 2},
		{70, 38, 32, 1, 10, 3},
		{68, 35, 32, 2, 12, 2},
		{130, 66, 64, 3, 10, 3},
	}
	for cfg in configs {
		width, height, size, chroma, depth, minimum :=
			cfg[0], cfg[1], cfg[2], cfg[3], cfg[4], cfg[5]
		log2 := 0
		for extent := size; extent > 1; extent /= 2 do log2 += 1
		s := SPS {
			chroma_format_idc          = u32(chroma),
			sub_width_c                = chroma == 1 || chroma == 2 ? 2 : 1,
			sub_height_c               = chroma == 1 ? 2 : 1,
			pic_width_in_luma_samples  = u32(width),
			pic_height_in_luma_samples = u32(height),
			pic_width_in_ctbs          = u32((width + size - 1) / size),
			pic_height_in_ctbs         = u32((height + size - 1) / size),
			ctb_size_y                 = u32(size),
			ctb_log2_size_y            = u8(log2),
			min_cb_log2_size_y         = 3,
			min_tb_log2_size_y         = u8(minimum),
			bit_depth_luma             = u8(depth),
			bit_depth_chroma           = u8(depth),
		}
		p := PPS {
			tiles_enabled    = true,
			uniform_spacing  = true,
			num_tile_columns = 2,
			num_tile_rows    = 2,
		}
		if !testing.expect(t, pps_resolve_tile_geometry(&p, &s)) do return
		defer destroy_pps(&p)
		pic := Picture {
			width  = width,
			height = height,
		}
		sh := new(Slice_Header)
		sh.sao_luma, sh.sao_chroma = true, true
		d := new(Ctu_Decoder(u16))
		d^ = new_ctu_decoder(u16, &s, &p, sh, &pic)
		defer {
			destroy_ctu_decoder(d)
			free(d)
		}
		components := chroma == 0 ? 1 : 3
		for component in 0 ..< components {
			sx, sy := 1, 1
			if component != 0 do sx, sy = s.sub_width_c, s.sub_height_c
			w, h := width / sx, height / sy
			stride, guard := w + 7, 11
			source := make([]u16, 2 * guard + h * stride)
			actual := make([]u16, len(source))
			wanted := make([]u16, len(source))
			snapshot := make([]u16, h * stride)
			defer delete(source)
			defer delete(actual)
			defer delete(wanted)
			defer delete(snapshot)
			maximum := i32(1 << uint(depth)) - 1
			for &value, index in source {
				value = u16((index * 53 + index / stride * 149) & int(maximum))
				// Flat patches give category zero, and a sharp 0/max pattern
				// gives both clipping endpoints under signed offset controls.
				if index % 23 < 5 do value = u16(maximum / 2)
				if index % 17 == 0 do value = 0
				if index % 19 == 0 do value = u16(maximum)
			}
			original_source := make([]u16, len(source))
			defer delete(original_source)
			copy(original_source, source)
			for flags in 0 ..< 32 {
				p.tiles_enabled = flags & 1 != 0
				p.loop_filter_across_tiles = flags & 2 != 0
				sh.sao_luma = flags & 1 == 0
				sh.sao_chroma = flags & 2 == 0
				for &address, ctb in d.grids.ctb_slice_addr {
					column, row := ctb % int(s.pic_width_in_ctbs), ctb / int(s.pic_width_in_ctbs)
					address = flags & 4 == 0 ? 0 : i32((column / 2 + row) & 1)
				}
				d.grids.slice_filters[0].loop_filter_across, d.grids.slice_filters[1].loop_filter_across = flags & 8 != 0, flags & 16 != 0
				for &filters in d.grids.slice_filters[:2] do filters.sao_luma, filters.sao_chroma = sh.sao_luma, sh.sao_chroma
				for exclusion in 0 ..< 4 {
					for &excluded, index in d.grids.no_filter {
						x, y := index % d.grids.min_tb_width, index / d.grids.min_tb_width
						excluded =
							exclusion == 1 ||
							(exclusion == 2 && (x + y) & 1 == 0) ||
							(exclusion == 3 && (3 * x + y) % 5 == 0)
					}
					for class in 0 ..< 4 {
						for &ctb, index in d.grids.sao {
							ctb[component] = Sao_Params {
								type_idx = SAO_EDGE,
								class    = class,
								offset   = {7, 3, -5, -7},
							}
							if index & 1 != 0 do ctb[component].offset = {-7, -3, 5, 7}
							if index % 5 == 0 do ctb[component].type_idx = SAO_OFF
							if index % 5 == 1 do ctb[component].type_idx, ctb[component].band = SAO_BAND, 31
						}
						copy(actual, source)
						copy(wanted, actual)
						plane := actual[guard:len(actual) - guard]
						expected := wanted[guard:len(wanted) - guard]
						input := source[guard:len(source) - guard]
						for &value in snapshot do value = 0xdef1
						sao_plane(d, plane, stride, component, snapshot, exclusion != 0)
						if component == 0 ? sh.sao_luma : sh.sao_chroma {
							for y in 0 ..< h do for x in 0 ..< w {
								ctb := y * sy / size * int(s.pic_width_in_ctbs) + x * sx / size
								sao_boundary_pixel_oracle(d, expected, input, stride, x, y, w, h, sx, sy, &d.grids.sao[ctb][component], depth)
							}
						}
						for value, index in actual {
							if value != wanted[index] {
								testing.expectf(
									t,
									false,
									"SAO boundary cfg=%v component=%d flags=%d exclusion=%d class=%d storage=%d got=%d want=%d",
									cfg,
									component,
									flags,
									exclusion,
									class,
									index,
									value,
									wanted[index],
								)
								return
							}
						}
						for value, index in source {
							if value != original_source[index] {
								testing.expectf(
									t,
									false,
									"SAO boundary modified snapshot cfg=%v component=%d flags=%d storage=%d",
									cfg,
									component,
									flags,
									index,
								)
								return
							}
						}
					}
				}
			}
		}
	}
}

@(test)
test_sao_plane_mixed_boundaries_scalar_pixel_oracle :: proc(t: ^testing.T) {
	sao_boundary_cases(t)
}
