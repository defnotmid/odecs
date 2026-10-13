#!/bin/bash
# Decode every test vector in third_party/openh264/res and compare with ffmpeg's
# output (display order). References are cached in $BUILD/vectors.
# usage: tests/vectors.sh [name-regex]
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD=${BUILD:-build}
mkdir -p $BUILD/vectors
odin build tests/yuv_dump.odin -file -o:speed -out:$BUILD/yuv_dump || exit 1
odin build tests/yuv_compare.odin -file -o:speed -out:$BUILD/yuv_compare || exit 1
exact=0; total=0; failures=0
shopt -s nullglob
for f in third_party/openh264/res/*.264 third_party/openh264/res/*.jsv third_party/openh264/res/*.h264; do
	b=$(basename "$f"); b=${b%.*}
	[ $# -ge 1 ] && ! [[ "$b" =~ $1 ]] && continue
	ref=$BUILD/vectors/$b.ref.yuv
	if [ ! -f "$ref" ]; then
		ffmpeg -v error -i "$f" -f rawvideo -pix_fmt yuv420p -y "$ref" 2>/dev/null || { echo "$b: ffmpeg cannot decode, skipped"; continue; }
	fi
	total=$((total + 1))
	if ! timeout 300 $BUILD/yuv_dump "$f" $BUILD/vectors/$b.ours.yuv >/dev/null 2>$BUILD/vectors/$b.err; then
		printf "%-44s CRASH %s\n" "$b" "$(head -c 160 $BUILD/vectors/$b.err | tr '\n' ' ')"
		failures=$((failures + 1)); continue
	fi
	$BUILD/yuv_compare "$ref" $BUILD/vectors/$b.ours.yuv "$b" && exact=$((exact + 1)) || failures=$((failures + 1))
	rm -f $BUILD/vectors/$b.ours.yuv
done
echo "exact $exact of $total"
[ "$total" -gt 0 ] && [ "$failures" -eq 0 ]
