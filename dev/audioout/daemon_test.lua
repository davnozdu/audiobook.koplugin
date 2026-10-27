#!/usr/bin/env luajit
-- Protocol test for the audioout daemon. Runs wherever luajit runs (host
-- for --sink fakesink, device for the MTK sink).
--
--   luajit dev/audioout/daemon_test.lua <socket> <wav> [expected_ms]
--
-- Assumes the daemon is already running on <socket> (start it from the
-- shell so logs stay visible). Exits 0 on PASS, 1 on FAIL.

local function fail(msg)
    print("FAIL - " .. msg)
    os.exit(1)
end

local socket_path = arg[1] or fail("usage: daemon_test.lua <socket> <wav> [expected_ms]")
local wav = arg[2] or fail("usage: daemon_test.lua <socket> <wav> [expected_ms]")
local expected_ms = tonumber(arg[3] or "") or 30000

-- Stub the KOReader modules audioout.lua touches.
package.preload.logger = function()
    return { warn = function() end, dbg = function() end, err = function() end }
end
-- Minimal flat-table JSON good enough for the daemon protocol.
package.preload.json = function()
    return (function()
    local function encode(v)
        if type(v) == "number" then
            local n = math.floor(v)
            return n == v and tostring(n) or string.format("%.3f", v)
        end
        if type(v) == "boolean" then return v and "true" or "false" end
        if type(v) == "string" then return string.format('"%s"', v) end
        local parts = {}
        for k, val in pairs(v) do
            parts[#parts + 1] = string.format('"%s":%s', k, encode(val))
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    local function decode(s)
        local t = {}
        for k, v in s:gmatch('"([^"]+)":%s*("?[^,}"]*"?)') do
            v = v:gsub('^"', ""):gsub('"$', "")
            if v == "true" then t[k] = true
            elseif v == "false" then t[k] = false
            elseif tonumber(v) then t[k] = tonumber(v)
            else t[k] = v end
        end
        return t
    end
    return { encode = encode, decode = decode }
end)()
end

local here = (arg[0]:match("^(.*)/") or ".")
local function first_existing(p)
    local f = io.open(p, "r")
    if f then f:close() return p end
    return nil
end
local mod = first_existing(here .. "/audioout.lua")
        or first_existing(here .. "/../../audioout.lua")
        or fail("audioout.lua not found next to or above the test")
local AudioOut = dofile(mod)
local ao = AudioOut:new{ socket_path = socket_path }

local checks = 0
local function ok(cond, name)
    checks = checks + 1
    if not cond then fail(name) end
    print("ok - " .. name)
end

-- 1. liveness
local resp = ao:_command({ cmd = "ping" }, 1000)
ok(resp and resp.ok, "ping answers")

-- 2. clean slate
ao:flush()
resp = ao:status()
ok(resp and resp.ok and resp.queue == 0, "status after flush, queue empty")
local t0_fed = resp.fed_ms

-- 3. queue the tone
resp = ao:play(wav, { rate = 22050, channels = 1 })
ok(resp and resp.ok, "play accepted")
ok(resp.done_count ~= nil, "play response carries done_count (completion baseline)")
ok(math.abs(resp.fed_end_ms - t0_fed - expected_ms) < 1500,
   string.format("fed_end_ms ~= +%d (%+d)", expected_ms,
                 resp.fed_end_ms - t0_fed - expected_ms))
local fed_end = resp.fed_end_ms

-- 4. position advances
local last_pos = -1
local advanced = false
for _ = 1, 12 do
    os.execute("sleep 0.25")
    resp = ao:status()
    if resp.pos_ms > last_pos + 100 then advanced = true end
    last_pos = resp.pos_ms
end
ok(advanced, string.format("pos advances (at %d ms)", last_pos))

-- 5. pause freezes-ish (buffered tail still plays out: allow +2500)
resp = ao:pause()
ok(resp and resp.ok, "pause accepted")
os.execute("sleep 0.5")
local p1 = ao:status()
os.execute("sleep 1.0")
local p2 = ao:status()
ok(p2.pos_ms >= p1.pos_ms, "pos does not go backwards on pause")
resp = ao:resume()
ok(resp and resp.ok, "resume accepted")

-- 6. completion
local done0 = (ao:status() or {}).done_count or 0
local deadline = expected_ms / 1000 + 15
local t = 0
local finished = false
while t < deadline do
    os.execute("sleep 0.5")
    t = t + 0.5
    resp = ao:status()
    if (resp.done_count or 0) > done0 or resp.state == "idle" then
        finished = true
        break
    end
end
ok(finished, string.format("clip completes (pos=%d, state=%s, t=%.1fs)",
                           resp.pos_ms or -1, tostring(resp.state), t))
ok(math.abs((resp.pos_ms or 0) - fed_end) < 2500,
   string.format("final pos ~= fed_end (delta %d ms)",
                 (resp.pos_ms or 0) - fed_end))

-- 7. stop / flush round trip
resp = ao:play(wav, { rate = 22050, channels = 1 })
ok(resp and resp.ok, "re-queue ok")
resp = ao:stop()
ok(resp and resp.ok and resp.state == "idle", "stop drains queue")
resp = ao:flush()
ok(resp and resp.ok, "flush rebuild ok")
resp = ao:status()
ok(resp.fed_end_ms == 0, "fed_end reset by flush")

-- 8. external epoch: the clock starts at the announced position, advances,
--    caps at the announced total and latches completion exactly at it.
--    (Checks the daemon's clock model; the real client feeds offset audio
--    via `ffmpeg -ss`, here a plain raw writer from byte 0 is enough.)
local raw = "/tmp/audioout-spike/tone10.raw"
do
    local f = io.open(raw, "wb")
    if f then
        -- 10 s of 22050 Hz mono s16 sine, written from Lua (no deps)
        local buf = {}
        for i = 0, 22050 * 10 - 1 do
            local v = math.floor(0.6 * 32767 * math.sin(2 * math.pi * 440 * i / 22050))
            buf[#buf + 1] = string.char(v % 256, math.floor(v / 256) % 256)
        end
        f:write(table.concat(buf))
        f:close()
    end
end
local function feed_raw()
    local p = io.popen(string.format("cat '%s' > '%s' & echo $!", raw, "/tmp/test_audioout_fifo"))
    local pid = p and tonumber(p:read("*l") or "")
    if p then p:close() end
    return pid
end
resp = ao:externalStart(22050, 1, nil, 5000, 10000)
ok(resp and resp.ok, "external start accepted")
resp = ao:status()
ok(resp and resp.external == 1 and resp.external_done == 0
   and math.abs(resp.pos_ms - 5000) < 400,
   string.format("external epoch anchors at pos_ms (pos=%s)", tostring(resp and resp.pos_ms)))
local feeder_pid = feed_raw()
local advanced2, latched, capped = false, false, true
for _ = 1, 40 do
    os.execute("sleep 0.25")
    resp = ao:status()
    if resp.pos_ms > 5400 then advanced2 = true end
    if resp.external_done == 1 then latched = true end
    if resp.pos_ms > 10000 then capped = false end
    if latched then break end
end
ok(advanced2, "external pos advances past the epoch offset")
ok(latched and capped,
   string.format("external_done latches at total (pos=%s)", tostring(resp and resp.pos_ms)))

-- 9. seek re-epochs: position jumps to the target, the latch clears, and a
--    fresh stream latches again.
if feeder_pid then
    os.execute(string.format("kill %d 2>/dev/null", feeder_pid))
end
resp = ao:seek(2000, 10000)
ok(resp and resp.ok and math.abs((resp.pos_ms or 0) - 2000) < 400,
   string.format("seek re-epochs at pos_ms (pos=%s)", tostring(resp and resp.pos_ms)))
resp = ao:status()
ok(resp.external_done == 0, "seek clears the completion latch")
feeder_pid = feed_raw()
latched = false
for _ = 1, 60 do
    os.execute("sleep 0.25")
    resp = ao:status()
    if resp.external_done == 1 then latched = true; break end
end
ok(latched, string.format("external_done latches again after seek (pos=%s)",
                          tostring(resp and resp.pos_ms)))
if feeder_pid then
    os.execute(string.format("kill %d 2>/dev/null", feeder_pid))
end
ao:release()

-- 10. volume round-trip (live reporting; the alsa live:true path needs a
--     device run, the host fakesink exercises the gst volume element)
resp = ao:setVolume(0.5)
ok(resp and resp.ok and resp.volume == 0.5, "volume command round-trips")
ao:setVolume(1.0)

-- 11. long-session timeline: after idling past the first clip's end on
--     keepalive silence, a second clip must still take ~its full
--     duration. The audible-vs-intake timeline divergence made every
--     clip after ~30 s of session complete instantly, racing the
--     read-along through sentences and pages.
resp = ao:play(wav, { rate = 22050, channels = 1 })
ok(resp and resp.ok, "long-session: first clip queued")
do
    local t = 0
    while t < expected_ms / 1000 + 6 do
        os.execute("sleep 1"); t = t + 1
        local st = ao:status()
        if (st.done_count or 0) > 0 then break end
    end
    os.execute("sleep 5")   -- idle on keepalive past the clip end
    resp = ao:play(wav, { rate = 22050, channels = 1 })
    ok(resp and resp.ok, "long-session: second clip queued")
    local done0 = (ao:status() or {}).done_count or 0
    local instant = false
    t = 0
    while t < expected_ms / 2000 do   -- half the duration
        os.execute("sleep 1"); t = t + 1
        local st = ao:status()
        if (st.done_count or 0) > done0 then instant = true; break end
    end
    ok(not instant, "long-session: second clip did not complete instantly")
    ao:stop()
    ao:flush()
end

-- 12. pause continuity: the position must hold while paused (a collapse to
--     zero sent the client's word tick negative on every auto-pause) and
--     continue from the same spot on resume.
resp = ao:play(wav, { rate = 22050, channels = 1 })
ok(resp and resp.ok, "pause-continuity: clip queued")
os.execute("sleep 2")
local pre = ao:status()
os.execute("sleep 0.3")
ao:pause()
os.execute("sleep 0.4")
local p1 = ao:status()
os.execute("sleep 1")
local p2 = ao:status()
ok(p1.pos_ms > 500 and math.abs(p2.pos_ms - p1.pos_ms) < 250,
   string.format("pause holds the position (%d -> %d)",
                 p1.pos_ms or -1, p2.pos_ms or -1))
ao:resume()
os.execute("sleep 0.3")
local p3 = ao:status()
ok(p3.pos_ms >= p2.pos_ms - 250 and p3.pos_ms <= pre.pos_ms + 4000,
   string.format("resume continues from the pause (%d)", p3.pos_ms or -1))
ao:stop()
ao:flush()

print(string.format("PASS - %d checks", checks))
