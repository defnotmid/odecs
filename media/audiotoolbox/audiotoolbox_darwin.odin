#+build darwin
package media_audiotoolbox

import media ".."
import "core:fmt"

// The input procs' status when they have nothing more for this call; the
// converter returns it with what it produced.
@(private)
NO_MORE :: OSStatus(1)

@(private)
State :: struct {
	converter:    AudioConverterRef,
	encode:       bool,
	channels:     int,
	sample_rate:  int, // the configuration's
	out_rate:     f64, // decoded rate (HE-AAC: twice the core)
	next_index:   i64,
	detail:       [96]u8,
	// Decoding: the AudioSpecificConfig, the packet the input proc hands
	// over, and the PCM it decodes to.
	asc:          [dynamic]u8,
	input:        []u8,
	input_given:  bool,
	description:  AudioStreamPacketDescription,
	pcm:          [dynamic]f32,
	// Encoding: two PCM frames in turn (the converter may read the last one
	// until the next input call), the next sample to hand over, and the
	// packet buffer.
	slots:        [2][dynamic]f32,
	slot:         int,
	offset:       int,
	slot_frames:  int,
	end_of_input: bool,
	packet:       [dynamic]u8,
}

@(private)
platform_probe :: proc(config: media.Config) -> media.Error {
	s: State
	defer destroy_state(&s)
	if config.operation == .Decode && len(config.extradata) == 0 do return .None // ADTS: configured by its first header
	return create_converter(&s, config)
}

@(private)
platform_open :: proc(session: ^media.Session, config: media.Config) -> media.Error {
	s := new(State)
	s.encode = config.operation == .Encode
	s.channels, s.sample_rate = config.channels, config.sample_rate
	if !s.encode && len(config.extradata) == 0 {
		// ADTS: the converter waits for the first header.
	} else if err := create_converter(s, config); err != .None {
		destroy_state(s)
		free(s)
		return err
	}
	session.state = s
	session.close_impl = close_session
	session.drain_impl = drain_session
	if s.encode {
		session.audio_impl = encode_session
	} else {
		session.decode_impl = decode_session
	}
	return .None
}

@(private)
destroy_state :: proc(s: ^State) {
	if s.converter != nil do AudioConverterDispose(s.converter)
	delete(s.asc)
	delete(s.pcm)
	for slot in s.slots do delete(slot)
	delete(s.packet)
	s^ = {}
}

@(private)
close_session :: proc(session: ^media.Session) {
	s := (^State)(session.state)
	destroy_state(s)
	free(s)
}

@(private)
fail :: proc(session: ^media.Session, s: ^State, call: string, status: OSStatus) -> media.Error {
	session.error_detail = fmt.bprintf(s.detail[:], "AudioToolbox: %s failed (OSStatus %d)", call, status)
	return .Codec_Error
}

@(private)
pcm_format :: proc(rate: f64, channels: int) -> AudioStreamBasicDescription {
	return {
		sample_rate = rate,
		format_id = kAudioFormatLinearPCM,
		format_flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
		bytes_per_packet = u32(4 * channels),
		frames_per_packet = 1,
		bytes_per_frame = u32(4 * channels),
		channels = u32(channels),
		bits_per_channel = 32,
	}
}

// The MPEG-4 ES_Descriptor that carries an AudioSpecificConfig: the magic
// cookie AudioToolbox takes for AAC (an MP4 esds box's payload).
@(private)
append_esds :: proc(out: ^[dynamic]u8, asc: []u8) {
	n := u8(len(asc))
	append(out, 0x03, 3 + (2 + 13 + 2 + n) + 3, 0x00, 0x00, 0x00) // ES_Descriptor, ES_ID 0, no flags
	append(out, 0x04, 13 + 2 + n, 0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) // DecoderConfigDescriptor: MPEG-4 audio
	append(out, 0x05, n)
	append(out, ..asc)
	append(out, 0x06, 0x01, 0x02) // SLConfigDescriptor
}

