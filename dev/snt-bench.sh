#!/bin/sh
# sanoTTS snt_server benchmark: drives the real binary over its stdin JSON
# protocol (the same path the plugin uses) and reports RTF per pass:
# wall time / seconds of audio produced.  Runs under busybox sh on a Kobo or
# bash on the host.  No server-side changes needed.
#
# Expected layout (each path overridable): snt_server, voice/, voice-amy/,
# voice-fr/, voice-nano/ next to this script, espeak-ng on PATH or via flags.
# On a Kobo, scp this script + the binary + the voice dirs into one dir
# (e.g. /tmp/sntbench) and run:  sh snt-bench.sh --engine int8 --passes 5
#
# Each pass restarts the server, so RTF includes one model load - the same
# methodology as the spike's per-call snt_cli runs that produced the 0.153
# anchor (BENCHMARKS.md).  Pass outputs are hashed so pass-1 vs later-pass
# drift (thermal or nondeterminism) is visible.
#
# Usage:
#   sh snt-bench.sh --engine int8|pq8|f32|nano [--passes 5] [--texts N]
#       [--threads 1|2] [--seed 1234] [--bin PATH] [--model DIR]
#       [--espeak-bin BIN] [--espeak-data DIR] [--voice ESPEAK_VOICE]
#       [--length-scale F] [--out DIR]

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ENGINE=int8
PASSES=5
NTEXTS=12
THREADS=
SEED=1234
BIN="$HERE/snt_server"
MODEL=
ESPEAK_BIN=${ESPEAK_BIN:-}
ESPEAK_DATA=${ESPEAK_DATA:-}
ESPEAK_VOICE=
LEN_SCALE=
OUT=
EXTRA=

while [ $# -gt 0 ]; do
    case "$1" in
        --engine) ENGINE=$2; shift 2 ;;
        --passes) PASSES=$2; shift 2 ;;
        --texts) NTEXTS=$2; shift 2 ;;
        --threads) THREADS=$2; shift 2 ;;
        --seed) SEED=$2; shift 2 ;;
        --bin) BIN=$2; shift 2 ;;
        --model) MODEL=$2; shift 2 ;;
        --espeak-bin) ESPEAK_BIN=$2; shift 2 ;;
        --espeak-data) ESPEAK_DATA=$2; shift 2 ;;
        --voice) ESPEAK_VOICE=$2; shift 2 ;;
        --length-scale) LEN_SCALE=$2; shift 2 ;;
        --out) OUT=$2; shift 2 ;;
        # Appended verbatim to the server command line (e.g. the Kobo
        # --loader/--loader-libdir flags for the bundled glibc espeak-ng).
        --extra) EXTRA="$EXTRA $2"; shift 2 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

case "$ENGINE" in
    int8) [ -n "$MODEL" ] || MODEL="$HERE/voice";     RATE=22050 ;;
    pq8)  [ -n "$MODEL" ] || MODEL="$HERE/voice-amy"; RATE=22050 ;;
    f32)  [ -n "$MODEL" ] || MODEL="$HERE/voice-fr";  RATE=22050 ;;
    nano) [ -n "$MODEL" ] || MODEL="$HERE/voice-nano"; RATE=24000 ;;
    *) echo "bad engine: $ENGINE" >&2; exit 2 ;;
esac

[ -x "$BIN" ] || { echo "snt_server not found: $BIN" >&2; exit 1; }
[ -d "$MODEL" ] || { echo "model dir not found: $MODEL" >&2; exit 1; }

if [ -z "$ESPEAK_VOICE" ]; then
    case "$ENGINE" in f32) ESPEAK_VOICE=fr ;; *) ESPEAK_VOICE=en-us ;; esac
fi

if [ "$ENGINE" != nano ]; then
    if [ -z "$ESPEAK_BIN" ]; then ESPEAK_BIN=$(command -v espeak-ng || true); fi
    [ -n "$ESPEAK_BIN" ] || { echo "espeak-ng not found (needed for $ENGINE)" >&2; exit 1; }
    if [ -z "$ESPEAK_DATA" ]; then
        ESPEAK_DATA=$(dirname "$(dirname "$(readlink -f "$ESPEAK_BIN")")")/share/espeak-ng-data
    fi
    [ -d "$ESPEAK_DATA" ] || { echo "espeak data not found: $ESPEAK_DATA" >&2; exit 1; }
fi

OUT=${OUT:-"$HERE/bench-$ENGINE-$$"}
mkdir -p "$OUT"

# Fixed corpus: plain declarative sentences of varied length, one per line.
corpus() {
    cat <<'EOF'
The little button broke.
He walked home in the rain, thinking about the letter she never sent.
It was a bright cold day in April, and the clocks were striking thirteen.
The old lighthouse keeper counted the waves until sleep took him.
Every morning the market filled with the smell of bread and roasted coffee.
She read the last page, closed the book, and watched the snow fall outside.
Two roads diverged in a yellow wood, and sorry I could not travel both.
The train arrived late, as trains in that country always seemed to do.
Nothing in the house would break, which was exactly what worried her most.
A single lamp burned in the window of the cottage across the field.
History does not repeat itself, but it often rhymes.
When the storm passed, the harbor was full of tangled rope and broken masts.
EOF
}

