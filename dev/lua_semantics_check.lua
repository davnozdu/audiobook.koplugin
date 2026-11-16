#!/usr/bin/env luajit
-- lua_semantics_check.lua -- load the plugin's core modules in a stubbed
-- KOReader environment and assert the public surface actually exists.
--
-- Exists because a mangled block comment (a `--[[--` opener left unterminated
-- by an edit) silently swallowed two TTSEngine method definitions while
-- loadfile still passed: the file parsed, the methods were nil, and play()
-- crashed on device ("attempt to call a nil value"). Syntax checks cannot
-- catch that; this can.
--
-- Usage: luajit dev/lua_semantics_check.lua   (from the repo root)

package.path = arg[0]:match("^(.*)dev/") and
    arg[0]:match("^(.*)dev/") .. "?.lua;" .. package.path or "./?.lua;" .. package.path

local function stub(name, mod) package.preload[name] = function() return mod end end

local logger = { warn = function() end, info = function() end,
                 dbg = function() end, err = function() end }
stub("device", {})
stub("ui/widget/infomessage", {})
stub("ui/uimanager", { scheduleIn = function() end, getTime = function() return 0 end })
stub("logger", logger)
stub("ui/time", { to_ms = function() return 0 end, to_s = function() return 0 end })
stub("ui/event", {})
stub("audiobook_gettext", function(s) return s end)
stub("ffi/util", { template = function(s) return s end })

local fails = 0
local function need(mod, field, kind)
    local ok, m = pcall(dofile, mod)
    if not ok then
        print("FAIL  " .. mod .. " failed to load: " .. tostring(m):sub(1, 90))
        fails = fails + 1
        return
    end
    if type(m[field]) ~= kind then
        print("FAIL  " .. mod .. ": " .. tostring(field) .. " is " ..
              type(m[field]) .. ", expected " .. kind)
        fails = fails + 1
    else
        print("ok    " .. mod .. ": " .. tostring(field))
    end
end

for _, f in ipairs({ "queueSpeakAndroid", "queueEventsAndroid", "queueStopAndroid", "reconnectAndroidTts",
        "_ensureAndroidTts", "pause", "stop", "shutdown", "listAndroidVoices", "androidEngineDisplayName" }) do
    need("ttsengine.lua", f, "function")
end
for _, f in ipairs({ "start", "pause", "resume", "stop", "nextSentence", "prevSentence", "rewind", "setSpeechRate",
        "jumpTocRelative", "showTocPicker", "seekToProgress", "refocusToReading", "showPlaybackBar", "hidePlaybackBar",
        "_applyBarVisibility", "restartFromStopped", "charsPerSecond", "isPlaying", "isPaused", "_remapAfterRotation" }) do
    need("synccontroller.lua", f, "function")
end
for _, f in ipairs({ "buildVoiceSettingsMenu", "buildHighlightStyleMenu", "showPagedPicker", "showTtsSettingsPicker" }) do
    need("menubuilder.lua", f, "function")
end
need("docstream.lua", "new", "function")

if fails > 0 then
    print("SEMANTIC CHECK FAILED: " .. fails .. " missing")
    os.exit(1)
end
print("SEMANTIC CHECK PASS")
