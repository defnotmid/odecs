#+build windows
package media_mediafoundation

import media ".."
import "core:fmt"
import win "core:sys/windows"

@(private)
State :: struct {
	mft:              ^IMFTransform,
	codec:            media.Codec,
	encode:           bool,
	provides_samples: bool, // the transform allocates its output samples
	out_size:         u32, // otherwise: our output sample's buffer size
	time:             i64, // input sample time, 100 ns units
	duration:         i64,
	// Decoding: the access unit being gathered, and the output format.
	au:               [dynamic]u8,
	au_has_vcl:       bool,
	frames:           int,
	coded_w, coded_h: int,
	crop:             [4]int, // x, y, width, height
	stride:           int, // MF_MT_DEFAULT_STRIDE, zero when absent
	depth:            int,
	planes:           [3][dynamic]u8,
	// Encoding: the sequence header for a first packet that lacks one.
	width, height:    int,
	sent_header:      bool,
	packet:           [dynamic]u8,
	detail:           [160]u8,
}

@(private)
platform_probe :: proc(config: media.Config) -> media.Error {
	if !ensure_api() do return .Unavailable
	s: State
	defer destroy_state(&s)
	return create_transform(&s, config)
}

@(private)
platform_open :: proc(session: ^media.Session, config: media.Config) -> media.Error {
	if !ensure_api() do return .Unavailable
	s := new(State)
	if err := create_transform(s, config); err != .None {
		destroy_state(s)
		free(s)
		return err
	}
	session.state = s
	session.close_impl = close_session
	session.drain_impl = drain_session
	if config.operation == .Decode {
		session.decode_impl = decode_session
	} else {
		session.video_impl = encode_session
	}
	return .None
}

@(private)
destroy_state :: proc(s: ^State) {
	release(s.mft)
	delete(s.au)
	for p in s.planes do delete(p)
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
new_type :: proc(subtype: ^GUID) -> ^IMFMediaType {
	t: ^IMFMediaType
	if api.MFCreateMediaType(&t) < 0 do return nil
	t->SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)
	t->SetGUID(&MF_MT_SUBTYPE, subtype)
	return t
}

@(private)
pack :: proc(hi, lo: int) -> u64 {
	return u64(u32(hi)) << 32 | u64(u32(lo))
}

// The first synchronous transform of the category that takes the
// configuration. Each candidate is activated and set up; the rest are
// released.
@(private)
create_transform :: proc(s: ^State, config: media.Config) -> media.Error {
	s.codec = config.codec
	s.encode = config.operation == .Encode
	compressed := config.codec == .H264 ? MFVideoFormat_H264 : MFVideoFormat_HEVC
	compressed_info := MFT_REGISTER_TYPE_INFO{MFMediaType_Video, compressed}
	raw_info := MFT_REGISTER_TYPE_INFO{MFMediaType_Video, MFVideoFormat_NV12}
	category := s.encode ? MFT_CATEGORY_VIDEO_ENCODER : MFT_CATEGORY_VIDEO_DECODER
	activates: [^]^IMFActivate
	count: u32
	flags: u32 = MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_LOCALMFT | MFT_ENUM_FLAG_SORTANDFILTER
	hr := s.encode ? api.MFTEnumEx(category, flags, &raw_info, &compressed_info, &activates, &count) : api.MFTEnumEx(category, flags, &compressed_info, nil, &activates, &count)
	if hr < 0 || count == 0 do return .Unavailable
	defer {
		for a in activates[:count] do release(a)
		free_com(activates)
	}
	for a in activates[:count] {
		object: rawptr
		if a->ActivateObject(&IID_IMFTransform, &object) < 0 do continue
		s.mft = (^IMFTransform)(object)
		ok := s.encode ? setup_encoder(s, config) : setup_decoder(s, config)
		if ok {
			s.mft->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0)
			s.mft->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0)
			return .None
		}
		release(s.mft)
		s.mft = nil
	}
	return .Unavailable
}

