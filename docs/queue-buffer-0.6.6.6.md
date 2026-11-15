# Android queue buffer · 0.6.6.6

Automatic page turns preserve queued utterances by their exact document range. Already started
page tails are not sent again; identical sentences at different positions remain distinct.
An utterance crossing a view stays bound to its original ID, including its highlight/resume item.

The rolling XPointer window covers up to six views (4000 words maximum). Queue refill estimates
60 seconds of speech from word count, rate and observed start/done durations, bounded by 64
requests and 12000 UTF-8 bytes. Six sentences remain the minimum target when available.
MyTTS's own byte/time PCM budgets still apply. This is a target, not a guarantee that 60 seconds
are always ready: available document text and synthesis speed also limit the buffer.

Punctuation-only tails need no completion event. Future synthesis errors mark their own items
terminal but cannot move the page before earlier speech finishes. Stale callbacks cannot reset
the watchdog; old terminal IDs/texts are pruned. Auto-advance OFF does not enqueue the next view.

Before the first queued speak, the plugin primes MyTTS's paragraph preparation without waiting
for the cloud. In MyTTS beta359+, paragraph and queued preparation share that result. Older
engines keep working; their pre-synthesis is unchanged.

Validation: `luajit dev/test_engine_queue.lua` (915 assertions), wrap-carry (31 checks), semantic
module check. Queue tests use the real controller/parser/XPointer code with a mock document;
they cover many turns, turns within speech, genuine repeated sentences, errors, stale events
and bounded metadata. On-device listening remains a separate check.
