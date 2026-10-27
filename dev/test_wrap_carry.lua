-- Unit tests for the page-boundary wrap-carry decision and the CJK helpers
-- it uses (issue #96: Chinese page-boundary sentences were never carried
-- because the old guard required a Latin lowercase continuation and a
-- space-separated word count, neither of which exists in Chinese).
--
-- Run with the dev shell Lua (no KOReader required):
--   luajit dev/test_wrap_carry.lua
--   (or: lua5_4 dev/test_wrap_carry.lua)

local here = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
local Utils = dofile(here .. "../utils.lua")

local passed, failed = 0, 0
local function eq(actual, expected, name)
    if actual == expected then
        passed = passed + 1
    else
        failed = failed + 1
        print(("FAIL %s: expected %s, got %s"):format(
            name, tostring(expected), tostring(actual)))
    end
end

-- decodeCharAt -------------------------------------------------------------
do
    local cp, next_i = Utils.decodeCharAt("a好", 1)
    eq(cp, 97, "decodeCharAt ascii")
    eq(next_i, 2, "decodeCharAt ascii next")
    cp, next_i = Utils.decodeCharAt("a好", 2)
    eq(cp, 0x597D, "decodeCharAt CJK unified")
    eq(next_i, 5, "decodeCharAt 3-byte advance")
    cp = Utils.decodeCharAt("a", 5)
    eq(cp, nil, "decodeCharAt past end")
end

-- hasCJKScript ---------------------------------------------------------------
do
    eq(Utils.hasCJKScript("这是一句中文。"), true, "CJK detects Chinese")
    eq(Utils.hasCJKScript("これは日本語です。"), true, "CJK detects kana")
    eq(Utils.hasCJKScript("ｶﾀｶﾅ"), true, "CJK detects halfwidth kana")
    eq(Utils.hasCJKScript("This is English."), false, "CJK rejects Latin")
    eq(Utils.hasCJKScript("Ceci est du français éàü"), false, "CJK rejects Latin-1")
    eq(Utils.hasCJKScript("한국어 텍스트"), false, "CJK excludes hangul (spaced script)")
    eq(Utils.hasCJKScript(""), false, "CJK rejects empty")
    eq(Utils.hasCJKScript(nil), false, "CJK rejects nil")
end

-- charCount ------------------------------------------------------------------
do
    eq(Utils.charCount("第二章"), 3, "charCount CJK")
    eq(Utils.charCount(" 这是一句测试 "), 6, "charCount skips spaces")
    eq(Utils.charCount("hello"), 5, "charCount ascii")
    eq(Utils.charCount(""), 0, "charCount empty")
end

-- shouldCarryPageBoundary ----------------------------------------------------
do
    -- Latin: the original heuristics must keep working.
    eq(Utils.shouldCarryPageBoundary(
        "he walked to the",
        "door and looked back"),
        true, "latin lowercase continuation carries")
    eq(Utils.shouldCarryPageBoundary(
        "end of chapter",
        "Chapter Two"),
        false, "latin capital continuation with short last line refuses")
    eq(Utils.shouldCarryPageBoundary(
        "it was a long winding road through the",
        "Mountains of the Moon"),
        true, "latin capital continuation with long last line carries")
    eq(Utils.shouldCarryPageBoundary(
        "he said — ",
        "nothing else mattered at all today"),
        true, "latin dash-prefixed continuation carries")

    -- CJK: the spaceless-script path (this is the issue #96 fix).
    -- A Chinese page ends mid-sentence; the continuation starts with no
    -- capital (impossible) and the whole last sentence is one word token,
    -- so the old guard always refused.
    eq(Utils.shouldCarryPageBoundary(
        "他沿着那条长长的路一直走到了山",
        "脚下才停下来。"),
        true, "cjk cut sentence carries (was always refused)")
    eq(Utils.shouldCarryPageBoundary(
        "天色渐渐暗了下来，街上的行人也少了",
        "不多。"),
        true, "cjk short continuation carries")
    -- A bare short heading line at the page end must not swallow the next
    -- sentence.
    eq(Utils.shouldCarryPageBoundary(
        "第二章",
        "山中的清晨格外安静。"),
        false, "cjk short heading line refuses")

    -- Japanese (kana): same spaceless treatment.
    eq(Utils.shouldCarryPageBoundary(
        "彼は長い長い道を歩いて山の",
        "ふもとにたどり着いた。"),
        true, "kana cut sentence carries")

    -- Korean uses spaces, so it stays on the Latin word-count path.
    eq(Utils.shouldCarryPageBoundary(
        "그는 길을",
        "걸었다."),
        false, "korean short last line refuses (spaced script)")
    eq(Utils.shouldCarryPageBoundary(
        "그는 오랜 시간 길었던 골목길을 따라 천천히",
        "걸었다."),
        true, "korean long last line carries")
end

-- reanchorFromHere (from-here anchoring, same issue) --------------------------
do
    -- Anchor present and unchanged: nil means keep the captured suffix.
    local fresh = "页面开头的一句话。\n这句话是选中的起点从这里继续读到结尾。"
    local captured = "从这里继续读到结尾。"
    eq(Utils.reanchorFromHere(fresh, captured), nil,
        "reanchor keeps CJK selection when unchanged")

    -- Anchor present but the settled page continued further: re-anchor.
    local grown = "这句话是选中的起点从这里继续读到结尾，还有更多。"
    local anchored = Utils.reanchorFromHere(grown, captured)
    eq(anchored ~= nil and Utils.ws(anchored) ~= Utils.ws(captured), true,
        "reanchor re-slices CJK selection in settled page")

    -- Anchor absent (moved off-page): fall back to the settled page.
    local moved = Utils.reanchorFromHere("完全不同的一页内容。", "不在这里的一段话。")
    eq(moved, "完全不同的一页内容。", "reanchor falls back to settled page")

    -- Same text (nothing moved): keep the captured suffix.
    local same_page = "这句是选中的起点从这里继续。"
    eq(Utils.reanchorFromHere(same_page, same_page), nil,
        "reanchor keeps suffix when nothing moved")
end

print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
