#!/usr/bin/env bash
# Vorbis gate: odin test audio/vorbis, every fixture (tests/vorbis_fixtures.sh)
# through oicut/audio against libvorbis (tests/vorbis_compare.odin: the same
# frame count, SNR at least 90 dB), and a fuzz pass. libvorbis and libogg are
# built from the pinned sources (tools/fetch_third_party.sh libvorbis libogg)
# into .work/vorbis-oracle. Development only.
#   bash tests/vorbis_check.sh [work-dir]
set -euo pipefail
cd "$(dirname "$0")/.."
work=${1:-.work/vorbis-check}
fx=.work/vorbis-fixtures
oracle=$PWD/.work/vorbis-oracle
mkdir -p "$work"
fail=0

odin test audio/vorbis > "$work/test.log" 2>&1 || { cat "$work/test.log"; fail=1; }
bash tests/vorbis_fixtures.sh "$fx" > /dev/null

if [ ! -f "$oracle/lib/libvorbisfile.a" ]; then
	[ -d third_party/libvorbis ] && [ -d third_party/libogg ] || bash tools/fetch_third_party.sh libvorbis libogg
	common=(-DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$oracle" -DCMAKE_PREFIX_PATH="$oracle" -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_POLICY_VERSION_MINIMUM=3.5)
	{
		cmake -S third_party/libogg -B .work/libogg-build "${common[@]}" -DINSTALL_DOCS=OFF
		cmake --build .work/libogg-build -j8 && cmake --install .work/libogg-build
		cmake -S third_party/libvorbis -B .work/libvorbis-build "${common[@]}"
		cmake --build .work/libvorbis-build -j8 && cmake --install .work/libvorbis-build
	} > "$work/oracle.log" 2>&1
fi

echo "== against libvorbis"
odin run tests/vorbis_compare.odin -file -o:speed -microarch:native -extra-linker-flags:"-L$oracle/lib" -out:"$work/vorbis_compare" -- "$fx"/*.ogg || fail=1

echo "== fuzz"
odin build tests/audio_fuzz.odin -file -o:speed -sanitize:address -out:"$work/audio_fuzz"
"$work/audio_fuzz" 300 "$fx"/*.ogg || fail=1

[ $fail = 0 ] && echo "vorbis gate: ok" || echo "vorbis gate: FAILED"
exit $fail
