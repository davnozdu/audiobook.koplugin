/* audioout.c -- owned audio-output daemon for audiobook.koplugin (Tier 2).
 *
 * One long-lived process drives the device's GStreamer pipeline (Kobo MTK
 * vendor sink for now), accepts clip commands over an AF_UNIX socket, and
 * reports a REAL rendered-position clock derived from a sink-pad probe.
 * Replaces the duplicated shell-wrapper FIFO pipelines in ttsengine.lua and
 * mediaengine.lua. Design and on-device measurements:
 * dev/audioout/PLAN.md (M0, 2026-10-14).
 *
 * Pipeline (topology unchanged from the proven production one, fed by us):
 *   filesrc location=FIFO ! rawaudioparse ... ! audioconvert ! audioresample
 *     ! audio/x-raw,format=S16LE,rate=48000,channels=2
 *     ! queue max-size-time=500000000 max-size-bytes=131072
 *     ! [volume name=vol] ! mtkbtmwrpcaudiosink name=sink sync=false
 *
 * Units: the FIFO carries INPUT-rate PCM (the clip's rate); the sink gets
 * 48 kHz stereo. The clock is tracked in MILLISECONDS on both sides, never
 * raw bytes across the boundary:
 *   feed side    ms = input_bytes * 1000 / (rate * channels * 2)
 *   clock side   ms = output_bytes / 192        (48000 * 4 B/frame)
 *
 * Clock model (M0-verified on the vendor sink): buffers reach the sink
 * ~1.5 s at a time, one per render period, real-time paced. When buffer i
 * (spanning output bytes S_i..S_i+b_i) is accepted at wall time W_i, the
 * sink begins rendering S_i at W_i, so
 *     rendered(T) = boundary_ms + (T - arrival_ms)      capped at accepted
 * gst_element_query_position is available on this sink and logged as a
 * cross-check only.
 *
 * Protocol: one JSON object per line in, one JSON line per response.
 * Events are pushed best-effort to whichever client is connected at push
 * time (a client that polls per command will miss pushes, so any fact the
 * client must not miss is ALSO latched in status). Commands:
 *   {"cmd":"play","path":"...","gap_ms":300,"rate":22050,"channels":1}
 *       Queue a WAV clip (append). A rate/channels change vs the running
 *       pipeline rebuilds it internally and drops any queued clips.
 *   {"cmd":"pause"}    stop feeding clips, feed silence (in-flight buffered
 *                      audio still plays out; same semantics as the old
 *                      feeder pause)
 *   {"cmd":"resume","pos_ms":N}   resume feeding; with pos_ms (external
 *                      mode only) the stream re-epochs at that position
 *   {"cmd":"stop"}     drop the queue, keep the A2DP link with silence
 *   {"cmd":"flush"}    drop the queue AND restart the pipeline (instant
 *                      silence, drops buffered audio too)
 *   {"cmd":"seek","pos_ms":N,"total_ms":N}   external mode: drop the old
 *                      stream's bytes, re-epoch the clock at pos_ms
 *   {"cmd":"external","rate":R,"channels":C,"alsa_device":"...","pos_ms":N,
 *    "total_ms":N}    external stream mode; pos_ms/total_ms place the
 *                      clock on the client's timeline (book position)
 *   {"cmd":"status"}   state/pos_ms/accepted_ms/fed_ms/done_count/queue/...
 *                      plus external_done (latched stream completion)
 *   {"cmd":"volume","value_x1000":800}
 *   {"cmd":"ping"} / {"cmd":"shutdown"}
 * Queue: 8 clips. When it runs dry the daemon feeds silence to hold the
 * A2DP link (replaces the 120 s keepalive WAV).
 *
 * Build: dev/audioout/build-daemon.sh (Jessie 2.19 sysroot, bare run under
 * the device loader, dlopens the device's libgstreamer-1.0).
 */

#include <gst/gst.h>

#ifdef AUDIOOUT_WITH_LIBAV
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libswresample/swresample.h>
#include <libavutil/opt.h>
#endif

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#ifdef AUDIOOUT_WITH_LIBAV
/* ffmpeg builds with _FILE_OFFSET_BITS=64, which remaps fcntl to
 * fcntl64; the Jessie glibc (2.19) stub library does not export that
 * symbol for static linking. fcntl64 is fcntl with a pointer-wide third
 * argument on this ABI, so forward it (ffmpeg only uses F_GETFL and
 * FD_CLOEXEC-style commands). */
#include <stdarg.h>
#undef fcntl
int fcntl64(int fd, int cmd, ...) {
    va_list ap;
    va_start(ap, cmd);
    void *arg = va_arg(ap, void *);
    va_end(ap);
    return fcntl(fd, cmd, arg);
}
#define fcntl fcntl64
#endif
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#define SOCKET_PATH_DEFAULT "/tmp/audiobook_audioout.sock"
#define FIFO_PATH_DEFAULT "/tmp/audiobook_audioout_fifo"
#define MAX_QUEUE 8
#define MAX_PATH 1024
#define LINE_MAX_LEN 2048
/* Bounded writes keep the poll loop responsive to commands. */
#define FEED_CHUNK (32 * 1024)
/* Pacing: keep the pipeline at most this many ms ahead of the audible
 * position.  The mtk sink accepts without backpressure, so an unbounded
 * feed lets the pipeline swallow the whole queue in seconds and the
 * firmware/ring then drops or delays it unpredictably (see
 * dev/audioout/FINDING-2026-10-19-instant-completion.md). */
#define FEED_LEAD_MS 3000
#define SILENCE_CHUNK (8 * 1024)
#define F_SETPIPE_SZ 1031
/* Output caps: S16LE stereo 48 kHz. */
#define OUT_BYTES_PER_MS 192

/* ------------------------------------------------------------------ */
/* GStreamer via dlopen, soft-bound (the device build strips optional   */
/* symbols; M0 listed exactly which survive).                           */
/* ------------------------------------------------------------------ */

typedef struct {
    void *gst;
    void *gobj;                 /* libgobject, optional (live volume) */
    void (*gst_init)(int *, char ***);
    GstElement *(*gst_parse_launch)(const gchar *, GError **);
    GstStateChangeReturn (*gst_element_set_state)(GstElement *, GstState);
    GstBus *(*gst_element_get_bus)(GstElement *);
    GstMessage *(*gst_bus_poll)(GstBus *, GstMessageType, GstClockTime);
    void (*gst_message_parse_error)(GstMessage *, GError **, gchar **);
    void (*gst_object_unref)(gpointer);
    GstElement *(*gst_bin_get_by_name)(GstBin *, const gchar *);
    GstPad *(*gst_element_get_static_pad)(GstElement *, const gchar *);
    gulong (*gst_pad_add_probe)(GstPad *, GstPadProbeType, GstPadProbeCallback,
                                gpointer, GDestroyNotify);
    gsize (*gst_buffer_get_size)(GstBuffer *);
    gboolean (*gst_element_query_position)(GstElement *, GstFormat, gint64 *);
    GstStateChangeReturn (*gst_element_get_state)(GstElement *, GstState *,
                                                  GstState *, GstClockTime);
    gboolean (*gst_element_factory_find)(const gchar *);
    void (*g_object_set)(gpointer, const gchar *, ...);
} GstApi;

static GstApi G;

/* ALSA via dlopen (BlueZ Kobos: the bluealsa PCM).  Bound lazily and only
 * used when the output is ALSA, so the MTK build path never touches it. */
typedef struct {
    void *alsa;                 /* libasound.so.2 handle */
    int (*snd_pcm_open)(void **, const char *, int, int);
    int (*snd_pcm_close)(void *);
    int (*snd_pcm_set_params)(void *, int, int, unsigned int, unsigned int,
                              int, unsigned int);
    long (*snd_pcm_writei)(void *, const void *, unsigned long);
    int (*snd_pcm_nonblock)(void *, int);
    int (*snd_pcm_recover)(void *, int, int);
    int (*snd_pcm_delay)(void *, long *);
    int (*snd_pcm_prepare)(void *);
    int (*snd_pcm_drop)(void *);
} AlsaApi;

static AlsaApi A;

#define SND_PCM_STREAM_PLAYBACK 0
#define SND_PCM_FORMAT_S16_LE   2
#define SND_PCM_ACCESS_RW_INTERLEAVED 3

static void log_line(const char *fmt, ...);

/* ------------------------------------------------------------------ */
/* In-process decode (AUDIOOUT_WITH_LIBAV, Tier 5b)                     */
/*                                                                      */
/* A decoder-subset ffmpeg is linked statically (see                    */
/* build-ffmpeg-libs.sh): any non-WAV clip or external stream is        */
/* demuxed and decoded to s16 PCM in-process, which retires the         */
/* per-track ffmpeg exec and the 30 MB bundled binary for compressed    */
/* input. Clients keep their WAV path unchanged: clip_open sniffs the   */
/* file. The client ffmpeg feeder stays for speed != 1.0 (atempo is     */
/* client-side).                                                        */
/* ------------------------------------------------------------------ */

#ifdef AUDIOOUT_WITH_LIBAV

typedef struct {
    AVFormatContext *fmt;
    const AVCodec *codec;
    AVCodecContext *ctx;
    AVPacket *pkt;
    AVFrame *frame;
    SwrContext *swr;
    int stream;
    int eof;
    /* leftover converted PCM not yet consumed by the caller */
    unsigned char obuf[16384];
    size_t olen, opos;
} DecState;

static void dec_close(DecState *d) {
    if (!d) return;
    if (d->swr) swr_free(&d->swr);
    if (d->frame) av_frame_free(&d->frame);
    if (d->pkt) av_packet_free(&d->pkt);
    if (d->ctx) avcodec_free_context(&d->ctx);
    if (d->fmt) avformat_close_input(&d->fmt);
    free(d);
}

/* Open path for in-process decode. Returns 0 and *out (caller frees via
 * dec_close), negative on any failure (caller falls back to WAV-only or
 * refuses). */
