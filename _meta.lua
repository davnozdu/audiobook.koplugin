--[[--
Plugin metadata for KOReader.

@module _meta
--]]

-- Ensure this plugin dir is on package.path so audiobook_gettext loads
-- when KOReader reads _meta before main.lua runs.
do
    local dir = (debug.getinfo(1, "S").source or ""):match("^@(.*/)") or "./"
    package.path = dir .. "?.lua;" .. package.path
end
local _ = require("audiobook_gettext")

return {
    name = "audiobook",
    version = "0.7.0.1",
    fullname = _("Audiobook Read-Along"),
    description = _([[Read-aloud for Android with synchronized sentence highlighting through the system TTS engine (MyTTS or any other). Also plays pre-recorded audiobooks (mp3, m4b, m4a) and EPUB 3 Media Overlays (Storyteller format), and syncs with Audiobookshelf.

Usage:
1. Long-press a word or select text, then tap "Read aloud from here"
2. Or use Tools menu → Audiobook Read-Along]]),
}
