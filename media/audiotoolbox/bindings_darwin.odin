#+build darwin
package media_audiotoolbox

// The AudioConverter and AudioFormat calls the provider uses, declared from
// the macOS SDK's AudioToolbox and CoreAudioTypes headers (macOS 10.3 and
// later).

foreign import audio_toolbox "system:AudioToolbox.framework"

OSStatus :: i32
AudioConverterRef :: distinct rawptr

AudioStreamBasicDescription :: struct {
	sample_rate:       f64,
	format_id:         u32,
	format_flags:      u32,
	bytes_per_packet:  u32,
	frames_per_packet: u32,
	bytes_per_frame:   u32,
	channels:          u32,
	bits_per_channel:  u32,
	reserved:          u32,
}

AudioStreamPacketDescription :: struct {
	start_offset:              i64,
	variable_frames_in_packet: u32,
	data_byte_size:            u32,
}

AudioBuffer :: struct {
	channels:  u32,
	byte_size: u32,
	data:      rawptr,
}

AudioBufferList :: struct {
	count:   u32,
	buffers: [1]AudioBuffer,
}

AudioConverterPrimeInfo :: struct {
	leading_frames, trailing_frames: u32,
}

AudioFormatInfo :: struct {
	asbd:        AudioStreamBasicDescription,
	cookie:      rawptr,
	cookie_size: u32,
}

AudioFormatListItem :: struct {
	asbd:               AudioStreamBasicDescription,
	channel_layout_tag: u32,
}

AudioConverterComplexInputDataProc :: #type proc "c" (
	converter: AudioConverterRef,
	packets: ^u32,
	data: ^AudioBufferList,
	descriptions: ^^AudioStreamPacketDescription,
	user: rawptr,
) -> OSStatus

@(default_calling_convention = "c")
foreign audio_toolbox {
	AudioConverterNew :: proc(source, destination: ^AudioStreamBasicDescription, converter: ^AudioConverterRef) -> OSStatus ---
	AudioConverterDispose :: proc(converter: AudioConverterRef) -> OSStatus ---
	AudioConverterSetProperty :: proc(converter: AudioConverterRef, id: u32, size: u32, data: rawptr) -> OSStatus ---
	AudioConverterGetProperty :: proc(converter: AudioConverterRef, id: u32, size: ^u32, data: rawptr) -> OSStatus ---
	AudioConverterFillComplexBuffer :: proc(converter: AudioConverterRef, input: AudioConverterComplexInputDataProc, user: rawptr, packets: ^u32, output: ^AudioBufferList, descriptions: ^AudioStreamPacketDescription) -> OSStatus ---
	AudioFormatGetProperty :: proc(id: u32, specifier_size: u32, specifier: rawptr, size: ^u32, data: rawptr) -> OSStatus ---
}

kAudioFormatLinearPCM :: 0x6c70636d // 'lpcm'
kAudioFormatMPEG4AAC :: 0x61616320 // 'aac '
kAudioFormatFlagIsFloat :: 1 << 0
kAudioFormatFlagIsPacked :: 1 << 3
kAudioConverterPrimeInfo :: 0x7072696d // 'prim'
kAudioConverterDecompressionMagicCookie :: 0x646d6763 // 'dmgc'
kAudioConverterEncodeBitRate :: 0x62726174 // 'brat'
kAudioFormatProperty_FormatInfo :: 0x666d7469 // 'fmti'
kAudioFormatProperty_FormatList :: 0x666c7374 // 'flst'
