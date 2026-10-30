#!/usr/bin/env bash
# Hardware decode gate: writes fixtures and runs media/vulkan's Vulkan tests,
# H.264 with B-frames and an open-GOP H.265 stream (CRA leading pictures)
# against FFmpeg's planar output, and HEVC device surfaces.
#   bash tests/gpu_check.sh [work-dir]
set -euo pipefail
out=$(realpath -m "${1:-.work/gpufx}")
mkdir -p "$out"
export TMPDIR=${TMPDIR:-$PWD/.work/tmp}
ff=(ffmpeg -hide_banner -loglevel error -y)
src=(-f lavfi -i "testsrc2=size=386x242:rate=30")
"${ff[@]}" "${src[@]}" -pix_fmt yuv420p -frames:v 40 -c:v libx264 -profile:v high -bf 2 -f h264 "$out/avc.264"
"${ff[@]}" -i "$out/avc.264" -f rawvideo -pix_fmt yuv420p "$out/avc.yuv"
"${ff[@]}" "${src[@]}" -pix_fmt yuv420p -frames:v 30 -c:v libx265 -x265-params "bframes=0:log-level=none" -f hevc "$out/surface.265"
# x265's default open GOP: CRA keyframes every 30 pictures with RASL pictures.
"${ff[@]}" -f lavfi -i "testsrc2=size=640x360:rate=30" -pix_fmt yuv420p10le -frames:v 90 -c:v libx265 -x265-params "bframes=4:keyint=30:log-level=none" -f hevc "$out/hevc_open_gop.265"
"${ff[@]}" -i "$out/hevc_open_gop.265" -f rawvideo -pix_fmt yuv420p10le "$out/hevc_open_gop.yuv"
odin test media/vulkan -o:speed -define:OICUT_PATENTED=true -define:ODIN_TEST_THREADS=1 \
	-define:OICUT_GPU_TEST=true -define:OICUT_GPU_AVC_TEST=true -define:OICUT_GPU_CONTEXT_TEST=true \
	-define:OICUT_GPU_SURFACE_TEST=true -define:OICUT_GPU_HEVC_TEST=true \
	-define:OICUT_GPU_AVC_FIXTURE="$out/avc.264" -define:OICUT_GPU_AVC_REFERENCE="$out/avc.yuv" \
	-define:OICUT_GPU_SURFACE_FIXTURE="$out/surface.265" \
	-define:OICUT_GPU_HEVC_FIXTURE="$out/hevc_open_gop.265" -define:OICUT_GPU_HEVC_REFERENCE="$out/hevc_open_gop.yuv" \
	2>&1 | grep -v "not a conformant"
