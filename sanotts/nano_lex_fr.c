/* nano_lex_fr.c -- French dictionary-first G2P; see nano_lex_fr.h. */

#include "nano_lex_fr.h"
#include "nano_lex_fr_tables.h"

#include <string.h>

static nano_lex_fr_stats_t g_fr_stats;

/* ------------------------------------------------------------------ */
/* UTF-8 helpers                                                        */
/* ------------------------------------------------------------------ */

static uint32_t fr_utf8_next(const char **pp)
{
    const unsigned char *p = (const unsigned char *)(*pp);
    uint32_t c;
    if (*p == 0) return 0;
    if (p[0] < 0x80) { *pp += 1; return p[0]; }
    if ((p[0] & 0xE0) == 0xC0 && (p[1] & 0xC0) == 0x80) {
        c = ((uint32_t)(p[0] & 0x1F) << 6) | (p[1] & 0x3F);
        *pp += 2; return c;
    }
    if ((p[0] & 0xF0) == 0xE0 && (p[1] & 0xC0) == 0x80 && (p[2] & 0xC0) == 0x80) {
        c = ((uint32_t)(p[0] & 0x0F) << 12) | ((uint32_t)(p[1] & 0x3F) << 6)
            | (p[2] & 0x3F);
        *pp += 3; return c;
    }
    if ((p[0] & 0xF8) == 0xF0 && (p[1] & 0xC0) == 0x80 && (p[2] & 0xC0) == 0x80
            && (p[3] & 0xC0) == 0x80) {
        c = ((uint32_t)(p[0] & 0x07) << 18) | ((uint32_t)(p[1] & 0x3F) << 12)
            | ((uint32_t)(p[2] & 0x3F) << 6) | (p[3] & 0x3F);
        *pp += 4; return c;
    }
    *pp += 1;
    return 0xFFFD;
}

static size_t fr_utf8_enc(char *dst, uint32_t c)
{
    if (c < 0x80) { dst[0] = (char)c; return 1; }
    if (c < 0x800) {
        dst[0] = (char)(0xC0 | (c >> 6));
        dst[1] = (char)(0x80 | (c & 0x3F));
        return 2;
    }
    dst[0] = (char)(0xE0 | (c >> 12));
    dst[1] = (char)(0x80 | ((c >> 6) & 0x3F));
    dst[2] = (char)(0x80 | (c & 0x3F));
    return 3;
}

static uint32_t fr_lower(uint32_t c)
{
    if (c >= 'A' && c <= 'Z') return c + 32;
    if (c >= 0xC0 && c <= 0xDE && c != 0xD7) return c + 32;
    if (c == 0x152) return 0x153;   /* Œ -> œ */
    return c;
}

static int fr_is_letter(uint32_t c)
{
    if (c >= 'a' && c <= 'z') return 1;
    if (c >= 'A' && c <= 'Z') return 1;          /* lowercased by the caller */
    if (c >= 0xC0 && c <= 0xFF && c != 0xD7) return 1;
    return c == 0x153 || c == 0x152 || c == 0xC6;
}

static int fr_is_digit(uint32_t c) { return c >= '0' && c <= '9'; }
static int fr_is_apos(uint32_t c) { return c == 0x27 || c == 0x2019; }

/* ------------------------------------------------------------------ */
/* Emission                                                             */
/* ------------------------------------------------------------------ */

static char *g_out;
static size_t g_cap;
static size_t g_len;
static int g_truncated;

static void fr_reset(char *out, size_t cap)
{
    g_out = out;
    g_cap = cap;
    g_len = 0;
    g_truncated = 0;
    if (cap > 0) out[0] = 0;
}

static void fr_put_cp(uint32_t c)
{
    char enc[4];
    size_t nb;
    if (c < 0x80) {
        if (g_len + 1 < g_cap) g_out[g_len++] = (char)c;
        else { g_truncated = 1; g_fr_stats.dropped++; }
        return;
    }
    nb = fr_utf8_enc(enc, c);
    if (g_len + nb < g_cap) {
        memcpy(g_out + g_len, enc, nb);
        g_len += nb;
    } else {
        g_truncated = 1;
        g_fr_stats.dropped++;
    }
}

static void fr_put_space(void) { fr_put_cp(' '); }

static void fr_finish(void) { if (g_cap) g_out[g_len] = 0; }