static int dec_open(const char *path, DecState **out, long long *duration_ms,
                    int *rate, int *channels) {
    *out = NULL;
    DecState *d = calloc(1, sizeof *d);
    if (!d) return -1;
    if (avformat_open_input(&d->fmt, path, NULL, NULL) != 0) {
        log_line("dec open: avformat_open_input failed for %s", path);
        goto fail;
    }
    if (avformat_find_stream_info(d->fmt, NULL) < 0) {
        log_line("dec open: find_stream_info failed for %s", path);
        goto fail;
    }
    d->stream = av_find_best_stream(d->fmt, AVMEDIA_TYPE_AUDIO, -1, -1,
                                    &d->codec, 0);
    if (d->stream < 0 || !d->codec) {
        log_line("dec open: no audio stream for %s (rc %d)", path, d->stream);
        goto fail;
    }
    AVStream *st = d->fmt->streams[d->stream];
    d->ctx = avcodec_alloc_context3(d->codec);
    if (!d->ctx) goto fail;
    if (avcodec_parameters_to_context(d->ctx, st->codecpar) < 0) goto fail;
    d->ctx->pkt_timebase = st->time_base;
    if (avcodec_open2(d->ctx, d->codec, NULL) < 0) goto fail;
    log_line("dec: stream=%d codec=%s rate=%d fmt=%d ch=%d",
             d->stream, d->codec ? d->codec->name : "?",
             d->ctx->sample_rate, d->ctx->sample_fmt,
             d->ctx->ch_layout.nb_channels);
    int orate = d->ctx->sample_rate > 0 ? d->ctx->sample_rate : 44100;
    int och = d->ctx->ch_layout.nb_channels > 0
        ? d->ctx->ch_layout.nb_channels : 2;
    if (swr_alloc_set_opts2(&d->swr,
                            &d->ctx->ch_layout, AV_SAMPLE_FMT_S16, orate,
                            &d->ctx->ch_layout, d->ctx->sample_fmt,
                            d->ctx->sample_rate, 0, NULL) < 0) goto fail;
    if (swr_init(d->swr) < 0) goto fail;
    d->pkt = av_packet_alloc();
    d->frame = av_frame_alloc();
    if (!d->pkt || !d->frame) goto fail;
    long long dur = 0;
    if (d->fmt->duration > 0)
        dur = d->fmt->duration * 1000LL / AV_TIME_BASE;
    else if (st->duration > 0 && st->time_base.den)
        dur = st->duration * 1000LL * st->time_base.num / st->time_base.den;
    if (dur <= 0 && d->fmt->bit_rate > 0)
        dur = (long long)d->fmt->pb ? 0
              : 0;  /* bitrate estimate needs the size; keep 0 = unknown */
    if (dur <= 0) {
        log_line("dec open: no duration for %s", path);
        goto fail;
    }
    *duration_ms = dur;
    *rate = orate;
    *channels = och;
    *out = d;
    return 0;
fail:
    dec_close(d);
    return -1;
}

/* Convert one received frame into the output buffer (appends). */
static void dec_convert(DecState *d, AVFrame *f) {
    int out_samples = swr_get_out_samples(d->swr, f->nb_samples);
    if (out_samples <= 0) out_samples = f->nb_samples + 16;
    size_t need = (size_t)out_samples * d->ctx->ch_layout.nb_channels * 2 + 64;
    if (need > sizeof d->obuf - d->olen) {
        /* compact first; a frame larger than the free space is clipped by
         * swr to what fits */
        if (d->opos > 0) {
            memmove(d->obuf, d->obuf + d->opos, d->olen - d->opos);
            d->olen -= d->opos;
            d->opos = 0;
        }
        if (need > sizeof d->obuf - d->olen) out_samples =
            (int)((sizeof d->obuf - d->olen - 64)
                  / (size_t)(d->ctx->ch_layout.nb_channels * 2));
        if (out_samples <= 0) return;
    }
    uint8_t *dstp = d->obuf + d->olen;
    int got = swr_convert(d->swr, &dstp, out_samples,
                          (const uint8_t **)f->extended_data, f->nb_samples);
    if (got > 0) d->olen += (size_t)got * d->ctx->ch_layout.nb_channels * 2;
}

/* Pull up to `want` bytes of s16 PCM; returns bytes pulled (0 = EOF). */
static size_t dec_pull(DecState *d, unsigned char *out, size_t want) {
    size_t total = 0;
    while (total < want) {
        if (d->opos < d->olen) {
            size_t take = d->olen - d->opos;
            if (take > want - total) take = want - total;
            memcpy(out + total, d->obuf + d->opos, take);
            d->opos += take;
            total += take;
            continue;
        }
        d->olen = 0;
        d->opos = 0;
        if (d->eof) break;
        /* drain the decoder first */
        int r = avcodec_receive_frame(d->ctx, d->frame);
        if (r == 0) { dec_convert(d, d->frame); av_frame_unref(d->frame); continue; }
        if (r == AVERROR_EOF) { d->eof = 1; break; }
        if (r != EAGAIN) {
            /* decode error: skip the packet rather than spinning */
        }
        if (av_read_frame(d->fmt, d->pkt) < 0) {
            avcodec_send_packet(d->ctx, NULL);   /* drain */
            continue;
        }
        if (d->pkt->stream_index == d->stream)
            avcodec_send_packet(d->ctx, d->pkt);
        av_packet_unref(d->pkt);
    }
    return total;
}

/* Re-position the decoder (external file mode seek). */
static int dec_seek(DecState *d, long long pos_ms) {
    int64_t ts = (int64_t)(pos_ms / 1000.0 * AV_TIME_BASE);
    int r = avformat_seek_file(d->fmt, -1, INT64_MIN, ts, ts, 0);
    if (r < 0) return -1;
    avcodec_flush_buffers(d->ctx);
    swr_init(d->swr);
    d->olen = 0;
    d->opos = 0;
    d->eof = 0;
    return 0;
}

#endif /* AUDIOOUT_WITH_LIBAV */

typedef struct {
    char path[MAX_PATH];
    int fd;
    unsigned long long data_offset;
    unsigned long long data_size;   /* PCM bytes */
    unsigned long long file_pos;    /* next byte to feed */
    int in_bps;                     /* input bytes per second */
    long long duration_ms;
    long long gap_ms_after;
    long long start_ms;             /* stream position of first PCM */
    long long end_ms;               /* start + duration + gap */
#ifdef AUDIOOUT_WITH_LIBAV
    void *dec;                      /* DecState* when the clip is decoded */
#endif
} Clip;

static struct {
    GstElement *pipe;
    GstElement *sink;
    GstBus *bus;
    int pipe_rate, pipe_channels;
    double volume;
    int pipeline_retries;
    long long pipeline_last_fail_ms;

    char fifo_path[MAX_PATH];
    int fifo_fd;
    unsigned long long fifo_written;    /* input bytes handed to the fifo */

    Clip queue[MAX_QUEUE];
    int queue_len;
    int feed_idx;                       /* clip being fed, -1 = none active */
    int all_fed;                        /* every queued clip written out */
    long long gap_left_ms;              /* silence owed before the next clip */
    int paused;

    long long fed_end_ms;               /* end of everything queued so far */
    unsigned long long done_count;
    int announce_idle;

    /* External stream mode (media path): an outside writer (ffmpeg) feeds
     * the fifo; the daemon builds the pipeline, stays off the stream, and
     * reports position from the probe clock. Positions are on the CLIENT's
     * timeline (book position), not since-pipeline-build: every fresh
     * stream announces its start position and length (pos_ms/total_ms) and
     * epoch_off_ms converts the since-build probe counters into that
     * timeline. */
    int external_active;
    int external_wait_first;            /* rebaseline base at first movement
                                           (legacy no-pos resume) */
#ifdef AUDIOOUT_WITH_LIBAV
    int ext_dec_eof;                    /* decoded stream fully delivered */
#endif
    long long epoch_off_ms;             /* client ms at since-build intake 0 */
    long long external_total_ms;        /* stream length from the client */
    int external_done;                  /* latched completion flag */
    long long external_base_ms;
    long long external_frozen_ms;       /* position while paused */
    long long external_anchor_wall_ms;  /* wall time the stream's first
                                           buffer reached the sink */
    int anchor_wait;                    /* set on a fresh pipeline or
                                           resume: anchor the audible clock
                                           at the next sink acceptance */

    /* Acceptance pacing: a healthy A2DP sink accepts at real time.  A sink
     * with a dead peer (D-Bus still lists it) swallows buffers at decode
     * speed, which runs the clock and the read-along highlight away. */
    int unpaced;
    long long pace_last_acc_ms;
    long long pace_last_wall_ms;
    int pace_fast_ticks;
    long long pace_arm_ms;              /* grace: sink warm-up after play */

    /* ALSA output (BlueZ Kobos).  No GStreamer pipeline: the daemon feeds
     * the bluealsa PCM directly and the kernel driver paces acceptance. */
    int out_alsa;
    char alsa_device[MAX_PATH];
    void *alsa_pcm;
    int alsa_rate, alsa_channels;
    unsigned long long alsa_written_frames;

    long long next_ka_ms;               /* wall time the next keepalive
                                           silence chunk may be written */
#ifdef AUDIOOUT_WITH_LIBAV
    void *ext_dec;                      /* DecState* for external file mode */
#endif
    int listen_fd;
    int client_fd;
} S;


/* ------------------------------------------------------------------ */
/* Clock                                                                */
/* ------------------------------------------------------------------ */

static void log_line(const char *fmt, ...);

static pthread_mutex_t probe_lock = PTHREAD_MUTEX_INITIALIZER;
static unsigned long long probe_bytes;      /* total accepted output bytes */
static unsigned long long probe_last_buf;   /* size of the newest buffer */

/* Main-thread copies refreshed each tick. */
static unsigned long long acc_bytes;
static long long acc_boundary_ms;           /* stream ms where the newest
                                               buffer STARTS rendering */
static long long acc_arrival_ms;            /* wall ms of that arrival */
static long long wall_now;
static int probe_seen;

static long long
mono_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static GstPadProbeReturn
probe_cb(GstPad *pad, GstPadProbeInfo *info, gpointer user) {
    (void)pad;
    (void)user;
    GstBuffer *buf = GST_PAD_PROBE_INFO_BUFFER(info);
    if (!buf) return GST_PAD_PROBE_OK;
    gsize sz = G.gst_buffer_get_size(buf);
    pthread_mutex_lock(&probe_lock);
    probe_last_buf = (unsigned long long)sz;
    probe_bytes += (unsigned long long)sz;
    pthread_mutex_unlock(&probe_lock);
    return GST_PAD_PROBE_OK;
}

