#!/usr/bin/env python3
"""Generate sanotts/nano_lex_fr_tables.c/.h: a packed French pronunciation
lexicon for the --g2p nano runtime, same nano_lex_dict_t blob format as
nano_lex_tables.c (bias-by-'0', front-coded blocks of 8, PLAIN vcode only).

Pronunciations are derived from espeak-ng `-q --ipa -v fr` output, so an
in-dictionary word is phonemized EXACTLY as espeak would -- the fr f32 voice
(fr-siwis) was trained on espeak-derived piper ids, which is what makes the
lexicon safe where a hand-written letter-to-sound layer is not.

Vocabulary (words only, no counts or alignments cross the boundary):
  - FrequencyWords fr_full.txt top-N alpha forms (OpenSubtitles-derived word
    list; word strings only),
  - literary supplement from Project Gutenberg French originals,
  - generated French number words (cardinals 0..999999, ordinals) so the
    runtime speller's output is always in-dictionary,
  - elision host forms (l', d', qu', jusqu', ...) with hand-set values,
  - words from the plugin's French UI strings (l10n/fr).

Words whose espeak IPA contains a symbol outside the plugin's fr piper map
(phoneme_id_map_fr.h) are dropped and counted: the runtime walks every IPA
symbol through that map, so an unmappable word would break synthesis.

Budget: the generator refuses output above --max-bytes (default 2 MB of
generated .rodata) and truncates the frequency-ordered vocabulary instead.

Usage:
  python3 -I tools/gen_fr_lex_tables.py --sources DIR [--check]
  python3 -I tools/gen_fr_lex_tables.py --help
"""

import argparse
import hashlib
import os
import re
import subprocess
import sys

WORD_RE = re.compile(r"^[a-zàâäéèêëîïôöùûüçœæ']+(-[a-zàâäéèêëîïôöùûüçœæ']+)*$")
GUTENBERG_START = "*** START OF"
GUTENBERG_END = "*** END OF"

DEFAULT_SOURCES = "/tmp/fr-lex"

# Frequency words cap before packing (the budget may truncate further).
FREQ_TOP = 100000

MAX_KEY_BYTES = 45
MAX_VALUE_CODES = 59
NANO_LEX_BIAS = ord("0")
NANO_LEX_BLOCK = 8
VCODE_NULL = 0
VCODE_PLAIN_BASE = 1

# Elision host forms: pronounced as themselves when split from the noun.
# Hand-set (espeak on the bare letter gives the letter NAME, not the
# elision sound).
HOST_FORMS = {
    "l": "l",
    "d": "d",
    "n": "n",
    "s": "s",
    "j": "ʒ",
    "m": "m",
    "t": "t",
    "c": "s",
    "qu": "k",
    "jusqu": "ʒysk",
    "lorsqu": "lɔʁsk",
    "puisqu": "pɥisk",
    "quoiqu": "kwak",
}

UNITS = ["zéro", "un", "deux", "trois", "quatre", "cinq", "six", "sept",
         "huit", "neuf", "dix", "onze", "douze", "treize", "quatorze",
         "quinze", "seize"]
TENS = {20: "vingt", 30: "trente", 40: "quarante", 50: "cinquante",
        60: "soixante"}


def num_tokens(n):
    """French cardinal spelling of n (0..999999), as a token list."""
    if n < 17:
        return [UNITS[n]]
    if n < 20:
        return ["dix", UNITS[n - 10]]
    if n < 70:
        t, r = divmod(n, 10)
        t *= 10
        if r == 0:
            return [TENS[t]]
        if r == 1:
            return [TENS[t], "et", "un"]
        return [TENS[t], UNITS[r]]
    if n < 80:
        r = n - 60
        if r == 11:
            return ["soixante", "et", "onze"]
        return ["soixante"] + num_tokens(r)
    if n < 100:
        r = n - 80
        if r == 0:
            return ["quatre-vingts"]
        return ["quatre-vingt"] + num_tokens(r)
    if n < 200:
        r = n - 100
        return ["cent"] if r == 0 else ["cent"] + num_tokens(r)
    if n < 1000:
        h, r = divmod(n, 100)
        head = [UNITS[h], "cents"] if r == 0 and h > 1 else [UNITS[h], "cent"]
        return head if r == 0 else head + num_tokens(r)
    if n < 1000000:
        th, r = divmod(n, 1000)
        head = ["mille"] if th == 1 else num_tokens(th) + ["mille"]
        return head if r == 0 else head + num_tokens(r)
    raise ValueError("out of range: %d" % n)


