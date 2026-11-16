--[[--
Menu builder functions for the Audiobook plugin.
Pure factory functions that return KOReader menu item tables.

All functions take `plugin` (the Audiobook WidgetContainer instance)
as their first parameter to access settings and engine state.

@module menubuilder
--]]

local _ = require("audiobook_gettext")
local T = require("ffi/util").template
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("logger")

-- Shared utility module
local _dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
local Utils = dofile(_dir .. "utils.lua")

local MenuBuilder = {}

--[[--
Friendly name of Android's preferred TTS engine (SherpaTTS, Google, ...).
@return string|nil
--]]
function MenuBuilder.androidSystemEngineName(plugin)
    local engine = plugin and plugin.tts_engine
    if not engine or not engine.androidEngineDisplayName then
        return nil
    end
    return engine:androidEngineDisplayName()
end

function MenuBuilder.buildVoiceSettingsMenu(plugin)
    local menu = {}
    table.insert(menu, {
        text_func = function()
            return T(_("TTS engine: %1"), MenuBuilder.androidSystemEngineName(plugin) or _("System TTS"))
        end,
        enabled = false,
        help_text = _("The system's preferred text-to-speech engine (Android settings → Text-to-speech)."),
    })
    do
        table.insert(menu, {
            text_func = function()
                local label = plugin:getSetting("android_tts_voice_label", "")
                if label ~= "" then
                    return T(_("Voice: %1"), label)
                end
                local lang = plugin:getSetting("android_tts_language", "auto")
                if lang == "auto" then
                    return T(_("Voice: %1"), _("Auto-detect"))
                end
                return T(_("Voice: %1"), lang)
            end,
            callback = function(touchmenu_instance)
                if touchmenu_instance then
                    touchmenu_instance:closeMenu()
                end
                MenuBuilder.showVoicePicker(plugin)
            end,
            help_text = _(
                "Pick a language from the HuggingFace catalog, or an installed "
                .. "Android TTS voice. Neural voices on Android come from the "
                .. "system TTS engine (Google, SherpaTTS, …)."
            ),
        })
    end
    -- The engine queue reads with the engine's own pauses: MyTTS ends sentences and paragraphs itself.
    -- Speech rate submenu
    table.insert(menu, {
        text_func = function()
            return T(_("Speech rate: %1x"), plugin:getSetting("speech_rate", 1.0))
        end,
        sub_item_table = MenuBuilder.buildSpeechRateMenu(plugin),
    })

    table.insert(menu, {
        text_func = function()
            return T(_("Pitch: %1"), plugin:getSetting("speech_pitch", 50))
        end,
        sub_item_table = MenuBuilder.buildPitchMenu(plugin),
    })

    table.insert(menu, {
        text_func = function()
            local v = plugin:getSetting("heading_pause", 1.5)
            return v > 0 and T(_("Pause after a chapter heading: %1 s"), v) or _("Pause after a chapter heading: off")
        end,
        sub_item_table = (function()
            local items = {}
            for _i, v in ipairs({0, 1, 1.5, 2, 3}) do
                table.insert(items, {
                    text = v > 0 and T(_("%1 s"), v) or _("Off"),
                    checked_func = function() return plugin:getSetting("heading_pause", 1.5) == v end,
                    callback = function() plugin:setSetting("heading_pause", v) end,
                })
            end
            return items
        end)(),
        help_text = _("Silence after a chapter heading («Глава вторая», «VI»), so the heading is heard apart from the text. Works with any TTS engine."),
    })

    -- Size of the bottom bar (MyTTS fork): bigger buttons on a phone. Takes effect when reading starts next.
    table.insert(menu, {
        text_func = function()
            return T(_("Bottom bar size: %1×"), plugin:getSetting("mini_bar_scale", 2))
        end,
        sub_item_table = (function()
            local items = {}
            for _i, v in ipairs({1, 1.5, 2, 2.5, 3}) do
                table.insert(items, {
                    text = tostring(v) .. "×",
                    checked_func = function() return plugin:getSetting("mini_bar_scale", 2) == v end,
                    callback = function() plugin:setSetting("mini_bar_scale", v) end,
                })
            end
            return items
        end)(),
        help_text = _("Height and font of the player bar at the bottom of the page. Takes effect the next time reading aloud starts."),
    })

    -- Headset «previous» and the return to the page being read (MyTTS fork).
    table.insert(menu, {
        text_func = function()
            local v = plugin:getSetting("headset_prev", 15)
            return T(_("Headset «previous»: %1"), v == "item" and _("previous sentence") or T(_("back %1 s"), v))
        end,
        sub_item_table = (function()
            local items = {}
            for _i, v in ipairs({15, 30, "item"}) do
                table.insert(items, {
                    text = v == "item" and _("previous sentence (chapter of an audiobook)") or T(_("back %1 s"), v),
                    checked_func = function() return plugin:getSetting("headset_prev", 15) == v end,
                    callback = function() plugin:setSetting("headset_prev", v) end,
                })
            end
            return items
        end)(),
    })
    -- «Ранее в книге» after a long break: off unless the listener turns it on; the break is chosen here.
    table.insert(menu, {
        text_func = function()
            if not plugin:getSetting("recap_after_break", false) then return _("«Previously in the book» after a break: off") end
            return T(_("«Previously in the book» after a break: %1 days"), plugin:getSetting("recap_break_days", 5))
        end,
        sub_item_table = (function()
            local items = { {
                text = _("Off"),
                checked_func = function() return not plugin:getSetting("recap_after_break", false) end,
                callback = function() plugin:setSetting("recap_after_break", false) end,
            } }
            for _i, d in ipairs({5, 7, 14, 30}) do
                table.insert(items, {
                    text = T(_("after %1 days"), d),
                    checked_func = function()
                        return plugin:getSetting("recap_after_break", false) and plugin:getSetting("recap_break_days", 5) == d
                    end,
                    callback = function() plugin:setSetting("recap_break_days", d); plugin:setSetting("recap_after_break", true) end,
                })
            end
            return items
        end)(),
        help_text = _("When the book was not listened to for this long, MyTTS first retells what happened before (one cloud request), then reading goes on. Only for books MyTTS knows («Умная книга»)."),
    })
    table.insert(menu, {
        text_func = function()
            return plugin:getSetting("headset_next", "announce") == "announce"
                and _("Headset «next»: time left in the chapter") or _("Headset «next»: next sentence")
        end,
        sub_item_table = {
            {
                text = _("Say how much is left of the chapter"),
                checked_func = function() return plugin:getSetting("headset_next", "announce") == "announce" end,
                callback = function() plugin:setSetting("headset_next", "announce") end,
            },
            {
                text = _("next sentence (chapter of an audiobook)"),
                checked_func = function() return plugin:getSetting("headset_next", "announce") == "item" end,
                callback = function() plugin:setSetting("headset_next", "item") end,
            },
        },
        help_text = _("A double press on most headsets. The book pauses, the engine says how long the chapter still lasts, then reading goes on."),
    })
    table.insert(menu, {
        text = _("Return to the page being read after a minute"),
        checked_func = function() return plugin:getSetting("auto_return", true) end,
        callback = function() plugin:setSetting("auto_return", not plugin:getSetting("auto_return", true)) end,
        help_text = _("Browsed away while reading aloud and left it there: after a minute without page turns the book goes back to the page being read. Not while paused."),
    })

    return menu
