#!/usr/bin/env bash
# Matroska gate: H.264/H.265 video and AAC/PCM audio in .mkv through
# video.Reader. Video must match the same streams remuxed to MP4 frame for
# frame (that path is verified against FFmpeg); audio is compared with
# FFmpeg's own decode of the .mkv. Also a stream written without seeking
# (unknown Segment size), a cut-off recording, and a short fuzz pass.
# FFmpeg is a development oracle only.
#   bash tests/mkv_check.sh [work-dir]
set -euo pipefail
cd "$(dirname "$0")/.."
work=${1:-/tmp/odecs-mkv}
fx="$work/fx"
mkdir -p "$fx"
fail=0
pass() { printf '  %-48s ok\n' "$1"; }
bad() { printf '  %-48s FAIL\n' "$1"; fail=1; }

odin test container/webm
odin test video -o:speed -define:ODECS_PATENTED=true
odin build tests/movie_equal.odin -file -o:speed -define:ODECS_PATENTED=true -out:"$work/movie_equal"
odin build tests/movie_alpha.odin -file -o:speed -define:ODECS_PATENTED=true -out:"$work/movie_alpha"
odin build tests/alpha_fuzz.odin -file -o:speed -define:ODECS_PATENTED=true -sanitize:address -out:"$work/alpha_fuzz"
odin build tests/vp9_encode_check.odin -file -o:speed -out:"$work/vp9_encode_check"

echo "== WebM chapters round trip and ffprobe oracle"
"$work/vp9_encode_check" "$fx/chapters" 64 48 100 1 8 0 animation 5 > "$fx/chapters.log" 2>&1
ffprobe -v error -show_chapters -of json "$fx/chapters.webm" > "$fx/chapters.json"
if grep -q '"start_time": "0.000000"' "$fx/chapters.json" &&
	grep -q '"end_time": "0.100000"' "$fx/chapters.json" &&
	grep -q '"title": "Intro"' "$fx/chapters.json" &&
	grep -q '"title": "Scène 2: Café & 🎬"' "$fx/chapters.json" &&
	grep -q '"start_time": "0.200000"' "$fx/chapters.json" &&
	grep -q '"end_time": "0.266667"' "$fx/chapters.json" &&
	grep -q '"title": "Finale"' "$fx/chapters.json"; then
	pass "WebM chapters ffprobe + reader round trip"
else
	bad "WebM chapters ffprobe + reader round trip"; cat "$fx/chapters.json"
fi

ff() { ffmpeg -v error -y "$@"; }
cat > "$fx/chapters.ffmeta" << 'EOF'
;FFMETADATA1
[CHAPTER]
TIMEBASE=1/1000
START=0
END=1000
title=Intro
[CHAPTER]
TIMEBASE=1/1000
START=1000
END=2000
title=Scène 2: Café & 🎬
[CHAPTER]
TIMEBASE=1/1000
START=2000
END=3000
title=Finale
EOF
src="-f lavfi -i testsrc2=size=640x360:rate=30:d=3 -f lavfi -i sine=frequency=440:sample_rate=48000:d=3"
ff $src -i "$fx/chapters.ffmeta" -map_metadata 2 -map_chapters 2 -ac 2 -c:v libx264 -pix_fmt yuv420p -bf 3 -g 30 -c:a aac "$fx/h264_aac.mkv"
ff -f lavfi -i testsrc2=size=480x270:rate=25:d=3 -f lavfi -i sine=frequency=300:sample_rate=44100:d=3 \
	-c:v libx265 -x265-params log-level=error:bframes=4 -pix_fmt yuv420p10le -c:a aac "$fx/h265_10bit_aac.mkv"
for a in pcm_s16le pcm_s16be pcm_s24le pcm_f32le; do
	ff $src -ac 2 -c:v libx264 -bf 2 -g 30 -c:a $a "$fx/h264_$a.mkv"
done
ff -f lavfi -i testsrc2=size=1280x720:rate=60000/1001:d=3 -c:v libx264 -bf 3 -x264-params open-gop=1:keyint=40 \
	-colorspace bt709 -color_range pc "$fx/h264_ntsc_open_gop.mkv"
ff $src -ac 2 -c:v libx264 -bf 0 -g 60 -c:a aac -f matroska - > "$fx/h264_streamed.mkv"
head -c $(( $(stat -c %s "$fx/h264_aac.mkv") * 7 / 10 )) "$fx/h264_aac.mkv" > "$fx/cut.mkv"
ff -f lavfi -i testsrc2=size=160x96:rate=30:d=2 -f lavfi -i sine=sample_rate=48000:d=2 -ac 2 -c:v libx264 -bf 2 -g 15 -c:a aac "$fx/small_h264_aac.mkv"
ff -f lavfi -i testsrc2=size=160x96:rate=25:d=2 -f lavfi -i sine=sample_rate=44100:d=2 -c:v libx265 -x265-params log-level=error \
	-pix_fmt yuv420p10le -c:a pcm_s24le "$fx/small_h265_pcm.mkv"

echo "== video: every frame identical to the MP4 remux"
for f in "$fx"/h264_*.mkv "$fx"/h265_*.mkv; do
	name=$(basename "$f")
	ff -i "$f" -c copy "${f%.mkv}.mp4"
	if "$work/movie_equal" "$f" "${f%.mkv}.mp4" --no-audio > "$f.equal.log" 2>&1; then pass "$name"; else bad "$name"; cat "$f.equal.log"; fi
done

echo "== audio against FFmpeg (PCM exact, AAC within decoder rounding), seeks"
for f in "$fx"/h264_aac.mkv "$fx"/h265_10bit_aac.mkv "$fx"/h264_streamed.mkv "$fx"/h264_pcm_*.mkv; do
	name=$(basename "$f")
	ff -i "$f" -map 0:a -f f32le "$f.f32"
	limit=0
	case "$name" in *aac*|*streamed*) limit=0.001 ;; esac
	if "$work/movie_alpha" "$f" - 1 "$f.f32" > "$f.reader.log" 2>&1 &&
		awk -v limit=$limit '/pcm:/ { gsub(/[(),]/, ""); ok = ($2 == $5 && $NF <= limit) } END { exit !ok }' "$f.reader.log"; then
		pass "$name $(grep -o 'max difference .*' "$f.reader.log")"
	else
		bad "$name"; cat "$f.reader.log"
	fi
done

echo "== a recording cut off mid-cluster keeps its complete frames"
if "$work/movie_equal" "$fx/cut.mkv" "$fx/cut.mkv" > "$fx/cut.log" 2>&1 && grep -q "frames identical" "$fx/cut.log"; then
	pass "cut.mkv $(grep -o '[0-9]* frames identical' "$fx/cut.log")"
else
	bad "cut.mkv"; cat "$fx/cut.log"
fi

echo "== fuzz (AddressSanitizer)"
for f in "$fx"/small_h264_aac.mkv "$fx"/small_h265_pcm.mkv; do
	if ASAN_OPTIONS=detect_leaks=0 "$work/alpha_fuzz" 300 "$f" > "$f.fuzz.log" 2>&1 && grep -q "leaked allocations 0" "$f.fuzz.log"; then pass "fuzz $(basename "$f")"; else bad "fuzz $(basename "$f")"; tail -20 "$f.fuzz.log"; fi
done
exit $fail
