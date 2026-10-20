package media_videotoolbox

// The parts of CoreFoundation, CoreMedia, CoreVideo and VideoToolbox the
// decoder and encoder use, declared from Apple's headers (macOS 11 and later;
// the frame QP limits are macOS 13).

foreign import core_foundation "system:CoreFoundation.framework"
foreign import core_media "system:CoreMedia.framework"
foreign import core_video "system:CoreVideo.framework"
foreign import video_toolbox "system:VideoToolbox.framework"

OSStatus :: i32
CFIndex :: int
CFTypeRef :: distinct rawptr
CFAllocatorRef :: distinct rawptr
CFStringRef :: distinct rawptr
CFNumberRef :: distinct rawptr
CFBooleanRef :: distinct rawptr
CFDictionaryRef :: distinct rawptr
CFArrayRef :: distinct rawptr
CMFormatDescriptionRef :: distinct rawptr
CMBlockBufferRef :: distinct rawptr
CMSampleBufferRef :: distinct rawptr
CVPixelBufferRef :: distinct rawptr
VTDecompressionSessionRef :: distinct rawptr
VTCompressionSessionRef :: distinct rawptr
CVPixelBufferPoolRef :: distinct rawptr

CFDictionaryKeyCallBacks :: struct {
	version:                                      CFIndex,
	retain, release, copy_description, equal, hash: rawptr,
}
CFDictionaryValueCallBacks :: struct {
	version:                                CFIndex,
	retain, release, copy_description, equal: rawptr,
}
CF_NUMBER_SINT32 :: 3
CF_NUMBER_FLOAT32 :: 5

CMTime :: struct {
	value:     i64,
	timescale: i32,
	flags:     u32,
	epoch:     i64,
}
CMVideoDimensions :: struct {
	width, height: i32,
}

// FourCCs.
CODEC_H264 :: 0x61766331 // 'avc1'
CODEC_HEVC :: 0x68766331 // 'hvc1'
PIXEL_NV12_VIDEO :: 0x34323076 // '420v': 8-bit 4:2:0, Y plane then interleaved CbCr
PIXEL_NV12_FULL :: 0x34323066 // '420f'
PIXEL_P010_VIDEO :: 0x78343230 // 'x420': 10-bit 4:2:0 in the high bits of 16
PIXEL_P010_FULL :: 0x78663230 // 'xf20'

CV_PIXEL_BUFFER_LOCK_READ_ONLY :: 1
VT_DECODE_INFO_FRAME_DROPPED :: 1 << 1

VTDecompressionOutputCallback :: #type proc "c" (
	decompression_output_ref_con: rawptr,
	source_frame_ref_con: rawptr,
	status: OSStatus,
	info_flags: u32,
	image_buffer: CVPixelBufferRef,
	presentation_time_stamp: CMTime,
	presentation_duration: CMTime,
)
VTDecompressionOutputCallbackRecord :: struct {
	callback: VTDecompressionOutputCallback,
	ref_con:  rawptr,
}
VTCompressionOutputCallback :: #type proc "c" (
	output_callback_ref_con: rawptr,
	source_frame_ref_con: rawptr,
	status: OSStatus,
	info_flags: u32,
	sample_buffer: CMSampleBufferRef,
)

@(default_calling_convention = "c")
foreign core_foundation {
	kCFAllocatorNull:              CFAllocatorRef
	kCFBooleanTrue:                CFBooleanRef
	kCFBooleanFalse:               CFBooleanRef
	kCFTypeDictionaryKeyCallBacks:   CFDictionaryKeyCallBacks
	kCFTypeDictionaryValueCallBacks: CFDictionaryValueCallBacks

	CFRetain :: proc(cf: CFTypeRef) -> CFTypeRef ---
	CFRelease :: proc(cf: CFTypeRef) ---
	CFArrayGetCount :: proc(array: CFArrayRef) -> CFIndex ---
	CFArrayGetValueAtIndex :: proc(array: CFArrayRef, index: CFIndex) -> rawptr ---
	CFDictionaryGetValue :: proc(dictionary: CFDictionaryRef, key: rawptr) -> rawptr ---
	CFNumberCreate :: proc(allocator: CFAllocatorRef, type: CFIndex, value: rawptr) -> CFNumberRef ---
	CFDictionaryCreate :: proc(allocator: CFAllocatorRef, keys: [^]rawptr, values: [^]rawptr, count: CFIndex, key_callbacks: ^CFDictionaryKeyCallBacks, value_callbacks: ^CFDictionaryValueCallBacks) -> CFDictionaryRef ---
}

