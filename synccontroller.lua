--[[--
Read-aloud controller (Android).

The book goes to the Android TTS engine's own queue (TextToSpeech.speak with QUEUE_ADD), sentence by sentence, from
one stream over the document (docstream.lua): a cursor that only moves forward, so a word is never sent twice and
nothing is glued from screen extracts. The engine plays the queue as one continuous stream and prepares the next
sentences while one sounds; KOReader only follows its events: onStart highlights the sentence and turns the screen to
it, onDone keeps about a minute of speech queued. Pages turn when the voice reaches them, never because text ran out.

Pause stops the queue; resume starts again from the beginning of the interrupted sentence (the engine usually still has
its audio). Jumps (previous/next sentence, back N seconds, chapters, speed change) start a new run from a sentence's
own position. An engine that stops answering is reconnected and the run starts again from the sentence being heard.

@module synccontroller
--]]

local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local time = require("ui/time")
local _ = require("audiobook_gettext")
local T = require("ffi/util").template

local _utils_dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
local DocStream = dofile(_utils_dir .. "docstream.lua")
local PLUGIN_PATH = _utils_dir

--- Diagnostic log (plugin menu «Подробный журнал», off by default): only short lines, timings, no book text.
local function dlog(...)
    local DL = package.loaded["audiobook_debuglog"]
    if DL and DL.log then pcall(DL.log, ...) end
end

local function now_s() return time.to_s(UIManager:getTime()) end

local SyncController = {
    STATE = { STOPPED = "stopped", PLAYING = "playing", PAUSED = "paused", LOADING = "loading" },
    -- Queue budget: about a minute of speech ahead, bounded in sentences and text sent through JNI.
    QUEUE_TARGET_S = 60,
    QUEUE_MIN_ITEMS = 4,
    QUEUE_MAX_ITEMS = 48,
    QUEUE_MAX_CHARS = 10000,
    POLL_S = 0.2,
    MAX_RECOVERIES = 3,
    PENDING_MAX_S = 6,
}

function SyncController:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o.state = self.STATE.STOPPED
    o.current_sentence = nil
    o.reading_sentence_idx = 0
    o.playback_bar = nil
    o._q = {}            -- queued and not finished, in order: { id, s, chars, words }
    o._q_by_id = {}
    o._heard = {}        -- sentences heard lately: { from, t, chars }
    o._run, o._seq = 0, 0
    return o
end

-- ── Documents ─────────────────────────────────────────────────────────

function SyncController:_doc()
    local ui = self.plugin and self.plugin.ui
    return ui and ui.document, ui
end

function SyncController:_byPosition()
    local doc, ui = self:_doc()
    return ui and ui.rolling and DocStream.supported(doc)
end

function SyncController:_parse(text)
    return self.text_parser:parse(text)
end

--- A new stream at [where]: { xp = position (the sentence holding it) } | { exact = word start } | nil (top of the view).
function SyncController:_openStream(where)
    local doc, ui = self:_doc()
    if not doc then return nil end
    where = where or {}
    if self:_byPosition() then
        local st = DocStream.new(doc, function(t) return self:_parse(t) end)
        if where.exact then
            st:seekExact(where.exact)
        else
            local xp = where.xp
            if not xp then pcall(function() xp = doc:getXPointer() end) end
            if not xp or not st:seek(xp) then return nil end
        end
        return st
    end
    -- Fixed layout (PDF, DjVu): page after page.
    local plugin = self.plugin
    local count = 1
    pcall(function() count = doc:getPageCount() end)
    local page = where.page or (ui.getCurrentPage and ui:getCurrentPage()) or 1
    local st = DocStream.PageStream.new(function(p) return plugin:getPageText(p) end, self.text_parser, page, count)
    st:seek(page, where.index or 1)
    return st
end

-- ── Start / stop ──────────────────────────────────────────────────────

--- Start reading. [text] is not used for books read by position (the stream reads the document); opts.anchor_xp
--- starts at the sentence holding that position («read from here»), otherwise at the sentence holding the top of the
--- screen.
function SyncController:start(text, opts)
    opts = opts or {}
    if not self.playback_bar then self:showPlaybackBar() end
    self:_ttsResetClock()
    self._recoveries = 0
    self._user_paused = false
    local where = opts.anchor_xp and { xp = opts.anchor_xp } or nil
    dlog("read start", opts.anchor_xp and "anchor" or "view", self:_byPosition() and "position" or "pages")
    self:_beginAt(where)
end

--- Restart after a stop: from the top of the screen.
function SyncController:restartFromStopped()
    if self.state ~= self.STATE.STOPPED then return end
    self:start()
end

--- A new run from [where] (see _openStream): drop the engine's queue, refill from there.
function SyncController:_beginAt(where)
    local e = self.tts_engine
    if e then e:queueStopAndroid() end
    self._run = self._run + 1
    self._q, self._q_by_id = {}, {}
    self._started_in_run = false
    self._ended = false
    self._pending_since = nil
    self._t_run = now_s()
    self.stream = self:_openStream(where)
    if not self.stream then
        dlog("read nothing-to-read")
        self:stop()
        return
    end
    self.state = self.STATE.PLAYING
    self:_ttsMarkPlay()
    if self.playback_bar then self.playback_bar:updatePlayState(true) end
    self:_applyBarVisibility()
    self:_publishPlaying(true)
    self:_fill()
    self:_ensurePoll()
    local MyTTS = self.plugin and self.plugin._mytts
    if MyTTS then
        MyTTS._sent_index, MyTTS._last_ahead = nil, nil
        pcall(MyTTS.ahead, self.plugin)
    end
