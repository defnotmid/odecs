#!/usr/bin/env bash
# FLAC gate: the RFC 9639 example files and corruption tests, then every
# fixture from tests/flac_fixtures.sh decoded natively and checked against
# the encoder's MD5 and FFmpeg's decode (bit-exact), with random seeks;
# FLAC in .flac, Matroska and MP4 through video.Reader; and a fuzz pass.
# FFmpeg and the flac tool are development oracles only.
#   bash tests/flac_check.sh [work-dir]
set -euo pipefail
cd "$(dirname "$0")/.."
work=${1:-/tmp/oicut-flac}
fx="$work/fx"
mkdir -p "$fx"
fail=0
pass() { printf '  %-44s ok\n' "$1"; }
bad() { printf '  %-44s FAIL\n' "$1"; fail=1; }

odin test audio/flac
odin build tests/flac_compare.odin -file -o:speed -out:"$work/flac_compare"
odin build tests/movie_alpha.odin -file -o:speed -out:"$work/movie_alpha"
odin build tests/alpha_fuzz.odin -file -o:speed -sanitize:address -out:"$work/alpha_fuzz"
bash tests/flac_fixtures.sh "$fx"

echo "== native decode: streaminfo MD5, FFmpeg bit-exact, 50 seeks"
for f in "$fx"/*.flac; do
	name=$(basename "$f")
	if "$work/flac_compare" "$f" "${f%.flac}.f32" > "$f.log" 2>&1; then
		pass "$name $(grep -o '[0-9]*x real time' "$f.log" | head -1)"
	else
		bad "$name"; cat "$f.log"
	fi
done

echo "== video.Reader: .flac, Matroska, MP4 (whole stream and 30 seeks, exact)"
for f in "$fx"/ref_l8.flac "$fx"/ref_32.flac "$fx"/ref_id3.flac "$fx"/in_matroska.mkv "$fx"/in_mp4.mp4 "$fx"/video_flac.mkv; do
	name=$(basename "$f")
	oracle="$f.f32" # containers: NAME.mkv.f32
	[[ "$f" == *.flac ]] && oracle="${f%.flac}.f32"
	if "$work/movie_alpha" "$f" - 1 "$oracle" > "$f.reader.log" 2>&1 &&
		awk '/pcm:/ { gsub(/[(),]/, ""); whole = ($2 == $5 && $NF == 0) } /pcm seeks:/ { seeks = ($NF == 0) } END { exit !(whole && seeks) }' "$f.reader.log"; then
		pass "reader $name"
	else
		bad "reader $name"; cat "$f.reader.log"
	fi
done

echo "== fuzz (AddressSanitizer)"
mkdir -p "$work/fuzz"
ffmpeg -v error -y -i "$fx/ref_l8.flac" -t 0.3 "$work/fuzz/small16.flac"
ffmpeg -v error -y -i "$fx/ref_32.flac" -t 0.25 -c:a flac -sample_fmt s32 "$work/fuzz/small32.flac"
ffmpeg -v error -y -i "$fx/src/s24_6ch.wav" -t 0.2 -c:a pcm_s24le "$work/fuzz/s24.wav"
flac --silent -f --lax -l 32 -o "$work/fuzz/small24_6ch.flac" "$work/fuzz/s24.wav" 2>/dev/null
for f in "$work"/fuzz/*.flac; do
	if ASAN_OPTIONS=detect_leaks=0 "$work/alpha_fuzz" 500 "$f" > "$f.fuzz.log" 2>&1 && grep -q "leaked allocations 0" "$f.fuzz.log"; then pass "fuzz $(basename "$f")"; else bad "fuzz $(basename "$f")"; tail -20 "$f.fuzz.log"; fi
done
exit $fail
