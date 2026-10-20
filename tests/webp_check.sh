#!/usr/bin/env bash
# WebP gate: every file of libwebp's test corpus decoded by webp and
# compared with dwebp: RGBA identical (-pam), and for lossy files the
# planes too (-pgm: Y, U, V, alpha); the largest decoded again on a
# Work_Pool; the animations' every canvas identical to anim_dump's; and a
# fuzz pass under AddressSanitizer with leak checking.
# Fixtures: tests/webp_fixtures.sh.
#   bash tests/webp_check.sh [fixture-dir]
set -uo pipefail
fx=${1:-.work/webpfx}
work=.work/webpgate
mkdir -p "$work"
export TMPDIR=${TMPDIR:-$PWD/.work/tmp}
odin build tests/webp_decode.odin -file -out:"$work/webp_decode" -o:speed -vet -strict-style || exit 1
odin build tests/webp_anim.odin -file -out:"$work/webp_anim" -o:speed -vet -strict-style || exit 1
odin build tests/webp_fuzz.odin -file -sanitize:address -debug -out:"$work/webp_fuzz" || exit 1
pass=0 fail=0
result() { # ok? message
	if [ "$1" = 0 ]; then pass=$((pass + 1)); else echo "FAIL $2"; fail=$((fail + 1)); fi
}
lossy=0 lossless=0
for f in "$fx"/testdata/*.webp; do
	n=$(basename "$f" .webp)
	log=$("$work/webp_decode" "$f" "$fx/ref/$n.pam" "$fx/ref/$n.pgm" 2>&1)
	if [[ "$log" == *lossless* ]]; then
		lossless=$((lossless + 1))
		[[ "$log" == *"RGBA identical to dwebp" ]]
	else
		lossy=$((lossy + 1))
		[[ "$log" == *"RGBA identical to dwebp; YUVA identical to dwebp" ]]
	fi
	result $? "$n: $log"
done
echo "ok   corpus: $lossy lossy and $lossless lossless files, $pass identical to dwebp"
log=$("$work/webp_decode" "$fx/testdata/bryce.webp" "$fx/ref/bryce.pam" - 1 8 2>&1)
[[ "$log" == *"RGBA identical to dwebp" ]]
result $? "bryce on 8 threads: $log"
[ $? = 0 ] && echo "ok   bryce on 8 threads: $log"
for n in lossless lossy mixed opaque blend; do
	log=$("$work/webp_anim" "$fx/anim/$n.webp" "$fx/anim/ref_$n" 2>&1)
	[[ "$log" == *"all identical"* ]]
	ok=$?
	result $ok "animation $n: $log"
	[ $ok = 0 ] && echo "ok   animation $n: $log"
done
inputs=("$fx"/testdata/{test,lossless1,lossy_alpha1,alpha_filter_3_method_1,lossless_color_transform,vp80-03-segmentation-1437,color_cache_bits_11,dual_transform}.webp "$fx"/anim/{blend,mixed,lossy}.webp)
log=$(ASAN_OPTIONS=detect_leaks=1 "$work/webp_fuzz" 3000 "${inputs[@]}" 2>&1)
[[ "$log" == *"no faults"* && "$log" != *"LeakSanitizer"* ]]
ok=$?
result $ok "fuzz: $(echo "$log" | tail -3)"
[ $ok = 0 ] && echo "ok   fuzz: $log"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
