#!/usr/bin/env bash
# Regression test: the pq8/f32 engines must synthesize words whose phonemes
# include an id the voice cannot embed.
#
# espeak renders "little", "button" and "certain" with a syllabic-consonant
# mark whose piper phoneme id is 144, above the amy voice's duration embedding
# vocabulary (d_vocab 129). Before drop_oov_ids() in snt_server.c the whole
# clause failed with "pq8 durations rc -3", and the request came back with
# header-only audio (44 bytes) or a sentence truncated at the failing clause.
#
# Requires a host toolchain and a host espeak-ng. Run from the repo root:
#   nix shell nixpkgs#gcc nixpkgs#espeak-ng -c bash dev/test_snt_server_oov.sh

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

BIN="$OUT/snt_server"
cc -O2 -std=c99 -w \
  -I "$REPO/sanotts/mcu/include" -I "$REPO/sanotts/mcu/src" -I "$REPO/sanotts/voice-nano" \
  -DFSD_FAST_MATH -o "$BIN" \
  "$REPO/sanotts/snt_server.c" \
  "$REPO/sanotts/mcu/src/snt_tts.c" "$REPO/sanotts/mcu/src/snt_kernels_ref.c" \
  "$REPO/sanotts/mcu/src/snt_nano.c" "$REPO/sanotts/mcu/src/snt_front_q8.c" \
  "$REPO/sanotts/mcu/src/snt_piperlite_q8.c" "$REPO/sanotts/mcu/src/snt_front_f32.c" \
  "$REPO/sanotts/mcu/src/snt_piperlite.c" "$REPO/sanotts/mcu/ports/host/snt_port_host.c" \
  "$REPO/sanotts/nano_lex_g2p.c" "$REPO/sanotts/nano_lex_tables.c" \
  "$REPO/sanotts/nano_lex_fr.c" "$REPO/sanotts/nano_lex_fr_tables.c" -lm

ESPEAK_BIN="$(command -v espeak-ng)"
ESPEAK_DATA="$(dirname "$(dirname "$(readlink -f "$ESPEAK_BIN")")")/share/espeak-ng-data"
test -d "$ESPEAK_DATA" || { echo "espeak-ng data not found" >&2; exit 1; }

fails=0
checks=0

# Header-only WAV is 44 bytes, which the plugin's size > 0 guard accepts, so
# the failure surfaced as silence or a truncated sentence rather than an error.
expect_audio() {
    local text="$1" wav="$OUT/case.wav"
    rm -f "$wav" "$wav.timing"
    local err
    err=$(printf '%s\n' "{\"text\":\"$text\",\"output_file\":\"$wav\"}" | \
        "$BIN" --engine pq8 --model "$REPO/sanotts/voice-amy" --pause-scale 2.5 \
        --espeak-bin "$ESPEAK_BIN" --espeak-data "$ESPEAK_DATA" --voice en-us 2>&1 \
        | grep -c '"error"' || true)
    local size=0
    [ -e "$wav" ] && size=$(stat -c%s "$wav")
    checks=$((checks + 1))
    if [ "$size" -le 44 ] || [ "$err" != "0" ]; then
        echo "FAIL  size=$size errors=$err  $text"
        fails=$((fails + 1))
    else
        echo "ok    size=$size  $text"
    fi
}

# Words espeak gives a syllabic consonant, so the trigger is everywhere.
expect_audio "The little button."
expect_audio "A certain garden."
expect_audio "He walked home. The little button broke."
expect_audio "Simple people at the table."

if [ "$fails" -ne 0 ]; then
    echo "FAILED $fails of $checks"
    exit 1
fi
echo "ok - $checks checks passed"
