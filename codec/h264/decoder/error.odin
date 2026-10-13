package h264_decoder

// Decode errors are machine-readable. Text is a separate diagnostic contract;
// admission and recovery must use the enum rather than match that text.
Error :: enum {
	None,
	Empty_NAL,
	Malformed_SPS,
	Malformed_PPS,
	Malformed_Slice_Header,
	No_Picture_Buffer,
	Allocation_Failed,
	Duplicate_Macroblock,
	Skip_Run_Out_Of_Range,
	Invalid_Macroblock_Type,
	Invalid_Chroma_Prediction_Mode,
	Invalid_Coded_Block_Pattern,
	Invalid_QP_Delta,
	Truncated_PCM,
	Invalid_Reference_Index,
	Invalid_Sub_Macroblock_Type,
	Unsupported_Chroma_Format,
	Unsupported_Bit_Depth,
	Unsupported_Transform_Bypass,
	Unsupported_Interlaced,
	Unsupported_Slice_Groups,
	Unsupported_Slice_Type,
	Unsupported_Data_Partitioning,
}

is_unsupported :: proc(err: Error) -> bool {
	#partial switch err {
	case .Unsupported_Chroma_Format,
	     .Unsupported_Bit_Depth,
	     .Unsupported_Transform_Bypass,
	     .Unsupported_Interlaced,
	     .Unsupported_Slice_Groups,
	     .Unsupported_Slice_Type,
	     .Unsupported_Data_Partitioning:
		return true
	case:
		return false
	}
}

error_description :: proc(err: Error) -> string {
	switch err {
	case .None:
		return ""
	case .Empty_NAL:
		return "empty NAL unit"
	case .Malformed_SPS:
		return "malformed SPS"
	case .Malformed_PPS:
		return "malformed PPS"
	case .Malformed_Slice_Header:
		return "malformed slice header"
	case .No_Picture_Buffer:
		return "no picture buffer available"
	case .Allocation_Failed:
		return "native picture storage allocation failed"
	case .Duplicate_Macroblock:
		return "macroblock decoded twice"
	case .Skip_Run_Out_Of_Range:
		return "mb_skip_run exceeds the picture"
	case .Invalid_Macroblock_Type:
		return "macroblock type out of range"
	case .Invalid_Chroma_Prediction_Mode:
		return "intra_chroma_pred_mode out of range"
	case .Invalid_Coded_Block_Pattern:
		return "coded_block_pattern out of range"
	case .Invalid_QP_Delta:
		return "mb_qp_delta out of range"
	case .Truncated_PCM:
		return "truncated I_PCM samples"
	case .Invalid_Reference_Index:
		return "reference index out of range"
	case .Invalid_Sub_Macroblock_Type:
		return "sub_mb_type out of range"
	case .Unsupported_Chroma_Format:
		return "only 4:2:0 chroma is supported"
	case .Unsupported_Bit_Depth:
		return "only 8-bit video is supported"
	case .Unsupported_Transform_Bypass:
		return "lossless transform bypass is not supported"
	case .Unsupported_Interlaced:
		return "interlaced coding is not supported"
	case .Unsupported_Slice_Groups:
		return "slice groups (FMO) are not supported"
	case .Unsupported_Slice_Type:
		return "SP/SI slices are not supported"
	case .Unsupported_Data_Partitioning:
		return "data partitioning is not supported"
	}
	return "unknown H.264 decode error"
}