ORDINAL_SPECIAL = {1: ["premier"], 2: ["deuxième"], 3: ["troisième"]}


def ordinal_tokens(n):
    """French ordinal spelling tokens for small ordinals used in books."""
    if n in ORDINAL_SPECIAL:
        return ORDINAL_SPECIAL[n]
    if n < 100:
        base = num_tokens(n)
        last = base[-1]
        if last == "cinq":
            base = base[:-1] + ["cinquième"]
        elif last == "neuf":
            base = base[:-1] + ["neuvième"]
        elif last.endswith("e"):
            base = base[:-1] + [last + "ième"]
        else:
            base = base + ["ième"]
        return base
    return []


def number_words():
    """Every distinct word the runtime spellers can emit."""
    words = set()
    for n in range(0, 1000000):
        words.update(num_tokens(n))
    for n in list(range(0, 101)) + [1000, 1001, 2000, 10000, 100000, 1000000]:
        words.update(ordinal_tokens(n))
    return words


def read_gutenberg_words(path):
    """Alpha tokens from a Gutenberg text, header/footer stripped."""
    with open(path, encoding="utf-8", errors="replace") as f:
        text = f.read()
    start = text.find(GUTENBERG_START)
    end = text.find(GUTENBERG_END)
    if start != -1:
        text = text[start:]
    if end != -1:
        text = text[:end]
    out = set()
    for m in re.finditer(r"[A-Za-zÀ-ÿŒœÆæ]+(?:['’-][A-Za-zÀ-ÿŒœÆæ]+)*", text):
        w = (m.group(0).replace("’", "'")).lower()
        if WORD_RE.match(w):
            out.add(w)
    return out


def l10n_words(repo):
    """Words from the plugin's own French UI strings."""
    out = set()
    l10n_dir = os.path.join(repo, "l10n", "fr", "LC_MESSAGES")
    if not os.path.isdir(l10n_dir):
        return out
    for name in os.listdir(l10n_dir):
        if not name.endswith(".po"):
            continue
        with open(os.path.join(l10n_dir, name), encoding="utf-8",
                  errors="replace") as f:
            text = f.read()
        for line in text.splitlines():
            if not line.startswith("msgstr"):
                continue
            for m in re.finditer(r"[A-Za-zÀ-ÿŒœÆæ]+", line):
                w = m.group(0).lower()
                if WORD_RE.match(w):
                    out.add(w)
    return out


def espeak_ipa_batch(words, espeak):
    """IPA per word. Batched through --stdin with a strict 1:1 token
    assertion; any batch that does not zip cleanly falls back to one
    process per word (espeak joins multi-word input on one line)."""
    result = {}
    todo = list(words)
    B = 200
    for i in range(0, len(todo), B):
        chunk = todo[i:i + B]
        proc = subprocess.run(
            [espeak, "-q", "--ipa", "-v", "fr", "--stdin"],
            input="\n".join(chunk) + "\n", capture_output=True, text=True)
        toks = proc.stdout.split()
        if len(toks) == len(chunk):
            for w, t in zip(chunk, toks):
                result[w] = t
            continue
        for w in chunk:  # slow path
            p2 = subprocess.run(
                [espeak, "-q", "--ipa", "-v", "fr", w],
                capture_output=True, text=True)
            result[w] = p2.stdout.split()[0] if p2.stdout.split() else ""
    return result