end

function MenuBuilder.buildSpeechRateMenu(plugin)
    local rates = {0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0}
    local menu = {}

    for _i, rate in ipairs(rates) do
        table.insert(menu, {
            text = string.format("%.2fx", rate),
            checked_func = function()
                return plugin:getSetting("speech_rate", 1.0) == rate
            end,
            callback = function()
                if plugin.sync_controller then
                    plugin.sync_controller:setSpeechRate(rate)
                else
                    plugin:setSetting("speech_rate", rate)
                    plugin.tts_engine:setRate(rate)
                end
            end,
        })
    end

    return menu
end

function MenuBuilder.buildPitchMenu(plugin)
    -- 0–99, 50 = the engine's natural pitch
    local pitches = {0, 10, 20, 30, 40, 50, 60, 70, 80, 99}
    local labels = {
        [0] = _("0 (very low)"),
        [10] = "10", [20] = "20", [30] = "30", [40] = "40",
        [50] = _("50 (default)"),
        [60] = "60", [70] = "70", [80] = "80",
        [99] = _("99 (very high)"),
    }
    local menu = {}
    for _i, p in ipairs(pitches) do
        table.insert(menu, {
            text = labels[p] or tostring(p),
            checked_func = function()
                return plugin:getSetting("speech_pitch", 50) == p
            end,
            callback = function()
                plugin:setSetting("speech_pitch", p)
                plugin.tts_engine:setPitch(p)
            end,
        })
    end
    return menu
