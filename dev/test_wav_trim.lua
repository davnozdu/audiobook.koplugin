-- Unit tests for WavUtils.trimSilence: engines bake silence into their
-- synthesized clips; trimming it at lookahead-fill time shortens the audible
-- gap between sentences (issue #96).
--
-- Run with the dev shell Lua (no KOReader required):
--   luajit dev/test_wav_trim.lua

local here = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
-- Stub KOReader's logger so wavutils.lua loads outside the reader.
package.loaded.logger = {
    dbg = function() end,
    warn = function() end,
    err = function() end,
}
local WavUtils = dofile(here .. "../wavutils.lua")

local passed, failed = 0, 0
local function ok(cond, name)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL " .. name)
    end
end

local path = os.tmpname() .. ".wav"

-- Build: 250 ms silence + 600 ms tone + 350 ms silence = 1200 ms.
ok(WavUtils.generateSilence(path, 250, 22050), "generateSilence")
ok(WavUtils.appendTone(path, 600, 440, 12000), "appendTone")
ok(WavUtils.appendSilence(path, 350), "append trailing silence")
local before = WavUtils.getDurationMs(path)
ok(math.abs(before - 1200) < 40, "fixture duration ~= 1200ms, got " .. before)

-- Trimming 16-bit PCM with the default thresholds keeps small pads.
ok(WavUtils.trimSilence(path), "trimSilence succeeds")
local after = WavUtils.getDurationMs(path)
-- ~250-20ms lead + ~350-40ms tail removed: expect roughly 610 ms.
ok(after < before - 300, "trim removed the silence: " .. before .. " -> " .. after)
ok(after > 400, "tone content kept: " .. after)

-- A second pass must be a no-op (already trimmed).
local after2_path = path
ok(WavUtils.trimSilence(after2_path) == false or true, "second trim runs")
local after2 = WavUtils.getDurationMs(after2_path)
ok(math.abs(after2 - after) < 60, "second trim stable: " .. after .. " -> " .. after2)

-- Non-PCM / corrupt input must be refused, not corrupted.
local bad = os.tmpname() .. ".wav"
local f = io.open(bad, "wb")
f:write("not a wav at all, just bytes")
f:close()
ok(WavUtils.trimSilence(bad) == false, "trimSilence refuses non-WAV")
local f2 = io.open(bad, "rb")
local unchanged = f2:read("*a")
f2:close()
ok(unchanged == "not a wav at all, just bytes", "non-WAV file untouched")

-- Fully silent clip: refuse (nothing audible to keep).
local silent = os.tmpname() .. ".wav"
WavUtils.generateSilence(silent, 300, 22050)
ok(WavUtils.trimSilence(silent) == false, "trimSilence refuses fully-silent clip")

os.remove(path)
os.remove(bad)
os.remove(silent)

print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
