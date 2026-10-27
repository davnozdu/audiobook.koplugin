#!/usr/bin/env bash
# Host A/B differential gate for snt_server kernel changes.
#
# Builds the scalar-reference server (snt_kernels_ref.c + ports/host port,
# the current link line) and a candidate server where an alternative port TU
# replaces both, runs a fixed corpus through both with the same seed, and
# compares output.  Default mode is byte identity (WAV + .timing sidecar) for
# the int8/pq8/nano engines.  --corr switches to a Pearson-correlation gate
# for the f32 engine, whose fp32 reassociation legitimately changes bytes.
#
# With no --with-tu the script builds the reference twice: PASS proves the
# harness itself is sound before any kernel work is judged with it.
#
# Host-only (needs cc + espeak-ng + python3 for --corr).  Run from repo root:
#   nix shell nixpkgs#gcc nixpkgs#espeak-ng -c bash dev/snt-ab.sh --engine int8
#   nix shell nixpkgs#gcc nixpkgs#espeak-ng -c bash dev/snt-ab.sh \
#       --engine int8 --with-tu sanotts/mcu/ports/arm-neon/snt_port_arm.c

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE=int8
WITH_TU=
CORR=
NTEXTS=10
SEED=1234
ESPEAK_VOICE=
KEEP=
CROSS=
REF_TREE=
IDS_DIR=

while [ $# -gt 0 ]; do
    case "$1" in
        --engine) ENGINE=$2; shift 2 ;;
        --with-tu) WITH_TU=$2; shift 2 ;;
        --corr) CORR=$2; shift 2 ;;
        --texts) NTEXTS=$2; shift 2 ;;
        --seed) SEED=$2; shift 2 ;;
        --voice) ESPEAK_VOICE=$2; shift 2 ;;
        --keep) KEEP=1; shift ;;
        # --ids DIR: espeak-free mode. Synthesizes every ids-*.bin through the
        # driver (dev/snt_ids_driver.c) instead of running snt_server; this is
        # the byte gate that runs under qemu, where the espeak child cannot
        # exec. Batch flags (pause/length scale) follow the engine defaults.
        --ids) IDS_DIR=$2; shift 2 ;;
        # --cross: armv7 static NEON builds run under qemu-arm. The reference
        # tree must be PRISTINE upstream mcu (+patches 0001/0002), e.g.
        # /tmp/snt-pristine/mcu, so no NEON code is in the reference at all.
        --cross) CROSS=1; shift ;;
        --ref-tree) REF_TREE=$2; shift 2 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

case "$ENGINE" in
    int8) MODEL="$REPO/sanotts/voice";     RATE=22050 ;;
    pq8)  MODEL="$REPO/sanotts/voice-amy"; RATE=22050 ;;
    f32)  MODEL="$REPO/sanotts/voice-fr";  RATE=22050 ;;
    nano) MODEL="$REPO/sanotts/voice-nano"; RATE=24000 ;;
    *) echo "bad engine: $ENGINE" >&2; exit 2 ;;
esac
[ -d "$MODEL" ] || { echo "model dir not found: $MODEL" >&2; exit 1; }

if [ -z "$ESPEAK_VOICE" ]; then
    case "$ENGINE" in f32) ESPEAK_VOICE=fr ;; *) ESPEAK_VOICE=en-us ;; esac
fi

OUT=$(mktemp -d)
if [ -z "$KEEP" ]; then trap 'rm -rf "$OUT"' EXIT; else echo "artifacts: $OUT"; fi

build() { # $1 = output path, $2 = engine src dir, $3 = "" (ref split) or one port TU
    local tree="$2" tu_src port_src cc_bin base_flags
    if [ -n "$3" ]; then
        tu_src="$3"
        port_src=""
    else
        tu_src="$tree/src/snt_kernels_ref.c"
        port_src="$tree/ports/host/snt_port_host.c"
    fi
    if [ -n "$CROSS" ]; then
        cc_bin=${CROSS_CC:-armv7l-unknown-linux-musleabihf-gcc}
        base_flags="-O2 -std=c99 -w -static -mfpu=neon -mfloat-abi=hard"
    else
        cc_bin=cc
        base_flags="-O2 -std=c99 -w"
    fi
    "$cc_bin" $base_flags \
      -I "$tree/include" -I "$tree/src" -I "$REPO/sanotts/voice-nano" \
      -DFSD_FAST_MATH -o "$1" \
      "$([ -n "$IDS_DIR" ] && echo "$REPO/dev/snt_ids_driver.c" || echo "$REPO/sanotts/snt_server.c")" \
      "$tree/src/snt_tts.c" "$tu_src" \
      "$tree/src/snt_nano.c" "$tree/src/snt_front_q8.c" \
      "$tree/src/snt_piperlite_q8.c" "$tree/src/snt_front_f32.c" \
      "$tree/src/snt_piperlite.c" $port_src \
      "$REPO/sanotts/nano_lex_g2p.c" "$REPO/sanotts/nano_lex_tables.c" \
      "$REPO/sanotts/nano_lex_fr.c" "$REPO/sanotts/nano_lex_fr_tables.c" -lm
}

