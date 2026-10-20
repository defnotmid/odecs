#!/usr/bin/env bash
# Opus gate:
# - the RFC 8251 conformance vectors through opus, checked by libopus's
#   opus_compare (stereo and mono output) and by every packet's final range
#   against the encoder's;
# - packet loss: a bursty loss pattern over every vector, against libopus
#   concealing the same packets (tests/opus_loss_ref.c); SILK exactly, CELT
#   and hybrid within 40 dB (CELT's concealment fits an LPC whose order a
#   rounding difference can change); then with in-band FEC recovering each
#   loss's last packet, on the vectors that carry it and on FEC streams;
# - DTX streams from opus_demo against libopus;
# - Ogg and WebM files in every mode, and 5.1 surround (multistream),
#   through video.Reader against FFmpeg's libopus decode, full and after
#   seeks;
# - a fuzz pass under AddressSanitizer.
# Fixtures: tests/opus_fixtures.sh.
#   bash tests/opus_check.sh [fixture-dir]
set -uo pipefail
fx=${1:-.work/opusfx}
work=.work/opusgate
mkdir -p "$work"
export TMPDIR=${TMPDIR:-$PWD/.work/tmp}
odin build tests/opus_decode.odin -file -out:"$work/opus_decode" -o:speed -vet -strict-style || exit 1
odin build tests/movie_alpha.odin -file -out:"$work/movie_alpha" -o:speed || exit 1
odin build tests/opus_fuzz.odin -file -sanitize:address -debug -out:"$work/opus_fuzz" || exit 1
cc -O2 -o "$work/opus_loss_ref" tests/opus_loss_ref.c -Ithird_party/opus/include "$fx/opus-build/libopus.a" -lm || exit 1
compare=$fx/opus-build/opus_compare
v=$fx/vectors/opus_newvectors
pass=0 fail=0
result() { # ok? message
	if [ "$1" = 0 ]; then echo "ok   $2"; pass=$((pass + 1)); else echo "FAIL $2"; fail=$((fail + 1)); fi
}
snr_at_least() { # log min-dB: identical, or an SNR of at least min-dB
	[[ "$1" == *identical* ]] || awk -v s="$(echo "$1" | sed -n 's/.*vs reference \([0-9.-]*\) dB.*/\1/p')" -v m="$2" 'BEGIN {exit !(s != "" && s >= m)}'
}
# Conformance: final ranges exact and opus_compare passing.
for i in 01 02 03 04 05 06 07 08 09 10 11 12; do
	for ch in 2 1; do
		ref=$v/testvector$i.dec flags=-s
		[ "$ch" = 1 ] && ref=$v/testvector${i}m.dec flags=
		log=$("$work/opus_decode" "$v/testvector$i.bit" "$work/$i.$ch.pcm" "$ch" 2>&1)
		ok=$?
		q=$("$compare" $flags -r 48000 "$ref" "$work/$i.$ch.pcm" 2>&1 | tail -1)
		[ $ok -eq 0 ] && [[ "$q" == *"quality metric"* ]]
		result $? "vector $i, $ch ch: $log; $q"
	done
done
# Loss: bursts (a loss follows a loss half the time, a good packet 8%).
awk 'BEGIN {srand(7); lost = 0; for (i = 0; i < 5000; i++) {lost = i > 0 && rand() < (lost ? 0.5 : 0.08); print lost}}' > "$work/loss.txt"
for i in 01 02 03 04 05 06 07 08 09 10 11 12; do
	for ch in 2 1; do
		"$work/opus_loss_ref" "$v/testvector$i.bit" "$work/loss.txt" "$work/loss$i.$ch.ref" "$ch" || { result 1 "loss reference $i"; continue; }
		log=$("$work/opus_decode" "$v/testvector$i.bit" "$work/loss$i.$ch.pcm" "$ch" "$work/loss.txt" "$work/loss$i.$ch.ref" 2>&1)
		case $i in
		02 | 03 | 04) [[ "$log" == *identical* ]] ;;
		*) snr_at_least "$log" 40 ;;
		esac
		result $? "vector $i with loss, $ch ch: $log"
	done
