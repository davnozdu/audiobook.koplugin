--[[--
Wake channel: KOReader sleeps until something actually happens, instead of polling Java every second.

The Java helpers (media buttons, calls, unplugged headphones, TTS engine start/done/error) write one byte into a pipe;
its read end is registered with KOReader's own ALooper (the one input_android.lua waits on), so the main loop wakes up
at once. input.waitForEvent is wrapped: after it returns, a readable pipe is drained and the handlers run on the next
UI tick (the wrapper returns an empty event batch so Input:waitEvent goes back to UIManager immediately).

Anything failing here leaves `Wake.ok == false`; callers then keep their old polling.
]]

local ffi = require("ffi")
local bit = require("bit")
local logger = require("logger")

local Wake = { ok = false, tried = false, handlers = {} }

-- Ident of our fd in the ALooper: any value input_android.lua does not use (1 main, 2 input, 3 user).
local IDENT = 77
local F_GETFL, F_SETFL, O_NONBLOCK = 3, 4, 0x800  -- Linux/Android (arm, arm64, x86)
local ALOOPER_EVENT_INPUT = 1

local function cdef(s) pcall(ffi.cdef, s) end
cdef("int pipe(int fds[2]);")
cdef("int fcntl(int fd, int cmd, ...);")
cdef("long read(int fd, void *buf, unsigned long n);")
cdef("int close(int fd);")
cdef("typedef struct ALooper ALooper;")
cdef("int ALooper_addFd(ALooper *looper, int fd, int ident, int events, void *callback, void *data);")
cdef("int ALooper_removeFd(ALooper *looper, int fd);")

local buf = ffi.new("unsigned char[64]")

--- True when bytes were waiting (each is one event from Java); the pipe is emptied.
function Wake.drain()
    if not Wake.rfd then return false end
    local got = false
    while true do
        local n = tonumber(ffi.C.read(Wake.rfd, buf, 64))
        if not n or n <= 0 then break end
        got = true
        if n < 64 then break end
    end
    return got
end

function Wake.on(name, fn) Wake.handlers[name] = fn end
function Wake.off(name) Wake.handlers[name] = nil end

function Wake.dispatch()
    local UIManager = require("ui/uimanager")
    for _, fn in pairs(Wake.handlers) do
        UIManager:nextTick(function() pcall(fn) end)
    end
end

--- Sets the channel up once per KOReader process. Returns true when events will wake KOReader.
function Wake.init()
    if Wake.tried then return Wake.ok end
    Wake.tried = true
    local ok, err = pcall(function()
        local android = require("android")
        local Device = require("device")
        local inp = Device.input and Device.input.input
        assert(inp and inp.waitForEvent, "no input backend")
        local fds = ffi.new("int[2]")
        assert(ffi.C.pipe(fds) == 0, "pipe")
        for i = 0, 1 do
            local fl = ffi.C.fcntl(fds[i], F_GETFL)
            ffi.C.fcntl(fds[i], F_SETFL, ffi.cast("int", bit.bor(fl, O_NONBLOCK)))
        end
        local looper = ffi.cast("ALooper *", android.app.looper)
        local r = android.lib.ALooper_addFd(looper, fds[0], IDENT, ALOOPER_EVENT_INPUT, nil, nil)
        if r ~= 1 then ffi.C.close(fds[0]); ffi.C.close(fds[1]); error("ALooper_addFd " .. tostring(r)) end
        Wake.rfd, Wake.wfd = fds[0], fds[1]
        if not inp._audiobook_wake then
            local orig = inp.waitForEvent
            inp.waitForEvent = function(sec, usec)
                local a, b, c = orig(sec, usec)
                if Wake.drain() then
                    Wake.dispatch()
                    -- Our fd woke the loop (EINTR) or a timeout raced it: back to UIManager now so the handlers run.
                    if a ~= true then return true, {} end
                end
                return a, b, c
            end
            inp._audiobook_wake = true
        end
    end)
    Wake.ok = ok and true or false
    if not ok then logger.warn("Audiobook wake channel unavailable, polling instead:", err) end
    return Wake.ok
end

--- The write end for the Java helpers, or -1.
function Wake.fd()
    if Wake.ok and Wake.wfd then return Wake.wfd end
    return -1
end

return Wake
