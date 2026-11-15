--[[--
Reading text by document position (CREngine XPointers) instead of by screen coordinates.

The old way took the visible page as text from screen coordinates and peeked at the next page by scrolling the document
out of sight and back. A sentence cut by the page break then had to be glued from two extracts that overlapped by an
unknown amount, and every heuristic for that (carry, overlap, peek of a stale view) produced its own errors: words
heard twice, a piece of another chapter, a lost comma, a page tail read as a heading.

Here every word of the book has an exact position. The text of the current view and of the next one is read from the
document directly (getTextFromXPointers), split into sentences, and each sentence gets the positions of its first and
last word. A sentence belongs to the view where it starts; it is read whole, its highlight is drawn from its positions
(only what is on screen shows), and nothing is ever glued or peeked.

Pure module: everything goes through the document object, so tests can run it on a mock document.

@module xptext
--]]

local XpText = {}

-- Words of context read before the view start, to find where the sentence holding the first word begins.
XpText.BACK_WORDS = 80
-- Words read past the end of the next view, so the last sentence that starts in it is complete.
XpText.TAIL_WORDS = 160
-- Upper bound on words read for one view build (two views of a dense page are ~700 words).
XpText.MAX_WORDS = 4000

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

--- The text, sentences and positions of the current view and of the next one.
--- @param doc        CreDocument
--- @param parse      function(text) -> parsed { text, sentences = { { text = … }, … } } (the plugin's TextParser)
--- @param opts       { anchor = xp (read from here: start at the sentence holding it) }
--- @return table|nil { current = { sentences }, next = { sentences }, prev_tail = sentence|nil,
---                     view_start, next_start, after_next }  or nil, reason
function XpText.build(doc, parse, opts)
    opts = opts or {}
    if not (doc and doc.getNextVisibleWordStart and doc.getNextVisibleWordEnd and doc.getPrevVisibleWordStart
            and doc.getTextFromXPointers and doc.compareXPointers and doc.getXPointer and doc.getPageXPointer
            and doc.getCurrentPage and doc.getPageCount) then
        return nil, "no xpointer api"
    end
    local view_start = doc:getXPointer()
    if not view_start then return nil, "no view position" end
    local page = doc:getCurrentPage()
    local count = doc:getPageCount()
    local nvis = 1
    if doc.getVisiblePageCount then
        local ok, n = pcall(doc.getVisiblePageCount, doc)
        if ok and type(n) == "number" and n >= 1 then nvis = n end
    end
    local next_start = (page + nvis <= count) and doc:getPageXPointer(page + nvis) or nil
    local after_next = (page + 2 * nvis <= count) and doc:getPageXPointer(page + 2 * nvis) or nil

    local first = XpText.firstWordAt(doc, view_start)
    if not first then return nil, "no words on the view" end
    -- Context before the view: the sentence holding the first word may have begun on the previous one.
    local back = first
    for _ = 1, XpText.BACK_WORDS do
        local p = doc:getPrevVisibleWordStart(back)
        if not p or p == back then break end
        local c = cmp(doc, p, back)
        if c == nil or c <= 0 then break end
        back = p
    end
    local words = XpText.walk(doc, back, XpText.MAX_WORDS, after_next, XpText.TAIL_WORDS)
    if #words == 0 then return nil, "no words" end
    local text = doc:getTextFromXPointers(words[1].xs, words[#words].xe) or ""
    local parsed = parse(text)
    if not (parsed and parsed.sentences and #parsed.sentences > 0) then return nil, "nothing parsed" end
    if not XpText.align(parsed.sentences, words) then return nil, "alignment failed" end

    local out = { current = {}, next = {}, prev_tail = nil,
                  view_start = view_start, next_start = next_start, after_next = after_next, parsed = parsed }
    local walked_to_end = not after_next
    local last_index = #parsed.sentences
    for i, s in ipairs(parsed.sentences) do
        if s.xp0 then
            if not within(doc, s.xp0, view_start, nil) then
                -- Started before the view: the last such one runs into the view (unless it ended before it).
                if within(doc, s.xp1, view_start, nil) then out.prev_tail = s end
            elseif not next_start or within(doc, s.xp0, view_start, next_start) then
                out.current[#out.current + 1] = s
            elseif not after_next or within(doc, s.xp0, next_start, after_next) then
                -- The last parsed sentence may be cut by the end of the walk; keep it only when the walk reached the
                -- end of the document or it is followed by another sentence.
                if i < last_index or walked_to_end then out.next[#out.next + 1] = s end
            end
        end
    end
    -- A sentence of this view that runs onto the next one: where (UTF-16 offset in its text) the next view begins, so
    -- the page can turn when the voice gets there instead of at the next sentence.
    if next_start then
        for _, s in ipairs(out.current) do
            if s.word_first then
                for wi = s.word_first, s.word_last do
                    if within(doc, words[wi].xs, next_start, nil) then
                        if wi > s.word_first then s.turn_at = XpText.utf16AtKey(s.text, words[wi].kstart - s.kfrom) end
                        break
                    end
                end
            end
        end
    end
    if opts.anchor then
        -- Read from here: drop the sentences of the view that end before the anchor.
        local kept, started = {}, false
        local all = {}
        if out.prev_tail then all[1] = out.prev_tail end
        for _, s in ipairs(out.current) do all[#all + 1] = s end
        for _, s in ipairs(all) do
            if started or within(doc, s.xp1, opts.anchor, nil) or cmp(doc, opts.anchor, s.xp1) == 0 then
                started = true
                kept[#kept + 1] = s
            end
        end
        if #kept == 0 then return nil, "anchor not on the view" end
        out.current = kept
        out.prev_tail = nil
        out.anchored = true
    end
    return out
end

return XpText
