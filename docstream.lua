--[[--
Read-aloud text as one stream of sentences, by document position.

The book is read from a cursor: the position of the first word not yet given to the engine. Each fill walks a bounded
window of words from the cursor, parses it into sentences, aligns them to the exact positions of their words, hands
out every complete sentence and moves the cursor past the last one. The last sentence of a window may be cut by the
window end: it is not handed out, the next window starts at it. So every word of the book is handed out exactly once
and in order: there are no pages, no views, nothing glued or peeked, and nothing to repeat.

Pages matter only for showing: a sentence carries its positions, the reader turns the screen to them.

Fixed-layout documents (PDF, DjVu) have no word positions; PageStream gives their pages in turn, sentence by sentence.

Pure module: everything goes through the document object, so tests can run it on a mock document.

@module docstream
--]]

local DocStream = {}
DocStream.__index = DocStream
local XpText = DocStream -- helper names shared with the previous module

-- Words walked per fill (~1500 characters): a few sentences of headroom, cheap to parse.
DocStream.WINDOW_WORDS = 220
-- Words of context read before a position, to find where the sentence holding it begins.
DocStream.BACK_WORDS = 80

-- A UTF-8 character that is not part of a word for alignment: space, punctuation, quotes, dashes, soft hyphen,
-- combining marks (stress U+0301), BOM. Letters and digits of any script are kept.
local function isNoise(ch)
    if #ch == 1 then return not ch:match("%w") end
    local b1, b2 = ch:byte(1, 2)
    if b1 == 0xC2 then return true end                                -- U+0080–U+00BF: nbsp, «», soft hyphen, signs
    if b1 == 0xCC or (b1 == 0xCD and b2 < 0xB0) then return true end -- combining marks U+0300–U+036F (stress)
    if b1 == 0xE2 then return true end                                -- U+2000–U+2FFF: punctuation, symbols, arrows
    if b1 == 0xE3 and b2 == 0x80 then return true end                 -- CJK punctuation U+3000–U+303F
    if b1 == 0xEF and b2 >= 0xB8 and b2 <= 0xBB then return true end  -- variation selectors, BOM, specials
    if b1 == 0xEF and (b2 == 0xBC or b2 == 0xBD) then                  -- fullwidth forms: keep letters/digits only
        local b3 = ch:byte(3)
        local cp = ((b1 % 16) * 4096) + ((b2 % 64) * 64) + (b3 % 64)
        local is_digit = cp >= 0xFF10 and cp <= 0xFF19
        local is_upper = cp >= 0xFF21 and cp <= 0xFF3A
        local is_lower = cp >= 0xFF41 and cp <= 0xFF5A
        return not (is_digit or is_upper or is_lower)
    end
    if b1 == 0xF0 and b2 == 0x9F then return true end                 -- emoji
    return false
end

