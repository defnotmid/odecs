package vp9

// One coefficient of a scan with what its token reads (6.4.24): its raster
// position, the two earlier positions whose energy classes give its context,
// its band and its row. Built once from the scan tables, so the token loops
// look these up instead of deriving them per coefficient.
Scan_Entry :: struct {
	pos, above, left: u16,
	band, row:        u8,
}

// Per transform size: the default scan (DCT_DCT and ADST_ADST), the row
// scan (ADST_DCT) and the column scan (DCT_ADST). 32x32 is DCT only.
@(private)
SCAN_4X4: [3][16]Scan_Entry
@(private)
SCAN_8X8: [3][64]Scan_Entry
@(private)
SCAN_16X16: [3][256]Scan_Entry
@(private)
SCAN_32X32: [1024]Scan_Entry

// The scan a transform block's coefficients are coded in.
scan_entries :: #force_inline proc "contextless" (tx, tx_type: int) -> []Scan_Entry {
	kind := tx_type == ADST_DCT ? 1 : tx_type == DCT_ADST ? 2 : 0
	switch tx {
	case TX_4X4:
		return SCAN_4X4[kind][:]
	case TX_8X8:
		return SCAN_8X8[kind][:]
	case TX_16X16:
		return SCAN_16X16[kind][:]
	}
	return SCAN_32X32[:]
}

@(private, init)
init_scans :: proc "contextless" () {
	build_scan(SCAN_4X4[0][:], DEFAULT_SCAN_4X4[:], TX_4X4, 0)
	build_scan(SCAN_4X4[1][:], ROW_SCAN_4X4[:], TX_4X4, 1)
	build_scan(SCAN_4X4[2][:], COL_SCAN_4X4[:], TX_4X4, 2)
	build_scan(SCAN_8X8[0][:], DEFAULT_SCAN_8X8[:], TX_8X8, 0)
	build_scan(SCAN_8X8[1][:], ROW_SCAN_8X8[:], TX_8X8, 1)
	build_scan(SCAN_8X8[2][:], COL_SCAN_8X8[:], TX_8X8, 2)
	build_scan(SCAN_16X16[0][:], DEFAULT_SCAN_16X16[:], TX_16X16, 0)
	build_scan(SCAN_16X16[1][:], ROW_SCAN_16X16[:], TX_16X16, 1)
	build_scan(SCAN_16X16[2][:], COL_SCAN_16X16[:], TX_16X16, 2)
	build_scan(SCAN_32X32[:], DEFAULT_SCAN_32X32[:], TX_32X32, 0)
}

// Neighbours above and to the left in the transform block; the row scan
// uses only the left one and the column scan only the one above.
@(private)
build_scan :: proc "contextless" (entries: []Scan_Entry, scan: []u16, tx, kind: int) {
	n := 4 << uint(tx)
	for pos, c in scan {
		p := int(pos)
		i, j := p / n, p % n
		a, l: int
		switch {
		case i > 0 && j > 0:
			a, l = p - n, p - 1
			if kind == 2 do l = a
			if kind == 1 do a = l
		case i > 0:
			a, l = p - n, p - n
		case:
			a, l = p - 1, p - 1
		}
		if c == 0 do a, l = 0, 0 // the first context comes from the neighbouring blocks
		band := tx == TX_4X4 ? COEFBAND_4X4[c] : COEFBAND_8X8PLUS[c]
		entries[c] = {u16(p), u16(a), u16(l), band, u8(i)}
	}
}