@(default_calling_convention = "c")
foreign core_media {
	kCMTimeInvalid:                CMTime
	kCMSampleAttachmentKey_NotSync: CFStringRef

	CMVideoFormatDescriptionCreateFromH264ParameterSets :: proc(allocator: CFAllocatorRef, parameter_set_count: uint, parameter_set_pointers: [^][^]u8, parameter_set_sizes: [^]uint, nal_unit_header_length: i32, format_description_out: ^CMFormatDescriptionRef) -> OSStatus ---
	CMVideoFormatDescriptionCreateFromHEVCParameterSets :: proc(allocator: CFAllocatorRef, parameter_set_count: uint, parameter_set_pointers: [^][^]u8, parameter_set_sizes: [^]uint, nal_unit_header_length: i32, extensions: CFDictionaryRef, format_description_out: ^CMFormatDescriptionRef) -> OSStatus ---
	CMVideoFormatDescriptionGetDimensions :: proc(description: CMFormatDescriptionRef) -> CMVideoDimensions ---
	CMBlockBufferCreateWithMemoryBlock :: proc(structure_allocator: CFAllocatorRef, memory_block: rawptr, block_length: uint, block_allocator: CFAllocatorRef, custom_block_source: rawptr, offset_to_data: uint, data_length: uint, flags: u32, block_buffer_out: ^CMBlockBufferRef) -> OSStatus ---
	CMSampleBufferCreateReady :: proc(allocator: CFAllocatorRef, data_buffer: CMBlockBufferRef, format_description: CMFormatDescriptionRef, num_samples: int, num_sample_timing_entries: int, sample_timing_array: rawptr, num_sample_size_entries: int, sample_size_array: [^]uint, sample_buffer_out: ^CMSampleBufferRef) -> OSStatus ---
	CMSampleBufferGetDataBuffer :: proc(buffer: CMSampleBufferRef) -> CMBlockBufferRef ---
	CMSampleBufferGetFormatDescription :: proc(buffer: CMSampleBufferRef) -> CMFormatDescriptionRef ---
	CMSampleBufferGetSampleAttachmentsArray :: proc(buffer: CMSampleBufferRef, create_if_necessary: b8) -> CFArrayRef ---
	CMBlockBufferGetDataLength :: proc(buffer: CMBlockBufferRef) -> uint ---
	CMBlockBufferCopyDataBytes :: proc(buffer: CMBlockBufferRef, offset_to_data: uint, data_length: uint, destination: rawptr) -> OSStatus ---
	CMVideoFormatDescriptionGetH264ParameterSetAtIndex :: proc(description: CMFormatDescriptionRef, index: uint, pointer_out: ^[^]u8, size_out: ^uint, count_out: ^uint, nal_unit_header_length_out: ^i32) -> OSStatus ---
	CMVideoFormatDescriptionGetHEVCParameterSetAtIndex :: proc(description: CMFormatDescriptionRef, index: uint, pointer_out: ^[^]u8, size_out: ^uint, count_out: ^uint, nal_unit_header_length_out: ^i32) -> OSStatus ---
}

@(default_calling_convention = "c")
foreign core_video {
	kCVPixelBufferPixelFormatTypeKey: CFStringRef
	kCVImageBufferColorPrimaries_ITU_R_709_2: CFStringRef
	kCVImageBufferTransferFunction_ITU_R_709_2: CFStringRef
	kCVImageBufferYCbCrMatrix_ITU_R_709_2: CFStringRef

	CVBufferRetain :: proc(buffer: CVPixelBufferRef) -> CVPixelBufferRef ---
	CVBufferRelease :: proc(buffer: CVPixelBufferRef) ---
	CVPixelBufferLockBaseAddress :: proc(buffer: CVPixelBufferRef, flags: u64) -> i32 ---
	CVPixelBufferUnlockBaseAddress :: proc(buffer: CVPixelBufferRef, flags: u64) -> i32 ---
	CVPixelBufferGetPixelFormatType :: proc(buffer: CVPixelBufferRef) -> u32 ---
	CVPixelBufferGetWidth :: proc(buffer: CVPixelBufferRef) -> uint ---
	CVPixelBufferGetHeight :: proc(buffer: CVPixelBufferRef) -> uint ---
	CVPixelBufferGetPlaneCount :: proc(buffer: CVPixelBufferRef) -> uint ---
	CVPixelBufferGetBaseAddressOfPlane :: proc(buffer: CVPixelBufferRef, plane: uint) -> rawptr ---
	CVPixelBufferGetBytesPerRowOfPlane :: proc(buffer: CVPixelBufferRef, plane: uint) -> uint ---
	CVPixelBufferGetHeightOfPlane :: proc(buffer: CVPixelBufferRef, plane: uint) -> uint ---
	CVPixelBufferPoolCreatePixelBuffer :: proc(allocator: CFAllocatorRef, pool: CVPixelBufferPoolRef, buffer_out: ^CVPixelBufferRef) -> i32 ---
}