--- Alignment key of [s]: its letters and digits only, ASCII lowercased. Two extracts of the same text have the same
--- key whatever the spacing, line breaks, hyphenation or punctuation spacing of each.
function XpText.key(s)
    if not s or s == "" then return "" end
    local out, n = {}, 0
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if not isNoise(ch) then
            n = n + 1
            out[n] = (#ch == 1) and ch:lower() or ch
        end
    end
    return table.concat(out)
end

--- UTF-16 offset (what Android reports in onRangeStart) of the character of [text] where the key reaches byte [kpos].
function XpText.utf16AtKey(text, kpos)
    local k, u = 0, 0
    for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if not isNoise(ch) then
            if k >= kpos then return u end
            k = k + #ch
        end
        u = u + ((#ch == 4) and 2 or 1)
    end
    return nil
end

local function cmp(doc, a, b)
    -- 1: b after a, 0: same, -1: b before a, nil: invalid
    local ok, r = pcall(doc.compareXPointers, doc, a, b)
    if ok then return r end
    return nil
end

--- True when position [xp] is at or after [from] (and before [to] when given).
local function within(doc, xp, from, to)
    if from then
        local c = cmp(doc, from, xp)
        if c == nil or c < 0 then return false end
    end
    if to then
        local c = cmp(doc, to, xp)
        if c == nil or c >= 0 then return false end
    end
    return true
end
XpText.within = within

--- Start of the first word at or after [xp] (nil at the end of the document).
function XpText.firstWordAt(doc, xp)
    local nxt = doc:getNextVisibleWordStart(xp)
    if not nxt then return nil end
    local prev = doc:getPrevVisibleWordStart(nxt)
    -- [xp] itself is a word start: the next start skipped it.
    if prev and prev ~= nxt then
        local c = cmp(doc, xp, prev)
        if c ~= nil and c >= 0 then return prev end
    end
    return nxt
end

--- Words from [xp_start] (a word start) forward: { xs, xe, key } each. Stops after [max] words, or [extra] words after
--- the first word that starts at or after [stop_xp].
function XpText.walk(doc, xp_start, max, stop_xp, extra)
    local words = {}
    local cur = xp_start
    local past = nil
    for _ = 1, max do
        if not cur then break end
        local xe = doc:getNextVisibleWordEnd(cur)
        if not xe then break end
        local text = doc:getTextFromXPointers(cur, xe) or ""
        words[#words + 1] = { xs = cur, xe = xe, key = XpText.key(text) }
        if stop_xp and not past and within(doc, cur, stop_xp, nil) then past = 0 end
        if past then
            past = past + 1
            if past > (extra or 0) then break end
        end
        local nxt = doc:getNextVisibleWordStart(cur)
        if not nxt or nxt == cur then break end
        local c = cmp(doc, cur, nxt)
        if c == nil or c <= 0 then break end -- never walk backwards (corrupt position): stop
        cur = nxt
    end
    return words
end

--- Give each sentence of [sentences] the positions of its first and last word ([words] cover the same text).
--- Returns false when the two do not describe the same letters (hidden text, an extraction quirk): the caller
--- then falls back to the old screen path rather than highlight or turn pages at wrong places.
function XpText.align(sentences, words)
    local wkeys = {}
    for i, w in ipairs(words) do wkeys[i] = w.key end
    local skeys = {}
    for i, s in ipairs(sentences) do skeys[i] = XpText.key(s.text) end
    if table.concat(wkeys) ~= table.concat(skeys) then return false end
    -- Cumulative key offsets of each word: word i covers [wstart[i], wend[i]).
    local wstart, wend = {}, {}
    local pos = 0
    for i, k in ipairs(wkeys) do
        wstart[i] = pos
        pos = pos + #k
        wend[i] = pos
        words[i].kstart = wstart[i]
    end
    local wi = 1
    pos = 0
    for i, s in ipairs(sentences) do
        local k = skeys[i]
        if #k == 0 then
            s.xp0, s.xp1 = nil, nil
        else
            local from, to = pos, pos + #k
            -- First word that reaches into the sentence (skip words with an empty key: lone dashes, quotes).
            while wi <= #words and (wend[wi] <= from or #wkeys[wi] == 0) do wi = wi + 1 end
            local wj = wi
            while wj + 1 <= #words and wstart[wj + 1] < to do wj = wj + 1 end
            -- A trailing word with an empty key (a closing dash or quote) is not part of the highlight.
            while wj > wi and #wkeys[wj] == 0 do wj = wj - 1 end
            if wi > #words then return false end
            s.xp0, s.xp1 = words[wi].xs, words[wj].xe
            s.word_first, s.word_last = wi, wj
            s.kfrom = from
            pos = to
        end
    end
    return true
end


local function speakable(text)
    -- A letter or digit of any script (UTF-8 lead bytes count as letters).
    return text and (text:find("[%w\192-\244]") ~= nil) or false
end
DocStream.speakable = speakable

--- A stream over [doc]. [parse] is function(text) -> { sentences = { { text = … }, … } } (the plugin's TextParser).
function DocStream.new(doc, parse)
    local o = setmetatable({ doc = doc, parse = parse, buf = {}, cursor = nil, ended = false }, DocStream)
    return o
end

--- True when [doc] supports reading by position.
function DocStream.supported(doc)
    return doc and doc.getNextVisibleWordStart and doc.getNextVisibleWordEnd and doc.getPrevVisibleWordStart
        and doc.getTextFromXPointers and doc.compareXPointers and true or false
end

local function backFrom(doc, xp, n)
    local back = xp
    for _ = 1, n do
        local p = doc:getPrevVisibleWordStart(back)
        if not p or p == back then break end
        local c = cmp(doc, p, back)
        if c == nil or c <= 0 then break end
        back = p
    end
    return back
end

-- Inline elements: a word inside one belongs to the paragraph around it.
local INLINE = { a = true, b = true, i = true, em = true, strong = true, span = true, sup = true, sub = true,
    small = true, u = true, s = true, font = true, code = true, q = true, cite = true, abbr = true, big = true,
    del = true, ins = true, mark = true, tt = true, emphasis = true, strikethrough = true, style = true }

--- The block (paragraph, heading) holding the word at [xp], from the CREngine XPointer path
--- («/body/DocFragment[3]/body/div/p[5]/em/text().12» → «/body/DocFragment[3]/body/div/p[5]»); nil when unknown.
local function blockOf(xp)
    local path = type(xp) == "string" and xp:match("^(/.*)/text%(%)")
    if not path then return nil end
    while true do
        local head, last = path:match("^(.*)/([%w_]+)%[?%d*%]?$")
        if not (head and last and INLINE[last:lower()]) then break end
        path = head
    end
    return path
end
DocStream.blockOf = blockOf

-- A short line of its own that names a chapter: «Глава вторая», «Часть 2», «VI», «12.», «Пролог», «Chapter 3».
local HEADING_WORDS = { ["глава"] = true, ["часть"] = true, ["книга"] = true, ["том"] = true, ["раздел"] = true,
    ["пролог"] = true, ["эпилог"] = true, ["chapter"] = true, ["part"] = true, ["book"] = true,
    ["prologue"] = true, ["epilogue"] = true }

local function headingText(t)
    t = t:gsub("^%s+", ""):gsub("[%s%.:]+$", "")
    if t == "" or #t > 60 then return false end
    if t:match("^[IVXLCDM]+$") or t:match("^%d+$") then return true end
    local first = t:match("^(%S+)")
    if not first then return false end
    -- Lowercase ASCII and Cyrillic («ГЛАВА», «Глава»).
    local low = first:lower():gsub("\208([\144-\175])", function(c)
        local b = c:byte()
        if b < 160 then return "\208" .. string.char(b + 32) end
        return "\209" .. string.char(b - 32)
    end):gsub("\208\129", "\209\145")
    return HEADING_WORDS[low] == true
end
DocStream.headingText = headingText

--- True when sentence [s] is a chapter heading: the book marks it so (h1–h6, an FB2 title), or it is a short line of its
--- own naming a chapter. A pause follows a heading.
function DocStream.isHeading(s, words)
    local w0, w1 = words[s.word_first], words[s.word_last]
    local block = w0 and blockOf(w0.xs)
    if not block then return false end
    if block:match("/[hH][1-6]%[?%d*%]?$") or block:find("/title/", 1, true) or block:match("/title%[?%d*%]?$") then
        return true
    end
    -- Its own block: the next word (when known) is in another one.
    local nxt = words[s.word_last + 1]
    if nxt and blockOf(nxt.xs) == block then return false end
    if blockOf(w1.xs) ~= block then return false end
    return headingText(s.text)
end

--- Text of [words]: one getTextFromXPointers per block, blocks joined by a line break. A range across blocks comes
--- back from CREngine without the break, which glued a heading to the first sentence after it («VI Полковника…»).
local function textOf(doc, words)
    local parts, from = {}, 1
    local cur = blockOf(words[1].xs)
    for i = 2, #words + 1 do
        local b = words[i] and blockOf(words[i].xs)
        if i > #words or (cur and b and b ~= cur) then
            parts[#parts + 1] = doc:getTextFromXPointers(words[from].xs, words[i - 1].xe) or ""
            from, cur = i, b
        end
    end
    -- A blank line: the parser joins single line breaks (wrapped PDF lines) and keeps blank ones as paragraphs.
    return table.concat(parts, "\n\n")
end
DocStream.textOf = textOf

--- Parse the words [words] (from walk) into aligned sentences. Each sentence gets [from]: the word position where its
--- text begins in the stream (a leading dash or quote of a reply included), and [last]: the index of its last word.
--- nil when the text and the words do not align.
local function sentencesOf(self, words)
    local doc = self.doc
    local text = textOf(doc, words)
    local parsed = self.parse(text)
    local list = parsed and parsed.sentences
    if not (list and #list > 0) then return nil end
    if not XpText.align(list, words) then return nil end
    local prev_last = 0
    for _, s in ipairs(list) do
        if s.word_first then
            s.from = words[prev_last + 1] and words[prev_last + 1].xs or s.xp0
            s.last = s.word_last
            prev_last = s.word_last
            s.heading = DocStream.isHeading(s, words)
        end
    end
    return list
end

--- Place the cursor at the start of the sentence holding [xp] (any position: a selection, the top of the screen).
--- Returns false when there is no text from there on.
function DocStream:seek(xp)
    local doc = self.doc
    self.buf, self.ended = {}, false
    local first = XpText.firstWordAt(doc, xp)
    if not first then self.cursor = nil; self.ended = true; return false end
    local back = backFrom(doc, first, DocStream.BACK_WORDS)
    local words = XpText.walk(doc, back, DocStream.BACK_WORDS + 60, first, 40)
    local list = #words > 0 and sentencesOf(self, words)
    self.cursor = first
    if list then
        for _, s in ipairs(list) do
            if s.xp0 and within(doc, first, s.from, nil) and within(doc, s.xp1, first, nil) then
                -- The sentence holding the word, unless it starts at the very edge of the context (cut by it).
                if s.from ~= words[1].xs or back == first then self.cursor = s.from end
                break
            end
        end
    end
    return true
end

--- Place the cursor exactly at [xp] (a word start known from an earlier sentence: resume, jumps).
function DocStream:seekExact(xp)
    self.buf, self.ended = {}, false
    self.cursor = xp
    if not xp then self.ended = true end
end

--- Next sentence: { text, xp0, xp1, from } (from = where its text begins), nil at the end of the book.
--- Sentences without a letter or digit are passed over.
function DocStream:next()
    while true do
        if #self.buf == 0 then
            if not self:_fill() then return nil end
        else
            local s = table.remove(self.buf, 1)
            if speakable(s.text) then return s end
        end
    end
end

--- The next sentences without taking them (up to [n]).
function DocStream:peek(n)
    while #self.buf < n and self:_fill() do end
    local out = {}
    for i = 1, math.min(n, #self.buf) do out[i] = self.buf[i] end
    return out
end

function DocStream:_fill()
    if self.ended or not self.cursor then self.ended = true; return false end
    local doc = self.doc
    local words = XpText.walk(doc, self.cursor, DocStream.WINDOW_WORDS)
    if #words == 0 then self.ended = true; return false end
    local at_end = #words < DocStream.WINDOW_WORDS or doc:getNextVisibleWordStart(words[#words].xs) == nil
    local list = sentencesOf(self, words)
    local after -- index of the last word handed out
    if not list then
        -- Text and positions disagree (hidden text, an extraction quirk): the window goes as it is, whole.
        local text = doc:getTextFromXPointers(words[1].xs, words[#words].xe) or ""
        self.buf[#self.buf + 1] = { text = text, xp0 = words[1].xs, xp1 = words[#words].xe, from = words[1].xs }
        after = #words
    else
        local take = #list
        if not at_end then
            -- The last sentence may be cut by the window: the next window starts at it.
            while take > 0 and not list[take].last do take = take - 1 end
            if take > 1 then take = take - 1 end
            -- One sentence longer than the window (the parser cuts long ones, so this is rare): handed out as it is.
        end
        for i = 1, take do
            local s = list[i]
            if s.last then
                self.buf[#self.buf + 1] = { text = s.text, xp0 = s.xp0, xp1 = s.xp1, from = s.from, heading = s.heading }
                after = s.last
            end
        end
        if not after then after = #words end
    end
    if after >= #words then
        if at_end then
            self.ended = true
            self.cursor = nil
        else
            self.cursor = doc:getNextVisibleWordStart(words[#words].xs)
            if not self.cursor then self.ended = true end
        end
    else
        self.cursor = words[after + 1].xs
    end
    return #self.buf > 0 or not self.ended
end

--- The sentence before the one that begins at [xp] (for «previous sentence»), or nil at the start of the book.
function DocStream:sentenceBefore(xp)
    local doc = self.doc
    local first = XpText.firstWordAt(doc, xp)
    if not first then return nil end
    local back = backFrom(doc, first, DocStream.BACK_WORDS)
    if back == first then return nil end
    local words = XpText.walk(doc, back, DocStream.BACK_WORDS + 2, first, 0)
    -- Only the words before [xp].
    while #words > 0 and within(doc, words[#words].xs, first, nil) do words[#words] = nil end
    if #words == 0 then return nil end
    local list = sentencesOf(self, words)
    if not list then return { text = "", xp0 = words[1].xs, xp1 = words[#words].xe, from = words[1].xs } end
    for i = #list, 1, -1 do
        local s = list[i]
        if s.last and speakable(s.text) then return { text = s.text, xp0 = s.xp0, xp1 = s.xp1, from = s.from } end
    end
    return nil
end

--- Where the screen view starting at [view_xp] cuts [s]: the UTF-16 offset in its text (what the engine reports in
--- onRangeStart) of its first word on that view; nil when the sentence does not reach it.
function DocStream.offsetAt(doc, s, view_xp)
    if not (s.xp0 and s.xp1 and view_xp) then return nil end
    if within(doc, s.xp0, view_xp, nil) or not within(doc, s.xp1, view_xp, nil) then return nil end
    local prefix = doc:getTextFromXPointers(s.xp0, view_xp) or ""
    return XpText.utf16AtKey(s.text, #XpText.key(prefix))
end

-- ═══════════════════════════════════════════════════════════════════════
-- Fixed-layout documents: page by page.
-- ═══════════════════════════════════════════════════════════════════════

local PageStream = {}
PageStream.__index = PageStream
DocStream.PageStream = PageStream

--- [page_text] is function(page) -> text|nil; [parser] the plugin's TextParser.
function PageStream.new(page_text, parser, page, page_count)
    return setmetatable({ page_text = page_text, parser = parser, page = page, count = page_count,
        list = nil, i = 0 }, PageStream)
end

--- Next sentence: { text, page, index, parsed }, nil after the last page.
function PageStream:next()
    while true do
        if self.list and self.i < #self.list then
            self.i = self.i + 1
            local s = self.list[self.i]
            if speakable(s.text) then
                return { text = s.text, page = self.list.page, index = self.i, sentence = s, parsed = self.list.parsed }
            end
        else
            if self.list then self.page = self.page + 1 end
            if self.page > self.count then return nil end
            local text = self.page_text(self.page) or ""
            local parsed = self.parser:parse(text)
            self.list = parsed.sentences or {}
            self.list.page, self.list.parsed = self.page, parsed
            self.i = 0
        end
    end
end

--- Start at sentence [index] of [page].
function PageStream:seek(page, index)
    self.page, self.list, self.i = page, nil, 0
    self.skip = (index or 1) - 1
    local s
    for _ = 1, self.skip do s = self:next(); if not s then break end end
end

return DocStream