if [ -n "$CROSS" ] && [ -z "${ESPEAK_BIN:-}" ] && [ -z "$IDS_DIR" ]; then
    # The phonemize child must also be ARM to run under qemu-user; point
    # ESPEAK_BIN at the cross espeak from the repo recipe, e.g.
    #   E=$(nix-build cross-build-espeak.nix --no-out-link)/bin/espeak-ng
    echo "cross mode needs ESPEAK_BIN (ARM espeak-ng) in the environment" >&2
    exit 1
fi
if [ -n "$CROSS" ] && [ -n "${ESPEAK_BIN:-}" ] && [ "$ENGINE" != nano ]; then
    # A guest-arch process under qemu-user cannot execve another guest binary
    # (no binfmt_misc); execl of a shebang script works, so the child execs a
    # host shell wrapper that re-enters qemu for the real ARM espeak.
    QEMU_BIN=${QEMU_BIN:-qemu-arm}
    cat > "$OUT/espeak-wrap.sh" <<WRAPEOF
#!/bin/sh
exec $QEMU_BIN -cpu ${QEMU_CPU:-cortex-a9} $ESPEAK_BIN "\$@"
WRAPEOF
    chmod +x "$OUT/espeak-wrap.sh"
    ESPEAK_BIN="$OUT/espeak-wrap.sh"
fi
ESPEAK_BIN=${ESPEAK_BIN:-$(command -v espeak-ng || true)}
if [ -n "$IDS_DIR" ]; then :; elif [ "$ENGINE" != nano ]; then
    [ -n "$ESPEAK_BIN" ] || { echo "espeak-ng not found" >&2; exit 1; }
    ESPEAK_DATA="${ESPEAK_DATA:-$(dirname "$(dirname "$(readlink -f "$ESPEAK_BIN")")")/share/espeak-ng-data}"
    [ -d "$ESPEAK_DATA" ] || { echo "espeak data not found: $ESPEAK_DATA" >&2; exit 1; }
fi

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
When the storm passed, the harbor was full of tangled rope and broken masts.
Le petit chat noir dort sur le canape pres de la fenetre.
Les oiseaux chantent des l'aube dans le jardin du voisin.
EOF
}

# Engine flags mirroring the plugin launch line (piperqueue buildBaseCommand).
FLAGS="--engine $ENGINE --model $MODEL --seed $SEED"
case "$ENGINE" in pq8|f32) FLAGS="$FLAGS --pause-scale 2.5" ;; esac
if [ -z "$IDS_DIR" ] && [ "$ENGINE" != nano ]; then
    FLAGS="$FLAGS --espeak-bin $ESPEAK_BIN --espeak-data $ESPEAK_DATA --voice $ESPEAK_VOICE"
    case "$ENGINE" in f32) FLAGS="$FLAGS --phonemes fr" ;; esac
fi

build "$OUT/ref_server" "${REF_TREE:-$REPO/sanotts/mcu}" ""
if [ -n "$WITH_TU" ]; then
    build "$OUT/cand_server" "$REPO/sanotts/mcu" "$WITH_TU"
    CAND="$OUT/cand_server"
    echo "A/B: reference vs candidate TU $WITH_TU"
else
    cp "$OUT/ref_server" "$OUT/cand_server"
    CAND="$OUT/cand_server"
    echo "A/B: reference vs itself (harness sanity mode)"
fi

