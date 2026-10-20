#!/usr/bin/env bash
# MP3 gate: the MPEG audio conformance streams in third_party/minimp3/vectors
# at full accuracy (PSNR >= 96 dB against the reference PCM), malformed and
# unsupported streams refused without crashing, LAME fixtures against
# FFmpeg (same gapless length, differences at float rounding), MP3 in .mp3,
# MP4, MOV and Matroska through movie.Reader with seeks, and a fuzz pass.
# FFmpeg and the vectors are development oracles only.
#   bash tests/mp3_check.sh [work-dir]
set -euo pipefail
cd "$(dirname "$0")/.."
work=${1:-/tmp/odecs-mp3}
fx="$work/fx"
vectors=third_party/minimp3/vectors
mkdir -p "$fx"
fail=0
pass() { printf '  %-50s ok\n' "$1"; }
bad() { printf '  %-50s FAIL\n' "$1"; fail=1; }

odin test mp3
odin build tests/mp3_compare.odin -file -o:speed -out:"$work/mp3_compare"
odin build tests/movie_alpha.odin -file -o:speed -out:"$work/movie_alpha"
odin build tests/alpha_fuzz.odin -file -o:speed -sanitize:address -out:"$work/alpha_fuzz"
bash tests/mp3_fixtures.sh "$fx"

if [ -d "$vectors" ]; then
	echo "== conformance streams (reference PCM, PSNR >= 96 dB)"
	for f in "$vectors"/l3-*.bit "$vectors"/M2L3_*.bit; do
		name=$(basename "$f" .bit)
		case "$name" in
		l3-he_free | l3-nonstandard-*) continue ;; # below
		esac
		if "$work/mp3_compare" "$f" "${f%.bit}.pcm" > "$work/$name.log" 2>&1; then
			pass "$name $(grep -o 'max difference [0-9]*, PSNR [0-9.]* dB' "$work/$name.log")"
		else
			bad "$name"; cat "$work/$name.log"
		fi
	done
	echo "== malformed, tag-only and unsupported streams fail cleanly"
	for f in "$vectors"/l3-he_free.bit "$vectors"/l3-nonstandard-*.bit; do
		set +e
		"$work/mp3_compare" "$f" > /dev/null 2>&1
		status=$?
		set -e
		if [ $status -lt 128 ]; then pass "$(basename "$f" .bit)"; else bad "$(basename "$f" .bit) (signal $((status - 128)))"; fi
	done
else
	echo "== conformance streams skipped: clone minimp3 into third_party (THIRD_PARTY_REFERENCES.md)"
fi

echo "== LAME fixtures against FFmpeg (same length, max difference < 1e-4)"
for f in "$fx"/*.mp3; do
	name=$(basename "$f")
	if "$work/mp3_compare" "$f" "${f%.mp3}.f32" > "$f.log" 2>&1 &&
		awk '/vs FFmpeg/ { gsub(/[(),]/, ""); ok = ($3 == $6 && $9 < 1e-4) } END { exit !ok }' "$f.log"; then
		pass "$name $(grep -o 'decode [0-9]*x' "$f.log")"
	else
		bad "$name"; cat "$f.log"
	fi
done

echo "== movie.Reader: .mp3, MP4, MOV, Matroska (whole stream and 30 seeks)"
for f in "$fx"/vbr_q2.mp3 "$fx"/transients48.mp3 "$fx"/mpeg25_8k.mp3 "$fx"/id3v2_cover.mp3 "$fx"/in_mp4.mp4 "$fx"/in_mov.mov "$fx"/in_matroska.mkv "$fx"/video_mp3.mp4; do
	name=$(basename "$f")
	oracle="$f.f32"
	[[ "$f" == *.mp3 ]] && oracle="${f%.mp3}.f32"
	if "$work/movie_alpha" "$f" - 1 "$oracle" > "$f.reader.log" 2>&1 &&
		awk '/pcm:/ { gsub(/[(),]/, ""); whole = ($2 == $5 && $NF < 1e-4) } /pcm seeks:/ { seeks = ($NF < 1e-4) } END { exit !(whole && seeks) }' "$f.reader.log"; then
		pass "reader $name"
	else
		bad "reader $name"; cat "$f.reader.log"
	fi
done

echo "== fuzz (AddressSanitizer)"
mkdir -p "$work/fuzz"
ffmpeg -v error -y -i "$fx/transients48.mp3" -t 0.4 -c copy "$work/fuzz/small48.mp3"
ffmpeg -v error -y -i "$fx/mpeg25_11k.mp3" -t 0.6 -c copy "$work/fuzz/small11k.mp3"
ffmpeg -v error -y -i "$fx/src/mono32.wav" -t 0.4 -c:a libmp3lame -b:a 64k "$work/fuzz/small_mono_tag.mp3"
for f in "$work"/fuzz/*.mp3; do
	if ASAN_OPTIONS=detect_leaks=0 "$work/alpha_fuzz" 500 "$f" > "$f.fuzz.log" 2>&1 && grep -q "leaked allocations 0" "$f.fuzz.log"; then pass "fuzz $(basename "$f")"; else bad "fuzz $(basename "$f")"; tail -20 "$f.fuzz.log"; fi
done
exit $fail
