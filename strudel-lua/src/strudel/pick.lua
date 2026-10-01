-- strudel/pick.lua
-- pick, pickF, pickRestart, pickReset, inhabit and their "mod" / "Out" variants: one pattern chooses events from
-- a lookup table (an array or a { name: pattern } object).  Ports of @strudel/core/pick.mjs (AGPL-3.0-or-later).

local P = require("strudel.pattern")
local Pattern, reify, silence = P.Pattern, P.reify, P.silence

local K = {}

local function round(x) return math.floor(x + 0.5) end
local function key_string(k)
  if type(k) == "number" and k == math.floor(k) then return string.format("%d", k) end
  return tostring(k)
end

-- pattern of patterns
local function pick_raw(lookup, pat, modulo)
  local is_array = P.is_list(lookup)
  local looked, len = {}, 0
  if is_array then
    for i, v in ipairs(lookup) do looked[i] = reify(v); len = len + 1 end
  elseif P.is_obj(lookup) then
    for k, v in pairs(lookup) do looked[k] = reify(v); len = len + 1 end
  else
    error("pick: the lookup must be an array [...] or an object { name: pattern }", 0)
  end
  if len == 0 then return silence end
  return reify(pat):fmap(function(i)
    if is_array then
      local key = modulo and (round(i) % len) or math.min(math.max(round(i), 0), len - 1)
      return looked[key + 1]
    end
    local v = looked[key_string(i)]
    if v == nil then error("pick: no entry named '" .. key_string(i) .. "'", 0) end
    return v
  end)
end
K.raw = pick_raw

local JOINS = {
  [""] = function(p) return p:inner_join() end,
  Out = function(p) return p:outer_join() end,
  Restart = function(p) return p:restart_join() end,
  Reset = function(p) return p:reset_join() end,
}
local function define(name, modulo, join)
  local f = function(self, lookup) return join(pick_raw(lookup, self, modulo)) end
  Pattern[name] = f
  P.api[name] = f
  K[name] = function(lookup, pat) return f(reify(pat), lookup) end
end
for suffix, join in pairs(JOINS) do
  define("pick" .. suffix, false, join)
  define("pickmod" .. suffix, true, join)
end
define("inhabit", false, function(p) return p:squeeze_join() end)
define("pickSqueeze", false, function(p) return p:squeeze_join() end)
define("inhabitmod", true, function(p) return p:squeeze_join() end)
define("pickmodSqueeze", true, function(p) return p:squeeze_join() end)

-- pickF(lookup, funcs): the lookup pattern chooses which function of the array is applied
local function define_f(name, modulo)
  local f = function(self, lookup, funcs)
    local sel = pick_raw(funcs, lookup, modulo):inner_join()
    return self:apply(sel)
  end
  Pattern[name] = f
  P.api[name] = f
end
define_f("pickF", false)

-- the global function pick(lookup, pat)   (the old argument order pick(pat, lookup) works too)
function K.pick(a, b)
  if P.is_list(b) or P.is_obj(b) then a, b = b, a end
  return K.pickfn(a, b)
end
K.pickfn = function(lookup, pat) return pick_raw(lookup, pat, false):inner_join() end
function K.pickmod(a, b)
  if P.is_list(b) or P.is_obj(b) then a, b = b, a end
  return pick_raw(a, b, true):inner_join()
end

return K
