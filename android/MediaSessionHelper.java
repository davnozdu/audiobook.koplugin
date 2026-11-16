package org.koreader.plugin.audiobook;

import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.media.AudioFormat;
import android.media.AudioTrack;
import android.media.MediaMetadata;
import android.media.session.MediaSession;
import android.media.session.PlaybackState;
import android.os.Build;
import android.os.Handler;
import android.os.HandlerThread;

/**
 * Active MediaSession so Bluetooth headsets (AirPods stem, AVRCP) deliver
 * play/pause/next/prev to KOReader on Android.  Lua polls getPendingCommand()
 * — no JNI callbacks required.
 */
public class MediaSessionHelper {
    public static final int CMD_NONE = 0;
    public static final int CMD_PLAY_PAUSE = 1;
    public static final int CMD_PLAY = 2;
    public static final int CMD_PAUSE = 3;
    public static final int CMD_STOP = 4;
    public static final int CMD_NEXT = 5;
    public static final int CMD_PREV = 6;
    /** Interruption (phone call, other app took audio focus): pause. */
    public static final int CMD_INTERRUPT_PAUSE = 7;
    /** Interruption is over and we paused for it: resume. */
    public static final int CMD_INTERRUPT_RESUME = 8;
    /** Headphones unplugged / Bluetooth gone (ACTION_AUDIO_BECOMING_NOISY): pause, never go on through the speaker. */
    public static final int CMD_NOISY = 9;

    // How often to poll AudioManager.getMode() as a fallback call detector
    // (some VoIP / OEM dialers do not take audio focus).
    private static final long MODE_POLL_MS = 1000;

    private final Context context;
    private final HandlerThread workerThread;
    private final Handler worker;
    private final Object lock = new Object();

    private MediaSession session;
    private AudioManager audioManager;
    private Object audioFocusRequest; // AudioFocusRequest on API 26+
    private volatile int pendingCommand = CMD_NONE;
    // Interruption commands bypass the button debounce: a short focus loss
    // followed by a quick regain must deliver both pause and resume.
    private volatile int pendingInterrupt = CMD_NONE;
    // True while we are paused because of a call / focus loss and should
    // resume automatically once it ends.
    private volatile boolean pausedByInterrupt;
    private volatile boolean focusLost;
    private volatile boolean inCall;
    private AudioManager.OnAudioFocusChangeListener focusListener;
    private volatile boolean active;
    private volatile boolean hasAudioFocus;
    private volatile long suppressCommandUntilMs;
    private volatile int playbackState = PlaybackState.STATE_NONE;
    private volatile long positionMs;
    private volatile String title = "Audiobook";
    private volatile String artist = "";

    // Wake channel: one byte into the plugin's pipe on every queued command, so KOReader's main loop wakes up at
    // once instead of polling getPendingCommand() every second (battery, screen off).
    private volatile java.io.FileOutputStream wakeOut;
    private volatile android.os.ParcelFileDescriptor wakeFd;
    private android.content.BroadcastReceiver noisyReceiver;
    private Object modeListener; // AudioManager.OnModeChangedListener on API 31+

    /** [fd]: the write end of the plugin's pipe (duplicated here; the plugin keeps its own). -1 turns it off. */
    public void setWakeFd(int fd) {
        try { if (wakeFd != null) wakeFd.close(); } catch (Exception ignored) {}
        wakeOut = null; wakeFd = null;
        if (fd < 0) return;
        try {
            android.os.ParcelFileDescriptor p = android.os.ParcelFileDescriptor.fromFd(fd);
            wakeFd = p;
            wakeOut = new java.io.FileOutputStream(p.getFileDescriptor());
        } catch (Exception e) { wakeOut = null; wakeFd = null; }
    }

    private void wake() {
        java.io.FileOutputStream o = wakeOut;
        if (o != null) try { o.write(1); } catch (Exception ignored) {}
    }

