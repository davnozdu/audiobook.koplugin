--[[--
MyTTS «Умная книга»: retellings of the open book by the MyTTS engine
(«Ранее в книге», «Предыдущая глава», «Эта глава», «Кто есть кто», «Чем закончится»).

The current page text goes to MyTTS with the command: MyTTS finds the book and
the exact place by its sentences, makes the retelling with its cloud LLM and
reads it aloud itself; KOReader stays on screen. Nothing is sent otherwise (no
page-turn or close events): an idle phone does nothing. MyTTS's own buttons know
the place from the text read aloud and from these commands. Android only; needs
MyTTS 5.0.6-beta13+.
--]]

local logger = require("logger")
local ffi = require("ffi")

local MyTTS = {
    PACKAGE = "com.davnozdu.supertonic.tts.fork",
    ACTIVITY = "com.brahmadeo.supertonic.tts.books.smart.SmartBookCommandActivity",
    MAX_TEXT = 6000,
    -- kind sent to MyTTS, menu label
    KINDS = {
        { "BEFORE", "Ранее в книге" },
        { "PREVIOUS", "Предыдущая глава" },
        { "CHAPTER", "Эта глава" },
        { "WHO", "Кто есть кто" },
        { "ENDING", "Чем закончится" },
    },
}

--- At most [limit] bytes of valid text for JNI's NewStringUTF: never a letter cut in half (that can abort KOReader), no
--- 4-byte characters (emoji are not modified UTF-8).
local function jniText(text, limit)
    text = text:gsub("[\240-\247][\128-\191][\128-\191][\128-\191]", "")
    if #text <= limit then return text end
    text = text:sub(1, limit)
    return (text:gsub("[\192-\255][\128-\191]*$", ""))
end
MyTTS.jniText = jniText

local function androidModule()
    local ok, android = pcall(require, "android")
    if ok and android and android.app and android.jni then return android end
    return nil
end

function MyTTS.available()
    return androidModule() ~= nil
end

--- Starts MyTTS's command activity with string extras; false when it could not be started (MyTTS not installed).
function MyTTS.send(extras)
    local android = androidModule()
    if not android then return false end
    local started = false
    local ok, err = pcall(function()
        android.jni:context(android.app.activity.vm, function(jni)
            local env = jni.env
            -- Every local reference of this call goes with the frame (the window asks once a second).
            env[0].PushLocalFrame(env, 64)
            local function jstr(s) return env[0].NewStringUTF(env, s) end
            local intent_class = env[0].FindClass(env, "android/content/Intent")
            local intent = env[0].NewObject(env, intent_class,
                env[0].GetMethodID(env, intent_class, "<init>", "()V"))
            local set_class = env[0].GetMethodID(env, intent_class, "setClassName",
                "(Ljava/lang/String;Ljava/lang/String;)Landroid/content/Intent;")
            local put_extra = env[0].GetMethodID(env, intent_class, "putExtra",
                "(Ljava/lang/String;Ljava/lang/String;)Landroid/content/Intent;")
            local add_flags = env[0].GetMethodID(env, intent_class, "addFlags", "(I)Landroid/content/Intent;")
            env[0].DeleteLocalRef(env, env[0].CallObjectMethod(env, intent, set_class, jstr(MyTTS.PACKAGE), jstr(MyTTS.ACTIVITY)))
            for key, value in pairs(extras) do
                env[0].DeleteLocalRef(env, env[0].CallObjectMethod(env, intent, put_extra, jstr(key), jstr(tostring(value))))
            end
            -- FLAG_ACTIVITY_NO_ANIMATION: the step is invisible.
            env[0].DeleteLocalRef(env, env[0].CallObjectMethod(env, intent, add_flags, ffi.new("int32_t", 0x00010000)))
            local activity = android.app.activity.clazz
            local activity_class = env[0].GetObjectClass(env, activity)
            local start = env[0].GetMethodID(env, activity_class, "startActivity", "(Landroid/content/Intent;)V")
            env[0].CallVoidMethod(env, activity, start, intent)
            if env[0].ExceptionCheck(env) ~= 0 then
                env[0].ExceptionClear(env)   -- ActivityNotFoundException: MyTTS is not installed
            else
                started = true
            end
            env[0].PopLocalFrame(env, nil)
        end)
    end)
    if not ok then logger.warn("MyTTS: command failed:", err) end
    return started
end