@(private)
setup_decoder :: proc(s: ^State, config: media.Config) -> bool {
	input := new_type(config.codec == .H264 ? &MFVideoFormat_H264 : &MFVideoFormat_HEVC)
	if input == nil do return false
	defer release(input)
	if config.width > 0 && config.height > 0 do input->SetUINT64(&MF_MT_FRAME_SIZE, pack(config.width, config.height))
	if s.mft->SetInputType(0, input, 0) < 0 do return false
	s.depth = config.bit_depth == 0 ? 8 : config.bit_depth
	s.duration = 333_333
	// Without a frame size the output type may wait for the first picture
	// (MF_E_TRANSFORM_STREAM_CHANGE).
	negotiate_output(s)
	return true
}

// Selects NV12 or P010 output and reads the picture geometry it carries.
@(private)
negotiate_output :: proc(s: ^State) -> bool {
	for i: u32 = 0; ; i += 1 {
		t: ^IMFMediaType
		if s.mft->GetOutputAvailableType(0, i, &t) < 0 do return false
		subtype: GUID
		t->GetGUID(&MF_MT_SUBTYPE, &subtype)
		if subtype != MFVideoFormat_NV12 && subtype != MFVideoFormat_P010 {release(t); continue}
		ok := s.mft->SetOutputType(0, t, 0) >= 0
		release(t)
		if !ok do continue
		s.depth = subtype == MFVideoFormat_P010 ? 10 : 8
		break
	}
	current: ^IMFMediaType
	if s.mft->GetOutputCurrentType(0, &current) < 0 do return false
	defer release(current)
	size: u64
	current->GetUINT64(&MF_MT_FRAME_SIZE, &size)
	s.coded_w, s.coded_h = int(size >> 32), int(u32(size))
	s.crop = {0, 0, s.coded_w, s.coded_h}
	Video_Area :: struct {
		offset_x_fract: u16,
		offset_x:       i16,
		offset_y_fract: u16,
		offset_y:       i16,
		width, height:  i32,
	}
	area: Video_Area
	written: u32
	if current->GetBlob(&MF_MT_MINIMUM_DISPLAY_APERTURE, cast([^]u8)&area, size_of(area), &written) >= 0 && written == size_of(area) && area.width > 0 && area.height > 0 {
		s.crop = {int(area.offset_x), int(area.offset_y), int(area.width), int(area.height)}
	}
	stride: u32
	s.stride = current->GetUINT32(&MF_MT_DEFAULT_STRIDE, &stride) >= 0 ? int(i32(stride)) : 0
	return refresh_stream_info(s)
}

@(private)
refresh_stream_info :: proc(s: ^State) -> bool {
	info: MFT_OUTPUT_STREAM_INFO
	if s.mft->GetOutputStreamInfo(0, &info) < 0 do return false
	s.provides_samples = info.flags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES) != 0
	size := info.size
	if size == 0 do size = u32(max(s.coded_w, s.width, 16) * max(s.coded_h, s.height, 16) * 3)
	s.out_size = size
	return true
}

@(private)
set_codec_value :: proc(codec: ^ICodecAPI, api: ^GUID, vt: u16, value: u64) {
	v := VARIANT {
		vt    = vt,
		value = value,
	}
	codec->SetValue(api, &v)
}

