# sanoTTS engine (int8 neural TTS, low-resource tier)

A tiny neural TTS engine that slots between Piper (quality tier) and
espeak-ng (fallback) in the backend list. Runs real-time on a Kobo Clara
(measured RTF 0.15 on a dual-core Libra Color; 0.33-class on single-core)
with a 0.7-1.5 MB voice and ~5 MB RAM, where Piper needs a ~60 MB voice and
~100 MB RAM.

## Layout

- `snt_server.c` — engine server. Reads Piper-style JSON lines
  (`{"text": "...", "output_file": "..."}`) on stdin, synthesizes, and
  prints the WAV path per line (the same protocol the piper queue expects).
  One binary serves three engines, selected with `--engine`:
  - `int8` (default): the R7 "kristin" voice, 22050 Hz, via `snt_tts.c`.
  - `pq8`: the fully-int8 piperlite stack (`snt_front_q8.c` +
    `snt_piperlite_q8.c`), 22050 Hz. Every dimension comes out of the
    blobs, so any exported piperlite int8 voice runs without a rebuild.
  - `nano`: the heart-nano voice, 24000 Hz, via `snt_nano.c`, phonemized
    by the espeak-free lexicon G2P (`nano_lex_g2p.c`, misaki dictionary
    data, Apache-2.0; ~3 MB of const tables in .rodata).
- `phoneme_id_map.h`: generated Piper phoneme-id map (en_US, espeak en-us),
  used by the int8 and pq8 engines.
- `voice/front_q8.bin`, `voice/model_q8.bin`: the kristin voice (R7 int8,
  680 KB total, 22050 Hz mono output).
- `voice-amy/front_meta_q8.bin`, `front_weights_q8.bin`, `meta_q8.bin`,
  `weights_q8.bin`: the amy voice (en_US-amy-medium distilled, fully int8,
  1.48 MB total, 22050 Hz mono output), exported with upstream's
  `tools/export_piperlite_q8.py` / `export_front_q8.py`.
- `voice-nano/`: heart-nano blobs staged for the nano engine (front_q8.bin,
  model_q8.bin, its `nano_q8_meta.h` offsets header); not yet wired into the
  Lua voice menu.
- `nano_lex_g2p.c`, `nano_lex_g2p.h`, `nano_lex_tables.c`,
  `nano_lex_tables.h`: the espeak-free English G2P for the nano engine,
  ported from upstream `esphome/components/sanotts/`.
- `snt_server` — prebuilt static armv7hf binary (see out/ after builds).

## Provenance and licensing

