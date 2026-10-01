-- shared by the differential tests: turn haps into a canonical, comparable string
local M = {}
local function ser(v)
  local t = type(v)
  if t == "number" then
    if math.type(v) == "integer" or v == math.floor(v) then return string.format("%d", v) end
    return string.format("%.9g", v)
  elseif t == "string" then return string.format("%q", v)
  elseif t == "boolean" then return tostring(v)
  elseif t == "table" then
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = string.format("%q", tostring(k)) .. ":" .. ser(v[k]) end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "?"
end
M.ser = ser
return M
