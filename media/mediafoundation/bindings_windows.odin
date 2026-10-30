#+build windows
package media_mediafoundation

import "core:dynlib"
import "core:sync"
import win "core:sys/windows"

// The Media Foundation subset the provider calls, from the Windows SDK
// 10.0.26100 headers (mfobjects.h, mftransform.h, mfapi.h, codecapi.h).
// Vtables list every method up to the last one called, in header order;
// methods the provider never calls are rawptr.

HRESULT :: i32
GUID :: win.GUID

@(private)
IUnknown_VTable :: struct {
	QueryInterface: proc "system" (this: rawptr, riid: ^GUID, object: ^rawptr) -> HRESULT,
	AddRef:         proc "system" (this: rawptr) -> u32,
	Release:        proc "system" (this: rawptr) -> u32,
}

@(private)
IMFAttributes_VTable :: struct {
	using unknown:                                     IUnknown_VTable,
	GetItem, GetItemType, CompareItem, Compare:        rawptr,
	GetUINT32:                                         proc "system" (this: rawptr, key: ^GUID, value: ^u32) -> HRESULT,
	GetUINT64:                                         proc "system" (this: rawptr, key: ^GUID, value: ^u64) -> HRESULT,
	GetDouble:                                         rawptr,
	GetGUID:                                           proc "system" (this: rawptr, key: ^GUID, value: ^GUID) -> HRESULT,
	GetStringLength, GetString, GetAllocatedString:    rawptr,
	GetBlobSize:                                       proc "system" (this: rawptr, key: ^GUID, size: ^u32) -> HRESULT,
	GetBlob:                                           proc "system" (this: rawptr, key: ^GUID, buffer: [^]u8, size: u32, written: ^u32) -> HRESULT,
	GetAllocatedBlob, GetUnknown:                      rawptr,
	SetItem, DeleteItem, DeleteAllItems:               rawptr,
	SetUINT32:                                         proc "system" (this: rawptr, key: ^GUID, value: u32) -> HRESULT,
	SetUINT64:                                         proc "system" (this: rawptr, key: ^GUID, value: u64) -> HRESULT,
	SetDouble:                                         rawptr,
	SetGUID:                                           proc "system" (this: rawptr, key: ^GUID, value: ^GUID) -> HRESULT,
	SetString, SetBlob, SetUnknown:                    rawptr,
	LockStore, UnlockStore, GetCount, GetItemByIndex:  rawptr,
	CopyAllItems:                                      rawptr,
}

@(private)
IMFAttributes :: struct {
	using vtable: ^IMFAttributes_VTable,
}

@(private)
IMFMediaType_VTable :: struct {
	using attributes:                                                              IMFAttributes_VTable,
	GetMajorType, IsCompressedFormat, IsEqual, GetRepresentation, FreeRepresentation: rawptr,
}

@(private)
IMFMediaType :: struct {
	using vtable: ^IMFMediaType_VTable,
}

@(private)
IMFActivate_VTable :: struct {
	using attributes: IMFAttributes_VTable,
	ActivateObject:   proc "system" (this: rawptr, riid: ^GUID, object: ^rawptr) -> HRESULT,
	ShutdownObject:   proc "system" (this: rawptr) -> HRESULT,
	DetachObject:     rawptr,
}

@(private)
IMFActivate :: struct {
	using vtable: ^IMFActivate_VTable,
}

@(private)
IMFMediaBuffer_VTable :: struct {
	using unknown:    IUnknown_VTable,
	Lock:             proc "system" (this: rawptr, data: ^[^]u8, max_length, current_length: ^u32) -> HRESULT,
	Unlock:           proc "system" (this: rawptr) -> HRESULT,
	GetCurrentLength: proc "system" (this: rawptr, length: ^u32) -> HRESULT,
	SetCurrentLength: proc "system" (this: rawptr, length: u32) -> HRESULT,
}

@(private)
IMFMediaBuffer :: struct {
	using vtable: ^IMFMediaBuffer_VTable,
}

@(private)
IMF2DBuffer_VTable :: struct {
	using unknown: IUnknown_VTable,
	Lock2D:        proc "system" (this: rawptr, scanline0: ^[^]u8, pitch: ^i32) -> HRESULT,
	Unlock2D:      proc "system" (this: rawptr) -> HRESULT,
}

@(private)
IMF2DBuffer :: struct {
	using vtable: ^IMF2DBuffer_VTable,
}