static void
refresh_clock(void) {
    unsigned long long b, last;
    pthread_mutex_lock(&probe_lock);
    b = probe_bytes;
    last = probe_last_buf;
    pthread_mutex_unlock(&probe_lock);
    if (b != acc_bytes || (b > 0 && !probe_seen)) {
        probe_seen = 1;
        acc_bytes = b;
        acc_boundary_ms = (long long)((b > last ? b - last : 0) / OUT_BYTES_PER_MS);
        acc_arrival_ms = wall_now;
        if (S.external_active && S.external_wait_first) {
            S.external_base_ms =
                (long long)(acc_bytes / OUT_BYTES_PER_MS) - acc_boundary_ms;
            S.external_wait_first = 0;
        }
        if (S.anchor_wait) {
            S.external_base_ms =
                (long long)(acc_bytes / OUT_BYTES_PER_MS) - acc_boundary_ms;
            S.external_anchor_wall_ms = acc_arrival_ms;
            S.anchor_wait = 0;
            log_line("ANCHOR base=%lld wall=%lld acc=%lld frozen=%lld paused=%d",
                     S.external_base_ms, S.external_anchor_wall_ms,
                     (long long)(acc_bytes / OUT_BYTES_PER_MS),
                     S.external_frozen_ms, S.paused);
        }
    }
}

/* ALSA position: hardware delay tells exactly how many frames are still
 * between written and played. Shifted by the client-timeline epoch so an
 * external stream started at a book offset reports book positions. */
static long long alsa_pos_ms(void);

static long long
alsa_pos_ms(void) {
    if (!S.alsa_pcm) return 0;
    long d = 0;
    if (A.snd_pcm_delay && A.snd_pcm_delay(S.alsa_pcm, &d) != 0) d = 0;
    if (d < 0) d = 0;
    long long written = (long long)S.alsa_written_frames;
    long long pos = written - d;
    int r = S.alsa_rate > 0 ? S.alsa_rate : 44100;
    if (pos < 0) pos = 0;
    return S.epoch_off_ms + pos * 1000LL / r;
}

/* Rendered stream position in ms (M0 model), capped at accepted. */
static long long
rendered_ms(void) {
    if (S.out_alsa) return alsa_pos_ms();
    if (!probe_seen || acc_bytes == 0) return 0;
    long long est = acc_boundary_ms + (wall_now - acc_arrival_ms);
    long long acc = (long long)(acc_bytes / OUT_BYTES_PER_MS);
    if (est < 0) est = 0;
    if (est > acc) est = acc;
    return est;
}

/* Audible stream position in external mode.  The mtk sink accepts buffers
 * without backpressure (they drain into the Bluetooth firmware), so no
 * acceptance-derived clock represents what the listener hears: a firehose
 * acceptance sweeps any intake-based model past clips that are still
 * playing, which made every clip "complete" within a second of queueing.
 * Instead, anchor once when the stream's first buffer reaches the sink and
 * advance at audio rate from that anchor; underruns hold at the last
 * delivered sample (min with the intake position); pauses freeze at the
 * frozen value until the client rebaselines on resume.
 *
 * The intake clamp carries a tail allowance: on the real vendor sink the
 * LAST partial transport batch (queue 500 ms + firmware, ~700-1000 ms) is
 * committed to playback but never crosses the pad probe, so clamping
 * strictly at intake froze completion ~750 ms short of every clip end.
 * The allowance bounds the overshoot; real positions re-clamp once the
 * keepalive pushes intake forward again. */
#define AUDIBLE_TAIL_SLACK_MS 1000

static long long
audible_ms(void) {
    if (S.paused) return S.external_frozen_ms;
    if (S.anchor_wait || acc_bytes == 0) return S.external_frozen_ms;
    long long est = S.epoch_off_ms + S.external_base_ms
                  + (wall_now - S.external_anchor_wall_ms);
    long long acc = S.epoch_off_ms
                  + (long long)(acc_bytes / OUT_BYTES_PER_MS)
                  + AUDIBLE_TAIL_SLACK_MS;
#ifdef AUDIOOUT_WITH_LIBAV
    /* The decoded stream is fully delivered: the last partial transport
     * batch never crosses the pad probe, so the intake clamp would freeze
     * the clock short of the announced total. The anchor alone is truth. */
    if (S.ext_dec_eof) acc = est + AUDIBLE_TAIL_SLACK_MS;
#endif
    if (est > acc) est = acc;
    long long lo = S.epoch_off_ms + S.external_base_ms;
    if (est < lo) est = lo;
    return est;
}

/* ------------------------------------------------------------------ */
/* Daemon state                                                         */
/* ------------------------------------------------------------------ */

static const char *g_socket_path = SOCKET_PATH_DEFAULT;
static const char *g_sink_name = "mtkbtmwrpcaudiosink";
static const char *g_output = "auto";   /* auto | mtk | alsa */
static int g_rate = 22050, g_channels = 1;
static long long g_started_ms;

/* ------------------------------------------------------------------ */
/* Helpers                                                              */
/* ------------------------------------------------------------------ */

static void
log_line(const char *fmt, ...) {
    va_list ap;
    long long t = mono_ms() - g_started_ms;
    fprintf(stderr, "[%lld.%03lld] ", t / 1000, t % 1000);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    fflush(stderr);
}

/* Flat-object JSON field extraction, snt_server style: enough for
 * machine-written command lines, no escaping (paths have no quotes). */
static int
json_find(const char *json, const char *key, char *out, size_t outsz) {
    char pat[64];
    snprintf(pat, sizeof pat, "\"%s\"", key);
    const char *p = strstr(json, pat);
    if (!p) return -1;
    p = strchr(p + strlen(pat), ':');
    if (!p) return -1;
    p++;
    while (*p == ' ' || *p == '\t') p++;
    if (*p == '"') {
        p++;
        size_t n = 0;
        /* Unescape the standard JSON escapes: KOReader's encoder writes
         * "/" as "\/", and an unescaped path fails to open. */
        while (*p && *p != '"') {
            char c = *p++;
            if (c == '\\' && *p) {
                char e = *p++;
                if (e == '/' || e == '"' || e == '\\') c = e;
                else if (e == 'n') c = '\n';
                else if (e == 't') c = '\t';
                else if (e == 'r') c = '\r';
                else c = e;
            }
            if (n + 1 < outsz) out[n++] = c;
        }
        out[n] = 0;
        return 0;
    }
    size_t n = 0;
    while (*p && *p != ',' && *p != '}' && *p != ']' && *p != ' '
           && *p != '\t' && *p != '\n' && *p != '\r') {
        if (n + 1 < outsz) out[n++] = *p++;
        else p++;
    }
    out[n] = 0;
    return 1;
}

static long long
json_num(const char *json, const char *key, long long dflt) {
    char v[64];
    if (json_find(json, key, v, sizeof v) < 0) return dflt;
    return strtoll(v, NULL, 10);
}

/* ------------------------------------------------------------------ */
/* WAV parsing (chunk walk; TTS WAVs are plain s16 PCM)                 */
/* ------------------------------------------------------------------ */

static int
clip_open(Clip *c, const char *path, int rate, int channels) {
    memset(c, 0, sizeof *c);
    snprintf(c->path, sizeof c->path, "%s", path);
    c->fd = open(path, O_RDONLY);
    if (c->fd < 0) {
        log_line("clip open failed: %s (%s)", path, strerror(errno));
        return -1;
    }
    unsigned char hdr[12];
    if (pread(c->fd, hdr, 12, 0) == 12 &&
        (memcmp(hdr, "RIFF", 4) != 0 || memcmp(hdr + 8, "WAVE", 4) != 0)) {
        /* Not a WAV: in-process decode (Tier 5b). The pread check above
         * also rejects short/garbage files the demuxer would reject. */
#ifdef AUDIOOUT_WITH_LIBAV
        long long dur = 0;
        int drate = 0, dch = 0;
        DecState *d = NULL;
        if (dec_open(path, &d, &dur, &drate, &dch) == 0) {
            c->dec = d;
            c->in_bps = drate * dch * 2;
            if (c->in_bps <= 0) c->in_bps = 44100;
            c->duration_ms = dur;
            /* nominal PCM size so remaining/end accounting works */
            c->data_size = (unsigned long long)(dur * (long long)c->in_bps / 1000);
            close(c->fd);
            c->fd = -1;
            log_line("clip decoded in-process: %s (%lld ms, %d Hz x %d ch)",
                     path, dur, drate, dch);
            return 0;
        }
        log_line("clip decode open failed, not RIFF either: %s", path);
#endif
        goto fail;
    }
    if (pread(c->fd, hdr, 12, 0) != 12 ||
        memcmp(hdr, "RIFF", 4) != 0 || memcmp(hdr + 8, "WAVE", 4) != 0) {
        log_line("clip not RIFF/WAVE: %s", path);
        goto fail;
    }
    unsigned long long off = 12;
    int fmt_bits = 0;
    for (;;) {
        unsigned char ch[8];
        if (pread(c->fd, ch, 8, off) != 8) break;
        unsigned long long sz = ch[4] | (ch[5] << 8) |
                                ((unsigned long long)ch[6] << 16) |
                                ((unsigned long long)ch[7] << 24);
        if (!memcmp(ch, "fmt ", 4) && sz >= 16) {
            unsigned char fmt[16];
            if (pread(c->fd, fmt, 16, off + 8) == 16)
                fmt_bits = fmt[14] | (fmt[15] << 8);
        } else if (!memcmp(ch, "data", 4)) {
            c->data_offset = off + 8;
            c->data_size = sz;
            c->file_pos = off + 8;
            break;
        }
        off += 8 + sz + (sz & 1);
    }
    if (c->data_size == 0 || (fmt_bits != 0 && fmt_bits != 16)) {
        log_line("clip unusable (data=%llu bits=%d): %s",
                 c->data_size, fmt_bits, path);
        goto fail;
    }
    c->in_bps = rate * channels * 2;
    if (c->in_bps <= 0) c->in_bps = 44100;
    c->duration_ms = (long long)((c->data_size * 1000ull) /
                                 (unsigned long long)c->in_bps);
    return 0;
fail:
    close(c->fd);
    c->fd = -1;
    return -1;
}

/* ------------------------------------------------------------------ */
/* Pipeline lifecycle                                                   */
/* ------------------------------------------------------------------ */

static const unsigned char silence_chunk[SILENCE_CHUNK];

