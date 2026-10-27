/* snt_server.c -- sanoTTS engine server for audiobook.koplugin.
 * Piper-shaped line protocol on stdin: {"input": "text", "output": "path.wav"}
 * per line; synthesizes and prints the WAV path alone on stdout.
 *
 * Three engines, selected with --engine:
 *   int8 (default)  kristin-class R7 voice, 22050 Hz. Phonemization: the
 *                   bundled espeak-ng binary (per-sentence spawn) produces IPA,
 *                   then piper's phoneme_id_map (phoneme_id_map.h) with
 *                   BOS/PAD/EOS framing, matching piper.phoneme_ids exactly.
 *   pq8             piperlite voice, fully int8 (snt_front_q8 +
 *                   snt_piperlite_q8), 22050 Hz. All dimensions come out of
 *                   the blobs, so one binary serves any exported voice; the
 *                   model dir holds front_meta_q8.bin, front_weights_q8.bin,
 *                   meta_q8.bin and weights_q8.bin. --length-scale warps the
 *                   durations (1.0 native speed). Phonemization as for int8.
 *   nano            heart-nano voice (294K params), 24000 Hz, snt_nano
 *                   runtime. Phonemization: the espeak-free lexicon G2P
 *                   (nano_lex_g2p.c, misaki dictionary data, Apache-2.0)
 *                   emits dense BOS/EOS-framed ids for the 62-symbol vocab;
 *                   no espeak spawn at all. Noise is seeded from the clause
 *                   text, or --seed forces one value.
 *   f32             fp32 piperlite voice (snt_front_f32 + snt_piperlite),
 *                   22050 Hz. Same family as pq8 but at fp32 precision and
 *                   with the fp32 kernel pair; the model dir holds
 *                   front_meta.bin, front_weights_f32.bin, dec_meta.bin and
 *                   dec_weights_f32.bin, converted from upstream's fp16
 *                   voice packages by tools/convert-sanotts-voice.py. This
 *                   is the engine for the non-English voices (fr-siwis and
 *                   later siblings). Phonemization as for int8, with the
 *                   espeak voice and phoneme id map chosen per language
 *                   (--voice, --phonemes).
 *
 * Usage: snt_server --model <dir> --engine int8|pq8|nano|f32
 *                   [--espeak-bin <bin> --espeak-data <dir> --voice en-us]
 *                   [--phonemes en|fr]
 *                   [--rate 22050|24000] [--loader <ld-linux>]
 *                   [--loader-libdir <dir>] [--comma-ms N] [--period-ms N]
 *                   [--seed N] [--length-scale F]
 * The espeak/loader args apply to the int8/pq8/f32 engines only (the loader execs
 * the bundled armhf espeak-ng through the bundled glibc loader on stock Kobo
 * rootfs); the gap args size the silence inserted after comma/period clauses
 * (defaults 150/350 ms; colon 220, semicolon 250).
 * Timing sidecar (pq8, f32 and int8). Alongside each WAV, "<wav>.timing" is
 * written with the word boundaries the duration student already produced,
 * then immediately discarded by the old code. Line-oriented ASCII integers:
 *
 *   sntt 1 <rate> <hop> <total_samples> <n_clauses> <n_words>
 *   c <j> <char_start> <char_end> <punct> <sample_start> <sample_end> <word0> <nwords>
 *   w <i> <start_sample> <end_sample>
 *
 * The magic and version are the capability flag. Each "c" record gives a
 * clause's absolute sample span in the WAV and its character territory in the
 * input string; "w" records are the clause's word spans, in stream order.
 * Word boundaries come from phoneme id 3 (the piper maps' ' ' separator) and
 * framing is found by position, not by id value, since both maps alias '^' to
 * BOS and '$' to EOS. The audio is bit-identical with or without this file:
 * every value is read out of arrays synthesis already computed.
 *
 * The pq8 and f32 voices embed fewer phoneme ids than the maps carry, so ids
 * at or above the voice's d_vocab are dropped before synthesis (see
 * drop_oov_ids); espeak's syllabic-consonant mark is the common case and
 * otherwise costs words like "little" and "certain".
 *
 * Sources: sanoTTS mcu core and nano lexicon G2P (MIT/Apache-2.0), server
 * written for the audiobook.koplugin spike. */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "snt_tts.h"
#include "snt_nano.h"
#include "snt_front_q8.h"
#include "snt_piperlite_q8.h"
#include "snt_front_f32.h"
#include "snt_piperlite.h"
#include "phoneme_id_map.h"
#include "phoneme_id_map_fr.h"
#include "nano_lex_g2p.h"
#include "nano_lex_fr.h"

#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/wait.h>

#define BOS_ID 1
#define EOS_ID 2
#define PAD_ID 0
#define MAX_IDS 1024
/* The piper maps alias ' ' to 3 in every language, and it is the only
 * symbol that maps there, so id 3 marks a word boundary in the token
 * stream. */
#define WORD_SEP_ID 3
/* The int8 (R7) engine's frame hop: FSD_HOP in the mcu core. */
#define INT8_HOP 256
/* A clause can hold at most MAX_IDS/2 phones, so at most that many words. */
#define MAX_WORDS 512
/* Per-word span, in frames while the ids are being walked and converted to
 * absolute WAV samples before it is published. */
typedef struct { long start, end; } SntWordSpan;

static void *xload2s(const char *dir, const char *name, size_t *out_bytes);

static void *xload2(const char *dir, const char *name) {
    return xload2s(dir, name, NULL);
}

static void *xload2s(const char *dir, const char *name, size_t *out_bytes) {
    char path[512];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    FILE *fh = fopen(path, "rb");
    if (!fh) { fprintf(stderr, "{\"error\": \"missing %s\"}\n", path); exit(1); }
    fseek(fh, 0, SEEK_END);
    long sz = ftell(fh);
    fseek(fh, 0, SEEK_SET);
    void *buf = malloc((size_t)sz);
    if (!buf || fread(buf, 1, (size_t)sz, fh) != (size_t)sz) { fprintf(stderr, "{\"error\": \"short read %s\"}\n", path); exit(1); }
    fclose(fh);
    if (out_bytes) *out_bytes = (size_t)sz;
    return buf;
}

static void put_u32(FILE *fh, uint32_t v) { fwrite(&v, 4, 1, fh); }
static void put_u16(FILE *fh, uint16_t v) { fwrite(&v, 2, 1, fh); }

typedef struct { FILE *fh; long n; } WavSink;

static int wav_cb(const float *pcm, int count, void *user) {
    WavSink *w = (WavSink *)user;
    for (int i = 0; i < count; i++) {
        float s = pcm[i];
        if (s > 1.0f) s = 1.0f;
        else if (s < -1.0f) s = -1.0f;
        int16_t v = (int16_t)(s * 32767.0f);
        if (fwrite(&v, sizeof v, 1, w->fh) != 1) return 1;
        w->n++;
    }
    return 0;
}

