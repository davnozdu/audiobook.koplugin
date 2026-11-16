--[[--
Android TTS engine for read-aloud: the system TextToSpeech (MyTTS or any other engine) through tts_helper.dex.

Read-aloud uses only the engine's own queue (speak with QUEUE_ADD, utterance ids «q:run:n»): the engine plays the
sentences as one stream, the plugin follows its events. Nothing is synthesized to files.

@module ttsengine
--]]

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("audiobook_gettext")
local T = require("ffi/util").template

local _utils_dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
local AndroidTts = dofile(_utils_dir .. "androidtts.lua")

local function dlog(...)
    local DL = package.loaded["audiobook_debuglog"]
    if DL and DL.log then pcall(DL.log, ...) end
end

local RE_HAN    = "[\228-\233][\128-\191][\128-\191]"
local RE_KANA   = "\227[\129-\131][\128-\191]"
local RE_HANGUL = "[\234-\237][\128-\191][\128-\191]"

local TTSEngine = {
    BACKENDS = { ANDROID = "android" },
    DEFAULT_RATE = 1.0,
    backend_error = nil,
}

function TTSEngine:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o.rate = o.rate or 1.0
    o.pitch = o.pitch or 50   -- 0–99, 50 = the engine's natural pitch
    o.volume = o.volume or 1.0
    o.backend = self.BACKENDS.ANDROID
    o._android_tts = nil
    o._queue_active = false
    return o
end

function TTSEngine:setBackend() end
function TTSEngine:setRate(rate) self.rate = math.max(0.25, math.min(2.0, tonumber(rate) or 1.0)) end
function TTSEngine:setPitch(pitch) self.pitch = math.max(0, math.min(99, tonumber(pitch) or 50)) end
function TTSEngine:setVolume(volume) self.volume = math.max(0.0, math.min(1.0, tonumber(volume) or 1.0)) end

function TTSEngine:_androidBookLanguage()
    if self._android_book_lang ~= nil then
        return self._android_book_lang or nil
    end
    local lang
    pcall(function()
        local doc = self.plugin and self.plugin.ui and self.plugin.ui.document
        local props = doc and doc.getProps and doc:getProps()
        lang = props and props.language
    end)
    if type(lang) ~= "string" then lang = nil end
    if lang then
        lang = lang:lower():gsub("_", "-"):match("^%s*(.-)%s*$")
        if lang == "" then lang = nil end
    end
    local aliases = {
        zh = "zh-CN", ja = "ja-JP", ko = "ko-KR", en = "en-US",
        fr = "fr-FR", de = "de-DE", es = "es-ES", it = "it-IT",
        pt = "pt-BR", nl = "nl-NL", pl = "pl-PL", cs = "cs-CZ", sk = "sk-SK",
        uk = "uk-UA", hi = "hi-IN", ar = "ar-JO", ca = "ca-ES",
        da = "da-DK", fi = "fi-FI", ru = "ru-RU", el = "el-GR",
        no = "no-NO", nb = "no-NO", nn = "no-NO", sv = "sv-SE",
        tr = "tr-TR", hu = "hu-HU", ro = "ro-RO",
    }
    if lang and aliases[lang] then lang = aliases[lang] end
    self._android_book_lang = lang or false
    logger.dbg("TTSEngine: Android book language =", lang or "(unknown)")
    return lang
end