    public MediaSessionHelper(Context context) {
        this.context = context.getApplicationContext();
        workerThread = new HandlerThread("abk-mediasession");
        workerThread.start();
        worker = new Handler(workerThread.getLooper());
        audioManager = (AudioManager) this.context.getSystemService(Context.AUDIO_SERVICE);
    }

    /** Activate the session (call when overlay/audiobook playback starts). */
    public void start(final String trackTitle, final String trackArtist) {
        if (trackTitle != null && trackTitle.length() > 0) title = trackTitle;
        if (trackArtist != null) artist = trackArtist;
        worker.post(new Runnable() {
            @Override
            public void run() {
                ensureSessionLocked();
                // Only request focus once.  Re-requesting on every
                // pause→play status update can briefly lose focus and was
                // auto-pausing AirPods resume after ~0.5s.
                if (!hasAudioFocus) requestFocus();
                // Claiming the session must not claim that sound is coming out of it:
                // with STATE_PLAYING here KOReader looked like it was playing while idle.
                // PAUSED keeps the session the freshest for headset keys; setPlaying(true)
                // flips it the moment playback really starts.
                setStateInternal(PlaybackState.STATE_PAUSED, positionMs);
                active = true;
                scheduleModePoll();
                registerNoisy();
            }
        });
    }

    public void stop() {
        worker.post(new Runnable() {
            @Override
            public void run() {
                active = false;
                pausedByInterrupt = false;
                worker.removeCallbacks(modePoll);
                unregisterModeListener();
                unregisterNoisy();
                setStateInternal(PlaybackState.STATE_STOPPED, positionMs);
                abandonFocus();
                releaseSessionLocked();
            }
        });
    }

    public void setPlaying(final boolean playing, final long posMs) {
        positionMs = Math.max(0, posMs);
        worker.post(new Runnable() {
            @Override
            public void run() {
                if (!active && session == null) return;
                ensureSessionLocked();
                if (playing) {
                    // User (or we) resumed: any pending auto-resume is moot.
                    pausedByInterrupt = false;
                    if (!hasAudioFocus) requestFocus();
                }
                setStateInternal(playing ? PlaybackState.STATE_PLAYING
                                         : PlaybackState.STATE_PAUSED, positionMs);
            }
        });
    }

    public void setMetadata(final String trackTitle, final String trackArtist) {
        if (trackTitle != null && trackTitle.length() > 0) title = trackTitle;
        if (trackArtist != null) artist = trackArtist;
        worker.post(new Runnable() {
            @Override
            public void run() {
                if (session == null) return;
                applyMetadataLocked();
            }
        });
    }

    /**
     * Atomically read-and-clear the next pending media-button command.
     * @return CMD_* constant
     */
    public int getPendingCommand() {
        synchronized (lock) {
            int c = pendingInterrupt;
            if (c != CMD_NONE) {
                pendingInterrupt = CMD_NONE;
                return c;
            }
            c = pendingCommand;
            pendingCommand = CMD_NONE;
            return c;
        }
    }

    public void shutdown() {
        stop();
        worker.post(new Runnable() {
            @Override
            public void run() {
                releaseSessionLocked();
                try { workerThread.quitSafely(); } catch (Exception ignored) {}
            }
        });
    }

    private void enqueue(int cmd) {
        long now = System.currentTimeMillis();
        synchronized (lock) {
            // AirPods / AVRCP often deliver both Callback.onPlay/onPause AND a
            // media-button event for one stem press.  Keep the first command
            // and suppress duplicates for a short window so resume is not
            // immediately toggled back to pause (~0.5s play bug).
            if (now < suppressCommandUntilMs) {
                return;
            }
            pendingCommand = cmd;
            suppressCommandUntilMs = now + 700;
        }
        wake();
    }

    private void enqueueInterrupt(int cmd) {
        synchronized (lock) {
            pendingInterrupt = cmd;
        }
        wake();
    }

