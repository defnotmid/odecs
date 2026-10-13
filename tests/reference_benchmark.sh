#!/usr/bin/env bash
# Resident-input medians of seven. Requires Odin, C++, FFmpeg, x264 and x265.
# Run with no other benchmark/test workloads on the measured core.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK=${WORK:-.work/reference-benchmark}
CPU=${CPU:-23}
CASE=${CASE:-all}
case "$CASE" in all|720|1080) ;; *) echo "CASE must be all, 720 or 1080" >&2; exit 2;; esac
mkdir -p "$WORK/bin"
if [ "${SKIP_BUILD:-0}" != 1 ]; then
for pair in 'benchmark enc264' 'decode_timing dec264' 'yuv_dump dump264' \
            'encode_timing_h265 enc265' 'decode_timing_h265 dec265' 'decode_h265 dump265'; do
    read -r src dst <<< "$pair"
    odin build "tests/$src.odin" -file -o:speed -microarch:native -debug -out:"$WORK/bin/$dst"
done
c++ -std=c++17 -O3 -g tests/x264_benchmark.cpp -lx264 -o "$WORK/bin/x264"
c++ -std=c++17 -O3 -g tests/x265_benchmark.cpp -lx265 -o "$WORK/bin/x265"
c++ -std=c++17 -O3 -g tests/ffmpeg_benchmark.cpp -lavformat -lavcodec -lavutil -o "$WORK/bin/ffmpeg"
fi
run() { taskset -c "$CPU" "$@"; }
for spec in '720 1280 720 19 Zhling_1280x720.264' \
            '1080 1920 1080 54 VID_1920x1080_cabac_temporal_direct.264'; do
    read -r name w h frames fixture <<< "$spec"
    if [ "$CASE" != all ] && [ "$CASE" != "$name" ]; then continue; fi
    dir="$WORK/$name"
    mkdir -p "$dir"
    src="$dir/source.yuv"
    ffmpeg -v error -y -i "third_party/openh264/res/$fixture" -pix_fmt yuv420p -f rawvideo "$src"
    [ "$(stat -c %s "$src")" = "$((w*h*3/2*frames))" ]
    sha256sum "third_party/openh264/res/$fixture" "$src" > "$dir/inputs.sha256"
    for codec in 264 265; do
        for encoder in "enc$codec" "x$codec"; do
            prefix="$dir/$encoder"
            echo "BENCH $name $encoder"
            if [ "$codec" = 264 ]; then
                run "$WORK/bin/$encoder" "$src" "$w" "$h" "$frames" 1 4 26 "$prefix.$codec" | tee "$prefix.encode.log"
            elif [ "$encoder" = enc265 ]; then
                run "$WORK/bin/$encoder" "$src" "$w" "$h" "$frames" --qp 26 --out "$prefix.$codec" | tee "$prefix.encode.log"
            else
                run "$WORK/bin/$encoder" "$src" "$w" "$h" "$frames" 26 "$prefix.$codec" | tee "$prefix.encode.log"
            fi
            ffmpeg -v error -y -i "$prefix.$codec" -pix_fmt yuv420p -f rawvideo "$prefix.ff.yuv"
            "$WORK/bin/dump$codec" "$prefix.$codec" "$prefix.native.yuv" > "$prefix.dump.log" 2>&1
            cmp "$prefix.ff.yuv" "$prefix.native.yuv"
            [ "$(stat -c %s "$prefix.ff.yuv")" = "$((w*h*3/2*frames))" ]
            for metric in psnr ssim; do
                ffmpeg -v info -f rawvideo -pix_fmt yuv420p -s "${w}x${h}" -i "$src" \
                    -f rawvideo -pix_fmt yuv420p -s "${w}x${h}" -i "$prefix.ff.yuv" \
                    -frames:v "$frames" -lavfi "$metric" -f null - > "$prefix.$metric.log" 2>&1
                sed -n -e 's/.*PSNR /PSNR /p' -e 's/.*SSIM /SSIM /p' "$prefix.$metric.log"
            done
            run "$WORK/bin/dec$codec" "$prefix.$codec" "$frames" | tee "$prefix.native-decode.log"
            run "$WORK/bin/ffmpeg" "$prefix.$codec" "$frames" 1 | tee "$prefix.ffmpeg-decode.log"
        done
    done
done
