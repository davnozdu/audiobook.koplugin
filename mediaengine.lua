--[[--
MediaEngine: pre-recorded audiobooks and EPUB Media Overlays on Android, through the system MediaPlayer (JNI,
androidplayer.lua). Seeking, speed and volume are applied live by MediaPlayer.

@module koplugin.audiobook.mediaengine
--]]

local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local time = require("ui/time")
local _ = require("audiobook_gettext")

local MediaEngine = {}

MediaEngine.BACKENDS = { ANDROID = "android" }

function MediaEngine:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o.backend = nil
    o.backend_cmd = nil
    o.play_generation = 0
    o.current_path = nil
    o.current_duration = nil
    o.is_playing = false
    o.is_paused = false
    o._on_complete = nil
    o._on_fail = nil
    o._plugin_dir = o.plugin_dir or "."
    o._play_start_time = nil
    o._pause_start_time = nil
    o._total_pause_ms = 0
    o._seek_offset = 0
    -- Live seek health (session-only): set when the one-shot probe finds MediaPlayer.seekTo is a no-op, switching
    -- seeks to seek-by-restart.
    o._seek_probe_done = false
    o._seek_to_broken = false
    o._volume = 1.0
    -- Last-used playback speed (persisted in setSpeed()).
    o._playback_speed = tonumber(o.plugin
        and o.plugin.getSetting
        and o.plugin:getSetting("playback_speed", 1.0)) or 1.0
    o.position_latency_s = 0
    return o
end

function MediaEngine:_ensureAndroidPlayer()
    if self._android_player then return self._android_player end
    if not (Device.isAndroid and Device:isAndroid()) then return nil end
    local ok, AndroidPlayer = pcall(dofile, self._plugin_dir .. "/androidplayer.lua")
    if not ok or not AndroidPlayer then
        logger.err("MediaEngine: androidplayer.lua failed:", AndroidPlayer)
        return nil
    end
    local player = AndroidPlayer:new()
    if player:init() then
        self._android_player = player
        return player
    end
    return nil
end


function MediaEngine:_fileExists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

function MediaEngine:_nextGeneration()
    self.play_generation = self.play_generation + 1
    return self.play_generation
end

function MediaEngine:detectBackend()
    if self.backend then return self.backend, self.backend_cmd end
    local player = self:_ensureAndroidPlayer()
    if player then
        self.backend = self.BACKENDS.ANDROID
        self.backend_cmd = "android-mediaplayer"
        return self.backend, self.backend_cmd
    end
    self.backend_error = _(
        "Android audio playback is unavailable.\n\n" ..
        "Could not initialize the system MediaPlayer. Restart KOReader and try again.")
    logger.err("MediaEngine: Android MediaPlayer unavailable")
    return nil, nil
end