@(private)
IMFSample_VTable :: struct {
	using attributes:                      IMFAttributes_VTable,
	GetSampleFlags, SetSampleFlags:        rawptr,
	GetSampleTime:                         rawptr,
	SetSampleTime:                         proc "system" (this: rawptr, time: i64) -> HRESULT,
	GetSampleDuration:                     rawptr,
	SetSampleDuration:                     proc "system" (this: rawptr, duration: i64) -> HRESULT,
	GetBufferCount, GetBufferByIndex:      rawptr,
	ConvertToContiguousBuffer:             proc "system" (this: rawptr, buffer: ^^IMFMediaBuffer) -> HRESULT,
	AddBuffer:                             proc "system" (this: rawptr, buffer: ^IMFMediaBuffer) -> HRESULT,
}

@(private)
IMFSample :: struct {
	using vtable: ^IMFSample_VTable,
}

@(private)
MFT_OUTPUT_STREAM_INFO :: struct {
	flags, size, alignment: u32,
}

@(private)
MFT_OUTPUT_DATA_BUFFER :: struct {
	stream_id: u32,
	sample:    ^IMFSample,
	status:    u32,
	events:    rawptr,
}

@(private)
MFT_REGISTER_TYPE_INFO :: struct {
	major, subtype: GUID,
}

@(private)
IMFTransform_VTable :: struct {
	using unknown:                                                         IUnknown_VTable,
	GetStreamLimits, GetStreamCount, GetStreamIDs, GetInputStreamInfo:     rawptr,
	GetOutputStreamInfo:                                                   proc "system" (this: rawptr, stream: u32, info: ^MFT_OUTPUT_STREAM_INFO) -> HRESULT,
	GetAttributes:                                                         proc "system" (this: rawptr, attributes: ^^IMFAttributes) -> HRESULT,
	GetInputStreamAttributes, GetOutputStreamAttributes:                   rawptr,
	DeleteInputStream, AddInputStreams, GetInputAvailableType:             rawptr,
	GetOutputAvailableType:                                                proc "system" (this: rawptr, stream, index: u32, type: ^^IMFMediaType) -> HRESULT,
	SetInputType:                                                          proc "system" (this: rawptr, stream: u32, type: ^IMFMediaType, flags: u32) -> HRESULT,
	SetOutputType:                                                         proc "system" (this: rawptr, stream: u32, type: ^IMFMediaType, flags: u32) -> HRESULT,
	GetInputCurrentType:                                                   rawptr,
	GetOutputCurrentType:                                                  proc "system" (this: rawptr, stream: u32, type: ^^IMFMediaType) -> HRESULT,
	GetInputStatus, GetOutputStatus, SetOutputBounds, ProcessEvent:        rawptr,
	ProcessMessage:                                                        proc "system" (this: rawptr, message: u32, param: uintptr) -> HRESULT,
	ProcessInput:                                                          proc "system" (this: rawptr, stream: u32, sample: ^IMFSample, flags: u32) -> HRESULT,
	ProcessOutput:                                                         proc "system" (this: rawptr, flags, count: u32, buffers: [^]MFT_OUTPUT_DATA_BUFFER, status: ^u32) -> HRESULT,
}

@(private)
IMFTransform :: struct {
	using vtable: ^IMFTransform_VTable,
}

@(private)
VARIANT :: struct {
	vt:       u16,
	reserved: [3]u16,
	value:    u64,
	_:        u64,
}

@(private)
ICodecAPI_VTable :: struct {
	using unknown:                                                                  IUnknown_VTable,
	IsSupported, IsModifiable, GetParameterRange, GetParameterValues, GetDefaultValue: rawptr,
	GetValue:                                                                       rawptr,
	SetValue:                                                                       proc "system" (this: rawptr, api: ^GUID, value: ^VARIANT) -> HRESULT,
}

@(private)
ICodecAPI :: struct {
	using vtable: ^ICodecAPI_VTable,
}

@(private)
release :: proc(object: rawptr) {
	if object != nil do (cast(^^IUnknown_VTable)object)^.Release(object)
}