@(private)
setup_encoder :: proc(s: ^State, config: media.Config) -> bool {
	s.width, s.height = config.width, config.height
	num, den := config.frame_rate_num, config.frame_rate_den
	if num <= 0 || den <= 0 do num, den = 30, 1
	s.duration = i64(10_000_000) * i64(den) / i64(num)
	gop := config.gop_size == 0 ? 15 : config.gop_size
	qp := u64(clamp(config.qp == 0 ? 23 : config.qp, 1, 51))
	// Rate control is set before the media types, which some encoders
	// require. An encoder that refuses a setting keeps its default.
	object: rawptr
	if s.mft->QueryInterface(&IID_ICodecAPI, &object) >= 0 {
		codec := (^ICodecAPI)(object)
		set_codec_value(codec, &CODECAPI_AVEncCommonRateControlMode, VT_UI4, eAVEncCommonRateControlMode_Quality)
		set_codec_value(codec, &CODECAPI_AVEncVideoEncodeQP, VT_UI8, qp | qp << 16 | qp << 32)
		set_codec_value(codec, &CODECAPI_AVEncMPVGOPSize, VT_UI4, u64(gop))
		set_codec_value(codec, &CODECAPI_AVEncMPVDefaultBPictureCount, VT_UI4, 0)
		release(codec)
	}
	attributes: ^IMFAttributes
	if s.mft->GetAttributes(&attributes) >= 0 {
		attributes->SetUINT32(&MF_LOW_LATENCY, 1)
		release(attributes)
	}
	output := new_type(config.codec == .H264 ? &MFVideoFormat_H264 : &MFVideoFormat_HEVC)
	if output == nil do return false
	defer release(output)
	output->SetUINT64(&MF_MT_FRAME_SIZE, pack(s.width, s.height))
	output->SetUINT64(&MF_MT_FRAME_RATE, pack(num, den))
	output->SetUINT64(&MF_MT_PIXEL_ASPECT_RATIO, pack(1, 1))
	output->SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive)
	// Required by the encoders; the quality mode governs the actual rate.
	output->SetUINT32(&MF_MT_AVG_BITRATE, u32(clamp(s.width * s.height * num / den / 4, 100_000, 100_000_000)))
	output->SetUINT32(&MF_MT_MPEG2_PROFILE, config.codec == .H264 ? eAVEncH264VProfile_High : eAVEncH265VProfile_Main_420_8)
	if s.mft->SetOutputType(0, output, 0) < 0 do return false
	input := new_type(&MFVideoFormat_NV12)
	if input == nil do return false
	defer release(input)
	input->SetUINT64(&MF_MT_FRAME_SIZE, pack(s.width, s.height))
	input->SetUINT64(&MF_MT_FRAME_RATE, pack(num, den))
	input->SetUINT64(&MF_MT_PIXEL_ASPECT_RATIO, pack(1, 1))
	input->SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive)
	input->SetUINT32(&MF_MT_DEFAULT_STRIDE, u32(s.width))
	if s.mft->SetInputType(0, input, 0) < 0 do return false
	return refresh_stream_info(s)
}

// A sample holding a copy of data, or nil.
@(private)
new_sample :: proc(size: int) -> (sample: ^IMFSample, buffer: ^IMFMediaBuffer, data: []u8) {
	if api.MFCreateSample(&sample) < 0 do return
	if api.MFCreateMemoryBuffer(u32(size), &buffer) < 0 {release(sample); return nil, nil, nil}
	sample->AddBuffer(buffer)
	p: [^]u8
	if buffer->Lock(&p, nil, nil) < 0 {release(buffer); release(sample); return nil, nil, nil}
	return sample, buffer, p[:size]
}

@(private)
submit :: proc(session: ^media.Session, s: ^State, size: int, fill: proc(dst: []u8, user: rawptr), user: rawptr, receiver: media.Receiver) -> media.Error {
	sample, buffer, dst := new_sample(size)
	if sample == nil {session.error_detail = "Media Foundation: sample allocation failed"; return .Codec_Error}
	defer release(sample)
	fill(dst, user)
	buffer->Unlock()
	buffer->SetCurrentLength(u32(len(dst)))
	release(buffer)
	sample->SetSampleTime(s.time)
	sample->SetSampleDuration(s.duration)
	s.time += s.duration
	for attempt in 0 ..< 2 {
		hr := s.mft->ProcessInput(0, sample, 0)
		if hr >= 0 do break
		if hr != MF_E_NOTACCEPTING || attempt == 1 {fail(session, s, "ProcessInput", hr); return .Codec_Error}
		if e := pull(session, s, receiver); e != .None do return e
	}
	return pull(session, s, receiver)
}

