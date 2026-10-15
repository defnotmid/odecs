#!/usr/bin/env bash
# Fetches the reference sources into third_party/ at the commits recorded in
# THIRD_PARTY_REFERENCES.md. They are development references and oracles
# only: never committed (third_party/ is ignored), never linked into odecs.
# Existing trees are left as they are; delete one to fetch it again.
#   bash tools/fetch_third_party.sh [name...]   (default: all)
set -euo pipefail
cd "$(dirname "$0")/.."

# name  upstream  commit
refs=(
	"edge264      https://github.com/tvlabs/edge264.git                2c2ab95d63c1ad89c5687f9e50b57cad772c871b"
	"openh264     https://github.com/cisco/openh264.git                9d974972d9f1ef572b87d8d774af8f8c304ad3e1"
	"kvazaar      https://github.com/ultravideo/kvazaar.git            2b06691bb5844404c0e703f12a5d7b0fee914ec7"
	"hevc.js      https://github.com/lid-labs/hevc.js.git              fa6c1bb2a58fbc1e425030555ef57121717de746"
	"glint        https://github.com/CrispStrobe/glint.git             77738f3ed9b15f627196cc5bbd7f6406814ba2fb"
	"h265         https://github.com/gen2brain/h265.git                5138267a04330b8f0e36ddeabbcf6f49b664fa88"
	"oxideav-h265 https://github.com/OxideAV/oxideav-h265.git          a1ecd6adceedeefd83740f6537946cc3ee8ab3ec"
	"minimp3      https://github.com/lieff/minimp3.git                 ea99364f61c14656440e8d77e9c233ccf3124633"
	"dr_libs      https://github.com/mackron/dr_libs.git               dfe8377631000664666519fdb83da193fd8037f4"
	"PDMP3        https://github.com/technosaurus/PDMP3.git            2a206a3ada78ec4d13434847f05f50097c60c36a"
	"opus         https://gitlab.xiph.org/xiph/opus.git                22244de5a79bd1d6d623c32e72bf1954b56235be"
	"libwebp      https://chromium.googlesource.com/webm/libwebp       4fa21912338357f89e4fd51cf2368325b59e9bd9"
	"alac         https://github.com/macosforge/alac.git               c38887c5c5e64a4b31108733bd79ca9b2496d987"
)

fetch() { # name upstream commit
	local dir="third_party/$1"
	if [ -e "$dir" ]; then
		echo "keep  $dir (exists)"
		return
	fi
	git init -q "$dir"
	git -C "$dir" remote add origin "$2"
	# Some hosts refuse a fetch by commit: then the whole history.
	if ! git -C "$dir" fetch -q --depth 1 --no-tags origin "$3" 2>/dev/null; then
		git -C "$dir" fetch -q --no-tags origin
	fi
	git -C "$dir" -c advice.detachedHead=false checkout -q --detach "$3"
	echo "fetch $dir at $(git -C "$dir" rev-parse HEAD)"
}

mkdir -p third_party
for ref in "${refs[@]}"; do
	read -r name upstream commit <<<"$ref"
	if [ $# -gt 0 ] && [[ " $* " != *" $name "* ]]; then continue; fi
	fetch "$name" "$upstream" "$commit"
done
