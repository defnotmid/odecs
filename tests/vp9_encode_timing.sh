#!/usr/bin/env bash
# Encoding only: no input generation, file I/O, muxing, decoding, init or destroy.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .work/tmp .work/vp9-timing
export TMPDIR="$PWD/.work/tmp"
odin build tests/vp9_encode_check.odin -file -o:speed -vet -strict-style -out:.work/vp9-timing/check
odin version
# Base revision plus a hash of the uncommitted delta identify the measured source.
jj --no-pager log -r '@-' --no-graph -T '"base: " ++ commit_id.short(12) ++ " " ++ description.first_line() ++ "\n"' 2>/dev/null || true
printf 'delta sha256: '; jj --no-pager diff -r @ --git 2>/dev/null | sha256sum
lscpu | grep -E 'Model name|^CPU\(s\)'
cat /proc/loadavg
for workers in 1 4; do
	.work/vp9-timing/check - 1920 1080 100 "$workers" 4 0 animation 5 120 > /dev/null
	for trial in 1 2 3; do
		printf 'trial=%d ' "$trial"
		.work/vp9-timing/check - 1920 1080 100 "$workers" 16 0 animation 5 120
	done
	for trial in 1 2 3; do
		printf 'trial=%d ' "$trial"
		.work/vp9-timing/check - 1920 1080 0 "$workers" 8 1 animation 5 120
	done
done
cat /proc/loadavg