// Takes every output the transform has ready.
@(private)
pull :: proc(session: ^media.Session, s: ^State, receiver: media.Receiver) -> media.Error {
	for {
		out := MFT_OUTPUT_DATA_BUFFER{}
		if !s.provides_samples {
			// A fresh sample for each call: the decoder may still hold the last.
			buffer: ^IMFMediaBuffer
			out.sample, buffer, _ = new_sample(int(s.out_size))
			if out.sample == nil {session.error_detail = "Media Foundation: sample allocation failed"; return .Codec_Error}
			buffer->Unlock()
			release(buffer)
		}
		status: u32
		hr := s.mft->ProcessOutput(0, 1, &out, &status)
		release(out.events)
		if hr == MF_E_TRANSFORM_NEED_MORE_INPUT {release(out.sample); return .None}
		if hr == MF_E_TRANSFORM_STREAM_CHANGE {
			release(out.sample)
			if !negotiate_output(s) {session.error_detail = "Media Foundation: no NV12 or P010 output"; return .Unsupported}
			continue
		}
		if hr < 0 {release(out.sample); fail(session, s, "ProcessOutput", hr); return .Codec_Error}
		if out.sample == nil do continue
		e := s.encode ? emit_packet(session, s, out.sample, receiver) : emit_frame(session, s, out.sample, receiver)
		release(out.sample)
		if e != .None do return e
	}
}

@(private)
emit_frame :: proc(session: ^media.Session, s: ^State, sample: ^IMFSample, receiver: media.Receiver) -> media.Error {
	buffer: ^IMFMediaBuffer
	if sample->ConvertToContiguousBuffer(&buffer) < 0 {session.error_detail = "Media Foundation: no output buffer"; return .Codec_Error}
	defer release(buffer)
	base: [^]u8
	pitch: int
	object: rawptr
	if buffer->QueryInterface(&IID_IMF2DBuffer, &object) >= 0 {
		b2 := (^IMF2DBuffer)(object)
		defer release(b2)
		p: i32
		if b2->Lock2D(&base, &p) < 0 {session.error_detail = "Media Foundation: output lock failed"; return .Codec_Error}
		defer b2->Unlock2D()
		pitch = int(p)
		return copy_frame(s, base, pitch, receiver)
	}
	if buffer->Lock(&base, nil, nil) < 0 {session.error_detail = "Media Foundation: output lock failed"; return .Codec_Error}
	defer buffer->Unlock()
	bytes := s.depth > 8 ? 2 : 1
	pitch = s.stride > 0 ? s.stride : s.coded_w * bytes
	return copy_frame(s, base, pitch, receiver)
}

