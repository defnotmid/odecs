#!/usr/bin/env bash
# Real-device gate: native reconstruction == native decode == FFmpeg == Vulkan.
# Usage: gpu_h265_native_gate.sh <640x360 8-bit.yuv> <640x360 10-bit.yuv> <work-dir>
# Each source must contain at least 10 frames. Set HM_DECODER for the optional
# independent HEVC reference decoder. Driver and device availability are required.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# != 3 ]]; then
  echo "usage: $0 <640x360 8-bit.yuv> <640x360 10-bit.yuv> <work-dir>" >&2
  exit 2
fi
source8="$(realpath "$1")"
source10="$(realpath "$2")"
if (( $(stat -c%s "$source8") < 640 * 360 * 3 / 2 * 10 || $(stat -c%s "$source10") < 640 * 360 * 3 * 10 )); then
  echo "both inputs must contain at least ten 640x360 planar frames" >&2
  exit 2
fi
mkdir -p "$3"
work="$(realpath "$3")"
cd "$root"
odin build tests/encode_h265.odin -file -o:speed -out:"$work/encode-h265"
odin build tests/decode_h265.odin -file -o:speed -out:"$work/decode-h265"
odin build tests/gpu_h265_decode.odin -file -o:speed -out:"$work/gpu-h265"
passed=0
refused=0
failed=0
case_() {
  local name="$1" depth="$2"; shift 2
  local unsupported=false
  if [[ "${1:-}" == --gpu-unsupported ]]; then unsupported=true; shift; fi
  local source="$source8" format=yuv420p
  if [[ "$depth" == 10 ]]; then source="$source10"; format=yuv420p10le; fi
  local prefix="$work/$name"
  if ! "$work/encode-h265" "$source" 640 360 10 "$prefix.265" --bitdepth "$depth" --qp 26 --rec "$prefix.rec.yuv" "$@" >"$prefix.enc.log" 2>&1 ||
     ! ffmpeg -v error -y -i "$prefix.265" -f rawvideo -pix_fmt "$format" "$prefix.ff.yuv" 2>"$prefix.ff.log" ||
     ! "$work/decode-h265" "$prefix.265" "$prefix.native.yuv" >"$prefix.native.log" 2>&1 ||
     ! cmp -s "$prefix.rec.yuv" "$prefix.ff.yuv" ||
     ! cmp -s "$prefix.native.yuv" "$prefix.ff.yuv"; then
    echo "FAIL $name (see $prefix.*.log and raw comparisons)"
    failed=$((failed+1)); return
  fi
  if [[ -n "${HM_DECODER:-}" ]]; then
    if ! "$HM_DECODER" -b "$prefix.265" -o "$prefix.hm.yuv" >"$prefix.hm.log" 2>&1 ||
       ! cmp -s "$prefix.hm.yuv" "$prefix.ff.yuv"; then
      echo "FAIL $name (HM reference)"
      failed=$((failed+1)); return
    fi
  fi
  if "$work/gpu-h265" "$prefix.265" "$prefix.gpu.yuv" >"$prefix.gpu.log" 2>&1; then
    if "$unsupported" || ! cmp -s "$prefix.gpu.yuv" "$prefix.ff.yuv"; then
      echo "FAIL $name (Vulkan output or expected refusal)"
      failed=$((failed+1)); return
    fi
  elif ! "$unsupported" || ! rg -q 'failed: Unsupported|flush: Unsupported' "$prefix.gpu.log"; then
    echo "FAIL $name (Vulkan decode)"
    failed=$((failed+1)); return
  fi
  if "$unsupported"; then
    echo "PASS $name (native exact; Vulkan Unsupported)"
    refused=$((refused+1)); return
  fi
  echo "PASS $name"
  passed=$((passed+1))
}
for depth in 8 10; do
  case_ "d${depth}-default" "$depth"
  case_ "d${depth}-refs4" "$depth" --refs 4
  case_ "d${depth}-weighted" "$depth" --wp
  case_ "d${depth}-tmvp" "$depth" --tmvp
  case_ "d${depth}-wpp" "$depth" --wpp
  case_ "d${depth}-bframes" "$depth" --b-frames
  case_ "d${depth}-hierarchical" "$depth" --hierarchical
  case_ "d${depth}-scaling-default" "$depth" --scaling-list default
  case_ "d${depth}-scaling-flat" "$depth" --scaling-list flat
  case_ "d${depth}-intra" "$depth" --intra-only
  case_ "d${depth}-tools" "$depth" --b-frames --wp --tmvp --wpp --intra-rqt --tskip --amp --scaling-list default
  # RDPCM requires a format-range-extension profile. The native codec owns it;
  # this GPU frontend admits Main/Main10 and must refuse it before submission.
  case_ "d${depth}-rdpcm-tools" "$depth" --gpu-unsupported --b-frames --wp --tmvp --wpp --intra-rqt --tskip --rdpcm --amp --scaling-list default
done
echo "$passed exact hardware cases, $refused typed refusal cases, $failed failed"
[[ "$failed" == 0 ]]
