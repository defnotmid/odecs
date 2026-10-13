#!/usr/bin/env bash
# Chroma-format encode/decode regression gate. Requires Odin, FFmpeg, and HM.
# Override HM_DECODER for an HM TAppDecoder installed outside this checkout.
# Set BASELINE_ENCODER to an immutable encoder binary to require byte identity.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK=${WORK:-.work/chroma-gate}
HM_DECODER=${HM_DECODER:-.work/HM-src/bin/TAppDecoderStatic}
BASELINE_ENCODER=${BASELINE_ENCODER:-}
[ -x "$HM_DECODER" ] || { echo "HM decoder required: set HM_DECODER" >&2; exit 1; }
if [ -n "$BASELINE_ENCODER" ] && { [ ! -f "$BASELINE_ENCODER" ] || [ ! -x "$BASELINE_ENCODER" ]; }; then
    echo "Baseline encoder must be executable: $BASELINE_ENCODER" >&2
    exit 1
fi
if [ -n "$BASELINE_ENCODER" ] && { [ "$BASELINE_ENCODER" -ef "$WORK/encode" ] || [ "$BASELINE_ENCODER" -ef "$WORK/decode" ]; }; then
    echo "Baseline encoder aliases a gate build target: $BASELINE_ENCODER" >&2
    exit 1
fi
mkdir -p "$WORK"
odin build tests/encode_h265.odin -file -o:speed -out:"$WORK/encode"
odin build tests/decode_h265.odin -file -o:speed -out:"$WORK/decode"
passed=0
check() {
    local layout=$1 depth=$2 qp=$3 width=$4 height=$5 mode=$6 frames=${FRAMES:-6}
    shift 6
    local fmt="yuv${layout}p" source="$WORK/input-$layout-$depth-${width}x$height-$frames.yuv"
    local name="$layout-$depth-$qp-${width}x$height-$mode"
    local prefix="$WORK/$name"
    local flags=("--$layout")
    if [ "$layout" = mono ]; then fmt=gray; fi
    if [ "$depth" = 10 ]; then
        if [ "$layout" = mono ]; then fmt=gray10le; else fmt="${fmt}10le"; fi
    fi
    if [ ! -f "$source" ]; then
        ffmpeg -v error -y -f lavfi -i "testsrc2=size=${width}x${height}:rate=5" \
            -frames:v "$frames" -pix_fmt "$fmt" -f rawvideo "$source"
    fi
    "$WORK/encode" "$source" "$width" "$height" "$frames" "$prefix.265" \
        "${flags[@]}" --bitdepth "$depth" --qp "$qp" --sei-hash \
        --rec "$prefix.rec.yuv" "$@" >"$prefix.enc.log" 2>&1
    if [ -n "$BASELINE_ENCODER" ]; then
        "$BASELINE_ENCODER" "$source" "$width" "$height" "$frames" "$prefix.baseline.265" \
            "${flags[@]}" --bitdepth "$depth" --qp "$qp" --sei-hash \
            --rec "$prefix.baseline.rec.yuv" "$@" >"$prefix.baseline.enc.log" 2>&1
        cmp "$prefix.baseline.265" "$prefix.265"
        cmp "$prefix.baseline.rec.yuv" "$prefix.rec.yuv"
    fi
    "$WORK/decode" "$prefix.265" "$prefix.our.yuv" >"$prefix.dec.log" 2>&1
    ffmpeg -v error -y -i "$prefix.265" -pix_fmt "$fmt" -f rawvideo \
        "$prefix.ff.yuv" 2>"$prefix.ff.log"
    "$HM_DECODER" -b "$prefix.265" -o "$prefix.hm.yuv" >"$prefix.hm.log" 2>&1
    cmp "$prefix.rec.yuv" "$prefix.our.yuv"
    cmp "$prefix.rec.yuv" "$prefix.ff.yuv"
    cmp "$prefix.rec.yuv" "$prefix.hm.yuv"
    if grep -qi error "$prefix.hm.log"; then cat "$prefix.hm.log"; exit 1; fi
    local expected_profile=Rext
    [ "$(ffprobe -v error -select_streams v:0 -show_entries stream=profile -of csv=p=0 "$prefix.265")" = "$expected_profile" ]
    echo "PASS $name: rec == ours == FFmpeg == HM; hashes and RExt profile verified"
    passed=$((passed + 1))
}
for depth in 8 10; do
    for qp in 26 42; do
        check 444 "$depth" "$qp" 192 108 plain
        check 444 "$depth" "$qp" 192 108 nofilters --no-deblock --no-sao
        check 444 "$depth" "$qp" 192 108 intra --intra-only
        check 444 "$depth" "$qp" 192 108 amp --amp
        check 444 "$depth" "$qp" 192 108 b --b-frames --amp --wp --tmvp
        check 444 "$depth" "$qp" 192 108 tiles --tiles 2x2 --threads 3
        check 444 "$depth" "$qp" 192 108 scaling --scaling-list default
        check 444 "$depth" "$qp" 192 108 wpp --wpp
        check 444 "$depth" "$qp" 192 108 hierarchical --hierarchical --gop 4 --tmvp
        check 444 "$depth" "$qp" 192 108 refs --refs 3 --wp
        check 422 "$depth" "$qp" 192 108 amp --amp
        check 422 "$depth" "$qp" 192 108 b --b-frames --amp --wp
        check mono "$depth" "$qp" 192 108 weighted --wp
    done
    for layout in 444 422 mono; do
        check "$layout" "$depth" 26 66 50 pcm --pcm
        check "$layout" "$depth" 26 66 50 rqt --rqt --amp
        check "$layout" "$depth" 26 66 50 intra-rqt --intra-rqt --intra-only
        check "$layout" "$depth" 26 66 50 all-trees --rqt --intra-rqt --tskip --rdpcm --amp --b-frames
    done
    check 444 "$depth" 26 66 50 cropped --amp
    check 444 "$depth" 42 8 8 tiny
    check 444 "$depth" 26 192 108 directional --mode 10
    FRAMES=18 check 444 "$depth" 26 192 108 hierarchical-long --hierarchical --gop 8 --tmvp
done
echo "Chroma gate: $passed passed"