def load_fr_map(repo):
    """(symbol -> id) from phoneme_id_map_fr.h, via a tiny parser."""
    path = os.path.join(repo, "sanotts", "phoneme_id_map_fr.h")
    entries = {}
    pat = re.compile(r'\{"((?:[^"\\]|\\.)*)",\s*(\d+)\}')
    with open(path, encoding="utf-8") as f:
        for m in pat.finditer(f.read()):
            entries[m.group(1)] = int(m.group(2))
    return entries


def ipa_mappable(ipa, fr_map):
    """True when every codepoint of the IPA string maps through the fr
    piper map (combining marks are their own map entries)."""
    for ch in ipa:
        if ch == " ":
            continue
        if ch not in fr_map:
            return False
    return True


def pack(words_ipa, fr_map):
    """Assign symbol codes, then pack front-coded blocks. Returns
    (blob_bytes, block_off, symbol_table, entry_count, key_bytes)."""
    # symbol vocabulary: every codepoint that survives mapping, space first.
    cps = {0x20}
    for ipa in words_ipa.values():
        for ch in ipa:
            if ch != " ":
                cps.add(ord(ch))
    symbols = sorted(cps)
    code_of = {cp: i + 1 for i, cp in enumerate(symbols)}  # codes 1..N

    entries = []
    for w in sorted(words_ipa):
        ipa = words_ipa[w]
        codes = [code_of[ord(ch)] for ch in ipa if ch == " " or ord(ch) in code_of]
        if not codes or len(codes) > MAX_VALUE_CODES:
            continue
        if len(w.encode("utf-8")) > MAX_KEY_BYTES:
            continue
        entries.append((w.encode("utf-8"), codes))
    entries.sort(key=lambda e: e[0])

    blob = bytearray()
    block_off = []
    prev_key = b""
    for bi in range(0, len(entries), NANO_LEX_BLOCK):
        block_off.append(len(blob))
        block = entries[bi:bi + NANO_LEX_BLOCK]
        for ri, (key, codes) in enumerate(block):
            if ri == 0:
                blob.append(len(key) ^ 0 if False else len(key))
                blob[-1] = len(key)
                blob += key
            else:
                shared = 0
                while (shared < len(prev_key) and shared < len(key)
                       and key[shared] == prev_key[shared]):
                    shared += 1
                blob.append(shared)
                blob.append(len(key) - shared)
                blob += key[shared:]
            prev_key = key
            vcode = VCODE_PLAIN_BASE + len(codes)
            blob.append(vcode)
            for c in codes:
                blob.append(c)
    # bias everything by '0'
    biased = bytes((b + NANO_LEX_BIAS) & 0xFF for b in blob)
    if b"\x00" in biased:
        raise SystemExit("internal error: NUL byte after biasing")
    return biased, block_off, symbols, code_of, len(entries)


