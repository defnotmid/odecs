package media_audiotoolbox

import media ".."

// AAC through Apple's AudioToolbox (AudioConverter): decoding AAC-LC, HE-AAC
// and HE-AAC v2, which oicut's own decoder refuses, and AAC-LC encoding. It
// is a system-tier provider (media.Tier.System), so in Automatic it serves
// what the native AAC codec does not admit. Mono and stereo only: wider
// layouts would need Apple's channel order mapped. Off Apple platforms every
// probe reports .Unavailable, so the provider can be listed unconditionally.
//
// Decoding takes raw AAC packets with the AudioSpecificConfig in
// Config.extradata, or ADTS frames, and delivers interleaved f32 at the
// decoded rate (twice the core rate for HE-AAC). Encoding takes 1024-sample
// frames and writes raw AAC packets; the first packet's sample_index is minus
// the encoder's priming (2112 samples with Apple's encoder), so a container
// trims it as it does oicut's own.
provider :: proc() -> media.Provider {
	return {backend = .AudioToolbox, name = "AudioToolbox", probe = probe, open = open}
}

probe :: proc(config: media.Config, user: rawptr) -> media.Error {
	if err := media.validate_config(config); err != .None do return err
	if config.codec != .AAC || config.channels < 1 || config.channels > 2 do return .Unsupported
	if config.frame_samples != 0 && config.frame_samples != 1024 do return .Unsupported
	if config.operation == .Encode && config.audio_transport != .Raw do return .Unsupported
	return platform_probe(config)
}

@(private)
open :: proc(session: ^media.Session, config: media.Config, user: rawptr) -> media.Error {
	return platform_open(session, config)
}
