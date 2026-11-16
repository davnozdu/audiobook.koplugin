--[[--
Headset media buttons on Android: an Android MediaSession (androidmediasession.lua) receives play/pause/next/previous
from a Bluetooth or wired headset and the playback state is published to it.

@module btmediacontrol
--]]

local logger = require("logger")

local BtMediaControl = {}

BtMediaControl._plugin = nil
BtMediaControl._last_sent_status = nil

--- Start listening for headset media buttons.
function BtMediaControl.start(plugin)
    BtMediaControl._plugin = plugin
    return BtMediaControl._startAndroidMediaSession(plugin)
end

--- Android MediaSession path (AirPods stem / BT headset buttons on Boox).
function BtMediaControl._startAndroidMediaSession(plugin)
    if BtMediaControl._android_session then
        local session = BtMediaControl._android_session
        session:startPolling(plugin)
        -- stopSession() keeps the Lua wrapper but releases the Java session.
        -- Re-activate so headset events reach us after a previous stop.
        if not BtMediaControl._android_session_started then
            pcall(function() session:startSession("Audiobook", "") end)
            BtMediaControl._android_session_started = true
        end
        return true
    end
    local plugin_dir = (plugin and plugin.path) or "."
    local ok, AndroidMediaSession = pcall(dofile,
        plugin_dir:gsub("/+$", "") .. "/androidmediasession.lua")
    if not ok or not AndroidMediaSession then
        -- Fallback: same folder as this module.
        local here = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
        ok, AndroidMediaSession = pcall(dofile, here .. "androidmediasession.lua")
    end
    if not ok or not AndroidMediaSession then
        logger.warn("BtMediaControl: AndroidMediaSession load failed:", AndroidMediaSession)
        return false
    end
    local session = AndroidMediaSession:new()
    if not session:init(plugin_dir) then
        logger.warn("BtMediaControl: Android MediaSession helper unavailable")
        return false
    end
    BtMediaControl._android_session = session
    session:startSession("Audiobook", "")
    -- startSession создаёт Java-сессию; без флага следующий статус создавал её заново,
    -- снова помечая сессию PLAYING.
    BtMediaControl._android_session_started = true
    BtMediaControl._last_sent_status = nil
    session:startPolling(plugin)
    logger.warn("BtMediaControl: Android MediaSession AVRCP active")
    return true
end

function BtMediaControl.getAndroidSession()
    return BtMediaControl._android_session
end

--- Stop listening for headset media buttons.
function BtMediaControl.stop()
    if BtMediaControl._android_session then
        pcall(function()
            BtMediaControl._android_session:stopPolling()
            BtMediaControl._android_session:stopSession()
        end)
    end
    BtMediaControl._plugin = nil
end

--- Publish "playing" / "paused" / "stopped" to the media session (Android maps the headset's play/pause key from it).
function BtMediaControl.sendPlaybackStatus(status)
    if BtMediaControl._last_sent_status == status then return end
    BtMediaControl._last_sent_status = status

    do
        local session = BtMediaControl._android_session
        if session then
            local playing = (status == "playing")
            local pos_ms = 0
            local plugin = BtMediaControl._plugin
            if plugin and plugin.media_sync and plugin.media_sync.media_engine then
                pcall(function()
                    pos_ms = math.floor((plugin.media_sync.media_engine:getPosition() or 0) * 1000)
                end)
            end
            if status == "stopped" then
                pcall(function() session:stopSession() end)
                BtMediaControl._android_session_started = false
            else
                -- startSession once; repeated start() re-requested audio focus
                -- and contributed to AirPods resume dying after ~0.5s.
                if not BtMediaControl._android_session_started then
                    pcall(function() session:startSession("Audiobook", "") end)
                    BtMediaControl._android_session_started = true
                end
                pcall(function() session:setPlaying(playing, pos_ms) end)
            end
        end
    end
end

function BtMediaControl.sendTrackMetadata() end
function BtMediaControl.rescan() end

return BtMediaControl
