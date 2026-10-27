/* dev/test_g2p_adapter.c -- golden gate for the --g2p nano adapter.
 *
 * Pins, in one place:
 *   1. every symbol of the nano 62-symbol vocabulary maps through the
 *      adapter exactly as documented: pass-through symbols keep their piper
 *      map id, the nine misaki-specific symbols expand to their espeak
 *      en-us IPA equivalents (A->eɪ, I->aɪ, O->oʊ, W->aʊ, Y->ɔɪ, T->ɾ,
 *      ʤ->dʒ, ʧ->tʃ, ᵊ->ə), and the four symbols espeak's own IPA also
 *      drops (em dash, curly quotes, ellipsis) vanish;
 *   2. end-to-end ids for a known clause: framing, the literal spot ids,
 *      and one word-separator id per word join (what the timing sidecar's
 *      word spans hang off);
 *   3. the native-punct variant interleaves punctuation ids at the text
 *      level;
 *   4. the per-clause OOV fallback fires on an all-OOV clause and on a
 *      clause above --g2p-oov-threshold, but not on in-dict text (needs a
 *      host espeak-ng; skipped gracefully when no espeak args are given).
 *
 * The whole server is compiled into this test (main renamed) so the static
 * adapter functions are callable directly. Build from the repo root:
 *
 *   cc -O2 -std=c99 -w \
 *     -I sanotts/mcu/include -I sanotts/mcu/src -I sanotts/voice-nano \
 *     -DFSD_FAST_MATH -o /tmp/test_g2p_adapter dev/test_g2p_adapter.c \
 *     sanotts/mcu/src/snt_tts.c sanotts/mcu/src/snt_kernels_ref.c \
 *     sanotts/mcu/src/snt_nano.c sanotts/mcu/src/snt_front_q8.c \
 *     sanotts/mcu/src/snt_piperlite_q8.c sanotts/mcu/src/snt_front_f32.c \
 *     sanotts/mcu/src/snt_piperlite.c sanotts/mcu/ports/host/snt_port_host.c \
 *     sanotts/nano_lex_g2p.c sanotts/nano_lex_tables.c -lm
 *
 *   /tmp/test_g2p_adapter [<espeak-bin> <espeak-data>]
 * (dev/snt-g2p-gate.sh wraps the build and the run.)
 */

#include <stdio.h>
#include <string.h>

#include "../sanotts/nano_lex_tables.h"   /* NANO_LEX_PH_UTF8 vocabulary dump */

#define main snt_server_main_unused
#include "../sanotts/snt_server.c"
#undef main

static int fails = 0;
static int checks = 0;

static void ok(int cond, const char *what) {
    checks++;
    if (!cond) {
        fails++;
        printf("FAIL - %s\n", what);
    } else {
        printf("ok - %s\n", what);
    }
}

/* Build the expected (id, PAD) stream for one symbol the way the adapter
 * documents it, without calling the adapter. */
static int expected_ids_for_sym(const char *sym, int32_t *out) {
    int n = 0;
    for (size_t k = 0; k < sizeof NANO_PIPER_EXP / sizeof NANO_PIPER_EXP[0];
         k++) {
        if (!strcmp(NANO_PIPER_EXP[k].sym, sym)) {
            for (int j = 0; NANO_PIPER_EXP[k].exp[j]; j++) {
                int id = map_id(NANO_PIPER_EXP[k].exp[j]);
                if (id >= 0) {
                    out[n++] = id;
                    out[n++] = PAD_ID;
                }
            }
            return n;
        }
    }
    int id = map_id(sym);
    if (id >= 0) {
        out[n++] = id;
        out[n++] = PAD_ID;
    }
    return n;
}