function MediaEngine:_probeDurationWav(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    -- WAV header: byte 22-23 = channels, 24-27 = sample rate, 28-31 = byte rate,
    -- 40-43 = data chunk size
    f:seek("set", 22)
    local channels_data = f:read(2)
    local rate_data = f:read(4)
    f:seek("set", 40)
    local data_size_data = f:read(4)
    f:close()
    if not channels_data or not rate_data or not data_size_data then return nil end
    local channels = channels_data:byte(1) + channels_data:byte(2) * 256
    local rate = rate_data:byte(1) + rate_data:byte(2) * 256 +
                 rate_data:byte(3) * 65536 + rate_data:byte(4) * 16777216
    local data_size = data_size_data:byte(1) + data_size_data:byte(2) * 256 +
                      data_size_data:byte(3) * 65536 + data_size_data:byte(4) * 16777216
    if channels > 0 and rate > 0 and data_size > 0 then
        local secs = data_size / (rate * channels * 2)
        logger.dbg("MediaEngine: WAV header duration =", secs)
        return secs
    end
    return nil
end

--- Duration before playback: WAV from its header; other formats are known once MediaPlayer has prepared them.
function MediaEngine:probeDuration(path)
    local ext = (path:match("%.([^.]+)$") or ""):lower()
    if ext == "wav" then return self:_probeDurationWav(path) end
    return nil
end

function MediaEngine:load(path)
    if not path or path == "" then
        logger.err("MediaEngine: load() called with empty path")
        return false
    end

    self:detectBackend()
    if not self.backend then
        logger.err("MediaEngine: no backend available")
        return false
    end

    self.current_path = path
    self.current_duration = self:probeDuration(path)
    self.is_playing = false
    self.is_paused = false
    self._seek_offset = 0
    self._use_progress_position = false
    self._progress_file = nil

    logger.warn("MediaEngine: loaded", path,
        "backend=", self.backend,
        "duration=", self.current_duration)
    return true
end

function MediaEngine:play(on_complete, on_fail)
    if not self.current_path then
        logger.err("MediaEngine: play() called without load()")
        if on_fail then on_fail("no file loaded") end
        return false
    end
    self:stop()
    local gen = self:_nextGeneration()
    self._on_complete = on_complete
    self._on_fail = on_fail
    self.is_playing = false
    self.is_paused = false
    self._android_playback_confirmed = false
    local ok = self:_playAndroid(gen)
    if ok then
        self.is_playing = true
        self._play_start_time = UIManager:getTime()
        self._pause_start_time = nil
        self._total_pause_ms = 0
    end
    return ok
end

function MediaEngine:_playAndroid(gen)
    local player = self:_ensureAndroidPlayer()
    if not player then
        logger.err("MediaEngine: Android MediaPlayer unavailable")
        if self._on_fail then self._on_fail("android mediaplayer unavailable") end
        return false
    end

    pcall(function() player:stop() end)

    -- Store rate on the player before play(); JNI applies it after prepare().
    pcall(function()
        player:setSpeed(self._playback_speed or 1.0)
    end)

    local offset = self._seek_offset or 0
    local seek_ms = math.floor(offset * 1000)
    local ok = player:play(self.current_path, seek_ms)
    if not ok then
        logger.err("MediaEngine: Android play failed for", self.current_path)
        if self._on_fail then self._on_fail("android playback failed") end
        return false
    end

    local dur_ms = player:getDurationMs()
    if dur_ms and dur_ms > 0 then
        self.current_duration = dur_ms / 1000
    end

    self._android_playback_confirmed = false
    -- Match Readest-style SMIL sync: highlight at the Media Overlay clock
    -- (clipBegin), not an artificial delay.  BT/e-ink micro-skew is handled
    -- by the Overlay sync offset setting / mini-player −/+ nudge (100 ms).
    -- The old 0.25 s default made sentence underlines visibly lag the narration.
    self.position_latency_s = 0

    logger.warn("MediaEngine: Android play", self.current_path,
        "offset=", offset, "duration=", self.current_duration)

    -- Apply saved media volume (♪ buttons) as MediaPlayer gain.
    pcall(function()
        player:setVolume(self._volume or 1.0)
    end)

    self:_startAndroidCompletionWatcher(gen)
    return true
end

function MediaEngine:_startAndroidCompletionWatcher(gen)
    local player = self._android_player
    if not player then return end
    local poll_count = 0
    -- Slow playback needs proportionally more 0.1 s polls to reach the end.
    local max_polls = math.max(600,
        math.floor((self.current_duration or 300) * 10
            / math.min(1.0, math.max(0.25, self._playback_speed or 1.0))))
    local function poll()
        if self.play_generation ~= gen then return end
        if not self.is_playing then return end
        if self.is_paused then
            UIManager:scheduleIn(0.25, poll)
            return
        end
        poll_count = poll_count + 1
        if poll_count == 15 and not self._android_playback_confirmed then
            if player._ever_confirmed_playing or player._audio_started then
                self._android_playback_confirmed = true
            else
                -- Only fail if MediaPlayer never produced a progressing position.
                local pos_ms = player:getPositionMs() or 0
                local start_ms = math.floor((self._seek_offset or 0) * 1000)
                if pos_ms <= start_ms + 100 then
                    logger.err("MediaEngine: Android playback failed to start")
                    self.is_playing = false
                    if self._on_fail then
                        local cb = self._on_fail
                        self._on_fail = nil
                        cb("android playback failed to start")
                    end
                    return
                end
                self._android_playback_confirmed = true
            end
        end
        if player:isPlaying() or player._ever_confirmed_playing then
            self._android_playback_confirmed = true
        end
        if player:isPlaybackDone() then
            self.is_playing = false
            self.is_paused = false
            if self._on_complete then
                local cb = self._on_complete
                self._on_complete = nil
                cb()
            end
            return
        end
        if poll_count >= max_polls then
            logger.warn("MediaEngine: Android playback timed out")
            pcall(function() player:stop() end)
            self.is_playing = false
            if self._on_fail then
                local cb = self._on_fail
                self._on_fail = nil
                cb("android playback timeout")
            end
            return
        end
        UIManager:scheduleIn(0.2, poll)
    end
    UIManager:scheduleIn(0.4, poll)
end

function MediaEngine:pause()
    if not self.is_playing or self.is_paused then return end
    self.is_paused = true
    self._pause_start_time = UIManager:getTime()
    if not self._android_player then return end
    -- Query/re-anchor via AndroidPlayer BEFORE trusting getPosition(): a leftover _paused_position from the previous
    -- pause would otherwise be returned as a stale SMIL mark.
    self._paused_position = nil
    local ap_pos = nil
    pcall(function() ap_pos = self._android_player:pause() end)
    local pos = 0
    if ap_pos and ap_pos > 0 then
        pos = ap_pos / 1000
    else
        pcall(function() pos = (self._android_player:getPositionMs() or 0) / 1000 end)
    end
    self._paused_position = math.max(0, pos)
    self._seek_offset = self._paused_position
    logger.warn("MediaEngine: Android pause at", self._paused_position)
end

function MediaEngine:resume()
    if not self.is_playing or not self.is_paused then return end
    local resume_pos = self._paused_position
    if resume_pos == nil then
        pcall(function() resume_pos = self:getPosition() or 0 end)
    end
    resume_pos = math.max(0, tonumber(resume_pos) or 0)
    self._seek_offset = resume_pos
    -- Keep the pause mark until after a successful resume so seek-restart and the SMIL highlight can still read it if
    -- MediaPlayer start fails.
    self._paused_position = resume_pos
    self.is_paused = false
    if self._pause_start_time then
        self._total_pause_ms = self._total_pause_ms + time.to_ms(UIManager:getTime() - self._pause_start_time)
        self._pause_start_time = nil
    end
    local player = self._android_player
    local resumed = false
    if player and player._mp_ref then
        -- Force AndroidPlayer's resume seek target from our SMIL mark.
        player._last_mp_pos_ms = math.floor(resume_pos * 1000)
        local ok, result = pcall(function() return player:resume() end)
        resumed = ok and result ~= false
    end
    if not resumed then
        -- MediaPlayer was released / the HAL dropped the session: restart at the saved pause position.
        logger.warn("MediaEngine: Android resume via seek-restart at", resume_pos)
        self:play(self._on_complete, self._on_fail)
        return
    end
    self._play_start_time = UIManager:getTime()
    self._total_pause_ms = 0
    logger.warn("MediaEngine: Android resume at", resume_pos)
end

function MediaEngine:stop()
    self:_nextGeneration()
    self.is_playing = false
    self.is_paused = false
    if self._android_player then pcall(function() self._android_player:stop() end) end
    self._on_complete = nil
    self._on_fail = nil
    self._play_start_time = nil
    self._pause_start_time = nil
    self._total_pause_ms = 0
    self._kill_keepalive_on_stop = nil
    -- _seek_offset is kept: seek-by-restart sets it, stops, then plays. load() resets it for a new file.
end

function MediaEngine:seek(seconds, mode)
    mode = mode or "absolute"
    local target = seconds
    if mode == "relative" then target = self:getPosition() + seconds end
    target = math.max(0, target)
    if self.current_duration and self.current_duration > 0 then
        target = math.min(target, self.current_duration)
    end
    self._seek_offset = target
    self._paused_position = target
    local player = self._android_player
    if self.is_paused then
        -- Stay paused; resume() plays from _paused_position / _last_mp_pos_ms.
        if player then
            pcall(function()
                player._last_mp_pos_ms = math.floor(target * 1000)
                player:seekToMs(math.floor(target * 1000))
            end)
        end
        return true
    end
    if not player then return false end
    if self._seek_to_broken then
        -- Live MediaPlayer.seekTo is a no-op on this device: play() seeks before start(), which works.
        return self:play(self._on_complete, self._on_fail)
    end
    local target_ms = math.floor(target * 1000)
    player:seekToMs(target_ms)
    self._play_start_time = UIManager:getTime()
    self._total_pause_ms = 0
    if not self._seek_probe_done then
        -- One-shot probe: on some HALs live seekTo is a no-op (the UI jumps, the audio keeps its timeline).
        self._seek_probe_done = true
        local gen = self.play_generation
        UIManager:scheduleIn(0.35, function()
            if self.play_generation ~= gen or not self.is_playing or self.is_paused or self._seek_to_broken then return end
            local pos_ms = tonumber(player:getPositionMs()) or 0
            if math.abs(pos_ms - target_ms) > 1000 then
                logger.warn("MediaEngine: Android live seek ignored, switching to seek-by-restart")
                self._seek_to_broken = true
                self:play(self._on_complete, self._on_fail)
            end
        end)
    end
    return true
end

function MediaEngine:getPosition()
    if not self.is_playing then
        -- Hold the paused/seek target so the UI does not flicker back to zero.
        return math.max(0, tonumber(self._paused_position) or tonumber(self._seek_offset) or 0)
    end
    if self.is_paused and self._paused_position ~= nil then return self._paused_position end
    if self._android_player then
        local pos_ms = self._android_player:getPositionMs()
        if pos_ms then
            local pos = pos_ms / 1000
            if not self.is_paused then self._seek_offset = pos end
            return pos
        end
    end
    -- MediaPlayer gave no position: estimate from the wall clock and the speed.
    if self._play_start_time then
        local ok, elapsed_ms = pcall(function()
            if self.is_paused and self._pause_start_time then
                return time.to_ms(self._pause_start_time - self._play_start_time) - self._total_pause_ms
            end
            return time.to_ms(UIManager:getTime() - self._play_start_time) - self._total_pause_ms
        end)
        if ok and elapsed_ms then
            local pos = math.max(0, elapsed_ms / 1000) * (self._playback_speed or 1.0) + (self._seek_offset or 0)
            return math.min(pos, self.current_duration or pos)
        end
    end
    return 0
end

function MediaEngine:setSpeed(speed)
    speed = math.max(0.5, math.min(3.0, tonumber(speed) or 1.0))
    local old_speed = self._playback_speed or 1.0
    self._playback_speed = speed
    -- Persisted so it applies to the next book; no-op calls never hit disk.
    if self.plugin and self.plugin.setSetting and math.abs(speed - old_speed) >= 0.01 then
        self.plugin:setSetting("playback_speed", speed)
    end
    -- MediaPlayer applies the rate live (and again after prepare() on the next play()).
    if self._android_player then pcall(function() self._android_player:setSpeed(speed) end) end
end

function MediaEngine:setVolume(pct)
    pct = math.max(0, math.min(100, tonumber(pct) or 100))
    local v = pct / 100
    if math.abs(v - (self._volume or 1.0)) < 0.001 then return end
    self._volume = v
    -- A live per-stream gain on top of the system volume.
    if self._android_player then pcall(function() self._android_player:setVolume(v) end) end
end

function MediaEngine:getDuration()
    return self.current_duration or 0
end

function MediaEngine:isPlaying()
    return self.is_playing
end

function MediaEngine:isPaused()
    return self.is_paused
end

-- ---------------------------------------------------------------------------
-- Playback speed
-- ---------------------------------------------------------------------------

function MediaEngine:getSpeed()
    return self._playback_speed or 1.0
end

-- ---------------------------------------------------------------------------
-- Playback volume (digital gain)
-- ---------------------------------------------------------------------------

function MediaEngine:getVolume()
    return math.floor((self._volume or 1.0) * 100 + 0.5)
end

-- ---------------------------------------------------------------------------
-- Chapter support (via m4bparser integration)
-- ---------------------------------------------------------------------------

function MediaEngine:setChapters(chapters)
    -- chapters: array of {title, start_time, end_time}
    self._chapters = chapters
end

function MediaEngine:getChapters()
    return self._chapters or {}
end

function MediaEngine:seekToChapter(index)
    local chapters = self._chapters
    if not chapters or not chapters[index] then return false end
    return self:seek(chapters[index].start_time, "absolute")
end

return MediaEngine
