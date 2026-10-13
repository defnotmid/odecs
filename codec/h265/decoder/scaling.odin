package h265_decoder

import hevc ".."

// ---------------------------------------------------------------------------
// Scaling lists (7.3.4, 7.4.5). The type and the default matrices live in the
// shared package because the encoder signals and quantizes with them too; this
// file owns the 7.3.4 parser. Ported from gen2brain/h265 hevc/scaling.go
// (MIT); oxideav-h265 src/scaling_list.rs is the per-file cross-reference.
// ---------------------------------------------------------------------------

MAX_SCALING_LIST_SIZES :: hevc.MAX_SCALING_LIST_SIZES
MAX_SCALING_LIST_MATS :: hevc.MAX_SCALING_LIST_MATS

Scaling_List :: hevc.Scaling_List
default_scaling_list :: hevc.default_scaling_list

parse_scaling_list_data :: proc(c: ^Get_Bits, sl: ^Scaling_List) -> bool {
	for size_id in 0 ..< MAX_SCALING_LIST_SIZES {
		step := 1
		if size_id == 3 do step = 3

		matrix_id := 0
		for matrix_id < MAX_SCALING_LIST_MATS {
			if get_bits_bit(c) == 0 {
				delta := int(get_bits_ue(c)) * step
				if delta > matrix_id do return false

				if delta == 0 {
					matrix_id += step
					continue
				}

				ref := matrix_id - delta
				sl.sl[size_id][matrix_id] = sl.sl[size_id][ref]

				if size_id > 1 {
					sl.dc[size_id - 2][matrix_id] = sl.dc[size_id - 2][ref]
				}

				matrix_id += step
				continue
			}

			next := i32(8)

			if size_id > 1 {
				dc := get_bits_se(c)
				if dc < -7 || dc > 247 do return false

				next = dc + 8
				sl.dc[size_id - 2][matrix_id] = u8(next)
			}

			scan := hevc.SCALING_SCAN_8X8[:]
			if size_id == 0 do scan = hevc.SCALING_SCAN_4X4[:]

			for idx in scan {
				d := get_bits_se(c)
				if d < -128 || d > 127 do return false

				next = (next + d + 256) % 256
				sl.sl[size_id][matrix_id][idx] = u8(next)
			}

			matrix_id += step
		}
	}

	if c.err do return false

	return true
}