@(private)
create_converter :: proc(s: ^State, config: media.Config) -> media.Error {
	if config.operation == .Encode {
		input := pcm_format(f64(config.sample_rate), config.channels)
		output := AudioStreamBasicDescription {
			sample_rate       = f64(config.sample_rate),
			format_id         = kAudioFormatMPEG4AAC,
			frames_per_packet = 1024,
			channels          = u32(config.channels),
		}
		if AudioConverterNew(&input, &output, &s.converter) != 0 do return .Unsupported
		if config.bit_rate > 0 {
			rate := u32(config.bit_rate)
			if AudioConverterSetProperty(s.converter, kAudioConverterEncodeBitRate, size_of(rate), &rate) != 0 do return .Unsupported
		}
		prime: AudioConverterPrimeInfo
		size := u32(size_of(prime))
		s.next_index = AudioConverterGetProperty(s.converter, kAudioConverterPrimeInfo, &size, &prime) == 0 ? -i64(prime.leading_frames) : -2112
		return .None
	}
	if len(s.asc) == 0 do append(&s.asc, ..config.extradata)
	return create_decoder(s)
}

@(private)
create_decoder :: proc(s: ^State) -> media.Error {
	if len(s.asc) == 0 || len(s.asc) > 64 do return .Invalid_Config
	cookie: [dynamic]u8
	defer delete(cookie)
	append_esds(&cookie, s.asc[:])
	info := AudioFormatInfo {
		asbd = {format_id = kAudioFormatMPEG4AAC},
		cookie = raw_data(cookie),
		cookie_size = u32(len(cookie)),
	}
	// The richest layer the stream signals: HE-AAC v2, HE-AAC or LC.
	items: [8]AudioFormatListItem
	size := u32(size_of(items))
	input: AudioStreamBasicDescription
	if AudioFormatGetProperty(kAudioFormatProperty_FormatList, size_of(info), &info, &size, &items[0]) == 0 && size >= size_of(AudioFormatListItem) {
		input = items[0].asbd
	} else {
		size = size_of(input)
		input = info.asbd
		if AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, info.cookie_size, info.cookie, &size, &input) != 0 do return .Unsupported
	}
	if input.channels < 1 || input.channels > 2 || input.sample_rate <= 0 do return .Unsupported
	s.channels = int(input.channels)
	s.out_rate = input.sample_rate
	output := pcm_format(input.sample_rate, s.channels)
	if AudioConverterNew(&input, &output, &s.converter) != 0 do return .Unsupported
	if AudioConverterSetProperty(s.converter, kAudioConverterDecompressionMagicCookie, info.cookie_size, info.cookie) != 0 do return .Unsupported
	return .None
}

@(private)
decode_input :: proc "c" (converter: AudioConverterRef, packets: ^u32, data: ^AudioBufferList, descriptions: ^^AudioStreamPacketDescription, user: rawptr) -> OSStatus {
	s := (^State)(user)
	if s.input_given || len(s.input) == 0 {
		packets^ = 0
		return s.end_of_input ? 0 : NO_MORE // zero packets and no error ends the stream
	}
	data.count = 1
	data.buffers[0] = {u32(s.channels), u32(len(s.input)), raw_data(s.input)}
	s.description = {0, 0, u32(len(s.input))}
	if descriptions != nil do descriptions^ = &s.description
	packets^ = 1
	s.input_given = true
	return 0
}

// Decodes one raw AAC frame, delivering its samples.
@(private)
decode_frame :: proc(session: ^media.Session, s: ^State, frame: []u8, index: i64, receiver: media.Receiver) -> media.Error {
	s.input, s.input_given = frame, false
	capacity := 4096
	resize(&s.pcm, capacity * s.channels)
	frames := u32(capacity)
	buffers := AudioBufferList{1, {{u32(s.channels), u32(len(s.pcm) * 4), raw_data(s.pcm)}}}
	status := AudioConverterFillComplexBuffer(s.converter, decode_input, s, &frames, &buffers, nil)
	if status != 0 && status != NO_MORE do return fail(session, s, "AudioConverterFillComplexBuffer", status)
	if frames == 0 do return .None
	if index != max(i64) do s.next_index = index
	if receiver.audio != nil {
		receiver.audio({samples = s.pcm[:int(frames) * s.channels], sample_rate = int(s.out_rate), channels = s.channels, samples_per_channel = int(frames), sample_index = s.next_index}, receiver.user)
	}
	s.next_index += i64(frames)
	return .None
}

