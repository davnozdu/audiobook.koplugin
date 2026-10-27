/* snt_ids_driver.c -- phoneme-ids file -> WAV for the int8/pq8/f32 engines.
 *
 * Test driver for the kernel A/B gates (dev/snt-ab.sh --ids mode): synthesis
 * without espeak, so it runs anywhere (host x86, qemu-arm, on device).  The
 * per-engine pipeline mirrors snt_server.c's clause path exactly (OOV drop,
 * pause-scale, length-scale, arena sizing), which cancels out in an A/B
 * because both sides run this same driver.
 *
 * Usage:
 *   snt_ids_driver --engine int8|pq8|f32 --model DIR --ids FILE --out WAV
 *       [--pause-scale F] [--length-scale F]
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "snt_tts.h"
#include "snt_front_q8.h"
#include "snt_piperlite_q8.h"
#include "snt_front_f32.h"
#include "snt_piperlite.h"

#define BOS_ID 1
#define EOS_ID 2
#define PAD_ID 0

typedef struct { FILE *fh; long n; } WavSink;

static int wav_cb(const float *pcm, int n, void *user) {
    WavSink *w = (WavSink *)user;
    for (int i = 0; i < n; i++) {
        float s = pcm[i];
        if (s > 1.0f) s = 1.0f;
        else if (s < -1.0f) s = -1.0f;
        int16_t v = (int16_t)(s * 32767.0f);
        if (fwrite(&v, sizeof v, 1, w->fh) != 1) return 1;
        w->n++;
    }
    return 0;
}

static void put_u32(FILE *fh, uint32_t v) { fwrite(&v, 4, 1, fh); }
static void put_u16(FILE *fh, uint16_t v) { fwrite(&v, 2, 1, fh); }

static void write_header(FILE *fh, uint32_t data_bytes, uint32_t rate) {
    uint32_t chunk = 36 + data_bytes, byte_rate = rate * 2;
    uint16_t fmt = 1, chan = 1, align = 2, bits = 16;
    fwrite("RIFF", 1, 4, fh); put_u32(fh, chunk); fwrite("WAVE", 1, 4, fh);
    fwrite("fmt ", 1, 4, fh); put_u32(fh, 16);
    put_u16(fh, fmt); put_u16(fh, chan); put_u32(fh, rate); put_u32(fh, byte_rate);
    put_u16(fh, align); put_u16(fh, bits);
    fwrite("data", 1, 4, fh); put_u32(fh, data_bytes);
}

static void *xload(const char *path, size_t *bytes) {
    FILE *fh = fopen(path, "rb");
    if (!fh) { fprintf(stderr, "driver: missing %s\n", path); exit(1); }
    fseek(fh, 0, SEEK_END);
    long sz = ftell(fh);
    fseek(fh, 0, SEEK_SET);
    void *buf = malloc((size_t)sz);
    if (!buf || fread(buf, 1, (size_t)sz, fh) != (size_t)sz) { fprintf(stderr, "driver: short read %s\n", path); exit(1); }
    fclose(fh);
    if (bytes) *bytes = (size_t)sz;
    return buf;
}

/* Same OOV drop as snt_server.c drop_oov_ids: an id outside [0, vocab) is
 * dropped together with its trailing PAD. */
static int drop_oov(int32_t *ids, int n, int vocab) {
    int k = 0;
    for (int i = 0; i < n; i++) {
        if (ids[i] != PAD_ID && (ids[i] < 0 || ids[i] >= vocab)) {
            if (i + 1 < n && ids[i + 1] == PAD_ID) i++;
            continue;
        }
        ids[k++] = ids[i];
    }
    return k;
}