@(default_calling_convention = "c")
foreign video_toolbox {
	kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: CFStringRef
	kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: CFStringRef
	kVTCompressionPropertyKey_AllowFrameReordering: CFStringRef
	kVTCompressionPropertyKey_MaxKeyFrameInterval: CFStringRef
	kVTCompressionPropertyKey_ProfileLevel: CFStringRef
	kVTCompressionPropertyKey_MinAllowedFrameQP: CFStringRef
	kVTCompressionPropertyKey_MaxAllowedFrameQP: CFStringRef
	kVTCompressionPropertyKey_Quality: CFStringRef
	kVTCompressionPropertyKey_ColorPrimaries: CFStringRef
	kVTCompressionPropertyKey_TransferFunction: CFStringRef
	kVTCompressionPropertyKey_YCbCrMatrix: CFStringRef
	kVTEncodeFrameOptionKey_ForceKeyFrame: CFStringRef
	kVTProfileLevel_H264_High_AutoLevel: CFStringRef
	kVTProfileLevel_HEVC_Main_AutoLevel: CFStringRef


	VTIsHardwareDecodeSupported :: proc(codec_type: u32) -> b8 ---
	VTDecompressionSessionCreate :: proc(allocator: CFAllocatorRef, format_description: CMFormatDescriptionRef, decoder_specification: CFDictionaryRef, destination_image_buffer_attributes: CFDictionaryRef, output_callback: ^VTDecompressionOutputCallbackRecord, session_out: ^VTDecompressionSessionRef) -> OSStatus ---
	VTDecompressionSessionDecodeFrame :: proc(session: VTDecompressionSessionRef, sample_buffer: CMSampleBufferRef, decode_flags: u32, source_frame_ref_con: rawptr, info_flags_out: ^u32) -> OSStatus ---
	VTDecompressionSessionWaitForAsynchronousFrames :: proc(session: VTDecompressionSessionRef) -> OSStatus ---
	VTDecompressionSessionCanAcceptFormatDescription :: proc(session: VTDecompressionSessionRef, format_description: CMFormatDescriptionRef) -> b8 ---
	VTDecompressionSessionInvalidate :: proc(session: VTDecompressionSessionRef) ---
	VTSessionSetProperty :: proc(session: rawptr, key: CFStringRef, value: rawptr) -> OSStatus ---
	VTCompressionSessionCreate :: proc(allocator: CFAllocatorRef, width, height: i32, codec_type: u32, encoder_specification: CFDictionaryRef, source_image_buffer_attributes: CFDictionaryRef, compressed_data_allocator: CFAllocatorRef, output_callback: VTCompressionOutputCallback, output_callback_ref_con: rawptr, session_out: ^VTCompressionSessionRef) -> OSStatus ---
	VTCompressionSessionPrepareToEncodeFrames :: proc(session: VTCompressionSessionRef) -> OSStatus ---
	VTCompressionSessionGetPixelBufferPool :: proc(session: VTCompressionSessionRef) -> CVPixelBufferPoolRef ---
	VTCompressionSessionEncodeFrame :: proc(session: VTCompressionSessionRef, image_buffer: CVPixelBufferRef, presentation_time_stamp: CMTime, duration: CMTime, frame_properties: CFDictionaryRef, source_frame_ref_con: rawptr, info_flags_out: ^u32) -> OSStatus ---
	VTCompressionSessionCompleteFrames :: proc(session: VTCompressionSessionRef, complete_until_presentation_time_stamp: CMTime) -> OSStatus ---
	VTCompressionSessionInvalidate :: proc(session: VTCompressionSessionRef) ---
}
