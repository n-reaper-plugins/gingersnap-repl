-- print onset events of ONE expression from strudel-lua:  lua5.4 test/one.lua 'expr' [cycles]
local here = (arg[0] or ""):match("^(.*)/test/[^/]*$") or "."
package.path = here .. "/src/?.lua;" .. package.path
local S = require("strudel")
local r, err = S.run(arg[1])
if not r then print("ERROR " .. tostring(err)); os.exit(1) end
local function js(v)
  if type(v) == "table" then
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local out = {}
    for _, k in ipairs(keys) do out[#out + 1] = string.format("%q:%s", tostring(k), js(v[k])) end
    return "{" .. table.concat(out, ",") .. "}"
  elseif type(v) == "string" then return string.format('"%s"', v)
  elseif type(v) == "number" and v == math.floor(v) then return string.format("%d", v)
  else return tostring(v) end
end
local rows = {}
for _, e in ipairs(S.events(r.layers[1].pattern, 0, tonumber(arg[2] or 8))) do
  rows[#rows + 1] = string.format("%s %s %s", tostring(e.b), tostring(e.e), js(e.value))
end
table.sort(rows)
print(table.concat(rows, "\n"))
