#!/usr/bin/env bash
# Compare the skip shortlist against exhaustive intra on the SAME source/config.
# Timings here are smoke measurements; benchmark.odin provides repeated timings.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$#" -ne 5 ]; then
    echo "usage: rd_compare.sh input.yuv width height frames output-name" >&2
    exit 2
fi
BUILD=${BUILD:-build}
src=$1; width=$2; height=$3; frames=$4; name=$5
mkdir -p "$BUILD/rd"
odin build tests/encode_clip.odin -file -o:speed -out:"$BUILD/encode_clip"
odin build tests/yuv_dump.odin -file -o:speed -out:"$BUILD/yuv_dump"
for qp in 22 26 30; do
    for mode in shortlist exhaustive; do
        flags=()
        [ "$mode" != exhaustive ] || flags+=(--exhaustive)
        output="$BUILD/rd/${name}_${qp}_${mode}"
        "$BUILD/encode_clip" "$src" "$width" "$height" "$frames" "$output.264" --qp "$qp" --workers 4 --slices 4 "${flags[@]}" > "$output.encode.log"
        ffmpeg -v error -i "$output.264" -f rawvideo -pix_fmt yuv420p -y "$output.yuv"
        [ "$(stat -c %s "$output.yuv")" = "$((width*height*3/2*frames))" ]
        "$BUILD/yuv_dump" "$output.264" "$output.ours.yuv" > "$output.decode.log"
        cmp "$output.yuv" "$output.ours.yuv"
        ffmpeg -v info -f rawvideo -pix_fmt yuv420p -s "${width}x${height}" -i "$src" -f rawvideo -pix_fmt yuv420p -s "${width}x${height}" -i "$output.yuv" -frames:v "$frames" -lavfi psnr -f null - > "$output.psnr.log" 2>&1
        psnr=$(sed -n 's/.*average:\([0-9.]*\).*/\1/p' "$output.psnr.log")
        [ -n "$psnr" ]
        printf '%s qp=%d %s bytes=%s psnr=%s parity=EXACT\n' "$name" "$qp" "$mode" "$(stat -c %s "$output.264")" "$psnr"
        rm "$output.ours.yuv" "$output.yuv"
    done
done
