# sanoTTS kernel benchmarks (Tier 3)

Before/after record for the NEON + dual-core snt_server work. All numbers from
`dev/snt-bench.sh` (device) and `dev/snt-ab.sh` (host A/B byte gates) unless
noted. RTF includes one model load per pass (per-call methodology, matching the
spike anchor in `~/projects/sanotts-spike/BENCHMARKS.md`).

## Harnesses

- `dev/snt-ab.sh`: host differential gate. Builds the scalar-reference server
  and a candidate (alternative port TU), runs a fixed corpus, compares WAV
  bytes + `.timing` sidecars (`--corr` mode for fr). Sanity mode (no
  `--with-tu`) PASSed 2026-10-18: int8, 10 utterances byte-identical.
- `dev/snt-bench.sh`: device/host bench driving the real server over its stdin
  protocol. Fixed 12-sentence corpus, `--seed 1234`. Determinism verified on
  host for all four engines (pass1 == pass3 hashes).

## In-tree gates (host, 2026-10-18, scalar reference)

- `make test` (R7): corr 0.989179, rms_ratio 0.935116 (bound 0.80-1.25), PASS.
- `make test-nano`: 8 rows, min corr 0.984251, PASS. Host scalar nano:
  5.76 ms per second of audio.

## Host scalar baseline (gary x86, 2026-10-18, threads=default)

12-text corpus, 3 passes each:

| engine | voice | RTF min | RTF med | RTF max |
|---|---|---|---|---|
| int8 | kristin | 0.0140 | 0.0141 | 0.0141 |
| pq8 | amy | 0.2824 | 0.3200 | 0.3206 |
| f32 | fr-siwis | 0.4392 | 0.4927 | 0.4997 |
| nano | heart-nano | 0.0072 | 0.0081 | 0.0090 |

