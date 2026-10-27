# FINDING 2026-10-19: external-stream completions fire instantly on MTK when the sink swallows

Seen on the single-core MTK test Kobo (MT8110), plugin 0.3.1 lua + audioout
daemon of Oct 18, kristin/NEON synthesis (unrelated to synthesis; the synthesis,
queue and timing sidecar all behaved). Symptom: highlight and sentence advance
raced through the chapter while the voice played on continuously.

## Evidence (device crash.log + /tmp/audiobook_audioout.log)

    TTSEngine: play() via audioout, dur= 27880 ms, start_ms= 41314 fed_end_ms= 69194
    TTSEngine: audioout clip rendered (pos= 23246 ms, fed_end= 69194 ms)   <- 1s later
    SyncController: Completion callback, concat ending at sentence 9

pos_ms (23246) is the acc_bytes intake clock and is BELOW the clip's own start
(41314), yet the pump loop popped the clip: the pump's completion test uses
`rendered_ms()` (the wall-clock extrapolation between acceptance boundaries),
which is a DIFFERENT clock from the status pos (acc_bytes - external_base).
When the mtk sink accepts buffers without pacing, acceptance bursts sweep the
extrapolation across every queued clip end within a second, all clips pop,
done_count jumps past the client's baseline, and the client declares the clip
rendered while the sink is still audibly rendering its internal buffer.

The UNPACED detector (25 fast acceptance ticks) did not fire for this shape:
the sink appears to alternate absorption and stall, so dw/da ratios stay under
the 2x threshold often enough to reset the counter.

## Suggested directions (yours to pick, your workstream)

1. Completion in external mode should use the same clock status reports
   (acc_bytes - external_base), not rendered_ms(), so at least the two clocks
   cannot disagree.  With this sink that alone may not be enough: acc_bytes
   itself swept to 69 s within ~1 s, so intake is not pacing either.
2. The mtk sink gives no render position and swallows without backpressure,
   so no intake-side clock can represent audibility here.  A wall-clock
   duration timer per clip (the legacy path's approach, including its
   premature-exit detection) may be the only honest completion signal on MTK.
3. The UNPACED threshold missed this case; consider counting intake-vs-fed
   divergence (acc_bytes crawling while fed_end jumps) as a second signal.

## Interim user mitigation

The TTS settings toggle "Use audio output daemon (experimental)" OFF returns
playback to the legacy gst-bt path (whose _gstVolumeFragment/_isAudioProcessRunning
definitions an earlier unterminated comment had swallowed; restored in 65f9853),
whose duration-based completion paces the highlight correctly on MTK.

## Resolved (same day, commit after this note)

Root cause was twofold, both in the daemon:

1. The completion and status clocks were acceptance-intake based.  The mtk
   sink's firehose intake swept them across every queued clip end at queue
   time.  Fix: an anchor-based audible clock (`audible_ms()`) - anchored once
   when the stream's first buffer reaches the sink, advancing at audio rate,
   clamped to the intake position on underrun, frozen while paused, re-armed
   on resume/rebuild/flush.  It now drives clip completion AND the status
   pos_ms (which the client's highlight sync consumes directly) in every mtk
   mode; alsa keeps its hardware delay clock.
2. The FIFO feed was unbounded, so the pipeline ingested 123 s of stream in
   19 s of wall time on the test device (the gst ring + firmware absorbed it,
   causing downstream drops/delays - the audible skips).  Fix: feed pacing -
   the daemon holds the FIFO at most FEED_LEAD_MS (3 s) ahead of the audible
   position, for clips, inter-clip gaps and idle keepalive alike.

Verified on the single-core MTK test Kobo with BT audio: a 32.0 s clip
completed 34.1 s after queue (pipeline + sink startup included), a 27.2 s
clip 28.0 s after queue, spans chaining continuously, no UNPACED events, no
pipeline errors, and the read-along highlight tracking the voice.
dev/audioout/clock_test.lua automates the on-device check.