static int
pipeline_build(int rate, int channels) {
    S.anchor_wait = 1;
    S.external_frozen_ms = 0;
    char launch[1600];
    char vol[64] = "";
    if (G.gst_element_factory_find && G.gst_element_factory_find("volume"))
        snprintf(vol, sizeof vol, " ! volume name=vol volume=%.3f", S.volume);
    snprintf(launch, sizeof launch,
        "filesrc location=\"%s\""
        " ! rawaudioparse use-sink-caps=false format=pcm pcm-format=s16le"
        " sample-rate=%d num-channels=%d"
        " ! audioconvert ! audioresample"
        " ! audio/x-raw,format=S16LE,rate=48000,channels=2"
        " ! queue max-size-time=500000000 max-size-bytes=131072"
        "%s"
        " ! %s name=sink sync=false",
        S.fifo_path, rate, channels, vol, g_sink_name);
    log_line("pipeline: %s", launch);

    GError *err = NULL;
    GstElement *pipe = G.gst_parse_launch(launch, &err);
    if (!pipe) {
        log_line("parse_launch failed: %s",
                 err && err->message ? err->message : "?");
        return -1;
    }
    S.pipe = pipe;
    S.sink = G.gst_bin_get_by_name(GST_BIN(pipe), "sink");
    if (S.sink) {
        GstPad *pad = G.gst_element_get_static_pad(S.sink, "sink");
        if (pad)
            G.gst_pad_add_probe(pad, GST_PAD_PROBE_TYPE_BUFFER, probe_cb,
                                NULL, NULL);
        else
            log_line("WARNING: sink has no static pad; no clock");
        S.bus = G.gst_element_get_bus(pipe);
    }
    if (G.gst_element_set_state(pipe, GST_STATE_PLAYING) ==
        GST_STATE_CHANGE_FAILURE) {
        /* Pull the bus error so failures are diagnosable off-device. */
        char errbuf[256] = "";
        if (S.bus) {
            GstMessage *msg = G.gst_bus_poll(S.bus, GST_MESSAGE_ERROR, 500);
            if (msg) {
                GError *e = NULL;
                gchar *dbg = NULL;
                G.gst_message_parse_error(msg, &e, &dbg);
                snprintf(errbuf, sizeof errbuf, "%s",
                         e && e->message ? e->message : "?");
                log_line("bus error: %s (%s)", errbuf, dbg ? dbg : "-");
            }
        }
        log_line("pipeline refused PLAYING%s%s",
                 errbuf[0] ? ": " : " (no bus error)", errbuf);
        return -1;
    }
    S.pipe_rate = rate;
    S.pipe_channels = channels;
    return 0;
}

/* ── ALSA output ─────────────────────────────────────────────────── */

static int
alsa_bind(void) {
    if (A.alsa) return 0;
    const char *names[] = { "libasound.so.2", "/lib/libasound.so.2", NULL };
    for (int i = 0; names[i] && !A.alsa; i++) {
        A.alsa = dlopen(names[i], RTLD_NOW | RTLD_LOCAL);
        if (A.alsa) log_line("dlopened %s", names[i]);
    }
    if (!A.alsa) {
        log_line("ALSA output requested but libasound is unavailable");
        return -1;
    }
#define ABIND(field, name) \
    A.field = dlsym(A.alsa, name); \
    if (!A.field) { log_line("FATAL: alsa %s not exported", name); return -1; }
    ABIND(snd_pcm_open, "snd_pcm_open")
    ABIND(snd_pcm_close, "snd_pcm_close")
    ABIND(snd_pcm_set_params, "snd_pcm_set_params")
    ABIND(snd_pcm_writei, "snd_pcm_writei")
    ABIND(snd_pcm_nonblock, "snd_pcm_nonblock")
    ABIND(snd_pcm_recover, "snd_pcm_recover")
    ABIND(snd_pcm_delay, "snd_pcm_delay")
    ABIND(snd_pcm_prepare, "snd_pcm_prepare")
    ABIND(snd_pcm_drop, "snd_pcm_drop")
#undef ABIND
    return 0;
}

/* Open (or reopen after a device/rate change) the bluealsa PCM.  The
 * "plug:" prefix makes libasound convert rate and channels, so clips can
 * stay at their native rate. */
static int
alsa_open(const char *device, int rate, int channels) {
    if (alsa_bind() != 0) return -1;
    if (S.alsa_pcm) {
        if (S.out_alsa && !strcmp(S.alsa_device, device)
                && S.alsa_rate == rate && S.alsa_channels == channels) {
            return 0;
        }
        A.snd_pcm_drop(S.alsa_pcm);
        A.snd_pcm_close(S.alsa_pcm);
        S.alsa_pcm = NULL;
    }
    void *pcm = NULL;
    int rc = A.snd_pcm_open(&pcm, device, SND_PCM_STREAM_PLAYBACK, 0);
    if (rc < 0) {
        log_line("alsa open %s failed: rc %d", device, rc);
        if (pcm) A.snd_pcm_close(pcm);
        return -1;
    }
    rc = A.snd_pcm_set_params(pcm, SND_PCM_FORMAT_S16_LE,
                              SND_PCM_ACCESS_RW_INTERLEAVED,
                              (unsigned)channels, (unsigned)rate,
                              1 /* allow libasound resampling */,
                              250000 /* 250 ms latency target */);
    if (rc < 0) {
        log_line("alsa set_params %s failed: %d", device, rc);
        A.snd_pcm_close(pcm);
        return -1;
    }
    A.snd_pcm_nonblock(pcm, 1);
    snprintf(S.alsa_device, sizeof S.alsa_device, "%s", device);
    S.alsa_rate = rate;
    S.alsa_channels = channels;
    S.alsa_pcm = pcm;
    S.alsa_written_frames = 0;
    log_line("alsa open ok: %s (%d Hz x %d ch)", device, rate, channels);
    return 0;
}

static void
alsa_teardown(void) {
    if (S.alsa_pcm) {
        A.snd_pcm_drop(S.alsa_pcm);
        A.snd_pcm_close(S.alsa_pcm);
        S.alsa_pcm = NULL;
    }
}

/* Non-blocking write; returns bytes accepted.  -EPIPE (underrun, happens
 * after pause starvation) recovers and retries once. */
static unsigned long long
alsa_write_raw(const unsigned char *buf, unsigned long long len) {
    unsigned long long total = 0;
    int frames_per_byte = S.alsa_channels * 2;
    while (total < len) {
        unsigned long long rem = len - total;
        long frames = (long)(rem / (unsigned long long)frames_per_byte);
        if (frames <= 0) break;
        long n = A.snd_pcm_writei(S.alsa_pcm, buf + total, (unsigned long)frames);
        if (n > 0) {
            total += (unsigned long long)n * (unsigned long long)frames_per_byte;
            S.alsa_written_frames += (unsigned long long)n;
            continue;
        }
        if (n == -EAGAIN) break;
        if (n == -EPIPE) {
            if (A.snd_pcm_prepare(S.alsa_pcm) == 0) continue;
        }
        log_line("alsa write error: %ld", n);
        break;
    }
    return total;
}

/* Software s16 scaling for the ALSA path (the gst path has the volume
 * element). Scaled into a staging buffer so const or aliased inputs are
 * never mutated. Values above 1.0 clip; the gst element saturates the same
 * way, so the knob keeps its range on both outputs. */
static unsigned char alsa_stage[FEED_CHUNK];

static unsigned long long
alsa_write(const unsigned char *buf, unsigned long long len) {
    if (S.volume > 0.999 && S.volume < 1.001)
        return alsa_write_raw(buf, len);
    unsigned long long total = 0;
    while (total < len) {
        unsigned long long chunk = len - total;
        if (chunk > sizeof alsa_stage) chunk = sizeof alsa_stage;
        const unsigned char *p = buf + total;
        unsigned long long even = chunk & ~1ULL;   /* whole samples */
        for (unsigned long long i = 0; i < even; i += 2) {
            int16_t s = (int16_t)(p[i] | (p[i + 1] << 8));
            int32_t v = (int32_t)((double)s * S.volume);
            if (v > 32767) v = 32767;
            if (v < -32768) v = -32768;
            alsa_stage[i] = (unsigned char)(v & 0xff);
            alsa_stage[i + 1] = (unsigned char)((v >> 8) & 0xff);
        }
        if (even < chunk) alsa_stage[even] = p[even];
        unsigned long long w = alsa_write_raw(alsa_stage, chunk);
        total += w;
        if (w < chunk) break;
    }
    return total;
}

static void
pipeline_teardown(void) {
    if (S.pipe) {
        /* Unblock filesrc before stopping the pipeline. The fifo is held
         * O_RDWR (no EOF across rebuilds by design), so a starved filesrc
         * sits in a blocking read; gst_pad_stop_task then waits for that
         * task inside set_state(NULL) and the whole daemon deadlocks (the
         * 3 s wedge guard below never runs: set_state blocks first). One
         * burst of silence satisfies the pending read; the flushing check
         * after each fill ends the task. Writes are nonblocking, so a
         * fifo that is already full just returns EAGAIN. */
        if (S.fifo_fd >= 0) {
            for (int i = 0; i < 8; i++) {
                if (write(S.fifo_fd, silence_chunk, SILENCE_CHUNK) <= 0) break;
            }
        }
        G.gst_element_set_state(S.pipe, GST_STATE_NULL);
        if (G.gst_element_get_state) {
            GstState cur = GST_STATE_VOID_PENDING, pend = GST_STATE_VOID_PENDING;
            /* Closing the MTK sink waits on the BT stack, which a wedged
             * peer can block forever.  Bound the wait; if the sink will
             * not close, exit so the client respawns a fresh daemon
             * instead of every later command timing out.  The cast matters
             * on armhf: GST_SECOND is 10^9, which overflows a 32-bit long
             * when multiplied and silently turns the bound into ~forever. */
            G.gst_element_get_state(S.pipe, &cur, &pend,
                                    3 * (GstClockTime)GST_SECOND);
            if (cur != GST_STATE_NULL) {
                log_line("teardown wedged (state %d after 3s); exiting",
                         (int)cur);
                fflush(stderr);
                _exit(1);
            }
        }
        if (S.bus) G.gst_object_unref(S.bus);
        G.gst_object_unref(S.pipe);
        S.pipe = NULL;
        S.sink = NULL;
        S.bus = NULL;
    }
    if (S.fifo_fd >= 0) {
        close(S.fifo_fd);
        S.fifo_fd = -1;
    }
}