--- What MyTTS needs to find the book and the place: the page text and the book file.
function MyTTS.extras(plugin, kind)
    local extras = {}
    local ok, text = pcall(function() return plugin:getCurrentPageText() end)
    if ok and type(text) == "string" and text ~= "" then extras.text = jniText(text, MyTTS.MAX_TEXT) end
    local doc = plugin.ui and plugin.ui.document
    if doc and doc.file then extras.path = doc.file end
    if kind then extras.kind = kind end
    return extras
end

--- Reports the sentence whose audio has just started playing. MyTTS holds the scene and the sound cues of a
--- file request until this call, so background sounds land with the words and not with the request (the lookahead
--- already writes sentences ahead). One provider call per sentence; no window is opened.
function MyTTS.playing(text)
    if not text or text == "" then return false end
    return MyTTS.call("playing", jniText(text, 400)) ~= nil
end

--- MyTTS's SmartBookProvider: ContentResolver.call(method) → table of the Bundle's values, nil when MyTTS cannot be
--- reached (not installed, or not visible to KOReader). «state» returns title/book/stage/text/error and
--- running/speaking/paused (0/1); «pause», «resume», «stop», «replay» control the speech.
function MyTTS.call(method, arg)
    local android = androidModule()
    if not android then return nil end
    local result
    local ok, err = pcall(function()
        android.jni:context(android.app.activity.vm, function(jni)
            local env = jni.env
            -- Every local reference of this call goes with the frame (the window asks once a second).
            env[0].PushLocalFrame(env, 64)
            local function jstr(s) return env[0].NewStringUTF(env, s) end
            local function failed()
                if env[0].ExceptionCheck(env) ~= 0 then env[0].ExceptionClear(env); return true end
                return false
            end
            local activity = android.app.activity.clazz
            local activity_class = env[0].GetObjectClass(env, activity)
            local resolver = env[0].CallObjectMethod(env, activity, env[0].GetMethodID(env, activity_class,
                "getContentResolver", "()Landroid/content/ContentResolver;"))
            local uri_class = env[0].FindClass(env, "android/net/Uri")
            local uri = env[0].CallStaticObjectMethod(env, uri_class, env[0].GetStaticMethodID(env, uri_class,
                "parse", "(Ljava/lang/String;)Landroid/net/Uri;"), jstr("content://" .. MyTTS.PACKAGE .. ".smartbook"))
            local resolver_class = env[0].GetObjectClass(env, resolver)
            local call = env[0].GetMethodID(env, resolver_class, "call",
                "(Landroid/net/Uri;Ljava/lang/String;Ljava/lang/String;Landroid/os/Bundle;)Landroid/os/Bundle;")
            local null = ffi.cast("void*", nil)
            local bundle = env[0].CallObjectMethod(env, resolver, call, uri, jstr(method), arg and jstr(arg) or null, null)
            if failed() or bundle == nil or tonumber(ffi.cast("intptr_t", bundle)) == 0 then
                env[0].PopLocalFrame(env, nil)
                return
            end
            local bundle_class = env[0].GetObjectClass(env, bundle)
            local get_string = env[0].GetMethodID(env, bundle_class, "getString", "(Ljava/lang/String;)Ljava/lang/String;")
            local get_int = env[0].GetMethodID(env, bundle_class, "getInt", "(Ljava/lang/String;)I")
            result = {}
            for _i, key in ipairs({ "title", "book", "stage", "text", "error" }) do
                local value = env[0].CallObjectMethod(env, bundle, get_string, jstr(key))
                if value ~= nil and tonumber(ffi.cast("intptr_t", value)) ~= 0 then
                    local chars = env[0].GetStringUTFChars(env, value, nil)
                    result[key] = ffi.string(chars)
                    env[0].ReleaseStringUTFChars(env, value, chars)
                    env[0].DeleteLocalRef(env, value)
                else
                    result[key] = ""
                end
            end
            for _i, key in ipairs({ "running", "speaking", "paused", "questions" }) do
                result[key] = tonumber(env[0].CallIntMethod(env, bundle, get_int, jstr(key))) or 0
            end
            failed()
            env[0].PopLocalFrame(env, nil)
        end)
    end)
    if not ok then logger.warn("MyTTS: call", method, "failed:", err); return nil end
    return result
end

--- How far ahead the text goes: MyTTS keeps to its own «Упреждение» limit within it.
MyTTS.AHEAD_PAGES = 12
MyTTS.AHEAD_CHARS = 40000