Observation: pq8 is ~23x heavier than int8 on host. If the int8 host-to-Libra
ratio (~11x from this 0.014 to the spike's 0.153) transferred to pq8, amy
would be ~3x realtime per core on the Libra, which would make amy effectively
unusable single-threaded. The device matrix below is the decider.

## M1 gate results (2026-10-18, qemu + host)

- Kernel-level byte test (test_neon_kernels.c): 400 cases ALL PASS on
  cortex-a7 and cortex-a9, x3 -frandom-seed values (18 runs).
- R7 golden through the NEON TU: corr/rms print identical to the host scalar
  run (corr 0.989179, rms_ratio 0.935116, 34304 samples) = byte-equivalent.
- int8 server-level ids A/B (dev/snt-ab.sh --ids --cross, pristine scalar vs
  NEON TU under qemu): 15/15 utterances byte-identical; 1 corpus file over
  the int8 token cap refused identically on both sides.
- nano: ARM-scalar vs ARM-NEON PCM FNV hashes IDENTICAL (8 fixture rows).
  Note: x86 host and ARM differ in nano's fp32 paths even with reference
  kernels (fp32 contraction), so the nano byte gate is ARM-vs-ARM by design.
- pq8 server-level ids A/B: **16/16 utterances byte-identical** (pristine
  scalar vs NEON TU, qemu, including the 2.1 MB "long" corpus file).
- Production build (cross-build-snt-server.nix with the NEON TU + -mfpu=neon):
  builds clean, NEON instructions verified present in the binary.

## M2 + M4 results (2026-10-19)

- M2 (f32/fr NEON): ARM-scalar vs ARM-NEON correlation **1.000000** on the
  ids corpus under qemu - the fp32 kernels are byte-identical on the same
  architecture (ARMv7 VMLA is architecturally non-fused), well above the
  0.99 corr gate.  The corr gate stays in place for real hardware.
- M4 (patch 0004, pq8 dual-core split): serial-vs-pristine byte-identical
  (the par rewrite is invisible single-threaded) AND SNT_THREADS=2 vs 1
  byte-identical through all four par site types (pre/upsample/bank t1/t2),
  on four corpus files plus the 2.1 MB "long" file.
- Deviation from the plan: patch 0004 covers pq8 only.  The f32 engine and
  the front stage (2% of cycles) keep serial loops; same pattern applies
  later if device numbers justify it.
- M5 plugin change: piperqueue launches the sanoTTS backend as ONE server
  with SNT_THREADS=2 on multi-core devices (backend-scoped pool, legacy
  2-server pool untouched for piper); single-core devices unchanged.
  synccontroller's RTF degrade ladder has no SERVER_COUNT assumptions
  (verified: it reads only rolling RTF samples).

## Compiler hazard found: vpadalq_s16 miscompile

GCC 15.2 (armv7 -O2, -mfpu=neon) silently miscompiles chained
`vpadalq_s16` accumulate forms for certain `-frandom-seed` values: the
4-row matvec block produced wrong results for one specific codegen while
passing the 400-case unit test at other codegens.  The fix (in the port TU)
uses explicit `vaddq_s32(acc, vpaddlq_s16(vmull_s8(...)))` - same math, one
extra instruction, robust under every codegen tested.  The gate ladder now
shakes codegen with three -frandom-seed values.  Worth an upstream GCC bug
report.

## Device results (2026-10-19, .142 single-core MTK MT8110, Cortex-A9)

Real-hardware gates: kernel byte test 400 cases ALL PASS; pq8 driver A/B
byte-identical; the int8 determinism hash is IDENTICAL across the scalar and
NEON server builds (13c5f527e6a21e00) - byte-identical audio on hardware.

12-text corpus, 3 passes, includes one model load per pass:

| engine | binary | RTF min | RTF med | RTF max |
|---|---|---|---|---|
| int8 | scalar (deployed 0.2.x) | 0.1708 | 0.1708 | 0.1708 |
| int8 | NEON | 0.0793 | 0.0793 | 0.0797 |
| pq8 | scalar (deployed 0.2.x) | 5.8183 | 5.8183 | 5.8308 |
| pq8 | NEON | 3.4907 | 3.4907 | 3.5175 |

Speedups on hardware: int8 **2.15x**, pq8 **1.67x** (pq8 is partly
memory-bound at the 16-bit planes, hence less than int8's ratio). The
determinism hash per corpus is IDENTICAL between the scalar and NEON builds
for both engines: byte-identical audio on real hardware, not just under
qemu. SNT_THREADS=2 on this single-core device: int8 RTF 0.0795 vs 0.0793
serial, no regression (worker never wins the one core).

## Strategic finding: amy (pq8) is not real-time on ARMv7 Kobos

Scalar pq8 is RTF 5.82 on a single-core A9 and 3.49 with NEON. Even at a
perfect 2x parallel split on dual-core devices, amy stays around RTF 1.7 -
slower than real time everywhere in the Kobo fleet. The kernel work makes
amy ~40% less bad and keeps audio byte-identical, but no amount of this
optimization makes amy real-time on these SoCs. kristin (int8) at RTF 0.079
NEON single-core is 44x faster than amy NEON. The realistic product paths
are (a) flip the default voice to kristin, (b) ship a lighter pq8 export
(smaller width) for ARMv7, or (c) accept amy only on much faster hardware.
This is a product decision, not a kernel one.

## Device identity and the 2026-10-22 fill (Libra Colour, single device)

Device identity settled 2026-10-22: the test device at 192.168.1.142 IS the
Kobo Libra Colour (FBInk: "Kobo Libra Colour (390 => Monza @ Mark 13)").
"Monza" is that model's codename, so the matrix below had split ONE device
into two rows. It is also single-core (1 processor in /proc/cpuinfo), which
closes the "after M3/M4 dual-core" premise: there is no second core for the
worker to win, and the measured 2-thread rows confirm it.

Fresh numbers (2026-10-22, deployed NEON binary, 5 passes per leg, pass1 ==
pass5 determinism on every leg). Measurement caveat: the stock MTK
`btservice` daemon spins ~90% of the core once Bluetooth has been used and
poisons the run (int8 measured 0.157 under it vs 0.077 after SIGSTOPping it
for the bench; resumed afterwards). Bench any MTK Kobo with it paused.

| device | engine | threads | RTF med | notes |
|---|---|---|---|---|
| Libra Colour (Monza) | int8 | 1 | **0.0774** (2026-10-22) | reproduces 0.0793 within 2.5%; spike anchor 0.153 was scalar pre-NEON |
| Libra Colour (Monza) | pq8 | 1 | **3.3133** (2026-10-22) | reproduces 3.4907 within 5% |
| Libra Colour (Monza) | int8 | 2 | 0.0774 (2026-10-22) | no gain, single core |
| Libra Colour (Monza) | pq8 | 2 | 3.2310 (2026-10-22) | noise-level, single core |
| Libra Colour (Monza) | f32 | 1 | pending | voice-fr is the only f32 model; the English bench corpus through the French phonemizer is not comparable, needs a real f32 corpus leg |
| .142 (MTK) = Libra Colour | int8 | 1 | 0.0793 (NEON; scalar 0.1708) | 2026-10-19 table above |
| .142 (MTK) = Libra Colour | pq8 | 1 | 3.4907 (NEON; scalar 5.8183) | 2026-10-19 table above |

## pq8 profile ranking (host, callgrind, 2 sentences, -O2)

| function | instruction share |
|---|---|
| `q16_conv1d_row` (decoder residual-bank conv rows) | **62.5%** |
| `snt_piperlite_q8_synthesize` body (inlined convtr rows, requant epilogues, tanhf, mix) | 33.6% |
| `fq_conv_row` (front stage conv rows) | 2.0% |

A finer pass with `-fno-inline` splits the buckets (-O2 shares, same corpus):

| function | share | rounding-sensitive |
|---|---|---|
| `q16_conv1d_row` | **61.3%** | no (integer MACs) |
| `q16_convtr1d_row` | **26.3%** | no (integer MACs) |
| `sat12` (requant epilogue) | 3.8% | yes (lrintf) |
| `q_leaky_requant` | 2.6% | yes (lrintf) |
| `fq_conv_row` | 1.9% | no (integer MACs) |

The two integer conv kernels cover ~88% of instructions; the rounding-sensitive
requant family (~6.4%) stays scalar. tanhf is below the top five.
