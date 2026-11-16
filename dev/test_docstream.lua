-- DocStream: every word of the book handed out exactly once, in order, from any start; previous sentence; screen cut.
package.preload['logger'] = function() return setmetatable({}, {__index=function() return function() end end}) end
local DS = dofile('docstream.lua')
local Parser = dofile('textparser.lua')
local parser = Parser:new{}
local parse = function(t) return parser:parse(t) end
local passed = 0
local function check(ok, name) if not ok then error('FAIL: '..name, 2) end; passed = passed + 1 end

local function docFor(text)
    local starts, ends = {}, {}
    for a, _, b in text:gmatch('()(%S+)()') do starts[#starts+1] = a; ends[#ends+1] = b end
    local d = {}
    function d:compareXPointers(a, b) a, b = tonumber(a), tonumber(b); return b == a and 0 or (b > a and 1 or -1) end
    function d:getNextVisibleWordStart(x) for _, a in ipairs(starts) do if a > tonumber(x) then return tostring(a) end end end
    function d:getPrevVisibleWordStart(x) for i = #starts, 1, -1 do if starts[i] < tonumber(x) then return tostring(starts[i]) end end end
    function d:getNextVisibleWordEnd(x) for i, a in ipairs(starts) do if a >= tonumber(x) then return tostring(ends[i]) end end end
    function d:getTextFromXPointers(a, b) return text:sub(tonumber(a), tonumber(b) - 1) end
    d.starts = starts
    return d
end

local function book(seed)
    math.randomseed(seed)
    local parts = {}
    for i = 1, 400 do
        local r = math.random(10)
        if r == 1 then parts[#parts+1] = '\n— Да, да, — сказал он. — Конечно.\n'
        elseif r == 2 then
            local w = {} for k = 1, math.random(60, 260) do w[k] = 'слово' .. k end
            parts[#parts+1] = table.concat(w, ' ') .. '.'
        elseif r == 3 then parts[#parts+1] = 'Глава ' .. i .. '\n'
        elseif r == 4 then parts[#parts+1] = 'И т. д. и А. И. Куприн пришёл… подождите… не бранитесь!'
        elseif r == 5 then parts[#parts+1] = '«Кто там?» — спросила она.'
        else parts[#parts+1] = 'Фраза номер ' .. i .. ' кончается тут.' end
    end
    return table.concat(parts, ' ')
end

for seed = 1, 6 do
    local text = book(seed)
    local doc = docFor(text)
    local whole = DS.key(text)
    -- From the start: the stream's keys concatenate to the whole book.
    local st = DS.new(doc, parse)
    st:seekExact(doc.starts[1])
    local got, n, last = {}, 0, nil
    while true do
        local s = st:next()
        if not s then break end
        n = n + 1
        if last then check(tonumber(s.from) > tonumber(last.xp1) - 1, 'monotonic ' .. seed) end
        got[#got+1] = DS.key(s.text)
        last = s
    end
    check(table.concat(got) == whole, 'every word once, in order (seed ' .. seed .. ', ' .. n .. ' sentences)')
    -- From random places: seek lands at a sentence start, and the rest is the exact tail of the book.
    for _ = 1, 25 do
        local w = math.random(#doc.starts)
        local st2 = DS.new(doc, parse)
        st2:seek(tostring(doc.starts[w]))
        local first = st2:next()
        check(first ~= nil, 'seek finds a sentence')
        check(tonumber(first.from) <= doc.starts[w], 'seek starts at or before the word')
        local tail = { DS.key(first.text) }
        while true do local s = st2:next(); if not s then break end; tail[#tail+1] = DS.key(s.text) end
        local from_key = DS.key(text:sub(tonumber(first.from)))
        check(table.concat(tail) == from_key, 'tail after seek is exact')
        -- Previous sentence ends right before this one.
        local prev = st2:sentenceBefore(first.from)
        if prev then
            check(tonumber(prev.xp1) <= tonumber(first.from), 'previous sentence is before')
            local between = DS.key(text:sub(tonumber(prev.xp1), tonumber(first.from) - 1))
            check(between == '', 'nothing between previous and current')
        end
    end
end
-- Chapter headings: marked by the book (h1–h6, FB2 title) or a short line of its own.
for _, t in ipairs({ 'VI', 'VI.', '12', 'Глава вторая', 'ГЛАВА I', 'Часть 2.', 'Пролог', 'Chapter 3' }) do
    check(DS.headingText(t), 'heading text ' .. t)
end
for _, t in ipairs({ 'Он пришёл.', 'Вот так', 'Главный герой ушёл' }) do check(not DS.headingText(t), 'not a heading ' .. t) end
check(DS.blockOf('/body/DocFragment[3]/body/div/p[5]/em/text().12') == '/body/DocFragment[3]/body/div/p[5]', 'inline is the paragraph')
check(DS.isHeading({ word_first = 1, word_last = 1, text = 'Начало' },
    { { xs = '/b/h2/text().0', xe = '/b/h2/text().2' }, { xs = '/b/p[1]/text().0' } }), 'h2 is a heading')
check(DS.isHeading({ word_first = 1, word_last = 1, text = 'VI' },
    { { xs = '/b/p[1]/text().0', xe = '/b/p[1]/text().2' }, { xs = '/b/p[2]/text().0' } }), 'VI alone is a heading')
check(not DS.isHeading({ word_first = 1, word_last = 1, text = 'VI' },
    { { xs = '/b/p[1]/text().0', xe = '/b/p[1]/text().2' }, { xs = '/b/p[1]/text().3' } }), 'VI inside a paragraph is not')
print('docstream: ' .. passed .. ' checks passed')