    private void registerNoisy() {
        if (noisyReceiver != null) return;
        noisyReceiver = new android.content.BroadcastReceiver() {
            @Override
            public void onReceive(Context c, Intent i) {
                if (AudioManager.ACTION_AUDIO_BECOMING_NOISY.equals(i.getAction())) enqueueInterrupt(CMD_NOISY);
            }
        };
        android.content.IntentFilter f = new android.content.IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY);
        try {
            if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(noisyReceiver, f, null, worker, 4 /* RECEIVER_NOT_EXPORTED */);
            else context.registerReceiver(noisyReceiver, f, null, worker);
        } catch (Exception e) { noisyReceiver = null; }
    }

    private void unregisterNoisy() {
        if (noisyReceiver == null) return;
        try { context.unregisterReceiver(noisyReceiver); } catch (Exception ignored) {}
        noisyReceiver = null;
    }

    private void onMode(int mode) {
        if (!active) return;
        boolean call = isCallMode(mode);
        if (call && !inCall) { inCall = true; interruptBegin(); }
        else if (!call && inCall) { inCall = false; interruptEnd(); }
    }

    private void unregisterModeListener() {
        if (modeListener == null || audioManager == null || Build.VERSION.SDK_INT < 31) return;
        try { audioManager.removeOnModeChangedListener((AudioManager.OnModeChangedListener) modeListener); } catch (Exception ignored) {}
        modeListener = null;
    }

    /** Something (call, other player) interrupted us: pause if playing. */
    private void interruptBegin() {
        if (playbackState == PlaybackState.STATE_PLAYING) {
            pausedByInterrupt = true;
            // Reflect the pause immediately so a second interruption source
            // (focus + mode) does not enqueue another pause.
            setStateInternal(PlaybackState.STATE_PAUSED, positionMs);
            enqueueInterrupt(CMD_INTERRUPT_PAUSE);
        }
    }

    /** All interruptions are over: resume if we were the ones who paused. */
    private void interruptEnd() {
        if (focusLost || inCall) return;
        if (pausedByInterrupt) {
            pausedByInterrupt = false;
            enqueueInterrupt(CMD_INTERRUPT_RESUME);
        }
    }

    private static boolean isCallMode(int mode) {
        return mode == AudioManager.MODE_IN_CALL
            || mode == AudioManager.MODE_IN_COMMUNICATION
            || mode == AudioManager.MODE_RINGTONE
            || (Build.VERSION.SDK_INT >= 30 && mode == 4 /* MODE_CALL_SCREENING */)
            || (Build.VERSION.SDK_INT >= 33 && mode == 5 /* MODE_CALL_REDIRECT */)
            || (Build.VERSION.SDK_INT >= 33 && mode == 6 /* MODE_COMMUNICATION_REDIRECT */);
    }

    private final Runnable modePoll = new Runnable() {
        @Override
        public void run() {
            if (!active || audioManager == null) return;
            boolean call = false;
            try { call = isCallMode(audioManager.getMode()); } catch (Exception ignored) {}
            if (call && !inCall) {
                inCall = true;
                interruptBegin();
            } else if (!call && inCall) {
                inCall = false;
                interruptEnd();
            }
            worker.postDelayed(this, MODE_POLL_MS);
        }
    };

    private void scheduleModePoll() {
        worker.removeCallbacks(modePoll);
        // Android 12+: the system tells us when the audio mode changes (call, VoIP) — no polling once a second.
        if (Build.VERSION.SDK_INT >= 31 && audioManager != null) {
            if (modeListener == null) try {
                AudioManager.OnModeChangedListener l = new AudioManager.OnModeChangedListener() {
                    @Override public void onModeChanged(final int mode) { worker.post(new Runnable() { @Override public void run() { onMode(mode); } }); }
                };
                audioManager.addOnModeChangedListener(new java.util.concurrent.Executor() {
                    @Override public void execute(Runnable r) { worker.post(r); }
                }, l);
                modeListener = l;
                try { onMode(audioManager.getMode()); } catch (Exception ignored) {}
                return;
            } catch (Exception e) { modeListener = null; }
            else return;
        }
        worker.postDelayed(modePoll, MODE_POLL_MS);
    }

    private void ensureSessionLocked() {
        if (session != null) return;
        session = new MediaSession(context, "audiobook.koplugin");
        session.setFlags(MediaSession.FLAG_HANDLES_MEDIA_BUTTONS
                | MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS);
        session.setCallback(new MediaSession.Callback() {
            @Override
            public void onPlay() { enqueue(CMD_PLAY); }

            @Override
            public void onPause() { enqueue(CMD_PAUSE); }

            @Override
            public void onStop() { enqueue(CMD_STOP); }

            @Override
            public void onSkipToNext() { enqueue(CMD_NEXT); }

            @Override
            public void onSkipToPrevious() { enqueue(CMD_PREV); }

            @Override
            public boolean onMediaButtonEvent(Intent intent) {
                // Let the default implementation map keys → onPlay/onPause
                // once based on PlaybackState.  Handling keys ourselves AND
                // receiving transport callbacks caused duplicate commands.
                return super.onMediaButtonEvent(intent);
            }
        }, worker);

        // Media button receiver intent so the system can wake us.
        try {
            Intent mb = new Intent(Intent.ACTION_MEDIA_BUTTON);
            mb.setPackage(context.getPackageName());
            int flags = PendingIntent.FLAG_UPDATE_CURRENT;
            if (Build.VERSION.SDK_INT >= 23) {
                flags |= PendingIntent.FLAG_IMMUTABLE;
            }
            PendingIntent pi = PendingIntent.getBroadcast(context, 0, mb, flags);
            session.setMediaButtonReceiver(pi);
        } catch (Exception ignored) {}

        applyMetadataLocked();
        session.setActive(true);
    }

    private void applyMetadataLocked() {
        if (session == null) return;
        MediaMetadata.Builder b = new MediaMetadata.Builder()
            .putString(MediaMetadata.METADATA_KEY_TITLE, title)
            .putString(MediaMetadata.METADATA_KEY_ARTIST,
                (artist != null && artist.length() > 0) ? artist : "Audiobook Read-Along")
            .putString(MediaMetadata.METADATA_KEY_ALBUM, "KOReader");
        session.setMetadata(b.build());
    }

    private void setStateInternal(int state, long posMs) {
        playbackState = state;
        if (session == null) return;
        long actions = PlaybackState.ACTION_PLAY
                | PlaybackState.ACTION_PAUSE
                | PlaybackState.ACTION_PLAY_PAUSE
                | PlaybackState.ACTION_STOP
                | PlaybackState.ACTION_SKIP_TO_NEXT
                | PlaybackState.ACTION_SKIP_TO_PREVIOUS
                | PlaybackState.ACTION_SEEK_TO;
        PlaybackState.Builder b = new PlaybackState.Builder()
            .setActions(actions)
            .setState(state, Math.max(0, posMs),
                state == PlaybackState.STATE_PLAYING ? 1.0f : 0.0f);
        session.setPlaybackState(b.build());
        if (!session.isActive()) session.setActive(true);
        holdMediaButtons(state == PlaybackState.STATE_PLAYING);
    }

    // Android gives headset keys to the session of the app whose own player is active.
    // In queue mode the TTS engine plays the speech in ITS process, so KOReader played
    // nothing and "Media button session" became null: headset keys stopped working.
    // While reading, a static looping buffer of zeros keeps KOReader's uid playing.
    // No focus request, no thread, no audible sound; stopped on pause/stop/release.
    private AudioTrack silentTrack;

    private void holdMediaButtons(boolean on) {
        if (on == (silentTrack != null)) return;
        if (!on) {
            try { silentTrack.stop(); } catch (Exception ignored) {}
            try { silentTrack.release(); } catch (Exception ignored) {}
            silentTrack = null;
            return;
        }
        if (Build.VERSION.SDK_INT < 23) return;
        try {
            int frames = 8000;
            AudioTrack t = new AudioTrack.Builder()
                .setAudioAttributes(new AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                .setAudioFormat(new AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(16000)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
                .setTransferMode(AudioTrack.MODE_STATIC)
                .setBufferSizeInBytes(frames * 2)
                .build();
            t.write(new short[frames], 0, frames);
            t.setLoopPoints(0, frames, -1);
            t.play();
            silentTrack = t;
        } catch (Exception e) {
            silentTrack = null;
        }
    }

    private void releaseSessionLocked() {
        holdMediaButtons(false);
        if (session != null) {
            try { session.setActive(false); } catch (Exception ignored) {}
            try { session.release(); } catch (Exception ignored) {}
            session = null;
        }
    }

    private void requestFocus() {
        if (audioManager == null) return;
        try {
            if (focusListener == null) {
                focusListener = new AudioManager.OnAudioFocusChangeListener() {
                    @Override
                    public void onAudioFocusChange(int focusChange) {
                        switch (focusChange) {
                            case AudioManager.AUDIOFOCUS_GAIN:
                            case AudioManager.AUDIOFOCUS_GAIN_TRANSIENT:
                            case AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK:
                                hasAudioFocus = true;
                                focusLost = false;
                                interruptEnd();
                                break;
                            case AudioManager.AUDIOFOCUS_LOSS_TRANSIENT:
                            case AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK:
                                // Phone call, navigation prompt, voice assistant,
                                // an app reading a notification aloud: pause now,
                                // resume when focus comes back.  Spoken word is
                                // not ducked under another voice (MyTTS fork).
                                focusLost = true;
                                interruptBegin();
                                break;
                            case AudioManager.AUDIOFOCUS_LOSS:
                                // Another player took over for good: pause and
                                // do not auto-resume.
                                hasAudioFocus = false;
                                focusLost = false;
                                if (playbackState == PlaybackState.STATE_PLAYING) {
                                    pausedByInterrupt = false;
                                    setStateInternal(PlaybackState.STATE_PAUSED, positionMs);
                                    enqueueInterrupt(CMD_INTERRUPT_PAUSE);
                                }
                                break;
                            default:
                                break;
                        }
                    }
                };
            }
            if (Build.VERSION.SDK_INT >= 26) {
                AudioAttributes attrs = new AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build();
                // Full GAIN like any audiobook/podcast player, so the system
                // delivers LOSS_TRANSIENT on incoming calls.  Spoken word
                // pauses rather than being ducked under a notification.
                AudioFocusRequest req = new AudioFocusRequest.Builder(
                        AudioManager.AUDIOFOCUS_GAIN)
                    .setAudioAttributes(attrs)
                    // Delivered LOSS_TRANSIENT_CAN_DUCK instead of being ducked
                    // by the system: two voices at once are not understood.
                    .setWillPauseWhenDucked(true)
                    .setAcceptsDelayedFocusGain(false)
                    .setOnAudioFocusChangeListener(focusListener, worker)
                    .build();
                audioFocusRequest = req;
                int r = audioManager.requestAudioFocus(req);
                hasAudioFocus = (r == AudioManager.AUDIOFOCUS_REQUEST_GRANTED);
            } else {
                int r = audioManager.requestAudioFocus(
                    focusListener,
                    AudioManager.STREAM_MUSIC,
                    AudioManager.AUDIOFOCUS_GAIN);
                hasAudioFocus = (r == AudioManager.AUDIOFOCUS_REQUEST_GRANTED);
            }
        } catch (Exception ignored) {}
    }

    private void abandonFocus() {
        if (audioManager == null) return;
        try {
            if (Build.VERSION.SDK_INT >= 26 && audioFocusRequest != null) {
                audioManager.abandonAudioFocusRequest((AudioFocusRequest) audioFocusRequest);
                audioFocusRequest = null;
            } else if (focusListener != null) {
                audioManager.abandonAudioFocus(focusListener);
            }
            hasAudioFocus = false;
            focusLost = false;
        } catch (Exception ignored) {}
    }
}