static void write_header(FILE *fh, uint32_t data_bytes, uint32_t rate) {
    uint32_t chunk = 36 + data_bytes, byte_rate = rate * 2;
    uint16_t fmt = 1, chan = 1, align = 2, bits = 16;
    fwrite("RIFF", 1, 4, fh); put_u32(fh, chunk); fwrite("WAVE", 1, 4, fh);
    fwrite("fmt ", 1, 4, fh); put_u32(fh, 16);
    put_u16(fh, fmt); put_u16(fh, chan); put_u32(fh, rate); put_u32(fh, byte_rate);
    put_u16(fh, align); put_u16(fh, bits);
    fwrite("data", 1, 4, fh); put_u32(fh, data_bytes);
}

/* phoneme id map: piper's first ~20 ids are ASCII punctuation in every
 * language, so the punctuation-aware splitting and the pause ids
 * (4, 8, 10..13) are shared across maps. */
static const PIPER_PMAP_ENT *g_map = PHONEME_MAP;
static int g_map_n = PHONEME_MAP_N;

static int map_id(const char *sym) {
    for (int i = 0; i < g_map_n; i++)
        if (!strcmp(g_map[i].sym, sym)) return g_map[i].id;
    return -1;
}

static int utf8_len(unsigned char b) {
    if (b < 0x80) return 1;
    if ((b & 0xE0) == 0xC0) return 2;
    if ((b & 0xF0) == 0xE0) return 3;
    if ((b & 0xF8) == 0xF0) return 4;
    return 0;
}

static const char *g_espeak_bin, *g_espeak_data, *g_voice = "en-us";
static const char *g_loader, *g_libdir;
static int g_comma_ms = 150, g_period_ms = 350, g_colon_ms = 220, g_semi_ms = 250;
static int g_engine_nano = 0;
static int g_engine_pq8 = 0;
static int g_engine_f32 = 0;
static int g_native_punct = 0;
static int g_g2p_nano = 0;              /* --g2p nano: in-process lexicon G2P */
static float g_g2p_oov_threshold = 0.25f;
static long g_g2p_nano_clauses, g_g2p_espeak_clauses;
static long g_g2p_oov_words, g_g2p_lex_words;
static float g_length_scale = 1.0f;
static float g_pause_scale = 1.0f;
static uint64_t g_seed;
static int g_seed_set = 0;

/* Run the bundled espeak-ng binary on a sentence, return its IPA output
 * (malloc'd). The binary reads stdin when no text argument is given. */
static char *phonemize_via_binary(const char *espeak_bin, const char *espeak_data, const char *voice, const char *text) {
    int in_pipe[2], out_pipe[2];
    if (pipe(in_pipe) || pipe(out_pipe)) return NULL;
    pid_t pid = fork();
    if (pid < 0) return NULL;
    if (pid == 0) {
        dup2(in_pipe[0], 0);
        dup2(out_pipe[1], 1);
        close(in_pipe[0]); close(in_pipe[1]);
        close(out_pipe[0]); close(out_pipe[1]);
        setenv("ESPEAK_DATA_PATH", espeak_data, 1);
        if (g_loader) {
            char lp[1024], dirbuf[512];
            snprintf(lp, sizeof lp, "%s:%s:/usr/lib:/lib", g_libdir ? g_libdir : "/usr/lib:/lib", g_libdir ? g_libdir : "");
            snprintf(dirbuf, sizeof dirbuf, "%s", g_libdir ? g_libdir : "");
            if (g_libdir && g_libdir[0])
                setenv("LD_LIBRARY_PATH", g_libdir, 1);
            execl(g_loader, g_loader, "--library-path", g_libdir ? g_libdir : "", espeak_bin, "-q", "--ipa", "-v", voice, (char *)NULL);
        } else {
            execl(espeak_bin, espeak_bin, "-q", "--ipa", "-v", voice, (char *)NULL);
        }
        _exit(127);
    }
    close(in_pipe[0]); close(out_pipe[1]);
    size_t cap = 4096, len = 0;
    char *ipa = malloc(cap);
    /* write sentence, then close so the child sees EOF */
    size_t tlen = strlen(text);
    if (write(in_pipe[1], text, tlen) != (ssize_t)tlen) { /* ignore short writes from EPIPE */ }
    close(in_pipe[1]);
    ssize_t r;
    while ((r = read(out_pipe[0], ipa + len, cap - len)) > 0) {
        len += (size_t)r;
        if (cap - len < 1024) { cap *= 2; ipa = realloc(ipa, cap); }
    }
    close(out_pipe[0]);
    waitpid(pid, NULL, 0);
    if (len == 0) { free(ipa); return NULL; }
    ipa[len] = 0;
    return ipa;
}

/* text -> piper phoneme ids: [BOS, PAD, (id, PAD)*, EOS] via espeak-ng IPA.
 * punct_id >= 0 appends the punctuation mark's own id before EOS so the
 * model renders its native terminal contour for the clause. */
static int text_to_ids(const char *text, int32_t *ids, int punct_id) {
    int n = 0;
    ids[n++] = BOS_ID;
    ids[n++] = PAD_ID;
    char *ipa = phonemize_via_binary(g_espeak_bin, g_espeak_data, g_voice, text);
    if (!ipa) return -1;
    for (const unsigned char *q = (const unsigned char *)ipa; *q; ) {
        int len = utf8_len(*q);
        if (len <= 0 || len > 7) { q++; continue; }
        char sym[8];
        memcpy(sym, q, (size_t)len);
        sym[len] = 0;
        int id = map_id(sym);
        if (id >= 0 && n < MAX_IDS - 2) {
            ids[n++] = id;
            ids[n++] = PAD_ID;
        }
        q += len;
    }
    free(ipa);
    if (punct_id >= 0 && n < MAX_IDS - 2) {
        ids[n++] = punct_id;
        ids[n++] = PAD_ID;
    }
    if (n > MAX_IDS - 1) n = MAX_IDS - 1;
    ids[n++] = EOS_ID;
    return n;
}

/* Drop tokens the voice cannot embed, in place. Returns the new token count.
 *
 * The phoneme maps are wider than the voices: the en map and the fr map both
 * carry 154 entries reaching id 153, while the pq8/f32 duration embedding was
 * trained on far fewer rows (the amy voice has d_vocab 129). An id at or above
 * d_vocab makes fq_embed_row reject the token, which fails the whole clause
 * with rc -3 and leaves the request with truncated or header-only audio.
 *
 * The common trigger is espeak's syllabic-consonant mark (id 144), which it
 * emits for ordinary words like "little", "button", "certain" and "garden",
 * so the default voice silently loses those sentences without this.
 *
 * A dropped token's trailing PAD goes with it, keeping the (id, PAD) shape the
 * model expects. The model never saw these ids, so removing them moves the
 * stream toward what it was trained on rather than away from it. The int8 and
 * nano engines do not go through here: their runtimes either expose no vocab
 * to check against or handle these ids already. */
static int drop_oov_ids(int32_t *ids, int n_ids, int vocab) {
    int n = 0;
    for (int i = 0; i < n_ids; i++) {
        if (ids[i] != PAD_ID && (ids[i] < 0 || ids[i] >= vocab)) {
            if (i + 1 < n_ids && ids[i + 1] == PAD_ID) i++;
            continue;
        }
        ids[n++] = ids[i];
    }
    return n;
}

