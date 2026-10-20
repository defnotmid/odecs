#!/usr/bin/env bash
# AV1 gate, on every fixture from tests/av1_fixtures.sh: the frame header
# parser against FFmpeg's trace_headers (every element both print must agree,
# frame by frame), then Vulkan Video decoding against libdav1d, bit-exact, of
# the raw streams and of MP4/Matroska files through video.Reader.
set -euo pipefail
fx=${1:-.work/av1fx}
work=.work/av1gate
mkdir -p "$work"
export TMPDIR=${TMPDIR:-$PWD/.work/tmp}
odin build tests/av1_headers.odin -file -out:"$work/av1_headers" -o:speed -vet -strict-style
odin build tests/av1_decode.odin -file -out:"$work/av1_decode" -o:speed
odin build tests/movie_av1.odin -file -out:"$work/movie_av1" -o:speed
pass=0 fail=0
for f in "$fx"/*.obu; do
	name=$(basename "$f" .obu)
	# Frame headers of OBU_FRAME_HEADER and OBU_FRAME only (redundant copies are skipped by both).
	ffmpeg -hide_banner -i "$f" -c copy -bsf:v trace_headers -f null - 2>&1 |
		awk '$4=="Frame" && $5=="Header" {print "frame"; on=1; next}
			$4=="Tile" || $4=="OBU" || $4=="Redundant" {on=0}
			on && NF>=8 && $(NF-1)=="=" {print $5, $NF}' >"$work/$name.trace"
	if ! "$work/av1_headers" "$f" >"$work/$name.ours" 2>"$work/$name.log"; then
		echo "FAIL $name: $(cat "$work/$name.log")"
		fail=$((fail + 1))
		continue
	fi
	# For each frame, every traced element must have our value.
	if awk 'FNR==NR {if ($1=="frame") n++; else ours[n, $1]=$2; next}
		$1=="frame" {m++; next}
		($1 != "zero_bit") && ((m, $1) in ours) && ours[m, $1] != $2 {
			printf "  frame %d %s: trace %s ours %s\n", m-1, $1, $2, ours[m, $1]; bad++
		}
		END {if (n != m) {printf "  %d frames ours, %d trace\n", n, m; bad++}; exit bad > 0}' \
		"$work/$name.ours" "$work/$name.trace" >"$work/$name.diff"; then
		echo "ok   $name ($(grep -cx frame "$work/$name.ours") headers, $(cat "$work/$name.log"))"
		pass=$((pass + 1))
	else
		echo "FAIL $name"
		head -20 "$work/$name.diff"
		fail=$((fail + 1))
	fi
done
for f in "$fx"/*.obu; do
	name=$(basename "$f" .obu)
	fmt=$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of csv=p=0 "$f")
	ffmpeg -hide_banner -loglevel error -y -c:v libdav1d -i "$f" -noautoscale -f rawvideo -pix_fmt "$fmt" "$work/$name.ref.yuv"
	if ! "$work/av1_decode" "$f" "$work/$name.yuv" 2>"$work/$name.decode.log"; then
		echo "FAIL $name decode: $(grep -v radv "$work/$name.decode.log")"
		fail=$((fail + 1))
	elif cmp -s "$work/$name.yuv" "$work/$name.ref.yuv"; then
		echo "ok   $name decode ($fmt, $(grep -v radv "$work/$name.decode.log"))"
		pass=$((pass + 1))
	else
		echo "FAIL $name decode differs ($fmt): $(cmp "$work/$name.yuv" "$work/$name.ref.yuv" 2>&1 | head -1)"
		fail=$((fail + 1))
	fi
done
# MP4 (av01) and Matroska (V_AV1) through video.Reader's planar output.
for f in "$fx"/*.mp4 "$fx"/*.mkv; do
	name=$(basename "$f")
	fmt=$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of csv=p=0 "$f")
	ffmpeg -hide_banner -loglevel error -y -c:v libdav1d -i "$f" -f rawvideo -pix_fmt "$fmt" "$work/$name.ref.yuv"
	if ! "$work/movie_av1" "$f" "$work/$name.yuv" >"$work/$name.log" 2>&1; then
		echo "FAIL $name movie: $(grep -v radv "$work/$name.log")"
		fail=$((fail + 1))
	elif cmp -s "$work/$name.yuv" "$work/$name.ref.yuv"; then
		echo "ok   $name movie ($(grep -v radv "$work/$name.log"))"
		pass=$((pass + 1))
	else
		echo "FAIL $name movie differs"
		fail=$((fail + 1))
	fi
done
for f in "$fx"/*.obu.refuse; do
	name=$(basename "$f" .obu.refuse)
	if ! "$work/av1_decode" "$f" "$work/$name.yuv" 2>"$work/$name.decode.log" && grep -q Unsupported "$work/$name.decode.log"; then
		echo "ok   $name refused"
		pass=$((pass + 1))
	else
		echo "FAIL $name was not refused"
		fail=$((fail + 1))
	fi
done
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
