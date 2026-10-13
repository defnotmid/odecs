package h265_decoder

// Alpha_Use is alpha_channel_use_idc of an alpha channel information SEI
// message (F.14.3.8): how decoded colour relates to the alpha layer.
Alpha_Use :: enum u8 {
	Straight      = 0, // colour is multiplied by alpha when blending
	Premultiplied = 1, // colour is already multiplied by alpha
	Unspecified   = 2,
}

// Scans the messages of an SEI RBSP (7.3.5) for alpha channel information
// (payloadType 165). A cancelling message reports Unspecified.
parse_alpha_channel_info :: proc(rbsp: []u8) -> (use: Alpha_Use, found: bool) {
	pos := 0
	for pos + 2 <= len(rbsp) && rbsp[pos] != 0x80 {
		type, size := 0, 0
		for pos < len(rbsp) && rbsp[pos] == 0xFF {type += 255; pos += 1}
		if pos >= len(rbsp) do return
		type += int(rbsp[pos]); pos += 1
		for pos < len(rbsp) && rbsp[pos] == 0xFF {size += 255; pos += 1}
		if pos >= len(rbsp) do return
		size += int(rbsp[pos]); pos += 1
		if pos + size > len(rbsp) do return
		if type == 165 && size > 0 {
			c: Get_Bits
			get_bits_init(&c, rbsp[pos:][:size])
			if get_bits_bit(&c) != 0 do return .Unspecified, true // alpha_channel_cancel_flag
			idc := get_bits_bits(&c, 3)
			return idc <= 1 ? Alpha_Use(idc) : .Unspecified, !c.err
		}
		pos += size
	}
	return
}