end

function SyncController:_publishPlaying(playing)
    local p = self.plugin
    if not p then return end
    local f = playing and p.notifyAudioPlaying or p.notifyAudioPaused
    if f then pcall(f, p) end
end

function SyncController:pause(auto)
    if self.state ~= self.STATE.PLAYING then return end
    self.state = self.STATE.PAUSED
    if not auto then self._user_paused = true end
    if self.tts_engine then self.tts_engine:pause() end
    self:_ttsMarkPause()
    self:_publishPlaying(false)
    if self.playback_bar then self.playback_bar:updatePlayState(false) end
    self:_applyBarVisibility()
    dlog("read pause", auto and "auto" or "user")
end

--- Resume: the interrupted sentence again from its beginning.
function SyncController:resume(auto)
    if self.state ~= self.STATE.PAUSED then return end
    if auto and self._user_paused then return end
    self._user_paused = false
    local cur = self.current_sentence
    dlog("read resume", auto and "auto" or "user")
    self:_restartAt(cur)
end

--- A new run from sentence [s] (its own start), or from the top of the screen.
function SyncController:_restartAt(s)
    if s and s.from then
        self:_beginAt({ exact = s.from })
    elseif s and s.page then
        self:_beginAt({ page = s.page, index = s.index })
    else
        self:_beginAt(nil)
    end
end

function SyncController:stop(opts)
    if self.state ~= self.STATE.STOPPED then dlog("read stop from", self.state) end
    self.state = self.STATE.STOPPED
    self._run = self._run + 1
    if self.tts_engine then pcall(function() self.tts_engine:stop() end) end
    if self.highlight_manager then pcall(function() self.highlight_manager:clearHighlights() end) end
    self._q, self._q_by_id = {}, {}
    self.stream = nil
    self.current_sentence = nil
    self._user_paused = false
    self:_ttsMarkPause()
    if opts and opts.hide_bar then
        pcall(function() self:hidePlaybackBar() end)
    elseif self.playback_bar then
        pcall(function() self.playback_bar:updatePlayState(false) end)
    end
    self:_publishPlaying(false)
end

function SyncController:isPlaying() return self.state == self.STATE.PLAYING end
function SyncController:isPaused() return self.state == self.STATE.PAUSED end
function SyncController:isStopped() return self.state == self.STATE.STOPPED end

-- ── The queue ─────────────────────────────────────────────────────────

local function countWords(t)
    local n = 0
    for _ in t:gmatch("%S+") do n = n + 1 end
    return n
end

--- Seconds of speech queued and not yet finished (estimated from words and the measured pace).
function SyncController:_queuedSeconds()
    local wps = (self._wps or 2.6) * math.max(0.25, (self.tts_engine and self.tts_engine.rate) or 1)
    local secs = 0
    for _, it in ipairs(self._q) do secs = secs + (it.secs or math.max(0.4, it.words / wps)) end
    return secs
end