// Copies the visible picture out of NV12 or P010 (10 bits in each u16's
// high bits) into tight planar planes.
@(private)
copy_frame :: proc(s: ^State, base: [^]u8, pitch: int, receiver: media.Receiver) -> media.Error {
	x0, y0, w, h := s.crop[0], s.crop[1], s.crop[2], s.crop[3]
	if w <= 0 || h <= 0 || x0 + w > s.coded_w || y0 + h > s.coded_h do return .Codec_Error
	bytes := s.depth > 8 ? 2 : 1
	cw, ch := (w + 1) / 2, (h + 1) / 2
	resize(&s.planes[0], w * h * bytes)
	resize(&s.planes[1], cw * ch * bytes)
	resize(&s.planes[2], cw * ch * bytes)
	uv := base[pitch * s.coded_h:]
	if bytes == 1 {
		for y in 0 ..< h do copy(s.planes[0][y * w:][:w], base[(y0 + y) * pitch + x0:][:w])
		for y in 0 ..< ch {
			row := uv[(y0 / 2 + y) * pitch + (x0 / 2) * 2:]
			u, v := s.planes[1][y * cw:][:cw], s.planes[2][y * cw:][:cw]
			for x in 0 ..< cw {u[x] = row[2 * x]; v[x] = row[2 * x + 1]}
		}
	} else {
		luma := ([^]u16)(raw_data(s.planes[0]))
		for y in 0 ..< h {
			row := ([^]u16)(&base[(y0 + y) * pitch + x0 * 2])
			for x in 0 ..< w do luma[y * w + x] = row[x] >> 6
		}
		u, v := ([^]u16)(raw_data(s.planes[1])), ([^]u16)(raw_data(s.planes[2]))
		for y in 0 ..< ch {
			row := ([^]u16)(&uv[(y0 / 2 + y) * pitch + (x0 / 2) * 4])
			for x in 0 ..< cw {u[y * cw + x] = row[2 * x] >> 6; v[y * cw + x] = row[2 * x + 1] >> 6}
		}
	}
	frame := media.Video_Frame {
		width        = w,
		height       = h,
		coded_width  = s.coded_w,
		coded_height = s.coded_h,
		crop_x       = x0,
		crop_y       = y0,
		bit_depth    = s.depth,
		storage_bits = 8 * bytes,
		chroma       = .YUV420,
		poc          = s.frames,
		storage      = .Host,
		planes       = {{s.planes[0][:], w * bytes}, {s.planes[1][:], cw * bytes}, {s.planes[2][:], cw * bytes}},
	}
	s.frames += 1
	if receiver.video != nil do receiver.video(frame, receiver.user)
	return .None
}

// Whether a NAL unit begins a new access unit, and whether it is a slice of
// the base layer (an HEVC alpha layer's units are left out).
@(private)
classify :: proc(codec: media.Codec, nal: []u8) -> (starts, vcl, keep: bool) {
	if codec == .H264 {
		if len(nal) < 2 do return false, false, true
		t := nal[0] & 0x1f
		if t == 1 || t == 5 do return nal[1] & 0x80 != 0, true, true // first_mb_in_slice == 0
		return t == 6 || t == 7 || t == 8 || t == 9 || (t >= 14 && t <= 18), false, true
	}
	if len(nal) < 3 do return false, false, true
	t := (nal[0] >> 1) & 0x3f
	layer := (nal[0] & 1) << 5 | nal[1] >> 3
	if layer != 0 do return false, false, false
	if t < 32 do return nal[2] & 0x80 != 0, true, true // first_slice_segment_in_pic_flag
	return t <= 35 || t == 39 || (t >= 41 && t <= 44) || (t >= 48 && t <= 55), false, true
}

@(private)
flush_au :: proc(session: ^media.Session, s: ^State, receiver: media.Receiver) -> media.Error {
	if !s.au_has_vcl do return .None
	defer {clear(&s.au); s.au_has_vcl = false}
	return submit(session, s, len(s.au), proc(dst: []u8, user: rawptr) {copy(dst, (^[dynamic]u8)(user)[:])}, &s.au, receiver)
}

@(private)
decode_session :: proc(session: ^media.Session, packet: media.Packet, receiver: media.Receiver) -> media.Error {
	s := (^State)(session.state)
	com()
	it := media.Nal_Iterator {
		packet = packet,
	}
	for {
		nal, done, err := media.next_nal(&it)
		if err != .None do return err
		if done do return .None
		starts, vcl, keep := classify(s.codec, nal)
		if !keep do continue
		if starts && s.au_has_vcl {
			if e := flush_au(session, s, receiver); e != .None do return e
		}
		append(&s.au, 0, 0, 0, 1)
		append(&s.au, ..nal)
		s.au_has_vcl ||= vcl
	}
}

@(private)
drain_session :: proc(session: ^media.Session, receiver: media.Receiver) -> media.Error {
	s := (^State)(session.state)
	com()
	if !s.encode {
		if e := flush_au(session, s, receiver); e != .None do return e
	}
	s.mft->ProcessMessage(MFT_MESSAGE_COMMAND_DRAIN, 0)
	return pull(session, s, receiver)
}