end

function MenuBuilder.buildHighlightStyleMenu(plugin)
    local styles = {
        { id = "background", text = _("Background highlight") },
        { id = "underline", text = _("Underline") },
        { id = "box", text = _("Box border") },
        { id = "invert", text = _("Invert colors") },
    }
    local menu = {}

    for _, style in ipairs(styles) do
        table.insert(menu, {
            text = style.text,
            checked_func = function()
                return plugin:getSetting("highlight_style", "background") == style.id
            end,
            callback = function()
                plugin:setSetting("highlight_style", style.id)
                plugin.highlight_manager:setStyle(style.id)
            end,
        })
    end

    return menu
end

function MenuBuilder.huggingfaceLanguageChoices()
    return {
        { id = "fr-FR", label = _("French") },
        { id = "en-US", label = _("English (US)") },
        { id = "en-GB", label = _("English (UK)") },
        { id = "es-ES", label = _("Spanish") },
        { id = "de-DE", label = _("German") },
        { id = "it-IT", label = _("Italian") },
        { id = "pt-BR", label = _("Portuguese (Brazil)") },
        { id = "nl-NL", label = _("Dutch") },
        { id = "pl-PL", label = _("Polish") },
        { id = "cs-CZ", label = _("Czech") },
        { id = "sk-SK", label = _("Slovak") },
        { id = "uk-UA", label = _("Ukrainian") },
        { id = "hi-IN", label = _("Hindi") },
        { id = "ar-JO", label = _("Arabic") },
        { id = "ca-ES", label = _("Catalan") },
        { id = "zh-CN", label = _("Chinese (Simplified)") },
        { id = "zh-TW", label = _("Chinese (Traditional)") },
        { id = "ja-JP", label = _("Japanese") },
        { id = "ko-KR", label = _("Korean") },
        { id = "da-DK", label = _("Danish") },
        { id = "fi-FI", label = _("Finnish") },
        { id = "ru-RU", label = _("Russian") },
        { id = "el-GR", label = _("Greek") },
        { id = "no-NO", label = _("Norwegian") },
        { id = "sv-SE", label = _("Swedish") },
        { id = "tr-TR", label = _("Turkish") },
        { id = "hu-HU", label = _("Hungarian") },
        { id = "ro-RO", label = _("Romanian") },
    }
end

local function _localePrefix(tag)
    if not tag or tag == "" then return "" end
    return (tag:lower():gsub("_", "-"):match("^(%a+)") or tag:lower())
end

function MenuBuilder._androidVoiceLabel(voice)
    local loc = voice.locale or ""
    local lang_label = loc
    for _, choice in ipairs(MenuBuilder.huggingfaceLanguageChoices()) do
        if choice.id:lower() == loc:lower()
            or _localePrefix(choice.id) == _localePrefix(loc) then
            lang_label = choice.label
            break
        end
    end
    local net = voice.network and _("online") or _("offline")
    if lang_label ~= "" then
        return T(_("%1 · %2 (%3)"), lang_label, voice.name, net)
    end
    return T(_("%1 (%2)"), voice.name, net)