/* Append one IPA string's ids to the stream (helper for text_to_ids_native). */
static void append_ipa_ids(const char *ipa, int32_t *ids, int *n) {
    for (const unsigned char *q = (const unsigned char *)ipa; *q; ) {
        int len = utf8_len(*q);
        if (len <= 0 || len > 7) { q++; continue; }
        char sym[8];
        memcpy(sym, q, (size_t)len);
        sym[len] = 0;
        int id = map_id(sym);
        if (id >= 0 && *n < MAX_IDS - 2) {
            ids[(*n)++] = id;
            ids[(*n)++] = PAD_ID;
        }
        q += len;
    }
}

/* Piper-style punctuation awareness (piper.phonemize_espeak behavior): the
 * text is split at . , ? ! : ;, each piece is phonemized separately, and the
 * punctuation mark's own id is emitted between pieces so the model renders
 * its native pauses and terminal contours (rising for ?, falling for .).
 * espeak's IPA output drops punctuation entirely, so the ids have to be
 * interleaved at the text level. */
static int text_to_ids_native(const char *text, int32_t *ids) {
    int n = 0;
    ids[n++] = BOS_ID;
    ids[n++] = PAD_ID;
    const char *p = text;
    while (*p && n < MAX_IDS - 2) {
        char c = *p;
        if (c == '.' || c == ',' || c == '?' || c == '!' || c == ':' || c == ';') {
            char sym[2] = { c, 0 };
            int id = map_id(sym);
            if (id >= 0) {
                ids[n++] = id;
                ids[n++] = PAD_ID;
            }
            p++;
            continue;
        }
        size_t len = strcspn(p, ".,!?;:");
        if (len == 0) { p++; continue; }
        char piece[2048];
        if (len > sizeof piece - 1) len = sizeof piece - 1;
        memcpy(piece, p, len);
        piece[len] = 0;
        p += len;
        char *ipa = phonemize_via_binary(g_espeak_bin, g_espeak_data, g_voice, piece);
        if (ipa) {
            append_ipa_ids(ipa, ids, &n);
            free(ipa);
        }
    }
    if (n > MAX_IDS - 1) n = MAX_IDS - 1;
    ids[n++] = EOS_ID;
    return n;
}

/* ---- in-process lexicon G2P (--g2p nano, int8/pq8/f32) ------------------
 *
 * The neural engines' phonemizer is espeak-ng by default:
 * phonemize_via_binary fork+execs the bundled binary once per clause.
 * --g2p nano replaces that with the in-process misaki lexicon G2P
 * (nano_lex_g2p.c: no espeak, no fork, dictionary-first). The engines
 * synthesize from piper-map ids either way, so only the phoneme source
 * changes.
 *
 * nano_lex_g2p emits a UTF-8 phoneme STRING in its own 62-symbol
 * vocabulary. Nearly all of it walks map_id() unchanged (shared symbols
 * carry the same sound in both vocabularies). The symbols the piper map
 * lacks get their espeak en-us IPA equivalents, verified symbol-for-symbol
 * against espeak-ng --ipa -v en-us output and pinned by
 * dev/test_g2p_adapter.c:
 *   A (FACE)   -> e ɪ      I (PRICE) -> a ɪ     O (GOAT)  -> o ʊ
 *   W (MOUTH)  -> a ʊ      Y (CHOICE)-> ɔ ɪ     T (flap)  -> ɾ
 *   ʤ -> d ʒ    ʧ -> t ʃ    ᵊ (syllabic mark)  -> ə
 * Em dash, curly quotes and ellipsis map nowhere and are skipped, exactly
 * like espeak's own IPA output drops them.
 *
 * Word boundaries survive intact (one space symbol per word join), so the
 * timing sidecar's word spans come out finer than espeak's, which merges
 * neighbouring words in roughly a quarter of sentences.
 *
 * Out-of-vocabulary words contribute no phonemes (a counted outcome of
 * the lexicon design, not a failure). A clause whose OOV ratio crosses
 * --g2p-oov-threshold (default 0.25: proper names, heavy jargon) falls
 * back to the espeak path FOR THAT CLAUSE. Counters land on stderr once
 * per request as {"g2p": "nano=N espeak_fb=N oov=X/Y"} so gates can
 * measure the real rate.
 */
#define NANO_G2P_FALLBACK (-1000)

static const char *const npx_ei[] = {"e", "ɪ", NULL};
static const char *const npx_ai[] = {"a", "ɪ", NULL};
static const char *const npx_ou[] = {"o", "ʊ", NULL};
static const char *const npx_au[] = {"a", "ʊ", NULL};
static const char *const npx_oi[] = {"ɔ", "ɪ", NULL};
static const char *const npx_flap[] = {"ɾ", NULL};
static const char *const npx_dʒ[] = {"d", "ʒ", NULL};
static const char *const npx_tʃ[] = {"t", "ʃ", NULL};
static const char *const npx_ə[] = {"ə", NULL};

static const struct { const char *sym; const char *const *exp; } NANO_PIPER_EXP[] = {
    {"A", npx_ei}, {"I", npx_ai}, {"O", npx_ou}, {"W", npx_au}, {"Y", npx_oi},
    {"T", npx_flap}, {"ʤ", npx_dʒ}, {"ʧ", npx_tʃ}, {"ᵊ", npx_ə},
};

/* Walk a nano phoneme string into (id, PAD) pairs, expanding the symbols
 * the piper map lacks. Same shape and cap as append_ipa_ids. */
static void append_nano_ids(const char *ph, int32_t *ids, int *n) {
    for (const unsigned char *q = (const unsigned char *)ph; *q; ) {
        int len = utf8_len(*q);
        if (len <= 0 || len > 7) { q++; continue; }
        char sym[8];
        memcpy(sym, q, (size_t)len);
        sym[len] = 0;
        const char *const *exp = NULL;
        for (size_t k = 0; k < sizeof NANO_PIPER_EXP / sizeof NANO_PIPER_EXP[0]; k++) {
            if (!strcmp(NANO_PIPER_EXP[k].sym, sym)) { exp = NANO_PIPER_EXP[k].exp; break; }
        }
        if (exp) {
            for (int k = 0; exp[k] && *n < MAX_IDS - 2; k++) {
                int id = map_id(exp[k]);
                if (id >= 0) { ids[(*n)++] = id; ids[(*n)++] = PAD_ID; }
            }
        } else {
            int id = map_id(sym);
            if (id >= 0 && *n < MAX_IDS - 2) { ids[(*n)++] = id; ids[(*n)++] = PAD_ID; }
        }
        q += len;
    }
}

/* One shared phoneme-string arena: a clause's G2P output before the id
 * walk. Static like the rest of the G2P machinery (single-threaded
 * request loop; the G2P module itself is not reentrant either). */
static char g_nano_ph[16384];

/* G2P one clause with the in-process lexicon: sub-split at word boundaries
 * (nano_lex_g2p caps input at 512 codepoints, same chunking as
 * synth_clause_nano), concatenate the phoneme strings into g_nano_ph, and
 * decide whether the clause is speakable. Returns the phoneme byte count,
 * or NANO_G2P_FALLBACK when the clause should go through espeak instead
 * (nothing survived, or the OOV ratio crossed the threshold while the
 * espeak fallback is available). */