static void
reset_stream(void) {
    /* Call right after a pipeline rebuild: the old backlog died with it. */
    S.fifo_written = 0;
    S.fed_end_ms = 0;
    S.queue_len = 0;
    S.feed_idx = -1;
    S.all_fed = 1;
    S.gap_left_ms = 0;
    acc_bytes = 0;
    acc_boundary_ms = 0;
    acc_arrival_ms = 0;
    probe_seen = 0;
}

static int
fifo_open(void) {
    if (S.fifo_fd >= 0) return 0;
    if (mkfifo(S.fifo_path, 0600) != 0 && errno != EEXIST) {
        log_line("mkfifo %s failed: %s", S.fifo_path, strerror(errno));
        return -1;
    }
    /* O_RDWR: we hold both ends, so filesrc never sees EOF across pipeline
     * rebuilds. 16 KB pipe like the old feeder, to bound stale audio. */
    int fd = open(S.fifo_path, O_RDWR | O_NONBLOCK);
    if (fd < 0) {
        log_line("fifo open failed: %s (%s)", S.fifo_path, strerror(errno));
        return -1;
    }
    log_line("fifo open ok on fd %d", fd);
    fcntl(fd, F_SETPIPE_SZ, 16384);
    S.fifo_fd = fd;
    return 0;
}

/* Wait for the exclusive MTK abstract socket to be free, killing legacy
 * gst-launch orphans: the old startup dance, done once at daemon start. */
static void
claim_exclusive_socket(void) {
    for (int attempt = 0; attempt < 5; attempt++) {
        FILE *f = fopen("/proc/net/unix", "r");
        int held = 0;
        if (f) {
            char line[512];
            while (fgets(line, sizeof line, f)) {
                if (strstr(line, "@kobo:mtkbtmwrpc")) {
                    held = 1;
                    break;
                }
            }
            fclose(f);
        }
        if (!held) return;
        log_line("MTK socket held; killing legacy gst-launch (attempt %d)",
                 attempt + 1);
        system("killall -9 gst-launch-1.0 2>/dev/null");
        usleep(200000);
    }
    log_line("WARNING: MTK socket still held after retries");
}

/* ------------------------------------------------------------------ */
/* Queue + feeding                                                      */
/* ------------------------------------------------------------------ */

static int
queue_clip(const char *path, long long gap_ms) {
    Clip c;
    if (clip_open(&c, path, g_rate, g_channels) != 0) return -1;
    c.gap_ms_after = gap_ms;
    /* Clip positions live on the AUDIBLE timeline (what the listener has
     * heard), not the fifo-intake timeline: unpaced keepalive silence and
     * the firehose sink make intake race ahead of wall time, and a clip
     * whose end_ms is an intake position "completes" the moment the
     * audible clock passes it -- the TTS session then races through
     * sentences and pages. fed_end_ms only ever advances with real clips,
     * so stacking works; the intake position only bounds the lead. */
    long long base_ms = audible_ms();
    if (S.fed_end_ms > base_ms) base_ms = S.fed_end_ms;
    c.start_ms = base_ms;
    c.end_ms = c.start_ms + c.duration_ms + gap_ms;
    S.fed_end_ms = c.end_ms;
    S.all_fed = 0;
    S.announce_idle = 0;
    S.unpaced = 0;
    S.pace_fast_ticks = 0;
    S.pace_arm_ms = wall_now;
    S.queue[S.queue_len++] = c;
    log_line("queued %s dur=%lldms gap=%lldms span=[%lld..%lld]ms",
             path, c.duration_ms, gap_ms, c.start_ms, c.end_ms);
    return 0;
}

static unsigned long long
fifo_write(const unsigned char *buf, unsigned long long len) {
    if (S.out_alsa) {
        unsigned long long w = alsa_write(buf, len);
        S.fifo_written += w;
        return w;
    }
    unsigned long long total = 0;
    while (total < len) {
        ssize_t n = write(S.fifo_fd, buf + total, len - total);
        if (n > 0) {
            total += (unsigned long long)n;
            continue;
        }
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
        if (n < 0 && errno == EINTR) continue;
        log_line("fifo write error: %s", strerror(errno));
        break;
    }
    S.fifo_written += total;
    return total;
}

/* One feed tick: active clip, then inter-clip gap, then keepalive. */
static void
feed_tick(void) {
    if (S.external_active) {
        /* External file decode (Tier 5b): the daemon demuxes and decodes
         * the announced file itself, no outside writer. */
#ifdef AUDIOOUT_WITH_LIBAV
        if (S.ext_dec) {
            if (S.paused) {
                if (S.out_alsa) fifo_write(silence_chunk, SILENCE_CHUNK);
                return;
            }
            unsigned char buf[FEED_CHUNK];
            size_t n = dec_pull((DecState *)S.ext_dec, buf, FEED_CHUNK);
            if (n > 0) fifo_write(buf, n);
            else if (S.out_alsa) fifo_write(silence_chunk, SILENCE_CHUNK);
            return;
        }
#endif
        /* ALSA external mode: the daemon READS the fifo (ffmpeg writes it)
         * and writes the PCM; gst external mode leaves the fifo to filesrc.
         * While paused, feed keepalive silence so the link stays up. */
        if (!S.out_alsa) return;
        if (S.paused || S.fifo_fd < 0) {
            fifo_write(silence_chunk, SILENCE_CHUNK);
            return;
        }
        unsigned char buf[FEED_CHUNK];
        ssize_t n = read(S.fifo_fd, buf, sizeof buf);
        if (n > 0) alsa_write(buf, (unsigned long long)n);
        else if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
            log_line("fifo read error: %s", strerror(errno));
        }
        return;
    }
    if (S.paused || S.fifo_fd < 0) return;
    /* Keepalive silence holds the A2DP link and keeps filesrc's blocking
     * read unblocked (a starved src deadlocks the next teardown; see
     * pipeline_teardown). It is NEVER gated by the lead window, but it IS
     * rate-limited to real time: the firehose sink accepts as fast as we
     * write, and unthrottled silence would flood the BT firmware and race
     * the intake position far ahead of the audible clock. */
    if (S.feed_idx < 0 && S.queue_len == 0) {
        if (wall_now >= S.next_ka_ms) {
            fifo_write(silence_chunk, SILENCE_CHUNK);   /* idle keepalive */
            S.next_ka_ms = wall_now
                + (long long)SILENCE_CHUNK * 1000LL
                  / (g_rate * g_channels * 2);
        }
        return;
    }
    if (S.all_fed) {
        /* Queue fully written (possibly still rendering): keepalive. */
        if (wall_now >= S.next_ka_ms) {
            fifo_write(silence_chunk, SILENCE_CHUNK);
            S.next_ka_ms = wall_now
                + (long long)SILENCE_CHUNK * 1000LL
                  / (g_rate * g_channels * 2);
        }
        return;
    }
    /* Pace REAL audio (clips and gaps) against the audible position: the
     * listener has heard up to audible_ms(), the FIFO head is at
     * fifo_written; never let the lead exceed the window.  The fifo's own
     * EAGAIN backpressure only kicks in once every downstream buffer is
     * full, which on the firehose mtk sink is far too late.  Before the
     * anchor fires there is nothing to pace against: feed. */
    if (!S.anchor_wait) {
        long long fed_head_ms =
            (long long)((S.fifo_written * 1000ull) /
                        (unsigned long long)(g_rate * g_channels * 2));
        if (fed_head_ms - audible_ms() > FEED_LEAD_MS) {
            return;   /* enough buffered ahead; next tick */
        }
    }
    if (S.feed_idx < 0) S.feed_idx = 0;

    unsigned long long budget = FEED_CHUNK;
    unsigned char buf[FEED_CHUNK];
    while (budget > 0) {
        if (S.gap_left_ms > 0) {
            /* Gap silence at the INPUT byte rate of the pipeline. */
            long long gap_bytes = (long long)((double)S.gap_left_ms *
                                              (g_rate * g_channels * 2) / 1000.0);
            unsigned long long want = (unsigned long long)gap_bytes;
            if (want > budget) want = budget;
            if (want > SILENCE_CHUNK) want = SILENCE_CHUNK;
            unsigned long long w = fifo_write(silence_chunk, want);
            double wrote_ms = (double)w * 1000.0 / (g_rate * g_channels * 2);
            S.gap_left_ms -= (long long)(wrote_ms + 0.5);
            if (S.gap_left_ms < 0) S.gap_left_ms = 0;
            budget -= w;
            if (w < want) return;   /* fifo full */
            continue;
        }
        if (S.feed_idx >= S.queue_len) {
            S.all_fed = 1;
            return;
        }
        Clip *c = &S.queue[S.feed_idx];
        unsigned long long remaining =
            (c->data_offset + c->data_size) - c->file_pos;
        if (remaining == 0) {
            if (c->fd >= 0) {
                close(c->fd);
                c->fd = -1;
            }
#ifdef AUDIOOUT_WITH_LIBAV
            if (c->dec) { dec_close((DecState *)c->dec); c->dec = NULL; }
#endif
            S.gap_left_ms = c->gap_ms_after;
            S.feed_idx++;
            continue;
        }
        unsigned long long want = remaining < budget ? remaining : budget;
        ssize_t n;
#ifdef AUDIOOUT_WITH_LIBAV
        if (c->dec) {
            n = (ssize_t)dec_pull((DecState *)c->dec, buf, want);
        } else
#endif
        n = pread(c->fd, buf, want, c->file_pos);
        if (n <= 0) {
            log_line("clip read failed at %llu: %s", c->file_pos, c->path);
            if (c->fd >= 0) {
                close(c->fd);
                c->fd = -1;
            }
#ifdef AUDIOOUT_WITH_LIBAV
            if (c->dec) { dec_close((DecState *)c->dec); c->dec = NULL; }
#endif
            S.gap_left_ms = c->gap_ms_after;
            S.feed_idx++;
            continue;
        }
        unsigned long long w = fifo_write(buf, (unsigned long long)n);
        c->file_pos += w;
        budget -= w;
        if (w < (unsigned long long)n) return;   /* fifo full, next tick */
    }
}

/* ------------------------------------------------------------------ */
/* Socket                                                               */
/* ------------------------------------------------------------------ */

static void
send_line(const char *line) {
    if (S.client_fd < 0) return;
    size_t len = strlen(line);
    send(S.client_fd, line, len, MSG_DONTWAIT | MSG_NOSIGNAL);
}

