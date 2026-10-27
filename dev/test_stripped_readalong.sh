#!/usr/bin/env bash
# Host test for Audiobook:_documentIsStrippedReadalong (main.lua).
#
# BookOrbit's text-only delivery keeps storyteller-readaloud.css and the
# sentence markup but strips audio and SMIL, so "stylesheet present, SMIL
# absent" identifies a read-along that arrived without its narration. This
# script builds synthetic EPUB fixtures and asserts the detection decision
# used by main.lua on each of them.
#
# Usage: bash dev/test_stripped_readalong.sh
# Needs: python3, unzip, and luajit (nix shell nixpkgs#luajit if absent).
set -u

fail=0
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Fixture builder: mimetype stored first, rest deflated (python3 stdlib).
make_epub() {
    local out="$1"; shift
    python3 - "$out" "$@" <<'PYEOF'
import sys, zipfile
out = sys.argv[1]
members = sys.argv[2:]
with zipfile.ZipFile(out, "w") as z:
    z.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip", zipfile.ZIP_STORED)
    for name in members:
        parts = name.split(":")
        arcname = parts[0]
        body = parts[1] if len(parts) > 1 else "<html/>"
        z.writestr(arcname, body, zipfile.ZIP_DEFLATED)
PYEOF
}

CSS='OEBPS/storyteller-readaloud.css:/* readaloud */'
SMIL='OEBPS/ch1.smil:<smil xmlns="http://www.w3.org/ns/SMIL" version="3.0"/>'

make_epub "$work/stripped.epub" "$CSS" "OEBPS/ch1.xhtml"
make_epub "$work/original.epub" "$CSS" "$SMIL" "OEBPS/ch1.xhtml"
make_epub "$work/plain.epub" "OEBPS/ch1.xhtml"
make_epub "$work/with space.epub" "$CSS" "OEBPS/ch1.xhtml"

cat > "$work/detect.lua" <<'LUAEOF'
-- Same decision logic as main.lua:_documentHasMediaOverlays plus
-- Audiobook:_documentIsStrippedReadalong, verbatim popen pipeline.
local function has_overlays(path)
    local h = io.popen('unzip -l "' .. path:gsub('"', '\\"') .. '" 2>/dev/null | grep -i "\\.smil"')
    if h then
        local out = h:read("*a") or ""
        h:close()
        if out:match("%.smil") then return true end
    end
    return false
end
local function stripped(path)
    if has_overlays(path) then return false end
    local h = io.popen('unzip -l "' .. path:gsub('"', '\\"') .. '" 2>/dev/null | grep -i "storyteller-readaloud.css"')
    if h then
        local out = h:read("*a") or ""
        h:close()
        return out:lower():find("storyteller-readaloud.css", 1, true) ~= nil
    end
    return false
end
for _, c in ipairs({
    { path = arg[1], overlays = false, stripped = true  },
    { path = arg[2], overlays = true,  stripped = false },
    { path = arg[3], overlays = false, stripped = false },
    { path = arg[4], overlays = false, stripped = true  },
}) do
    local o, s = has_overlays(c.path), stripped(c.path)
    if o == c.overlays and s == c.stripped then
        print("ok    " .. c.path:gsub(".*/", "") .. " overlays=" .. tostring(o) .. " stripped=" .. tostring(s))
    else
        print("FAIL  " .. c.path:gsub(".*/", "") .. " overlays=" .. tostring(o) .. " stripped=" .. tostring(s))
        os.exit(1)
    end
end
LUAEOF

run_luajit() {
    if command -v luajit >/dev/null 2>&1; then
        luajit "$@"
    else
        nix shell nixpkgs#luajit -c luajit "$@"
    fi
}

run_luajit "$work/detect.lua" \
    "$work/stripped.epub" "$work/original.epub" "$work/plain.epub" "$work/with space.epub" || fail=1

if [ "$fail" -eq 0 ]; then
    echo "STRIPPED READALONG DETECTION PASS"
else
    echo "STRIPPED READALONG DETECTION FAILED"
fi
exit "$fail"
