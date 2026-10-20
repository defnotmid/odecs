#!/usr/bin/env bash
# FFmpeg/libvpx and Chromium are development oracles only.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .work/tmp .work/vp9-encode
export TMPDIR="$PWD/.work/tmp"
odin test video/vp9/encoder -vet -strict-style -out:.work/vp9-encode/encoder-test
odin test container/webm -vet -strict-style -out:.work/vp9-encode/webm-test
odin test video/vp9 -vet -strict-style -out:.work/vp9-encode/shared-test
odin build tests/vp9_encode_check.odin -file -o:speed -vet -strict-style -out:.work/vp9-encode/check
for size in '1 1' '7 5' '17 19' '64 64' '65 67' '257 73' '1025 67'; do
	read -r w h <<< "$size"
	for q in 0 1 32 100 255; do
		for block in 3 4 5; do
			p=".work/vp9-encode/${w}x${h}-q${q}-b${block}"
			.work/vp9-encode/check "$p" "$w" "$h" "$q" 4 8 1 animation "$block"
			ffmpeg -v error -y -threads 1 -i "$p.webm" -fps_mode passthrough -pix_fmt yuv420p -f rawvideo "$p.ffmpeg.yuv"
			cmp "$p.rec.yuv" "$p.ffmpeg.yuv"
			ffmpeg -v error -y -c:v libvpx-vp9 -threads 1 -i "$p.webm" -fps_mode passthrough -pix_fmt yuv420p -f rawvideo "$p.libvpx.yuv"
			cmp "$p.rec.yuv" "$p.libvpx.yuv"
			ffmpeg -v error -y -threads 1 -i "$p.alpha.webm" -fps_mode passthrough -pix_fmt yuv420p -f rawvideo "$p.alpha.ffmpeg.yuv"
			cmp "$p.alpha.rec.yuv" "$p.alpha.ffmpeg.yuv"
			ffmpeg -v error -y -c:v libvpx-vp9 -threads 1 -i "$p.webm" -fps_mode passthrough -vf alphaextract -pix_fmt gray -f rawvideo "$p.alpha.additional.raw"
			cmp "$p.alpha.luma" "$p.alpha.additional.raw"
			if [ "$q" = 0 ]; then cmp "$p.source.yuv" "$p.rec.yuv"; fi
			ffprobe -v error -count_frames -show_entries stream=codec_name,width,height,color_range,color_space,nb_read_frames:stream_tags=alpha_mode -show_entries format=duration -of default "$p.webm" > "$p.structure.txt"
			grep -q 'nb_read_frames=8' "$p.structure.txt"
			grep -q 'TAG:alpha_mode=1' "$p.structure.txt"
		done
	done
done
for content in flat noise; do
	for q in 0 100 255; do
		p=".work/vp9-encode/$content-q$q"
		.work/vp9-encode/check "$p" 257 73 "$q" 1 8 0 "$content" 5
		ffmpeg -v error -y -i "$p.webm" -fps_mode passthrough -pix_fmt yuv420p -f rawvideo "$p.ffmpeg.yuv"
		cmp "$p.rec.yuv" "$p.ffmpeg.yuv"
	done
done
if [ -n "${VP9_CAMERA:-}" ]; then
	ffmpeg -v error -y -i "$VP9_CAMERA" -frames:v 8 -vf scale=320:180 -pix_fmt yuv420p -f rawvideo .work/vp9-encode/camera-source.yuv
	.work/vp9-encode/check .work/vp9-encode/camera 320 180 100 1 8 0 .work/vp9-encode/camera-source.yuv 5 120
	ffmpeg -v error -y -i .work/vp9-encode/camera.webm -fps_mode passthrough -pix_fmt yuv420p -f rawvideo .work/vp9-encode/camera.ffmpeg.yuv
	cmp .work/vp9-encode/camera.rec.yuv .work/vp9-encode/camera.ffmpeg.yuv
fi
p=.work/vp9-encode/browser
.work/vp9-encode/check "$p" 128 128 0 1 8 1 animation 4
bash tests/vp9_browser_check.sh "$p" 128 128 8
printf 'VP9/WebM oracle gate passed\n'
