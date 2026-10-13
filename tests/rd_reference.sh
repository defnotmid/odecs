#!/usr/bin/env bash
# Matched-work 1080p rate/distortion sweep. Times in this script are preliminary;
# benchmark.sh supplies repeated codec-call timing for the selected operating point.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$#" -lt 5 ]; then
    echo "usage: rd_reference.sh input.yuv width height frames workers [qp ...]" >&2
    exit 2
fi
BUILD=${BUILD:-build}
MICROARCH=${MICROARCH:-native}
src=$1; width=$2; height=$3; frames=$4; workers=$5; shift 5
[ "$#" -gt 0 ] || set -- 22 26 30 34
mkdir -p "$BUILD/reference"
odin build tests/encode_clip.odin -file -o:speed -microarch:"$MICROARCH" -out:"$BUILD/reference/encode"
odin build tests/yuv_dump.odin -file -o:speed -microarch:"$MICROARCH" -out:"$BUILD/reference/decode"
for qp in "$@"; do
    for codec in oicu x264; do
        output="$BUILD/reference/${codec}_${qp}"
        if [ "$codec" = oicu ]; then
            "$BUILD/reference/encode" "$src" "$width" "$height" "$frames" "$output.264" --qp "$qp" --workers "$workers" --slices "$workers" > "$output.log"
        else
            x264 --input-res "${width}x${height}" --fps 30 --frames "$frames" --quiet --profile baseline --preset medium --no-scenecut --ref 1 --qp "$qp" --ipratio 1 --pbratio 1 --keyint 15 --min-keyint 1 --threads "$workers" --slices "$workers" --sliced-threads --sync-lookahead 0 --rc-lookahead 0 -o "$output.264" "$src" 2> "$output.log"
        fi
        ffmpeg -v error -i "$output.264" -f rawvideo -pix_fmt yuv420p -y "$output.yuv"
        [ "$(stat -c %s "$output.yuv")" = "$((width*height*3/2*frames))" ]
        "$BUILD/reference/decode" "$output.264" "$output.ours.yuv" >/dev/null
        cmp "$output.yuv" "$output.ours.yuv"
        ffmpeg -v info -f rawvideo -pix_fmt yuv420p -s "${width}x${height}" -i "$src" -f rawvideo -pix_fmt yuv420p -s "${width}x${height}" -i "$output.yuv" -frames:v "$frames" -lavfi psnr -f null - > "$output.psnr.log" 2>&1
        ffmpeg -v info -f rawvideo -pix_fmt yuv420p -s "${width}x${height}" -i "$src" -f rawvideo -pix_fmt yuv420p -s "${width}x${height}" -i "$output.yuv" -frames:v "$frames" -lavfi ssim -f null - > "$output.ssim.log" 2>&1
        psnr=$(sed -n 's/.*average:\([0-9.]*\).*/\1/p' "$output.psnr.log")
        ssim=$(sed -n 's/.*All:\([0-9.]*\).*/\1/p' "$output.ssim.log")
        [ -n "$psnr" ] && [ -n "$ssim" ]
        printf '%s qp=%d bytes=%s psnr=%s ssim=%s parity=EXACT\n' "$codec" "$qp" "$(stat -c %s "$output.264")" "$psnr" "$ssim"
        rm "$output.yuv" "$output.ours.yuv"
    done
done
