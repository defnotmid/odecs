#!/bin/bash
# Encode a short clip with x264 under many feature combinations and check that
# the decoder matches ffmpeg bit-exactly. Needs x264 and ffmpeg.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD=${BUILD:-build}
mkdir -p $BUILD/x264
odin build tests/yuv_dump.odin -file -o:speed -out:$BUILD/yuv_dump || exit 1
odin build tests/yuv_compare.odin -file -o:speed -out:$BUILD/yuv_compare || exit 1
SRC=$BUILD/x264/src.yuv
[ -f $SRC ] || ffmpeg -v error -i third_party/openh264/res/Zhling_1280x720.264 -frames:v 8 -f rawvideo -pix_fmt yuv420p -y $SRC
# High 10 and 4:2:2 runs (PIX, the stream's format as FFmpeg names it) encode
# a copy of the clip in that format, with noise in the low bits, and compare
# in it. x264 converts no formats itself.
high_source() {
	file=$BUILD/x264/src-$1.yuv
	[ -f $file ] || ffmpeg -v error -i third_party/openh264/res/Zhling_1280x720.264 -frames:v 8 -vf noise=alls=4:allf=t -f rawvideo -pix_fmt $1 -y $file
	csp=i420; extra=""
	case $1 in
		gray*)    csp=i400; extra="--input-range pc --range pc" ;;
		yuv422*)  csp=i422 ;;
		yuv444*)  csp=i444 ;;
	esac
	depth=8; case $1 in *10le) depth=10 ;; esac
	echo "--input-csp $csp --input-depth $depth $extra $file"
}
run() {
	name=$1; shift
	expected=${EXPECTED_REFUSAL:-0}
	source=$SRC
	[ -n "${PIX:-}" ] && source=$(high_source $PIX)
	x264 --input-res 1280x720 --fps 30 --frames 8 --quiet "$@" -o $BUILD/x264/$name.264 $source 2>/dev/null || { echo "$name: x264 failed"; return 1; }
	ffmpeg -v error -i $BUILD/x264/$name.264 -f rawvideo -pix_fmt ${PIX:-yuv420p} -y $BUILD/x264/$name.ref.yuv
	status=0
	timeout 120 $BUILD/yuv_dump $BUILD/x264/$name.264 $BUILD/x264/$name.ours.yuv >$BUILD/x264/$name.log 2>&1 || status=$?
	if [ "$expected" = 1 ]; then
		[ "$status" = 3 ] || { echo "$name: expected unsupported refusal, got $status"; return 1; }
		echo "$name: expected unsupported refusal"; return 0
	fi
	[ "$status" = 0 ] || { cat $BUILD/x264/$name.log; return 1; }
	$BUILD/yuv_compare $BUILD/x264/$name.ref.yuv $BUILD/x264/$name.ours.yuv $name
}
run cavlc_intra_8x8      --profile high --no-cabac --intra --8x8dct --qp 20
run cabac_intra_8x8_qp3  --profile high --intra --8x8dct --qp 3
run cabac_intra_8x8_qp45 --profile high --intra --8x8dct --qp 45
run aq_i8x8              --profile high --intra --8x8dct --crf 18 --aq-mode 3 --aq-strength 3
run aq_ipb               --profile high --crf 18 --aq-mode 3 --aq-strength 3 --bframes 3 --ref 4 --8x8dct
run main_pyramid         --profile main --crf 20 --bframes 4 --b-pyramid normal --ref 5 --weightp 2 --weightb --direct auto --trellis 2
run cavlc_ipb_weightb    --profile high --no-cabac --qp 22 --bframes 2 --b-adapt 0 --ref 3 --weightb --weightp 2 --direct temporal
run high_slices          --profile high --crf 20 --bframes 2 --slices 4 --8x8dct
run high_slicembs        --profile high --crf 20 --bframes 2 --slice-max-mbs 37 --8x8dct --deblock 3:-2
run cavlc_slices         --profile high --no-cabac --crf 20 --bframes 2 --slices 3 --8x8dct --constrained-intra
run cip_cabac            --profile high --crf 20 --bframes 2 --constrained-intra --8x8dct
run nodeblock            --profile high --crf 20 --bframes 2 --no-deblock
run idr4                 --profile high --crf 20 --bframes 2 --keyint 4 --min-keyint 2 --8x8dct
run opengop              --profile high --crf 20 --bframes 3 --open-gop --keyint 6 --min-keyint 3
run hrd                  --profile high --crf 20 --bframes 2 --nal-hrd cbr --bitrate 4000 --vbv-maxrate 4000 --vbv-bufsize 4000 --crf-max 40
run baseline             --profile baseline --crf 22
run intra_refresh        --profile high --crf 22 --intra-refresh --keyint 8
run psy_8x8              --profile high --crf 15 --8x8dct --psy-rd 2:1 --trellis 2 --bframes 3 --ref 6
echo "High 10 (4:2:0), 4:0:0, 4:2:2, 4:4:4 (8-bit and 10-bit), and lossless:"
PIX=yuv420p10le run hi10_intra_cavlc  --profile high10 --output-depth 10 --no-cabac --intra --8x8dct --qp 20
PIX=yuv420p10le run hi10_ipb          --profile high10 --output-depth 10 --crf 18 --bframes 3 --ref 4 --8x8dct --weightp 2 --weightb --direct auto
PIX=yuv420p10le run hi10_qp1          --profile high10 --output-depth 10 --qp 1 --bframes 2 --8x8dct
PIX=gray        run i400_cabac        --profile high --output-csp i400 --output-depth 8 --crf 20 --bframes 2 --8x8dct --weightb
PIX=gray        run i400_cavlc        --profile high --output-csp i400 --output-depth 8 --no-cabac --crf 20 --bframes 2 --8x8dct
PIX=gray10le    run hi400_cabac       --profile high10 --output-csp i400 --output-depth 10 --crf 18 --bframes 2 --8x8dct
PIX=yuv422p     run i422_cabac        --profile high422 --output-csp i422 --output-depth 8 --crf 20 --bframes 3 --8x8dct --weightb
PIX=yuv422p     run i422_cavlc        --profile high422 --output-csp i422 --output-depth 8 --no-cabac --crf 20 --bframes 2 --weightp 2
PIX=yuv422p10le run hi422_ipb         --profile high422 --output-csp i422 --output-depth 10 --crf 18 --bframes 3 --ref 4 --8x8dct --weightp 2 --weightb --direct auto
PIX=yuv422p10le run hi422_cavlc       --profile high422 --output-csp i422 --output-depth 10 --no-cabac --crf 20 --bframes 2 --slices 3 --constrained-intra --8x8dct
PIX=yuv422p10le run hi422_intra_qp1   --profile high422 --output-csp i422 --output-depth 10 --intra --qp 1 --8x8dct
PIX=yuv422p10le run hi422_offsets     --profile high422 --output-csp i422 --output-depth 10 --crf 22 --bframes 2 --deblock 3:-2 --chroma-qp-offset 5 --cqm jvt
PIX=yuv422p10le run hi422_temporal    --profile high422 --output-csp i422 --output-depth 10 --no-cabac --qp 30 --bframes 3 --b-pyramid normal --direct temporal --no-8x8dct
PIX=yuv444p     run i444_cabac        --profile high444 --output-csp i444 --output-depth 8 --crf 20 --bframes 3 --8x8dct --weightp 2 --weightb
PIX=yuv444p     run i444_cavlc        --profile high444 --output-csp i444 --output-depth 8 --no-cabac --crf 20 --bframes 2 --8x8dct --weightp 2
PIX=yuv444p10le run hi444_ipb         --profile high444 --output-csp i444 --output-depth 10 --crf 18 --bframes 3 --ref 4 --8x8dct --weightp 2 --weightb --direct auto
PIX=yuv444p10le run hi444_cavlc       --profile high444 --output-csp i444 --output-depth 10 --no-cabac --crf 20 --bframes 2 --slices 3 --constrained-intra --8x8dct
run lossless                          --profile high444 --qp 0 --output-csp i420 --bframes 2 --8x8dct
PIX=yuv444p     run i444_lossless     --profile high444 --qp 0 --output-csp i444 --bframes 2 --8x8dct
echo "interlaced streams are expected to be refused (NOOUT):"
EXPECTED_REFUSAL=1 run interlaced     --profile high --crf 22 --interlaced --bframes 2
