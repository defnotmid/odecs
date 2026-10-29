#!/usr/bin/env bash
# Alpha-video gate: ProRes in QuickTime and VP9 (with alpha) in WebM, decoded
# by odecs and compared with FFmpeg, plus video.Reader end to end, QuickTime
# PCM, and a short fuzz pass. FFmpeg is a development oracle only.
#   bash tests/alpha_check.sh [work-dir] [--large]
set -euo pipefail
cd "$(dirname "$0")/.."
work=${1:-/tmp/odecs-alpha}
large=${2:-}
mkdir -p "$work"
fail=0
pass() { printf '  %-48s ok\n' "$1"; }
bad() { printf '  %-48s FAIL\n' "$1"; fail=1; }

odin test video/prores/decoder
odin test video/vp9
odin test video/vp9/decoder
odin test container/webm
odin test container/mp4
odin test video -o:speed
odin build tests/alpha_compare.odin -file -o:speed -out:"$work/alpha_compare"
odin build tests/movie_alpha.odin -file -o:speed -define:ODECS_PATENTED=true -out:"$work/movie_alpha"
odin build tests/alpha_fuzz.odin -file -o:speed -define:ODECS_PATENTED=true -sanitize:address -out:"$work/alpha_fuzz"
odin build tests/movie_planar.odin -file -o:speed -define:ODECS_PATENTED=true -out:"$work/movie_planar"
bash tests/alpha_fixtures.sh "$work/fx" $large > /dev/null

echo "== decoded planes against FFmpeg (ProRes colour within 1, VP9 and alpha exact)"
for f in "$work"/fx/*.mov "$work"/fx/*.webm; do
	name=$(basename "$f")
	[ -f "${f%.*}.yuv" ] || continue
	[[ "$name" == hevc_* ]] && continue # checked through video.Reader below
	for threads in 1 8; do
		if "$work/alpha_compare" "$f" - $threads > "$f.$threads.log" 2>&1; then pass "$name threads=$threads"; else bad "$name threads=$threads"; cat "$f.$threads.log"; fi
	done
done

echo "== video.Reader: frames, alpha, seeks, PCM"
for f in "$work"/fx/prores_4444_a16.mov "$work"/fx/prores_4444_odd.mov "$work"/fx/prores_422_interlaced.mov "$work"/fx/vp9_alpha.webm "$work"/fx/vp9_twopass.webm "$work"/fx/vp9_rgb.webm; do
	if "$work/movie_alpha" "$f" "${f%.*}.yuv" 4 > "$f.reader.log" 2>&1 && ! grep -q "alpha vs FFmpeg: max difference [1-9]" "$f.reader.log"; then pass "reader $(basename "$f")"; else bad "reader $(basename "$f")"; cat "$f.reader.log"; fi
done
for a in pcm_s16le pcm_s16be pcm_s24le pcm_f32le; do
	f="$work/fx/prores_audio_$a.mov"
	ffmpeg -v error -y -i "$f" -map 0:a -f f32le "$f.f32"
	if "$work/movie_alpha" "$f" - 1 "$f.f32" > "$f.reader.log" 2>&1 && grep -q "max difference 0$" "$f.reader.log"; then pass "PCM $a"; else bad "PCM $a"; cat "$f.reader.log"; fi
done
transparent=../onimite/third_party/fframes/examples/audio-announce/dynamic_media/transparent.mov
if [ -f "$transparent" ]; then
	ffmpeg -v error -y -i "$transparent" -f rawvideo -pix_fmt yuva444p12le "$work/transparent.yuv"
	echo yuva444p12le > "$work/transparent.fmt"
	if "$work/alpha_compare" "$transparent" "$work/transparent.yuv" > "$work/transparent.log" 2>&1; then pass "fframes transparent.mov planes"; else bad "fframes transparent.mov planes"; cat "$work/transparent.log"; fi
	if "$work/movie_alpha" "$transparent" "$work/transparent.yuv" 4 > "$work/transparent.reader.log" 2>&1 && grep -q "alpha vs FFmpeg: max difference 0," "$work/transparent.reader.log"; then pass "fframes transparent.mov reader"; else bad "fframes transparent.mov reader"; cat "$work/transparent.reader.log"; fi
fi

echo "== planar output: planar_to_rgba equals the RGBA output"
for f in "$work"/fx/vp9_alpha.webm "$work"/fx/vp9_rgb.webm "$work"/fx/vp9_12bit.webm "$work"/fx/prores_4444_a16.mov "$work"/fx/prores_422_odd.mov; do
	if "$work/movie_planar" "$f" > "$f.planar.log" 2>&1; then pass "planar $(basename "$f")"; else bad "planar $(basename "$f")"; cat "$f.planar.log"; fi
done

if [ -f "$work/fx/hevc_alpha.mov" ]; then
	echo "== HEVC alpha layer (X265_ALPHA fixtures)"
	f="$work/fx/hevc_alpha.mov"
	if "$work/movie_alpha" "$f" "${f%.mov}.yuv" 4 > "$f.reader.log" 2>&1 && grep -q "alpha vs FFmpeg: max difference 0," "$f.reader.log"; then pass "reader hevc_alpha.mov (alpha exact)"; else bad "reader hevc_alpha.mov"; cat "$f.reader.log"; fi
	f="$work/fx/hevc_alpha_bframes.mov"
	if "$work/movie_alpha" "$f" - 4 > "$f.reader.log" 2>&1 && grep -q "alpha true" "$f.reader.log"; then pass "reader hevc_alpha_bframes.mov (seeks)"; else bad "reader hevc_alpha_bframes.mov"; cat "$f.reader.log"; fi
	for f in "$work"/fx/hevc_alpha.mov "$work"/fx/hevc_alpha_bframes.mov; do
		if "$work/movie_planar" "$f" > "$f.planar.log" 2>&1; then pass "planar $(basename "$f")"; else bad "planar $(basename "$f")"; cat "$f.planar.log"; fi
	done
	f="$work/fx/hevc_alpha_bframes.mov"
	if ASAN_OPTIONS=detect_leaks=0 "$work/alpha_fuzz" 100 "$f" > "$f.fuzz.log" 2>&1 && grep -q "leaked allocations 0" "$f.fuzz.log"; then pass "fuzz $(basename "$f")"; else bad "fuzz $(basename "$f")"; tail -20 "$f.fuzz.log"; fi
fi

echo "== fuzz (AddressSanitizer)"
for f in "$work"/fx/prores_4444_a16.mov "$work"/fx/prores_audio_pcm_s24le.mov "$work"/fx/vp9_alpha.webm "$work"/fx/vp9_twopass.webm; do
	if ASAN_OPTIONS=detect_leaks=0 "$work/alpha_fuzz" 100 "$f" > "$f.fuzz.log" 2>&1 && grep -q "leaked allocations 0" "$f.fuzz.log"; then pass "fuzz $(basename "$f")"; else bad "fuzz $(basename "$f")"; tail -20 "$f.fuzz.log"; fi
done
exit $fail
