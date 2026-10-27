/* dev/g2p_corpus_oov.c -- corpus OOV gate for the --g2p nano lexicon.
 *
 * Reads plain text on stdin, splits it into clause-sized pieces the same
 * way the server does (sentence punctuation, then word-boundary chunks of
 * at most 480 codepoints), runs the in-process lexicon G2P per piece, and
 * reports:
 *   - pieces, OOV words, lexicon words, token OOV rate;
 *   - the fraction of pieces the server would route to the espeak
 *     fallback at a given --g2p-oov-threshold (argv[1], default 0.25).
 *
 * This measures the G2P alone (no synthesis), so a full novel takes
 * seconds. Build from the repo root:
 *
 *   cc -O2 -std=c99 -o g2p_corpus_oov dev/g2p_corpus_oov.c \
 *     sanotts/nano_lex_g2p.c sanotts/nano_lex_tables.c -I sanotts -lm
 *
 * (dev/snt-g2p-gate.sh wraps the build and the corpus fetch.)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "nano_lex_g2p.h"
#include "nano_lex_fr.h"

/* Word-boundary chunking, mirroring g2p_nano_clause() in snt_server.c. */
static long oov_total, lex_total, pieces, pieces_fallback;
static float threshold = 0.25f;

static int use_fr;
static long spoken_words;   /* words that produced audio (en: total-oov) */

static void run_piece(const char *chunk) {
    char ph[8192];
    int rc;
    if (use_fr) {
        nano_lex_fr_stats_t st;
        rc = nano_lex_fr_text_to_phonemes(chunk, ph, sizeof ph);
        nano_lex_fr_get_stats(&st);
        oov_total += st.oov_words;
        lex_total += st.lexicon_words;
        pieces++;
        if (st.lexicon_words > 0 &&
            (float)st.oov_words / (float)st.lexicon_words > threshold)
            pieces_fallback++;
        return;
    }
    nano_lex_g2p_stats_t st;
    rc = nano_lex_g2p_text_to_phonemes(chunk, ph, sizeof ph);
    nano_lex_g2p_get_stats(&st);
    oov_total += st.oov_words;
    lex_total += st.lexicon_words;
    pieces++;
    if (st.lexicon_words > 0 &&
        (float)st.oov_words / (float)st.lexicon_words > threshold)
        pieces_fallback++;
    (void)rc;
}

static void run_text(const char *text) {
    int off = 0, n = (int)strlen(text);
    while (off < n) {
        int take = n - off;
        if (take > 480) {
            take = 480;
            int cut = off + take;
            while (cut > off + 64 && text[cut] != ' ') cut--;
            take = cut - off;
        }
        while (off < n && text[off] == ' ') off++;
        if (off >= n) break;
        char chunk[512];
        memcpy(chunk, text + off, (size_t)take);
        chunk[take] = 0;
        off += take;
        run_piece(chunk);
    }
}

int main(int argc, char **argv) {
    int argi = 1;
    if (argi < argc && !strcmp(argv[argi], "--fr")) { use_fr = 1; argi++; }
    if (argi < argc) threshold = (float)atof(argv[argi]);
    /* Slurp stdin (cap 64 MB). */
    size_t cap = 1 << 20, len = 0;
    char *buf = malloc(cap);
    size_t r;
    while ((r = fread(buf + len, 1, cap - len - 1, stdin)) > 0) {
        len += r;
        if (cap - len < 2) { cap *= 2; buf = realloc(buf, cap); }
    }
    buf[len] = 0;
    /* Clause split at sentence punctuation, same set as the server's
     * clause splitter. */
    const char *p = buf;
    while (*p) {
        size_t l = strcspn(p, ".!?");

        if (l == 0) { p++; continue; }
        char piece[65536];
        size_t take = l < sizeof piece - 1 ? l : sizeof piece - 1;
        memcpy(piece, p, take);
        piece[take] = 0;
        p += take;
        /* Skip Gutenberg boilerplate runs of ALL-CAPS lines cheaply: they
         * measure like ordinary text, leave them in. */
        run_text(piece);
    }
    printf("pieces=%ld oov=%ld lex=%ld token_oov_pct=%.2f fallback_pct=%.2f (threshold %.2f)\n",
           pieces, oov_total, lex_total,
           lex_total ? 100.0 * oov_total / lex_total : 0.0,
           pieces ? 100.0 * pieces_fallback / pieces : 0.0,
           threshold);
    return 0;
}