static int g2p_nano_clause(const char *text) {
    size_t len = 0;
    long oov = 0, lex = 0;
    int off = 0, n = (int)strlen(text);
    while (off < n) {
        int take = n - off;
        if (take > 480) {
            take = 480;
            int cut = off + take;
            while (cut > off + 64 && text[cut] != ' ') cut--;
            take = cut - off;
        }
        while (off < n && text[off] == ' ') off++;   /* never lead with a space */
        if (off >= n) break;
        char chunk[512];
        memcpy(chunk, text + off, (size_t)take);
        chunk[take] = 0;
        off += take;

        /* Two lexicons share this clause walk: misaki English
         * (nano_lex_g2p) and the espeak-derived French one
         * (nano_lex_fr). The phoneme map (--phonemes) picks the G2P;
         * the fr tables store espeak fr IPA verbatim, so in-dictionary
         * French words are espeak-exact. */
        long oov_c, lex_c;
        int rc;
        if (g_map == PHONEME_MAP_FR) {
            nano_lex_fr_stats_t st;
            rc = nano_lex_fr_text_to_phonemes(chunk, g_nano_ph + len,
                                              sizeof g_nano_ph - len);
            nano_lex_fr_get_stats(&st);
            oov_c = st.oov_words;
            lex_c = st.lexicon_words;
        } else {
            nano_lex_g2p_stats_t st;
            rc = nano_lex_g2p_text_to_phonemes(chunk, g_nano_ph + len,
                                               sizeof g_nano_ph - len);
            nano_lex_g2p_get_stats(&st);
            oov_c = st.oov_words;
            lex_c = st.lexicon_words;
        }
        oov += oov_c;
        lex += lex_c;
        /* E_CAP leaves a truncated but speakable prefix in the buffer;
         * every other negative code writes nothing. */
        if (rc < 0 && rc != NANO_LEX_E_CAP && rc != NFR_E_CAP) continue;
        len += strlen(g_nano_ph + len);
    }
    g_g2p_oov_words += oov;
    g_g2p_lex_words += lex;
    if (len == 0) return NANO_G2P_FALLBACK;
    if (lex > 0 &&
        (float)oov / (float)lex > g_g2p_oov_threshold &&
        g_espeak_bin && g_espeak_data) {
        g_g2p_espeak_clauses++;
        return NANO_G2P_FALLBACK;
    }
    g_g2p_nano_clauses++;
    return (int)len;
}

/* text -> piper phoneme ids via the in-process lexicon G2P. Same framing
 * and return contract as text_to_ids(); NANO_G2P_FALLBACK asks the caller
 * to redo the clause through espeak. */
static int text_to_ids_nano(const char *text, int32_t *ids, int punct_id) {
    int n = 0;
    ids[n++] = BOS_ID;
    ids[n++] = PAD_ID;
    int plen = g2p_nano_clause(text);
    if (plen == NANO_G2P_FALLBACK) return NANO_G2P_FALLBACK;
    if (plen > 0) append_nano_ids(g_nano_ph, ids, &n);
    if (punct_id >= 0 && n < MAX_IDS - 2) {
        ids[n++] = punct_id;
        ids[n++] = PAD_ID;
    }
    if (n > MAX_IDS - 1) n = MAX_IDS - 1;
    ids[n++] = EOS_ID;
    return n;
}

/* --native-punct variant of text_to_ids_nano: split at the text-level
 * punctuation like text_to_ids_native and interleave each mark's own id,
 * with the lexicon G2P phonemizing the pieces. */
static int text_to_ids_nano_native(const char *text, int32_t *ids) {
    int n = 0;
    ids[n++] = BOS_ID;
    ids[n++] = PAD_ID;
    const char *p = text;
    while (*p && n < MAX_IDS - 2) {
        char c = *p;
        if (c == '.' || c == ',' || c == '?' || c == '!' || c == ':' || c == ';') {
            char sym[2] = { c, 0 };
            int id = map_id(sym);
            if (id >= 0) { ids[n++] = id; ids[n++] = PAD_ID; }
            p++;
            continue;
        }
        size_t len = strcspn(p, ".,!?;:");
        if (len == 0) { p++; continue; }
        char piece[2048];
        if (len > sizeof piece - 1) len = sizeof piece - 1;
        memcpy(piece, p, len);
        piece[len] = 0;
        p += len;
        int plen = g2p_nano_clause(piece);
        if (plen == NANO_G2P_FALLBACK) return NANO_G2P_FALLBACK;
        if (plen > 0) append_nano_ids(g_nano_ph, ids, &n);
    }
    if (n > MAX_IDS - 1) n = MAX_IDS - 1;
    ids[n++] = EOS_ID;
    return n;
}

/* Synthesize one clause on the nano engine: sub-split the clause at word
 * boundaries so no piece exceeds the G2P's 512-codepoint input limit, run
 * the lexicon G2P per piece, and feed snt_nano. Noise is seeded from the
 * piece text (deterministic) or the forced --seed. Returns 0 on success,
 * the first non-zero synth rc otherwise; samples emitted are added to
 * *emitted so the caller can skip the clause gap for silent clauses. */
static int synth_clause_nano(void *front, void *dec, void *arena, size_t arena_size,
                             const char *clause, WavSink *sink, long *emitted) {
    static int32_t ids[NANO_LEX_MAX_TOKENS];
    int off = 0, n = (int)strlen(clause);
    long before = sink->n;
    while (off < n) {
        int take = n - off;
        if (take > 480) {
            take = 480;
            int cut = off + take;
            while (cut > off + 64 && clause[cut] != ' ') cut--;
            take = cut - off;
        }
        while (off < n && clause[off] == ' ') off++; /* never lead with a space */
        if (off >= n) break;
        char chunk[512];
        memcpy(chunk, clause + off, (size_t)take);
        chunk[take] = 0;
        off += take;

        int n_ids = nano_lex_g2p_text_to_ids(chunk, ids, NANO_LEX_MAX_TOKENS);
        if (n_ids == NANO_LEX_E_CAP) n_ids = NANO_LEX_MAX_TOKENS; /* framed prefix, speakable */
        if (n_ids < 0) {
            fprintf(stderr, "{\"error\": \"g2p rc %d (%s)\"}\n", n_ids, nano_lex_g2p_strerror(n_ids));
            fflush(stderr);
            continue;
        }
        if (n_ids <= 2) continue; /* nothing survived the vocabulary */

        uint64_t seed = g_seed;
        if (!g_seed_set && snt_nano_sha256_seed(chunk, &seed) != 0) seed = (uint64_t)n * 2654435761u;
        snt_nano_config ncfg = {front, dec, arena, arena_size, NULL, seed};
        snt_nano_stats nst;
        int rc = snt_nano_synthesize(&ncfg, ids, n_ids, wav_cb, sink, &nst);
        if (rc != 0) return rc;
    }
    *emitted += sink->n - before;
    return 0;
}

