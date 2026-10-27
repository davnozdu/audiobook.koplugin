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
            env[0].DeleteLocalRef(env, activity_class)
            env[0].DeleteLocalRef(env, intent)
            env[0].DeleteLocalRef(env, intent_class)
        end)
    end)
    if not ok then logger.warn("MyTTS: command failed:", err) end
    return started
end

--- What MyTTS needs to find the book and the place: the page text and the book file.
function MyTTS.extras(plugin, kind)
    local extras = {}
    local ok, text = pcall(function() return plugin:getCurrentPageText() end)
    if ok and type(text) == "string" and text ~= "" then extras.text = text:sub(1, MyTTS.MAX_TEXT) end
    local doc = plugin.ui and plugin.ui.document
    if doc and doc.file then extras.path = doc.file end
    if kind then extras.kind = kind end
    return extras
end

--- A retelling: the plugin's own reading pauses first (MyTTS reads the retelling with the same engine).
function MyTTS.recap(plugin, kind)
    if plugin.pauseReadAlong then pcall(plugin.pauseReadAlong, plugin) end
    local extras = MyTTS.extras(plugin, kind)
    if not extras.text then
        logger.warn("MyTTS: no page text for the retelling")
        return false
    end
    return MyTTS.send(extras)
end

return MyTTS