done
# In-band FEC: each loss's last packet recovered from the next one's LBRR
# copy. The vectors with LBRR data, then streams encoded for loss.
for i in 02 04 10 12; do
	"$work/opus_loss_ref" "$v/testvector$i.bit" "$work/loss.txt" "$work/fec$i.ref" 2 fec || { result 1 "FEC reference $i"; continue; }
	log=$("$work/opus_decode" "$v/testvector$i.bit" "$work/fec$i.pcm" 2 "$work/loss.txt" "$work/fec$i.ref" fec 2>&1)
	case $i in
	02 | 04) [[ "$log" == *identical* ]] ;;
	*) snr_at_least "$log" 40 ;;
	esac
	result $? "vector $i with loss and FEC: $log"
done
for t in silk:1 silk40:1 silk60:2 hybrid:2; do
	IFS=: read -r name ch <<< "$t"
	"$work/opus_loss_ref" "$fx/fec_$name.bit" "$work/loss.txt" "$work/fec_$name.ref" "$ch" fec || { result 1 "FEC reference $name"; continue; }
	log=$("$work/opus_decode" "$fx/fec_$name.bit" "$work/fec_$name.pcm" "$ch" "$work/loss.txt" "$work/fec_$name.ref" fec 2>&1)
	[[ "$log" == *identical* ]]
	result $? "FEC $name: $log"
done
# DTX.
for t in silk:1:exact voip:2:exact audio:2:90 celt:2:90; do
	IFS=: read -r name ch need <<< "$t"
	"$work/opus_loss_ref" "$fx/dtx_$name.bit" /dev/null "$work/dtx_$name.ref" "$ch" || { result 1 "DTX reference $name"; continue; }
	log=$("$work/opus_decode" "$fx/dtx_$name.bit" "$work/dtx_$name.pcm" "$ch" - "$work/dtx_$name.ref" 2>&1)
	if [ "$need" = exact ]; then [[ "$log" == *identical* ]]; else snr_at_least "$log" "$need"; fi
	result $? "DTX $name: $log"
done
# Containers through video.Reader. After a seek's 80 ms pre-roll the
# decoder has re-converged to within (worst over every position) 0.007 for
# CELT and hybrid; SILK converges more slowly (0.044, exactly as libopus
# restarted at the same packet, SILK being bit-exact), and the surround LFE
# (a 60 Hz onset in the first 250 ms) is 0.118 off, as libopus is.
for f in "$fx"/celt_*.opus "$fx"/celt_*.webm "$fx"/celt_*.ogg "$fx/silk_mono.ogg" "$fx/hybrid_stereo.webm" "$fx/surround51.opus"; do
	log=$("$work/movie_alpha" "$f" - 1 "$f.f32" 2>&1)
	full=$(echo "$log" | awk '/pcm:/ {print $NF}')
	seek=$(echo "$log" | awk '/pcm seeks:/ {print $NF}')
	limit=0.02
	[[ "$(basename "$f")" == silk_* ]] && limit=0.06
	[[ "$(basename "$f")" == surround* ]] && limit=0.15
	[ -n "$full" ] && awk -v a="$full" -v b="$seek" -v l="$limit" 'BEGIN {exit !(a < 5e-5 && b < l)}' && echo "$log" | grep -q "FFmpeg $(echo "$log" | awk '/pcm:/ {print $2}'))"
	result $? "$(basename "$f"): full decode max difference $full, after seeks $seek"
done
for i in 04 11; do
	ASAN_OPTIONS=detect_leaks=0 "$work/opus_fuzz" "$v/testvector$i.bit" "$fx/celt_stereo.opus" "$fx/surround51.opus" 300 > "$work/fuzz.log" 2>&1
	result $? "fuzz (vector $i): $(tail -1 "$work/fuzz.log")"
done
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