/* ------------------------------------------------------------------ */
/* Packed dictionary (same blob format as nano_lex_tables.c; PLAIN)     */
/* ------------------------------------------------------------------ */

static int fr_dict_find(const char *key, uint16_t klen,
                        const uint8_t **codes, uint16_t *ncodes)
{
    const nano_lex_fr_dict_t *d = &NANO_LEX_FR_GOLD;
    uint32_t lo = 0, hi = d->block_count, block, pos, i;
    uint8_t cur[NANO_LEX_FR_MAX_KEY];
    uint16_t curlen = 0;

    *codes = NULL;
    *ncodes = 0;
    if (klen == 0 || klen > NANO_LEX_FR_MAX_KEY) return 0;
    while (lo < hi) {
        uint32_t mid = lo + (hi - lo) / 2u;
        uint32_t p = d->block_off[mid];
        uint8_t hlen = (uint8_t)(d->blob[p] - NANO_LEX_FR_BIAS);
        uint16_t n = hlen < klen ? hlen : klen;
        int cmp = 0;
        for (i = 0; i < n; i++) {
            uint8_t b = (uint8_t)(d->blob[p + 1 + i] - NANO_LEX_FR_BIAS);
            if (b != (uint8_t)key[i]) { cmp = b < (uint8_t)key[i] ? -1 : 1; break; }
        }
        if (cmp == 0) cmp = hlen < klen ? -1 : (hlen > klen ? 1 : 0);
        if (cmp <= 0) lo = mid + 1u; else hi = mid;
    }
    if (lo == 0) return 0;
    block = lo - 1u;
    pos = d->block_off[block];
    for (i = 0; i < NANO_LEX_FR_BLOCK
                && block * NANO_LEX_FR_BLOCK + i < d->entry_count; i++) {
        uint8_t vcode;
        uint16_t plen;
        if (i == 0) {
            curlen = (uint8_t)(d->blob[pos] - NANO_LEX_FR_BIAS);
            pos++;
            if (curlen == 0 || curlen > NANO_LEX_FR_MAX_KEY) return 0;
            for (uint32_t j = 0; j < curlen; j++)
                cur[j] = (uint8_t)(d->blob[pos + j] - NANO_LEX_FR_BIAS);
            pos += curlen;
        } else {
            uint8_t shared = (uint8_t)(d->blob[pos] - NANO_LEX_FR_BIAS);
            uint8_t slen = (uint8_t)(d->blob[pos + 1] - NANO_LEX_FR_BIAS);
            pos += 2;
            if ((uint16_t)shared + slen > NANO_LEX_FR_MAX_KEY
                    || shared > curlen) return 0;
            for (uint32_t j = 0; j < slen; j++)
                cur[shared + j] = (uint8_t)(d->blob[pos + j] - NANO_LEX_FR_BIAS);
            curlen = (uint16_t)(shared + slen);
            pos += slen;
        }
        vcode = (uint8_t)(d->blob[pos] - NANO_LEX_FR_BIAS);
        pos++;
        plen = vcode == 0 ? 0 : (uint16_t)(vcode - 1);
        if (curlen == klen && memcmp(cur, key, klen) == 0) {
            if (vcode == 0) return 0;
            *codes = d->blob + pos;
            *ncodes = plen;
            return 1;
        }
        pos += plen;
    }
    return 0;
}

static void fr_emit_dict_entry(const uint8_t *codes, uint16_t n)
{
    /* payload codes are biased in the blob, like every other byte */
    for (uint16_t i = 0; i < n; i++)
        fr_put_cp(NANO_LEX_FR_PH_CP[(uint8_t)(codes[i] - NANO_LEX_FR_BIAS)]);
}

/* Look a word up and emit its phonemes. Returns 1 hit, 0 miss. */
static int fr_lookup(const char *w, size_t wlen)
{
    const uint8_t *codes;
    uint16_t n;
    if (!fr_dict_find(w, (uint16_t)wlen, &codes, &n)) return 0;
    fr_emit_dict_entry(codes, n);
    return 1;
}

/* ------------------------------------------------------------------ */
/* Letter-to-sound fallback (OOV only; the shipped OOV path is the      */
/* per-clause espeak fallback in snt_server, so this layer is best      */
/* effort and counted in the stats)                                     */
/* ------------------------------------------------------------------ */