--- Keep about QUEUE_TARGET_S of speech in the engine's queue.
function SyncController:_fill()
    if self.state ~= self.STATE.PLAYING or not self.stream then return end
    if self._ended then
        if #self._q == 0 then
            dlog("read end of book")
            self:stop()
        end
        return
    end
    local e = self.tts_engine
    local t0 = os.clock()
    local chars = 0
    for _, it in ipairs(self._q) do chars = chars + it.chars end
    local secs = self:_queuedSeconds()
    local wps = (self._wps or 2.6) * math.max(0.25, e.rate or 1)
    local added = 0
    while #self._q < self.QUEUE_MAX_ITEMS and chars < self.QUEUE_MAX_CHARS
            and (#self._q < self.QUEUE_MIN_ITEMS or secs < self.QUEUE_TARGET_S) do
        local s = self._held or self.stream:next()
        self._held = nil
        if not s then
            self._ended = true
            break
        end
        local first = (#self._q == 0 and not self._started_in_run and added == 0)
        self._seq = self._seq + 1
        local id = "q:" .. self._run .. ":" .. self._seq
        local ok, why = e:queueSpeakAndroid(id, s.text, first)
        if not ok then
            -- The engine is still binding (just started or restarted): the same sentence again shortly.
            self._held = s
            self._seq = self._seq - 1
            if why == "pending" and first then
                self._pending_since = self._pending_since or now_s()
                if now_s() - self._pending_since < self.PENDING_MAX_S then
                    local run = self._run
                    UIManager:scheduleIn(0.15, function()
                        if self._run == run then self:_fill() end
                    end)
                    return
                end
            end
            dlog("read dispatch-failed", why)
            return self:_recover("dispatch " .. tostring(why), true)
        end
        self._pending_since = nil
        local it = { id = id, s = s, chars = #s.text, words = countWords(s.text), t_q = now_s() }
        self._q[#self._q + 1] = it
        self._q_by_id[id] = it
        chars = chars + it.chars
        secs = secs + math.max(0.4, it.words / wps)
        added = added + 1
        -- After a chapter heading a pause, so the heading is heard apart from the text («VI» — pause — «Полковника…»).
        local pause = s.heading and tonumber(self.plugin and self.plugin:getSetting("heading_pause", 1.5)) or 0
        if pause > 0 then
            self._seq = self._seq + 1
            local pid = "q:" .. self._run .. ":" .. self._seq .. ":p"
            if e.queueSilenceAndroid and e:queueSilenceAndroid(pid, math.floor(pause * 1000)) then
                local p = { id = pid, pause = true, chars = 0, words = 0, secs = pause, t_q = now_s() }
                self._q[#self._q + 1] = p
                self._q_by_id[pid] = p
                secs = secs + pause
                dlog("read heading pause", pause)
            end
        end
    end
    if added > 0 then
        dlog("read fill +" .. added, "queued", #self._q, string.format("%.0fs %.1fms", secs, (os.clock() - t0) * 1000))
    end
    if self._ended and #self._q == 0 then
        dlog("read end of book")
        self:stop()
    end
end

function SyncController:_ensurePoll()
    if self._polling then return end
    self._polling = true
    local function tick()
        if self.state ~= self.STATE.PLAYING then
            self._polling = false
            return
        end
        local ok, err = pcall(self._tick, self)
        if not ok then logger.warn("SyncController: tick failed:", err) end
        UIManager:scheduleIn(self.POLL_S, tick)
    end
    UIManager:scheduleIn(self.POLL_S, tick)
end

--- Follow the engine: every start, end, error and range since the last tick, in order.
function SyncController:_tick()
    local e = self.tts_engine
    local events, lost = e:queueEventsAndroid()
    if events == nil then return end
    if lost then return self:_recover("engine lost", true) end
    local run = self._run
    for _, ev in ipairs(events) do
        if self._run ~= run or self.state ~= self.STATE.PLAYING then return end
        local it = self._q_by_id[ev.id]
        if it then
            self._changed_at = now_s()
            if ev.kind == "S" then
                self:_onStart(it)
            elseif ev.kind == "D" then
                self:_onDone(it)
            elseif ev.kind == "E" then
                dlog("read engine-error", ev.extra)
                if not self._started_in_run then
                    return self:_recover("engine refuses the queue (" .. tostring(ev.extra) .. ")", true)
                end
                -- One sentence the engine could not say (a language it has no voice for): go on.
                self:_onDone(it)
            elseif ev.kind == "R" then
                self:_onRange(it, ev.extra)
            end
        end
    end
    -- Nothing started or ended for far longer than the sentence could take: the engine is stuck or was restarted.
    if #self._q > 0 and self._changed_at then
        local head = self._q[1]
        local limit = 25 + math.floor(head.chars / 10)
        if now_s() - self._changed_at > limit then self:_recover("no progress for " .. limit .. " s", false) end
    elseif #self._q > 0 then
        self._changed_at = now_s()
    end
end

function SyncController:_onStart(it)
    if it.started then return end
    it.started = now_s()
    if it.pause then
        while self._q[1] and self._q[1] ~= it do
            local old = table.remove(self._q, 1)
            self._q_by_id[old.id] = nil
        end
        return
    end
    if not self._started_in_run then
        self._started_in_run = true
        dlog("read first-sound", string.format("%.0fms", (it.started - (self._t_run or it.started)) * 1000))
    elseif self._last_done_t then
        local gap = it.started - self._last_done_t
        if gap > 0.25 then dlog("read gap", string.format("%.0fms", gap * 1000), "queued", #self._q) end
    end
    self._recoveries = 0
    -- Sentences queued before it that never started (an engine that skipped them) are over.
    while self._q[1] and self._q[1] ~= it do
        local old = table.remove(self._q, 1)
        self._q_by_id[old.id] = nil
    end
    local s = it.s
    self.current_sentence = s
    self.reading_sentence_idx = self.reading_sentence_idx + 1
    self._reading_xp = s.xp0
    self._reading_page = s.page
    self._heard[#self._heard + 1] = { from = s.from, page = s.page, index = s.index, t = it.started,
        chars = select(2, s.text:gsub("[^\128-\191]", "")) }
    if #self._heard > 80 then table.remove(self._heard, 1) end
    self:_show(it)
    if self.playback_bar then
        self.playback_bar:updatePlayState(true)
        self.playback_bar:updateProgress(self:getProgress())
        self:_refreshTtsTimeUi()
    end
    local MyTTS = self.plugin and self.plugin._mytts
    if MyTTS then pcall(MyTTS.ahead, self.plugin) end
end

function SyncController:_onDone(it)
    local t = now_s()
    if it.started and not it.pause then
        local elapsed = t - it.started
        if elapsed > 0.5 then
            local wps = math.max(1, math.min(6, it.words / elapsed / math.max(0.25, self.tts_engine.rate or 1)))
            self._wps = (self._wps or wps) * 0.8 + wps * 0.2
        end
    end
    self._last_done_t = t
    -- This one and anything queued before it are over.
    while self._q[1] do
        local old = table.remove(self._q, 1)
        self._q_by_id[old.id] = nil
        if old == it then break end
    end
    self:_fill()
end

--- The voice is inside a sentence (onRangeStart: UTF-16 offset in its text): a sentence running onto the next screen
--- turns it when the voice gets there.
function SyncController:_onRange(it, extra)
    if not it.turn_at or it.turned then return end
    local start = tonumber((extra or ""):match("^(%d+)"))
    if not start or start < it.turn_at then return end
    it.turned = true
    self:_follow(it, true)
end

--- The engine stopped answering: reconnect when it was lost, then start again from the sentence being heard.
function SyncController:_recover(reason, lost)
    self._recoveries = (self._recoveries or 0) + 1
    logger.warn("SyncController: recovery", self._recoveries, ":", reason)
    dlog("read recover", self._recoveries, reason)
    local e = self.tts_engine
    e:queueStopAndroid()
    if lost or not self._started_in_run then pcall(function() e:reconnectAndroidTts() end) end
    if self._recoveries > self.MAX_RECOVERIES then
        self:stop()
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{ text = _("The TTS engine does not respond. Reading stopped."), timeout = 5 })
        return
    end
    local head = self._q[1]
    local s = (head and head.started and head.s) or self.current_sentence or (head and head.s)
    self:_restartAt(s)
end

-- ── Showing: highlight and page follow ────────────────────────────────

function SyncController:_pageMode()
    local _, ui = self:_doc()
    return not (ui and ui.view and ui.view.view_mode == "scroll")
end

--- Pages shown at once (two in dual-page mode).
function SyncController:_visiblePages()
    local doc = self:_doc()
    local n = 1
    if doc and doc.getVisiblePageCount then
        local ok, v = pcall(doc.getVisiblePageCount, doc)
        if ok and type(v) == "number" and v >= 1 then n = v end
    end
    return n
end

function SyncController:_currentPage()
    local doc, ui = self:_doc()
    local p
    pcall(function() p = ui.paging and ui:getCurrentPage() or doc:getCurrentPage() end)
    return p
end

--- Page of a sentence (its first word); nil when unknown.
function SyncController:_pageOf(s, last)
    if s.page then return s.page end
    local doc = self:_doc()
    local p
    local xp = last and s.xp1 or s.xp0
    if xp then pcall(function() p = doc:getPageFromXPointer(xp) end) end
    return p
end

--- True when the page shown is the one read-aloud put there (or shows the sentence): the reader did not browse away.
function SyncController:_following(page)
    local cur = self:_currentPage()
    if not cur then return true end
    if self._shown_page == nil or cur == self._shown_page then return true end
    -- Browsed elsewhere, or onto the page being read.
    if page and page >= cur and page < cur + self:_visiblePages() then
        self._shown_page = cur
        return true
    end
    return false
end

function SyncController:_gotoPage(page, xp)
    local doc, ui = self:_doc()
    dlog("read turn", self:_currentPage(), "->", page)
    if self:_pageMode() or ui.paging then
        ui:handleEvent(Event:new("GotoPage", page))
    elseif xp then
        ui:handleEvent(Event:new("GotoXPointer", xp, xp))
    end
    self._shown_page = self:_currentPage()
end

--- Turn the screen to the sentence [it] (or, with [inside], to its part on the next screen) and highlight it.
function SyncController:_show(it, inside)
    self:_follow(it, inside)
end

function SyncController:_follow(it, inside)
    local plugin = self.plugin
    if not plugin then return end
    local s = it.s
    local p0 = self:_pageOf(s)
    local follow = plugin:getSetting("auto_advance", true)
    if follow and not plugin._app_in_background and self:_following(p0) then
        local cur = self:_currentPage()
        local nvis = self:_visiblePages()
        if inside then
            local p1 = self:_pageOf(s, true)
            if p1 and cur and p1 >= cur + nvis then self:_gotoPage(cur + nvis, nil) end
        elseif p0 and cur and (p0 >= cur + nvis or (p0 < cur and (self:_pageOf(s, true) or p0) < cur)) then
            -- Not on the screen (a sentence begun on the previous screen and running onto this one is: it stays).
            self:_gotoPage(p0, s.xp0)
        elseif self._shown_page == nil then
            self._shown_page = cur
        end
        -- A sentence that runs onto the next screen turns it when the voice gets there.
        if not inside and s.xp1 and self:_pageMode() then
            cur = self:_currentPage()
            local p1 = self:_pageOf(s, true)
            if cur and p1 and p1 >= cur + nvis then
                local doc = self:_doc()
                local next_xp
                pcall(function() next_xp = doc:getPageXPointer(cur + nvis) end)
                it.turn_at = next_xp and DocStream.offsetAt(doc, s, next_xp)
            end
        end
    end
    if plugin:getSetting("highlight_sentences", true) and not plugin._app_in_background then
        pcall(self.highlightCurrentSentence, self, s)
    end
end

function SyncController:highlightCurrentSentence(s)
    if not s or not self.highlight_manager then return end
    if self.plugin and self.plugin._app_in_background then return end
    if s.xp0 then
        self.highlight_manager:highlightSentence({ xp0 = s.xp0, xp1 = s.xp1, text = s.text, index = 0 }, nil)
    elseif s.sentence and s.page == self:_currentPage() then
        self.highlight_manager:highlightSentence(s.sentence, s.parsed)
    end
end

--- Back to the page being read (the «○» button, auto return after browsing).
function SyncController:refocusToReading()
    local s = self.current_sentence
    if not s then return end
    local p = self:_pageOf(s)
    if p then self:_gotoPage(p, s.xp0) end
    UIManager:scheduleIn(0.3, function()
        if self.current_sentence == s then pcall(self.highlightCurrentSentence, self, s) end
    end)
end
SyncController.realignToReadingPage = SyncController.refocusToReading

--- Screen size or font changed: positions are the same, only pages moved. Show the sentence again.
function SyncController:_remapAfterRotation()
    self._shown_page = nil
    local head = self._q[1]
    if head and head.started and head.s then self:_follow(head) end
end

-- ── Jumps ─────────────────────────────────────────────────────────────

function SyncController:_active()
    return self.state == self.STATE.PLAYING or self.state == self.STATE.PAUSED
end

function SyncController:nextSentence()
    if not self:_active() then return end
    for i = 2, #self._q do
        if self._q[i].s then return self:_restartAt(self._q[i].s) end
    end
    local s = self.stream and self.stream:next()
    if s then self:_restartAt(s) end
end

function SyncController:prevSentence()
    if not self:_active() then return end
    local cur = self.current_sentence
    if not cur then return end
    if cur.from and self.stream and self.stream.sentenceBefore then
        local prev = self.stream:sentenceBefore(cur.from)
        return self:_restartAt(prev or cur)
    end
    if cur.page then
        if (cur.index or 1) > 1 then return self:_beginAt({ page = cur.page, index = cur.index - 1 }) end
        return self:_beginAt({ page = math.max(1, cur.page - 1) })
    end
end

--- Back about [seconds] of listening (a headset «previous»: the listener missed something). A pause does not count:
--- each sentence counts at most 30 s.
function SyncController:rewind(seconds)
    if not self:_active() then return end
    local heard = self._heard
    local t_now = now_s()
    local target, back, later = nil, 0, t_now
    for i = #heard, 1, -1 do
        local h = heard[i]
        back = back + math.min(30, math.max(0, later - h.t))
        target = h
        later = h.t
        if back >= seconds then break end
    end
    dlog("read rewind", seconds)
    if target then
        -- Heard sentences from here on are heard again: drop them from the history.
        for i = #heard, 1, -1 do
            local h = table.remove(heard)
            if h == target then break end
        end
        if target.from then return self:_beginAt({ exact = target.from }) end
        return self:_beginAt({ page = target.page, index = target.index })
    end
    self:_restartAt(self.current_sentence)
end

--- Characters read per second, measured on the sentences heard (a pause, over 30 s, does not count); nil until a
--- minute of reading. Follows the engine's real speed.
function SyncController:charsPerSecond()
    local heard = self._heard
    local chars, secs = 0, 0
    for i = 1, #heard - 1 do
        local d = heard[i + 1].t - heard[i].t
        if d > 0 and d <= 30 then chars = chars + (heard[i].chars or 0); secs = secs + d end
    end
    if secs < 60 then return nil end
    return chars / secs
end

-- ── Chapters and progress ─────────────────────────────────────────────

--- The table of contents, kept while the layout (page count) is the same: asked on every sentence for the progress.
function SyncController:_toc()
    local doc = self:_doc()
    local count
    pcall(function() count = doc:getPageCount() end)
    if self._toc_cache and self._toc_count == count and self._toc_doc == doc then return self._toc_cache end
    self._toc_cache, self._toc_count, self._toc_doc = self:_documentToc() or false, count, doc
    return self._toc_cache
end

--- First and next chapter page around [page].
function SyncController:_chapterBounds(page)
    local toc = self:_toc()
    local doc = self:_doc()
    local count = 1
    pcall(function() count = doc:getPageCount() end)
    local c0, c1 = 1, count + 1
    for _, entry in ipairs(toc or {}) do
        local p = tonumber(entry.page)
        if p then
            if p <= page and p >= c0 then c0 = p end
            if p > page and p < c1 then c1 = p end
        end
    end
    return c0, c1
end

--- Progress through the chapter being read, 0–100.
function SyncController:getProgress()
    local s = self.current_sentence
    local p = s and self:_pageOf(s) or self:_currentPage()
    if not p then return 0 end
    local c0, c1 = self:_chapterBounds(p)
    if c1 <= c0 then return 0 end
    return math.max(0, math.min(100, (p - c0) / (c1 - c0) * 100))
end

--- Scrub the chapter: [pct] 0–1 maps onto its pages.
function SyncController:seekToProgress(pct)
    if not self:_active() then return end
    pct = math.max(0, math.min(1, tonumber(pct) or 0))
    local s = self.current_sentence
    local p = s and self:_pageOf(s) or self:_currentPage()
    if not p then return end
    local c0, c1 = self:_chapterBounds(p)
    local target = math.max(c0, math.min(c1 - 1, math.floor(c0 + pct * (c1 - c0))))
    if self:_byPosition() then
        local doc = self:_doc()
        local xp
        pcall(function() xp = doc:getPageXPointer(target) end)
        if xp then self:_beginAt({ xp = xp }) end
    else
        self:_beginAt({ page = target })
    end
end

function SyncController:_gotoTocEntry(entry)
    if not entry then return end
    if not self:_active() then
        local _, ui = self:_doc()
        if entry.xpointer and ui.rolling then ui:handleEvent(Event:new("GotoXPointer", entry.xpointer))
        elseif entry.page then ui:handleEvent(Event:new("GotoPage", entry.page)) end
        return
    end
    self._shown_page = nil
    if entry.xpointer and self:_byPosition() then
        self:_beginAt({ xp = entry.xpointer })
    elseif entry.page then
        self:_beginAt({ page = entry.page })
    end
end

function SyncController:jumpTocRelative(delta)
    local toc = self:_documentToc()
    if not toc then
        if delta > 0 then self:nextSentence() else self:prevSentence() end
        return
    end
    local s = self.current_sentence
    local page = (s and self:_pageOf(s)) or self:_currentPage() or 1
    local idx = 1
    for i, entry in ipairs(toc) do
        if entry.page and entry.page <= page then idx = i end
    end
    idx = math.max(1, math.min(#toc, idx + delta))
    self:_gotoTocEntry(toc[idx])
end

-- ── Speed ─────────────────────────────────────────────────────────────

--- An explicit TTS rate from the player's speed control. Queued audio has the old rate: start again from the sentence
--- being heard so the change is heard at once.
function SyncController:setSpeechRate(speed)
    speed = math.max(0.25, math.min(2.0, tonumber(speed) or 1.0))
    if self.plugin and self.plugin.setSetting then self.plugin:setSetting("speech_rate", speed) end
    if self.tts_engine and self.tts_engine.setRate then self.tts_engine:setRate(speed) end
    if self.playback_bar and self.playback_bar.updateSpeed then
        pcall(function() self.playback_bar:updateSpeed(speed) end)
    end
    if self.state == self.STATE.PLAYING then self:_restartAt(self.current_sentence) end
    return speed
end

-- Old names some callers still use.
function SyncController:updateText() self:start() end
function SyncController:readNextSentence() if self.state ~= self.STATE.STOPPED then self:_restartAt(self.current_sentence) end end
function SyncController:getCurrentSentenceIndex() return self.reading_sentence_idx end
function SyncController:getCurrentWordIndex() return 0 end
function SyncController:getPlaybackTime() return 0 end
function SyncController:getTotalDuration() return 0 end
function SyncController:updatePlaybackBar()
    if not self.playback_bar then return end
    self.playback_bar:updateProgress(self:getProgress())
    self.playback_bar:updatePlayState(self:isPlaying())
    self:_refreshTtsTimeUi()
end

--- Where MyTTS's «prepare» text should begin: the sentence being heard (or the top of the screen).
function SyncController:aheadFrom()
    local s = self.current_sentence
    return s and s.xp0
end

-- ── Playback bar (shared AudiobookPlayer chrome) ──────────────────────

function SyncController:_reserveBarSpace()
    if self._bar_space_reserved then
        self._bar_space_reflowed = false
        return
    end
    if not (self.plugin and self.plugin.ui and self.plugin.ui.rolling) then
        return
    end
    local live = false
    if self.plugin._ensureAudiobookChromeMargins then
        live = self.plugin:_ensureAudiobookChromeMargins() and true or false
    end
    self._bar_space_reserved = true
    self._bar_space_reflowed = live
end

--[[--
Give the reserved bottom-margin space back to the page — unless the inset is
locked for TTS/Storyteller, in which case restoring would reflow the EPUB.
--]]
function SyncController:_releaseBarSpace()
    if not self._bar_space_reserved then return end
    self._bar_space_reserved = false
    self._bar_space_reflowed = false
    if self.plugin and self.plugin._releaseAudiobookChromeMargins then
        self.plugin:_releaseAudiobookChromeMargins()
    end
end

--[[--
Show the playback control bar.
--]]
function SyncController:showPlaybackBar()
    if self.playback_bar then
        self:hidePlaybackBar()
    end

    -- TTS read-along reuses the AudiobookPlayer chrome in tts_mode (mini bar
    -- with speed/sleep controls, full player with chapter list and scrubber).
    -- Same hotfix-load convention as MediaSync.
    local AudiobookPlayer = dofile(PLUGIN_PATH .. "audiobookplayer.lua")

    local plugin = self.plugin
    local title = _("Audiobook")
    local ui = plugin and plugin.ui
    if ui and ui.document then
        local ok_props, props = pcall(function() return ui.document:getProps() end)
        if ok_props and props and props.title and props.title ~= "" then
            title = props.title
        end
    end

    local keep_footer = false
    if plugin and plugin.getSetting and plugin:getSetting("keep_reader_status_bars", false) then
        keep_footer = true
    elseif ui and ui.view and ui.view.footer_visible and ui.view.footer then
        keep_footer = not ui.view.footer.reclaim_height
    end

    local speech_rate = (plugin and plugin.getSetting and plugin:getSetting("speech_rate", 1.0)) or 1.0
    local volume_pct = math.floor(((plugin and plugin.getSetting
        and plugin:getSetting("speech_volume", 1.0)) or 1.0) * 100)

    local controller = self
    self.playback_bar = AudiobookPlayer:new{
        plugin = plugin,
        title = title,
        chapter_title = "",
        output_name = title,
        tts_mode = true,
        start_minimized = true,
        keep_reader_status_bars = keep_footer,
        playback_speed = speech_rate,
        volume_pct = volume_pct,
        show_progress = not (plugin
            and plugin:getSetting("hide_tts_progress_bar", false)),
        ui_widget = ui,
        on_play_pause = function()
            if controller:isPlaying() then
                controller:pause()
            elseif controller:isPaused() then
                controller:resume()
            else
                -- Stopped (end of page, or a stop after a failure): the
                -- bar stays visible, so play restarts from the current
                -- page instead of doing nothing.
                controller:restartFromStopped()
            end
        end,
        on_skip_back = function()
            controller:prevSentence()
        end,
        on_skip_forward = function()
            controller:nextSentence()
        end,
        on_prev_chapter = function()
            controller:jumpTocRelative(-1)
        end,
        on_next_chapter = function()
            controller:jumpTocRelative(1)
        end,
        on_seek = function(pct)
            controller:seekToProgress(pct)
        end,
        on_close = function()
            controller:stop({ hide_bar = true })
        end,
        on_chapter_list = function()
            controller:showTocPicker()
        end,
        on_speed = function(speed)
            controller:setSpeechRate(speed)
        end,
        on_volume = function(pct)
            controller:setSpeechVolumePct(pct)
        end,
        on_sleep_timer_set = function(minutes)
            if plugin and plugin._startSleepTimer then
                plugin:_startSleepTimer(minutes)
            end
        end,
        on_sleep_timer_cancel = function()
            if plugin and plugin._cancelSleepTimer then
                plugin:_cancelSleepTimer()
            end
        end,
        -- «○»: back to the page being read and its highlighted sentence after
        -- browsing away (a manual page turn does not move read-aloud).
        on_refocus = function()
            controller:refocusToReading()
        end,
        on_tts_settings = function()
            local MenuBuilder = dofile(PLUGIN_PATH .. "menubuilder.lua")
            if MenuBuilder and MenuBuilder.showTtsSettingsPicker then
                MenuBuilder.showTtsSettingsPicker(plugin)
            end
        end,
    }

    self.playback_bar:show()
    if plugin then
        pcall(function()
            self.playback_bar:updateSleepTimer(plugin:getSleepTimerRemaining(),
                plugin._sleep_timer_end ~= nil)
        end)
    end

    -- Reflow the page so its text ends above the bar (nothing covered).
    self:_reserveBarSpace()

    -- Force an immediate UI refresh so the bar is painted on the very next
    -- cycle, even if another (toast) notification is still visible.
    UIManager:setDirty(self.playback_bar, "ui")

    -- Honor the visibility preference.  In "paused_only" mode the bar is
    -- created but immediately hidden so subsequent pause/resume calls can
    -- toggle it without re-creating the widget.
    self:_applyBarVisibility()
end

--[[--
Apply the playback_bar_visibility setting.  Called on bar creation, on
beginSentencePlayback (state -> PLAYING), and on every pause/resume so
the bar shows only while paused (or always) per the user preference.

Implementation note (issue #15, PB632 v0.1.5.79 regression):  earlier
versions toggled the bar by adding/removing it from the UIManager window
stack via show()/hide().  When the bar was hidden it lost its tap
interception, so taps fell through to the reader (page turn / dictionary)
and there was no way for the user to bring the bar back.  The overlay
auto-pause poller also misbehaved because the widget was no longer in the
stack.  We now keep the bar mounted at all times and only toggle painting
via setSuppressed(), so taps anywhere still pause and the menu/overlay
detection keeps working.
--]]
function SyncController:_applyBarVisibility()
    if not self.playback_bar then return end
    local mode = self.plugin and self.plugin:getSetting("playback_bar_visibility", "always")
        or "always"
    -- Make sure the bar is mounted.  showPlaybackBar() always mounts it on
    -- creation, but we re-show defensively here in case something else
    -- closed it.
    if not self.playback_bar:isVisible() then
        self.playback_bar:show()
    end
    local should_suppress = (mode == "paused_only") and self:isPlaying()
    self.playback_bar:setSuppressed(should_suppress)
end

--[[--
Hide the playback control bar and refresh the screen.
--]]
function SyncController:hidePlaybackBar()
    -- Remember the page being read before the bar (and its reserved margin)
    -- go away.  Releasing the margin re-typesets the page, and a stale
    -- re-anchor there sends the reader back to where read-aloud began
    -- (possibly many pages earlier).  Re-assert the captured page once the
    -- new layout has settled, and log both positions so a recurrence is
    -- visible in the bug report.
    local ui = self.plugin and self.plugin.ui
    local keep_xp, page, rolling_xp
    if ui and ui.document then
        pcall(function() keep_xp = ui.document:getXPointer() end)
        pcall(function() page = ui.document:getCurrentPage() end)
    end
    if ui and ui.rolling then
        rolling_xp = ui.rolling.xpointer
    end

    if self.playback_bar then
        self.playback_bar:hide()
        self.playback_bar = nil
    end
    -- Give the reserved bottom-margin space back only when the inset is not
    -- locked (TTS and Storyteller must keep the same typeset).
    self:_releaseBarSpace()
    local keep_layout = self.plugin and self.plugin._shouldLockKoreaderMargins
        and self.plugin:_shouldLockKoreaderMargins()
    if not keep_layout then
        -- Force full screen refresh on e-ink to cleanly remove bar and
        -- highlight artifacts.  Skipped under a locked inset: no reflow
        -- happened, so a full flash is pure cost.
        UIManager:setDirty("all", "full")
    end

    if keep_xp and ui and ui.rolling then
        logger.warn("SyncController: hidePlaybackBar page", page,
            "doc_xp=", tostring(keep_xp), "rolling_xp=", tostring(rolling_xp))
        UIManager:scheduleIn(0.4, function()
            if not (ui and ui.rolling and ui.document) then return end
            local now
            pcall(function() now = ui.document:getXPointer() end)
            logger.warn("SyncController: post-stop page", page, "doc_xp=", tostring(now))
            if now ~= keep_xp then
                pcall(function()
                    ui:handleEvent(Event:new("GotoXPointer", keep_xp))
                end)
            end
        end)
    end
end

function SyncController:_ttsResetClock()
    self._tts_elapsed_acc = 0
    self._tts_play_t0 = UIManager:getTime()
end

function SyncController:_ttsMarkPlay()
    self._tts_play_t0 = UIManager:getTime()
end

function SyncController:_ttsMarkPause()
    if self._tts_play_t0 then
        local ok, dt = pcall(function()
            return time.to_s(UIManager:getTime() - self._tts_play_t0)
        end)
        if ok and dt then
            self._tts_elapsed_acc = (self._tts_elapsed_acc or 0) + dt
        end
        self._tts_play_t0 = nil
    end
end

function SyncController:_ttsElapsedSec()
    local acc = self._tts_elapsed_acc or 0
    if self.state == self.STATE.PLAYING and self._tts_play_t0 then
        local ok, dt = pcall(function()
            return time.to_s(UIManager:getTime() - self._tts_play_t0)
        end)
        if ok and dt then
            acc = acc + dt
        end
    end
    return acc
end

function SyncController:_refreshTtsTimeUi()
    local bar = self.playback_bar
    if not bar or not bar.updateTimeDisplay then return end
    local elapsed = self:_ttsElapsedSec()
    local progress = self:getProgress() / 100
    local total = 0
    if progress > 0.05 and elapsed > 0.5 then
        total = elapsed / progress
    end
    pcall(function() bar:updateTimeDisplay(elapsed, total) end)
end

function SyncController:cycleSpeechRate()
    local speeds = {0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0}
    local plugin = self.plugin
    local current = (plugin and plugin.getSetting and plugin:getSetting("speech_rate", 1.0)) or 1.0
    local next_speed = speeds[1]
    for i, s in ipairs(speeds) do
        if math.abs(current - s) < 0.01 then
            next_speed = speeds[i + 1] or speeds[1]
            break
        end
    end
    self:setSpeechRate(next_speed)
end

function SyncController:setSpeechVolumePct(pct)
    pct = tonumber(pct) or 100
    if pct < 0 then pct = 0 end
    if pct > 100 then pct = 100 end
    local vol = pct / 100
    if self.plugin and self.plugin.setSetting then
        self.plugin:setSetting("speech_volume", vol)
    end
    if self.tts_engine and self.tts_engine.setVolume then
        self.tts_engine:setVolume(vol)
    end
end

function SyncController:_documentToc()
    local ui = self.plugin and self.plugin.ui
    if not (ui and ui.document and ui.document.getToc) then return nil end
    local ok, toc = pcall(function() return ui.document:getToc() end)
    if ok and type(toc) == "table" and #toc > 0 then return toc end
    return nil
end


function SyncController:showTocPicker()
    local toc = self:_documentToc()
    local MenuBuilder = dofile(PLUGIN_PATH .. "menubuilder.lua")
    if not toc then
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{
            text = _("No chapters available."),
            timeout = 2,
        })
        return
    end
    local items = {}
    local current = 1
    local current_page
    local ui = self.plugin and self.plugin.ui
    if ui and ui.document and ui.document.getCurrentPage then
        local ok, page = pcall(function() return ui.document:getCurrentPage() end)
        if ok then current_page = page end
    end
    for i, entry in ipairs(toc) do
        local title = entry.title or (_("Chapter") .. " " .. i)
        table.insert(items, {
            text = title,
            callback = function()
                self:_gotoTocEntry(entry)
            end,
        })
        if current_page and entry.page and entry.page <= current_page then
            current = i
        end
    end
    if MenuBuilder and MenuBuilder.showPagedPicker then
        MenuBuilder.showPagedPicker({
            title = _("Chapters"),
            items = items,
            current = current,
        })
    end
end

return SyncController
