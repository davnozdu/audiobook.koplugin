-- Read-aloud controller with a mock Android engine and a mock document: a whole book through the engine queue.
-- Without user jumps every word is heard exactly once, in order; the screen follows the voice; jumps, pauses,
-- an engine that is lost or stalls all go on from a sentence start.
local now = 0
local tasks = {}
package.preload['ui/event'] = function() return { new = function(_, name, a, b) return { name = name, args = { a, b } } end } end
package.preload['ui/uimanager'] = function() return {
    getTime = function() return now end,
    scheduleIn = function(_, s, f) tasks[#tasks + 1] = { t = now + s, f = f } end,
    unschedule = function() end, setDirty = function() end, show = function() end, close = function() end,
} end
package.preload['ui/time'] = function() return { to_s = function(t) return t end, to_ms = function(t) return t * 1000 end } end
package.preload['ui/widget/infomessage'] = function() return { new = function(_, o) return o end } end
package.preload['logger'] = function() return setmetatable({}, { __index = function() return function() end end }) end
package.preload['audiobook_gettext'] = function() return function(s) return s end end
package.preload['ffi/util'] = function() return { template = function(s) return s end } end
package.preload['device'] = function() return { screen = { getWidth = function() return 600 end, getHeight = function() return 800 end } } end

local SC = dofile('synccontroller.lua')
local DS = dofile('docstream.lua')
local Parser = dofile('textparser.lua')
local passed = 0
local function check(ok, name) if not ok then error('FAIL: ' .. name, 2) end; passed = passed + 1 end

local function docFor(text, perpage)
    local starts, ends = {}, {}
    for a, _, b in text:gmatch('()(%S+)()') do starts[#starts+1] = a; ends[#ends+1] = b end
    local d = { page = 1, starts = starts }
    local idx = {} for i, a in ipairs(starts) do idx[a] = i end
    function d:compareXPointers(a, b) a, b = tonumber(a), tonumber(b); return b == a and 0 or (b > a and 1 or -1) end
    function d:getNextVisibleWordStart(x) for _, a in ipairs(starts) do if a > tonumber(x) then return tostring(a) end end end
    function d:getPrevVisibleWordStart(x) for i = #starts, 1, -1 do if starts[i] < tonumber(x) then return tostring(starts[i]) end end end
    function d:getNextVisibleWordEnd(x) for i, a in ipairs(starts) do if a >= tonumber(x) then return tostring(ends[i]) end end end
    function d:getTextFromXPointers(a, b) return text:sub(tonumber(a), tonumber(b) - 1) end
    function d:getPageXPointer(p) local w = starts[(p - 1) * perpage + 1]; return w and tostring(w) end
    function d:getXPointer() return self:getPageXPointer(self.page) end
    function d:getCurrentPage() return self.page end
    function d:getPageCount() return math.ceil(#starts / perpage) end
    function d:getVisiblePageCount() return 1 end
    function d:getPageFromXPointer(x)
        x = tonumber(x)
        local w = 1
        for i, a in ipairs(starts) do if a <= x then w = i else break end end
        return math.floor((w - 1) / perpage) + 1
    end
    function d:getToc() return { { page = 1, title = 'A' }, { page = 5, title = 'B' } } end
    return d
end

-- The engine: a queue; each step starts the head (S, some R) or finishes it (D).
local function engine()
    local e = { rate = 1, q = {}, ev = {}, heard = {}, flushes = 0, lost = false }
    function e:queueSpeakAndroid(id, text, flush)
        if flush then self.q = {}; self.flushes = self.flushes + 1 end
        self.q[#self.q + 1] = { id = id, text = text }
        self._queue_active = true
        return true
    end
    function e:queueStopAndroid() self.q = {}; self.playing = nil; self._queue_active = false end
    function e:queueEventsAndroid()
        local ev, lost = self.ev, self.lost
        self.ev = {}
        self.lost = false
        return ev, lost
    end
    function e:reconnectAndroidTts() return true end
    function e:pause() self:queueStopAndroid() end
    function e:stop() self:queueStopAndroid() end
    function e:step()
        if self.playing then
            local it = self.playing
            self.playing = nil
            table.remove(self.q, 1)
            self.ev[#self.ev + 1] = { kind = 'D', id = it.id }
        elseif self.q[1] then
            self.playing = self.q[1]
            self.heard[#self.heard + 1] = self.q[1].text
            self.ev[#self.ev + 1] = { kind = 'S', id = self.q[1].id }
            self.ev[#self.ev + 1] = { kind = 'R', id = self.q[1].id, extra = tostring(math.floor(#self.q[1].text / 2)) .. '\t0' }
        end
    end
    return e
end

local function controller(text, perpage)
    local doc = docFor(text, perpage)
    local settings = {}
    local ui = { rolling = true, document = doc, view = { view_mode = 'page' } }
    function ui:handleEvent(ev) if ev.name == 'GotoPage' then doc.page = ev.args[1] end end
    local plugin = { ui = ui, getSetting = function(_, k, d) if settings[k] ~= nil then return settings[k] end return d end,
        setSetting = function(_, k, v) settings[k] = v end }
    local e = engine()
    local c = SC:new{ plugin = plugin, tts_engine = e, text_parser = Parser:new{},
        highlight_manager = { highlightSentence = function() end, clearHighlights = function() end } }
    c.showPlaybackBar = function() end
    c._applyBarVisibility = function() end
    return c, e, doc
end

local function run(c, e, steps, hook)
    for i = 1, steps do
        now = now + 0.5
        e:step()
        local due = tasks
        tasks = {}
        for _, t in ipairs(due) do if t.t <= now then t.f() else tasks[#tasks + 1] = t end end
        if hook then hook(i) end
        if c.state == c.STATE.STOPPED and not e.q[1] then break end
    end
end

local function book(seed)
    math.randomseed(seed)
    local parts = {}
    for i = 1, 260 do
        local r = math.random(8)
        if r == 1 then parts[#parts+1] = '— Да, да, — сказал он. — Конечно.'
        elseif r == 2 then local w = {} for k = 1, math.random(30, 120) do w[k] = 'слово' .. k end; parts[#parts+1] = table.concat(w, ' ') .. '.'
        elseif r == 3 then parts[#parts+1] = 'Глава ' .. i .. '\n'
        else parts[#parts+1] = 'Фраза номер ' .. i .. ' кончается тут.' end
    end
    return table.concat(parts, ' ')
end

-- 1. A whole book, no jumps: heard text = the book, page followed to the end.
for seed = 1, 3 do
    local text = book(seed)
    local c, e, doc = controller(text, 40)
    c:start()
    run(c, e, 100000)
    check(c.state == c.STATE.STOPPED, 'stops at the end of the book')
    local got = {}
    for _, t in ipairs(e.heard) do got[#got+1] = DS.key(t) end
    check(table.concat(got) == DS.key(text), 'every word heard exactly once (seed ' .. seed .. ')')
    check(e.flushes == 1, 'one flush for the whole book')
    check(doc.page == doc:getPageCount(), 'the screen followed to the last page')
end

-- 2. Pauses and resumes: a resumed sentence is heard again from its start; nothing else repeats or is lost.
do
    local text = book(7)
    local c, e = controller(text, 40)
    c:start()
    local restarts = 0
    run(c, e, 100000, function(i)
        if i % 97 == 0 and c:isPlaying() then c:pause(); c:resume(); restarts = restarts + 1 end
    end)
    -- Drop the sentence heard twice at each resume and compare.
    local got, last = {}, nil
    for _, t in ipairs(e.heard) do if t ~= last then got[#got+1] = DS.key(t) end; last = t end
    check(restarts > 3, 'resumed several times')
    check(table.concat(got) == DS.key(text), 'pause/resume: only the interrupted sentence repeats')
end

-- 3. The engine is lost mid-book: reconnect, go on from the sentence being heard.
do
    local text = book(9)
    local c, e = controller(text, 40)
    c:start()
    run(c, e, 100000, function(i) if i == 301 then e.lost = true; e.q = {}; e.playing = nil end end)
    local got, last = {}, nil
    for _, t in ipairs(e.heard) do if t ~= last then got[#got+1] = DS.key(t) end; last = t end
    check(table.concat(got) == DS.key(text), 'engine lost: reading goes on without a gap or a repeat')
end

-- 4. Previous sentence and rewind land on sentence starts and continue in order from there.
do
    local text = book(11)
    local c, e = controller(text, 40)
    c:start()
    run(c, e, 400)
    local before = c.current_sentence
    c:prevSentence()
    run(c, e, 2)
    local prev = c.current_sentence
    check(prev ~= before and tonumber(prev.xp1) <= tonumber(before.from), 'previous sentence is before the current one')
    check(DS.key(text:sub(tonumber(prev.xp1), tonumber(before.from) - 1)) == '', 'nothing between the previous and the current one')
    c:rewind(15)
    run(c, e, 2)
    check(c:isPlaying(), 'rewind keeps playing')
end

-- 5. Speed change restarts from the sentence being heard.
do
    local text = book(13)
    local c, e = controller(text, 40)
    c:start()
    run(c, e, 200)
    local cur = c.current_sentence
    c:setSpeechRate(1.5)
    run(c, e, 1)
    check(e.heard[#e.heard] == cur.text, 'new rate: the current sentence again')
end

print('reader: ' .. passed .. ' checks passed')