--- The text from the top of this page about [AHEAD_PAGES] pages on (CRE books: by position, without turning pages);
--- otherwise this page and the next.
local function aheadText(plugin)
    local doc = plugin.ui and plugin.ui.document
    if not doc then return nil end
    if plugin.ui.rolling and doc.getTextFromXPointers and doc.getXPointer and doc.getPageXPointer then
        local ok, text = pcall(function()
            local from = doc:getXPointer()
            local page = doc:getCurrentPage()
            local last = math.min(page + MyTTS.AHEAD_PAGES, doc:getPageCount())
            local to = last > page and doc:getPageXPointer(last) or nil
            if not to then return nil end
            return doc:getTextFromXPointers(from, to)
        end)
        if ok and type(text) == "string" and #text > 200 then return text end
    end
    local ok, current = pcall(plugin.getCurrentPageText, plugin)
    if not ok or type(current) ~= "string" or current == "" then return nil end
    local ok_next, following = pcall(plugin.peekNextPageText, plugin)
    following = (ok_next and type(following) == "string") and following or ""
    -- A paragraph going on over the page is kept whole, so its sentences are found in it.
    local glue = current:match("[%.!%?…»\"]%s*$") and "\n" or " "
    return current .. glue .. following
end

--- The text about to be read aloud goes to MyTTS with the exact sentences this plugin will send: MyTTS prepares the
--- paragraphs by its LLM (stress, ё, punctuation, voices) and makes their audio ahead into its RAM cache, so each sentence
--- plays at once, also through a dropped connection while the buffer lasts. Only while reading aloud, on start and on
--- page turns; deferred so a page turn is not slowed. MyTTS skips what it already has.
local function alog(...)
    local DL = package.loaded["audiobook_debuglog"]
    if DL and DL.log then pcall(DL.log, ...) end
end

