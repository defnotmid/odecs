package media_videotoolbox

// A VideoToolbox decompression session decoding one picture per call,
// synchronously, so pictures come back in decode order. The session's
// address is VideoToolbox's callback context: do not move it while open.
Session :: struct {
	codec:        Codec,
	format:       CMFormatDescriptionRef,
	vt:           VTDecompressionSessionRef,
	output:       u32, // the pixel format requested of the session
	image:        CVPixelBufferRef, // the output callback's picture, retained
	status:       i32, // the last OSStatus VideoToolbox returned, for diagnostics
	pixel_format: u32, // the last picture's CoreVideo format (a FourCC)
}

hardware_decode_supported :: proc(codec: Codec) -> bool {
	return bool(VTIsHardwareDecodeSupported(codec == .H264 ? CODEC_H264 : CODEC_HEVC))
}

@(private)
on_output :: proc "c" (ref_con, frame_ref_con: rawptr, status: OSStatus, info_flags: u32, image: CVPixelBufferRef, pts, duration: CMTime) {
	s := (^Session)(ref_con)
	s.status = status
	if status == 0 && image != nil && info_flags & VT_DECODE_INFO_FRAME_DROPPED == 0 do s.image = CVBufferRetain(image)
}

// Describes the stream with its parameter sets (NAL units without start
// codes: H.264 SPS then PPSs, HEVC VPS, SPS then PPSs), keeping the session
// when it accepts the description and opening a new one otherwise. Call it
// between pictures only. The session always asks for a documented layout,
// NV12 or (at 10 bits) P010-style 16-bit samples, in the stream's range so
// nothing is rescaled: a decoder's own format can differ between chips (the
// M4's at 10 bits is a private packed one).
session_set_format :: proc(s: ^Session, codec: Codec, parameter_sets: [][]u8, bit_depth: int, full_range: bool) -> Error {
	output: u32 = full_range ? PIXEL_NV12_FULL : PIXEL_NV12_VIDEO
	if bit_depth > 8 do output = full_range ? PIXEL_P010_FULL : PIXEL_P010_VIDEO
	if len(parameter_sets) == 0 || len(parameter_sets) > MAX_PARAMETER_SETS do return .Invalid_Argument
	pointers: [MAX_PARAMETER_SETS][^]u8
	sizes: [MAX_PARAMETER_SETS]uint
	for set, i in parameter_sets do pointers[i], sizes[i] = raw_data(set), uint(len(set))
	format: CMFormatDescriptionRef
	n := uint(len(parameter_sets))
	if codec == .H264 {
		s.status = CMVideoFormatDescriptionCreateFromH264ParameterSets(nil, n, &pointers[0], &sizes[0], 4, &format)
	} else {
		s.status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(nil, n, &pointers[0], &sizes[0], 4, nil, &format)
	}
	if s.status != 0 do return .Unsupported
	if s.vt != nil && s.codec == codec && s.output == output && bool(VTDecompressionSessionCanAcceptFormatDescription(s.vt, format)) {
		CFRelease(CFTypeRef(s.format))
		s.format = format
		return .None
	}
	session_destroy(s)
	s.codec, s.format, s.output = codec, format, output
	keys := [1]rawptr{rawptr(kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder)}
	values := [1]rawptr{rawptr(kCFBooleanTrue)}
	specification := CFDictionaryCreate(nil, &keys[0], &values[0], 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks)
	defer CFRelease(CFTypeRef(specification))
	callback := VTDecompressionOutputCallbackRecord{on_output, s}
	format_type := i32(output)
	number := CFNumberCreate(nil, CF_NUMBER_SINT32, &format_type)
	defer CFRelease(CFTypeRef(number))
	attribute_keys := [1]rawptr{rawptr(kCVPixelBufferPixelFormatTypeKey)}
	attribute_values := [1]rawptr{rawptr(number)}
	attributes := CFDictionaryCreate(nil, &attribute_keys[0], &attribute_values[0], 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks)
	defer CFRelease(CFTypeRef(attributes))
	s.status = VTDecompressionSessionCreate(nil, s.format, specification, attributes, &callback, &s.vt)
	if s.status != 0 {
		s.vt = nil
		return .Unavailable
	}
	return .None
}

// Decodes one whole picture (length-prefixed NAL units) into f, whose
// planes, strides, size and depth are set.
session_decode :: proc(s: ^Session, sample: []u8, f: ^Frame) -> Error {
	if s.vt == nil || len(sample) == 0 do return .Invalid_Argument
	block: CMBlockBufferRef
	// kCFAllocatorNull: the block borrows sample and never frees it.
	s.status = CMBlockBufferCreateWithMemoryBlock(nil, raw_data(sample), uint(len(sample)), kCFAllocatorNull, nil, 0, uint(len(sample)), 0, &block)
	if s.status != 0 do return .Decoder_Error
	defer CFRelease(CFTypeRef(block))
	buffer: CMSampleBufferRef
	size := uint(len(sample))
	s.status = CMSampleBufferCreateReady(nil, block, s.format, 1, 0, nil, 1, &size, &buffer)
	if s.status != 0 do return .Decoder_Error
	defer CFRelease(CFTypeRef(buffer))
	s.image = nil
	info: u32
	status := VTDecompressionSessionDecodeFrame(s.vt, buffer, 0, nil, &info)
	VTDecompressionSessionWaitForAsynchronousFrames(s.vt)
	if status != 0 do s.status = status
	if s.image == nil do return .Decoder_Error
	defer {CVBufferRelease(s.image); s.image = nil}
	return copy_image(s, s.image, f)
}

@(private)
copy_image :: proc(s: ^Session, image: CVPixelBufferRef, f: ^Frame) -> Error {
	format := CVPixelBufferGetPixelFormatType(image)
	s.pixel_format = format
	high_depth := format == PIXEL_P010_VIDEO || format == PIXEL_P010_FULL
	if !high_depth && format != PIXEL_NV12_VIDEO && format != PIXEL_NV12_FULL do return .Unsupported
	if high_depth != (f.storage_bits == 16) do return .Unsupported
	if CVPixelBufferLockBaseAddress(image, CV_PIXEL_BUFFER_LOCK_READ_ONLY) != 0 do return .Decoder_Error
	defer CVPixelBufferUnlockBaseAddress(image, CV_PIXEL_BUFFER_LOCK_READ_ONLY)
	width, height := int(CVPixelBufferGetWidth(image)), int(CVPixelBufferGetHeight(image))
	// The whole coded picture: the session's SPS has no cropping (parameters.odin).
	if width < f.crop_x + f.width || height < f.crop_y + f.height do return .Unsupported
	planes: [2][]u8
	strides: [2]int
	for i in 0 ..< 2 {
		base := CVPixelBufferGetBaseAddressOfPlane(image, uint(i))
		if base == nil do return .Decoder_Error
		strides[i] = int(CVPixelBufferGetBytesPerRowOfPlane(image, uint(i)))
		planes[i] = ([^]u8)(base)[:strides[i] * int(CVPixelBufferGetHeightOfPlane(image, uint(i)))]
	}
	copy_semi_planar(f, planes[0], strides[0], planes[1], strides[1], f.crop_x, f.crop_y)
	return .None
}

session_destroy :: proc(s: ^Session) {
	if s.vt != nil {
		VTDecompressionSessionWaitForAsynchronousFrames(s.vt)
		VTDecompressionSessionInvalidate(s.vt)
		CFRelease(CFTypeRef(s.vt))
	}
	if s.format != nil do CFRelease(CFTypeRef(s.format))
	if s.image != nil do CVBufferRelease(s.image)
	s^ = {}
}