end

function MenuBuilder.applyTtsLanguage(plugin, lang, label)
    plugin:setSetting("android_tts_language", lang)
    plugin:setSetting("android_tts_voice", "")
    plugin:setSetting("android_tts_voice_label", label or lang)
    if plugin.tts_engine and plugin.tts_engine.invalidateAndroidVoice then
        plugin.tts_engine:invalidateAndroidVoice()
    end
    local atts = plugin.tts_engine and plugin.tts_engine._android_tts
    if atts and atts.setLanguage and lang and lang ~= "auto" then
        pcall(function() atts:setLanguage(lang) end)
        plugin.tts_engine._android_tts_lang = lang
        plugin.tts_engine._android_tts_voice = nil
    end
    UIManager:show(InfoMessage:new{
        text = T(_("Voice set to %1."), label or lang),
        timeout = 2,
    })
end

function MenuBuilder.applyAndroidInstalledVoice(plugin, voice)
    local label = MenuBuilder._androidVoiceLabel(voice)
    plugin:setSetting("android_tts_voice", voice.name)
    if voice.locale and voice.locale ~= "" then
        plugin:setSetting("android_tts_language", voice.locale)
    end
    plugin:setSetting("android_tts_voice_label", label)
    if plugin.tts_engine and plugin.tts_engine.invalidateAndroidVoice then
        plugin.tts_engine:invalidateAndroidVoice()
    end
    local atts = plugin.tts_engine and plugin.tts_engine._android_tts
    if atts and atts.setVoice then
        pcall(function() atts:setVoice(voice.name) end)
        plugin.tts_engine._android_tts_voice = voice.name
        plugin.tts_engine._android_tts_lang = "voice:" .. voice.name
    end
    UIManager:show(InfoMessage:new{
        text = T(_("Voice set to %1."), label),
        timeout = 2,
    })
end