def emit(repo, blob, block_off, symbols, fr_map, entry_count, stats,
         sources, check):
    def cstr(bs):
        return "".join("\\x%02x" % b for b in bs)

    # codes are 1-based over `symbols`; index 0 of every array is unused.
    ph_id = "    0,\n" + "".join(
        "    %d,\n" % fr_map.get(chr(cp), -1) for cp in symbols)
    ph_cp = "    0,\n" + "".join(
        "    %d,\n" % cp for cp in symbols)
    vowels = set("aeiouyɛɑɔəøœ")
    ph_flags = "    0,\n" + "".join(
        "    %d,\n" % (1 if chr(cp) in vowels else 0) for cp in symbols)

    n_blocks = len(block_off)
    src_doc = "".join("  - %s\n" % s for s in sources)
    header = f"""/* nano_lex_fr_tables.h -- GENERATED by tools/gen_fr_lex_tables.py,
 * DO NOT EDIT BY HAND. Verify with:
 *   python3 -I tools/gen_fr_lex_tables.py --sources <dir> --check
 *
 * French pronunciation lexicon for the --g2p nano runtime (nano_lex_fr.c),
 * packed in the same nano_lex_dict_t format as nano_lex_tables.c: bias
 * '{NANO_LEX_BIAS}', front-coded blocks of {NANO_LEX_BLOCK}, PLAIN vcode only
 * (vcode = 1 + code count; the values are biased fr-vocabulary codes).
 *
 * Pronunciations are espeak-ng `-q --ipa -v fr` output, so in-dictionary
 * words are espeak-exact by construction. Words whose IPA does not fully
 * map through phoneme_id_map_fr.h were dropped at generation time.
 *
 * SOURCES (sha256 at generation time):
{src_doc}
 * PACKED: {entry_count} entries, blob {len(blob)} B + index {4 * n_blocks} B.
 */

#ifndef NANO_LEX_FR_TABLES_H
#define NANO_LEX_FR_TABLES_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {{
#endif

#define NANO_LEX_FR_BIAS '{chr(NANO_LEX_BIAS)}'
#define NANO_LEX_FR_BLOCK {NANO_LEX_BLOCK}
#define NANO_LEX_FR_MAX_KEY {MAX_KEY_BYTES}
#define NANO_LEX_FR_MAX_VALUE {MAX_VALUE_CODES}
#define NANO_LEX_FR_PH_COUNT {len(symbols) + 1}

/* code -> piper fr map id, or -1 (index 0 unused). */
extern const int16_t NANO_LEX_FR_PH_ID[NANO_LEX_FR_PH_COUNT];
/* code -> Unicode codepoint. */
extern const uint32_t NANO_LEX_FR_PH_CP[NANO_LEX_FR_PH_COUNT];
/* code -> flags (bit 0 vowel). */
extern const uint8_t NANO_LEX_FR_PH_FLAGS[NANO_LEX_FR_PH_COUNT];

typedef struct {{
    const char     *blob;
    const uint32_t *block_off;
    uint32_t        blob_bytes;
    uint32_t        block_count;
    uint32_t        entry_count;
}} nano_lex_fr_dict_t;

extern const nano_lex_fr_dict_t NANO_LEX_FR_GOLD;

#ifdef __cplusplus
}}
#endif

#endif /* NANO_LEX_FR_TABLES_H */
"""
    body = f"""/* nano_lex_fr_tables.c -- GENERATED, see nano_lex_fr_tables.h. */
#include "nano_lex_fr_tables.h"

#define B(b) ((const char)(b))

/* biased blob: keys are UTF-8 bytes, values biased fr codes. */
static const char FR_BLOB[] =
"""
    # emit the blob as C string chunks with escapes
    lines = []
    CH = 80
    for i in range(0, len(blob), CH):
        piece = blob[i:i + CH]
        lines.append('  "' + cstr(piece) + '"')
    body += "\n".join(lines) + ";\n\n"
    body += "static const uint32_t FR_BLOCK_OFF[] = {\n"
    for i in range(0, n_blocks, 12):
        row = block_off[i:i + 12]
        body += "    " + " ".join("%uu," % v for v in row) + "\n"
    body += "};\n\n"
    body += ("const nano_lex_fr_dict_t NANO_LEX_FR_GOLD = {\n"
             "    FR_BLOB, FR_BLOCK_OFF, sizeof FR_BLOB - 1, %u, %u\n};\n\n"
             % (n_blocks, entry_count))
    body += ("const int16_t NANO_LEX_FR_PH_ID[NANO_LEX_FR_PH_COUNT] = {\n"
             + ph_id + "};\n"
             "const uint32_t NANO_LEX_FR_PH_CP[NANO_LEX_FR_PH_COUNT] = {\n"
             + ph_cp + "};\n"
             "const uint8_t NANO_LEX_FR_PH_FLAGS[NANO_LEX_FR_PH_COUNT] = {\n"
             + ph_flags + "};\n")

    if check:
        # regenerate byte-identical content
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".c", delete=False,
                                         encoding="utf-8") as f:
            f.write(body)
            tmp = f.name
        try:
            existing = open(os.path.join(repo, "sanotts",
                                         "nano_lex_fr_tables.c"),
                            encoding="utf-8").read()
        except OSError:
            existing = None
        os.unlink(tmp)
        if existing != body:
            print("CHECK FAILED: nano_lex_fr_tables.c differs", file=sys.stderr)
            sys.exit(1)
        print("check ok: %d entries, blob %d B" % (entry_count, len(blob)))
        return

    with open(os.path.join(repo, "sanotts", "nano_lex_fr_tables.h"), "w",
              encoding="utf-8") as f:
        f.write(header)
    with open(os.path.join(repo, "sanotts", "nano_lex_fr_tables.c"), "w",
              encoding="utf-8") as f:
        f.write(body)
    print("wrote nano_lex_fr_tables.h/.c: %d entries, blob %d B + index %d B"
          % (entry_count, len(blob), 4 * n_blocks))
    for k, v in stats.items():
        print("  %s: %s" % (k, v))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sources", default=DEFAULT_SOURCES)
    ap.add_argument("--espeak", default="espeak-ng")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--max-bytes", type=int, default=2 * 1024 * 1024)
    args = ap.parse_args()
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    src = args.sources

    fr_map = load_fr_map(repo)

    # 1. vocabulary
    freq = []
    fp = os.path.join(src, "fr_full.txt")
    with open(fp, encoding="utf-8", errors="replace") as f:
        for line in f:
            w = line.split(" ", 1)[0].strip().lower()
            if WORD_RE.match(w):
                freq.append(w)
            if len(freq) >= FREQ_TOP:
                break
    lit = set()
    for name in ("meunier.txt", "balzac1.txt"):
        p = os.path.join(src, name)
        if os.path.exists(p):
            lit |= read_gutenberg_words(p)
    vocab = list(dict.fromkeys(freq)) + sorted(lit - set(freq))
    vocab += sorted(number_words() - set(vocab))
    vocab += sorted(HOST_FORMS.keys() - set(vocab))
    vocab += sorted(l10n_words(repo) - set(vocab))
    print("vocabulary: %d (freq %d, literary +%d, numbers/hosts/l10n rest)"
          % (len(vocab), len(dict.fromkeys(freq)),
             len(lit - set(freq))))

    # 2. phonemize
    ipa = espeak_ipa_batch(vocab, args.espeak)
    kept, unmapped, empty = {}, 0, 0
    for w in vocab:
        t = ipa.get(w, "")
        if not t:
            empty += 1
            continue
        if ipa_mappable(t, fr_map):
            kept[w] = t
        else:
            unmapped += 1
    # host forms override whatever espeak said about bare letters
    kept.update(HOST_FORMS)

    # 3. pack (with budget truncation on the frequency-ordered prefix)
    order = [w for w in vocab if w in kept]
    while True:
        sub = {w: kept[w] for w in order}
        blob, block_off, symbols, code_of, n = pack(sub, fr_map)
        total = len(blob) + 4 * len(block_off)
        if total <= args.max_bytes or len(order) < 1000:
            break
        order = order[:int(len(order) * 0.9)]
        print("over budget (%d B); truncating to %d entries"
              % (total, len(order)))

    stats = {
        "kept": len(kept),
        "unmappable_ipa_dropped": unmapped,
        "empty_ipa_dropped": empty,
        "fr_map_entries": len(fr_map),
        "symbols": len(symbols),
        "packed_entries": n,
    }
    srcs = []
    for name in ("fr_full.txt", "meunier.txt", "balzac1.txt"):
        p = os.path.join(src, name)
        if os.path.exists(p):
            h = hashlib.sha256(open(p, "rb").read()).hexdigest()
            srcs.append("%s sha256 %s" % (name, h))
    emit(repo, blob, block_off, symbols, fr_map, n, stats, srcs, args.check)


if __name__ == "__main__":
    main()
