#!/usr/bin/env bash
# AV1 fixtures for tests/av1_check.sh: raw OBU streams (low-overhead
# format) from three encoders, chosen to exercise the header features a
# hardware decode depends on, and the same in MP4 and Matroska.
set -euo pipefail
out=${1:-.work/av1fx}
mkdir -p "$out"
src=(-f lavfi -i "testsrc2=size=352x288:rate=30,format=yuv420p")
src10=(-f lavfi -i "testsrc2=size=352x288:rate=30,format=yuv420p10le")
export SVT_LOG=1
ff=(ffmpeg -hide_banner -loglevel error -y)

# SVT-AV1: hidden ALTREFs shown again with show_existing_frame.
"${ff[@]}" "${src[@]}" -frames:v 40 -c:v libsvtav1 -preset 8 -g 32 -svtav1-params "hierarchical-levels=3" -f obu "$out/svt8.obu"
"${ff[@]}" "${src10[@]}" -frames:v 40 -c:v libsvtav1 -preset 8 -g 32 -f obu "$out/svt10.obu"
# libaom: several tiles and tile groups, error resilience, frame ids,
# with SVT-AV1 superres at 10 bits.
"${ff[@]}" "${src[@]}" -frames:v 30 -c:v libaom-av1 -cpu-used 8 -g 16 -tile-columns 1 -tile-rows 1 -f obu "$out/aom_tiles.obu"
"${ff[@]}" "${src[@]}" -frames:v 30 -c:v libaom-av1 -cpu-used 8 -g 16 -error-resilient 1 -aom-params "frame-parallel=1" -f obu "$out/aom_resilient.obu"
"${ff[@]}" "${src10[@]}" -frames:v 30 -c:v libsvtav1 -preset 8 -g 10 -svtav1-params "superres-mode=1:superres-denom=12" -f obu "$out/svt_superres10.obu"
# Film grain, segmentation, frame headers in their own OBUs with several
# tile groups.
"${ff[@]}" "${src[@]}" -frames:v 30 -c:v libsvtav1 -preset 8 -svtav1-params "film-grain=10" -f obu "$out/svt_grain.obu"
"${ff[@]}" "${src[@]}" -frames:v 30 -c:v libaom-av1 -cpu-used 8 -aq-mode 1 -f obu "$out/aom_segments.obu"
"${ff[@]}" "${src[@]}" -frames:v 30 -c:v libaom-av1 -cpu-used 8 -tiles 4x2 -aom-params "num-tile-groups=3" -f obu "$out/aom_tilegroups.obu"
"${ff[@]}" "${src[@]}" -frames:v 30 "$out/src.y4m"
# Key frames at one size and inter frames at another: references scaled
# down (352x288 to 235x192, an odd width) and up (235x192 to 176x144).
aom_resize() { # name, inter denominator, key frame denominator
	aomenc --quiet --cpu-used=8 --resize-mode=1 --resize-denominator="$2" --resize-kf-denominator="$3" --kf-max-dist=10 --limit=30 --ivf -o "$out/$1.ivf" "$out/src.y4m"
	"${ff[@]}" -i "$out/$1.ivf" -c copy -f obu "$out/$1.obu"
	rm "$out/$1.ivf"
}
aom_resize aom_scaled_down 12 8
aom_resize aom_scaled_up 16 12
# 235x192 to 201x165: an odd height from a scaled reference faults RADV, so
# the decoder must refuse it (av1_check.sh expects Unsupported).
aom_resize unsupported_odd_scaled 14 12
mv "$out/unsupported_odd_scaled.obu" "$out/unsupported_odd_scaled.obu.refuse"
rm "$out/src.y4m"
# rav1e: its own reference structure and switchable restoration.
"${ff[@]}" "${src[@]}" -frames:v 30 -c:v librav1e -speed 10 -g 15 -f obu "$out/rav1e.obu"
# Containers.
"${ff[@]}" -i "$out/svt8.obu" -c copy "$out/svt8.mp4"
"${ff[@]}" -i "$out/svt8.obu" -c copy "$out/svt8.mkv"
"${ff[@]}" -i "$out/aom_tiles.obu" -c copy "$out/aom_tiles.mp4"
"${ff[@]}" -i "$out/svt10.obu" -c copy "$out/svt10.mkv"
"${ff[@]}" -i "$out/svt_grain.obu" -c copy "$out/svt_grain.mp4"
echo "fixtures in $out"
