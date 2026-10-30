#+build !darwin
package media_audiotoolbox

import media ".."

// AudioToolbox exists only on Apple platforms.

@(private)
platform_probe :: proc(config: media.Config) -> media.Error {
	return .Unavailable
}

@(private)
platform_open :: proc(session: ^media.Session, config: media.Config) -> media.Error {
	return .Unavailable
}
