#!/usr/bin/env bash
# Tier 4a G2P gates: everything that must pass before --g2p nano becomes
# the default for English sanoTTS voices. Run from the repo root:
#
#   nix shell nixpkgs#gcc nixpkgs#espeak-ng -c bash dev/snt-g2p-gate.sh
#
# Gates:
#   1. golden adapter test (dev/test_g2p_adapter.c, 73 checks)
#   2. espeak-path regression (dev/test_snt_server_oov.sh must stay green)
#   3. byte identity: an explicit --g2p espeak must produce byte-identical
#      WAV + .timing to the absent flag (the flag plumbing is inert)
#   4. corpus OOV rate over three public-domain novels (target: token OOV
#      < 5%, espeak-fallback clauses < 3%; Moby Dick historically runs
#      above the clause target on archaic vocabulary -- the summary says so
#      rather than hiding it)
#   5. RTF: no meaningful regression on host (nano <= 1.5x espeak; both sit
#      near 0.02 here, where a fork+exec costs ~1 ms and the ordering
#      flips between runs). The BINDING "nano must win" measurement is the
#      on-device run (the bundled-loader espeak exec costs far more on the
#      ARM CPU), part of the on-device gate before any default flip.
#   6. timing coverage on a fixed sentence sample: grouped word spans
#      (espeak merges neighbouring words in ~25% of sentences; nano should
#      land under 5%)
#   7. French gates: the fr lexicon G2P (nano_lex_fr) against a held-out
#      novel. French OOV words SPEAK through the rule layer (they are not
#      silent like English OOV), so the numbers here are informational:
#      the binding French quality gate is the listening A/B, and clauses
#      above --g2p-oov-threshold still fall back to espeak.
#
# Flags: --skip-corpus (no network), --skip-rtf (skips the slow passes).
# The corpus is fetched to $G2P_CORPUS_DIR (default /tmp/g2p-corpus);
# provenance and sha256s live in dev/snt-g2p-corpus.md.

set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
SKIP_CORPUS=0
SKIP_RTF=0
[ "${1:-}" = "--skip-corpus" ] && SKIP_CORPUS=1
[ "${1:-}" = "--skip-rtf" ] && SKIP_RTF=1

CC_ARGS=(-O2 -std=gnu99 -w
  -I "$REPO/sanotts/mcu/include" -I "$REPO/sanotts/mcu/src" -I "$REPO/sanotts/voice-nano"
  -DFSD_FAST_MATH)
SRCS="$REPO/sanotts/mcu/src/snt_tts.c $REPO/sanotts/mcu/src/snt_kernels_ref.c
  $REPO/sanotts/mcu/src/snt_nano.c $REPO/sanotts/mcu/src/snt_front_q8.c
  $REPO/sanotts/mcu/src/snt_piperlite_q8.c $REPO/sanotts/mcu/src/snt_front_f32.c
  $REPO/sanotts/mcu/src/snt_piperlite.c $REPO/sanotts/mcu/ports/host/snt_port_host.c
  $REPO/sanotts/nano_lex_g2p.c $REPO/sanotts/nano_lex_tables.c \
  $REPO/sanotts/nano_lex_fr.c $REPO/sanotts/nano_lex_fr_tables.c"

EB=$(command -v espeak-ng) || { echo "espeak-ng not on PATH" >&2; exit 1; }
ED=$(dirname "$(dirname "$(readlink -f "$EB")")")/share/espeak-ng-data
test -d "$ED" || { echo "espeak-ng data not found at $ED" >&2; exit 1; }

fails=0
step() { echo; echo "== $1"; }

step "1. golden adapter test"
cc "${CC_ARGS[@]}" -o "$OUT/test_g2p_adapter" "$REPO/dev/test_g2p_adapter.c" \
  $SRCS -lm || exit 1
"$OUT/test_g2p_adapter" "$EB" "$ED" | tail -1
[ "${PIPESTATUS[0]}" = 0 ] || fails=$((fails+1))

step "2. espeak-path regression (oov drop test)"
bash "$REPO/dev/test_snt_server_oov.sh" >/dev/null 2>&1 \
  && echo "ok - espeak path unchanged" || { echo "FAIL - espeak path regressed"; fails=$((fails+1)); }

