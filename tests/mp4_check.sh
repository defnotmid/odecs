#!/usr/bin/env bash
# MP4 container and movie gate. FFmpeg/ffprobe are development oracles:
# they produce third-party fixtures and reference decodes, never a runtime
# dependency. Usage: bash tests/mp4_check.sh [work-dir]
set -euo pipefail
cd "$(dirname "$0")/.."
work=${1:-/tmp/odecs-mp4}
mkdir -p "$work"
fail=0
pass() { printf '  %-44s ok\n' "$1"; }
bad() { printf '  %-44s FAIL\n' "$1"; fail=1; }

odin test container/mp4
odin test video -o:speed
odin build tools/mp4_smoke -o:speed -define:ODECS_PATENTED=true -out:"$work/mp4_smoke"
odin build tests/mp4_interop.odin -file -o:speed -define:ODECS_PATENTED=true -out:"$work/mp4_interop"

reference() { # file -> ref.rgba / ref.pcm next to it
	if ffprobe -v error -select_streams v -show_entries stream=index -of csv=p=0 "$1" | grep -q .; then
		ffmpeg -v error -y -i "$1" -map 0:v:0 -fps_mode passthrough -f rawvideo -pix_fmt rgba "$1.rgba"
	else
		rm -f "$1.rgba"
	fi
	if ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$1" | grep -q .; then
		ffmpeg -v error -y -i "$1" -map 0:a:0 -f f32le "$1.pcm"
	else
		rm -f "$1.pcm"
	fi
}
interop() { # file [args]
	local f=$1; shift
	local rgba=-; [ -f "$f.rgba" ] && rgba="$f.rgba"
	local pcm=-; [ -f "$f.pcm" ] && pcm="$f.pcm"
	local first="-1"
	if [ "$rgba" != "-" ]; then
		first=$(ffprobe -v error -select_streams v:0 -show_entries frame=pts_time -read_intervals "%+#1" -of csv=p=0 "$f" | head -1 | tr -d ,)
	fi
	if "$work/mp4_interop" "$f" "$rgba" "$pcm" --first-time "$first" "$@" > "$f.log" 2>&1; then pass "$(basename "$f") $*"; else bad "$(basename "$f") $*"; cat "$f.log" || true; fi
}

echo "== odecs output: smoke round trips, FFmpeg decode and interop"
for spec in "h264 --native" "h264" "h265 --native --frames 30" "h265" "h264 --native --fps 30000/1001 --size 1280x720 --frames 45 --no-faststart" "h264 --native --size 320x240 --no-audio" "h264 --native --chapters"; do
	set -- $spec
	name="$work/odecs-$(printf %s "$spec" | tr -c '[:alnum:]' _).mp4"
	codec=$1; shift
	if "$work/mp4_smoke" "$name" --codec "$codec" "$@" > "$name.smoke" 2>&1; then pass "smoke $spec"; else bad "smoke $spec"; cat "$name.smoke" || true; continue; fi
	if [ -n "$(ffmpeg -v error -i "$name" -f null - 2>&1)" ]; then bad "ffmpeg decodes cleanly: $spec"; else pass "ffmpeg decodes cleanly: $spec"; fi
	case "$spec" in *--chapters*)
		chref="$name.chapters.json"
		ffprobe -v error -show_chapters -of json "$name" > "$chref"
		if grep -q '"start_time": "0.000000"' "$chref" &&
			grep -q '"end_time": "1.000000"' "$chref" &&
			grep -q '"title": "Intro"' "$chref" &&
			grep -q '"title": "Scène 2: Café & 🎬"' "$chref" &&
			grep -q '"start_time": "2.000000"' "$chref" &&
			grep -q '"end_time": "3.000000"' "$chref" &&
			grep -q '"title": "Finale"' "$chref"; then
			pass "ffprobe chapters: $spec"
		else
			bad "ffprobe chapters: $spec"; cat "$chref" || true
		fi ;;
	esac
	reference "$name"
	interop "$name" --native
	rm -f "$name.rgba" "$name.pcm" # raw references are large
done

