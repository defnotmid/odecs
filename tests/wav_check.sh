#!/usr/bin/env bash
# WAV gate: every supported sample format, RF64, header chunks before the
# data, unfilled sizes from a piped writer and a cut-off file through
# movie.Reader, bit-exact against FFmpeg's f32 decode (whole stream and
# reads after random seeks); a refused codec; and a short fuzz pass. FFmpeg
# is a development oracle only.
#   bash tests/wav_check.sh [work-dir]
set -euo pipefail
cd "$(dirname "$0")/.."
work=${1:-/tmp/odecs-wav}
fx="$work/fx"
mkdir -p "$fx"
fail=0
pass() { printf '  %-40s ok\n' "$1"; }
bad() { printf '  %-40s FAIL\n' "$1"; fail=1; }

odin test wav
odin build tests/movie_alpha.odin -file -o:speed -out:"$work/movie_alpha"
odin build tests/alpha_fuzz.odin -file -o:speed -sanitize:address -out:"$work/alpha_fuzz"

ff() { ffmpeg -v error -y "$@"; }
tone="aevalsrc=0.8*sin(2*PI*440*t)+0.15*sin(2*PI*3000*t)*sin(2*PI*0.5*t)"
two="$tone|0.5*sin(2*PI*220*t)"
ff -f lavfi -i "$tone:s=22050:d=3" -c:a pcm_u8 "$fx/u8_mono.wav"
ff -f lavfi -i "$two:s=44100:d=3" -c:a pcm_s16le "$fx/s16_stereo.wav"
ff -f lavfi -i "$two:s=48000:d=3" -c:a pcm_s24le -write_bext 1 -metadata title=gate "$fx/s24_bext.wav"
ff -f lavfi -i "$two|0.2*sin(2*PI*55*t)|0.3*sin(2*PI*880*t)|0.1*sin(2*PI*100*t)|0.4*sin(2*PI*660*t):s=96000:d=2:c=5.1" -c:a pcm_s32le "$fx/s32_51_96k.wav"
ff -f lavfi -i "$two:s=48000:d=3" -c:a pcm_f32le "$fx/f32_stereo.wav"
ff -f lavfi -i "$tone:s=48000:d=3" -c:a pcm_f64le "$fx/f64_mono.wav"
ff -f lavfi -i "$two:s=48000:d=3" -c:a pcm_s24le -rf64 always "$fx/rf64.wav"
ff -f lavfi -i "$two:s=48000:d=3" -c:a pcm_s16le -f wav - > "$fx/piped.wav"
ff -f lavfi -i "$tone:s=8000:d=2" -c:a pcm_mulaw "$fx/mulaw.wav"
ff -f lavfi -i "$tone:s=8000:d=2" -c:a pcm_alaw "$fx/alaw.wav"
head -c $(( $(stat -c %s "$fx/s16_stereo.wav") * 6 / 10 + 1 )) "$fx/s16_stereo.wav" > "$fx/cut.wav"
ff -f lavfi -i "$tone:s=8000:d=1" -c:a adpcm_ms "$fx/adpcm.wav"

echo "== PCM against FFmpeg: whole stream and after 30 random seeks, exact"
for f in "$fx"/*.wav; do
	name=$(basename "$f")
	[ "$name" = adpcm.wav ] && continue
	ff -i "$f" -f f32le "${f%.wav}.f32" 2>/dev/null # cut.wav ends in half a frame, which FFmpeg reports
	if "$work/movie_alpha" "$f" - 1 "${f%.wav}.f32" > "$f.log" 2>&1 &&
		awk '/pcm:/ { gsub(/[(),]/, ""); whole = ($2 == $5 && $NF == 0) } /pcm seeks:/ { seeks = ($NF == 0) } END { exit !(whole && seeks) }' "$f.log"; then
		pass "$name"
	else
		bad "$name"; cat "$f.log"
	fi
done

echo "== compressed WAV is refused"
if "$work/movie_alpha" "$fx/adpcm.wav" > "$fx/adpcm.log" 2>&1; then bad "adpcm.wav opened"; elif grep -q Unsupported "$fx/adpcm.log"; then pass "adpcm.wav -> Unsupported"; else bad "adpcm.wav"; cat "$fx/adpcm.log"; fi

echo "== fuzz (AddressSanitizer)"
mkdir -p "$work/fuzz"
ff -f lavfi -i "sine=sample_rate=8000:d=0.25" -ac 2 -c:a pcm_s24le -write_bext 1 "$work/fuzz/s24_bext.wav"
ff -f lavfi -i "sine=sample_rate=8000:d=0.25" -c:a pcm_s16le -rf64 always "$work/fuzz/rf64.wav"
ff -f lavfi -i "sine=sample_rate=8000:d=0.25" -c:a pcm_mulaw "$work/fuzz/mulaw.wav"
for f in "$work"/fuzz/*.wav; do
	if ASAN_OPTIONS=detect_leaks=0 "$work/alpha_fuzz" 500 "$f" > "$f.fuzz.log" 2>&1 && grep -q "leaked allocations 0" "$f.fuzz.log"; then pass "fuzz $(basename "$f")"; else bad "fuzz $(basename "$f")"; tail -20 "$f.fuzz.log"; fi
done
exit $fail
