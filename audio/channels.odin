package audio

// Every codec's channels come out in WAVE order: the speakers sorted as
// WAVE_FORMAT_EXTENSIBLE numbers them (FL, FR, FC, LFE, BL, BR, FLC, FRC,
// BC, SL, SR), as WAV, FLAC, ALAC, FFmpeg and miniaudio give them. AAC
// stores front, side, back, then LFE; Vorbis and Opus (mapping family 1)
// their own order. channel_order gives, for each WAVE-order channel, the
// codec's channel it comes from; reorder is false where they agree.
channel_order :: proc(codec: Codec, channels: int, opus_family := 1) -> (source: [8]u8, reorder: bool) {
	for &s, i in source do s = u8(i)
	if channels < 3 || channels > 8 do return
	@(static, rodata) aac := [9][8]u8 {
		3 = {1, 2, 0, 3, 4, 5, 6, 7}, // C L R
		4 = {1, 2, 0, 3, 4, 5, 6, 7}, // C L R BC
		5 = {1, 2, 0, 3, 4, 5, 6, 7}, // C L R BL BR
		6 = {1, 2, 0, 5, 3, 4, 6, 7}, // C L R BL BR LFE
		7 = {1, 2, 0, 5, 6, 3, 4, 7}, // C L R SL SR BL BR
		8 = {3, 4, 0, 7, 5, 6, 1, 2}, // C FLC FRC L R BL BR LFE
	}
	@(static, rodata) vorbis := [9][8]u8 {
		3 = {0, 2, 1, 3, 4, 5, 6, 7}, // L C R
		4 = {0, 1, 2, 3, 4, 5, 6, 7}, // FL FR BL BR
		5 = {0, 2, 1, 3, 4, 5, 6, 7}, // FL C FR BL BR
		6 = {0, 2, 1, 5, 3, 4, 6, 7}, // FL C FR BL BR LFE
		7 = {0, 2, 1, 6, 5, 3, 4, 7}, // FL C FR SL SR BC LFE
		8 = {0, 2, 1, 7, 5, 6, 3, 4}, // FL C FR SL SR BL BR LFE
	}
	#partial switch codec {
	case .AAC:
		source = aac[channels]
	case .Vorbis:
		source = vorbis[channels]
	case .Opus:
		if opus_family != 1 do return
		source = vorbis[channels]
	case:
		return
	}
	for s, i in source[:channels] do if int(s) != i do reorder = true
	return
}
