--[[--
Ring-buffer + on-disk debug log for audiobook.koplugin.

Included in bug reports so Android/Boox issues can be diagnosed without
adb logcat.  No book text is logged — only short diagnostic strings.

@module debuglog
--]]

local DebugLog = {}

local MAX_LINES = 250
local MAX_FILE_BYTES = 180 * 1024
-- По умолчанию лог только в памяти: каждая строка раньше сразу шла в debug.log на флеш,
-- а строки пишутся на каждое предложение. Файл включается настройкой «Журнал плагина».
local _on_disk = false
local _lines = {}
local _path = nil
local _initialized = false

local function ensureDir(path)
    -- Best-effort mkdir for the parent of path.
    local dir = path:match("^(.*)/[^/]+$")
    if not dir or dir == "" then return end
    os.execute('mkdir -p "' .. dir:gsub('"', '\\"') .. '" 2>/dev/null')
end

--- Initialize log path (call once from plugin init).
-- @param plugin_dir string
--- Включать/выключать запись на флеш. По умолчанию выключена: память дешёвая, флеш — нет.
function DebugLog.setOnDisk(enabled)
    _on_disk = enabled == true
end

function DebugLog.init(plugin_dir)
    if not plugin_dir or plugin_dir == "" then return end
    plugin_dir = plugin_dir:gsub("//+", "/"):gsub("/+$", "")
    _path = plugin_dir .. "/debug.log"
    ensureDir(_path)
    -- Truncate if the file grew too large.
    local f = io.open(_path, "r")
    if f then
        local size = f:seek("end")
        f:close()
        if size and size > MAX_FILE_BYTES then
            os.remove(_path)
        end
    end
    _initialized = true
    DebugLog.log("DebugLog: ready path=", _path, "disk=", tostring(_on_disk))
end

--- Append a debug line (also kept in memory for bug reports).
function DebugLog.log(...)
    local n = select("#", ...)
    local parts = {}
    for i = 1, n do
        parts[i] = tostring(select(i, ...))
    end
    local line = os.date("!%Y-%m-%dT%H:%M:%SZ ") .. table.concat(parts, " ")
    _lines[#_lines + 1] = line
    while #_lines > MAX_LINES do
        table.remove(_lines, 1)
    end
    if _path and _on_disk then
        local f = io.open(_path, "a")
        if f then
            f:write(line, "\n")
            f:close()
        end
    end
end

--- A line with book text (queued sentences): written to debug.log only while «debug.on» is present,
-- never kept in the in-memory ring that goes into bug reports.
function DebugLog.text(...)
    if not (_path and _on_disk) then return end
    local n = select("#", ...)
    local parts = {}
    for i = 1, n do parts[i] = tostring(select(i, ...)) end
    local f = io.open(_path, "a")
    if f then
        f:write(os.date("!%Y-%m-%dT%H:%M:%SZ "), table.concat(parts, " "), "\n")
        f:close()
    end
end

--- Return the in-memory tail (and last lines from disk if memory is empty).
-- @param max_lines number|nil
-- @return string
function DebugLog.tail(max_lines)
    max_lines = max_lines or 120
    if #_lines > 0 then
        local start = math.max(1, #_lines - max_lines + 1)
        return table.concat(_lines, "\n", start, #_lines)
    end
    if not _path then return "(no debug log yet)" end
    local f = io.open(_path, "r")
    if not f then return "(debug.log not found)" end
    local content = f:read("*a") or ""
    f:close()
    if content == "" then return "(debug.log empty)" end
    local collected = {}
    for line in content:gmatch("[^\n]+") do
        collected[#collected + 1] = line
    end
    local start = math.max(1, #collected - max_lines + 1)
    return table.concat(collected, "\n", start, #collected)
end

function DebugLog.path()
    return _path
end

function DebugLog.isReady()
    return _initialized and _path ~= nil
end

return DebugLog