int main(int argc, char **argv) {
    const char *engine = NULL, *model = NULL, *ids_path = NULL, *out_path = NULL;
    float pause_scale = 1.0f, length_scale = 0.0f;
    int rate = 22050;

    for (int i = 1; i < argc - 1; i++) {
        if (!strcmp(argv[i], "--engine")) engine = argv[i + 1];
        else if (!strcmp(argv[i], "--model")) model = argv[i + 1];
        else if (!strcmp(argv[i], "--ids")) ids_path = argv[i + 1];
        else if (!strcmp(argv[i], "--out")) out_path = argv[i + 1];
        else if (!strcmp(argv[i], "--pause-scale")) pause_scale = (float)atof(argv[i + 1]);
        else if (!strcmp(argv[i], "--length-scale")) length_scale = (float)atof(argv[i + 1]);
    }
    if (!engine || !model || !ids_path || !out_path) {
        fprintf(stderr, "usage: %s --engine int8|pq8|f32 --model DIR --ids FILE --out WAV "
                        "[--pause-scale F] [--length-scale F]\n", argv[0]);
        return 2;
    }

    size_t nb;
    int32_t *ids = (int32_t *)xload(ids_path, &nb);
    int n_ids = (int)(nb / 4);

    FILE *fh = fopen(out_path, "wb");
    if (!fh) { fprintf(stderr, "driver: cannot write %s\n", out_path); return 1; }
    write_header(fh, 0, (uint32_t)rate);
    WavSink sink = {fh, 0};

    char p[512];
    int rc = -1;
    snt_stats st;
    long frames = 0;

    if (!strcmp(engine, "int8")) {
        snprintf(p, sizeof p, "%s/front_q8.bin", model);
        void *front = xload(p, NULL);
        snprintf(p, sizeof p, "%s/model_q8.bin", model);
        void *dec = xload(p, NULL);
        if (length_scale > 0.0f) snt_length_scale = 1.08f * length_scale;
        size_t arena_size = (1u << 20) + (size_t)n_ids * 8192;
        void *arena = malloc(arena_size);
        snt_config cfg = {front, dec, arena, arena_size, NULL, 0};
        rc = snt_synthesize(&cfg, ids, n_ids, wav_cb, &sink, &st);
        free(arena); free(front); free(dec);
    } else if (!strcmp(engine, "pq8")) {
        snprintf(p, sizeof p, "%s/front_meta_q8.bin", model);
        size_t fm_nb; void *fm = xload(p, &fm_nb);
        snprintf(p, sizeof p, "%s/front_weights_q8.bin", model);
        size_t fw_nb; void *fw = xload(p, &fw_nb);
        snprintf(p, sizeof p, "%s/meta_q8.bin", model);
        size_t dm_nb; void *dm = xload(p, &dm_nb);
        snprintf(p, sizeof p, "%s/weights_q8.bin", model);
        size_t dw_nb; void *dw = xload(p, &dw_nb);
        snt_front_q8_model fq;
        snt_piperlite_q8_model dq;
        if (snt_front_q8_init(&fq, fm, fm_nb, (const int8_t *)fw, fw_nb) != 0) { fprintf(stderr, "driver: front init\n"); return 1; }
        if (snt_piperlite_q8_init(&dq, dm, dm_nb, (const int8_t *)dw, dw_nb) != 0) { fprintf(stderr, "driver: dec init\n"); return 1; }
        n_ids = drop_oov(ids, n_ids, fq.d_vocab);
        if (n_ids <= 2) { fprintf(stderr, "driver: nothing survived OOV drop\n"); return 1; }

        static int32_t durs[4096];
        float ls = length_scale > 0.0f ? length_scale : 1.0f;
        size_t arena_size = 16u << 20;
        void *arena = malloc(arena_size);
        frames = snt_front_q8_durations(&fq, ids, n_ids, ls, durs, arena, arena_size);
        if (frames < 0) { fprintf(stderr, "driver: durations rc %ld\n", frames); return 1; }
        if (pause_scale != 1.0f) {
            long total = 0;
            for (int i = 0; i < n_ids; i++) {
                if (ids[i] == 4 || ids[i] == 8 || ids[i] == 10 ||
                    ids[i] == 11 || ids[i] == 12 || ids[i] == 13) {
                    long scaled = (long)(durs[i] * pause_scale + 0.5f);
                    durs[i] = (int32_t)(scaled < 1 ? 1 : scaled);
                }
                total += durs[i];
            }
            frames = total;
        }
        size_t la = snt_front_q8_latent_arena_bytes(&fq, n_ids, frames);
        size_t da = snt_piperlite_q8_arena_bytes(&dq, (int)frames);
        size_t need = la > da ? la : da;
        void *ar = need > arena_size ? malloc(need) : arena;
        float *latent = malloc(sizeof(float) * (size_t)fq.a_out * (size_t)frames);
        float *audio = malloc(sizeof(float) * (size_t)frames * SNT_PIPERLITE_Q8_HOP);
        rc = snt_front_q8_latent(&fq, ids, durs, n_ids, (int)frames, latent, ar, la);
        if (rc == 0) rc = snt_piperlite_q8_synthesize(&dq, latent, (int)frames, audio, ar, da);
        if (rc == 0) {
            long n = (long)frames * SNT_PIPERLITE_Q8_HOP;
            if (wav_cb(audio, (int)n, &sink) != 0) rc = -1;
        }
        free(latent); free(audio);
        if (ar != arena) free(ar);
        free(arena); free(fm); free(fw); free(dm); free(dw);
    } else if (!strcmp(engine, "f32")) {
        snprintf(p, sizeof p, "%s/front_meta.bin", model);
        size_t fm_nb; void *fm = xload(p, &fm_nb);
        snprintf(p, sizeof p, "%s/front_weights_f32.bin", model);
        size_t fw_nb; void *fw = xload(p, &fw_nb);
        snprintf(p, sizeof p, "%s/dec_meta.bin", model);
        size_t dm_nb; void *dm = xload(p, &dm_nb);
        snprintf(p, sizeof p, "%s/dec_weights_f32.bin", model);
        size_t dw_nb; void *dw = xload(p, &dw_nb);
        snt_front_model fmf;
        snt_piperlite_model dfm;
        if (snt_front_init(&fmf, fm, fm_nb, (const float *)fw, fw_nb / 4) != 0) { fprintf(stderr, "driver: front init\n"); return 1; }
        if (snt_piperlite_init(&dfm, dm, dm_nb, (const float *)dw, dw_nb / 4) != 0) { fprintf(stderr, "driver: dec init\n"); return 1; }
        n_ids = drop_oov(ids, n_ids, fmf.d_vocab);
        if (n_ids <= 2) { fprintf(stderr, "driver: nothing survived OOV drop\n"); return 1; }

        static int32_t durs[4096];
        float ls = length_scale > 0.0f ? length_scale : 1.0f;
        size_t arena_floats = 4u << 20;
        float *arena = malloc(arena_floats * 4);
        frames = snt_front_durations(&fmf, ids, n_ids, ls, durs, arena, arena_floats);
        if (frames < 0) { fprintf(stderr, "driver: durations rc %ld\n", frames); return 1; }
        if (pause_scale != 1.0f) {
            long total = 0;
            for (int i = 0; i < n_ids; i++) {
                if (ids[i] == 4 || ids[i] == 8 || ids[i] == 10 ||
                    ids[i] == 11 || ids[i] == 12 || ids[i] == 13) {
                    long scaled = (long)(durs[i] * pause_scale + 0.5f);
                    durs[i] = (int32_t)(scaled < 1 ? 1 : scaled);
                }
                total += durs[i];
            }
            frames = total;
        }
        size_t la = snt_front_latent_arena_floats(&fmf, n_ids, (int)frames);
        size_t da = snt_piperlite_arena_floats(&dfm, (int)frames);
        size_t need = la > da ? la : da;
        float *ar = need > arena_floats ? malloc(need * 4) : arena;
        float *latent = malloc(sizeof(float) * (size_t)fmf.a_out * (size_t)frames);
        float *audio = malloc(sizeof(float) * (size_t)frames * SNT_PIPERLITE_HOP);
        rc = snt_front_latent(&fmf, ids, durs, n_ids, (int)frames, latent, ar, la);
        if (rc == 0) rc = snt_piperlite_synthesize(&dfm, latent, (int)frames, audio, ar, da);
        if (rc == 0) {
            long n = (long)frames * SNT_PIPERLITE_HOP;
            if (wav_cb(audio, (int)n, &sink) != 0) rc = -1;
        }
        free(latent); free(audio);
        if (ar != arena) free(ar);
        free(arena); free(fm); free(fw); free(dm); free(dw);
    } else {
        fprintf(stderr, "driver: unknown engine %s\n", engine);
        fclose(fh);
        return 2;
    }

    long data_bytes = sink.n * 2;
    fseek(fh, 0, SEEK_SET);
    write_header(fh, (uint32_t)data_bytes, (uint32_t)rate);
    fclose(fh);
    fprintf(stderr, "driver: ids %d frames %ld samples %ld rc %d\n",
            n_ids, frames, sink.n, rc);
    return rc == 0 ? 0 : 1;
}
