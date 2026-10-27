#!/usr/bin/env bash
# Listening A/B for the --g2p nano phonemizer (gate d): renders a fixed
# 20-sentence sample twice on the SAME server binary, once per G2P, into
# per-sentence WAV pairs named NNN_nano.wav / NNN_espeak.wav. Listen in
# pairs; any sentence where nano sounds worse than espeak is a gate-d
# failure. Two sentences are deliberately OOV-heavy: they demonstrate the
# per-clause espeak fallback (whole-clause) and single-OOV swallowing.
#
# Host-only. Run from the repo root:
#   nix shell nixpkgs#gcc nixpkgs#espeak-ng -c bash dev/snt-ab-g2p.sh [outdir]
# Output: ${1:-/tmp/g2p-ab}/ with the WAV pairs and a playlist-style list.

set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUTDIR="${1:-/tmp/g2p-ab}"
ENGINE=int8
VOICE_DIR="$REPO/sanotts/voice"          # kristin
[ "${2:-}" = "amy" ] && { VOICE_DIR="$REPO/sanotts/voice-amy"; ENGINE=pq8; }

EB=$(command -v espeak-ng) || { echo "espeak-ng not on PATH" >&2; exit 1; }
ED=$(dirname "$(dirname "$(readlink -f "$EB")")")/share/espeak-ng-data
mkdir -p "$OUTDIR"

SERVER="$OUTDIR/snt_server"
cc -O2 -std=gnu99 -w \
  -I "$REPO/sanotts/mcu/include" -I "$REPO/sanotts/mcu/src" -I "$REPO/sanotts/voice-nano" \
  -DFSD_FAST_MATH -o "$SERVER" "$REPO/sanotts/snt_server.c" \
  "$REPO/sanotts/mcu/src/snt_tts.c" "$REPO/sanotts/mcu/src/snt_kernels_ref.c" \
  "$REPO/sanotts/mcu/src/snt_nano.c" "$REPO/sanotts/mcu/src/snt_front_q8.c" \
  "$REPO/sanotts/mcu/src/snt_piperlite_q8.c" "$REPO/sanotts/mcu/src/snt_front_f32.c" \
  "$REPO/sanotts/mcu/src/snt_piperlite.c" "$REPO/sanotts/mcu/ports/host/snt_port_host.c" \
  "$REPO/sanotts/nano_lex_g2p.c" "$REPO/sanotts/nano_lex_tables.c" \
  "$REPO/sanotts/nano_lex_fr.c" "$REPO/sanotts/nano_lex_fr_tables.c" -lm

SAMPLE=(
  "Hello world."
  "The little engine climbed the far hill."
  "Mr. Brown laughed and said hello."
  "It costs twelve dollars and fifty cents."
  "In nineteen twenty six the ship sailed."
  "Vancouver is a rainy city in the fall."
  "She said, come here at once."
  "The quick brown fox jumps over the lazy dog."
  "Queequeg handed him the harpoon at dawn."
  "Elizabeth read the letter in silence."
  "My brother judged the water contest better than I did."
  "The church bell tower judge wore a brown jacket."
  "Chapter twenty two begins on page one hundred and forty."
  "They arrived at three thirty, wet and tired."
  "The city water tower overlooks the valley."
  "Did you write the letter to my cousin in London?"
  "Yes, and I posted it on Tuesday morning."
  "Manfred met Zyxwv in Quxxly."
  "A thousand regrets, but the hour is late."
  "The bridge over the river shone in the evening light."
)

i=0
for s in "${SAMPLE[@]}"; do
  i=$((i+1))
  id=$(printf "%02d" $i)
  for mode in nano espeak; do
    extra=""
    [ "$mode" = nano ] && extra="--g2p nano"
    echo "{\"input\": \"$s\", \"output\": \"$OUTDIR/${id}_${mode}.wav\"}" \
      | "$SERVER" --model "$VOICE_DIR" --engine "$ENGINE" $extra \
          --espeak-bin "$EB" --espeak-data "$ED" --seed 1234 >/dev/null 2>&1
  done
  echo "$id: $s"
done
echo
echo "A/B pairs written to $OUTDIR (${#SAMPLE[@]} sentences, engine $ENGINE)."
echo "Listen NNN_nano.wav against NNN_espeak.wav; 09 and 18 show the OOV"
echo "fallback and swallowing behavior."
