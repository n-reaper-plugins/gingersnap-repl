-- Build:  lua tools/build.lua        (run from the project root)
-- Output: dist/Gingersnap.lua  = the ONE file users need (strudel-lua is bundled into it)
package.path = "./src/?.lua;./strudel-lua/src/?.lua;" .. package.path
local Core = require("GSCore")

local GINGERSNAP = { "strudel.fraction", "strudel.pattern", "strudel.signal", "strudel.library", "strudel.scales", "strudel.tonal",
                  "strudel.slicing", "strudel.pick", "strudel.controls",
                  "strudel.mini", "strudel.lang", "strudel" }
local MODULES = { "GSCore", "GSReaper", "GSApp", "GSUI" }

local function read(p) local f = assert(io.open(p, "rb"), "cannot read " .. p); local s = f:read("*a"); f:close(); return s end
local function write(p, s) local f = assert(io.open(p, "wb"), "cannot write " .. p); f:write(s); f:close() end

local main = read("src/Gingersnap.lua"):gsub("@@VERSION@@", Core.VERSION)
local header, body = {}, main
while true do
  local line, rest = body:match("^([^\n]*)\n(.*)$")
  if line and line:match("^%-%-") then header[#header + 1] = line; body = rest else break end
end
-- the bundle has no strudel-lua/ folder next to it: drop that search path
body = body:gsub('package%.path = dir %.%. "%?%.lua;" %.%. dir %.%. "strudel%-lua/src/%?%.lua;" %.%. package%.path',
                 'package.path = dir .. "?.lua;" .. package.path')

local out = { table.concat(header, "\n"),
  "-- BUNDLED BUILD of Gingersnap v" .. Core.VERSION .. " (minimal Strudel subset for REAPER) - edit the files in src/ and strudel-lua/, not this one.",
  "-- Contains strudel-lua (AGPL-3.0-or-later), a Lua implementation of Strudel's semantics.",
  "local __preload = package.preload" }
for _, m in ipairs(GINGERSNAP) do
  local path = (m == "strudel") and "strudel-lua/src/strudel.lua" or ("strudel-lua/src/" .. m:gsub("%.", "/") .. ".lua")
  out[#out + 1] = string.format('__preload["%s"] = function(...)\n%s\nend', m, read(path))
end
for _, m in ipairs(MODULES) do
  out[#out + 1] = string.format('__preload["%s"] = function(...)\n%s\nend', m, read("src/" .. m .. ".lua"))
end
out[#out + 1] = body
os.execute("mkdir -p dist")
write("dist/Gingersnap.lua", table.concat(out, "\n") .. "\n")
print("built dist/Gingersnap.lua v" .. Core.VERSION)