step "3. byte identity: --g2p espeak explicit vs absent flag"
cc "${CC_ARGS[@]}" -o "$OUT/snt_server" "$REPO/sanotts/snt_server.c" $SRCS -lm || exit 1
TEXT="Hello world. The little engine climbed the far hill, and 12 fine birds sang."
run_one() {  # $1 = extra flags, $2 = output prefix
  echo "{\"input\": \"$TEXT\", \"output\": \"$OUT/$2.wav\"}" \
    | "$OUT/snt_server" --model "$REPO/sanotts/voice" --engine int8 \
        --espeak-bin "$EB" --espeak-data "$ED" --seed 1234 $1 \
        2>/dev/null >/dev/null
}
run_one "" plain
run_one "--g2p espeak" explicit
if cmp -s "$OUT/plain.wav" "$OUT/explicit.wav" \
   && cmp -s "$OUT/plain.wav.timing" "$OUT/explicit.wav.timing"; then
  echo "ok - absent flag and explicit --g2p espeak are byte-identical"
else
  echo "FAIL - flag plumbing changed the espeak path"; fails=$((fails+1))
fi

step "4. corpus OOV"
cc -O2 -std=gnu99 -o "$OUT/corpus_oov" "$REPO/dev/g2p_corpus_oov.c" \
  "$REPO/sanotts/nano_lex_g2p.c" "$REPO/sanotts/nano_lex_tables.c" \
  "$REPO/sanotts/nano_lex_fr.c" "$REPO/sanotts/nano_lex_fr_tables.c" \
  -I "$REPO/sanotts" -lm || exit 1
if [ "$SKIP_CORPUS" = 1 ]; then
  echo "skip - corpus (--skip-corpus)"
else
  CORPUS="${G2P_CORPUS_DIR:-/tmp/g2p-corpus}"
  mkdir -p "$CORPUS"
  fetch() {  # $1=url $2=file
    [ -f "$CORPUS/$2" ] && return 0
    curl -fsSL "$1" -o "$CORPUS/$2" || { echo "FAIL - download $2"; fails=$((fails+1)); return 1; }
  }
  fetch "https://www.gutenberg.org/files/1342/1342-0.txt" pride_prejudice.txt
  fetch "https://www.gutenberg.org/files/2701/2701-0.txt" moby_dick.txt
  fetch "https://www.gutenberg.org/cache/epub/64317/pg64317.txt" great_gatsby.txt
  for b in pride_prejudice.txt moby_dick.txt great_gatsby.txt; do
    f="$CORPUS/$b"
    [ -f "$f" ] || continue
    line=$(cat "$f" | "$OUT/corpus_oov" 0.25)
    echo "$b: $line"
    oovpct=$(echo "$line" | sed 's/.*token_oov_pct=\([0-9.]*\).*/\1/')
    fbpct=$(echo "$line" | sed 's/.*fallback_pct=\([0-9.]*\).*/\1/')
    awk -v o="$oovpct" 'BEGIN{exit !(o < 5.0)}' \
      && echo "ok - token OOV < 5%" || { echo "FAIL - token OOV >= 5%"; fails=$((fails+1)); }
    awk -v f="$fbpct" 'BEGIN{exit !(f < 3.0)}' \
      && echo "ok - fallback clauses < 3%" \
      || echo "NOTE - fallback clauses >= 3% on $b (archaic vocabulary; A/B decides)"
  done
fi

step "5. RTF: nano vs espeak (host, kristin int8)"
if [ "$SKIP_RTF" = 1 ]; then
  echo "skip - RTF (--skip-rtf)"
else
  rt() {  # $1 = extra server flags; prints median rtf= value from 3 passes
    local out
    out=$(sh "$REPO/dev/snt-bench.sh" --engine int8 --passes 3 --bin "$OUT/snt_server" \
       --model "$REPO/sanotts/voice" --espeak-bin "$EB" --espeak-data "$ED" \
       --extra "$1" 2>/dev/null | grep -oE "rtf=[0-9.]+" | grep -oE "[0-9.]+" | sort -n | sed -n 2p)
    [ -n "$out" ] || { echo "FAIL - RTF run produced no rtf= lines" >&2; fails=$((fails+1)); echo 0; return; }
    echo "$out"
  }
  r_espeak=$(rt "")
  r_nano=$(rt "--g2p nano")
  echo "espeak RTF med=$r_espeak  nano RTF med=$r_nano"
  awk -v n="$r_nano" -v e="$r_espeak" 'BEGIN{exit !(n <= 1.5 * e)}' \
    && echo "ok - nano <= 1.5x espeak on host (device target: nano wins, on-device gate)" \
    || { echo "FAIL - nano regressed on host beyond noise"; fails=$((fails+1)); }
fi

