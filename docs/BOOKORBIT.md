# BookOrbit Integration Guide

This guide explains how to use the Audiobook Read-Along plugin together with a [BookOrbit](https://github.com/bookorbit/bookorbit) server. BookOrbit is a self-hosted library platform whose read-along books use the same format this plugin plays: EPUB 3 Media Overlays, the format Storyteller exports. With both plugins installed, your e-reader becomes a first-class read-along device: the recorded narration plays with the publisher's own sentence timing, and your reading position syncs back to your BookOrbit server.

**What this combination gives you**

- Play read-along EPUBs from your BookOrbit library on an e-reader, with real narration and sentence highlighting
- Download books from your BookOrbit library on the device (BookOrbit's own KOReader plugin)
- Reading position syncs to your BookOrbit server while the narration turns pages, so the web reader and the iOS app pick up where the e-reader stopped
- Plain EPUBs (no narration) still work normally with this plugin's text-to-speech read-along

**What to expect**

- The e-reader is the one BookOrbit client that can *play* read-along narration
- Page-level position sync works today; narration-precise position (resume at the exact sentence on another device) is proposed upstream and not yet available
- This plugin does not talk to BookOrbit directly; the [bookorbit.koplugin](https://github.com/bookorbit/bookorbit) companion plugin handles the server connection

---

## Table of Contents

- [Requirements](#requirements)
- [BookOrbit Server Setup](#bookorbit-server-setup)
- [Device Setup](#device-setup)
- [Using the Integration](#using-the-integration)
- [How Progress Sync Works](#how-progress-sync-works)
- [Troubleshooting](#troubleshooting)

---

## Requirements

### On the server side

- A self-hosted BookOrbit server (v3.4 or later is known to work) reachable from your e-reader's network
- At least one book with EPUB 3 media overlays (read-along). BookOrbit does not align ebooks and audiobooks itself; read-alongs are files that already carry overlays, such as Storyteller exports. Books without overlays play with text-to-speech instead
- A BookOrbit account, and a KOReader credential for it (BookOrbit creates these under Settings → KOReader)

### On the e-reader side

- KOReader, with this plugin (audiobook.koplugin) installed
- The [bookorbit.koplugin](https://github.com/bookorbit/bookorbit) companion plugin, installed next to it
- Both plugins are tested to coexist; bookorbit.koplugin handles the server connection, this plugin handles narration playback

---

## BookOrbit Server Setup

1. Import at least one read-along EPUB into a BookOrbit library (drop it into the library folder and scan).
2. Give your KOReader credential the right delivery preference. BookOrbit can deliver each read-along book in two shapes:
   - **Original**: the file with its recorded narration. This is what you want on an e-reader running this plugin.
   - **Text-only**: a smaller copy with the narration and overlay tables stripped. The sentence markup is kept, but there is no audio.
   
   New KOReader credentials default to text-only, because stock KOReader cannot play the audio. In BookOrbit's settings, set the KOReader credential's read-along delivery to **Original** (server-wide default or per device).
3. If you skip this step, nothing breaks: this plugin detects narration-free copies and shows a hint pointing at the delivery setting when you try to start a read-aloud on one.

## Device Setup

1. Install this plugin (see the [README](../README.md#quick-start)).
2. Install bookorbit.koplugin: BookOrbit serves a pre-configured zip for your device (Settings → KOReader on the server), or take the latest from the [bookorbit repository](https://github.com/bookorbit/bookorbit). Copy it into KOReader's plugins directory next to audiobook.koplugin.
3. In KOReader, open the BookOrbit plugin, point it at your server, and sign in with your KOReader credential.
4. KOReader setting worth checking: the BookOrbit plugin refuses to auto-sync unless KOReader's `wifi_enable_action` is set to `turn_on` (so it may turn Wi-Fi on to sync). If you see "auto sync disabled because wifi_enable_action is not turn_on" in the crash log, set that key in KOReader's settings.

---

## Using the Integration

1. In the BookOrbit plugin's catalog, find a read-along book and download it. With the Original delivery preference, the narration comes down as part of the file.
2. Open the book in KOReader.
3. Start the read-aloud from this plugin as usual. The plugin detects the media overlays automatically, plays the recorded narration, and highlights the current sentence with the publisher's own timing.
4. Leave **Follow narration page (aligned)** enabled (it is on by default) so the book turns pages while the narration plays.
5. Read alouds work offline after download; only progress sync needs the server.

Books from the same server without overlays open as plain books. This plugin's TTS read-along reads them, and their positions sync the same way.

## How Progress Sync Works

While the narration plays and turns pages, KOReader's own reading position moves with it. The BookOrbit plugin syncs that position (percentage and text anchor) to your server, so the web reader and the iOS app resume on the page where the e-reader narration stopped. Highlights and bookmarks exchange through the same channel.

One position is not synced today: the exact narration offset. If you stop the e-reader mid-sentence, other BookOrbit clients resume at the page, not the sentence. Narration-precise position needs an extension to BookOrbit's KOReader progress exchange that has been proposed upstream; this plugin will adopt it when available.

---

## Troubleshooting

**The plugin says the book was "delivered without narration".**
You received the text-only copy. In BookOrbit, set the KOReader credential's read-along delivery to **Original** and download the book again. Changing the preference affects future downloads only.

**Progress does not sync.**
Check three things: the bookorbit.koplugin shows you as signed in; KOReader's `wifi_enable_action` is `turn_on` (see Device Setup); and the book was opened through KOReader so its position is tracked. The plugin pushes as pages turn and on book close.

**A downloaded book starts text-to-speech instead of the recorded narration.**
The delivered file has no media overlays. Either the book has none on the server, or the text-only variant was delivered (see the first item).

**The BookOrbit catalog does not list a book.**
BookOrbit's catalog can hide audio-only titles and books without KOReader-compatible files. Check the book on the server's web interface first.