function TTSEngine:_androidChunkLanguage(text)
    local override = self.plugin
        and self.plugin:getSetting("android_tts_language", "auto")
    if override and override ~= "auto" then
        return override
    end
    local book = self:_androidBookLanguage()
    if text:find(RE_KANA) then return "ja-JP" end
    if text:find(RE_HANGUL) then return "ko-KR" end
    if text:find(RE_HAN) then
        if book == "ja-JP" then return "ja-JP" end
        if book and (book:find("^zh%-tw") or book:find("^zh%-hant")
                or book:find("^zh%-hk") or book:find("^zh%-mo")) then
            return "zh-TW"
        end
        return "zh-CN"
    end
    -- Chunks with no detectable script (numbers, punctuation, Latin
    -- fragments inside a CJK book): reuse the last language the engine
    -- accepted rather than flipping to en-US, which monolingual engines
    -- reject and which kills read-aloud mid-page (issue #96).
    if self._android_last_good_lang and not book then
        return self._android_last_good_lang
    end
    return book or "en-US"
end

function TTSEngine:_androidPitchMultiplier(espeak_pitch)
    local p = tonumber(espeak_pitch) or 50
    if p < 0 then p = 0 elseif p > 99 then p = 99 end
    if p <= 50 then
        return 0.5 + (p / 50) * 0.5
    end
    return 1.0 + ((p - 50) / 49)
end

function TTSEngine:_androidEnginePackage()
    local atts = self._android_tts
    if not atts or not atts.getDefaultEngine then return nil end
    local ok, pkg = pcall(function() return atts:getDefaultEngine() end)
    if not ok or type(pkg) ~= "string" then return nil end
    if pkg == "" or pkg == "pending" or pkg == "not_ready" or pkg == "unknown" then
        return nil
    end
    return pkg
end

function TTSEngine.androidEngineLabelForPackage(pkg)
    if type(pkg) ~= "string" or pkg == "" then return nil end
    if pkg == "pending" then return _("Detecting…") end
    if pkg == "not_ready" or pkg == "unknown" then return _("Not detected") end
    local p = pkg:lower()
    -- MyTTS (com.davnozdu.supertonic.tts.fork): the last segment "fork" says nothing.
    if p:find("davnozdu.supertonic", 1, true) then return _("MyTTS") end
    -- VoxSherpa contains "sherpa"; match it before the generic SherpaTTS apps.
    if p:find("woheller69", 1, true) then return _("SherpaTTS") end
    if p:find("voxsherpa", 1, true) or p:find("codebysonu", 1, true) then
        return _("VoxSherpa TTS")
    end
    if p:find("k2fsa", 1, true) or p:find("k2-fsa", 1, true)
        or p:find("sherpa", 1, true) then
        return _("SherpaTTS")
    end
    if p:find("google", 1, true) then return _("Google") end
    if p:find("samsung", 1, true) then return _("Samsung") end
    if p:find("pico", 1, true) or p:find("svox", 1, true) then
        return _("Pico TTS")
    end
    if p:find("rhvoice", 1, true) then return _("RHVoice") end
    if p:find("piper", 1, true) then return _("Piper") end
    local short = pkg:match("([^.]+)$") or pkg
    return T(_("Unknown (%1)"), short)
end

function TTSEngine:androidEngineDisplayName()
    local pkg = self:_androidEnginePackage()
    if not pkg then return nil end
    return TTSEngine.androidEngineLabelForPackage(pkg)
end

--- Pauses the plugin adds between sentences: none with the engine queue (the engine ends sentences itself).
function TTSEngine:pauseDefault(key)
    return 0
end

--- Lazy-load AndroidTts (dex + TextToSpeech). Safe to call repeatedly.
function TTSEngine:_ensureAndroidTts()
    if self._android_tts then return self._android_tts end
    if self._android_tts_failed then return nil end
    local atts = AndroidTts:new{ plugin_dir = self.plugin_dir or "." }
    local ok, err = pcall(function()
        if not atts:init() then error("AndroidTts:init returned false") end
        if not atts:waitForInit(3000) then
            atts:shutdown()
            error("AndroidTts:waitForInit failed")
        end
    end)
    if not ok then
        self._android_tts_failed = true
        self.backend_error = _("Android TTS is not available.")
        logger.err("TTSEngine: Android TTS init failed:", err)
        return nil
    end
    self._android_tts = atts
    return atts
end

--- Bind to the engine again (its process died: an update, or Android reclaimed its memory).
function TTSEngine:reconnectAndroidTts()
    local old = self._android_tts
    self._android_tts = nil
    self._android_tts_failed = nil
    self:invalidateAndroidVoice()
    self._sent_rate, self._sent_pitch = nil, nil
    self._queue_active = false
    if old then pcall(function() old:shutdown() end) end
    local atts = self:_ensureAndroidTts()
    logger.warn("TTSEngine: Android TTS reconnected, ready=", atts ~= nil)
    dlog("engine reconnect", atts ~= nil)
    return atts ~= nil
end

function TTSEngine:_androidSelectLanguage(atts, text)
    local chunk_lang = self:_androidChunkLanguage(text)
    local voice_name = self.plugin
        and self.plugin:getSetting("android_tts_voice", "")
        or ""
    if voice_name ~= "" then
        if voice_name ~= self._android_tts_voice then
            local res = atts:setVoice(voice_name)
            logger.dbg("TTSEngine: Android TTS voice =", voice_name, "result:", res)
            if res and res >= 0 then
                self._android_tts_voice = voice_name
                self._android_tts_lang = "voice:" .. voice_name
            else
                -- Voice name unknown to this engine; fall back to language.
                self._android_tts_voice = false
                logger.warn("TTSEngine: Android TTS setVoice failed for", voice_name)
            end
        end
    elseif chunk_lang and chunk_lang ~= self._android_tts_lang then
        local res = atts:setLanguage(chunk_lang)
        -- Only cache the language on success: recording a failed switch
        -- would keep the engine on its previous language while Lua
        -- believes otherwise, and repeated failed switches break some
        -- engines outright (monolingual engines like Xiaomi mibrain
        -- reject the languages they have no voice for, issue #96).
        if res and res >= 0 then
            self._android_tts_lang = chunk_lang
            self._android_last_good_lang = chunk_lang
            self._android_tts_voice = nil
        end
        logger.dbg("TTSEngine: Android TTS language =", chunk_lang, "result:", res)
        if res and res < 0 and not self._android_lang_warned then
            -- LANG_MISSING_DATA / LANG_NOT_SUPPORTED: voice data not
            -- installed for this language in the system TTS engine.
            self._android_lang_warned = true
            logger.err("TTSEngine: Android TTS setLanguage(", chunk_lang,
                ") failed, code:", res)
            UIManager:show(InfoMessage:new{
                text = T(_("Android TTS: no voice available for %1.\nInstall the matching voice data in Android's Text-to-speech settings, or pick a different language in Voice settings."), chunk_lang),
                timeout = 8,
            })
        end
    end
end

--- One sentence into the engine's queue.
--- @param id string    utterance id ("q:…")
--- @param flush bool   start a new run (drops whatever the engine still had queued)
--- @return boolean     true when dispatched
--- @return string|nil  on failure: "pending" (the engine is still binding: try again shortly) or "unavailable"
function TTSEngine:queueSpeakAndroid(id, text, flush)
    local atts = self:_ensureAndroidTts()
    if not atts or not atts:hasQueue() then return false, "unavailable" end
    if atts:getInitStatus() == -1 then return false, "pending" end
    -- Rate and pitch cross JNI only when they change.
    if self._sent_rate ~= self.rate then atts:setRate(self.rate or 1.0); self._sent_rate = self.rate end
    if self._sent_pitch ~= self.pitch then
        atts:setPitch(self:_androidPitchMultiplier(self.pitch))
        self._sent_pitch = self.pitch
    end
    self:_androidSelectLanguage(atts, text)
    if atts:queueSpeak(id, text, flush) == 0 then
        self._queue_active = true
        return true
    end
    return false, atts:getInitStatus() == -1 and "pending" or "unavailable"
end

--- Ordered queue events since the last call (see AndroidTts:queueEvents), or nil.
function TTSEngine:queueEventsAndroid()
    if not self._android_tts then return nil end
    return self._android_tts:queueEvents()
end

--- Silence the engine and drop its queue (pause, stop, jump).
function TTSEngine:queueStopAndroid()
    if self._android_tts and self._queue_active then
        pcall(function() self._android_tts:queueStop() end)
    end
    self._queue_active = false
end

function TTSEngine:queueStateAndroid()
    if not self._android_tts then return nil end
    return self._android_tts:queueState()
end

--- Pause: the queue stops, MyTTS fades its background sounds at once.
function TTSEngine:pause()
    self:queueStopAndroid()
    local ok, MyTTS = pcall(require, "mytts")
    if ok and MyTTS and MyTTS.paused then pcall(MyTTS.paused) end
end

function TTSEngine:resume() end
function TTSEngine:stop() self:queueStopAndroid() end
--- Stop at the end of a session; the engine connection stays for the next start.
function TTSEngine:forceKillAll() self:queueStopAndroid() end
function TTSEngine:cleanup() end
function TTSEngine:fullCleanup() end

--- Release the engine connection (the plugin closes).
function TTSEngine:shutdown()
    self:queueStopAndroid()
    if self._android_tts then
        pcall(function() self._android_tts:shutdown() end)
        self._android_tts = nil
    end
end

function TTSEngine:isSpeaking() return self._queue_active end
function TTSEngine:isPaused() return false end

function TTSEngine:listAndroidVoices()
    if self.backend ~= self.BACKENDS.ANDROID then return {} end
    local atts = self:_ensureAndroidTts()
    if not atts or not atts.listVoices then return {} end
    local ok, voices = pcall(function() return atts:listVoices() end)
    if ok and type(voices) == "table" then return voices end
    return {}
end

--[[--
Forget the cached Android language/voice so the next sentence reapplies
the current settings (after the user picks a new voice).
--]]
function TTSEngine:invalidateAndroidVoice()
    self._android_tts_lang = nil
    self._android_tts_voice = nil
    self._android_lang_warned = nil
end

return TTSEngine
