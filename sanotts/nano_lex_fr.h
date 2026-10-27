/* nano_lex_fr.h -- espeak-free French text -> fr-piper phoneme string.
 *
 * Dictionary-first French G2P over the packed lexicon in
 * nano_lex_fr_tables.c (tools/gen_fr_lex_tables.py). In-dictionary words
 * are espeak-exact by construction: the lexicon stores espeak-ng fr IPA
 * verbatim, and the fr f32 voice (fr-siwis) was trained on espeak-derived
 * ids. Words that are not in the dictionary go through a compact
 * letter-to-sound rule layer (best effort, counted in the stats) -- the
 * shipped OOV path is the per-clause espeak fallback in snt_server.c, so
 * the rule layer only fires when espeak args are absent entirely.
 *
 * FORMAT: same packed-blob dictionary as nano_lex_tables.c (bias '0',
 * front-coded blocks of 8, PLAIN vcode). The lookup here is deliberately a
 * small self-contained copy of that walk rather than a shared TU: the
 * format is pinned by golden tests on both sides (dev/test_g2p_adapter.c
 * for en, dev/test_snt_fr_l2s.c for fr), so a format change cannot drift
 * silently.
 *
 * MEMORY: tables are const (.rodata); the module's own scratch is static,
 * there is no malloc and no run-time allocation.
 * REENTRANCY: not reentrant (one request loop, like nano_lex_g2p).
 */

#ifndef NANO_LEX_FR_H
#define NANO_LEX_FR_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Reuses the nano_lex_g2p error-code values where the causes match. */
#define NFR_OK              0
#define NFR_E_NULL_ARG      (-1)
#define NFR_E_BAD_CAP       (-2)
#define NFR_E_EMPTY_TEXT    (-3)
#define NFR_E_BAD_UTF8      (-4)
#define NFR_E_TEXT_LONG     (-5)
#define NFR_E_CAP           (-9)

/* Counters describing the last nano_lex_fr_text_to_phonemes() call. Same
 * fields and meanings as nano_lex_g2p_stats_t. */
typedef struct {
    uint16_t tokens;          /* word/number groups seen */
    uint16_t lexicon_words;   /* word groups the lexicon was asked about */
    uint16_t oov_words;       /* of those, ones that produced no phonemes */
    uint16_t chunks;          /* pieces the caller split off */
    uint16_t dropped;         /* phonemes the emission had to truncate */
    uint16_t arena_peak;      /* high-water mark of the phoneme buffer */
} nano_lex_fr_stats_t;

void nano_lex_fr_get_stats(nano_lex_fr_stats_t *out);

/* text -> UTF-8 phoneme string (espeak fr IPA). Apostrophe elision splits
 * host forms ("l'avion" -> l + avion), digit runs spell out as French
 * cardinals (vigesimal, 0..999999, longer numbers read digit-wise), and
 * "N.er"/"N.ème"-style ordinal suffixes map to premier/-ième forms.
 * Returns the byte count written excluding the NUL, or a negative NFR_*
 * code; on NFR_E_CAP a truncated but well-formed prefix is in the buffer.
 */
int nano_lex_fr_text_to_phonemes(const char *text, char *out, size_t cap);

/* Human-readable name for a code from this module. */
const char *nano_lex_fr_strerror(int rc);

#endif /* NANO_LEX_FR_H */