--[[--
Paginated ButtonDialog picker.  Full Menu widgets have crashed on Boox;
this is the same pattern as the chapter list.
--]]
function MenuBuilder.showPagedPicker(opts)
    local items = opts.items or {}
    if #items == 0 then
        UIManager:show(InfoMessage:new{
            text = opts.empty_text or _("No voices found."),
            timeout = 3,
        })
        return
    end
    local ok_bd, ButtonDialog = pcall(require, "ui/widget/buttondialog")
    if not ok_bd or not ButtonDialog then
        logger.err("MenuBuilder: ButtonDialog unavailable:", ButtonDialog)
        UIManager:show(InfoMessage:new{
            text = _("Could not open voice list."),
            timeout = 4,
        })
        return
    end

    local PAGE_SIZE = 8
    local page = 1
    local current = tonumber(opts.current) or 1
    if current < 1 then current = 1 end
    if current > #items then current = #items end
    page = math.floor((current - 1) / PAGE_SIZE) + 1

    local dialog
    local function close_picker()
        if dialog then
            pcall(function() UIManager:close(dialog) end)
        end
        dialog = nil
    end

    local function show_page()
        local total_pages = math.max(1, math.ceil(#items / PAGE_SIZE))
        if page < 1 then page = 1 end
        if page > total_pages then page = total_pages end
        local first = (page - 1) * PAGE_SIZE + 1
        local last = math.min(#items, page * PAGE_SIZE)

        local buttons = {}
        for i = first, last do
            local item = items[i]
            if item then
                local label = tostring(item.text or (_("Item") .. " " .. i))
                if #label > 80 then
                    label = label:sub(1, 77) .. "..."
                end
                if i == current then
                    label = "> " .. label
                end
                local cb = item.callback
                local enabled = item.enabled
                if enabled == nil then enabled = (cb ~= nil) end
                table.insert(buttons, {{
                    text = label,
                    enabled = enabled,
                    callback = function()
                        if not cb then return end
                        close_picker()
                        UIManager:scheduleIn(0.1, function()
                            pcall(cb)
                        end)
                    end,
                }})
            end
        end

        table.insert(buttons, {
            {
                text = _("Prev"),
                enabled = page > 1,
                callback = function()
                    page = page - 1
                    close_picker()
                    UIManager:scheduleIn(0.05, show_page)
                end,
            },
            {
                text = _("Close"),
                callback = close_picker,
            },
            {
                text = _("Next"),
                enabled = page < total_pages,
                callback = function()
                    page = page + 1
                    close_picker()
                    UIManager:scheduleIn(0.05, show_page)
                end,
            },
        })

        local title = string.format("%s (%d/%d)",
            tostring(opts.title or _("Select voice")), page, total_pages)
        local ok, err = pcall(function()
            dialog = ButtonDialog:new{
                title = title,
                buttons = buttons,
            }
            UIManager:show(dialog)
        end)
        if not ok then
            logger.err("MenuBuilder: voice ButtonDialog failed:", err)
            UIManager:show(InfoMessage:new{
                text = _("Could not open voice list.") .. "\n" .. tostring(err),
                timeout = 6,
            })
        end
    end

    UIManager:scheduleIn(0.15, function()
        local ok, err = pcall(show_page)
        if not ok then
            logger.err("MenuBuilder: voice picker failed:", err)
            UIManager:show(InfoMessage:new{
                text = _("Could not open voice list.") .. "\n" .. tostring(err),
                timeout = 6,
            })
        end
    end)
end

function MenuBuilder._androidVoicePickerItems(plugin)
    local items = {}
    local current_voice = plugin:getSetting("android_tts_voice", "")
    local current_lang = plugin:getSetting("android_tts_language", "auto")
    local current_idx = 1

    table.insert(items, {
        text = _("Auto (book language)"),
        callback = function()
            MenuBuilder.applyTtsLanguage(plugin, "auto", _("Auto-detect"))
        end,
    })
    if current_voice == "" and current_lang == "auto" then
        current_idx = #items
    end

    -- Installed voices first: an engine's own voices (MyTTS «Мультиголос» / «Один голос») were
    -- listed after every language and took many pages to reach.
    local book_lang
    if plugin.tts_engine and plugin.tts_engine._androidBookLanguage then
        book_lang = plugin.tts_engine:_androidBookLanguage()
    end
    local voices = {}
    if plugin.tts_engine and plugin.tts_engine.listAndroidVoices then
        voices = plugin.tts_engine:listAndroidVoices() or {}
    end
    if #voices > 0 then
        table.insert(items, {
            text = "- " .. _("Installed voices") .. " -",
            enabled = false,
        })
        local prefer = current_lang ~= "auto" and current_lang or book_lang or ""
        table.sort(voices, function(a, b)
            local function rank(v)
                local r = 2
                if prefer ~= "" and v.locale
                    and _localePrefix(v.locale) == _localePrefix(prefer) then
                    r = 0
                end
                if v.network then r = r + 1 end
                return r, -(v.quality or 0), v.name or ""
            end
            local ra, qa, na = rank(a)
            local rb, qb, nb = rank(b)
            if ra ~= rb then return ra < rb end
            if qa ~= qb then return qa < qb end
            return na < nb
        end)
        for _, voice in ipairs(voices) do
            table.insert(items, {
                text = MenuBuilder._androidVoiceLabel(voice),
                callback = function()
                    MenuBuilder.applyAndroidInstalledVoice(plugin, voice)
                end,
            })
            if current_voice ~= "" and current_voice == voice.name then
                current_idx = #items
            end
        end
    end

    table.insert(items, {
        text = "- " .. _("Languages") .. " -",
        enabled = false,
    })

    local langs = MenuBuilder.huggingfaceLanguageChoices()
    -- Book language first so a French EPUB surfaces French immediately.
    table.sort(langs, function(a, b)
        local function rank(c)
            if book_lang and (c.id:lower() == book_lang:lower()
                or _localePrefix(c.id) == _localePrefix(book_lang)) then
                return 0
            end
            return 1
        end
        local ra, rb = rank(a), rank(b)
        if ra ~= rb then return ra < rb end
        return a.label < b.label
    end)
    for _, choice in ipairs(langs) do
        table.insert(items, {
            text = choice.label,
            callback = function()
                MenuBuilder.applyTtsLanguage(plugin, choice.id, choice.label)
            end,
        })
        if current_voice == "" and current_lang:lower() == choice.id:lower() then
            current_idx = #items
        end
    end

    return items, current_idx
end

function MenuBuilder.showVoicePicker(plugin)
    if not plugin or not plugin.tts_engine then
        UIManager:show(InfoMessage:new{ text = _("TTS engine is not available."), timeout = 3 })
        return
    end
    local info = InfoMessage:new{ text = _("Loading voices…"), timeout = 0 }
    UIManager:show(info)
    UIManager:scheduleIn(0.05, function()
        local items, current = MenuBuilder._androidVoicePickerItems(plugin)
        UIManager:close(info)
        MenuBuilder.showPagedPicker({ title = _("Select voice"), items = items, current = current })
    end)
end

local function _valuePicker(title, values, current, format_fn, apply_fn)
    local items = {}
    local current_idx = 1
    for i, v in ipairs(values) do
        table.insert(items, {
            text = format_fn(v),
            callback = function() apply_fn(v) end,
        })
        if current == v then current_idx = i end
    end
    MenuBuilder.showPagedPicker({
        title = title,
        items = items,
        current = current_idx,
    })
end

--[[--
TTS settings from the playback overlay: voice, speed,
sentence/paragraph pauses, volume.
--]]
function MenuBuilder.showTtsSettingsPicker(plugin)
    if not plugin or not plugin.tts_engine then
        UIManager:show(InfoMessage:new{
            text = _("TTS engine is not available."),
            timeout = 3,
        })
        return
    end
    local voice_label = plugin:getSetting("android_tts_voice_label", "")
    if voice_label == "" then
        local lang = plugin:getSetting("android_tts_language", "auto")
        voice_label = (lang == "auto") and _("Auto-detect") or lang
    end
    local items = {}
    table.insert(items, {
        text = T(_("Voice: %1"), voice_label),
        callback = function()
            MenuBuilder.showVoicePicker(plugin)
        end,
    })
    table.insert(items, {
        text = T(_("Speech rate: %1x"), plugin:getSetting("speech_rate", 1.0)),
        callback = function()
            _valuePicker(_("Speech rate"), {0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0},
                plugin:getSetting("speech_rate", 1.0),
                function(v) return string.format("%.2fx", v) end,
                function(v)
                    -- Route through the sync controller where possible: it
                    -- updates the engine, the bar, and re-reads the current
                    -- sentence so the new rate is heard immediately.
                    if plugin.sync_controller and plugin.sync_controller.setSpeechRate then
                        plugin.sync_controller:setSpeechRate(v)
                    else
                        plugin:setSetting("speech_rate", v)
                        if plugin.tts_engine then plugin.tts_engine:setRate(v) end
                        if plugin.sync_controller and plugin.sync_controller.playback_bar
                            and plugin.sync_controller.playback_bar.updateSpeed then
                            pcall(function()
                                plugin.sync_controller.playback_bar:updateSpeed(v)
                            end)
                        end
                    end
                    UIManager:show(InfoMessage:new{
                        text = T(_("Speech rate: %1x"), v),
                        timeout = 1.5,
                    })
                end)
        end,
    })
    -- Sleep timer.  TTS has no full-screen player, so this menu is where the
    -- timer lives during read-along.
    table.insert(items, {
        text = _("Sleep timer"),
        callback = function()
            if plugin._showSleepTimerDialog then
                plugin:_showSleepTimerDialog()
            end
        end,
    })
    table.insert(items, {
        text = _("Sleep timer: until the end of the chapter"),
        callback = function()
            if plugin._startChapterSleep then plugin:_startChapterSleep() end
        end,
    })
    MenuBuilder.showPagedPicker({
        title = _("TTS settings"),
        items = items,
    })
end

return MenuBuilder