function MyTTS.ahead(plugin, tries)
    if not MyTTS.available() then alog("mytts-ahead no android module"); return end
    local UIManager = require("ui/uimanager")
    tries = tries or 0
    UIManager:scheduleIn(tries == 0 and 0.5 or 1, function()
        local sc = plugin.sync_controller
        -- Still well inside what MyTTS was given: no new extraction (12 pages of text and their parse on every page
        -- turn cost more than the turn itself). Sent again past the middle, or after a jump.
        local now_text = sc and sc.parsed_data and sc.parsed_data.sentences and sc.reading_sentence_idx
            and sc.parsed_data.sentences[sc.reading_sentence_idx]
        now_text = now_text and now_text.text
        if now_text and MyTTS._sent_index and MyTTS._sent_index[now_text]
                and MyTTS._sent_index[now_text] < (MyTTS._sent_count or 0) / 2 then
            return
        end
        if not (sc and sc.isPlaying and sc:isPlaying()) then
            -- Reading is starting (the engine loads, the first sentence is made): ask again, up to 20 s.
            if sc and sc.state == "loading" and tries < 20 then MyTTS.ahead(plugin, tries + 1); return end
            alog("mytts-ahead skip state", sc and tostring(sc.state) or "no controller")
            return
        end
        local text = aheadText(plugin)
        if not text then alog("mytts-ahead no text"); return end
        text = jniText(text, MyTTS.AHEAD_CHARS)
        if text == MyTTS._last_ahead then return end
        -- The sentences as this plugin parses them, from the one being read on (the ones before are already heard).
        local sentences = {}
        local parser = plugin.text_parser
        local ok_p, parsed = pcall(function() return parser and parser:parse(text) end)
        if ok_p and parsed and parsed.sentences then
            local current = sc.parsed_data and sc.parsed_data.sentences and sc.reading_sentence_idx
                and sc.parsed_data.sentences[sc.reading_sentence_idx]
            local from = 1
            if current and current.text then
                for i, sentence in ipairs(parsed.sentences) do
                    if sentence.text == current.text then from = i; break end
                end
            end
            for i = from, #parsed.sentences do
                local t = parsed.sentences[i].text
                if t and t ~= "" then table.insert(sentences, jniText(t, 4000)) end
            end
        end
        local ok_j, json = pcall(require, "json")
        if not ok_j or not json or not json.encode then
            alog("mytts-ahead no json module")
            return
        end
        local sent = MyTTS.call("prepare", json.encode({ text = text, sentences = sentences }))
        -- Not reached (MyTTS restarting after an update): the same page is sent again on the next call.
        if sent then
            MyTTS._last_ahead = text
            MyTTS._sent_index, MyTTS._sent_count = {}, #sentences
            for i, t in ipairs(sentences) do
                if MyTTS._sent_index[t] == nil then MyTTS._sent_index[t] = i end
            end
        end
        alog("mytts-ahead chars", #text, "sentences", #sentences, sent and "ok" or "unreachable")
    end)
end

--- «Спросить о книге»: [question] about the place being read, answered by MyTTS's cloud LLM from what has been read
--- (the page goes with it, and the sentence heard last for «объясни последнюю фразу»), shown and read in the window.
function MyTTS.ask(plugin, question)
    if not question or question:match("^%s*$") then return false end
    if plugin.pauseReadAlong then pcall(plugin.pauseReadAlong, plugin) end
    local extras = MyTTS.extras(plugin)
    if not extras.text then return false end
    extras.question = jniText(question, 1000)
    local sc = plugin.sync_controller
    local sentence = sc and sc.current_sentence and sc.current_sentence.text
    if sentence then extras.sentence = jniText(sentence, 2000) end
    extras.window = "1"
    if not MyTTS.send(extras) then return false end
    local UIManager = require("ui/uimanager")
    MyTTS._recap_seen = nil
    UIManager:scheduleIn(0.8, function() MyTTS.showWindow(plugin, "Вопрос о книге") end)
    return true
end

--- «Спросить о книге»: a field for the question, or the microphone (MyTTS listens and recognises it, GigaAM).
function MyTTS.askDialog(plugin)
    local UIManager = require("ui/uimanager")
    local InputDialog = require("ui/widget/inputdialog")
    local input
    input = InputDialog:new{
        title = "Спросить о книге",
        input_hint = "Например: почему героиня злится?",
        buttons = {{
            { text = "Отмена", id = "close", callback = function() UIManager:close(input) end },
            { text = "🎤 Голосом", callback = function()
                UIManager:close(input)
                MyTTS.askByVoice(plugin)
            end },
            { text = "Спросить", is_enter_default = true, callback = function()
                local q = input:getInputText()
                UIManager:close(input)
                MyTTS.ask(plugin, q)
            end },
        }},
    }
    UIManager:show(input)
    input:onShowKeyboard()
end

--- The question by voice: MyTTS opens its small listening window over KOReader, recognises the question and asks it;
--- the answer comes into this plugin's window as a typed one does.
function MyTTS.askByVoice(plugin)
    if plugin.pauseReadAlong then pcall(plugin.pauseReadAlong, plugin) end
    local extras = MyTTS.extras(plugin)
    if not extras.text then return false end
    local sc = plugin.sync_controller
    local sentence = sc and sc.current_sentence and sc.current_sentence.text
    if sentence then extras.sentence = jniText(sentence, 2000) end
    extras.voice = "1"
    extras.window = "1"
    if not MyTTS.send(extras) then return false end
    MyTTS._recap_seen = nil
    -- After listening (a few seconds) the answer is being made: the window follows it.
    require("ui/uimanager"):scheduleIn(1.5, function() MyTTS.showWindow(plugin, "Вопрос о книге", nil, 40) end)
    return true
end

--- Pause / resume / stop / replay of the retelling's speech: through the provider, else through the command activity.
function MyTTS.control(method)
    if MyTTS.call(method) == nil then MyTTS.send({ control = method }) end
end

--- KOReader's own window over the book: the retelling as it is written, and its speech controls. It asks MyTTS once a
--- second while the retelling is made or read, and stops asking when the window closes or the speech ends.
--- [on_done]: called once the retelling has been made and read (or failed), the window then closes by itself —
--- reading after a break goes on with the book.
function MyTTS.showWindow(plugin, label, on_done, wait_polls)
    local UIManager = require("ui/uimanager")
    local TextViewer = require("ui/widget/textviewer")
    local Screen = require("device").screen
    local viewer
    local open = true
    local state = MyTTS.call("state")
    local shown = ""

    local function body(s)
        if not s then return "MyTTS готовит пересказ и прочитает его вслух." end
        local parts = {}
        if s.stage ~= "" then table.insert(parts, s.stage) end
        if s.text ~= "" then table.insert(parts, s.text) elseif s.running == 1 then table.insert(parts, "Готовится…") end
        if s.error ~= "" then table.insert(parts, s.error) end
        return table.concat(parts, "\n\n")
    end

    local refresh
    local polls = 0
    local function act(method)
        MyTTS.control(method)
        UIManager:scheduleIn(0.3, function() refresh(true) end)
    end

    local function buttons(s)
        local speaking = s and s.speaking == 1
        local paused = s and s.paused == 1
        local done = s and s.running == 0 and s.text ~= ""
        return {
            {
                paused and { text = "Продолжить", callback = function() act("resume") end }
                    or { text = "Пауза", enabled = speaking, callback = function() act("pause") end },
                { text = "Стоп", enabled = speaking or (s and s.running == 1) or false, callback = function() act("stop") end },
                { text = "Слушать снова", enabled = done and not speaking or false, callback = function() act("replay") end },
            },
            {
                { text = "Продолжить чтение", callback = function()
                    MyTTS.control("stop")
                    open = false -- closed here, not through close_callback: no refresh may show it again
                    UIManager:close(viewer)
                    -- The book's own reading goes on (or starts from this page).
                    local sc = plugin.sync_controller
                    if sc and sc.isPaused and sc:isPaused() then pcall(plugin.resumeReadAlong, plugin)
                    elseif not (sc and sc.isPlaying and sc:isPlaying()) then pcall(plugin.startReadAlong, plugin) end
                end },
                { text = "Закрыть", callback = function() open = false; UIManager:close(viewer) end },
            },
        }
    end

    viewer = TextViewer:new{
        title = (state and state.title ~= "" and state.title) or label,
        text = body(state),
        height = math.floor(Screen:getHeight() * 0.7),
        buttons_table = buttons(state),
        add_default_buttons = false,
        close_callback = function() open = false end,
    }
    shown = viewer.text .. tostring(state and state.speaking) .. tostring(state and state.paused)
    UIManager:show(viewer)

    refresh = function(force)
        if not open then return end
        local s = MyTTS.call("state")
        local text = body(s)
        local key = text .. tostring(s and s.speaking) .. tostring(s and s.paused)
        if force or key ~= shown then
            shown = key
            viewer.text = text
            viewer.title = (s and s.title ~= "" and s.title) or label
            viewer.buttons_table = buttons(s)
            -- The answer grows while it is written: the place the listener scrolled to stays (reinit starts at the top).
            local ok_r, low = pcall(function() return (viewer.scroll_widget.text_widget:getVisibleHeightRatios()) end)
            viewer:reinit()
            if ok_r and low and low > 0 then pcall(function() viewer.scroll_widget:scrollToRatio(low) end) end
        end
        -- Asked only while something is made or read; a closed window or a finished retelling costs nothing.
        -- The first seconds always: the new retelling may not have started yet when the window opens.
        polls = polls + 1
        if on_done and open then
            if s and (s.running == 1 or s.speaking == 1) then MyTTS._recap_seen = true end
            local over = (s and s.running == 0 and s.speaking == 0 and s.paused == 0 and (MyTTS._recap_seen or s.error ~= ""))
                or (not s and polls >= 5)
            if over and polls >= 3 then
                open = false
                UIManager:close(viewer)
                MyTTS._recap_seen = nil
                pcall(on_done)
                return
            end
            if s and polls >= 5 and s.running == 0 and s.speaking == 0 and not MyTTS._recap_seen then
                -- Nothing started (the book is not in MyTTS's «Умная книга»): go on reading.
                open = false
                UIManager:close(viewer)
                pcall(on_done)
                return
            end
        end
        -- Paused: nothing changes until a button here or in the notification, so rarely.
        -- [wait_polls]: a voice question is still being said and recognised in MyTTS's window — keep asking longer.
        if (s or on_done) and (polls < (wait_polls or 5) or (s and (s.running == 1 or s.speaking == 1))) then
            UIManager:scheduleIn((s and s.paused == 1 and s.running == 0) and 5 or 1, function() refresh(false) end)
        end
    end
    UIManager:scheduleIn(1, function() refresh(false) end)
end

--- A retelling: the plugin's own reading pauses first (MyTTS reads the retelling with the same engine), then KOReader
--- shows its window with the text and the controls.
function MyTTS.recap(plugin, kind, on_done)
    if plugin.pauseReadAlong then pcall(plugin.pauseReadAlong, plugin) end
    local extras = MyTTS.extras(plugin, kind)
    if not extras.text then
        logger.warn("MyTTS: no page text for the retelling")
        return false
    end
    extras.window = "1"
    if not MyTTS.send(extras) then return false end
    local label = kind
    for _i, k in ipairs(MyTTS.KINDS) do if k[1] == kind then label = k[2] end end
    local UIManager = require("ui/uimanager")
    -- After MyTTS's invisible step has finished and KOReader is in front again.
    MyTTS._recap_seen = nil
    UIManager:scheduleIn(0.8, function() MyTTS.showWindow(plugin, label, on_done) end)
    return true
end

return MyTTS