static int fr_at(const uint32_t *w, int n, int i)
{
    return i >= 0 && i < n ? w[i] : 0;
}

static int fr_vowel(uint32_t c)
{
    switch (c) {
    case 'a': case 'e': case 'i': case 'o': case 'u': case 'y':
    case 0xE2: case 0xE0: case 0xE9: case 0xE8: case 0xEA: case 0xEB:
    case 0xEE: case 0xEF: case 0xF4: case 0xF9: case 0xFB: case 0xFC:
    case 0xE6: case 0x153: case 0xFF:
        return 1;
    }
    return 0;
}

/* nasal vowel: base symbol + combining tilde (the fr map carries U+0303
 * as its own entry, matching how the voice was trained) */
static void fr_nasal(uint32_t base)
{
    fr_put_cp((uint32_t)(unsigned char)base);
    fr_put_cp(0x303);
}

static int fr_word_eq(const uint32_t *w, int n, const char *s)
{
    int i;
    for (i = 0; i < n; i++) {
        if (!s[i] || w[i] != (uint32_t)(unsigned char)s[i]) return 0;
    }
    return s[n] == 0;
}

/* Truncate the word at its pronounced end: final -e -s -t -d -x -z are
 * usually silent, -ent (verb-like, 4+ letters after a consonant) drops
 * entirely, -er keeps 'e' only. KEEP lists common exceptions. */
static int fr_trim_final(const uint32_t *w, int n)
{
    static const char *const KEEP[] = {
        "est", "ouest", "net", "but", "chat", "huit", "brut", "sud",
        "chef", "neuf", "serf", "cerf", "or", "mer", "hier", "cher",
        "fier", "amer", "hiver", "fer", "cul", "fil", "avril", "sel",
        "sens", "chose", "case", "texts", NULL,
    };
    int end = n;
    int k;
    for (k = 0; KEEP[k]; k++)
        if (fr_word_eq(w, n, KEEP[k])) return n;
    if (end >= 3 && w[end - 3] == 'e' && w[end - 2] == 'n' && w[end - 1] == 't'
            && end >= 5 && !fr_vowel(w[end - 4])) {
        return end - 3;                     /* -ent verb ending */
    }
    if (end >= 2 && w[end - 2] == 'e' && w[end - 1] == 'r') {
        return end - 1;                     /* -er keeps the e */
    }
    while (end >= 2) {
        uint32_t c = w[end - 1];
        if (c == 'e' || c == 's' || c == 't' || c == 'd' || c == 'x'
                || c == 'z') {
            end--;
            continue;
        }
        break;
    }
    return end ? end : n;
}

