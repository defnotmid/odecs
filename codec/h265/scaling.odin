package h265

// ---------------------------------------------------------------------------
// Scaling lists (7.3.4, 7.4.5). The decoder parses these from the SPS or PPS,
// the encoder signals them, and both sides quantize and dequantize with the
// same per-position matrices. Ported from gen2brain/h265 hevc/scaling.go (MIT);
// oxideav-h265 src/scaling_list.rs is the per-file cross-reference.
// ---------------------------------------------------------------------------

MAX_SCALING_LIST_SIZES :: 4
MAX_SCALING_LIST_MATS :: 6

DEFAULT_SCALING_LIST_4X4 := [16]u8{16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16}

DEFAULT_SCALING_LIST_INTRA := [64]u8 {
	16,
	16,
	16,
	16,
	17,
	18,
	21,
	24,
	16,
	16,
	16,
	16,
	17,
	19,
	22,
	25,
	16,
	16,
	17,
	18,
	20,
	22,
	25,
	29,
	16,
	16,
	18,
	21,
	24,
	27,
	31,
	36,
	17,
	17,
	20,
	24,
	30,
	35,
	41,
	47,
	18,
	19,
	22,
	27,
	35,
	44,
	54,
	65,
	21,
	22,
	25,
	31,
	41,
	54,
	70,
	88,
	24,
	25,
	29,
	36,
	47,
	65,
	88,
	115,
}

DEFAULT_SCALING_LIST_INTER := [64]u8 {
	16,
	16,
	16,
	16,
	17,
	18,
	20,
	24,
	16,
	16,
	16,
	17,
	18,
	20,
	24,
	25,
	16,
	16,
	17,
	18,
	20,
	24,
	25,
	28,
	16,
	17,
	18,
	20,
	24,
	25,
	28,
	33,
	17,
	18,
	20,
	24,
	25,
	28,
	33,
	41,
	18,
	20,
	24,
	25,
	28,
	33,
	41,
	54,
	20,
	24,
	25,
	28,
	33,
	41,
	54,
	71,
	24,
	25,
	28,
	33,
	41,
	54,
	71,
	91,
}

// Scaling lists code their matrices in the plain up-right diagonal scan, not
// the grouped coefficient scan that scan_table holds: 7.4.5 matches ffmpeg's
// ff_hevc_diag_scan4x4/8x8 and HM's SCAN_UNGROUPED table. The values are
// raster positions in scan order.
SCALING_SCAN_4X4 := [16]u32{0, 4, 1, 8, 5, 2, 12, 9, 6, 3, 13, 10, 7, 14, 11, 15}

SCALING_SCAN_8X8 := [64]u32 {
	0,
	8,
	1,
	16,
	9,
	2,
	24,
	17,
	10,
	3,
	32,
	25,
	18,
	11,
	4,
	40,
	33,
	26,
	19,
	12,
	5,
	48,
	41,
	34,
	27,
	20,
	13,
	6,
	56,
	49,
	42,
	35,
	28,
	21,
	14,
	7,
	57,
	50,
	43,
	36,
	29,
	22,
	15,
	58,
	51,
	44,
	37,
	30,
	23,
	59,
	52,
	45,
	38,
	31,
	60,
	53,
	46,
	39,
	61,
	54,
	47,
	62,
	55,
	63,
}

// Scaling_List is the raw list state of scaling_list_data(): the eight-by-eight
// matrices for sizes 8, 16 and 32 (size ID 1..3), the 4x4 matrix (size ID 0) in
// the low 16 entries of sl[0], and the DC overrides for size IDs 2 and 3. The
// matrices are indexed by raster position, since that is what dequantization
// reads; scaling_list_data() codes them in diagonal scan order.
Scaling_List :: struct {
	sl: [MAX_SCALING_LIST_SIZES][MAX_SCALING_LIST_MATS][64]u8,
	dc: [2][MAX_SCALING_LIST_MATS]u8,
}

default_scaling_list :: proc() -> Scaling_List {
	sl: Scaling_List

	for m in 0 ..< MAX_SCALING_LIST_MATS {
		for i in 0 ..< 16 {
			sl.sl[0][m][i] = DEFAULT_SCALING_LIST_4X4[i]
		}
	}

	for s in 1 ..< MAX_SCALING_LIST_SIZES {
		for m in 0 ..< MAX_SCALING_LIST_MATS {
			if m < 3 {
				sl.sl[s][m] = DEFAULT_SCALING_LIST_INTRA
			} else {
				sl.sl[s][m] = DEFAULT_SCALING_LIST_INTER
			}
		}
	}

	for s in 0 ..< 2 {
		for m in 0 ..< MAX_SCALING_LIST_MATS {
			sl.dc[s][m] = 16
		}
	}

	return sl
}
