#!/usr/bin/env bash
# Matched-quality (PSNR, not QP) comparison. Single-pass libvpx good/cpu-used 4.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .work/tmp .work/vp9-quality
export TMPDIR="$PWD/.work/tmp"
odin build tests/vp9_encode_check.odin -file -o:speed -vet -strict-style -out:.work/vp9-quality/check
p=.work/vp9-quality/animation
.work/vp9-quality/check "$p" 320 180 100 1 30 0 animation 5 120
.work/vp9-quality/check "$p-lossless" 320 180 0 1 30 0 animation 5 120
for crf in 24 28 32 36 40 44 48 50 51 52 56 60 63; do
	o=".work/vp9-quality/libvpx-crf$crf.webm"
	ffmpeg -v error -y -f rawvideo -pixel_format yuv420p -video_size 320x180 -framerate 30 -i "$p.source.yuv" -c:v libvpx-vp9 -deadline good -cpu-used 4 -threads 1 -tile-columns 2 -g 120 -lag-in-frames 0 -b:v 0 -crf "$crf" "$o"
	ffmpeg -v error -y -i "$o" -fps_mode passthrough -pix_fmt yuv420p -f rawvideo "$o.yuv"
	ffmpeg -v info -f rawvideo -pixel_format yuv420p -video_size 320x180 -framerate 30 -i "$p.source.yuv" -f rawvideo -pixel_format yuv420p -video_size 320x180 -framerate 30 -i "$o.yuv" -lavfi psnr -f null - > "$o.psnr.log" 2>&1
	bytes=$(ffprobe -v error -show_entries packet=size -of csv=p=0 "$o" | awk '{s+=$1}END{print s}')
	printf 'libvpx crf=%s payload_bytes=%s ' "$crf" "$bytes"
	grep 'PSNR y:' "$o.psnr.log"
done
ffmpeg -v error -y -f rawvideo -pixel_format yuv420p -video_size 320x180 -framerate 30 -i "$p.source.yuv" -c:v libvpx-vp9 -deadline good -cpu-used 4 -threads 1 -tile-columns 2 -g 120 -lag-in-frames 0 -lossless 1 .work/vp9-quality/libvpx-lossless.webm
ffprobe -v error -show_entries packet=size -of csv=p=0 .work/vp9-quality/libvpx-lossless.webm | awk '{s+=$1}END{print "libvpx lossless payload_bytes="s}'
ffmpeg -v error -y -i .work/vp9-quality/libvpx-lossless.webm -fps_mode passthrough -pix_fmt yuv420p -f rawvideo .work/vp9-quality/libvpx-lossless.yuv
cmp "$p.source.yuv" .work/vp9-quality/libvpx-lossless.yuv
printf 'Input hash: '; sha256sum "$p.source.yuv"
printf 'Compiler: '; odin version
jj --no-pager log -r '@-' --no-graph -T '"base: " ++ commit_id.short(12) ++ " " ++ description.first_line() ++ "\n"' 2>/dev/null || true
printf 'delta sha256: '; jj --no-pager diff -r @ --git 2>/dev/null | sha256sum
ffmpeg -version | sed -n '1p'
cat /proc/loadavg
