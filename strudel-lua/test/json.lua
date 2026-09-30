-- minimal JSON decoder for the golden files (objects -> tables, arrays -> tables)
local J = {}
local function skip(s, i) return s:find("[^ \n\r\t]", i) or #s + 1 end
local parse
local function parse_string(s, i)
  local out, j = {}, i + 1
  while true do
    local c = s:sub(j, j)
    if c == '"' then return table.concat(out), j + 1
    elseif c == "\\" then
      local n = s:sub(j + 1, j + 1)
      if n == "u" then out[#out + 1] = utf8.char(tonumber(s:sub(j + 2, j + 5), 16)); j = j + 6
      else out[#out + 1] = ({ n = "\n", t = "\t", r = "\r", b = "\b", f = "\f" })[n] or n; j = j + 2 end
    else out[#out + 1] = c; j = j + 1 end
  end
end
function parse(s, i)
  i = skip(s, i)
  local c = s:sub(i, i)
  if c == "{" then
    local t = {}
    i = skip(s, i + 1)
    if s:sub(i, i) == "}" then return t, i + 1 end
    while true do
      local k; k, i = parse_string(s, skip(s, i))
      i = skip(s, i); i = i + 1              -- ':'
      t[k], i = parse(s, i)
      i = skip(s, i)
      local d = s:sub(i, i); i = i + 1
      if d == "}" then return t, i end
    end
  elseif c == "[" then
    local t = {}
    i = skip(s, i + 1)
    if s:sub(i, i) == "]" then return t, i + 1 end
    while true do
      t[#t + 1], i = parse(s, i)
      i = skip(s, i)
      local d = s:sub(i, i); i = i + 1
      if d == "]" then return t, i end
    end
  elseif c == '"' then return parse_string(s, i)
  elseif s:sub(i, i + 3) == "true" then return true, i + 4
  elseif s:sub(i, i + 4) == "false" then return false, i + 5
  elseif s:sub(i, i + 3) == "null" then return nil, i + 4
  else
    local m = s:match("^-?[%d%.eE%+%-]+", i)
    return tonumber(m), i + #m
  end
end
function J.decode(s) return (parse(s, 1)) end
return J