static void fr_l2s(const uint32_t *w, int n)
{
    int end = fr_trim_final(w, n);
    int i = 0;
    while (i < end) {
        uint32_t c = w[i], c1 = fr_at(w, end, i + 1), c2 = fr_at(w, end, i + 2);
        int next_v = fr_vowel(c1);
        if (c == '-' || fr_is_apos(c)) { i++; continue; }
        /* three-letter groups */
        if (c == 'a' && c1 == 'i' && (c2 == 'n' || c2 == 'm')
                && i + 3 <= end) {
            fr_nasal(0x25B); i += 3; continue;
        }
        if (c == 'e' && c1 == 'i' && (c2 == 'n' || c2 == 'm')
                && i + 3 <= end) {
            fr_nasal(0x25B); i += 3; continue;
        }
        if (c == 'o' && c1 == 'i' && c2 == 'n' && i + 3 <= end) {
            fr_put_cp('w'); fr_nasal(0x25B); i += 3; continue;
        }
        if (c == 'i' && c1 == 'e' && c2 == 'n' && i + 3 <= end) {
            fr_put_cp('j'); fr_nasal(0x25B); i += 3; continue;
        }
        if (c == 'e' && c1 == 'a' && c2 == 'u') { fr_put_cp('o'); i += 3; continue; }
        if (c == 'a' && c1 == 'u' && c2 == 'x') { fr_put_cp('o'); i += 3; continue; }
        if (c == 'o' && c1 == 'e' && c2 == 'u') { fr_put_cp(0xF8); i += 3; continue; }
        if (c == 0x153 && c1 == 'u') { fr_put_cp(0xF8); i += 2; continue; }
        if (c == 'u' && c1 == 'i' && c2 == 'e') {
            fr_put_cp(0x265); fr_put_cp('i'); i += 2; continue;
        }
        /* two-letter groups */
        if (c == 'o' && c1 == 'i') { fr_put_cp('w'); fr_put_cp('a'); i += 2; continue; }
        if (c == 'a' && c1 == 'i') { fr_put_cp(0x25B); i += 2; continue; }
        if (c == 'e' && c1 == 'i') { fr_put_cp(0x25B); i += 2; continue; }
        if (c == 'a' && c1 == 'u') { fr_put_cp('o'); i += 2; continue; }
        if (c == 'e' && c1 == 'u') { fr_put_cp(0xF8); i += 2; continue; }
        if (c == 'o' && c1 == 'u') { fr_put_cp('u'); i += 2; continue; }
        if (c == 'a' && c1 == 'y') { fr_put_cp(0x25B); fr_put_cp('j'); i += 2; continue; }
        if (c == 'e' && c1 == 'y') { fr_put_cp(0x25B); fr_put_cp('j'); i += 2; continue; }
        if (c == 'c' && c1 == 'h') { fr_put_cp(0x283); i += 2; continue; }
        if (c == 'p' && c1 == 'h') { fr_put_cp('f'); i += 2; continue; }
        if (c == 'g' && c1 == 'n') { fr_put_cp(0x272); i += 2; continue; }
        if (c == 'q' && c1 == 'u') { fr_put_cp('k'); i += 2; continue; }
        if (c == 'g' && c1 == 'u' && fr_vowel(c2)) { fr_put_cp('g'); i += 2; continue; }
        if (c == 's' && c1 == 's') { fr_put_cp('s'); i += 2; continue; }
        if (c == 'i' && c1 == 'l' && c2 == 'l' && i + 2 < end) {
            fr_put_cp('j'); i += 3; continue;
        }
        /* nasal vowel groups: only before a consonant other than n/m */
        if ((c == 'a' || c == 'e' || c == 'o' || c == 'u' || c == 'i'
             || c == 0xE2 || c == 0xE0 || c == 0xEA || c == 0xEE)
                && (c1 == 'n' || c1 == 'm') && !fr_vowel(c2) && c2 != 'n'
                && c2 != 'm' && i + 2 <= end) {
            uint32_t base = 0x251;
            if (c == 'o') base = 0x254;
            if (c == 'u' || c == 'i' || c == 0xEE) base = 0x25B;
            fr_nasal(base);
            i += 2;
            continue;
        }
        /* singles */
        switch (c) {
        case 'a': fr_put_cp('a'); break;
        case 0xE2: case 0xE0: fr_put_cp(0x251); break;
        case 'e': fr_put_cp(i + 1 == end ? 0x259 : 'e'); break;
        case 0xE9: case 0xE8: case 0xEA: fr_put_cp('e'); break;
        case 0xEB: fr_put_cp(0x25B); break;
        case 'i': case 0xEE: case 0xEF: case 'y': case 0xFF:
            fr_put_cp('i'); break;
        case 'o': case 0xF4: fr_put_cp('o'); break;
        case 'u': case 0xF9: case 0xFB: case 0xFC: fr_put_cp('y'); break;
        case 0xE6: fr_put_cp('e'); break;
        case 0x153: fr_put_cp(0xF8); break;
        case 'b': fr_put_cp('b'); break;
        case 'c': fr_put_cp(next_v ? 's' : 'k'); break;
        case 0xE7: fr_put_cp('s'); break;
        case 'd': fr_put_cp('d'); break;
        case 'f': fr_put_cp('f'); break;
        case 'g': fr_put_cp(next_v ? 0x292 : 'g'); break;
        case 'j': fr_put_cp(0x292); break;
        case 'k': fr_put_cp('k'); break;
        case 'l': fr_put_cp('l'); break;
        case 'm': fr_put_cp('m'); break;
        case 'n': fr_put_cp('n'); break;
        case 'p': fr_put_cp('p'); break;
        case 'q': fr_put_cp('k'); break;
        case 'r': fr_put_cp(0x281); break;
        case 's':
            fr_put_cp(fr_vowel(fr_at(w, end, i - 1)) && fr_vowel(c1)
                      ? 'z' : 's');
            break;
        case 't': fr_put_cp('t'); break;
        case 'v': fr_put_cp('v'); break;
        case 'w': fr_put_cp('v'); break;
        case 'x': fr_put_cp('k'); fr_put_cp('s'); break;
        case 'z': fr_put_cp('z'); break;
        default: break;   /* h and anything unknown: silent */
        }
        i++;
    }
}