@(private) MFMediaType_Video := GUID{0x73646976, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}}
@(private) MFVideoFormat_H264 := GUID{0x34363248, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}} // 'H264'
@(private) MFVideoFormat_HEVC := GUID{0x43564548, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}} // 'HEVC'
@(private) MFVideoFormat_NV12 := GUID{0x3231564e, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}} // 'NV12'
@(private) MFVideoFormat_P010 := GUID{0x30313050, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}} // 'P010'
@(private) MFT_CATEGORY_VIDEO_DECODER := GUID{0xd6c02d4b, 0x6833, 0x45b4, {0x97, 0x1a, 0x05, 0xa4, 0xb0, 0x4b, 0xab, 0x91}}
@(private) MFT_CATEGORY_VIDEO_ENCODER := GUID{0xf79eac7d, 0xe545, 0x4387, {0xbd, 0xee, 0xd6, 0x47, 0xd7, 0xbd, 0xe4, 0x2a}}
@(private) MF_MT_MAJOR_TYPE := GUID{0x48eba18e, 0xf8c9, 0x4687, {0xbf, 0x11, 0x0a, 0x74, 0xc9, 0xf9, 0x6a, 0x8f}}
@(private) MF_MT_SUBTYPE := GUID{0xf7e34c9a, 0x42e8, 0x4714, {0xb7, 0x4b, 0xcb, 0x29, 0xd7, 0x2c, 0x35, 0xe5}}
@(private) MF_MT_FRAME_SIZE := GUID{0x1652c33d, 0xd6b2, 0x4012, {0xb8, 0x34, 0x72, 0x03, 0x08, 0x49, 0xa3, 0x7d}}
@(private) MF_MT_FRAME_RATE := GUID{0xc459a2e8, 0x3d2c, 0x4e44, {0xb1, 0x32, 0xfe, 0xe5, 0x15, 0x6c, 0x7b, 0xb0}}
@(private) MF_MT_PIXEL_ASPECT_RATIO := GUID{0xc6376a1e, 0x8d0a, 0x4027, {0xbe, 0x45, 0x6d, 0x9a, 0x0a, 0xd3, 0x9b, 0xb6}}
@(private) MF_MT_INTERLACE_MODE := GUID{0xe2724bb8, 0xe676, 0x4806, {0xb4, 0xb2, 0xa8, 0xd6, 0xef, 0xb4, 0x4c, 0xcd}}
@(private) MF_MT_AVG_BITRATE := GUID{0x20332624, 0xfb0d, 0x4d9e, {0xbd, 0x0d, 0xcb, 0xf6, 0x78, 0x6c, 0x10, 0x2e}}
@(private) MF_MT_MPEG2_PROFILE := GUID{0xad76a80b, 0x2d5c, 0x4e0b, {0xb3, 0x75, 0x64, 0xe5, 0x20, 0x13, 0x70, 0x36}}
@(private) MF_MT_MINIMUM_DISPLAY_APERTURE := GUID{0xd7388766, 0x18fe, 0x48c6, {0xa1, 0x77, 0xee, 0x89, 0x48, 0x67, 0xc8, 0xc4}}
@(private) MF_MT_DEFAULT_STRIDE := GUID{0x644b4e48, 0x1e02, 0x4516, {0xb0, 0xeb, 0xc0, 0x1c, 0xa9, 0xd4, 0x9a, 0xc6}}
@(private) MF_MT_MPEG_SEQUENCE_HEADER := GUID{0x3c036de7, 0x3ad0, 0x4c9e, {0x92, 0x16, 0xee, 0x6d, 0x6a, 0xc2, 0x1c, 0xb3}}
@(private) MFSampleExtension_CleanPoint := GUID{0x9cdf01d8, 0xa0f0, 0x43ba, {0xb0, 0x77, 0xea, 0xa0, 0x6c, 0xbd, 0x72, 0x8a}}
@(private) MF_LOW_LATENCY := GUID{0x9c27891a, 0xed7a, 0x40e1, {0x88, 0xe8, 0xb2, 0x27, 0x27, 0xa0, 0x24, 0xee}}
@(private) CODECAPI_AVEncCommonRateControlMode := GUID{0x1c0608e9, 0x370c, 0x4710, {0x8a, 0x58, 0xcb, 0x61, 0x81, 0xc4, 0x24, 0x23}}
@(private) CODECAPI_AVEncVideoEncodeQP := GUID{0x2cb5696b, 0x23fb, 0x4ce1, {0xa0, 0xf9, 0xef, 0x5b, 0x90, 0xfd, 0x55, 0xca}}
@(private) CODECAPI_AVEncMPVGOPSize := GUID{0x95f31b26, 0x95a4, 0x41aa, {0x93, 0x03, 0x24, 0x6a, 0x7f, 0xc6, 0xee, 0xf1}}
@(private) CODECAPI_AVEncMPVDefaultBPictureCount := GUID{0x8d390aac, 0xdc5c, 0x4200, {0xb5, 0x7f, 0x81, 0x4d, 0x04, 0xba, 0xba, 0xb2}}
@(private) IID_IMFTransform := GUID{0xbf94c121, 0x5b05, 0x4e6f, {0x80, 0x00, 0xba, 0x59, 0x89, 0x61, 0x41, 0x4d}}
@(private) IID_IMF2DBuffer := GUID{0x7dc9d5f9, 0x9ed9, 0x44ec, {0x9b, 0xbf, 0x06, 0x00, 0xbb, 0x58, 0x9f, 0xbb}}
@(private) IID_ICodecAPI := GUID{0x901db4c7, 0x31ce, 0x41a2, {0x85, 0xdc, 0x8f, 0xa0, 0xbf, 0x41, 0xb8, 0xda}}

