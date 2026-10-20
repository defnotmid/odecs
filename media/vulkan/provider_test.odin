package media_vulkan

import media ".."
import native "../native"
import "core:testing"

@(test)
test_bound_context_never_probes_other_devices :: proc(t: ^testing.T) {
	shared: Context
	bound := provider(&shared)
	config := media.default_config(.H264, .Encode)
	config.width, config.height = 320, 240
	// Invalid bound context must fail locally; global device discovery cannot
	// replace the caller's chosen owner, even if another GPU is available.
	testing.expect_value(t, bound.probe(config, bound.user), media.Error.Invalid_Config)
	config.preference = .Require_Hardware
	session: media.Session
	testing.expect_value(
		t,
		media.open(&session, config, []media.Provider{bound, native.provider()}),
		media.Error.Invalid_Config,
	)
	testing.expect(t, session.state == nil)
	config.preference = .Automatic
	testing.expect_value(
		t,
		media.open(&session, config, []media.Provider{bound, native.provider()}),
		media.Error.None,
	)
	testing.expect(t, session.backend == .Native && session.hardware_error == .Invalid_Config)
	testing.expect_value(t, media.close(&session), media.Error.None)
}

@(test)
test_known_unsupported_profile_selects_native_before_stream_input :: proc(t: ^testing.T) {
	config := media.default_config(.H265, .Decode)
	config.width, config.height, config.profile_idc = 16, 16, 4
	providers := []media.Provider{provider(), native.provider()}
	session: media.Session
	testing.expect_value(t, probe(config, nil), media.Error.Unsupported)
	testing.expect_value(t, media.open(&session, config, providers), media.Error.None)
	testing.expect_value(t, session.backend, media.Backend.Native)
	testing.expect_value(t, session.hardware_error, media.Error.Unsupported)
	testing.expect_value(t, media.close(&session), media.Error.None)
	config.preference = .Require_Hardware
	testing.expect_value(t, media.open(&session, config, providers), media.Error.Unsupported)
	testing.expect_value(t, session.state, rawptr(nil))
}

@(test)
test_audio_and_native_only_video_settings_refuse_hardware :: proc(t: ^testing.T) {
	config := media.default_config(.AAC, .Encode)
	config.sample_rate, config.channels = 48000, 2
	testing.expect_value(t, probe(config, nil), media.Error.Unsupported)
	config = media.default_config(.H265, .Encode)
	config.width, config.height, config.bit_depth, config.qp = 16, 16, 10, -1
	testing.expect_value(t, probe(config, nil), media.Error.Unsupported)
	config.qp, config.chroma = 26, .YUV444
	testing.expect_value(t, probe(config, nil), media.Error.Unsupported)
}