/* ------------------------------------------------------------------ */
/* Numbers                                                              */
/* ------------------------------------------------------------------ */

static const char *const FR_UNITS[] = {
    "zéro", "un", "deux", "trois", "quatre", "cinq", "six", "sept",
    "huit", "neuf", "dix", "onze", "douze", "treize", "quatorze",
    "quinze", "seize",
};

static const char *const FR_TENS[] = {
    "", "", "vingt", "trente", "quarante", "cinquante", "soixante",
};

/* spell 0..999999 as lexicon words; words separated by spaces. Returns 0
 * ok, -1 out of range. */
static int fr_spell_cardinal(uint64_t n, int first)
{
    uint64_t t = (n / 10) * 10, r = n % 10;
    if (n > 999999) return -1;
    if (!first) fr_put_space();
    if (n < 17) { fr_lookup(FR_UNITS[n], (uint16_t)strlen(FR_UNITS[n])); return 0; }
    if (n < 20) {
        fr_lookup("dix", 3); fr_put_space();
        fr_lookup(FR_UNITS[n - 10], (uint16_t)strlen(FR_UNITS[n - 10]));
        return 0;
    }
    if (n < 70) {
        fr_lookup(FR_TENS[t / 10], (uint16_t)strlen(FR_TENS[t / 10]));
        if (r == 1) { fr_put_space(); fr_lookup("et", 2); fr_put_space();
                      fr_lookup("un", 2); }
        else if (r) { fr_put_space();
                      fr_lookup(FR_UNITS[r], (uint16_t)strlen(FR_UNITS[r])); }
        return 0;
    }
    if (n < 80) {
        fr_lookup("soixante", 8);
        if (n == 71) { fr_put_space(); fr_lookup("et", 2); fr_put_space();
                       fr_lookup("onze", 4); return 0; }
        return fr_spell_cardinal(n - 60, 0);
    }
    if (n < 100) {
        if (n == 80) { fr_lookup("quatre-vingts", 13); return 0; }
        fr_lookup("quatre-vingt", 12);
        return fr_spell_cardinal(n - 80, 0);
    }
    if (n < 200) {
        fr_lookup("cent", 4);
        if (n != 100) return fr_spell_cardinal(n - 100, 0);
        return 0;
    }
    if (n < 1000) {
        uint64_t h = n / 100;
        fr_lookup(FR_UNITS[h], (uint16_t)strlen(FR_UNITS[h]));
        fr_put_space();
        fr_lookup(n % 100 ? "cent" : "cents", n % 100 ? 4 : 5);
        if (n % 100) return fr_spell_cardinal(n % 100, 0);
        return 0;
    }
    {
        uint64_t th = n / 1000;
        if (th == 1) fr_lookup("mille", 5);
        else { fr_spell_cardinal(th, 0); fr_put_space(); fr_lookup("mille", 5); }
        if (n % 1000) return fr_spell_cardinal(n % 1000, 0);
        return 0;
    }
}

/* ordinal: 1 premier, 2 deuxième, otherwise the cardinal words (the
 * lexicon carries the composed ordinal forms the generator enumerated;
 * for larger numbers the cardinal is a safe approximation) */
static int fr_spell_ordinal(uint64_t n, int first)
{
    if (!first) fr_put_space();
    if (n == 1) { fr_lookup("premier", 7); return 0; }
    if (n == 2) { fr_lookup("deuxième", strlen("deuxième")); return 0; }
    if (n == 3) { fr_lookup("troisième", strlen("troisième")); return 0; }
    return fr_spell_cardinal(n, 1);
}

/* ------------------------------------------------------------------ */
/* Word flush                                                           */
/* ------------------------------------------------------------------ */

/* Emit one word group: elision split at an apostrophe (host form + rest),
 * plain dict lookup, rule layer on a miss. */