/* Derive per-word frame spans from the synthesized token stream.
 *
 * Word boundaries come from WORD_SEP_ID, which is where espeak's inter-word
 * space lands after map_id(). Framing is found by POSITION, never by id
 * value: both maps alias '^' to BOS_ID and '$' to EOS_ID, so a real IPA
 * stream may legitimately carry id 1 or 2. Index 0 is BOS and the last index
 * is EOS by construction (text_to_ids always appends EOS last).
 *
 * The BOS/PAD prefix is folded into the first word so word 1 starts at the
 * clause start, and everything after the final separator (trailing PAD, the
 * punctuation id, EOS) is folded into the last word so the last span ends
 * exactly on the clause's content end. The separator's own frames are left
 * as an inter-word gap: they belong to neither neighbouring word.
 *
 * Returns the number of spans written, capped at max_out. */
static int word_spans_from_ids(const int32_t *ids, const int32_t *durs, int n_ids,
                               SntWordSpan *out, int max_out) {
    int n = 0, open = 0;
    long cur = 0;
    for (int i = 0; i < n_ids; i++) {
        if (i == 0 || i == n_ids - 1) { cur += durs[i]; continue; }
        if (ids[i] == WORD_SEP_ID) {
            if (open) { out[n - 1].end = cur; open = 0; }
            cur += durs[i];
            continue;
        }
        if (!open) {
            if (n >= max_out) return n;
            out[n].start = cur;
            out[n].end = cur;
            n++;
            open = 1;
        }
        cur += durs[i];
        out[n - 1].end = cur;
    }
    if (n > 0) {
        /* Fold the framing prefix into word 1 and the trailing framing and
         * punctuation into the last word, so the span covers the clause. */
        out[0].start = 0;
        out[n - 1].end = cur;
    }
    return n;
}

/* Synthesize one clause on the pq8 engine (blob-parameterized piperlite,
 * fully int8): durations -> latent -> decoder -> PCM. Phoneme ids come from
 * the shared espeak path, so this takes the framed id array directly.
 * Returns 0 on success, the failing rc otherwise. */
static int synth_clause_pq8(snt_front_q8_model *fq, snt_piperlite_q8_model *dq,
                            void *arena, size_t arena_size,
                            const int32_t *ids, int n_ids,
                            WavSink *sink, long *emitted,
                            SntWordSpan *spans, int *n_spans, int max_spans,
                            long base_samples) {
    static int32_t durs[MAX_IDS];
    long before = sink->n;
    *n_spans = 0;
    long frames = snt_front_q8_durations(fq, ids, n_ids, g_length_scale,
                                         durs, arena, arena_size);
    if (frames < 0) {
        fprintf(stderr, "{\"error\": \"pq8 durations rc %ld\"}\n", frames);
        fflush(stderr);
        return (int)frames;
    }
    /* --pause-scale stretches only the punctuation tokens' frame counts,
     * leaving every phone at its native duration: the pacing pauses get
     * longer without feeding the decoder stretched phones (which reads as
     * phasing/reverb). Frames must re-sum to the new total. */
    if (g_pause_scale != 1.0f) {
        long total = 0;
        for (int i = 0; i < n_ids; i++) {
            if (ids[i] == 4 || ids[i] == 8 || ids[i] == 10 ||
                ids[i] == 11 || ids[i] == 12 || ids[i] == 13) {
                long scaled = (long)(durs[i] * g_pause_scale + 0.5f);
                durs[i] = (int32_t)(scaled < 1 ? 1 : scaled);
            }
            total += durs[i];
        }
        frames = total;
    }
    /* Read the per-word spans out of the frame counts the duration student
     * just produced. This runs after the pause adjustment so the spans match
     * the audio; it reads ids[]/durs[] only and never feeds back into
     * synthesis. */
    {
        int ns = word_spans_from_ids(ids, durs, n_ids, spans, max_spans);
        for (int g = 0; g < ns; g++) {
            spans[g].start = base_samples + spans[g].start * SNT_PIPERLITE_Q8_HOP;
            spans[g].end   = base_samples + spans[g].end   * SNT_PIPERLITE_Q8_HOP;
        }
        *n_spans = ns;
    }
    size_t la = snt_front_q8_latent_arena_bytes(fq, n_ids, frames);
    size_t da = snt_piperlite_q8_arena_bytes(dq, (int)frames);
    /* The decoder arena scales with clause length (tens of KB per second of
     * audio), so long clauses fall back to a heap arena. The two stages run
     * sequentially and share whichever buffer wins. */
    size_t need = la > da ? la : da;
    void *ar = arena;
    int heap_arena = 0;
    if (need > arena_size) {
        ar = malloc(need);
        if (!ar) { fprintf(stderr, "{\"error\": \"pq8 arena malloc %zu\"}\n", need); fflush(stderr); return -1; }
        heap_arena = 1;
    }
    float *latent = malloc(sizeof(float) * (size_t)fq->a_out * (size_t)frames);
    float *audio = malloc(sizeof(float) * (size_t)frames * SNT_PIPERLITE_Q8_HOP);
    if (!latent || !audio) { free(latent); free(audio); if (heap_arena) free(ar); return -1; }
    int rc = snt_front_q8_latent(fq, ids, durs, n_ids, frames, latent, ar, la);
    if (rc == 0)
        rc = snt_piperlite_q8_synthesize(dq, latent, (int)frames, audio, ar, da);
    if (heap_arena) free(ar);
    if (rc == 0) {
        long n = (long)frames * SNT_PIPERLITE_Q8_HOP;
        for (long i = 0; i < n; i++) {
            float s = audio[i];
            if (s > 1.0f) s = 1.0f;
            else if (s < -1.0f) s = -1.0f;
            int16_t v = (int16_t)(s * 32767.0f);
            if (fwrite(&v, sizeof v, 1, sink->fh) != 1) { rc = -1; break; }
            sink->n++;
        }
    }
    free(latent);
    free(audio);
    if (rc != 0) {
        fprintf(stderr, "{\"error\": \"pq8 synth rc %d\"}\n", rc);
        fflush(stderr);
        return rc;
    }
    *emitted += sink->n - before;
    return 0;
}

/* Synthesize one clause on the f32 engine (fp32 piperlite voice pair): same
 * dataflow as pq8 -- durations -> latent -> decoder -> PCM -- at fp32
 * precision, with float-unit arenas. Phoneme ids come from the shared espeak
 * path. Returns 0 on success, the failing rc otherwise. */