@(private)
decode_session :: proc(session: ^media.Session, packet: media.Packet, receiver: media.Receiver) -> media.Error {
	s := (^State)(session.state)
	// A timed packet places the output: its index in the decoded rate.
	index := max(i64)
	if packet.sample_rate != 0 do index = i64(f64(packet.sample_index) * (s.out_rate > 0 ? s.out_rate : f64(packet.sample_rate)) / f64(packet.sample_rate))
	#partial switch packet.framing {
	case .Raw_AAC, .Frame:
		if s.converter == nil do return .Invalid_Input
		return decode_frame(session, s, packet.data, index, receiver)
	case .ADTS:
		data := packet.data
		for len(data) > 0 {
			if len(data) < 7 || data[0] != 0xff || data[1] & 0xf6 != 0xf0 do return .Invalid_Input
			header := data[1] & 1 != 0 ? 7 : 9 // protection_absent
			length := int(data[3] & 3) << 11 | int(data[4]) << 3 | int(data[5]) >> 5
			if data[6] & 3 != 0 || length < header || length > len(data) do return .Unsupported // several raw blocks per frame
			if s.converter == nil {
				object := (data[2] >> 6) + 1
				rate := (data[2] >> 2) & 0xf
				channels := (data[2] & 1) << 2 | data[3] >> 6
				append(&s.asc, object << 3 | rate >> 1, (rate & 1) << 7 | channels << 3)
				if e := create_decoder(s); e != .None {session.error_detail = "AudioToolbox: the ADTS configuration is not decodable"; return e}
				if s.out_rate > 0 && index != max(i64) do index = i64(f64(packet.sample_index) * s.out_rate / f64(packet.sample_rate))
			}
			if e := decode_frame(session, s, data[header:length], index, receiver); e != .None do return e
			index = max(i64)
			data = data[length:]
		}
		return .None
	}
	return .Unsupported
}

@(private)
encode_input :: proc "c" (converter: AudioConverterRef, packets: ^u32, data: ^AudioBufferList, descriptions: ^^AudioStreamPacketDescription, user: rawptr) -> OSStatus {
	s := (^State)(user)
	available := s.slot_frames - s.offset
	if available <= 0 {
		packets^ = 0
		return s.end_of_input ? 0 : NO_MORE // zero packets and no error ends the stream
	}
	n := min(int(packets^), available)
	data.count = 1
	data.buffers[0] = {u32(s.channels), u32(n * s.channels * 4), &s.slots[s.slot][s.offset * s.channels]}
	packets^ = u32(n)
	s.offset += n
	return 0
}

// Takes every packet the converter can make from the input it has.
@(private)
pump :: proc(session: ^media.Session, s: ^State, receiver: media.Receiver) -> media.Error {
	resize(&s.packet, 1536 * s.channels)
	for {
		count: u32 = 1
		description: AudioStreamPacketDescription
		buffers := AudioBufferList{1, {{u32(s.channels), u32(len(s.packet)), raw_data(s.packet)}}}
		status := AudioConverterFillComplexBuffer(s.converter, encode_input, s, &count, &buffers, &description)
		if status != 0 && status != NO_MORE do return fail(session, s, "AudioConverterFillComplexBuffer", status)
		if count == 0 do return .None
		size := description.data_byte_size != 0 ? int(description.data_byte_size) : int(buffers.buffers[0].byte_size)
		if receiver.packet != nil {
			receiver.packet({data = s.packet[:size], framing = .Raw_AAC, sample_index = s.next_index, duration_samples = 1024, sample_rate = s.sample_rate}, receiver.user)
		}
		s.next_index += 1024
	}
}

@(private)
encode_session :: proc(session: ^media.Session, frame: media.Audio_Frame, receiver: media.Receiver) -> media.Error {
	s := (^State)(session.state)
	s.slot = 1 - s.slot
	resize(&s.slots[s.slot], len(frame.samples))
	copy(s.slots[s.slot][:], frame.samples)
	s.offset, s.slot_frames = 0, frame.samples_per_channel
	return pump(session, s, receiver)
}

@(private)
drain_session :: proc(session: ^media.Session, receiver: media.Receiver) -> media.Error {
	s := (^State)(session.state)
	s.end_of_input = true
	if s.encode do return pump(session, s, receiver)
	// The decoder's last samples: what it holds back (HE-AAC's filter banks).
	if s.converter == nil do return .None
	for {
		before := s.next_index
		if e := decode_frame(session, s, nil, max(i64), receiver); e != .None do return e
		if s.next_index == before do return .None
	}
}
