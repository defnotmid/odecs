package h265

Slice_Type :: enum u8 {
	B = 0,
	P = 1,
	I = 2,
}

// NAL unit types (Table 7-1)
Nal_Type :: enum u8 {
	TRAIL_N        = 0,
	TRAIL_R        = 1,
	TSA_N          = 2,
	TSA_R          = 3,
	STSA_N         = 4,
	STSA_R         = 5,
	RADL_N         = 6,
	RADL_R         = 7,
	RASL_N         = 8,
	RASL_R         = 9,
	BLA_W_LP       = 16,
	BLA_W_RADL     = 17,
	BLA_N_LP       = 18,
	IDR_W_RADL     = 19,
	IDR_N_LP       = 20,
	CRA_NUT        = 21,
	RSV_IRAP_VCL23 = 23,
	VPS_NUT        = 32,
	SPS_NUT        = 33,
	PPS_NUT        = 34,
	AUD_NUT        = 35,
	EOS_NUT        = 36,
	EOB_NUT        = 37,
	FD_NUT         = 38,
	PREFIX_SEI_NUT = 39,
	SUFFIX_SEI_NUT = 40,
}

Chroma_Format :: enum u32 {
	Monochrome = 0,
	YUV_420    = 1,
	YUV_422    = 2,
	YUV_444    = 3,
}

Color :: enum u8 {
	Y = 0,
	U = 1,
	V = 2,
}

Scan_Order :: enum u8 {
	Diag       = 0,
	Horizontal = 1,
	Vertical   = 2,
}