echo "== third-party files through the demuxer and native decoders"
src=(-f lavfi -i "testsrc2=size=640x360:rate=25:duration=4" -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=4")
tags=(-colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv)
ffmpeg -v error -y "${src[@]}" -c:v libx264 -preset fast -bf 3 -b_strategy 2 -g 50 "${tags[@]}" -pix_fmt yuv420p -c:a aac -b:a 128k -ac 2 -movflags +faststart "$work/x264-bframes.mp4"
ffmpeg -v error -y "${src[@]}" -c:v libx264 -preset fast -bf 2 -g 25 -x264-params open-gop=1 "${tags[@]}" -pix_fmt yuv420p -c:a aac -ac 1 -ar 44100 "$work/x264-opengop.mp4"
ffmpeg -v error -y "${src[@]}" -c:v libx265 -preset fast -x265-params "bframes=4:log-level=error" -tag:v hvc1 "${tags[@]}" -pix_fmt yuv420p -c:a aac "$work/x265-bframes.mp4"
ffmpeg -v error -y "${src[@]}" -c:v libx265 -preset fast -x265-params log-level=error -pix_fmt yuv420p10le "${tags[@]}" -an "$work/x265-main10.mp4"
ffmpeg -v error -y "${src[@]}" -c:v libx264 -preset fast "${tags[@]}" -pix_fmt yuv420p -c:a aac -f mov "$work/x264.mov"
ffmpeg -v error -y -f lavfi -i "testsrc2=size=646x358:rate=24000/1001:duration=3" -c:v libx264 -preset fast -pix_fmt yuv420p -an "$work/x264-cropped-sd.mp4"
ffmpeg -v error -y -ss 1.3 -i "$work/x264-bframes.mp4" -c copy -avoid_negative_ts make_zero "$work/x264-trimmed.mp4"
# Stream copy from 0.5 s: the edit list hides the GOP's pre-roll frames.
ffmpeg -v error -y -ss 0.5 -i "$work/x264-bframes.mp4" -c copy "$work/x264-cut.mp4"
# QuickTime nclc carries no range flag; full range comes from the VUI.
ffmpeg -v error -y "${src[@]}" -c:v libx264 -preset fast -pix_fmt yuvj420p -color_range pc -movflags +write_colr -an -f mov "$work/x264-fullrange.mov"
# Fragmented MP4 and M4A (mvex/trex + moof/traf/tfhd/tfdt/trun).
ffmpeg -v error -y "${src[@]}" -c:v libx264 -preset fast "${tags[@]}" -pix_fmt yuv420p -c:a aac -movflags frag_keyframe+delay_moov+default_base_moof "$work/fragmented.mp4"
ffmpeg -v error -y -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=2" -c:a aac -movflags frag_keyframe+empty_moov+default_base_moof "$work/aac-fragmented.m4a"
# Apple Lossless (.m4a) and Opus in MP4.
ffmpeg -v error -y -f lavfi -i "aevalsrc=0.4*sin(2*PI*440*t)|0.3*cos(2*PI*660*t):s=48000:d=2" -c:a alac "$work/alac-16.m4a"
ffmpeg -v error -y -f lavfi -i "aevalsrc=0.4*sin(2*PI*440*t)|0.3*cos(2*PI*660*t):s=96000:d=1" -c:a alac -sample_fmt s32p "$work/alac-24-96k.m4a"
ffmpeg -v error -y -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=2" -c:a libopus -application lowdelay -b:a 128k "$work/opus.mp4"
for f in x264-bframes.mp4 x264-opengop.mp4 x265-bframes.mp4 x264.mov x264-cropped-sd.mp4 x264-trimmed.mp4 x264-cut.mp4 x264-fullrange.mov fragmented.mp4 aac-fragmented.m4a alac-16.m4a alac-24-96k.m4a opus.mp4; do
	reference "$work/$f"
	interop "$work/$f" --native
	{ [ "$f" = x264-bframes.mp4 ] || [ "$f" = fragmented.mp4 ]; } && interop "$work/$f" # automatic: hardware decode when admitted
	rm -f "$work/$f.rgba" "$work/$f.pcm"
done
# FFmpeg's 10-bit RGB path interpolates chroma where the reader replicates
# it; testsrc2's saturated edges then differ by up to ~3 dB. Alignment and
# the bias-free mean are still checked.
reference "$work/x265-main10.mp4"
interop "$work/x265-main10.mp4" --native --min-psnr 30
rm -f "$work/x265-main10.mp4.rgba"

if [ "$fail" = 0 ]; then echo "mp4 gate: ok"; else echo "mp4 gate: FAILED"; exit 1; fi