run_side() { # $1 = binary, $2 = out prefix
    if [ -n "$CROSS" ]; then
        corpus | awk -v n="$NTEXTS" -v o="$2" '
            { printf "{\"text\":\"%s\",\"output_file\":\"%s_t%02d.wav\"}\n", $0, o, NR }
            NR >= n { exit }' | ${QEMU:-qemu-arm} -cpu ${QEMU_CPU:-cortex-a9} "$1" $FLAGS \
            > "$2.stdout" 2> "$2.stderr"
    else
        corpus | awk -v n="$NTEXTS" -v o="$2" '
            { printf "{\"text\":\"%s\",\"output_file\":\"%s_t%02d.wav\"}\n", $0, o, NR }
            NR >= n { exit }' | "$1" $FLAGS > "$2.stdout" 2> "$2.stderr"
    fi
}

if [ -n "$IDS_DIR" ]; then
    # espeak-free gate: same build() with the driver as the main, run per ids
    # file on both sides, compare WAV bytes.  Engine defaults mirror the
    # plugin (pq8/f32 carry --pause-scale 2.5).
    [ -d "$IDS_DIR" ] || { echo "ids dir not found: $IDS_DIR" >&2; exit 1; }
    build "$OUT/ref_drv" "${REF_TREE:-$REPO/sanotts/mcu}" ""
    if [ -n "$WITH_TU" ]; then
        build "$OUT/cand_drv" "$REPO/sanotts/mcu" "$WITH_TU"
    else
        cp "$OUT/ref_drv" "$OUT/cand_drv"
    fi
    DRV_FLAGS="--engine $ENGINE --model $MODEL"
    case "$ENGINE" in pq8|f32) DRV_FLAGS="$DRV_FLAGS --pause-scale 2.5" ;; esac
    [ -n "${LEN_SCALE:-}" ] && DRV_FLAGS="$DRV_FLAGS --length-scale $LEN_SCALE" || true
    fail=0; n=0
    for f in "$IDS_DIR"/*.bin; do
        n=$((n + 1))
        b=$(basename "$f" .bin)
        DRVQ=()
        [ -n "$CROSS" ] && DRVQ=(${QEMU:-qemu-arm} -cpu ${QEMU_CPU:-cortex-a9})
        rrc=0; crc=0
        "${DRVQ[@]}" "$OUT/ref_drv" $DRV_FLAGS --ids "$f" --out "$OUT/ref_$b.wav" 2> "$OUT/ref_$b.err" || rrc=$?
        "${DRVQ[@]}" "$OUT/cand_drv" $DRV_FLAGS --ids "$f" --out "$OUT/cand_$b.wav" 2> "$OUT/cand_$b.err" || crc=$?
        if [ "$rrc" -ne 0 ] || [ "$crc" -ne 0 ]; then
            if [ "$rrc" = "$crc" ]; then
                echo "skip  $b: both sides refused (rc $rrc: $(tail -1 "$OUT/ref_$b.err" | cut -c1-60))"
            else
                echo "FAIL $b: rc mismatch ref=$rrc cand=$crc"
                fail=$((fail + 1))
            fi
            continue
        fi
        rs=$(stat -c%s "$OUT/ref_$b.wav"); cs=$(stat -c%s "$OUT/cand_$b.wav")
        if [ "$rs" -le 44 ] || [ "$cs" -le 44 ]; then
            echo "FAIL $b: empty output (ref=${rs}B cand=${cs}B)"; fail=$((fail + 1)); continue
        fi
        if [ -n "$CORR" ]; then
            if [ "$rs" != "$cs" ]; then
                echo "FAIL $b: sample-count mismatch ref=${rs}B cand=${cs}B"; fail=$((fail + 1)); continue
            fi
            c=$(python3 - "$OUT/ref_$b.wav" "$OUT/cand_$b.wav" <<'PYEOF'
import struct, sys
def pcm(path):
    b = open(path, 'rb').read()
    n = (len(b) - 44) // 2
    return struct.unpack(f'<{n}h', b[44:44 + 2 * n])
a, b = pcm(sys.argv[1]), pcm(sys.argv[2])
na = sum(float(x) * x for x in a) ** 0.5
nb = sum(float(x) * x for x in b) ** 0.5
if na == 0 or nb == 0:
    print("ERR silent"); raise SystemExit(2)
print(f"{sum(float(x) * y for x, y in zip(a, b)) / (na * nb):.6f}")
PYEOF
)
            ok=$(awk -v c="$c" -v m="$CORR" 'BEGIN { print (c + 0 >= m + 0) ? 1 : 0 }')
            if [ "$ok" = 1 ]; then
                echo "ok    $b corr=$c (>= $CORR, $rs B)"
            else
                echo "FAIL $b corr=$c (< $CORR, $rs B)"; fail=$((fail + 1))
            fi
        else
            if [ "$rs" != "$cs" ]; then
                echo "FAIL $b: size mismatch ref=${rs}B cand=${cs}B"; fail=$((fail + 1)); continue
            fi
            if cmp -s "$OUT/ref_$b.wav" "$OUT/cand_$b.wav"; then
                echo "ok    $b byte-identical ($rs B)"
            else
                echo "FAIL $b: bytes differ (ref=${rs}B cand=${cs}B)"; fail=$((fail + 1))
            fi
        fi
    done
    if [ "$fail" -ne 0 ]; then
        echo "AB FAIL: $fail mismatches (engine=$ENGINE ids mode)"
        exit 1
    fi
    echo "AB PASS: $n ids utterances (engine=$ENGINE ids mode)"
    exit 0
fi

run_side "$OUT/ref_server" "$OUT/ref"
run_side "$CAND" "$OUT/cand"

fail=0
for i in $(seq 1 "$NTEXTS"); do
    rw="$OUT/ref_t$(printf '%02d' "$i").wav"
    cw="$OUT/cand_t$(printf '%02d' "$i").wav"
    if [ ! -s "$rw" ] || [ ! -s "$cw" ]; then
        echo "FAIL t$i: missing output (ref $(stat -c%s "$rw" 2>/dev/null || echo none)B, cand $(stat -c%s "$cw" 2>/dev/null || echo none)B)"
        fail=$((fail + 1)); continue
    fi
    rs=$(stat -c%s "$rw"); cs=$(stat -c%s "$cw")
    if [ -n "$CORR" ]; then
        c=$(python3 - "$rw" "$cw" <<'PYEOF'
import struct, sys
def pcm(path):
    b = open(path, 'rb').read()
    n = (len(b) - 44) // 2
    return struct.unpack(f'<{n}h', b[44:44 + 2 * n])
a, b = pcm(sys.argv[1]), pcm(sys.argv[2])
if len(a) != len(b) or len(a) == 0:
    print(f"ERR len {len(a)} vs {len(b)}"); raise SystemExit(2)
na = sum(float(x) * x for x in a) ** 0.5
nb = sum(float(x) * x for x in b) ** 0.5
if na == 0 or nb == 0:
    print("ERR silent"); raise SystemExit(2)
dot = sum(float(x) * y for x, y in zip(a, b))
print(f"{dot / (na * nb):.6f}")
PYEOF
        )
        case "$c" in ERR*) echo "FAIL t$i: $c"; fail=$((fail + 1)); continue ;; esac
        ok=$(awk -v c="$c" -v m="$CORR" 'BEGIN { print (c + 0 >= m + 0) ? 1 : 0 }')
        if [ "$ok" = 1 ]; then
            echo "ok    t$i corr=$c (>= $CORR, sizes $rs/$cs)"
        else
            echo "FAIL t$i corr=$c (< $CORR, sizes $rs/$cs)"
            fail=$((fail + 1))
        fi
    else
        if [ "$rs" -le 44 ] || [ "$cs" -le 44 ]; then
            echo "FAIL t$i: empty output (ref=${rs}B cand=${cs}B) - phonemize failed?"
            fail=$((fail + 1)); continue
        fi
        if [ "$rs" != "$cs" ]; then
            echo "FAIL t$i: size mismatch ref=${rs}B cand=${cs}B"
            fail=$((fail + 1)); continue
        fi
        if cmp -s "$rw" "$cw"; then
            echo "ok    t$i byte-identical ($rs B)"
        else
            echo "FAIL t$i: bytes differ (ref=${rs}B cand=${cs}B)"
            fail=$((fail + 1))
        fi
        rt="$rw.timing"; ct="$cw.timing"
        if [ -f "$rt" ] || [ -f "$ct" ]; then
            if cmp -s "$rt" "$ct"; then
                echo "ok    t$i .timing identical"
            else
                echo "FAIL t$i: .timing differs"
                fail=$((fail + 1))
            fi
        fi
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "AB FAIL: $fail mismatches (engine=$ENGINE corr=${CORR:-byte})"
    exit 1
fi
echo "AB PASS: $NTEXTS utterances (engine=$ENGINE corr=${CORR:-byte})"
