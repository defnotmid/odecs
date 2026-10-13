#!/usr/bin/env bash
# Seven fresh decoder contexts; independent streams use fixed CPU slots.
# Generate reference inputs first with tests/reference_benchmark.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK=${WORK:-.work/video-decode-benchmark}
INPUTS=${INPUTS:-.work/reference-benchmark}
CASE=${CASE:-all}
SLOTS=${SLOTS:-23,0,6,1,7,2,8,3,9,4,10,5,12,18,13,19}
case "$CASE" in all|720|1080) ;; *) exit 2 ;; esac
mkdir -p "$WORK/bin"
odin build tests/video_decode_timing.odin -file -o:speed -microarch:native -out:"$WORK/bin/native"
c++ -std=c++17 -O3 -Wall -Wextra -Werror tests/reference_video_decode.cpp \
    -lavformat -lavcodec -lavutil -pthread -o "$WORK/bin/reference"
IFS=, read -r -a slots <<< "$SLOTS"
[ "${#slots[@]}" -ge 16 ]
for spec in '720 1280 720 19' '1080 1920 1080 54'; do
    read -r name width height frames <<< "$spec"
    if [ "$CASE" != all ] && [ "$CASE" != "$name" ]; then continue; fi
    for codec in 264 265; do
        source="$INPUTS/$name/x$codec.$codec"
        [ -f "$source" ]
        for streams in 1 12 16; do
            cpus=$(IFS=,; echo "${slots[*]:0:streams}")
            dir="$WORK/$name-h$codec-$streams"
            mkdir -p "$dir"
            sha256sum "$source" > "$dir/input.sha256"
            for run in 1-native 2-reference 3-reference 4-native; do
                provider=${run#*-}
                if [ "$provider" = native ]; then
                    VIDEO_CPUS="$cpus" "$WORK/bin/native" "$source" "h$codec" \
                        "$width" "$height" "$frames" "$streams" > "$dir/$run.log"
                else
                    VIDEO_CPUS="$cpus" "$WORK/bin/reference" "$source" \
                        "$frames" "$streams" > "$dir/$run.log"
                fi
            done
            expected=$(sed -n 's/.*verification_hash=\([^ ]*\).*/\1/p' "$dir/1-native.log")
            [ -n "$expected" ]
            for log in "$dir"/*.log; do
                [ "$(sed -n 's/.*verification_hash=\([^ ]*\).*/\1/p' "$log")" = "$expected" ]
            done
            cat "$dir"/*.log
        done
    done
done