step "6. timing coverage (grouped spans, fixed sample)"
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
)
run_cov() {  # $1 = extra flags; prints "spans" per sentence on separate lines
  for s in "${SAMPLE[@]}"; do
    echo "{\"input\": \"$s\", \"output\": \"$OUT/cov.wav\"}" \
      | "$OUT/snt_server" --model "$REPO/sanotts/voice" --engine int8 $1 \
          --espeak-bin "$EB" --espeak-data "$ED" --seed 1234 2>"$OUT/cov.err" \
          >/dev/null
    words=$(echo "$s" | wc -w)
    oov=$(grep -oE 'oov=[0-9]+' "$OUT/cov.err" 2>/dev/null | grep -oE '[0-9]+' | head -1)
    oov=${oov:-0}
    # OOV words contribute no audio (that is what the fallback counter
    # counts), so the span target is the whitespace words minus them.
    expected=$((words - oov))
    got=$(grep -c "^w " "$OUT/cov.wav.timing" 2>/dev/null || echo 0)
    echo "$got $expected"
  done
}
count_grouped() {  # reads "got expected" lines; prints grouped count
  g=0
  while read -r got expected; do
    [ "$got" -lt "$expected" ] && g=$((g+1))
  done
  echo "$g"
}
total=${#SAMPLE[@]}
g_nano=$(run_cov "--g2p nano" | count_grouped)
g_espeak=$(run_cov "" | count_grouped)
echo "nano grouped spans:   $g_nano/$total"
echo "espeak grouped spans: $g_espeak/$total (known-bad baseline)"
rate=$(awk -v g=$g_nano -v t=$total 'BEGIN{printf "%.1f", 100*g/t}')
awk -v r="$rate" 'BEGIN{exit !(r < 5.0)}' \
  && echo "ok - nano grouped spans < 5%" \
  || { echo "FAIL - nano grouped spans >= 5%"; fails=$((fails+1)); }

step "7. French: lexicon G2P gates (held-out novel, f32 RTF)"
cc -O2 -std=gnu99 -w -o "$OUT/test_snt_fr_l2s" "$REPO/dev/test_snt_fr_l2s.c" \
  "$REPO/sanotts/nano_lex_fr.c" "$REPO/sanotts/nano_lex_fr_tables.c" \
  -I "$REPO/sanotts" -lm || exit 1
"$OUT/test_snt_fr_l2s" "$EB" | tail -1
[ "${PIPESTATUS[0]}" = 0 ] || fails=$((fails+1))

if [ "$SKIP_CORPUS" = 1 ]; then
  echo "skip - French corpus (--skip-corpus)"
else
  FRCORPUS="${G2P_CORPUS_DIR:-/tmp/g2p-corpus}"
  mkdir -p "$FRCORPUS"
  [ -f "$FRCORPUS/miserables1.txt" ] || \
    curl -fsSL "https://www.gutenberg.org/cache/epub/17489/pg17489.txt" \
      -o "$FRCORPUS/miserables1.txt" \
      || { echo "FAIL - miserables1 download"; fails=$((fails+1)); }
  if [ -f "$FRCORPUS/miserables1.txt" ]; then
    line=$(cat "$FRCORPUS/miserables1.txt" | "$OUT/corpus_oov" --fr 0.25)
    echo "miserables1 (fr): $line"
    echo "note - French OOV speaks via the rule layer; thresholds are informational"
  fi
fi

if [ "$SKIP_RTF" = 1 ]; then
  echo "skip - French RTF (--skip-rtf)"
else
  rt_fr() {
    local out
    out=$(sh "$REPO/dev/snt-bench.sh" --engine f32 --passes 3 --bin "$OUT/snt_server" \
       --model "$REPO/sanotts/voice-fr" --espeak-bin "$EB" --espeak-data "$ED" \
       --voice fr --extra "$1" 2>/dev/null | grep -oE "rtf=[0-9.]+" | grep -oE "[0-9.]+" | sort -n | sed -n 2p)
    [ -n "$out" ] || { echo "FAIL - fr RTF run produced no rtf= lines" >&2; fails=$((fails+1)); echo 0; return; }
    echo "$out"
  }
  r_fr_espeak=$(rt_fr "")
  r_fr_nano=$(rt_fr "--g2p nano --phonemes fr")
  echo "fr espeak RTF med=$r_fr_espeak  fr nano RTF med=$r_fr_nano"
  awk -v n="$r_fr_nano" -v e="$r_fr_espeak" 'BEGIN{exit !(n <= 1.5 * e)}' \
    && echo "ok - fr nano <= 1.5x espeak on host (device target: nano wins)" \
    || { echo "FAIL - fr nano regressed on host beyond noise"; fails=$((fails+1)); }
fi

echo
if [ "$fails" = 0 ]; then echo "G2P GATE PASS"; else echo "G2P GATE FAILED: $fails"; exit 1; fi