static void fr_flush_word(const uint32_t *w, int wi)
{
    char key[NANO_LEX_FR_MAX_KEY + 1];
    const uint8_t *codes;
    uint16_t cn;
    size_t wl = 0, split = 0;
    int k, has_apos = 0;

    /* one space per word join: the timing sidecar's word spans hang off
     * the piper space id, exactly like the English path */
    if (g_len > 0) fr_put_space();
    g_fr_stats.tokens++;
    for (k = 0; k < wi; k++) {
        size_t nb = fr_utf8_enc(key + wl, w[k]);
        if (wl + nb > NANO_LEX_FR_MAX_KEY) { wl = 0; break; }
        wl += nb;
    }
    if (wl == 0) return;
    key[wl] = 0;
    for (k = 0; k < (int)wl; k++)
        if (key[k] == 0x27) { has_apos = 1; split = (size_t)k; break; }

    g_fr_stats.lexicon_words++;
    /* whole word first: running text in the lexicon keeps apostrophe words
     * whole (aujourd'hui), so the elision split is the fallback, not the
     * default */
    if (fr_dict_find(key, (uint16_t)wl, &codes, &cn)) {
        fr_emit_dict_entry(codes, cn);
        return;
    }
    if (has_apos && split > 0 && split + 1 < wl) {
        /* host form (l', d', qu', jusqu', ...) + rest */
        g_fr_stats.lexicon_words++;
        key[split] = 0;
        if (fr_lookup(key, (uint16_t)split)) {
            g_fr_stats.lexicon_words++;
            if (fr_lookup(key + split + 1, (uint16_t)(wl - split - 1))) {
                return;                             /* both spoken */
            }
            /* rest missing: rule layer over the suffix letters */
            g_fr_stats.oov_words++;
            fr_l2s(w + split + 1, wi - (int)split - 1);
            return;
        }
        key[split] = 0x27;                          /* restore */
    }
    g_fr_stats.oov_words++;
    fr_l2s(w, wi);
}

/* ------------------------------------------------------------------ */
/* Public entry                                                         */
/* ------------------------------------------------------------------ */

void nano_lex_fr_get_stats(nano_lex_fr_stats_t *out)
{
    if (out) *out = g_fr_stats;
}

const char *nano_lex_fr_strerror(int rc)
{
    switch (rc) {
    case NFR_OK: return "ok";
    case NFR_E_NULL_ARG: return "null argument";
    case NFR_E_BAD_CAP: return "cap too small";
    case NFR_E_EMPTY_TEXT: return "empty text";
    case NFR_E_BAD_UTF8: return "malformed UTF-8";
    case NFR_E_TEXT_LONG: return "text too long";
    case NFR_E_CAP: return "output truncated";
    default: return "unknown";
    }
}

#define FR_MAX_CODEPOINTS 1024

