#+build !windows
package media_mediafoundation

import media ".."

// Media Foundation exists only on Windows.

@(private)
platform_probe :: proc(config: media.Config) -> media.Error {
	return .Unavailable
}

@(private)
platform_open :: proc(session: ^media.Session, config: media.Config) -> media.Error {
	return .Unavailable
}