static void
respond(const char *fmt, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    size_t l = strlen(buf);
    if (l < sizeof buf - 2) {
        buf[l] = '\n';
        buf[l + 1] = 0;
    }
    send_line(buf);
}

static const char *
state_str(void) {
    if (S.paused) return "paused";
    if (S.feed_idx >= 0 && !S.all_fed) return "playing";
    if (S.queue_len > 0) return "buffered";
    return "idle";
}

static void
drop_queue(void) {
    for (int i = 0; i < S.queue_len; i++) {
        if (S.queue[i].fd >= 0) close(S.queue[i].fd);
#ifdef AUDIOOUT_WITH_LIBAV
        if (S.queue[i].dec) { dec_close((DecState *)S.queue[i].dec); S.queue[i].dec = NULL; }
#endif
    }
    S.queue_len = 0;
    S.feed_idx = -1;
    S.all_fed = 1;
    S.gap_left_ms = 0;
}

/* Empty the fifo (O_NONBLOCK, so read returns EAGAIN at empty). A writer
 * must be dead: the client kills its feeder before re-epoching. */
static void
fifo_drain(void) {
    if (S.fifo_fd < 0) return;
    unsigned char tmp[4096];
    while (read(S.fifo_fd, tmp, sizeof tmp) > 0) {}
}

/* Begin a fresh stream epoch at client position pos_ms: drop every byte of
 * the old stream (queue, fifo backlog, pipeline) so none of it can leak
 * into the new one, zero the clocks, and let the first buffer of the new
 * stream re-anchor. S.paused is left untouched; the caller decides. Used by
 * external, seek and resume-with-pos. Returns -1 when the gst rebuild
 * failed. */
static int
stream_epoch(long long pos_ms, long long total_ms) {
    drop_queue();
    S.external_total_ms = total_ms;
    S.external_done = 0;
    S.announce_idle = 1;        /* the dead stream owes no idle event */
    S.unpaced = 0;
    S.pace_fast_ticks = 0;
    S.pace_arm_ms = wall_now;   /* warm-up grace applies to the new stream */
    if (S.out_alsa) {
        if (S.alsa_pcm) {
            A.snd_pcm_drop(S.alsa_pcm);
            A.snd_pcm_prepare(S.alsa_pcm);
        }
        fifo_open();
        fifo_drain();
        S.alsa_written_frames = 0;
    } else {
        pipeline_teardown();
        reset_stream();
        if (fifo_open() != 0) return -1;
        fifo_drain();
        if (pipeline_build(g_rate, g_channels) != 0) return -1;
    }
    S.epoch_off_ms = pos_ms;
    S.external_base_ms = 0;
    S.external_anchor_wall_ms = 0;
    S.external_frozen_ms = pos_ms;
    S.external_wait_first = 0;
    S.anchor_wait = 1;
    return 0;
}

static void
handle_command(char *line) {
    char cmd[32] = "";
    json_find(line, "cmd", cmd, sizeof cmd);

    if (!strcmp(cmd, "ping")) {
        respond("{\"ok\":true,\"uptime_ms\":%lld,\"bufs\":%llu"
#ifdef AUDIOOUT_WITH_LIBAV
                ",\"decoder\":1"
#endif
                "}",
                mono_ms() - g_started_ms, acc_bytes / OUT_BYTES_PER_MS);
    } else if (!strcmp(cmd, "play")) {
        char path[MAX_PATH] = "";
        json_find(line, "path", path, sizeof path);
        if (!path[0]) {
            respond("{\"ok\":false,\"error\":\"missing path\"}");
            return;
        }
        if (S.queue_len >= MAX_QUEUE) {
            respond("{\"ok\":false,\"error\":\"queue full\"}");
            return;
        }
        long long rate = json_num(line, "rate", g_rate);
        long long channels = json_num(line, "channels", g_channels);
        /* Lazy output build: the MTK vendor sink can stall tens of
         * seconds at init when no A2DP peer is connected (M0/M1 measured
         * ~26 s), and a stalled build at daemon start would hang the
         * client.  ALSA opens fail fast instead. */
        char alsa_dev[MAX_PATH] = "";
        json_find(line, "alsa_device", alsa_dev, sizeof alsa_dev);
        if (S.out_alsa) {
            const char *dev = (alsa_dev[0] || S.alsa_device[0])
                ? (alsa_dev[0] ? alsa_dev : S.alsa_device) : "default";
            if (fifo_open() != 0 || alsa_open(dev, (int)rate, (int)channels) != 0) {
                respond("{\"ok\":false,\"error\":\"alsa open failed\"}");
                return;
            }
        } else if (!S.pipe) {
            if (fifo_open() != 0 || pipeline_build((int)rate, (int)channels) != 0) {
                respond("{\"ok\":false,\"error\":\"pipeline build failed\"}");
                return;
            }
        }
        if (!S.out_alsa &&
                ((int)rate != S.pipe_rate || (int)channels != S.pipe_channels)) {
            log_line("rate change %dx%d -> %ldx%ld; rebuilding (queue dropped)",
                     S.pipe_rate, S.pipe_channels, rate, channels);
            drop_queue();
            if (S.out_alsa) {
                /* Reopen at the new rate; the device string is unchanged. */
                alsa_teardown();
                g_rate = (int)rate;
                g_channels = (int)channels;
                reset_stream();
                if (fifo_open() != 0 || alsa_open(S.alsa_device, g_rate,
                                                  g_channels) != 0) {
                    respond("{\"ok\":false,\"error\":\"alsa reopen failed\"}");
                    return;
                }
            } else {
                pipeline_teardown();
                g_rate = (int)rate;
                g_channels = (int)channels;
                reset_stream();
                if (fifo_open() != 0 || pipeline_build(g_rate, g_channels) != 0) {
                    respond("{\"ok\":false,\"error\":\"pipeline rebuild failed\"}");
                    return;
                }
            }
        }
        if (fifo_open() != 0) {
            respond("{\"ok\":false,\"error\":\"fifo open failed\"}");
            return;
        }
        if (queue_clip(path, json_num(line, "gap_ms", 0)) != 0) {
            respond("{\"ok\":false,\"error\":\"clip open failed\"}");
            return;
        }
        respond("{\"ok\":true,\"queue\":%d,\"fed_end_ms\":%lld,"
                "\"start_ms\":%lld,\"duration_ms\":%lld,"
                "\"done_count\":%llu}",
                S.queue_len, S.fed_end_ms,
                S.queue[S.queue_len - 1].start_ms,
                S.queue[S.queue_len - 1].duration_ms,
                S.done_count);
    } else if (!strcmp(cmd, "pause")) {
        /* Freeze the clock in EVERY mode: in clip mode the frozen value is
         * what status reports while paused, and a collapse to 0 here sent
         * the client's word tick (pos_ms - start_ms) far negative on every
         * auto-pause, scrambling the read-along highlight. */
        if (!S.paused) {
            S.external_frozen_ms = audible_ms();
            log_line("PAUSE freeze=%lld acc=%lld", S.external_frozen_ms,
                     (long long)(acc_bytes / OUT_BYTES_PER_MS));
        }
        S.paused = 1;
        respond("{\"ok\":true,\"state\":\"paused\"}");
    } else if (!strcmp(cmd, "resume")) {
        long long pos_ms = json_num(line, "pos_ms", -1);
        if (S.external_active && pos_ms >= 0) {
            /* Explicit client position: a new epoch at pos. The writer
             * restarts at pos after this command returns. */
#ifdef AUDIOOUT_WITH_LIBAV
            if (S.ext_dec) dec_seek((DecState *)S.ext_dec, pos_ms);
#endif
            if (stream_epoch(pos_ms, S.external_total_ms) != 0) {
                respond("{\"ok\":false,\"error\":\"resume rebuild failed\"}");
                return;
            }
        } else if (S.external_active && S.paused) {
            /* Legacy resume without a position: the writer restarts at an
             * offset only it knows; rebaseline the stream position at
             * first movement (byte-derived, client timeline since-build). */
            S.external_wait_first = 1;
            S.external_base_ms = 0;
        }
        if (S.paused && !S.external_active) {
            /* Clip mode: continue the clock from the frozen value. The
             * pipeline drains while paused, so re-anchoring from intake
             * would read the DRAINED position and collapse the clock to
             * (near) zero on every resume -- which scrambled the client's
             * word tick each time the sync flow auto-paused. */
            S.external_base_ms = S.external_frozen_ms;
            S.epoch_off_ms = 0;
            S.external_anchor_wall_ms = wall_now;
            S.external_wait_first = 0;
            S.anchor_wait = 0;
        } else if (S.paused) {
            S.anchor_wait = 1;
        }
        S.paused = 0;
        respond("{\"ok\":true,\"state\":\"%s\"}", state_str());
    } else if (!strcmp(cmd, "stop")) {
        drop_queue();
        respond("{\"ok\":true,\"state\":\"idle\"}");
    } else if (!strcmp(cmd, "flush")) {
        drop_queue();
        S.external_active = 0;
#ifdef AUDIOOUT_WITH_LIBAV
        if (S.ext_dec) { dec_close((DecState *)S.ext_dec); S.ext_dec = NULL; }
#endif
        S.epoch_off_ms = 0;
        S.external_total_ms = 0;
        S.external_done = 0;
        if (S.out_alsa && S.alsa_pcm) {
            A.snd_pcm_drop(S.alsa_pcm);
            A.snd_pcm_prepare(S.alsa_pcm);
            respond("{\"ok\":true,\"state\":\"idle\"}");
            return;
        }
        if (S.pipe) {
            pipeline_teardown();
            reset_stream();
            if (fifo_open() != 0) {
                respond("{\"ok\":false,\"error\":\"flush fifo failed\"}");
                return;
            }
            fifo_drain();
            if (pipeline_build(g_rate, g_channels) != 0) {
                respond("{\"ok\":false,\"error\":\"flush rebuild failed\"}");
                return;
            }
        }
        respond("{\"ok\":true,\"state\":\"idle\"}");
    } else if (!strcmp(cmd, "seek")) {
        if (!S.external_active) {
            respond("{\"ok\":false,\"error\":\"not in external mode\"}");
            return;
        }
        long long pos_ms = json_num(line, "pos_ms", 0);
        long long total_ms = json_num(line, "total_ms", S.external_total_ms);
#ifdef AUDIOOUT_WITH_LIBAV
        if (S.ext_dec && dec_seek((DecState *)S.ext_dec, pos_ms) != 0) {
            respond("{\"ok\":false,\"error\":\"seek failed\"}");
            return;
        }
#endif
        if (stream_epoch(pos_ms, total_ms) != 0) {
            respond("{\"ok\":false,\"error\":\"seek rebuild failed\"}");
            return;
        }
        log_line("seek: epoch at %lldms (total %lldms)", pos_ms, total_ms);
        respond("{\"ok\":true,\"state\":\"%s\",\"pos_ms\":%lld}",
                state_str(), pos_ms);
    } else if (!strcmp(cmd, "external")) {
        long long rate = json_num(line, "rate", g_rate);
        long long channels = json_num(line, "channels", g_channels);
        long long pos_ms = json_num(line, "pos_ms", 0);
        long long total_ms = json_num(line, "total_ms", 0);
        char alsa_dev[MAX_PATH] = "";
        char dec_path[MAX_PATH] = "";
        json_find(line, "alsa_device", alsa_dev, sizeof alsa_dev);
        json_find(line, "path", dec_path, sizeof dec_path);
        drop_queue();
        S.external_active = 0;
#ifdef AUDIOOUT_WITH_LIBAV
        S.ext_dec_eof = 0;
#endif
#ifdef AUDIOOUT_WITH_LIBAV
        if (S.ext_dec) { dec_close((DecState *)S.ext_dec); S.ext_dec = NULL; }
        if (dec_path[0]) {
            long long dur = 0;
            int drate = 0, dch = 0;
            DecState *d = NULL;
            if (dec_open(dec_path, &d, &dur, &drate, &dch) != 0) {
                respond("{\"ok\":false,\"error\":\"decode open failed\"}");
                return;
            }
            (void)dur;
            S.ext_dec = d;
        }
#endif
        if (S.out_alsa) {
            const char *dev = (alsa_dev[0] || S.alsa_device[0])
                ? (alsa_dev[0] ? alsa_dev : S.alsa_device) : "default";
            if (fifo_open() != 0 || alsa_open(dev, (int)rate, (int)channels) != 0) {
                respond("{\"ok\":false,\"error\":\"alsa open failed\"}");
                return;
            }
            g_rate = (int)rate;
            g_channels = (int)channels;
            /* New stream, new epoch: no byte of the previous track (fifo
             * backlog included) may leak into this one. */
            if (stream_epoch(pos_ms, total_ms) != 0) {
                respond("{\"ok\":false,\"error\":\"alsa re-epoch failed\"}");
                return;
            }
        } else {
            /* Always flush-class: a new stream must not inherit the old
             * pipeline's queued or fifo-buffered bytes. */
            g_rate = (int)rate;
            g_channels = (int)channels;
            if (stream_epoch(pos_ms, total_ms) != 0) {
                respond("{\"ok\":false,\"error\":\"pipeline build failed\"}");
                return;
            }
        }
        S.external_active = 1;
        S.paused = 0;
        log_line("external stream mode (%d x %d) at %lldms/%lldms",
                 g_rate, g_channels, pos_ms, total_ms);
        respond("{\"ok\":true,\"mode\":\"external\",\"fifo\":\"%s\"}",
                S.fifo_path);
    } else if (!strcmp(cmd, "release")) {
        drop_queue();
        S.external_active = 0;
#ifdef AUDIOOUT_WITH_LIBAV
        if (S.ext_dec) { dec_close((DecState *)S.ext_dec); S.ext_dec = NULL; }
#endif
        S.epoch_off_ms = 0;
        S.external_total_ms = 0;
        S.external_done = 0;
        if (S.out_alsa) {
            alsa_teardown();
            respond("{\"ok\":true,\"state\":\"released\"}");
            return;
        }
        if (S.pipe) {
            pipeline_teardown();
            reset_stream();
        }
        respond("{\"ok\":true,\"state\":\"released\"}");
    } else if (!strcmp(cmd, "status")) {
        /* Cap at the end of REAL audio: idle keepalive silence advances
         * the probe clock but is not part of any clip, and the client's
         * sync math must never see a position past the last word. In
         * external mode the cap is the stream length the client announced. */
        long long rend = rendered_ms();
        long long fed = (long long)((S.fifo_written * 1000ull) /
                                    (unsigned long long)(g_rate * g_channels * 2));
        if (!S.out_alsa) {
            /* The audible clock (see audible_ms), so the client's sync math
             * tracks what the listener hears instead of an intake clock the
             * firehose mtk sink sweeps ahead. */
            rend = audible_ms();
            if (rend < 0) rend = 0;
        }
        long long cap = S.external_active ? S.external_total_ms : S.fed_end_ms;
        if (cap > 0 && rend > cap) rend = cap;
        respond("{\"ok\":true,\"state\":\"%s\",\"pos_ms\":%lld,"
                "\"accepted_ms\":%lld,\"fed_ms\":%lld,\"fed_end_ms\":%lld,"
                "\"done_count\":%llu,\"queue\":%d,\"rate\":%d,\"channels\":%d,"
                "\"volume\":%.2f,\"unpaced\":%d,\"out\":\"%s\",\"uptime_ms\":%lld,"
                "\"external\":%d,\"external_done\":%d,\"decoder\":%d}",
                state_str(), rend, (long long)(acc_bytes / OUT_BYTES_PER_MS),
                fed, S.fed_end_ms, S.done_count, S.queue_len,
                S.pipe_rate, S.pipe_channels, S.volume,
                S.unpaced, S.out_alsa ? "alsa" : "mtk",
                mono_ms() - g_started_ms,
                S.external_active, S.external_done,
#ifdef AUDIOOUT_WITH_LIBAV
                1
#else
                0
#endif
                );
    } else if (!strcmp(cmd, "volume")) {
        long long v = json_num(line, "value_x1000", 1000);
        double vol = (double)v / 1000.0;
        if (vol < 0) vol = 0;
        if (vol > 4) vol = 4;
        S.volume = vol;
        if (S.out_alsa) {
            /* Applied in software to every byte written after this point;
             * only the fifo tail already handed to the driver is not
             * retroactive. */
            respond("{\"ok\":true,\"volume\":%.2f,\"live\":true}", vol);
            return;
        }
        if (G.g_object_set && S.pipe) {
            GstElement *el = G.gst_bin_get_by_name(GST_BIN(S.pipe), "vol");
            if (el) {
                G.g_object_set(el, "volume", vol, (char *)NULL);
                G.gst_object_unref(el);
                respond("{\"ok\":true,\"volume\":%.2f,\"live\":true}", vol);
                return;
            }
        }
        respond("{\"ok\":true,\"volume\":%.2f,\"live\":false}", vol);
    } else if (!strcmp(cmd, "shutdown")) {
        respond("{\"ok\":true,\"bye\":true}");
        usleep(50000);
        exit(0);
    } else {
        respond("{\"ok\":false,\"error\":\"unknown cmd\"}");
    }
}

