package media_mediafoundation

import media ".."

// H.264 and HEVC through Windows Media Foundation: the synchronous decoder
// and encoder transforms Windows ships (Microsoft's H.264 decoder and
// encoder, and its HEVC decoder and encoder where the HEVC Video Extensions
// are installed). mfplat.dll is loaded at runtime, so nothing is linked; off
// Windows, or without Media Foundation (N editions, Server without the
// feature), every probe reports .Unavailable and the provider can be listed
// unconditionally. It is a system-tier provider (media.Tier.System).
//
// Decoding: 4:2:0 at 8 bits (H.264) or 8 and 10 bits (HEVC), host output.
// Encoding: 8-bit 4:2:0, I and P pictures, a keyframe every gop_size frames,
// QP held through the encoder's quality mode where it accepts one.
provider :: proc() -> media.Provider {
	return {backend = .MediaFoundation, name = "Media Foundation", probe = probe, open = open}
}

probe :: proc(config: media.Config, user: rawptr) -> media.Error {
	if err := media.validate_config(config); err != .None do return err
	if config.codec != .H264 && config.codec != .H265 || config.chroma != .YUV420 || config.alpha do return .Unsupported
	depth := config.bit_depth == 0 ? 8 : config.bit_depth
	if config.operation == .Encode {
		if depth != 8 do return .Unsupported
	} else {
		if config.output_storage != .Host do return .Unsupported
		if depth != 8 && (config.codec == .H264 || depth != 10) do return .Unsupported
	}
	return platform_probe(config)
}

@(private)
open :: proc(session: ^media.Session, config: media.Config, user: rawptr) -> media.Error {
	return platform_open(session, config)
}