int nano_lex_fr_text_to_phonemes(const char *text, char *out, size_t cap)
{
    uint32_t w[FR_MAX_CODEPOINTS];
    char digits[24];
    int wi = 0, nd = 0, rc = NFR_OK;
    int have_out = 0;
    const char *p = text;

    memset(&g_fr_stats, 0, sizeof g_fr_stats);
    if (!text || !out) return NFR_E_NULL_ARG;
    if (cap < 2) return NFR_E_BAD_CAP;
    fr_reset(out, cap);

    while (*p) {
        uint32_t c = fr_utf8_next(&p);
        if (c == 0xFFFD) { rc = NFR_E_BAD_UTF8; goto done; }
        if (fr_is_digit(c)) {
            if (nd < (int)sizeof digits - 1) digits[nd++] = (char)c;
            continue;
        }

        /* a word or number group ended; letters may continue a number as
         * an ordinal suffix (1er, 2e, 21ème) */
        if (nd > 0 && fr_is_letter(c)) {
            /* collect up to 3 suffix letters into the word buffer */
            uint64_t val = 0;
            int k;
            uint32_t sfx[4];
            int ns = 0;
            digits[nd] = 0;
            for (k = 0; k < nd; k++) val = val * 10 + (uint64_t)(digits[k] - '0');
            while (fr_is_letter(*p) && ns < 3) {
                sfx[ns++] = fr_lower(fr_utf8_next(&p));
            }
            /* c (the letter that ended the digit run) is the FIRST suffix
             * letter; sfx[0..ns-1] continue it. Patterns: er, e, è, ème,
             * eme, de. */
            int ordinal = 0;
            if (c == 'e' && sfx[0] == 'r' && ns == 1) ordinal = 1;
            else if (c == 'e' && ns == 0) ordinal = 1;
            else if (c == 0xE8 && ns == 0) ordinal = 1;
            else if ((c == 0xE8 || c == 'e') && sfx[0] == 'm' && sfx[1] == 'e'
                     && ns == 2) ordinal = 1;
            else if (c == 'd' && sfx[0] == 'e' && ns == 1) ordinal = 1;
            g_fr_stats.tokens++;
            if (have_out) fr_put_space();
            if (val <= 999999 && ordinal) {
                fr_spell_ordinal(val, 1);
            } else if (val <= 999999) {
                fr_spell_cardinal(val, 1);
                /* the suffix letters begin a word group of their own */
                wi = 0;
                if (fr_is_letter(c) && wi < FR_MAX_CODEPOINTS) w[wi++] = c;
                for (k = 0; k < ns; k++)
                    if (wi < FR_MAX_CODEPOINTS) w[wi++] = sfx[k];
            } else {
                /* >6 digits: read digit-wise */
                for (k = 0; k < nd; k++) {
                    uint32_t d = (uint32_t)(digits[k] - '0');
                    if (k) fr_put_space();
                    fr_lookup(FR_UNITS[d], (uint16_t)strlen(FR_UNITS[d]));
                }
            }
            have_out = 1;
            nd = 0;
            /* fall through: any suffix letters left in sfx beyond the
             * recognized patterns were consumed as-is (counted OOV) */
            if (ns == 3 && !(sfx[0] == 'e' && sfx[1] == 'm' && sfx[2] == 'e')
                    && !(sfx[0] == 'd' && sfx[1] == 'e')) {
                g_fr_stats.oov_words++;
            }
            continue;
        }
        if (fr_is_letter(c)) {
            if (wi < FR_MAX_CODEPOINTS) w[wi++] = fr_lower(c);
            continue;
        }
        if (nd > 0) {
            uint64_t val = 0;
            int k;
            digits[nd] = 0;
            for (k = 0; k < nd; k++) val = val * 10 + (uint64_t)(digits[k] - '0');
            g_fr_stats.tokens++;
            if (have_out) fr_put_space();
            if (val <= 999999) {
                fr_spell_cardinal(val, 1);
            } else {
                for (k = 0; k < nd; k++) {
                    uint32_t d = (uint32_t)(digits[k] - '0');
                    if (k) fr_put_space();
                    fr_lookup(FR_UNITS[d], (uint16_t)strlen(FR_UNITS[d]));
                }
            }
            have_out = 1;
            nd = 0;
            /* the letter run that follows becomes a fresh word group */
            if (fr_is_letter(c)) {
                if (wi < FR_MAX_CODEPOINTS) w[wi++] = fr_lower(c);
            }
            continue;
        }
        /* letter group ended */
        if (fr_is_apos(c) && wi > 0) {
            if (wi < FR_MAX_CODEPOINTS) w[wi++] = 0x27;
            continue;
        }
        if (c == '-' && wi > 0) {
            if (wi < FR_MAX_CODEPOINTS) w[wi++] = 0x2D;
            continue;
        }
        fr_flush_word(w, wi);
        if (g_len > 0) have_out = 1;
        wi = 0;
    }
    if (nd > 0) {
        uint64_t val = 0;
        int k;
        digits[nd] = 0;
        for (k = 0; k < nd; k++) val = val * 10 + (uint64_t)(digits[k] - '0');
        g_fr_stats.tokens++;
        if (have_out) fr_put_space();
        if (val <= 999999) fr_spell_cardinal(val, 1);
        else for (k = 0; k < nd; k++) {
            uint32_t d = (uint32_t)(digits[k] - '0');
            if (k) fr_put_space();
            fr_lookup(FR_UNITS[d], (uint16_t)strlen(FR_UNITS[d]));
        }
        have_out = 1;
    }
    if (wi > 0) fr_flush_word(w, wi);

done:
    fr_finish();
    g_fr_stats.arena_peak = (uint16_t)(g_len < 65535 ? g_len : 65535);
    if (g_len == 0 && rc == NFR_OK) return NFR_E_EMPTY_TEXT;
    if (g_truncated) return NFR_E_CAP;
    return (int)g_len;
}