// NV12 at a stride of the width: luma, then interleaved Cb and Cr.
@(private)
fill_nv12 :: proc(dst: []u8, user: rawptr) {
	f := (^media.Video_Frame)(user)
	w, h := f.width, f.height
	for y in 0 ..< h do copy(dst[y * w:][:w], f.planes[0].data[y * f.planes[0].stride:][:w])
	uv := dst[w * h:]
	cw, ch := w / 2, h / 2
	for y in 0 ..< ch {
		row := uv[y * w:][:w]
		if f.chroma_interleaved {
			copy(row, f.planes[1].data[y * f.planes[1].stride:][:w])
		} else {
			u, v := f.planes[1].data[y * f.planes[1].stride:], f.planes[2].data[y * f.planes[2].stride:]
			for x in 0 ..< cw {row[2 * x] = u[x]; row[2 * x + 1] = v[x]}
		}
	}
}

@(private)
encode_session :: proc(session: ^media.Session, frame: media.Video_Frame, receiver: media.Receiver) -> media.Error {
	s := (^State)(session.state)
	if frame.storage != .Host || frame.storage_bits != 8 || frame.chroma != .YUV420 do return .Unsupported
	if frame.width != s.width || frame.height != s.height do return .Invalid_Input
	com()
	frame := frame
	return submit(session, s, s.width * s.height * 3 / 2, fill_nv12, &frame, receiver)
}

// Annex B NAL unit types in data: whether it carries an SPS.
@(private)
has_sps :: proc(codec: media.Codec, data: []u8) -> bool {
	for i := 0; i + 3 < len(data); i += 1 {
		if data[i] != 0 || data[i + 1] != 0 || data[i + 2] != 1 do continue
		b := data[i + 3]
		if codec == .H264 ? b & 0x1f == 7 : (b >> 1) & 0x3f == 33 do return true
	}
	return false
}

@(private)
emit_packet :: proc(session: ^media.Session, s: ^State, sample: ^IMFSample, receiver: media.Receiver) -> media.Error {
	buffer: ^IMFMediaBuffer
	if sample->ConvertToContiguousBuffer(&buffer) < 0 {session.error_detail = "Media Foundation: no output buffer"; return .Codec_Error}
	defer release(buffer)
	p: [^]u8
	length: u32
	if buffer->Lock(&p, nil, &length) < 0 {session.error_detail = "Media Foundation: output lock failed"; return .Codec_Error}
	defer buffer->Unlock()
	data := p[:length]
	clean: u32
	sample->GetUINT32(&MFSampleExtension_CleanPoint, &clean)
	if !s.sent_header && !has_sps(s.codec, data) {
		// The parameter sets went to the output type instead of the stream.
		current: ^IMFMediaType
		if s.mft->GetOutputCurrentType(0, &current) >= 0 {
			size: u32
			if current->GetBlobSize(&MF_MT_MPEG_SEQUENCE_HEADER, &size) >= 0 && size > 0 {
				resize(&s.packet, int(size))
				current->GetBlob(&MF_MT_MPEG_SEQUENCE_HEADER, raw_data(s.packet), size, nil)
				append(&s.packet, ..data)
				data = s.packet[:]
			}
			release(current)
		}
	}
	s.sent_header = true
	if receiver.packet != nil do receiver.packet({data = data, framing = .Annex_B, keyframe = clean != 0}, receiver.user)
	return .None
}

// The output of CoTaskMemAlloc (MFTEnumEx's array).
@(private)
free_com :: proc(p: rawptr) {
	if p != nil do win.CoTaskMemFree(p)
}

// The failing call and its HRESULT, in the session's buffer.
@(private)
fail :: proc(session: ^media.Session, s: ^State, call: string, hr: HRESULT) {
	session.error_detail = fmt.bprintf(s.detail[:], "Media Foundation: %s failed (HRESULT 0x%08x, frame %d, %dx%d, own samples %v of %d bytes)", call, u32(hr), s.frames, s.coded_w, s.coded_h, !s.provides_samples, s.out_size)
}