# Engine flags mirroring the plugin's launch line (piperqueue buildBaseCommand):
# pq8 and f32 carry --pause-scale 2.5; int8 none; length-scale only when asked.
FLAGS="--engine $ENGINE --model $MODEL --seed $SEED"
case "$ENGINE" in
    pq8|f32) FLAGS="$FLAGS --pause-scale 2.5" ;;
esac
[ -n "$LEN_SCALE" ] && FLAGS="$FLAGS --length-scale $LEN_SCALE"
[ -n "$EXTRA" ] && FLAGS="$FLAGS $EXTRA"
if [ "$ENGINE" != nano ]; then
    FLAGS="$FLAGS --espeak-bin $ESPEAK_BIN --espeak-data $ESPEAK_DATA --voice $ESPEAK_VOICE"
    case "$ENGINE" in f32) FLAGS="$FLAGS --phonemes fr" ;; esac
fi

# Timestamps as seconds with fractions; awk does all float math so busybox
# integer width never matters.  If the platform lacks date +%N (older busybox
# prints a literal N), fall back to /proc/uptime (centiseconds).
now_s() {
    t=$(date +%s.%N 2>/dev/null) || t=""
    case "$t" in
        *N*|""|0.000000000) t=$(cut -d' ' -f1 /proc/uptime 2>/dev/null || echo 0) ;;
    esac
    echo "$t"
}

gen_requests() {
    corpus | awk -v n="$NTEXTS" -v k="$1" -v out="$OUT" '
        { printf "{\"text\":\"%s\",\"output_file\":\"%s/p%s_t%d.wav\"}\n", $0, out, k, NR }
        NR >= n { exit }'
}

run_pass() {
    p=$1
    # shellcheck disable=SC2086  # FLAGS is intentionally word-split
    if [ -n "$THREADS" ]; then
        SNT_THREADS="$THREADS" "$BIN" $FLAGS
    else
        "$BIN" $FLAGS
    fi
}

echo "=== snt-bench engine=$ENGINE threads=${THREADS:-default} passes=$PASSES texts=$NTEXTS rate=$RATE ==="
echo "bin: $BIN"
echo "model: $MODEL"

PASS_ROWS=""
P=1
while [ "$P" -le "$PASSES" ]; do
    t0=$(now_s)
    # Requests and responses ride the same pipes; the server processes one
    # line at a time and prints the WAV path after the sidecar is closed.
    gen_requests "$P" | run_pass "$P" > "$OUT/stdout_p$P.txt" 2> "$OUT/stderr_p$P.txt"
    t1=$(now_s)

    SIZES=""
    i=1
    while [ "$i" -le "$NTEXTS" ]; do
        f="$OUT/p${P}_t$i.wav"
        if [ -f "$f" ]; then s=$(wc -c < "$f"); else s=0; fi
        SIZES="$SIZES $s"
        i=$((i + 1))
    done
    STATS=$(echo "$SIZES" | awk -v rate="$RATE" '
        {
            total = 0; got = 0
            for (i = 1; i <= NF; i++) {
                if ($i + 0 > 44) { total += ($i - 44) / 2 / rate; got++ }
            }
            printf "%.4f %d %d", total, got, NF
        }')
    AUDIO_S=$(echo "$STATS" | awk '{print $1}')
    GOT=$(echo "$STATS" | awk '{print $2}')
    WANT=$(echo "$STATS" | awk '{print $3}')
    RTF=$(awk -v w="$t1" -v s="$t0" -v a="$AUDIO_S" \
        'BEGIN { if (a + 0 <= 0) print "nan"; else printf "%.4f", (w - s) / a }')
    echo "pass $P: rtf=$RTF audio=${AUDIO_S}s wavs=$GOT/$WANT"
    PASS_ROWS="$PASS_ROWS $RTF"
    P=$((P + 1))
done

# Cross-pass determinism check: the same seed must give identical bytes.
if [ "$PASSES" -gt 1 ]; then
    H1=$(cd "$OUT" && sha256sum p1_t*.wav 2>/dev/null | awk '{print $1}' | sha256sum | cut -c1-16)
    HL=$(cd "$OUT" && sha256sum p${PASSES}_t*.wav 2>/dev/null | awk '{print $1}' | sha256sum | cut -c1-16)
    if [ "$H1" = "$HL" ]; then
        echo "determinism: pass1 == pass$PASSES ($H1)"
    else
        echo "determinism: MISMATCH pass1=$H1 pass$PASSES=$HL"
    fi
fi

echo "$PASS_ROWS" | tr ' ' '\n' | awk 'NF' | sort -n | awk '
    { v[NR] = $1 }
    END {
        if (NR == 0) { print "BENCH rtf=nan"; exit }
        mid = int((NR + 1) / 2)
        printf "BENCH engine=%s threads=%s passes=%d rtf_min=%.4f rtf_med=%.4f rtf_max=%.4f\n", e, t, NR, v[1], v[mid], v[NR]
    }' e="$ENGINE" t="${THREADS:-default}"
echo "outputs: $OUT"
