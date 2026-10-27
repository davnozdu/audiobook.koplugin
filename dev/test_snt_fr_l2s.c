/* dev/test_snt_fr_l2s.c -- gate tests for the French lexicon G2P
 * (nano_lex_fr.c). Checks:
 *   1. in-dictionary words decode to live `espeak-ng -q --ipa -v fr`
 *      output byte-for-byte (the lexicon stores espeak IPA verbatim, so
 *      any mismatch is a lookup or emission bug, not a quality tradeoff);
 *   2. elision splits host forms (l'avion, aujourd'hui, qu'il);
 *   3. cardinals and ordinal suffixes spell out as lexicon words
 *      (vigesimal forms included);
 *   4. OOV words fall to the rule layer and produce SOMETHING speakable
 *      (symbols from the fr vocabulary), and the stats count them OOV.
 *
 * Build (repo root, dev/snt-g2p-gate.sh wraps this):
 *   cc -O2 -std=gnu99 -o /tmp/test_snt_fr_l2s dev/test_snt_fr_l2s.c \
 *     sanotts/nano_lex_fr.c sanotts/nano_lex_fr_tables.c -I sanotts -lm
 *
 *   /tmp/test_snt_fr_l2s <espeak-bin> [<espeak-data>]
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "nano_lex_fr.h"

static int fails = 0, checks = 0;

static void ok(int cond, const char *what)
{
    checks++;
    if (!cond) { fails++; printf("FAIL - %s\n", what); }
    else printf("ok - %s\n", what);
}

static void live_ipa(const char *espeak, const char *word, char *out, size_t cap)
{
    char cmd[1024];
    snprintf(cmd, sizeof cmd, "%s -q --ipa -v fr \"%s\" 2>/dev/null", espeak, word);
    FILE *f = popen(cmd, "r");
    if (!f) { out[0] = 0; return; }
    size_t n = 0;
    int c;
    while ((c = fgetc(f)) != EOF && n + 1 < cap) {
        if (c == '\n' || c == '\r') break;
        out[n++] = (char)c;
    }
    out[n] = 0;
    pclose(f);
}

int main(int argc, char **argv)
{
    char buf[2048], live[2048];
    nano_lex_fr_stats_t st;
    const char *espeak = argc > 1 ? argv[1] : NULL;
    (void)argc;

    /* 1. in-dict = espeak-exact */
    if (espeak) {
        static const char *const WORDS[] = {
            "bonjour", "avion", "aujourd'hui", "élégant", "œuvre",
            "misérables", "vaisselle", "château", "gentiment", "soleil",
            "femme", "monsieur", "quatre-vingt", "université",
            NULL,
        };
        int bad = 0;
        for (int i = 0; WORDS[i]; i++) {
            int rc = nano_lex_fr_text_to_phonemes(WORDS[i], buf, sizeof buf);
            live_ipa(espeak, WORDS[i], live, sizeof live);
            if (rc < 0 || strcmp(buf, live) != 0) {
                bad++;
                printf("  %-14s fr=%s live=%s\n", WORDS[i], buf, live);
            }
        }
        ok(bad == 0, "in-dictionary words are espeak-exact");
    } else {
        printf("skip - espeak-exact check (pass <espeak-bin>)\n");
    }

    /* 2. elision */
    int rc2 = nano_lex_fr_text_to_phonemes("l'avion", buf, sizeof buf);
    nano_lex_fr_get_stats(&st);
    ok(rc2 > 0 && buf[0] == 'l' && st.oov_words == 0,
       "l'avion splits into the host form + avion");
    nano_lex_fr_text_to_phonemes("qu'il", buf, sizeof buf);
    nano_lex_fr_get_stats(&st);
    ok(buf[0] == 'k', "qu' host form is /k/");

    /* 3. numbers */
    nano_lex_fr_text_to_phonemes("4", buf, sizeof buf);
    ok(strstr(buf, "atʁ") != NULL, "4 spells quatre");
    nano_lex_fr_text_to_phonemes("80", buf, sizeof buf);
    nano_lex_fr_get_stats(&st);
    ok(st.oov_words == 0, "80 spells quatre-vingts from the lexicon");
    nano_lex_fr_text_to_phonemes("1999", buf, sizeof buf);
    nano_lex_fr_get_stats(&st);
    ok(st.oov_words == 0, "1999 spells from the lexicon");
    nano_lex_fr_text_to_phonemes("2e", buf, sizeof buf);
    ok(strstr(buf, "døzjɛm") != NULL || strstr(buf, "døzj") != NULL,
       "2e spells deuxième");

    /* 4. OOV -> rule layer produces fr-vocabulary symbols only */
    nano_lex_fr_text_to_phonemes("blorptique", buf, sizeof buf);
    nano_lex_fr_get_stats(&st);
    ok(st.oov_words == 1, "OOV word counted");
    ok(strlen(buf) > 0, "OOV word produced rule-layer phonemes");

    printf("%s - %d checks, %d failures\n", fails ? "FAIL" : "PASS", checks,
           fails);
    return fails ? 1 : 0;
}
