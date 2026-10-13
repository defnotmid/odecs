#!/usr/bin/env bash
# All reported codec times come from resident-input, in-process harnesses.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$#" -ne 7 ]; then
    echo "usage: benchmark.sh input.yuv width height frames workers slices qp" >&2
    exit 2
fi
BUILD=${BUILD:-build}
MICROARCH=${MICROARCH:-native}
mkdir -p "$BUILD/benchmark"
odin build tests/benchmark.odin -file -o:speed -microarch:"$MICROARCH" -out:"$BUILD/benchmark/encode"
odin build tests/decode_timing.odin -file -o:speed -microarch:"$MICROARCH" -out:"$BUILD/benchmark/decode"
odin build tests/yuv_dump.odin -file -o:speed -microarch:"$MICROARCH" -out:"$BUILD/benchmark/yuv_dump"
c++ -std=c++17 -O3 tests/x264_benchmark.cpp -lx264 -o "$BUILD/benchmark/x264"
c++ -std=c++17 -O3 tests/ffmpeg_benchmark.cpp -lavformat -lavcodec -lavutil -o "$BUILD/benchmark/ffmpeg"
for codec in encode x264; do
    output="$BUILD/benchmark/$codec"
    "$output" "$@" "$output.264" | tee "$output.log"
    ffmpeg -v error -i "$output.264" -f rawvideo -pix_fmt yuv420p -y "$output.yuv"
    [ "$(stat -c %s "$output.yuv")" = "$(($2*$3*3/2*$4))" ]
    "$BUILD/benchmark/yuv_dump" "$output.264" "$output.ours.yuv" >/dev/null
    cmp "$output.yuv" "$output.ours.yuv"
    ffmpeg -v info -f rawvideo -pix_fmt yuv420p -s "${2}x${3}" -i "$1" -f rawvideo -pix_fmt yuv420p -s "${2}x${3}" -i "$output.yuv" -frames:v "$4" -lavfi psnr -f null - > "$output.psnr.log" 2>&1
    sed -n 's/.*PSNR /PSNR /p' "$output.psnr.log"
    ffmpeg -v info -f rawvideo -pix_fmt yuv420p -s "${2}x${3}" -i "$1" -f rawvideo -pix_fmt yuv420p -s "${2}x${3}" -i "$output.yuv" -frames:v "$4" -lavfi ssim -f null - > "$output.ssim.log" 2>&1
    sed -n 's/.*SSIM /SSIM /p' "$output.ssim.log"
    "$BUILD/benchmark/decode" "$output.264" "$4"
    "$BUILD/benchmark/ffmpeg" "$output.264" "$4" "$5"
done