The inference runtimes (`snt_tts.c`, `snt_nano.c`, `snt_front_q8.c`,
`snt_piperlite_q8.c`, kernels, headers) and the int8 voice blobs come from
the sanoTTS project (https://github.com/ampixa/sanoTTS) and are
MIT-licensed. The phoneme-id map is generated from the same project's
piper-phoneme-config.json (Piper/eSpeak conventions); the nano G2P's
pronunciation data is misaki's us_gold/us_silver tables (Apache-2.0). The
driver (`snt_server.c`) is written for this plugin. Phonemization at runtime
uses the bundled espeak-ng binary already shipped for the espeak-ng backend
(int8 and pq8 engines), so no additional espeak data is bundled here.

## Rebuilding the server

```bash
cd sanotts
nix shell nixpkgs#pkgsCross.armv7l-hf-multiplatform.pkgsStatic.stdenv \
  -c bash -c 'export NIX_CFLAGS_COMPILE="$NIX_CFLAGS_COMPILE -O2 -std=c99 -I$PWD/mcu/include -I$PWD/mcu/src -I$PWD/voice-nano -DFSD_FAST_MATH";
  $CC -static -o snt_server snt_server.c mcu/src/snt_tts.c mcu/src/snt_kernels_ref.c mcu/src/snt_nano.c mcu/src/snt_front_q8.c mcu/src/snt_piperlite_q8.c mcu/ports/host/snt_port_host.c nano_lex_g2p.c nano_lex_tables.c -lm'
```

(with the sanoTTS checkout in `mcu/`; `package-for-kobo.sh` does this
automatically against the pinned upstream snapshot through
`cross-build-snt-server.nix`.)

## Punctuation handling

espeak's IPA output drops punctuation entirely, so the server carries it in
two layers (both on by default for int8/pq8):

1. The text is split at `. , ? ! : ;` and each clause is synthesized
   separately with a silence gap after it, sized by the punctuation
   (`--comma-ms` 150, `--period-ms` 350, colon 220, semicolon 250).
2. The punctuation mark's own phoneme id is appended to the clause's token
   stream before EOS, so the model renders its native terminal contour
   (rising for `?`, falling for `.`). This mirrors what piper's own
   phonemizer does; without it the punctuation would vanish.

`--native-punct` replaces both with piper's exact behavior: the whole line
is one synthesis and the punctuation ids carry all pauses themselves. On
these students the native pauses are subtle (~120 ms), which is why the
layered default exists.

## Runtime tuning

- `--engine int8|pq8|nano` selects the runtime (see Layout).
- `--pause-scale F` (pq8) stretches only the punctuation tokens' frame
  counts; phones keep their native durations, so pacing deepens without
  feeding the decoder stretched phones (which reads as phasing). The plugin
  ships 2.5.
- `--length-scale F` (pq8) warps every duration; useful as a speed control
  but audible as phasing at larger values on these students.
- `--comma-ms N`, `--period-ms N` size the silence inserted after clauses
  ending in `,` and in `. ? !` (colon 220 ms, semicolon 250 ms).
- `--voice en-us`, `--rate 22050|24000` choose the espeak-ng voice for
  phonemization and the output sample rate (nano defaults to 24000).
- `--seed N` (nano) forces one decoder noise seed; default seeds from the
  clause text, so a sentence always sounds the same.
- `--loader <ld-linux>`, `--loader-libdir <dir>` exec the bundled armhf
  espeak-ng through the bundled glibc loader on stock Kobo rootfs (set
  automatically by piperqueue).

## Phoneme ids above the voice's vocabulary

The phoneme maps are wider than the pq8 and f32 voices. Both the English and
the French map carry 154 entries reaching id 153, while the duration embedding
was trained on fewer rows: the amy voice has `d_vocab` 129. An id at or above
`d_vocab` is rejected by the runtime, which in `snt_server.c`'s terms means the
clause fails with `pq8 durations rc -3` and the request comes back with
header-only audio or a sentence truncated at that clause.

The frequent trigger is espeak's syllabic-consonant mark, id 144, which it
emits for ordinary words: "little", "button", "certain", "garden", "simple".
`drop_oov_ids()` in `snt_server.c` removes such tokens and their trailing pad
before synthesis, so the sentence is spoken instead of dropped. The affected
phones are those the model never saw, so the result is closer to the training
distribution than the failure was. `dev/test_snt_server_oov.sh` covers it.

The int8 and nano engines are unaffected: their runtimes either expose no
vocabulary to check against or already handle these ids.

## Word timing sidecar

On the pq8 and f32 engines the server writes `<wav>.timing` beside every WAV
it produces, and the plugin uses it to place the read-aloud highlight on the
right word instead of estimating from character counts. The values are the
duration student's own per-phoneme frame counts, computed during synthesis and
previously discarded; reading them back changes no audio, and the WAV is
bit-identical with or without the file. The int8 engine publishes the same
sidecar (local patch 0002 reads its duration student's output); the nano
engine has no duration read-out and writes nothing, which is how the plugin
tells the cases apart.

```
sntt 1 <rate> <hop> <total_samples> <n_clauses> <n_words>
c <j> <char_start> <char_end> <punct> <sample_start> <sample_end> <word0> <nwords>
w <i> <start_sample> <end_sample>
```

Word boundaries are the phoneme id that `" "` maps to, which is 3 in every
piper map and is the only symbol that maps there. Framing is found by
position, not by id value, because both maps alias `^` and `$` to BOS and EOS
and a live IPA stream may carry either. Each `c` record gives a clause's
absolute sample span in the WAV (trailing silence included) and its character
territory in the request string; the `w` records are that clause's word spans,
in stream order. The territories refer to the text after the caller's own
cleaning, not the raw input, so a reader must clean its input the same way
before matching them.

The `w` records are really **phoneme groups**, which coincide with words only
when espeak keeps them apart. It often does not: unstressed function words are
joined to their neighbour, so `in the` and `from the` each come back as one
group. A reader that maps words to groups one-for-one must therefore check the
counts and fall back when they disagree, rather than assume. On the benchmark
prose in `dev/benchmark/`, about a quarter of sentences disagree this way, and
a smaller number disagree because espeak spells numbers out (`1984` becomes
three groups). Per-word phonemization does not recover the missing boundaries:
espeak de-stresses and reduces those words in context, so phonemizing a word
alone yields a different phone sequence than the one it contributes to the
clause. Exact word boundaries are only available from a phonemizer that
preserves them, which would mean a different phone sequence and therefore
different audio.

## ARM NEON kernels + dual-core (patches 0003/0004)

The Kobo build compiles the port TU `mcu/ports/arm-neon/snt_port_arm.c`
(NEON int kernels + a condvar-blocked pthread `snt_par_run`, scalar
fallbacks everywhere) and vectorizes the integer conv kernels in the pq8 and
front engines. Byte-identity discipline:

- The vector axis is always the disjoint t/lane axis, so no integer addition
  is ever reordered; `lrintf` requant epilogues, fp32 mixing and `tanhf`
  stay scalar. Gates: 400-case kernel byte test, R7/nano goldens, and
  server-level ids A/B (`dev/snt-ab.sh --ids --cross`) byte-comparing
  pristine-scalar vs NEON for int8, pq8 and nano, plus f32 by correlation.
- The f32 (fr) engine's fp32 kernels are byte-identical on the same
  architecture (ARMv7 VMLA is non-fused) but carry only a correlation gate
  across architectures; fr output bytes are not stable across toolchains.
- The pq8 decoder splits by output channel (patch 0004) with per-core
  `rowbuf` scratch; the fp32 branch-sum, stage taps and mix quant run after
  the last barrier on the main thread, so audio and the `.timing` sidecar
  are bit-identical under the 2-thread split.

`SNT_THREADS` selects threading at runtime: unset or `1` is fully serial
(the worker is never created), `2` runs one worker pinned to the second
core. The plugin sets `SNT_THREADS=2` on multi-core devices and launches a
single server; older server binaries ignore the variable.

Compiler hazard worth knowing: GCC 15.2 armv7 -O2 miscompiles chained
`vpadalq_s16` accumulate forms for some `-frandom-seed` values (silent wrong
results that come and go with codegen). The kernels use explicit
`vaddq_s32(acc, vpaddlq_s16(vmull_s8(...)))` instead; the gate ladder shakes
three seeds. Build flags: `-mfpu=neon`, not `neon-vfpv4` (Cortex-A8/A9 have
no scalar VFPv4 FMA and would trap on `vfma`).
