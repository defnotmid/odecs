#!/bin/bash
# Encode the 720p reference clip with several settings, check that ffmpeg and our
# decoder agree bit-exactly on the result, and report size and PSNR against the
# source alongside x264 (baseline, comparable tools) at the same QP.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD=${BUILD:-build}
mkdir -p $BUILD/enc
odin build tests/encode_clip.odin -file -o:speed -out:$BUILD/encode_clip || exit 1
odin build tests/yuv_dump.odin -file -o:speed -out:$BUILD/yuv_dump || exit 1
odin build tests/yuv_compare.odin -file -o:speed -out:$BUILD/yuv_compare || exit 1
SRC=$BUILD/enc/src.yuv
[ -f $SRC ] || ffmpeg -v error -i third_party/openh264/res/Zhling_1280x720.264 -frames:v 19 -f rawvideo -pix_fmt yuv420p -y $SRC
# Average PSNR of a decoded raw file against the source, both read as raw so no container timing is involved
psnr() {
	ffmpeg -v info -f rawvideo -pix_fmt yuv420p -s 1280x720 -i $SRC -f rawvideo -pix_fmt yuv420p -s 1280x720 -i $1 -lavfi psnr -f null - 2>&1 | grep -o "average:[0-9.]*" | cut -d: -f2
}
run() {
	name=$1; shift
	$BUILD/encode_clip $SRC 1280 720 19 $BUILD/enc/$name.264 "$@" > $BUILD/enc/$name.log || { echo "$name: encoder failed"; return 1; }
	ffmpeg -v error -i $BUILD/enc/$name.264 -f rawvideo -pix_fmt yuv420p -y $BUILD/enc/$name.ff.yuv || { echo "$name: ffmpeg rejects the stream"; return 1; }
	$BUILD/yuv_dump $BUILD/enc/$name.264 $BUILD/enc/$name.ours.yuv >/dev/null 2>&1
	agree=$($BUILD/yuv_compare $BUILD/enc/$name.ff.yuv $BUILD/enc/$name.ours.yuv | awk '{print $2}')
	printf "%-28s %8d bytes  PSNR %s dB  ffmpeg/ours %s  %s\n" "$name" $(stat -c %s $BUILD/enc/$name.264) "$(psnr $BUILD/enc/$name.ff.yuv)" "$agree" "$(tail -1 $BUILD/enc/$name.log)"
}
x264ref() {
	name=$1; shift
	x264 --threads 1 --slices 4 --ipratio 1 --pbratio 1 --input-res 1280x720 --fps 30 --frames 19 --quiet --profile baseline --preset medium --no-scenecut "$@" -o $BUILD/enc/$name.264 $SRC 2>/dev/null
	ffmpeg -v error -i $BUILD/enc/$name.264 -f rawvideo -pix_fmt yuv420p -y $BUILD/enc/$name.ff.yuv
	printf "%-28s %8d bytes  PSNR %s dB  (x264)\n" "$name" $(stat -c %s $BUILD/enc/$name.264) "$(psnr $BUILD/enc/$name.ff.yuv)"
}
run qp22_ref1           --qp 22
run qp26_ref1           --qp 26
run qp26_ref3           --qp 26 --refs 3
run qp30_ref1           --qp 30
run qp26_nodeblock      --qp 26 --no-deblock
run qp26_threads        --qp 26 --threads
run qp26_cabac          --qp 26 --cabac
run qp26_cabac_8x8      --qp 26 --cabac --8x8
run qp26_cabac_8x8_mt   --qp 26 --cabac --8x8 --threads
run bitrate_2000        --bitrate 2000
# Bitrate accuracy on the longer 151-frame clip
LONG=$BUILD/enc/long.yuv
[ -f $LONG ] || ffmpeg -v error -i third_party/openh264/res/VID_1280x544_cavlc_temporal_direct.264 -f rawvideo -pix_fmt yuv420p -y $LONG
for kbps in 500 1500 4000; do
	$BUILD/encode_clip $LONG 1280 544 151 $BUILD/enc/long_$kbps.264 --bitrate $kbps --gop 30 --threads | tail -1 | awk -v kbps=$kbps '{printf "bitrate target %5d kbps: achieved %5.0f kbps over 151 frames\n", kbps, $3 * 8 / (151 / 30) / 1000}'
done
x264ref x264_qp22       --qp 22 --ref 1 --keyint 15
x264ref x264_qp26       --qp 26 --ref 1 --keyint 15
x264ref x264_qp30       --qp 30 --ref 1 --keyint 15