@(private) MF_VERSION :: 0x0002_0070
@(private) MFSTARTUP_LITE :: 1
@(private) MFT_ENUM_FLAG_SYNCMFT :: 0x01
@(private) MFT_ENUM_FLAG_LOCALMFT :: 0x10
@(private) MFT_ENUM_FLAG_SORTANDFILTER :: 0x40
@(private) MFT_MESSAGE_COMMAND_DRAIN :: 0x1
@(private) MFT_MESSAGE_NOTIFY_BEGIN_STREAMING :: 0x1000_0000
@(private) MFT_MESSAGE_NOTIFY_START_OF_STREAM :: 0x1000_0003
@(private) MFT_OUTPUT_STREAM_PROVIDES_SAMPLES :: 0x100
@(private) MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES :: 0x200
@(private) MFVideoInterlace_Progressive :: 2
@(private) eAVEncCommonRateControlMode_Quality :: 3
@(private) eAVEncH264VProfile_High :: 100
@(private) eAVEncH265VProfile_Main_420_8 :: 1
@(private) VT_UI4 :: 19
@(private) VT_UI8 :: 21
@(private) MF_E_NOTACCEPTING :: HRESULT(-1072875851) // 0xC00D36B5
@(private) MF_E_TRANSFORM_STREAM_CHANGE :: HRESULT(-1072861855) // 0xC00D6D61
@(private) MF_E_TRANSFORM_NEED_MORE_INPUT :: HRESULT(-1072861838) // 0xC00D6D72

// mfplat.dll, loaded once at first use. MFStartup's reference is never
// released (MFShutdown would tear Media Foundation down under other users).
@(private)
API :: struct {
	MFStartup:            proc "system" (version, flags: u32) -> HRESULT,
	MFTEnumEx:            proc "system" (category: GUID, flags: u32, input, output: ^MFT_REGISTER_TYPE_INFO, activates: ^[^]^IMFActivate, count: ^u32) -> HRESULT,
	MFCreateMediaType:    proc "system" (type: ^^IMFMediaType) -> HRESULT,
	MFCreateSample:       proc "system" (sample: ^^IMFSample) -> HRESULT,
	MFCreateMemoryBuffer: proc "system" (max_length: u32, buffer: ^^IMFMediaBuffer) -> HRESULT,
	loaded:               bool,
}

@(private)
api: API
@(private)
api_once: sync.Once

@(private)
load_api :: proc() {
	lib, ok := dynlib.load_library("mfplat.dll")
	if !ok do return
	a: API
	found: bool
	for name in ([]string{"MFStartup", "MFTEnumEx", "MFCreateMediaType", "MFCreateSample", "MFCreateMemoryBuffer"}) {
		address: rawptr
		address, found = dynlib.symbol_address(lib, name)
		if !found do return
		switch name {
		case "MFStartup":
			a.MFStartup = cast(type_of(a.MFStartup))address
		case "MFTEnumEx":
			a.MFTEnumEx = cast(type_of(a.MFTEnumEx))address
		case "MFCreateMediaType":
			a.MFCreateMediaType = cast(type_of(a.MFCreateMediaType))address
		case "MFCreateSample":
			a.MFCreateSample = cast(type_of(a.MFCreateSample))address
		case "MFCreateMemoryBuffer":
			a.MFCreateMemoryBuffer = cast(type_of(a.MFCreateMemoryBuffer))address
		}
	}
	com()
	if a.MFStartup(MF_VERSION, MFSTARTUP_LITE) < 0 do return
	a.loaded = true
	api = a
}

// Media Foundation runs in the multithreaded apartment. Joining it is cheap
// once a thread has, and harmless where the thread already chose a model.
@(private)
com :: proc() {
	win.CoInitializeEx(nil, .MULTITHREADED)
}

@(private)
ensure_api :: proc() -> bool {
	sync.once_do(&api_once, load_api)
	if api.loaded do com()
	return api.loaded
}