static int synth_clause_f32(snt_front_model *fm, snt_piperlite_model *dm,
                            float *arena, size_t arena_floats,
                            const int32_t *ids, int n_ids,
                            WavSink *sink, long *emitted,
                            SntWordSpan *spans, int *n_spans, int max_spans,
                            long base_samples) {
    static int32_t durs[MAX_IDS];
    long before = sink->n;
    *n_spans = 0;
    long frames = snt_front_durations(fm, ids, n_ids, g_length_scale,
                                      durs, arena, arena_floats);
    if (frames < 0) {
        fprintf(stderr, "{\"error\": \"f32 durations rc %ld\"}\n", frames);
        fflush(stderr);
        return (int)frames;
    }
    /* Same pause treatment as pq8: stretch only the punctuation tokens. */
    if (g_pause_scale != 1.0f) {
        long total = 0;
        for (int i = 0; i < n_ids; i++) {
            if (ids[i] == 4 || ids[i] == 8 || ids[i] == 10 ||
                ids[i] == 11 || ids[i] == 12 || ids[i] == 13) {
                long scaled = (long)(durs[i] * g_pause_scale + 0.5f);
                durs[i] = (int32_t)(scaled < 1 ? 1 : scaled);
            }
            total += durs[i];
        }
        frames = total;
    }
    /* Same read-out as pq8: spans come from the post-scaling frame counts. */
    {
        int ns = word_spans_from_ids(ids, durs, n_ids, spans, max_spans);
        for (int g = 0; g < ns; g++) {
            spans[g].start = base_samples + spans[g].start * SNT_PIPERLITE_HOP;
            spans[g].end   = base_samples + spans[g].end   * SNT_PIPERLITE_HOP;
        }
        *n_spans = ns;
    }
    size_t la = snt_front_latent_arena_floats(fm, n_ids, frames);
    size_t da = snt_piperlite_arena_floats(dm, (int)frames);
    size_t need = la > da ? la : da;
    float *ar = arena;
    int heap_arena = 0;
    if (need > arena_floats) {
        ar = malloc(sizeof(float) * need);
        if (!ar) { fprintf(stderr, "{\"error\": \"f32 arena malloc %zu\"}\n", need); fflush(stderr); return -1; }
        heap_arena = 1;
    }
    float *latent = malloc(sizeof(float) * (size_t)fm->a_out * (size_t)frames);
    float *audio = malloc(sizeof(float) * (size_t)frames * SNT_PIPERLITE_HOP);
    if (!latent || !audio) { free(latent); free(audio); if (heap_arena) free(ar); return -1; }
    int rc = snt_front_latent(fm, ids, durs, n_ids, frames, latent, ar, la);
    if (rc == 0)
        rc = snt_piperlite_synthesize(dm, latent, (int)frames, audio, ar, da);
    if (heap_arena) free(ar);
    if (rc == 0) {
        long n = (long)frames * SNT_PIPERLITE_HOP;
        for (long i = 0; i < n; i++) {
            float s = audio[i];
            if (s > 1.0f) s = 1.0f;
            else if (s < -1.0f) s = -1.0f;
            int16_t v = (int16_t)(s * 32767.0f);
            if (fwrite(&v, sizeof v, 1, sink->fh) != 1) { rc = -1; break; }
            sink->n++;
        }
    }
    free(latent);
    free(audio);
    if (rc != 0) {
        fprintf(stderr, "{\"error\": \"f32 synth rc %d\"}\n", rc);
        fflush(stderr);
        return rc;
    }
    *emitted += sink->n - before;
    return 0;
}

/* extract "input" and "output" string values from a flat JSON object line;
 * unescapes the common escapes in place. */
static int json_fields(char *line, char **input, char **output) {
    *input = NULL; *output = NULL;
    char *cursor = line;
    while ((cursor = strchr(cursor, '"')) != NULL) {
        char *key = cursor + 1;
        char *kend = strchr(key, '"');
        if (!kend) break;
        *kend = 0;
        char *rest = kend + 1;
        while (*rest == ' ' || *rest == ':') rest++;
        if (*rest != '"') { cursor = rest; continue; }
        rest++;
        char *out = rest, *r = rest;
        while (*r && *r != '"') {
            if (*r == '\\' && r[1]) {
                r++;
                switch (*r) {
                case 'n': *out++ = '\n'; break;
                case 't': *out++ = '\t'; break;
                case 'r': *out++ = '\r'; break;
                default: *out++ = *r;
                }
                r++;
            } else *out++ = *r++;
        }
        if (*r != '"') { cursor = kend + 1; continue; }
        *out = 0;
        /* accept both piper json-input key names and generic ones */
        if ((!strcmp(key, "input") || !strcmp(key, "text")) && !*input) *input = rest;
        else if ((!strcmp(key, "output") || !strcmp(key, "output_file")) && !*output) *output = rest;
        cursor = r + 1;
        if (*input && *output) return 0;
    }
    return (*input && *output) ? 0 : -1;
}

