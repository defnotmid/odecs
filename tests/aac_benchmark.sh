#!/usr/bin/env bash
# Resident AAC-LC encoder/decoder comparison; reference APIs are development only.
# CPU defaults match the recorded 9900X3D capture. Override for another machine.
set -euo pipefail
cd "$(dirname "$0")/.."
D=${WORK:-.work/aac-benchmark}
SINGLE_CPU=${SINGLE_CPU:-23}
MULTI_CPUS=${MULTI_CPUS:-0-23}
WORKERS=${WORKERS:-"1 16"}
case " $WORKERS " in *" 1 "*) ;; *) echo 'WORKERS must include 1 for output controls' >&2; exit 2;; esac
for workers in $WORKERS; do
    if [[ ! "$workers" =~ ^([1-9]|1[0-6])$ ]]; then
        echo 'WORKERS must contain counts between 1 and 16' >&2; exit 2
    fi
done
mkdir -p "$D"
odin build tests/audio_timing.odin -file -o:speed -microarch:native -debug -out:"$D/native"
odin build tests/audio_fixture.odin -file -o:speed -microarch:native -out:"$D/fixture"
odin build tests/audio_compare.odin -file -o:speed -microarch:native -out:"$D/compare"
cc -O3 -march=native -std=c11 -Wall -Wextra tests/reference_audio.c \
    $(pkg-config --cflags --libs libavcodec libavutil) -lm -pthread -o "$D/reference"

for case in 44100-1 48000-2; do
    rate=${case%-*}
    channels=${case#*-}
    bitrate=$((channels * 64000))
    source="$D/input-$case.pcm"
    "$D/fixture" "$source" "$rate" "$channels" 12 > "$D/input-$case.log"
    for workers in $WORKERS; do
        cpus=$SINGLE_CPU
        if [ "$workers" != 1 ]; then cpus=$MULTI_CPUS; fi
        # Optional, identical slot placement for both wrappers. Empty means
        # each thread may run anywhere in the taskset mask. Neither production
        # codec changes affinity. Example: AAC_SLOT_CPUS_1=23.
        slot_variable=AAC_SLOT_CPUS_$workers
        slot_cpus=${!slot_variable-}
        placement_env=(env -u AUDIO_CPUS)
        if [ -n "$slot_cpus" ]; then placement_env=(env AUDIO_CPUS="$slot_cpus"); fi
        for run in 1-native 2-reference 3-reference 4-native; do
            provider=${run#*-}
            prefix="$D/$case-$workers-encode-$run"
            "${placement_env[@]}" taskset -c "$cpus" "$D/$provider" encode "$source" "$rate" "$channels" \
                "$bitrate" "$workers" "$prefix.aac" > "$prefix.log" 2>&1
            tail -2 "$prefix.log"
        done
        cmp "$D/$case-$workers-encode-1-native.aac" "$D/$case-$workers-encode-4-native.aac"
        cmp "$D/$case-$workers-encode-2-reference.aac" "$D/$case-$workers-encode-3-reference.aac"
        for origin in native reference; do
            encoded_run=1-native
            if [ "$origin" = reference ]; then encoded_run=2-reference; fi
            input="$D/$case-1-encode-$encoded_run.aac"
            for run in 1-native 2-reference 3-reference 4-native; do
                provider=${run#*-}
                prefix="$D/$case-$workers-decode-$origin-$run"
                "${placement_env[@]}" taskset -c "$cpus" "$D/$provider" decode "$input" "$workers" \
                    "$prefix.pcm" > "$prefix.log" 2>&1
                tail -1 "$prefix.log"
            done
            prefix="$D/$case-$workers-decode-$origin"
            cmp "$prefix-1-native.pcm" "$prefix-4-native.pcm"
            cmp "$prefix-2-reference.pcm" "$prefix-3-reference.pcm"
        done
    done
done

# Validate only after all timings; no decode/quality workload runs concurrently.
for case in 44100-1 48000-2; do
    rate=${case%-*}
    channels=${case#*-}
    for provider in native reference; do
        encoded_run=1-native
        if [ "$provider" = reference ]; then encoded_run=2-reference; fi
        for workers in $WORKERS; do
            cmp "$D/$case-1-encode-$encoded_run.aac" "$D/$case-$workers-encode-$encoded_run.aac"
            for origin in native reference; do
                decoded_run=1-native
                if [ "$provider" = reference ]; then decoded_run=2-reference; fi
                cmp "$D/$case-1-decode-$origin-$decoded_run.pcm" "$D/$case-$workers-decode-$origin-$decoded_run.pcm"
            done
        done
        input="$D/$case-1-encode-$encoded_run.aac"
        ffmpeg -v error -threads 1 -y -i "$input" -f s16le "$D/$case-$provider.ff.pcm"
        prefix="$D/$case-1-decode-$provider"
        "$D/compare" pair "$prefix-1-native.pcm" "$prefix-2-reference.pcm" > "$D/$case-$provider.pair.log"
        "$D/compare" pair "$prefix-2-reference.pcm" "$D/$case-$provider.ff.pcm" > "$D/$case-$provider.cli-pair.log"
        "$D/compare" pair "$prefix-1-native.pcm" "$D/$case-$provider.ff.pcm" > "$D/$case-$provider.native-cli-pair.log"
        "$D/compare" quality "$D/input-$case.pcm" "$prefix-2-reference.pcm" \
            "$rate" "$channels" 1024 > "$D/$case-$provider.quality.log"
        cat "$D/$case-$provider.pair.log" "$D/$case-$provider.quality.log"
    done
done
echo "AAC benchmark passed: deterministic rounds and identical output for worker counts $WORKERS; all native/reference/CLI PCM pairs within two s16 units; declared 1024-sample priming applied and frame/padding counts checked"