/* ------------------------------------------------------------------ */
/* Per-tick bookkeeping                                                 */
/* ------------------------------------------------------------------ */

static void
tick_bookkeeping(void) {
    wall_now = mono_ms();
    refresh_clock();

    /* Acceptance pacing watchdog.  Sustained acceptance faster than real
     * time while a clip is up means the sink is swallowing (dead peer the
     * connection manager still lists).  One flag, read by the client; the
     * legacy path owns the retry UX for that case.  The first-buffer burst
     * (M0: ~1.5 s accepted in one tick) rides out on the reset below. */
    if (!S.paused && probe_seen && (S.queue_len > 0 || !S.all_fed)) {
        long long acc = (long long)(acc_bytes / OUT_BYTES_PER_MS);
        if (wall_now - S.pace_arm_ms < 3000) {
            /* Sink warm-up: the initial buffer burst plus the auto-pause
             * the sync flow issues right after play both look like
             * swallowing.  M0 measured the first accept at ~250 ms and
             * full init at ~1.4 s; 3 s covers both with margin. */
            S.pace_last_acc_ms = 0;
            S.pace_last_wall_ms = 0;
            S.pace_fast_ticks = 0;
        } else if (S.pace_last_wall_ms > 0) {
            long long dw = wall_now - S.pace_last_wall_ms;
            long long da = acc - S.pace_last_acc_ms;
            if (dw > 0 && da > dw * 2 + 250) {
                S.pace_fast_ticks++;
                if (S.pace_fast_ticks >= 25 && !S.unpaced) {
                    S.unpaced = 1;
                    log_line("UNPACED: sink accepting %lldms of audio in %lldms"
                             " of wall time; flagging for the client", da, dw);
                    respond("{\"event\":\"unpaced\"}");
                }
            } else {
                S.pace_fast_ticks = 0;
            }
        }
        S.pace_last_acc_ms = acc;
        S.pace_last_wall_ms = wall_now;
    } else {
        S.pace_last_acc_ms = 0;
        S.pace_last_wall_ms = 0;
        S.pace_fast_ticks = 0;
    }

    /* Clip completion: the rendered estimate crossed the clip's end.  In
     * external mode that estimate is the audible clock: the intake-based
     * rendered_ms() sweeps past every clip end at queue time on a sink
     * that accepts without pacing, completing clips that are still
     * playing (see dev/audioout/FINDING-2026-10-19-instant-completion.md). */
    long long rend = S.out_alsa ? alsa_pos_ms() : audible_ms();
    while (S.queue_len > 0 && rend >= S.queue[0].end_ms) {
        log_line("clip done: %s (end_ms=%lld)", S.queue[0].path,
                 S.queue[0].end_ms);
        if (S.queue[0].fd >= 0) {
            close(S.queue[0].fd);
            S.queue[0].fd = -1;
        }
        for (int i = 1; i < S.queue_len; i++) S.queue[i - 1] = S.queue[i];
        S.queue_len--;
        S.done_count++;
        if (S.feed_idx > 0) S.feed_idx--;
    }

    if (!S.announce_idle && S.queue_len == 0 && S.fed_end_ms > 0 &&
        rend >= S.fed_end_ms) {
        S.announce_idle = 1;
        log_line("queue drained; idle keepalive (pos=%lldms)", rend);
        respond("{\"event\":\"idle\",\"pos_ms\":%lld,\"done_count\":%llu}",
                rend, S.done_count);
    }

    /* External stream completion, on the client's timeline. Latched: the
     * push only reaches a client that happens to be connected, so status
     * carries external_done until the next external/seek/resume-with-pos
     * clears it. The 30 ms tolerance absorbs clock-vs-length rounding. */
    if (S.external_active && !S.paused && !S.external_done &&
        S.external_total_ms > 0 && rend >= S.external_total_ms - 30) {
        S.external_done = 1;
        log_line("external stream complete (pos=%lldms total=%lldms)",
                 rend, S.external_total_ms);
        respond("{\"event\":\"external_done\",\"pos_ms\":%lld}", rend);
    }

    /* Bus: errors only. Our O_RDWR fifo never produces a natural EOS. */
    if (S.bus) {
        GstMessage *msg = G.gst_bus_poll(S.bus, GST_MESSAGE_ERROR, 0);
        if (msg) {
            GError *e = NULL;
            gchar *dbg = NULL;
            G.gst_message_parse_error(msg, &e, &dbg);
            log_line("pipeline ERROR: %s (%s)",
                     e && e->message ? e->message : "?", dbg ? dbg : "-");
            respond("{\"event\":\"error\",\"message\":\"pipeline\"}");
            long long now = mono_ms();
            if (S.pipeline_retries < 3 &&
                (S.pipeline_last_fail_ms == 0 ||
                 now - S.pipeline_last_fail_ms > 30000)) {
                S.pipeline_retries++;
                S.pipeline_last_fail_ms = now;
                pipeline_teardown();
                reset_stream();
                if (fifo_open() == 0) pipeline_build(g_rate, g_channels);
            }
        }
    }
}