int main(int argc, char **argv) {
    int32_t ids[MAX_IDS];
    int32_t want[MAX_IDS];

    /* 1. every vocabulary symbol maps as documented */
    for (int i = 0; i < 63; i++) {
        const char *sym = NANO_LEX_PH_UTF8[i];
        if (!sym || !sym[0]) continue;
        int n = 0;
        append_nano_ids(sym, ids, &n);
        int wn = expected_ids_for_sym(sym, want);
        char what[128];
        snprintf(what, sizeof what, "sym [%s] -> %d id pairs", sym, wn / 2);
        if (n != wn || (n && memcmp(ids, want, (size_t)n * sizeof(int32_t)))) {
            fails++;
            checks++;
            printf("FAIL - %s (got %d pairs, first ids %d,%d)\n", what, n / 2,
                   n > 1 ? ids[0] : -1, n > 1 ? ids[1] : -1);
        } else {
            checks++;
            printf("ok - %s\n", what);
        }
    }

    /* 2. end-to-end: framing, spot ids, one separator per word join */
    int n = text_to_ids_nano("hello world", ids, -1);
    ok(n > 0, "text_to_ids_nano returns a stream");
    ok(ids[0] == BOS_ID && ids[1] == PAD_ID && ids[n - 1] == EOS_ID,
       "framing is BOS PAD ... EOS");
    int seps = 0;
    for (int i = 0; i < n; i++)
        if (ids[i] == WORD_SEP_ID) seps++;
    ok(seps == 1, "one word separator between the two words");
    /* literal spot ids from the piper en map (pinned, not derived): */
    int have_ə = 0, have_ˈ = 0, have_o = 0, have_ʊ = 0, have_ɜ = 0, have_ɹ = 0;
    for (int i = 0; i < n; i++) {
        if (ids[i] == 59) have_ə = 1;      /* ə */
        if (ids[i] == 120) have_ˈ = 1;     /* ˈ */
        if (ids[i] == 27) have_o = 1;      /* o (from the O expansion) */
        if (ids[i] == 100) have_ʊ = 1;     /* ʊ (from the O expansion) */
        if (ids[i] == 62) have_ɜ = 1;      /* ɜ */
        if (ids[i] == 88) have_ɹ = 1;      /* ɹ */
    }
    ok(have_ə && have_ˈ && have_o && have_ʊ && have_ɜ && have_ɹ,
       "spot ids present (ə ˈ o ʊ from expansions, ɜ ɹ passthrough)");

    /* word spans derive from the same stream */
    SntWordSpan spans[8];
    int32_t durs[MAX_IDS];
    for (int i = 0; i < n; i++) durs[i] = 1;
    int nspans = word_spans_from_ids(ids, durs, n, spans, 8);
    ok(nspans == 2, "two word spans from a two-word clause");

    /* 3. native-punct variant interleaves punctuation ids */
    n = text_to_ids_nano_native("hello, world.", ids);
    ok(n > 0, "native variant returns a stream");
    int have_comma = 0, have_period = 0;
    for (int i = 0; i < n; i++) {
        if (ids[i] == 8) have_comma = 1;    /* , */
        if (ids[i] == 10) have_period = 1;  /* . */
    }
    ok(have_comma && have_period, "comma and period ids interleaved");

    /* 4. OOV fallback (needs espeak args) */
    if (argc >= 3) {
        g_espeak_bin = argv[1];
        g_espeak_data = argv[2];
        n = text_to_ids_nano("Zyxwv", ids, -1);
        ok(n == NANO_G2P_FALLBACK, "all-OOV clause falls back to espeak");
        n = text_to_ids_nano("Zyxwv hello", ids, -1);
        ok(n == NANO_G2P_FALLBACK,
           "clause above the 0.25 OOV threshold falls back");
        g_g2p_oov_threshold = 1.1f;
        n = text_to_ids_nano("Zyxwv hello", ids, -1);
        ok(n > 0 && n != NANO_G2P_FALLBACK,
           "threshold above 1 keeps the clause on the nano path");
        g_g2p_oov_threshold = 0.25f;
        n = text_to_ids_nano("hello world", ids, -1);
        ok(n > 0 && n != NANO_G2P_FALLBACK, "in-dict clause stays on nano");
    } else {
        printf("skip - OOV fallback checks (pass <espeak-bin> <espeak-data>)\n");
    }

    printf("%s - %d checks, %d failures\n", fails ? "FAIL" : "PASS", checks,
           fails);
    return fails ? 1 : 0;
}
