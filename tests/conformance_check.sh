#!/usr/bin/env bash
# H.264 and HEVC conformance gate (with FFmpeg). Decodes the OpenH264
# reference streams (bash tools/fetch_third_party.sh openh264) and the JCT-VC
# HEVC conformance streams (bash tests/hevc_conformance.sh) through
# codec/media: MODE=hardware (the default; VideoToolbox on macOS, Vulkan Video
# elsewhere) or MODE=native. Output must match the conformance MD5s where a
# stream has them, and FFmpeg's software decode otherwise. A stream the
# hardware or our admission refuses is listed as refused (codec/media then
# falls back to the native decoder); any difference fails.
# usage: [MODE=native] tests/conformance_check.sh [name-regex]
set -euo pipefail
cd "$(dirname "$0")/.."
W=${WORK:-.work/conformance-check}
MODE=${MODE:-hardware}
HEVC=${HEVC:-.work/hevc-conformance}
mkdir -p "$W"
odin build tests/decode_media.odin -file -o:speed -out:"$W/decode"
exact=0 refused=0 damaged=0 limits=0 failed=0

# Streams with pictures lost on purpose. How a decoder conceals the loss is not
# specified, so they must only decode, or fail, cleanly (VideoToolbox, and
# FFmpeg's VideoToolbox path, reject pictures that reference lost ones).
is_damaged() {
	case "$1" in BA_MW_D_IDR_LOST | BA_MW_D_P_LOST | Error_I_P) return 0 ;; esac
	return 1
}
# VideoToolbox's own limit: this picture has 8160 slices (255 decode fine).
is_vt_limit() { [ "$1" = jm_1080p_allslice ]; }

checksum() { if command -v md5 >/dev/null; then md5 -q "$1"; else md5sum "$1" | cut -d" " -f1; fi; }

shopt -s nullglob
check() {
	local codec=$1 f=$2 b format want log size
	b=$(basename "$f"); b=${b%.*}
	if [ -n "$FILTER" ] && ! [[ "$b" =~ $FILTER ]]; then return; fi
	format=$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of csv=p=0 "$f" 2>/dev/null || true)
	# Vulkan Video admits a stream only with its size given, as containers give it.
	size=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$f" 2>/dev/null || true)
	local depth=depth=8
	case "$format" in
	yuv420p | yuvj420p | gray) format=yuv420p ;;
	yuv420p10le) depth=depth=10 ;;
	*) printf "%-40s refused (FFmpeg reads %s)\n" "$b" "${format:-nothing}"; refused=$((refused + 1)); return ;;
	esac
	want=$(cat /dev/null "$HEVC/md5/$b"* 2>/dev/null | grep -oE '[0-9a-fA-F]{32}' | tr 'A-F' 'a-f' || true)
	if [ -z "$want" ]; then
		ffmpeg -v error -y -i "$f" -f rawvideo -pix_fmt "$format" "$W/$b.ref.yuv" 2>/dev/null || { printf "%-40s skipped: FFmpeg cannot decode\n" "$b"; return; }
		want=$(checksum "$W/$b.ref.yuv")
		rm -f "$W/$b.ref.yuv"
	fi
	local status=0
	log=$("$W/decode" "$codec" "$f" "$W/$b.out.yuv" "$MODE" $size $depth 2>&1) || status=$?
	if is_damaged "$b" && [ "$status" -le 1 ]; then
		printf "%-40s damaged on purpose, %s cleanly\n" "$b" "$( [ "$status" -eq 0 ] && echo decoded || echo refused)"
		damaged=$((damaged + 1))
	elif [ "$status" -ne 0 ]; then
		if is_vt_limit "$b" && [[ "$log" == *VideoToolbox* ]]; then
			printf "%-40s VideoToolbox limit: 8160 slices in one picture\n" "$b"
			limits=$((limits + 1))
		elif [[ "$log" == *Unsupported* || "$log" == *Unavailable* ]]; then
			printf "%-40s refused: %s\n" "$b" "$(tail -1 <<<"$log")"
			refused=$((refused + 1))
		else
			printf "%-40s FAILED: %s\n" "$b" "$(tail -1 <<<"$log")"
			failed=$((failed + 1))
		fi
	elif grep -qx "$(checksum "$W/$b.out.yuv")" <<<"$want"; then
		printf "%-40s exact  %s\n" "$b" "$(tail -1 <<<"$log")"
		exact=$((exact + 1))
	else
		printf "%-40s MISMATCH (%s bytes)\n" "$b" "$(wc -c <"$W/$b.out.yuv" | tr -d ' ')"
		failed=$((failed + 1))
	fi
	rm -f "$W/$b.out.yuv"
}
FILTER=${1:-}
for f in third_party/openh264/res/*.264 third_party/openh264/res/*.jsv third_party/openh264/res/*.h264; do check h264 "$f"; done
for f in "$HEVC"/*.bit "$HEVC"/*.bin; do check h265 "$f"; done
echo "$MODE: $exact exact, $refused refused, $damaged damaged streams handled cleanly, $limits VideoToolbox limits, $failed failed"
[ "$failed" -eq 0 ]
