#!/bin/sh
# Gets the media the demo doesn't commit into media/, each checked against
# its SHA-256: run it once before rendering (media/.gitignore keeps them out
# of commits). A file already there with the right hash is kept.
set -eu
cd "$(dirname "$0")/media"

sha256() {
	if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d ' ' -f 1
}

# get NAME SHA256 URL [base64]: downloads URL into NAME unless it is there.
get() {
	if [ -f "$1" ] && [ "$(sha256 "$1")" = "$2" ]; then return; fi
	if [ "${4:-}" = base64 ]; then curl -fsSL "$3" | base64 -d >"$1.part"; else curl -fsSL -o "$1.part" "$3"; fi
	got="$(sha256 "$1.part")"
	if [ "$got" != "$2" ]; then
		rm -f "$1.part"
		echo "$1: SHA-256 $got, expected $2" >&2
		exit 1
	fi
	mv "$1.part" "$1"
}

# ProRes 4444 with alpha: the avatar clip of fframes' audio-announce example
# (MIT, fframes-MIT.txt), at a pinned commit.
get transparent.mov 23b70a14328a74bfde0bd253c423ee883b650b8790ab8fcfabde670b079a9284 \
	https://raw.githubusercontent.com/dmtrKovalenko/fframes/f962cd6df51d19fa06462d470fc57e90cc0f17b0/examples/audio-announce/dynamic_media/transparent.mov
# The same avatar as VP9 with an alpha stream, made from it with FFmpeg: an
# asset of odecs' v0.0.12 release.
get avatar_vp9_alpha.webm 008d65eb0e8d958c9cbacf31183f6ec91248c3c21346f9145bdeac9375fb783b \
	https://github.com/defnotmid/odecs/releases/download/v0.0.12/avatar_vp9_alpha.webm
# 11158x2156 lossy WebP from libwebp's test corpus, at the commit
# tests/webp_fixtures.sh pins (gitiles serves a file base64).
get bryce.webp a0921902341af61a058297ce7851220c26b12eb0a2e8946ebefa6906ebb64e52 \
	"https://chromium.googlesource.com/webm/libwebp-test-data/+/06ddd96e276c2c638a72d39d3c0f340afd61978c/bryce.webp?format=TEXT" base64