int main(int argc, char **argv) {
    const char *model = NULL;
    const char *engine = "int8";
    int rate = 0; /* resolved after arg parse: 22050 int8, 24000 nano */
    int length_scale_given = 0;
    for (int i = 1; i < argc - 1; i++) {
        if (!strcmp(argv[i], "--model")) model = argv[i + 1];
        else if (!strcmp(argv[i], "--engine")) engine = argv[i + 1];
        else if (!strcmp(argv[i], "--espeak-bin")) g_espeak_bin = argv[i + 1];
        else if (!strcmp(argv[i], "--espeak-data")) g_espeak_data = argv[i + 1];
        else if (!strcmp(argv[i], "--voice")) g_voice = argv[i + 1];
        else if (!strcmp(argv[i], "--loader")) g_loader = argv[i + 1];
        else if (!strcmp(argv[i], "--loader-libdir")) g_libdir = argv[i + 1];
        else if (!strcmp(argv[i], "--comma-ms")) g_comma_ms = atoi(argv[i + 1]);
        else if (!strcmp(argv[i], "--period-ms")) g_period_ms = atoi(argv[i + 1]);
        else if (!strcmp(argv[i], "--rate")) rate = atoi(argv[i + 1]);
        else if (!strcmp(argv[i], "--seed")) { g_seed = strtoull(argv[i + 1], NULL, 0); g_seed_set = 1; }
        else if (!strcmp(argv[i], "--length-scale")) {
            g_length_scale = (float)atof(argv[i + 1]);
            length_scale_given = 1;
        }
        else if (!strcmp(argv[i], "--phonemes")) {
            if (!strcmp(argv[i + 1], "fr")) { g_map = PHONEME_MAP_FR; g_map_n = PHONEME_MAP_FR_N; }
            else if (strcmp(argv[i + 1], "en")) {
                fprintf(stderr, "{\"error\": \"unknown phoneme map %s\"}\n", argv[i + 1]);
                return 2;
            }
        }
        else if (!strcmp(argv[i], "--pause-scale")) g_pause_scale = (float)atof(argv[i + 1]);
        else if (!strcmp(argv[i], "--native-punct")) g_native_punct = 1;
        else if (!strcmp(argv[i], "--g2p")) {
            if (!strcmp(argv[i + 1], "nano")) g_g2p_nano = 1;
            else if (strcmp(argv[i + 1], "espeak")) {
                fprintf(stderr, "{\"error\": \"unknown g2p %s\"}\n", argv[i + 1]);
                return 2;
            }
        }
        else if (!strcmp(argv[i], "--g2p-oov-threshold"))
            g_g2p_oov_threshold = (float)atof(argv[i + 1]);
    }
    if (!strcmp(engine, "nano")) g_engine_nano = 1;
    if (!strcmp(engine, "pq8")) g_engine_pq8 = 1;
    if (!strcmp(engine, "f32")) g_engine_f32 = 1;
    if (g_g2p_nano && g_engine_nano) {
        fprintf(stderr, "{\"error\": \"--g2p nano applies to int8/pq8/f32; --engine nano already uses the lexicon G2P\"}\n");
        return 2;
    }
    if (!rate) rate = g_engine_nano ? 24000 : 22050;
    /* The int8 (R7) engine has no per-call scale; it renders at a runtime
     * global whose native value is 1.08.  Apply the requested length scale as
     * a ratio on top of that, so --length-scale 1.0 (and omitting the flag)
     * keeps the voice's native speed.  pq8 and f32 take the value per call. */
    if (length_scale_given && !g_engine_nano && !g_engine_pq8 && !g_engine_f32) {
        snt_length_scale = 1.08f * g_length_scale;
    }
    /* espeak stays mandatory for the espeak G2P; under --g2p nano it is an
     * optional per-clause OOV fallback (absent = OOV words are swallowed,
     * counted on the g2p stderr line). */
    if (!model || (!g_engine_nano && !g_g2p_nano &&
                   (!g_espeak_bin || !g_espeak_data))) {
        fprintf(stderr, "usage: %s --model <dir> --engine int8|pq8|nano|f32 [--espeak-bin <bin> --espeak-data <dir>] [--phonemes en|fr] [--g2p espeak|nano] [--g2p-oov-threshold F] [--rate 22050|24000] [--seed N] [--length-scale F]\n", argv[0]);
        return 2;
    }

    void *front = NULL, *dec = NULL;
    snt_front_q8_model fq;
    snt_piperlite_q8_model dq;
    snt_front_model fmf;
    snt_piperlite_model dfm;
    if (g_engine_f32) {
        /* The metas must outlive the models (weight pointers point into
         * them), so these allocations are simply never freed. */
        size_t fm_meta_nb, fm_w_nb, dm_meta_nb, dm_w_nb;
        void *fm_meta = xload2s(model, "front_meta.bin", &fm_meta_nb);
        void *fm_w = xload2s(model, "front_weights_f32.bin", &fm_w_nb);
        void *dm_meta = xload2s(model, "dec_meta.bin", &dm_meta_nb);
        void *dm_w = xload2s(model, "dec_weights_f32.bin", &dm_w_nb);
        if ((fm_w_nb | dm_w_nb) % 4) {
            fprintf(stderr, "{\"error\": \"f32 weight blob not multiple of 4\"}\n");
            return 1;
        }
        int rc = snt_front_init(&fmf, fm_meta, fm_meta_nb, (const float *)fm_w, fm_w_nb / 4);
        if (rc == 0)
            rc = snt_piperlite_init(&dfm, dm_meta, dm_meta_nb, (const float *)dm_w, dm_w_nb / 4);
        if (rc != 0) { fprintf(stderr, "{\"error\": \"f32 init rc %d\"}\n", rc); return 1; }
    } else if (g_engine_pq8) {
        /* The metas must outlive the models (the fp32 pool is read in
         * place), so these allocations are simply never freed. */
        size_t fq_meta_nb, fq_w_nb, dq_meta_nb, dq_w_nb;
        void *fq_meta = xload2s(model, "front_meta_q8.bin", &fq_meta_nb);
        void *fq_w = xload2s(model, "front_weights_q8.bin", &fq_w_nb);
        void *dq_meta = xload2s(model, "meta_q8.bin", &dq_meta_nb);
        void *dq_w = xload2s(model, "weights_q8.bin", &dq_w_nb);
        int rc = snt_front_q8_init(&fq, fq_meta, fq_meta_nb, (const int8_t *)fq_w, fq_w_nb);
        if (rc == 0) rc = snt_piperlite_q8_init(&dq, dq_meta, dq_meta_nb, (const int8_t *)dq_w, dq_w_nb);
        if (rc != 0) { fprintf(stderr, "{\"error\": \"pq8 init rc %d\"}\n", rc); return 1; }
    } else {
        front = xload2(model, "front_q8.bin");
        dec = xload2(model, "model_q8.bin");
    }

    static unsigned char arena[16 * 1024 * 1024] __attribute__((aligned(16)));
    int32_t *ids = malloc((size_t)MAX_IDS * 4);
    WavSink sink;

    char line[16384];
    while (fgets(line, sizeof line, stdin)) {
        char *input = NULL, *output = NULL;
        if (json_fields(line, &input, &output) != 0) {
            fprintf(stderr, "{\"error\": \"bad line\"}\n");
            fflush(stderr);
            continue;
        }

        /* split into clauses at punctuation; each clause is phonemized and
         * synthesized separately, with a silence gap after it sized by the
         * punctuation that ended it. --native-punct skips the splitting:
         * the whole line is one synthesis and the punctuation mark ids
         * carry the pauses and contours themselves. */
        char clauses[64][4096];
        int clause_ms[64];
        char clause_punct[64];
        int n_clauses = 0;
        /* Timeline read-out. One entry per clause holds its absolute sample
         * span in the request WAV and its character territory in `input`;
         * `words` accumulates the per-word spans the clause loop appends.
         * Only the pq8 and f32 engines fill these. */
        long cl_sstart[64] = {0}, cl_send[64] = {0};
        int cl_char_start[64] = {0}, cl_char_end[64] = {0};
        int cl_word0[64] = {0}, cl_nwords[64] = {0};
        static SntWordSpan words[MAX_WORDS];
        int n_words = 0;
        if (g_native_punct && !g_engine_nano) {
            snprintf(clauses[0], sizeof clauses[0], "%s", input);
            clauses[0][sizeof clauses[0] - 1] = 0;
            clause_ms[0] = 0;
            clause_punct[0] = 0; /* punctuation ids are already in the stream */
            cl_char_start[0] = 0;
            cl_char_end[0] = (int)strlen(input);
            n_clauses = 1;
        } else {
            char cur[4096]; int cur_n = 0;
            const char *p = input;
            int cur_start = 0;
            while (*p && n_clauses < 64) {
                unsigned char c = (unsigned char)*p;
                if (c == '.' || c == ',' || c == '?' || c == '!' || c == ':' || c == ';') {
                    if (cur_n > 0) {
                        cur[cur_n] = 0;
                        memcpy(clauses[n_clauses], cur, (size_t)cur_n + 1);
                        clause_ms[n_clauses] =
                            c == ',' ? g_comma_ms :
                            c == ':' ? g_colon_ms :
                            c == ';' ? g_semi_ms : g_period_ms;
                        clause_punct[n_clauses] = (char)c;
                        cl_char_start[n_clauses] = cur_start;
                        n_clauses++;
                        cur_n = 0;
                    }
                    p++;
                    continue;
                }
                if (cur_n < 4090) {
                    if (cur_n == 0) cur_start = (int)(p - input);
                    cur[cur_n++] = (char)c;
                }
                p++;
            }
            if (cur_n > 0 && n_clauses < 64) {
                cur[cur_n] = 0;
                memcpy(clauses[n_clauses], cur, (size_t)cur_n + 1);
                clause_ms[n_clauses] = 0; /* final clause: plugin adds its own gap */
                clause_punct[n_clauses] = 0;
                cl_char_start[n_clauses] = cur_start;
                n_clauses++;
            }
            /* A clause's territory runs to the next clause's first character,
             * not to its own terminator, so a run of swallowed punctuation
             * stays inside the clause it ended and the territories partition
             * [0, strlen(input)) exactly. */
            for (int j = 0; j + 1 < n_clauses; j++) cl_char_end[j] = cl_char_start[j + 1];
            if (n_clauses > 0) cl_char_end[n_clauses - 1] = (int)strlen(input);
        }
        if (n_clauses == 0) {
            fprintf(stderr, "{\"error\": \"empty input\"}\n");
            fflush(stderr);
            continue;
        }

        FILE *fh = fopen(output, "wb");
        if (!fh) { fprintf(stderr, "{\"error\": \"cannot write %s\"}\n", output); fflush(stderr); continue; }
        write_header(fh, 0, (uint32_t)rate);
        sink.fh = fh; sink.n = 0;
        if (g_g2p_nano) {
            g_g2p_nano_clauses = 0;
            g_g2p_espeak_clauses = 0;
            g_g2p_oov_words = 0;
            g_g2p_lex_words = 0;
        }

        long total_ms = 0;
        int rc_all = 0;
        for (int ci = 0; ci < n_clauses; ci++) {
            int rc = 0, spoke = 0;
            long emitted = 0;
            int nspans = 0;
            cl_sstart[ci] = sink.n;
            if (g_engine_nano) {
                rc = synth_clause_nano(front, dec, arena, sizeof arena, clauses[ci], &sink, &emitted);
                spoke = emitted > 0;
            } else {
                int n_ids;
                if (g_native_punct) {
                    n_ids = g_g2p_nano
                        ? text_to_ids_nano_native(clauses[ci], ids)
                        : text_to_ids_native(clauses[ci], ids);
                    if (n_ids == NANO_G2P_FALLBACK)
                        n_ids = text_to_ids_native(clauses[ci], ids);
                } else {
                    int pid = -1;
                    if (clause_punct[ci]) {
                        char sym[2] = { clause_punct[ci], 0 };
                        pid = map_id(sym);
                    }
                    n_ids = g_g2p_nano
                        ? text_to_ids_nano(clauses[ci], ids, pid)
                        : text_to_ids(clauses[ci], ids, pid);
                    if (n_ids == NANO_G2P_FALLBACK)
                        n_ids = text_to_ids(clauses[ci], ids, pid);
                }
                /* The piperlite voices embed fewer ids than the phoneme map
                 * carries, and an id they cannot embed fails the whole
                 * clause. Drop those before synthesizing. */
                if (g_engine_pq8) n_ids = drop_oov_ids(ids, n_ids, fq.d_vocab);
                else if (g_engine_f32) n_ids = drop_oov_ids(ids, n_ids, fmf.d_vocab);
                if (n_ids > 3) {
                    if (g_engine_pq8) {
                        rc = synth_clause_pq8(&fq, &dq, arena, sizeof arena, ids, n_ids, &sink, &emitted,
                                              words + n_words, &nspans, MAX_WORDS - n_words, cl_sstart[ci]);
                        spoke = emitted > 0;
                    } else if (g_engine_f32) {
                        rc = synth_clause_f32(&fmf, &dfm, (float *)arena,
                                              sizeof arena / sizeof(float),
                                              ids, n_ids, &sink, &emitted,
                                              words + n_words, &nspans, MAX_WORDS - n_words, cl_sstart[ci]);
                        spoke = emitted > 0;
                    } else {
                        /* The int8 (R7) engine computes per-token durations
                         * internally; read them back and derive the same
                         * word spans the pq8/f32 engines publish. */
                        static int32_t int8_durs[MAX_IDS];
                        snt_config cfg = {front, dec, arena, sizeof arena,
                                          NULL, int8_durs, n_ids};
                        snt_stats st;
                        long base = sink.n;
                        rc = snt_synthesize(&cfg, ids, n_ids, wav_cb, &sink, &st);
                        if (rc == 0) {
                            SntWordSpan *sp = words + n_words;
                            int ns = word_spans_from_ids(ids, int8_durs,
                                                         n_ids, sp,
                                                         MAX_WORDS - n_words);
                            for (int g = 0; g < ns; g++) {
                                sp[g].start = base + sp[g].start * INT8_HOP;
                                sp[g].end = base + sp[g].end * INT8_HOP;
                            }
                            nspans = ns;
                        }
                        spoke = 1;
                    }
                }
            }
            if (rc != 0) { rc_all = rc; break; }
            if (spoke && nspans > 0) {
                cl_word0[ci] = n_words;
                cl_nwords[ci] = nspans;
                n_words += nspans;
            }
            if (spoke && ci < n_clauses - 1 && clause_ms[ci] > 0) {
                int gap = rate * clause_ms[ci] / 1000;
                static const int16_t zero;
                for (int s = 0; s < gap; s++) fwrite(&zero, 2, 1, fh);
                sink.n += gap;
            }
            /* The clause's sample span includes the gap it emitted, so
             * consecutive clauses tile the WAV without a seam. */
            cl_send[ci] = sink.n;
        }

        long data_bytes = sink.n * 2;
        fseek(fh, 0, SEEK_SET);
        write_header(fh, (uint32_t)data_bytes, (uint32_t)rate);
        fclose(fh);

        /* Timing sidecar, "<wav>.timing", derived from the output path so the
         * stdout protocol stays one path per line. Written and closed BEFORE
         * the path is printed, so the wrapper's "<wav>.done" marker (made from
         * that line) gates both files. Absence is the plugin's "no real
         * timing" signal: int8/pq8/f32 fill word spans (int8 since the
         * duration-readout patch), while the nano engine and every failed
         * run write nothing. See the format note at the top of this file. */
        if (rc_all == 0 && n_words > 0) {
            char tpath[1100];
            int hop = g_engine_pq8 ? SNT_PIPERLITE_Q8_HOP
                    : g_engine_f32 ? SNT_PIPERLITE_HOP
                    : INT8_HOP;
            snprintf(tpath, sizeof tpath, "%s.timing", output);
            FILE *tf = fopen(tpath, "w");
            if (tf) {
                fprintf(tf, "sntt 1 %d %d %ld %d %d\n", rate, hop, sink.n, n_clauses, n_words);
                for (int ci = 0; ci < n_clauses; ci++)
                    fprintf(tf, "c %d %d %d %d %ld %ld %d %d\n", ci,
                            cl_char_start[ci], cl_char_end[ci], (int)clause_punct[ci],
                            cl_sstart[ci], cl_send[ci], cl_word0[ci], cl_nwords[ci]);
                for (int i = 0; i < n_words; i++)
                    fprintf(tf, "w %d %ld %ld\n", i, words[i].start, words[i].end);
                fclose(tf);
            }
        }

        printf("%s\n", output);
        fflush(stdout);
        if (g_g2p_nano) {
            fprintf(stderr, "{\"g2p\": \"nano=%ld espeak_fb=%ld oov=%ld/%ld\"}\n",
                    g_g2p_nano_clauses, g_g2p_espeak_clauses,
                    g_g2p_oov_words, g_g2p_lex_words);
            fflush(stderr);
        }
        if (rc_all != 0) { fprintf(stderr, "{\"error\": \"synth rc %d\"}\n", rc_all); fflush(stderr); }
        (void)total_ms;
    }
    return 0;
}