/* ------------------------------------------------------------------ */
/* Main                                                                 */
/* ------------------------------------------------------------------ */

static volatile sig_atomic_t g_quit;

static void
on_term(int sig) {
    (void)sig;
    g_quit = 1;
}

int
main(int argc, char **argv) {
    g_started_ms = mono_ms();

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--socket") && i + 1 < argc) g_socket_path = argv[++i];
        else if (!strcmp(argv[i], "--fifo") && i + 1 < argc)
            snprintf(S.fifo_path, sizeof S.fifo_path, "%s", argv[++i]);
        else if (!strcmp(argv[i], "--rate") && i + 1 < argc) g_rate = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--channels") && i + 1 < argc)
            g_channels = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--volume") && i + 1 < argc)
            S.volume = atof(argv[++i]);
        else if (!strcmp(argv[i], "--sink") && i + 1 < argc)
            g_sink_name = argv[++i];
        else if (!strcmp(argv[i], "--output") && i + 1 < argc)
            g_output = argv[++i];
        else if (!strcmp(argv[i], "--alsa-device") && i + 1 < argc)
            snprintf(S.alsa_device, sizeof S.alsa_device, "%s", argv[++i]);
        else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
            printf("usage: audioout [--socket PATH] [--fifo PATH]"
                   " [--rate HZ] [--channels N] [--volume 0-4]"
                   " [--sink ELEMENT] [--output auto|mtk|alsa]"
                   " [--alsa-device STR]\n");
            return 0;
        }
    }
    if (!S.fifo_path[0])
        snprintf(S.fifo_path, sizeof S.fifo_path, "%s", FIFO_PATH_DEFAULT);
    /* Static struct: fd sentinels must be -1, not 0 (fd 0 is stdin and
     * would make fifo_open think it is already open). */
    S.fifo_fd = -1;
    S.listen_fd = -1;
    S.client_fd = -1;
    if (S.volume <= 0) S.volume = 1.0;

    signal(SIGPIPE, SIG_IGN);
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_term;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);

    const char *names[] = {
        "libgstreamer-1.0.so.0", "/lib/libgstreamer-1.0.so.0", NULL,
    };
    for (int i = 0; names[i] && !G.gst; i++) {
        G.gst = dlopen(names[i], RTLD_NOW | RTLD_GLOBAL);
        if (G.gst) log_line("dlopened %s", names[i]);
    }
    if (!G.gst) {
        log_line("FATAL: no libgstreamer-1.0 (%s)", dlerror());
        return 2;
    }
    G.gobj = dlopen("libgobject-2.0.so.0", RTLD_NOW | RTLD_GLOBAL);

#define BIND(field, name)                                   \
    G.field = dlsym(G.gst, name);                           \
    if (!G.field) {                                         \
        log_line("FATAL: %s not exported", name);           \
        return 2;                                           \
    }
    BIND(gst_init, "gst_init");
    BIND(gst_parse_launch, "gst_parse_launch");
    BIND(gst_element_set_state, "gst_element_set_state");
    BIND(gst_element_get_bus, "gst_element_get_bus");
    BIND(gst_bus_poll, "gst_bus_poll");
    BIND(gst_message_parse_error, "gst_message_parse_error");
    BIND(gst_object_unref, "gst_object_unref");
    BIND(gst_bin_get_by_name, "gst_bin_get_by_name");
    BIND(gst_element_get_static_pad, "gst_element_get_static_pad");
    BIND(gst_pad_add_probe, "gst_pad_add_probe");
    BIND(gst_buffer_get_size, "gst_buffer_get_size");
#undef BIND
    G.gst_element_query_position = dlsym(G.gst, "gst_element_query_position");
    G.gst_element_get_state = dlsym(G.gst, "gst_element_get_state");
    G.gst_element_factory_find = dlsym(G.gst, "gst_element_factory_find");
    if (G.gobj)
        G.g_object_set = dlsym(G.gobj, "g_object_set");
    if (!G.gst_element_query_position)
        log_line("note: query_position unavailable; probe clock only");
    if (!G.g_object_set)
        log_line("note: g_object_set unavailable; volume applies on rebuild");

    G.gst_init(NULL, NULL);

    /* Output selection.  auto: the MTK vendor sink when present, else the
     * bluealsa ALSA PCM. */
    if (!strcmp(g_output, "alsa")) S.out_alsa = 1;
    else if (!strcmp(g_output, "auto")) {
        S.out_alsa = !(G.gst_element_factory_find
                       && G.gst_element_factory_find("mtkbtmwrpcaudiosink"));
    }
    if (S.out_alsa) {
        /* The bluealsa PCM type is defined by an ALSA plugin .so.  The
         * firmware ships one in /lib/alsa-lib on the generations that run
         * bluealsa natively; otherwise the bundled bluealsa dir has one
         * built for the device glibc.  ALSA_PLUGIN_DIR must be set before
         * the first snd_pcm_open resolves the PCM type. */
        if (access("/lib/alsa-lib/libasound_module_pcm_bluealsa.so", F_OK) != 0) {
            char exe[MAX_PATH], dir[MAX_PATH], plugdir[MAX_PATH];
            ssize_t n = readlink("/proc/self/exe", exe, sizeof exe - 1);
            if (n > 0) {
                exe[n] = 0;
                snprintf(dir, sizeof dir, "%s", exe);
                char *slash = strrchr(dir, '/');
                if (slash) *slash = 0;          /* .../audioout */
                slash = strrchr(dir, '/');
                if (slash) *slash = 0;          /* plugin dir root */
                snprintf(plugdir, sizeof plugdir,
                         "%s/bluealsa/lib/alsa-lib", dir);
                if (access(plugdir, F_OK) == 0)
                    setenv("ALSA_PLUGIN_DIR", plugdir, 1);
            }
        }
        log_line("output: alsa (device %s)",
                 S.alsa_device[0] ? S.alsa_device : "(set per play)");
    } else {
        log_line("output: mtk (%s)", g_sink_name);
    }

    unlink(g_socket_path);
    S.listen_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (S.listen_fd < 0) {
        log_line("FATAL: socket: %s", strerror(errno));
        return 2;
    }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof addr.sun_path, "%s", g_socket_path);
    if (bind(S.listen_fd, (struct sockaddr *)&addr, sizeof addr) < 0 ||
        listen(S.listen_fd, 2) < 0) {
        log_line("FATAL: bind/listen: %s", strerror(errno));
        return 2;
    }
    fcntl(S.listen_fd, F_SETFL, O_NONBLOCK);
    log_line("listening on %s (fifo %s, %d Hz x %d ch)", g_socket_path,
             S.fifo_path, g_rate, g_channels);

    if (!S.out_alsa) claim_exclusive_socket();
    /* The pipeline builds lazily on the first play command: the vendor
     * sink's init can block for many seconds with no A2DP peer. */
    log_line("ready (pipeline builds on first play)");

    S.client_fd = -1;
    S.feed_idx = -1;
    S.all_fed = 1;

    char rbuf[LINE_MAX_LEN];
    size_t rlen = 0;

    while (!g_quit) {
        struct pollfd fds[2];
        int nfds = 0;
        fds[nfds].fd = S.listen_fd;
        fds[nfds].events = POLLIN;
        nfds++;
        int cli = S.client_fd;
        if (cli >= 0) {
            fds[nfds].fd = cli;
            fds[nfds].events = POLLIN;
            nfds++;
        }
        int rc = poll(fds, nfds, 10);
        if (rc < 0 && errno != EINTR) break;

        int c = accept(S.listen_fd, NULL, NULL);
        if (c >= 0) {
            if (S.client_fd >= 0) {
                log_line("replacing client connection");
                close(S.client_fd);
            }
            S.client_fd = c;
            fcntl(c, F_SETFL, O_NONBLOCK);
            rlen = 0;
            log_line("client connected");
        }

        if (S.client_fd >= 0) {
            for (;;) {
                ssize_t n = recv(S.client_fd, rbuf + rlen,
                                 sizeof rbuf - rlen - 1, MSG_DONTWAIT);
                if (n > 0) {
                    rlen += (size_t)n;
                    rbuf[rlen] = 0;
                    char *nl;
                    while ((nl = memchr(rbuf, '\n', rlen)) != NULL) {
                        *nl = 0;
                        if (nl > rbuf) handle_command(rbuf);
                        size_t consumed = (size_t)(nl - rbuf) + 1;
                        memmove(rbuf, nl + 1, rlen - consumed);
                        rlen -= consumed;
                        rbuf[rlen] = 0;
                    }
                    if (rlen >= sizeof rbuf - 1) rlen = 0;
                    continue;
                }
                if (n == 0 ||
                    (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK)) {
                    log_line("client gone");
                    close(S.client_fd);
                    S.client_fd = -1;
                }
                break;
            }
        }

        feed_tick();
        tick_bookkeeping();
    }

    log_line("shutting down");
    pipeline_teardown();
    if (S.client_fd >= 0) close(S.client_fd);
    close(S.listen_fd);
    unlink(g_socket_path);
    return 0;
}
