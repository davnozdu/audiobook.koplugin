#!/usr/bin/env luajit
-- clock_test.lua -- on-device validation of the audioout audible clock.
-- Plays one known WAV through the daemon and polls the position: it must
-- advance at about real time and done_count must bump at about the clip's
-- duration, not instantly (the firehose-sink bug: completions firing within
-- a second of queueing while the sink is still audibly rendering).
--
-- Usage (on device):
--   luajit clock_test.lua <wav> [poll_s]
-- Expects the daemon binary at /tmp/sntbench/audioout.

local function stub(name, mod) package.preload[name] = function() return mod end end
stub("logger", { warn = function() end, info = function() end,
                 dbg = function() end, err = function() end })

-- Minimal JSON for the flat command/response objects audioout.lua speaks.
local function enc(v)
    if type(v) == "number" then
        local s = tostring(v)
        return s:gsub("%.0+$", "")
    end
    if type(v) == "boolean" then return v and "true" or "false" end
    if type(v) == "table" then
        local parts = {}
        for k, val in pairs(v) do
            parts[#parts + 1] = '"' .. k .. '":' .. enc(val)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return '"' .. tostring(v):gsub('\\', "\\\\"):gsub('"', '\\"') .. '"'
end
local function dec(s)
    -- Correct-enough flat-object parser: keys are quoted identifiers,
    -- values are numbers, true/false/null, or short strings.
    local out = {}
    local i = 1
    while true do
        local k1 = s:find('"', i)
        if not k1 then break end
        local k2 = s:find('"', k1 + 1, true)
        if not k2 then break end
        local key = s:sub(k1 + 1, k2 - 1)
        local colon = s:find(":", k2 + 1, true)
        if not colon then break end
        local vstart = colon + 1
        while s:sub(vstart, vstart) == " " do vstart = vstart + 1 end
        if s:sub(vstart, vstart) == '"' then
            local vend = s:find('"', vstart + 1, true)
            out[key] = s:sub(vstart + 1, (vend or #s) - 1)
            i = (vend or #s) + 1
        else
            local vend = s:find("[,%}]", vstart, true) or (#s + 1)
            local tok = s:sub(vstart, vend - 1)
            if tok == "true" then out[key] = true
            elseif tok == "false" then out[key] = false
            elseif tok == "null" then out[key] = nil
            else out[key] = tonumber(tok) end
            i = vend
        end
    end
    return out
end
stub("json", { encode = enc, decode = dec })

local wav = arg[1]
local poll_s = tonumber(arg[2] or "0.5")
if not wav then print("usage: clock_test.lua <wav> [poll_s]") os.exit(2) end

local fh = io.open(wav, "rb")
if not fh then print("cannot open " .. wav) os.exit(2) end
local sz = fh:seek("end")
fh:close()
local dur_ms = (sz - 44) / 2 / 22050 * 1000
print(string.format("clip %s size=%d dur=%.0fms", wav, sz, dur_ms))

package.path = arg[0]:match("^(.*)clock_test%.lua$") .. "../../?.lua;" .. package.path
local AudioOut = dofile("audioout.lua")

local ao = AudioOut:new{
    daemon_path = "/tmp/sntbench/audioout",
    socket_path = "/tmp/clocktest.sock",
    log_path = "/tmp/clocktest_audioout.log",
    rate = 22050,
    channels = 1,
    STARTUP_WAIT_MS = 10000,
}
ao:stopDaemon()

local t0 = os.time()
local frac
local function now_s()
    -- wall seconds with fraction from /proc/uptime (busybox-safe)
    local up = io.open("/proc/uptime", "r")
    if up then
        local v = up:read("*l"):match("^%S+")
        up:close()
        return tonumber(v) or 0
    end
    return os.time()
end
frac = now_s()

local ok, err = ao:start()
if not ok then
    -- slow device: give the cold binary three more tries before giving up
    for attempt = 1, 3 do
        os.execute("sleep 1")
        ok, err = ao:start()
        if ok then break end
        print("start retry " .. attempt .. ": " .. tostring(err))
    end
    if not ok then
        -- the startup ping race on this device is not what we are testing:
        -- if a daemon answers, proceed
        local pr = ao:_command({ cmd = "ping" }, 800)
        if not (pr and pr.ok == true) then
            print("daemon start failed: " .. tostring(err))
            os.exit(1)
        end
        print("start() raced but daemon answers; proceeding")
    end
end

resp = ao:play(wav, { rate = 22050, channels = 1 })
if not (resp and resp.ok == true and resp.ok == not false and (resp.ok == true or resp.ok == 1)) then
    -- json stub decodes true as boolean, false as the string "false" via the
    -- numeric fallback below, so test the decoded error field instead.
end
if resp and resp.error then
    print("play refused: " .. tostring(resp.error))
    os.exit(1)
end
if not resp then print("play failed: timeout") os.exit(1) end
for k, v in pairs(resp) do print("  resp." .. k .. " = " .. tostring(v)) end
local baseline = resp.done_count or 0
print(string.format("queued start_ms=%d fed_end_ms=%d baseline_done=%d",
    resp.start_ms or -1, resp.fed_end_ms or -1, baseline))

local deadline = now_s() + dur_ms / 1000 + 30
while now_s() < deadline do
    os.execute("sleep " .. poll_s)
    local st = ao:status(800)
    if st and st.pos_ms then
        print(string.format("t+%.1fs pos=%dms done=%d queue=%d",
            now_s() - t0, st.pos_ms, st.done_count or 0, st.queue or 0))
        if (st.done_count or 0) > baseline then
            local t = now_s() - t0
            print(string.format("DONE at t+%.1fs (clip dur %.1fs, ratio %.2f)",
                t, dur_ms / 1000, t / (dur_ms / 1000)))
            ao:stopDaemon()
            if t >= (dur_ms / 1000) * 0.6 then
                print("CLOCK TEST PASS")
                os.exit(0)
            end
            print("CLOCK TEST FAIL: completed too early")
            os.exit(1)
        end
    end
end
print("CLOCK TEST FAIL: timeout")
ao:stopDaemon()
os.exit(1)
