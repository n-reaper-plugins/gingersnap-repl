-- @description Gingersnap: minimal Strudel subset for REAPER - render patterns into the project (audio items and/or MIDI)
-- @version 0.2.0
-- @about
--   Gingersnap is a minimal Strudel subset for REAPER (not affiliated with the Strudel project).
--   Run this action to open the Gingersnap window (needs ReaImGui: ReaPack > ReaTeam Extensions;
--   a folder dialog additionally needs js_ReaScriptAPI, otherwise a file dialog / drag&drop / typing is used).
--   1. Choose a sounds root folder with one sub-folder per sound (root/bd, root/sn, root/hh).
--   2. "New pattern" inserts an EMPTY item on the timeline; its notes hold the code, e.g.  $: s("bd*2, ~ sn")
--   3. The pattern is rendered into the item's time range: audio items on tracks under a GINGERSNAP folder,
--      and/or MIDI notes (one track per $: line). Move or resize the item and the result follows.
--   s("bd:3") = 4th file of folder bd; s("bd").n(3) too.  1 cycle = "beats per cycle" quarter notes (default 4).
--   Run the action again while the window is open to close it.
--   Pattern engine: strudel-lua, a Lua implementation of Strudel's semantics. AGPL-3.0-or-later.
-- BUNDLED BUILD of Gingersnap v0.2.0 (minimal Strudel subset for REAPER) - edit the files in src/ and strudel-lua/, not this one.
-- Contains strudel-lua (AGPL-3.0-or-later), a Lua implementation of Strudel's semantics.
local __preload = package.preload
__preload["strudel.fraction"] = function(...)
-- strudel/fraction.lua
-- Exact rational numbers on Lua 5.3+/5.4 integers. Time in patterns is ALWAYS a Fraction, so that
-- triplets, nested subdivisions and slow/fast never drift (this is what Strudel's fraction.js does).
--
-- Part of strudel-lua, a Lua implementation of the semantics of Strudel
-- (https://strudel.cc). Licensed AGPL-3.0-or-later, see ../../README.md.

local F = {}
F.__index = F

local function gcd(a, b)
  a, b = math.abs(a), math.abs(b)
  while b ~= 0 do a, b = b, a % b end
  return a
end

local function new(n, d)
  if d < 0 then n, d = -n, -d end
  local g = gcd(n, d)
  if g > 1 then n, d = n // g, d // g end
  return setmetatable({ n = n, d = d }, F)
end

local ZERO, ONE = new(0, 1), new(1, 1)
F.ZERO, F.ONE = ZERO, ONE

function F.is(x) return getmetatable(x) == F end

-- float -> nearest simple fraction (Farey/Stern-Brocot search, denominators <= 1e7, like fraction.js)
local function from_float(x)
  if x ~= x or x == math.huge or x == -math.huge then error("cannot convert " .. tostring(x) .. " to a fraction") end
  if x == math.floor(x) and math.abs(x) < 2 ^ 62 then return new(math.tointeger(x), 1) end
  local neg = x < 0
  if neg then x = -x end
  local ip = math.floor(x)
  local frac = x - ip
  local N = 10000000
  local A, B, C, D = 0, 1, 1, 1               -- A/B <= frac <= C/D
  local n, d
  while B <= N and D <= N do
    local M = (A + C) / (B + D)
    if frac == M then
      if B + D <= N then n, d = A + C, B + D
      elseif D > B then n, d = C, D
      else n, d = A, B end
      break
    elseif frac > M then A, B = A + C, B + D
    else C, D = A + C, B + D end
    if B > N then n, d = C, D
    elseif D > N then n, d = A, B end
  end
  if not n then n, d = A, B end
  local r = new(ip * d + n, d)
  return neg and new(-r.n, r.d) or r
end

-- anything numeric -> Fraction
function F.of(x, d)
  if getmetatable(x) == F then return x end
  if d then return new(x, d) end
  if math.type(x) == "integer" then return new(x, 1) end
  if type(x) == "number" then return from_float(x) end
  if type(x) == "string" then
    local n = tonumber(x)
    if n then return F.of(n) end
  end
  error("cannot convert " .. tostring(x) .. " to a fraction")
end
local of = F.of

function F.__add(a, b) a, b = of(a), of(b); return new(a.n * b.d + b.n * a.d, a.d * b.d) end
function F.__sub(a, b) a, b = of(a), of(b); return new(a.n * b.d - b.n * a.d, a.d * b.d) end
function F.__mul(a, b) a, b = of(a), of(b); return new(a.n * b.n, a.d * b.d) end
function F.__div(a, b)
  a, b = of(a), of(b)
  if b.n == 0 then error("fraction: division by zero") end
  return new(a.n * b.d, a.d * b.n)
end
function F.__unm(a) return new(-a.n, a.d) end
function F.__eq(a, b) return a.n == b.n and a.d == b.d end
function F.__lt(a, b) a, b = of(a), of(b); return a.n * b.d < b.n * a.d end
function F.__le(a, b) a, b = of(a), of(b); return a.n * b.d <= b.n * a.d end
function F.__tostring(a) return a.d == 1 and tostring(a.n) or (a.n .. "/" .. a.d) end

function F:float() return self.n / self.d end
function F:floor() return new(self.n // self.d, 1) end     -- integer floor division = mathematical floor
function F:ceil() return new(-((-self.n) // self.d), 1) end
function F:sam() return self:floor() end                     -- start of the cycle
function F:next_sam() return self:floor() + ONE end
function F:cycle_pos() return self - self:floor() end
function F:min(o) o = of(o); return (o < self) and o or self end
function F:max(o) o = of(o); return (o > self) and o or self end
function F:is_zero() return self.n == 0 end
function F:int() return self.n // self.d end                 -- floor as a Lua integer

-- whole-cycle span of a time
function F:whole_cycle() return self:sam(), self:next_sam() end

return F

end
__preload["strudel.pattern"] = function(...)
-- strudel/pattern.lua
-- The pattern core: a Pattern is a function  query(span) -> list of haps  (events).
-- Nothing in here knows about audio, MIDI or REAPER.
--
-- strudel-lua is a Lua implementation of the semantics of Strudel
-- (https://strudel.cc) and Tidal. It follows the behaviour of Strudel's @strudel/core and is checked
-- against it (test/reference). Licensed AGPL-3.0-or-later, see ../../README.md.

local Fraction = require("strudel.fraction")
local of = Fraction.of
local ZERO, ONE = Fraction.ZERO, Fraction.ONE

local P = {}

--------------------------------------------------------------------------------
-- lists (JS arrays, produced by the `:` operator of mini-notation) vs control maps
--------------------------------------------------------------------------------
local List = {}
List.__index = List
function P.list(t) return setmetatable(t, List) end
function P.is_list(v) return getmetatable(v) == List end
local function is_map(v) return type(v) == "table" and getmetatable(v) == nil end
P.is_map = is_map

-- JS object literals ({ a: x, b: y }) as written in code; NOT control maps (those have no metatable)
local Obj = {}
Obj.__index = Obj
function P.obj(t) return setmetatable(t, Obj) end
function P.is_obj(v) return getmetatable(v) == Obj end

--------------------------------------------------------------------------------
-- TimeSpan  { b = Fraction, e = Fraction }
--------------------------------------------------------------------------------
local function S(b, e) return { b = b, e = e } end
P.span = S

local function span_with_time(sp, f) return S(f(sp.b), f(sp.e)) end

-- splits a span at cycle boundaries
local function span_cycles(sp)
  if sp.b == sp.e then return { sp } end
  local out = {}
  local b, e = sp.b, sp.e
  local end_sam = e:sam()
  while e > b do
    if b:sam() == end_sam then out[#out + 1] = S(b, e); break end
    local nb = b:next_sam()
    out[#out + 1] = S(b, nb)
    b = nb
  end
  return out
end

local function span_intersection(a, b)
  local ib, ie = a.b:max(b.b), a.e:min(b.e)
  if ib > ie then return nil end
  if ib == ie then
    -- zero-width intersection at the end of a non-zero-width span does not count
    if ib == a.e and a.b < a.e then return nil end
    if ib == b.e and b.b < b.e then return nil end
  end
  return S(ib, ie)
end

local function span_intersection_e(a, b)
  local r = span_intersection(a, b)
  if not r then error("TimeSpans do not intersect") end
  return r
end

--------------------------------------------------------------------------------
-- Hap  { whole = span|nil, part = span, value = any }
--------------------------------------------------------------------------------
local function H(whole, part, value) return { whole = whole, part = part, value = value } end
P.hap = H
local function whole_or_part(h) return h.whole or h.part end
local function has_onset(h) return h.whole ~= nil and h.whole.b == h.part.b end
P.has_onset = has_onset

local function hap_with_span(h, f) return H(h.whole and f(h.whole), f(h.part), h.value) end

--------------------------------------------------------------------------------
-- Pattern
--------------------------------------------------------------------------------
local Pattern = {}
Pattern.__index = Pattern
P.Pattern = Pattern

local function new(q, pure_value)
  return setmetatable({ query = q, pure = pure_value }, Pattern)
end
P.new = new

function P.is_pattern(x) return getmetatable(x) == Pattern end

function Pattern:query_arc(b, e) return self.query(S(of(b), of(e))) end

function Pattern:split_queries()
  local pat = self
  return new(function(sp)
    local out = {}
    for _, sub in ipairs(span_cycles(sp)) do
      for _, h in ipairs(pat.query(sub)) do out[#out + 1] = h end
    end
    return out
  end)
end

function Pattern:with_query_span(f)
  local pat = self
  return new(function(sp) return pat.query(f(sp)) end)
end
function Pattern:with_query_span_maybe(f)
  local pat = self
  return new(function(sp)
    local s2 = f(sp)
    if not s2 then return {} end
    return pat.query(s2)
  end)
end
function Pattern:with_query_time(f)
  return self:with_query_span(function(sp) return span_with_time(sp, f) end)
end
function Pattern:with_hap_span(f)
  local pat = self
  return new(function(sp)
    local out = {}
    for i, h in ipairs(pat.query(sp)) do out[i] = hap_with_span(h, f) end
    return out
  end)
end
function Pattern:with_hap_time(f)
  return self:with_hap_span(function(sp) return span_with_time(sp, f) end)
end
function Pattern:with_haps(f)
  local pat = self
  return new(function(sp) return f(pat.query(sp), sp) end)
end
function Pattern:fmap(f)
  local pat = self
  local r = new(function(sp)
    local out = {}
    for i, h in ipairs(pat.query(sp)) do out[i] = H(h.whole, h.part, f(h.value)) end
    return out
  end)
  r.weight = self.weight            -- steps are kept, like Strudel's withValue
  return r
end
function Pattern:filter_haps(f)
  local pat = self
  return new(function(sp)
    local out = {}
    for _, h in ipairs(pat.query(sp)) do if f(h) then out[#out + 1] = h end end
    return out
  end)
end
function Pattern:filter_values(f) return self:filter_haps(function(h) return f(h.value) end) end
function Pattern:discrete_only() return self:filter_haps(function(h) return h.whole ~= nil end) end
function Pattern:onsets_only() return self:filter_haps(has_onset) end

-- sentinel: a combine function returns SKIP to drop the hap (JS: returning undefined + removeUndefineds)
local SKIP = {}
P.SKIP = SKIP
function Pattern:remove_skipped()
  return self:filter_values(function(v) return v ~= SKIP end)
end

--------------------------------------------------------------------------------
-- applicative: combine(a, b) computes the new value from the left and right value
--------------------------------------------------------------------------------
local function call(a, b) return a(b) end

function Pattern:app_whole(whole_func, other, combine)
  local pat_func, pat_val = self, other
  combine = combine or call
  return new(function(sp)
    local out = {}
    local funcs, vals = pat_func.query(sp), pat_val.query(sp)
    for _, f in ipairs(funcs) do
      for _, v in ipairs(vals) do
        local s = span_intersection(f.part, v.part)
        if s then out[#out + 1] = H(whole_func(f.whole, v.whole), s, combine(f.value, v.value)) end
      end
    end
    return out
  end)
end

function Pattern:app_both(other, combine)
  return self:app_whole(function(a, b)
    if a == nil or b == nil then return nil end
    return span_intersection_e(a, b)
  end, other, combine)
end

function Pattern:app_left(other, combine)
  local pat_func, pat_val = self, other
  combine = combine or call
  return new(function(sp)
    local out = {}
    for _, f in ipairs(pat_func.query(sp)) do
      for _, v in ipairs(pat_val.query(whole_or_part(f))) do
        local part = span_intersection(f.part, v.part)
        if part then out[#out + 1] = H(f.whole, part, combine(f.value, v.value)) end
      end
    end
    return out
  end)
end

function Pattern:app_right(other, combine)
  local pat_func, pat_val = self, other
  combine = combine or call
  return new(function(sp)
    local out = {}
    for _, v in ipairs(pat_val.query(sp)) do
      for _, f in ipairs(pat_func.query(whole_or_part(v))) do
        local part = span_intersection(f.part, v.part)
        if part then out[#out + 1] = H(v.whole, part, combine(f.value, v.value)) end
      end
    end
    return out
  end)
end

--------------------------------------------------------------------------------
-- monadic bind / join
--------------------------------------------------------------------------------
function Pattern:bind_whole(choose_whole, func)
  local pat_val = self
  return new(function(sp)
    local out = {}
    for _, a in ipairs(pat_val.query(sp)) do
      for _, b in ipairs(func(a.value).query(a.part)) do
        out[#out + 1] = H(choose_whole(a.whole, b.whole), b.part, b.value)
      end
    end
    return out
  end)
end
local function id(x) return x end
function Pattern:bind(func)
  return self:bind_whole(function(a, b)
    if a == nil or b == nil then return nil end
    return span_intersection_e(a, b)
  end, func)
end
function Pattern:join() return self:bind(id) end
function Pattern:outer_bind(func) return self:bind_whole(function(a) return a end, func) end
function Pattern:outer_join() return self:outer_bind(id) end
function Pattern:inner_bind(func) return self:bind_whole(function(_, b) return b end, func) end
function Pattern:inner_join() return self:inner_bind(id) end

function Pattern:squeeze_join()
  local pat_of_pats = self
  return new(function(sp)
    local out = {}
    for _, outer in ipairs(pat_of_pats:discrete_only().query(sp)) do
      local inner_pat = outer.value:_focus_span(whole_or_part(outer))
      for _, inner in ipairs(inner_pat.query(outer.part)) do
        local whole
        local skip = false
        if inner.whole and outer.whole then
          whole = span_intersection(inner.whole, outer.whole)
          if not whole then skip = true end
        end
        local part = (not skip) and span_intersection(inner.part, outer.part) or nil
        if part then out[#out + 1] = H(whole, part, inner.value) end
      end
    end
    return out
  end)
end
function Pattern:squeeze_bind(func) return self:fmap(func):squeeze_join() end

-- retriggers the inner patterns at the onsets of the outer haps
--   reset   : the inner cycle start is aligned to the outer hap start
--   restart : inner cycle ZERO is aligned to the outer hap start
function Pattern:reset_join(restart)
  local pat_of_pats = self
  return new(function(sp)
    local out = {}
    for _, outer in ipairs(pat_of_pats:discrete_only().query(sp)) do
      local shift = restart and outer.whole.b or outer.whole.b:cycle_pos()
      local inner = outer.value:_late(shift)
      for _, ih in ipairs(inner.query(sp)) do
        local whole = ih.whole and span_intersection(ih.whole, outer.whole) or nil
        local part = span_intersection(ih.part, outer.part)
        if part then out[#out + 1] = H(whole, part, ih.value) end
      end
    end
    return out
  end)
end
function Pattern:restart_join() return self:reset_join(true) end

--------------------------------------------------------------------------------
-- constructors
--------------------------------------------------------------------------------
local silence = new(function() return {} end)
P.silence = silence

local function pure(v)
  local p = new(function(sp)
    local out = {}
    for _, sub in ipairs(span_cycles(sp)) do
      out[#out + 1] = H(S(sub.b:sam(), sub.b:next_sam()), sub, v)
    end
    return out
  end, v)
  p.weight = ONE                      -- number of steps (Strudel's _steps): used by stepcat / polymeter
  return p
end
P.pure = pure

-- string -> pattern hook, set by strudel.mini (Strudel: setStringParser / miniAllStrings)
local string_parser
function P.set_string_parser(f) string_parser = f end

local function reify(x)
  if getmetatable(x) == Pattern then return x end
  if type(x) == "string" and string_parser then return string_parser(x) end
  if P.is_list(x) then return P.sequence(table.unpack(x)) end
  return pure(x)
end
P.reify = reify

local function stack(...)
  local pats = { ... }
  for i, p in ipairs(pats) do
    pats[i] = P.is_list(p) and P.sequence(table.unpack(p)) or reify(p)
  end
  return new(function(sp)
    local out = {}
    for _, p in ipairs(pats) do
      for _, h in ipairs(p.query(sp)) do out[#out + 1] = h end
    end
    return out
  end)
end
P.stack = stack

local function slowcat(...)
  local pats = { ... }
  for i, p in ipairs(pats) do
    pats[i] = P.is_list(p) and P.fastcat(table.unpack(p)) or reify(p)
  end
  local n = #pats
  if n == 0 then return silence end
  if n == 1 then return pats[1] end
  return new(function(sp)
    local cyc = sp.b:sam()
    local pat = pats[(cyc:int() % n) + 1]
    if not pat then return {} end
    local offset = sp.b:floor() - (sp.b / n):floor()
    return pat:with_hap_time(function(t) return t + offset end).query(span_with_time(sp, function(t) return t - offset end))
  end):split_queries()
end
P.slowcat = slowcat

-- like slowcat but without shifting the inner cycle counter (used by every / firstOf / lastOf)
function P.slowcat_prime(...)
  local pats = { ... }
  for i, p in ipairs(pats) do pats[i] = reify(p) end
  local n = #pats
  return new(function(sp)
    -- JS semantics on purpose: `-1 % 2` is -1, so cycles before 0 that fall on a negative index are silent
    local pat = pats[math.fmod(sp.b:floor():int(), n) + 1]
    return pat and pat.query(sp) or {}
  end):split_queries()
end

function P.fastcat(...)
  local n = select("#", ...)
  local result = slowcat(...)
  if n > 1 then result = result:_fast(n) end
  if n > 1 then result.weight = of(n) end   -- (n == 1 returns the argument itself: do not touch it)
  return result
end
P.sequence = P.fastcat

local function timecat(pairs_)
  local total = ZERO
  for _, p in ipairs(pairs_) do total = total + of(p[1]) end
  local b = ZERO
  local pats = {}
  for _, p in ipairs(pairs_) do
    local e = b + of(p[1])
    pats[#pats + 1] = reify(p[2]):_compress(b / total, e / total)
    b = e
  end
  return stack(table.unpack(pats))
end
P.timecat = timecat

function P.signal(func)
  return new(function(sp) return { H(nil, sp, func(sp.b)) } end)
end

--------------------------------------------------------------------------------
-- register: make a function usable with patterned arguments, exactly like Strudel's register()
--   nargs = number of leading arguments (before the pattern). func(a1..an, pat) -> Pattern
--------------------------------------------------------------------------------
P.api = {}          -- public method table: name -> function(pat, ...)
P.arity = {}        -- name -> number of leading (patternified) arguments
P.raw = {}          -- non-patterned versions: name -> function(pat, ...)   (Strudel's _name)

local function register(names, nargs, func, patternify)
  if type(names) == "string" then names = { names } end
  if patternify == nil then patternify = true end
  local pfunc
  if patternify and nargs > 0 then
    pfunc = function(pat, ...)
      local args = { ... }
      for i = 1, nargs do
        if args[i] == nil then error("missing argument " .. i, 0) end
        args[i] = reify(args[i])
      end
      local all_pure = true
      for i = 1, nargs do if args[i].pure == nil then all_pure = false; break end end
      if all_pure then
        local a = {}
        for i = 1, nargs do a[i] = args[i].pure end
        a[nargs + 1] = pat
        return func(table.unpack(a, 1, nargs + 1))
      end
      local acc = args[1]:fmap(function(v) return { v } end)
      for i = 2, nargs do
        acc = acc:app_left(args[i], function(list, b)
          local nl = { table.unpack(list) }
          nl[#nl + 1] = b
          return nl
        end)
      end
      return acc:fmap(function(list)
        local a = { table.unpack(list) }
        a[nargs + 1] = pat
        return func(table.unpack(a, 1, nargs + 1))
      end):inner_join()
    end
  elseif nargs == 0 then
    pfunc = function(pat) return func(pat) end
  else
    pfunc = function(pat, ...)
      local a = { ... }
      for i = 1, nargs do a[i] = reify(a[i]) end
      a[nargs + 1] = pat
      return func(table.unpack(a, 1, nargs + 1))
    end
  end
  for _, name in ipairs(names) do
    P.api[name] = pfunc
    P.arity[name] = nargs
    P.raw[name] = function(pat, ...)
      local a = { ... }
      a[nargs + 1] = pat
      return func(table.unpack(a, 1, nargs + 1))
    end
    Pattern[name] = pfunc
    Pattern["_" .. name] = P.raw[name]
  end
  return pfunc
end
P.register = register

--------------------------------------------------------------------------------
-- helpers shared by the library
--------------------------------------------------------------------------------
local function truthy(v) return v ~= nil and v ~= false and v ~= 0 and v ~= "" and v == v end
P.truthy = truthy

function P.parse_numeral(v)
  if type(v) == "number" then return v end
  if type(v) == "string" then
    local n = tonumber(v)
    if n then return n end
    local m = P.note_to_midi and P.note_to_midi(v)
    if m then return m end
  end
  if v == true then return 1 elseif v == false then return 0 end
  error('cannot parse as numeral: "' .. tostring(v) .. '"', 0)
end

--------------------------------------------------------------------------------
-- time transforms
--------------------------------------------------------------------------------
register("fast", 1, function(factor, pat)
  factor = of(factor)
  if factor.n == 0 then return silence end
  return pat:with_query_time(function(t) return t * factor end):with_hap_time(function(t) return t / factor end)
end)
P.api.density = P.api.fast; Pattern.density = Pattern.fast

register("slow", 1, function(factor, pat)
  factor = of(factor)
  if factor.n == 0 then return silence end
  return pat:_fast(ONE / factor)
end)
P.api.sparsity = P.api.slow; Pattern.sparsity = Pattern.slow

register("early", 1, function(offset, pat)
  offset = of(offset)
  return pat:with_query_time(function(t) return t + offset end):with_hap_time(function(t) return t - offset end)
end)

register("late", 1, function(offset, pat)
  return pat:_early(ZERO - of(offset))
end)

register("rev", 0, function(pat)
  return new(function(sp)
    local cycle, next_cycle = sp.b:sam(), sp.b:next_sam()
    local function reflect(s)
      local nb = cycle + (next_cycle - s.e)
      local ne = cycle + (next_cycle - s.b)
      return S(nb, ne)
    end
    local out = {}
    for i, h in ipairs(pat.query(reflect(sp))) do out[i] = hap_with_span(h, reflect) end
    return out
  end):split_queries()
end, false)

register("fastGap", 1, function(factor, pat)
  factor = of(factor)
  local function qf(sp)
    local cycle = sp.b:sam()
    local bpos = ((sp.b - cycle) * factor):min(ONE)
    local epos = ((sp.e - cycle) * factor):min(ONE)
    if bpos >= ONE then return nil end
    return S(cycle + bpos, cycle + epos)
  end
  local function ef(h)
    local b, e = h.part.b, h.part.e
    local cycle = b:sam()
    local bpos = ((b - cycle) / factor):min(ONE)
    local epos = ((e - cycle) / factor):min(ONE)
    local part = S(cycle + bpos, cycle + epos)
    local whole
    if h.whole then
      whole = S(part.b - (b - h.whole.b) / factor, part.e + (h.whole.e - e) / factor)
    end
    return H(whole, part, h.value)
  end
  return pat:with_query_span_maybe(qf):with_haps(function(haps)
    local out = {}
    for i, h in ipairs(haps) do out[i] = ef(h) end
    return out
  end):split_queries()
end)
P.api.fastgap = P.api.fastGap

register("compress", 2, function(b, e, pat)
  b, e = of(b), of(e)
  if b > e or b > ONE or e > ONE or b < ZERO or e < ZERO then return silence end
  return pat:_fastGap(ONE / (e - b)):_late(b)
end)

register("focus", 2, function(b, e, pat)
  b, e = of(b), of(e)
  return pat:_early(b:sam()):_fast(ONE / (e - b)):_late(b)
end)

function Pattern:_focus_span(sp) return self:_focus(sp.b, sp.e) end

register("repeatCycles", 1, function(n, pat)
  n = of(n)
  return new(function(sp)
    local cycle = sp.b:sam()
    local source_cycle = (cycle / n):sam()
    local delta = cycle - source_cycle
    local out = {}
    for i, h in ipairs(pat.query(span_with_time(sp, function(t) return t - delta end))) do
      out[i] = hap_with_span(h, function(s) return span_with_time(s, function(t) return t + delta end) end)
    end
    return out
  end):split_queries()
end)

return P

end
__preload["strudel.signal"] = function(...)
-- strudel/signal.lua
-- Continuous signals, deterministic randomness, degrade / sometimes, choose.
-- Randomness is a pure function of time (Strudel's "legacy" generator, bit for bit), so every
-- regeneration of a pattern gives the same result.

local P = require("strudel.pattern")
local Fraction = require("strudel.fraction")
local register, reify, stack, pure = P.register, P.reify, P.stack, P.pure
local Pattern = P.Pattern

local M = {}

--------------------------------------------------------------------------------
-- random numbers
--------------------------------------------------------------------------------
local function i32(x)
  x = x & 0xFFFFFFFF
  if x >= 0x80000000 then x = x - 0x100000000 end
  return x
end
local function xorwise(x)
  local a = i32((x << 13) ~ x)
  local b = i32((a // 131072) ~ a)          -- (a >> 17) with sign extension (floor division = arithmetic shift)
  return i32((b << 5) ~ b)
end
local function trunc(x) return math.tointeger(x >= 0 and math.floor(x) or math.ceil(x)) end

local function time_to_int_seed(t)
  local y = t / 300
  local frac = y - trunc(y)
  return xorwise(trunc(frac * 536870912))
end

-- t: time as a float (cycles)  ->  [0, 1)
function M.time_to_rand(t)
  return math.abs(math.fmod(time_to_int_seed(t), 536870912) / 536870912)
end

-- n successive numbers at time t (Strudel's legacy getRandsAtTime(t, n)); NOT made positive, like Strudel
function M.time_to_rands(t, n)
  local seed = time_to_int_seed(t)
  if n == 1 then return { math.abs(math.fmod(seed, 536870912) / 536870912) } end
  local out = {}
  for i = 1, n do
    out[i] = math.fmod(seed, 536870912) / 536870912
    seed = xorwise(seed)
  end
  return out
end

--------------------------------------------------------------------------------
-- signals
--------------------------------------------------------------------------------
local signal = P.signal
local fmod = math.fmod

function Pattern:to_bipolar() return self:fmap(function(x) return x * 2 - 1 end) end
function Pattern:from_bipolar() return self:fmap(function(x) return (x + 1) / 2 end) end

M.saw = signal(function(t) return fmod(t:float(), 1) end)
M.isaw = signal(function(t) return 1 - fmod(t:float(), 1) end)
M.saw2, M.isaw2 = M.saw:to_bipolar(), M.isaw:to_bipolar()
M.sine2 = signal(function(t) return math.sin(math.pi * 2 * t:float()) end)
M.sine = M.sine2:from_bipolar()
M.cosine = M.sine:_early(Fraction.of(1, 4))
M.cosine2 = M.sine2:_early(Fraction.of(1, 4))
M.square = signal(function(t) return math.floor(fmod(t:float() * 2, 2)) end)
M.tri = P.fastcat(M.saw, M.isaw)
M.itri = P.fastcat(M.isaw, M.saw)
M.rand = signal(function(t) return M.time_to_rand(t:float()) end)
M.rand2 = M.rand:to_bipolar()

--------------------------------------------------------------------------------
-- range / numeric helpers (need the operator family from library.lua, resolved lazily)
--------------------------------------------------------------------------------
register("range", 2, function(min, max, pat)
  return pat:mul(max - min):add(min)
end)
register("range2", 2, function(min, max, pat)
  return pat:from_bipolar():_range(min, max)
end)
register("round", 0, function(pat)
  return pat:fmap(function(x) return math.floor(x + 0.5) end)
end, false)

function M.irand_raw(i) return M.rand:fmap(function(x) return trunc(x * i) end) end
function M.irand(ipat) return reify(ipat):fmap(M.irand_raw):inner_join() end
function M.run(n) return M.saw:range(0, n):round():segment(n) end

--------------------------------------------------------------------------------
-- choosing
--------------------------------------------------------------------------------
local function choose_with_raw(pat, xs)
  local pats = {}
  for i, x in ipairs(xs) do pats[i] = reify(x) end
  if #pats == 0 then return P.silence end
  return pat:range(0, #pats):fmap(function(i)
    local key = math.min(math.max(math.floor(i), 0), #pats - 1)
    return pats[key + 1]
  end)
end
function M.choose_in_with(pat, xs) return choose_with_raw(pat, xs):inner_join() end
function M.choose_with(pat, xs) return choose_with_raw(pat, xs):outer_join() end

--------------------------------------------------------------------------------
-- degrade / sometimes
--------------------------------------------------------------------------------
local function degrade_by_with(pat, with_pat, x)
  return pat:app_left(with_pat:filter_values(function(v) return v > x end), function(a) return a end)
end
function Pattern:degrade_by_with(with_pat, x) return degrade_by_with(self, with_pat, x) end

local function inv_rand() return M.rand:fmap(function(r) return 1 - r end) end

register("degradeBy", 1, function(x, pat) return degrade_by_with(pat, M.rand, x) end)
register("degrade", 0, function(pat) return pat:_degradeBy(0.5) end)
register("undegradeBy", 1, function(x, pat) return degrade_by_with(pat, inv_rand(), x) end)
register("undegrade", 0, function(pat) return pat:_undegradeBy(0.5) end)

-- sometimesBy takes a pattern as first argument (probability) and applies func to the un-degraded part
register("sometimesBy", 2, function(x, func, pat)
  return stack(pat:_degradeBy(x), reify(func(pat:_undegradeBy(1 - x))))
end)
register("sometimes", 1, function(func, pat) return pat:_sometimesBy(0.5, func) end)
register("often", 1, function(func, pat) return pat:sometimesBy(0.75, func) end)
register("rarely", 1, function(func, pat) return pat:sometimesBy(0.25, func) end)
register("almostNever", 1, function(func, pat) return pat:sometimesBy(0.1, func) end)
register("almostAlways", 1, function(func, pat) return pat:sometimesBy(0.9, func) end)
register("always", 1, function(func, pat) return reify(func(pat)) end)
register("never", 1, function(_, pat) return pat end)

register("someCyclesBy", 2, function(x, func, pat)
  return stack(
    degrade_by_with(pat, M.rand:_segment(1), x),
    reify(func(degrade_by_with(pat, inv_rand():_segment(1), 1 - x))))
end)
register("someCycles", 1, function(func, pat) return pat:_someCyclesBy(0.5, func) end)

--------------------------------------------------------------------------------
-- 0.2: shuffle / scramble, choose family, perlin / berlin
--------------------------------------------------------------------------------
local fastcat = P.fastcat

-- a random permutation of 0 .. n-1 per cycle, one value per 1/n
function M.randrun(n)
  return signal(function(t)
    local rands = M.time_to_rands(t:floor():float() + 0.5, n)
    local idx = {}
    for i = 1, n do idx[i] = i end
    table.sort(idx, function(a, b)                 -- stable: ties keep their order
      if rands[a] ~= rands[b] then return rands[a] < rands[b] end
      return a < b
    end)
    local i = (t:cycle_pos() * n):floor():int() % n
    return idx[i + 1] - 1
  end):_segment(n)
end

local function rearrange_with(ipat, n, pat)
  local pats = {}
  for i = 0, n - 1 do
    pats[i + 1] = pat:_zoom(Fraction.of(i, n), Fraction.of(i + 1, n)):_repeatCycles(n):_fast(n)
  end
  return ipat:fmap(function(i) return pats[i + 1] end):inner_join()
end
register("shuffle", 1, function(n, pat) return rearrange_with(M.randrun(n), n, pat) end)
register("scramble", 1, function(n, pat) return rearrange_with(M.irand_raw(n):_segment(n), n, pat) end)

-- choose: the values are picked by a (continuous) pattern; xs is a Lua list
function M.choose(...) return M.choose_with(M.rand, { ... }) end
function M.choose_in(...) return M.choose_in_with(M.rand, { ... }) end
function M.choose_cycles(...) return M.choose_in_with(M.rand:_segment(1), { ... }) end
function Pattern:choose(...) return M.choose_with(self, { ... }) end
function Pattern:choose2(...) return M.choose_with(self:from_bipolar(), { ... }) end

-- weighted choice: pairs = { {value, weight}, ... }  (values and weights may be patterns)
local function wchoose_with_raw(pat, pairs_)
  local values, weights = {}, {}
  local total = pure(0)
  for i, pr in ipairs(pairs_) do
    values[i] = reify(pr[1])
    total = total:add(pr[2])
    weights[i] = total
  end
  -- sequenceP: a pattern of the list of all weights
  local weightspat = pure({})
  for _, w in ipairs(weights) do
    weightspat = weightspat:bind(function(list)
      return w:fmap(function(v) local nl = { table.unpack(list) }; nl[#nl + 1] = v; return nl end)
    end)
  end
  local function match(r)
    local findpat = total:mul(r)
    return weightspat:fmap(function(ws)
      return function(find)
        for i, x in ipairs(ws) do if x > find then return values[i] end end
        return nil
      end
    end):app_left(findpat)
  end
  return pat:bind(match)
end
function M.wchoose_with(pat, pairs_) return wchoose_with_raw(pat, pairs_):outer_join() end
function M.wchoose(...) return M.wchoose_with(M.rand, { ... }) end
function M.wchoose_cycles(...) return wchoose_with_raw(M.rand:_segment(1), { ... }):inner_join() end

-- smooth noise
local function rand_at(t) return M.time_to_rands(t, 1)[1] end
M.perlin = signal(function(t)
  local tf = t:float()
  local ta = math.floor(tf)
  local x = tf - ta
  local smoother = 6.0 * x ^ 5 - 15.0 * x ^ 4 + 10.0 * x ^ 3
  local ra, rb = rand_at(ta), rand_at(ta + 1)
  return ra + smoother * (rb - ra)
end)
M.berlin = signal(function(t)
  local tf = t:float()
  local a = math.floor(tf)
  local bottom = rand_at(a)
  local top = bottom + rand_at(a + 1)
  return (bottom + (tf - a) * (top - bottom)) / 2
end)

return M

end
__preload["strudel.library"] = function(...)
-- strudel/library.lua
-- The function library built on the core: operators (add/set/struct/mask ...), euclid, every, off,
-- iter, ply, segment, jux, zoom, chunk ... Everything here is sugar over pattern.lua / signal.lua.

local P = require("strudel.pattern")
local Fraction = require("strudel.fraction")
local Sig = require("strudel.signal")
local of, ZERO, ONE = Fraction.of, Fraction.ZERO, Fraction.ONE
local Pattern, register, reify, stack, pure, silence = P.Pattern, P.register, P.reify, P.stack, P.pure, P.silence
local fastcat, slowcat, SKIP, truthy, is_map = P.fastcat, P.slowcat, P.SKIP, P.truthy, P.is_map

local L = {}

--------------------------------------------------------------------------------
-- operator family:  pat:add(x)  (structure from the left, like Strudel's default "in")
--   values that are control maps ({s="bd", n=1}) are combined key by key
--------------------------------------------------------------------------------
local function union_with_obj(a, b, op)
  -- Strudel: arithmetic between a control map and a bare number is not allowed (a warning, `a` is kept)
  if b.value ~= nil then
    local count = 0
    for _ in pairs(b) do count = count + 1 end
    if count == 1 then L.warned_control_arithmetic = true; return a end
  end
  local r = {}
  for k, v in pairs(a) do r[k] = v end
  for k, v in pairs(b) do r[k] = v end
  for k in pairs(a) do
    if type(k) == "string" and b[k] ~= nil then r[k] = op(a[k], b[k]) end    -- (non-string keys are hidden bookkeeping, e.g. the scale)
  end
  return r
end
local function compose_op(a, b, op)
  if is_map(a) or is_map(b) then
    if not is_map(a) then a = { value = a } end
    if not is_map(b) then b = { value = b } end
    return union_with_obj(a, b, op)
  end
  return op(a, b)
end
L.compose_op = compose_op

local function numeral(f)
  return function(a, b) return f(P.parse_numeral(a), P.parse_numeral(b)) end
end
local jsmod = function(n, m) return ((n % m) + m) % m end
local ops = {
  set = function(_, b) return b end,
  keep = function(a) return a end,
  add = numeral(function(a, b) return a + b end),
  sub = numeral(function(a, b) return a - b end),
  mul = numeral(function(a, b) return a * b end),
  div = numeral(function(a, b) return a / b end),
  mod = numeral(jsmod),
  pow = numeral(function(a, b) return a ^ b end),
}

local function sequence_of(...)
  local n = select("#", ...)
  if n == 1 then return reify((...)) end
  return P.sequence(...)
end

for name, op in pairs(ops) do
  Pattern["op_in_" .. name] = function(self, other)
    return self:app_left(reify(other), function(a, b) return compose_op(a, b, op) end)
  end
  Pattern[name] = function(self, ...) return self:app_left(sequence_of(...), function(a, b) return compose_op(a, b, op) end) end
  P.api[name] = Pattern[name]
  P.arity[name] = 1
end

-- keepif family: struct (structure from the argument), mask (structure from the left)
local function keepif(a, b) if truthy(b) then return a end; return SKIP end
function Pattern:struct(...)
  return self:app_right(sequence_of(...), keepif):remove_skipped()
end
function Pattern:mask(...)
  return self:app_left(sequence_of(...), keepif):remove_skipped()
end
P.api.struct, P.api.mask = Pattern.struct, Pattern.mask
P.arity.struct, P.arity.mask = 1, 1

--------------------------------------------------------------------------------
-- multi-pattern methods
--------------------------------------------------------------------------------
function Pattern:stack(...) return stack(self, ...) end
function Pattern:cat(...) return slowcat(self, ...) end
function Pattern:fastcat(...) return fastcat(self, ...) end
P.api.stack, P.api.cat, P.api.fastcat = Pattern.stack, Pattern.cat, Pattern.fastcat
function Pattern:superimpose(...)
  local out = {}
  for i, f in ipairs({ ... }) do out[i] = f(self) end
  return stack(self, table.unpack(out))
end
function Pattern:layer(...)
  local out = {}
  for i, f in ipairs({ ... }) do out[i] = f(self) end
  return stack(table.unpack(out))
end
P.api.superimpose, P.api.layer = Pattern.superimpose, Pattern.layer

--------------------------------------------------------------------------------
-- rhythm
--------------------------------------------------------------------------------
register({ "segment", "seg" }, 1, function(rate, pat)
  return pat:struct(pure(true):_fast(rate))
end)

-- Euclidean rhythms (Bjorklund), same algorithm as Tidal/Strudel
local function split_at(i, arr)
  local a, b = {}, {}
  for k, v in ipairs(arr) do if k <= i then a[#a + 1] = v else b[#b + 1] = v end end
  return a, b
end
local function concat(a, b)
  local r = {}
  for _, v in ipairs(a) do r[#r + 1] = v end
  for _, v in ipairs(b) do r[#r + 1] = v end
  return r
end
local function bjork_rec(ons, offs, xs, ys)
  if math.min(ons, offs) <= 1 then return xs, ys end
  if ons > offs then
    local a, b = split_at(offs, xs)
    local z = {}
    for i, v in ipairs(a) do z[i] = concat(v, ys[i] or {}) end
    return bjork_rec(offs, ons - offs, z, b)
  else
    local a, b = split_at(ons, ys)
    local z = {}
    for i, v in ipairs(xs) do z[i] = concat(v, a[i] or {}) end
    return bjork_rec(ons, offs - ons, z, b)
  end
end
function L.bjorklund(ons, steps)
  local inverted = ons < 0
  local abs_ons = math.abs(ons)
  local offs = steps - abs_ons
  local ones, zeros = {}, {}
  for i = 1, abs_ons do ones[i] = { 1 } end
  for i = 1, math.max(offs, 0) do zeros[i] = { 0 } end
  local xs, ys = bjork_rec(abs_ons, math.max(offs, 0), ones, zeros)
  local out = {}
  for _, v in ipairs(xs) do for _, x in ipairs(v) do out[#out + 1] = x end end
  for _, v in ipairs(ys) do for _, x in ipairs(v) do out[#out + 1] = x end end
  if inverted then for i, x in ipairs(out) do out[i] = 1 - x end end
  return out
end
-- JS Array.prototype.slice semantics for rotate(arr, n) = arr.slice(n).concat(arr.slice(0, n))
local function js_slice(arr, s, e)
  local len = #arr
  s = s or 0
  e = e or len
  if s < 0 then s = math.max(len + s, 0) else s = math.min(s, len) end
  if e < 0 then e = math.max(len + e, 0) else e = math.min(e, len) end
  local r = {}
  for i = s + 1, e do r[#r + 1] = arr[i] end
  return r
end
local function rotate(arr, n) return concat(js_slice(arr, n), js_slice(arr, 0, n)) end
local function euclid_rot(pulses, steps, rotation)
  local b = L.bjorklund(pulses, steps)
  if rotation and rotation ~= 0 then return rotate(b, -rotation) end
  return b
end
L.euclid_bits = euclid_rot
local function bits_pattern(bits) return fastcat(table.unpack(bits)) end

register("euclid", 2, function(pulses, steps, pat)
  return pat:struct(bits_pattern(euclid_rot(pulses, steps, 0)))
end)
register({ "euclidRot", "euclidrot" }, 3, function(pulses, steps, rot, pat)
  return pat:struct(bits_pattern(euclid_rot(pulses, steps, rot)))
end)

--------------------------------------------------------------------------------
-- conditional / structural
--------------------------------------------------------------------------------
register("when", 2, function(on, func, pat)
  if truthy(on) then return reify(func(pat)) end
  return pat
end)

register({ "firstOf", "every" }, 2, function(n, func, pat)
  if n <= 0 then return pat end
  local pats = {}
  for i = 1, n - 1 do pats[i] = pat end
  table.insert(pats, 1, reify(func(pat)))
  return P.slowcat_prime(table.unpack(pats))
end)
register("lastOf", 2, function(n, func, pat)
  if n <= 0 then return pat end
  local pats = {}
  for i = 1, n - 1 do pats[i] = pat end
  pats[#pats + 1] = reify(func(pat))
  return P.slowcat_prime(table.unpack(pats))
end)
register("off", 2, function(time_pat, func, pat)
  return stack(pat, reify(func(pat:late(time_pat))))
end)
register("apply", 1, function(func, pat) return reify(func(pat)) end)

local function iter_impl(times, pat, back)
  times = of(times)
  local pats = {}
  for i = 0, times:int() - 1 do
    local off = of(i) / times
    pats[#pats + 1] = back and pat:late(off) or pat:early(off)
  end
  return slowcat(table.unpack(pats))
end
register("iter", 1, function(times, pat) return iter_impl(times, pat, false) end)
register({ "iterBack", "iterback" }, 1, function(times, pat) return iter_impl(times, pat, true) end)

register("palindrome", 0, function(pat)
  return pat:lastOf(2, function(p) return p:rev() end)
end)

register("ply", 1, function(factor, pat)
  return pat:fmap(function(x) return pure(x):_fast(factor) end):squeeze_join()
end)

register("inside", 2, function(factor, f, pat)
  return reify(f(pat:_slow(factor))):_fast(factor)
end)
register("outside", 2, function(factor, f, pat)
  return pat:_inside(ONE / of(factor), f)
end)

register("zoom", 2, function(s, e, pat)
  s, e = of(s), of(e)
  if s >= e then return silence end
  local d = e - s
  local function with_cycle(sp, f)
    local sam = sp.b:sam()
    return P.span(sam + f(sp.b - sam), sam + f(sp.e - sam))
  end
  return pat:with_query_span(function(sp) return with_cycle(sp, function(t) return t * d + s end) end)
    :with_hap_span(function(sp) return with_cycle(sp, function(t) return (t - s) / d end) end)
    :split_queries()
end)
register("linger", 1, function(t, pat)
  t = of(t)
  if t.n == 0 then return silence end
  if t < ZERO then error("linger: negative values are not supported", 0) end
  return pat:_zoom(0, t):_slow(t)
end)

local function chunk_impl(n, func, pat, back, fast)
  local binary = {}
  for i = 1, n - 1 do binary[i] = false end
  table.insert(binary, 1, true)
  local binary_pat = iter_impl(n, P.sequence(table.unpack(binary)), not back)
  if not fast then pat = pat:_repeatCycles(n) end
  return pat:when(binary_pat, func)
end
register({ "chunk", "slowchunk", "slowChunk" }, 2, function(n, func, pat) return chunk_impl(n, func, pat, false, false) end)
register({ "chunkBack", "chunkback" }, 2, function(n, func, pat) return chunk_impl(n, func, pat, true, false) end)

--------------------------------------------------------------------------------
-- stereo / speed / echo (use the controls `pan`, `speed`, `gain`)
--------------------------------------------------------------------------------
local function copy_with(map, k, v)
  local r = {}
  for kk, vv in pairs(map) do r[kk] = vv end
  r[k] = v
  return r
end
register({ "juxBy", "juxby" }, 2, function(by, func, pat)
  by = by / 2
  local left = pat:fmap(function(v) return copy_with(v, "pan", (v.pan or 0.5) - by) end)
  local right = reify(func(pat:fmap(function(v) return copy_with(v, "pan", (v.pan or 0.5) + by) end)))
  return stack(left, right)
end)
register("jux", 1, function(func, pat) return pat:_juxBy(1, func) end)
register("hurry", 1, function(r, pat) return pat:_fast(r):mul(pure({ speed = r })) end)

register({ "echoWith", "echowith", "stutWith", "stutwith" }, 3, function(times, time, func, pat)
  local pats = {}
  for i = 0, times - 1 do pats[#pats + 1] = reify(func(pat:late(of(time) * of(i)), i)) end
  return stack(table.unpack(pats))
end)
register("echo", 3, function(times, time, feedback, pat)
  return pat:_echoWith(times, time, function(p, i) return p:gain(feedback ^ i) end)
end)
register("stut", 3, function(times, feedback, time, pat)
  return pat:_echoWith(times, time, function(p, i) return p:gain(feedback ^ i) end)
end)

--------------------------------------------------------------------------------
-- 0.2: rhythm and structure
--------------------------------------------------------------------------------
register("swingBy", 2, function(swing, n, pat)
  return pat:_inside(n, function(p) return p:late(P.sequence(0, swing / 2)) end)
end)
register("swing", 1, function(n, pat) return pat:_swingBy(1 / 3, n) end)

register("brak", 0, function(pat)
  return pat:when(slowcat(false, true), function(x) return fastcat(x, silence):_late(0.25) end)
end)

register("pressBy", 1, function(r, pat)
  return pat:fmap(function(x) return pure(x):_compress(r, 1) end):squeeze_join()
end)
register("press", 0, function(pat) return pat:_pressBy(0.5) end)

-- keeps only the events whose START falls in [a, b] (cycle position), applies f to them
local function filter_when(pat, test)
  return pat:filter_haps(function(h) return test(h.whole.b) end)
end
register("within", 3, function(a, b, fn, pat)
  return stack(
    reify(fn(filter_when(pat, function(t) local c = t:cycle_pos():float(); return c >= a and c <= b end))),
    filter_when(pat, function(t) local c = t:cycle_pos():float(); return c < a or c > b end))
end)

local function apply_n(n, func, p)
  local result = p
  for _ = 1, n do result = reify(func(result)) end
  return result
end
register({ "plyWith", "plywith" }, 2, function(factor, func, pat)
  return pat:fmap(function(x)
    local pats = {}
    for i = 0, factor - 1 do pats[#pats + 1] = apply_n(i, func, pure(x)) end
    return slowcat(table.unpack(pats)):_fast(factor)
  end):squeeze_join()
end)

-- euclid variants
local function euclid_legato(pulses, steps, rotation, pat)
  if pulses < 1 then return silence end
  local bits = L.euclid_bits(pulses, steps, 0)
  local str = table.concat(bits)
  local pairs_, first = {}, true
  -- split on "1", drop the part before the first one: each remaining piece is a step that lasts until the next onset
  for piece in (str .. "1"):gmatch("([^1]*)1") do
    if first then first = false else pairs_[#pairs_ + 1] = { #piece + 1, true } end
  end
  return pat:struct(P.timecat(pairs_)):late(of(rotation) / of(steps))
end
register("euclidLegato", 2, function(pulses, steps, pat) return euclid_legato(pulses, steps, 0, pat) end)
register("euclidLegatoRot", 3, function(pulses, steps, rot, pat) return euclid_legato(pulses, steps, rot, pat) end)

-- boolean helpers
register({ "invert", "inv" }, 0, function(pat) return pat:fmap(function(x) return not truthy(x) end) end, false)

-- reset / restart: retrigger the pattern at every true event of the argument
local function keepif_join(self, other, restart)
  return reify(other):fmap(function(b)
    return self:fmap(function(a) if truthy(b) then return a end; return SKIP end)
  end):reset_join(restart):remove_skipped()
end
function Pattern:reset(...) return keepif_join(self, sequence_of(...), false) end
function Pattern:restart(...) return keepif_join(self, sequence_of(...), true) end
P.api.reset, P.api.restart = Pattern.reset, Pattern.restart
P.arity.reset, P.arity.restart = 1, 1

register({ "ribbon", "rib" }, 2, function(offset, cycles, pat)
  return pat:early(offset):restart(pure(1):slow(cycles))
end)


--------------------------------------------------------------------------------
-- steps: stepcat, polymeter, arrange (Strudel's _steps = our `weight`)
--------------------------------------------------------------------------------
local function gcd_i(a, b) a, b = math.abs(a), math.abs(b); while b ~= 0 do a, b = b, a % b end; return a end
local function lcm_fraction(a, b)          -- fraction.js: lcm(n1/d1, n2/d2) = lcm(n1, n2) / gcd(d1, d2)
  if a.n == 0 or b.n == 0 then return ZERO end
  local l = (a.n // gcd_i(a.n, b.n)) * b.n
  return of(l, gcd_i(a.d, b.d))
end

function L.stepcat(...)
  local items = {}
  for i, x in ipairs({ ... }) do
    if P.is_list(x) then items[i] = { of(x[1]), reify(x[2]) }
    else local rp = reify(x); items[i] = { rp.weight or ONE, rp } end
  end
  if #items == 0 then return silence end
  if #items == 1 then local r = items[1][2]; return r:_slow(ONE) end
  local total = ZERO
  for _, it in ipairs(items) do total = total + it[1] end
  local b, pats = ZERO, {}
  for _, it in ipairs(items) do
    if it[1].n ~= 0 then
      local e = b + it[1]
      pats[#pats + 1] = it[2]:_compress(b / total, e / total)
      b = e
    end
  end
  local r = stack(table.unpack(pats))
  r.weight = total
  return r
end

function L.arrange(...)
  local total, secs = ZERO, {}
  for i, sec in ipairs({ ... }) do
    total = total + of(sec[1])
    secs[i] = P.list({ sec[1], reify(sec[2]):fast(sec[1]) })
  end
  return L.stepcat(table.unpack(secs)):_slow(total)
end

-- polymeter: with arrays   polymeter([a b], [c d e])  -> every array keeps the pulse of the first; with patterns: lcm of the steps
local function sequence_count(x)
  if P.is_list(x) then
    if #x == 0 then return silence, 0 end
    if #x == 1 then return sequence_count(x[1]) end
    local pats = {}
    for i, a in ipairs(x) do pats[i] = (sequence_count(a)) end
    return fastcat(table.unpack(pats)), #x
  end
  return reify(x), 1
end
function L.polymeter(...)
  local args = { ... }
  if P.is_list(args[1]) then
    local seqs = {}
    for i, a in ipairs(args) do local p, n = sequence_count(a); seqs[i] = { p, n } end
    if #seqs == 0 then return silence end
    local steps = seqs[1][2]
    local pats = {}
    for _, sq in ipairs(seqs) do
      if sq[2] ~= 0 then
        if steps == sq[2] then pats[#pats + 1] = sq[1] else pats[#pats + 1] = sq[1]:_fast(of(steps) / of(sq[2])) end
      end
    end
    return stack(table.unpack(pats))
  end
  local with = {}
  for _, a in ipairs(args) do
    local p = reify(a)
    if p.weight then with[#with + 1] = p end
  end
  if #with == 0 then return silence end
  local steps = with[1].weight
  for i = 2, #with do steps = lcm_fraction(steps, with[i].weight) end
  if steps.n == 0 then return silence end
  local pats = {}
  for i, p in ipairs(with) do pats[i] = p:_fast(steps / p.weight) end
  local r = stack(table.unpack(pats))
  r.weight = steps
  return r
end

return L

end
__preload["strudel.scales"] = function(...)
-- strudel/scales.lua  (GENERATED by reference/gen_scales.mjs from the scale dictionary of tonal.js, MIT)
-- { name, { aliases }, { intervals } }
return {
  { "major pentatonic", { "pentatonic" }, { "1P", "2M", "3M", "5P", "6M" } },
  { "major", { "ionian" }, { "1P", "2M", "3M", "4P", "5P", "6M", "7M" } },
  { "minor", { "aeolian" }, { "1P", "2M", "3m", "4P", "5P", "6m", "7m" } },
  { "major blues", {  }, { "1P", "2M", "3m", "3M", "5P", "6M" } },
  { "minor blues", { "blues" }, { "1P", "3m", "4P", "5d", "5P", "7m" } },
  { "melodic minor", {  }, { "1P", "2M", "3m", "4P", "5P", "6M", "7M" } },
  { "harmonic minor", {  }, { "1P", "2M", "3m", "4P", "5P", "6m", "7M" } },
  { "bebop", {  }, { "1P", "2M", "3M", "4P", "5P", "6M", "7m", "7M" } },
  { "diminished", { "whole-half diminished" }, { "1P", "2M", "3m", "4P", "5d", "6m", "6M", "7M" } },
  { "dorian", {  }, { "1P", "2M", "3m", "4P", "5P", "6M", "7m" } },
  { "lydian", {  }, { "1P", "2M", "3M", "4A", "5P", "6M", "7M" } },
  { "mixolydian", { "dominant" }, { "1P", "2M", "3M", "4P", "5P", "6M", "7m" } },
  { "phrygian", {  }, { "1P", "2m", "3m", "4P", "5P", "6m", "7m" } },
  { "locrian", {  }, { "1P", "2m", "3m", "4P", "5d", "6m", "7m" } },
  { "ionian pentatonic", {  }, { "1P", "3M", "4P", "5P", "7M" } },
  { "mixolydian pentatonic", { "indian" }, { "1P", "3M", "4P", "5P", "7m" } },
  { "ritusen", {  }, { "1P", "2M", "4P", "5P", "6M" } },
  { "egyptian", {  }, { "1P", "2M", "4P", "5P", "7m" } },
  { "neapolitan major pentatonic", {  }, { "1P", "3M", "4P", "5d", "7m" } },
  { "vietnamese 1", {  }, { "1P", "3m", "4P", "5P", "6m" } },
  { "pelog", {  }, { "1P", "2m", "3m", "5P", "6m" } },
  { "kumoijoshi", {  }, { "1P", "2m", "4P", "5P", "6m" } },
  { "hirajoshi", {  }, { "1P", "2M", "3m", "5P", "6m" } },
  { "iwato", {  }, { "1P", "2m", "4P", "5d", "7m" } },
  { "in-sen", {  }, { "1P", "2m", "4P", "5P", "7m" } },
  { "lydian pentatonic", { "chinese" }, { "1P", "3M", "4A", "5P", "7M" } },
  { "malkos raga", {  }, { "1P", "3m", "4P", "6m", "7m" } },
  { "locrian pentatonic", { "minor seven flat five pentatonic" }, { "1P", "3m", "4P", "5d", "7m" } },
  { "minor pentatonic", { "vietnamese 2" }, { "1P", "3m", "4P", "5P", "7m" } },
  { "minor six pentatonic", {  }, { "1P", "3m", "4P", "5P", "6M" } },
  { "flat three pentatonic", { "kumoi" }, { "1P", "2M", "3m", "5P", "6M" } },
  { "flat six pentatonic", {  }, { "1P", "2M", "3M", "5P", "6m" } },
  { "scriabin", {  }, { "1P", "2m", "3M", "5P", "6M" } },
  { "whole tone pentatonic", {  }, { "1P", "3M", "5d", "6m", "7m" } },
  { "lydian #5p pentatonic", {  }, { "1P", "3M", "4A", "5A", "7M" } },
  { "lydian dominant pentatonic", {  }, { "1P", "3M", "4A", "5P", "7m" } },
  { "minor #7m pentatonic", {  }, { "1P", "3m", "4P", "5P", "7M" } },
  { "super locrian pentatonic", {  }, { "1P", "3m", "4d", "5d", "7m" } },
  { "minor hexatonic", {  }, { "1P", "2M", "3m", "4P", "5P", "7M" } },
  { "augmented", {  }, { "1P", "2A", "3M", "5P", "5A", "7M" } },
  { "piongio", {  }, { "1P", "2M", "4P", "5P", "6M", "7m" } },
  { "prometheus neapolitan", {  }, { "1P", "2m", "3M", "4A", "6M", "7m" } },
  { "prometheus", {  }, { "1P", "2M", "3M", "4A", "6M", "7m" } },
  { "mystery #1", {  }, { "1P", "2m", "3M", "5d", "6m", "7m" } },
  { "six tone symmetric", {  }, { "1P", "2m", "3M", "4P", "5A", "6M" } },
  { "whole tone", { "messiaen's mode #1" }, { "1P", "2M", "3M", "4A", "5A", "6A" } },
  { "messiaen's mode #5", {  }, { "1P", "2m", "4P", "4A", "5P", "7M" } },
  { "locrian major", { "arabian" }, { "1P", "2M", "3M", "4P", "5d", "6m", "7m" } },
  { "double harmonic lydian", {  }, { "1P", "2m", "3M", "4A", "5P", "6m", "7M" } },
  { "altered", { "super locrian", "diminished whole tone", "pomeroy" }, { "1P", "2m", "2A", "3M", "4A", "6m", "7m" } },
  { "locrian #2", { "half-diminished", "aeolian b5" }, { "1P", "2M", "3m", "4P", "5d", "6m", "7m" } },
  { "mixolydian b6", { "melodic minor fifth mode", "hindu" }, { "1P", "2M", "3M", "4P", "5P", "6m", "7m" } },
  { "lydian dominant", { "lydian b7", "overtone" }, { "1P", "2M", "3M", "4A", "5P", "6M", "7m" } },
  { "lydian augmented", {  }, { "1P", "2M", "3M", "4A", "5A", "6M", "7M" } },
  { "dorian b2", { "phrygian #6", "melodic minor second mode" }, { "1P", "2m", "3m", "4P", "5P", "6M", "7m" } },
  { "ultralocrian", { "superlocrian bb7", "superlocrian diminished" }, { "1P", "2m", "3m", "4d", "5d", "6m", "7d" } },
  { "locrian 6", { "locrian natural 6", "locrian sharp 6" }, { "1P", "2m", "3m", "4P", "5d", "6M", "7m" } },
  { "augmented heptatonic", {  }, { "1P", "2A", "3M", "4P", "5P", "5A", "7M" } },
  { "dorian #4", { "ukrainian dorian", "romanian minor", "altered dorian" }, { "1P", "2M", "3m", "4A", "5P", "6M", "7m" } },
  { "lydian diminished", {  }, { "1P", "2M", "3m", "4A", "5P", "6M", "7M" } },
  { "leading whole tone", {  }, { "1P", "2M", "3M", "4A", "5A", "7m", "7M" } },
  { "lydian minor", {  }, { "1P", "2M", "3M", "4A", "5P", "6m", "7m" } },
  { "phrygian dominant", { "spanish", "phrygian major" }, { "1P", "2m", "3M", "4P", "5P", "6m", "7m" } },
  { "balinese", {  }, { "1P", "2m", "3m", "4P", "5P", "6m", "7M" } },
  { "neapolitan major", {  }, { "1P", "2m", "3m", "4P", "5P", "6M", "7M" } },
  { "harmonic major", {  }, { "1P", "2M", "3M", "4P", "5P", "6m", "7M" } },
  { "double harmonic major", { "gypsy" }, { "1P", "2m", "3M", "4P", "5P", "6m", "7M" } },
  { "hungarian minor", {  }, { "1P", "2M", "3m", "4A", "5P", "6m", "7M" } },
  { "hungarian major", {  }, { "1P", "2A", "3M", "4A", "5P", "6M", "7m" } },
  { "oriental", {  }, { "1P", "2m", "3M", "4P", "5d", "6M", "7m" } },
  { "flamenco", {  }, { "1P", "2m", "3m", "3M", "4A", "5P", "7m" } },
  { "todi raga", {  }, { "1P", "2m", "3m", "4A", "5P", "6m", "7M" } },
  { "persian", {  }, { "1P", "2m", "3M", "4P", "5d", "6m", "7M" } },
  { "enigmatic", {  }, { "1P", "2m", "3M", "5d", "6m", "7m", "7M" } },
  { "major augmented", { "major #5", "ionian augmented", "ionian #5" }, { "1P", "2M", "3M", "4P", "5A", "6M", "7M" } },
  { "lydian #9", {  }, { "1P", "2A", "3M", "4A", "5P", "6M", "7M" } },
  { "messiaen's mode #4", {  }, { "1P", "2m", "2M", "4P", "4A", "5P", "6m", "7M" } },
  { "purvi raga", {  }, { "1P", "2m", "3M", "4P", "4A", "5P", "6m", "7M" } },
  { "spanish heptatonic", {  }, { "1P", "2m", "3m", "3M", "4P", "5P", "6m", "7m" } },
  { "bebop minor", {  }, { "1P", "2M", "3m", "3M", "4P", "5P", "6M", "7m" } },
  { "bebop major", {  }, { "1P", "2M", "3M", "4P", "5P", "5A", "6M", "7M" } },
  { "bebop locrian", {  }, { "1P", "2m", "3m", "4P", "5d", "5P", "6m", "7m" } },
  { "minor bebop", {  }, { "1P", "2M", "3m", "4P", "5P", "6m", "7m", "7M" } },
  { "ichikosucho", {  }, { "1P", "2M", "3M", "4P", "5d", "5P", "6M", "7M" } },
  { "minor six diminished", {  }, { "1P", "2M", "3m", "4P", "5P", "6m", "6M", "7M" } },
  { "half-whole diminished", { "dominant diminished", "messiaen's mode #2" }, { "1P", "2m", "3m", "3M", "4A", "5P", "6M", "7m" } },
  { "kafi raga", {  }, { "1P", "3m", "3M", "4P", "5P", "6M", "7m", "7M" } },
  { "messiaen's mode #6", {  }, { "1P", "2M", "3M", "4P", "4A", "5A", "6A", "7M" } },
  { "composite blues", {  }, { "1P", "2M", "3m", "3M", "4P", "5d", "5P", "6M", "7m" } },
  { "messiaen's mode #3", {  }, { "1P", "2M", "3m", "3M", "4A", "5P", "6m", "7m", "7M" } },
  { "messiaen's mode #7", {  }, { "1P", "2m", "2M", "3m", "4P", "4A", "5P", "6m", "6M", "7M" } },
  { "chromatic", {  }, { "1P", "2m", "2M", "3m", "3M", "4P", "5d", "5P", "6m", "6M", "7m", "7M" } },
}

end
__preload["strudel.tonal"] = function(...)
-- strudel/tonal.lua
-- scale(), scaleTranspose(), transpose(): ports of @strudel/tonal (AGPL-3.0-or-later) over a small pitch
-- arithmetic that follows tonal.js (MIT) for what is needed here: note names, intervals, scale types.
-- The scale table (scales.lua) is generated from tonal's own dictionary.

local P = require("strudel.pattern")
local Scales = require("strudel.scales")
local register, is_map = P.register, P.is_map

local T = {}

-- hidden key on control maps: the name of the scale a value came from (Strudel keeps it in hap.context)
T.SCALE = setmetatable({}, { __tostring = function() return "<scale>" end })
P.SCALE = T.SCALE

local function jsmod(n, m) return ((n % m) + m) % m end
local STEP_SEMI = { 0, 2, 4, 5, 7, 9, 11 }       -- C D E F G A B  (index = step + 1)
local STEP_LETTER = "CDEFGAB"
local LETTER_STEP = { c = 0, d = 1, e = 2, f = 3, g = 4, a = 5, b = 6 }

--------------------------------------------------------------------------------
-- notes
--------------------------------------------------------------------------------
-- "c#4" -> { step=0, alt=1, oct=4|nil, pc="C#" , name="C#4" }   (nil if it is not a note)
function T.note(str)
  if type(str) ~= "string" then return nil end
  local l, acc, oct = str:match("^([a-gA-G])([#bsf]*)(-?%d*)$")
  if not l then return nil end
  local alt = 0
  for ch in acc:gmatch(".") do alt = alt + ((ch == "#" or ch == "s") and 1 or -1) end
  local n = { step = LETTER_STEP[l:lower()], alt = alt, oct = (oct ~= "") and tonumber(oct) or nil }
  local pc = STEP_LETTER:sub(n.step + 1, n.step + 1) .. (alt > 0 and string.rep("#", alt) or string.rep("b", -alt))
  n.pc, n.name = pc, pc .. (n.oct and tostring(n.oct) or "")
  return n
end

local function note_name(step, alt, oct)
  local pc = STEP_LETTER:sub(step + 1, step + 1) .. (alt > 0 and string.rep("#", alt) or string.rep("b", -alt))
  return pc .. (oct and tostring(oct) or "")
end

--------------------------------------------------------------------------------
-- intervals:  { ds = diatonic steps (signed), sm = semitones (signed) }
--------------------------------------------------------------------------------
local PERFECT = { [0] = true, [3] = true, [4] = true }
function T.interval(str)
  if type(str) ~= "string" then return nil end
  local num, q = str:match("^([-+]?%d+)([dmMPA]+)$")
  if not num then q, num = str:match("^([dmMPA]+)([-+]?%d+)$") end
  if not num then return nil end
  num = tonumber(num)
  if num == 0 then return nil end
  local dir = num < 0 and -1 or 1
  local a = math.abs(num)
  local step, oct = (a - 1) % 7, (a - 1) // 7
  local alt
  local c = #q
  if q:match("^A+$") then alt = c
  elseif q == "P" and PERFECT[step] then alt = 0
  elseif q == "M" and not PERFECT[step] then alt = 0
  elseif q == "m" and not PERFECT[step] then alt = -1
  elseif q:match("^d+$") then alt = PERFECT[step] and -c or -(c + 1)
  else return nil end
  return { ds = dir * (step + 7 * oct), sm = dir * (STEP_SEMI[step + 1] + alt + 12 * oct) }
end

local IN = { 1, 2, 2, 3, 3, 4, 5, 5, 6, 6, 7, 7 }
function T.interval_from_semitones(n)
  local d = n < 0 and -1 or 1
  local a = math.abs(n)
  local c, o = a % 12, a // 12
  return { ds = d * (IN[c + 1] - 1 + 7 * o), sm = n }
end

-- transposes a note table by an interval table; keeps "no octave" if the note had none
local function transpose_note(n, iv, extra_octaves)
  local nd = n.step + 7 * (n.oct or 0)
  local nm = STEP_SEMI[n.step + 1] + n.alt + 12 * (n.oct or 0)
  local dd, dm = nd + iv.ds + 7 * (extra_octaves or 0), nm + iv.sm + 12 * (extra_octaves or 0)
  local step, oct = dd % 7, dd // 7
  local alt = dm - (STEP_SEMI[step + 1] + 12 * oct)
  return note_name(step, alt, n.oct and oct or nil)
end

-- Note.transpose(name, interval-string | interval-table) -> name | nil
function T.transpose_name(name, iv)
  local n = T.note(name)
  if not n then return nil end
  if type(iv) == "string" then iv = T.interval(iv) end
  if not iv then return nil end
  return transpose_note(n, iv)
end

--------------------------------------------------------------------------------
-- scales
--------------------------------------------------------------------------------
local TYPES = {}
for _, row in ipairs(Scales) do
  local st = { name = row[1], intervals = row[3] }
  TYPES[row[1]] = st
  for _, a in ipairs(row[2]) do TYPES[a] = st end
end

-- Scale.get(name)  ->  { tonic = "C" | "", intervals = {...}, notes = {...}, type = "major" }  or nil if unknown
function T.get_scale(src)
  local tonic, typ = "", ""
  local i = src:find(" ", 1, true)
  local tn = i and T.note(src:sub(1, i - 1)) or nil
  if tn then
    tonic, typ = tn.name, src:sub(#tn.name + 2):lower()
  else
    local n = T.note(src)
    if n then tonic, typ = n.name, "" else typ = src:lower() end
  end
  local st = TYPES[typ]
  if not st then return nil, tonic end
  local notes = {}
  if tonic ~= "" then
    local tnote = T.note(tonic)
    for k, iv in ipairs(st.intervals) do notes[k] = transpose_note(tnote, T.interval(iv)) end
  end
  return { tonic = tonic, intervals = st.intervals, notes = notes, type = st.name }
end

local function get_scale(name)
  name = name:gsub(":", " ")
  local sc, tonic = T.get_scale(name)
  if not sc then
    if T.note(name) or tonic == "" then
      error('Scale name ' .. name .. ' is incomplete. Make sure to use ":" instead of spaces, example: .scale("C:major")', 0)
    end
    error('Invalid scale name "' .. name .. '"', 0)
  end
  return sc
end

local function scale_step(step, scale)
  step = math.ceil(step)
  local sc = get_scale(scale)
  local tonic = T.note(sc.tonic ~= "" and sc.tonic or "C")
  local oct = tonic.oct or 3
  local n = #sc.intervals
  local octave_offset = step // n
  local iv = T.interval(sc.intervals[step % n + 1])
  return transpose_note({ step = tonic.step, alt = tonic.alt, oct = oct }, iv, octave_offset)
end

local function scale_offset(scale, offset, note)
  local sc = get_scale(scale)
  local notes = {}
  for i, nm in ipairs(sc.notes) do notes[i] = T.note(nm).pc end
  if offset ~= offset then error('scale offset "' .. tostring(offset) .. '" not a number', 0) end
  local nn = T.note(note)
  if not nn then error('note "' .. tostring(note) .. '" is not a note', 0) end
  local oct = nn.oct or 3
  local index
  for i, pc in ipairs(notes) do if pc == nn.pc then index = i - 1; break end end
  if not index then error('note "' .. note .. '" is not in scale "' .. scale .. '"', 0) end
  local i, o, n = index, oct, nn.pc
  local direction = (offset > 0 and 1) or (offset < 0 and -1) or 0
  while math.abs(i - index) < math.abs(offset) do
    i = i + direction
    local nx = jsmod(i, #notes)
    if direction < 0 and n:sub(1, 1) == "C" then o = o + direction end
    n = notes[nx + 1]
    if direction > 0 and n:sub(1, 1) == "C" then o = o + direction end
  end
  return n .. o
end

local function note_to_midi(name) return P.note_to_midi(name) end

local function nearest_index(target, numbers, prefer_higher)
  local best, best_diff = 0, math.huge
  for i, s in ipairs(numbers) do
    local diff = math.abs(s - target)
    if (not prefer_higher and diff < best_diff) or (prefer_higher and diff <= best_diff) then best, best_diff = i - 1, diff end
  end
  return best
end

local function nearest_scale_note(scale, note)
  local sc = get_scale(scale)
  local tonic = T.note(sc.tonic ~= "" and sc.tonic or "C")
  local pc0 = { step = tonic.step, alt = tonic.alt, oct = 0 }
  local midis, names = {}, {}
  local ivs = { table.unpack(sc.intervals) }
  ivs[#ivs + 1] = "8P"
  for i, iv in ipairs(ivs) do
    names[i] = transpose_note(pc0, T.interval(iv))
    midis[i] = note_to_midi(names[i])
  end
  local nm = type(note) == "string" and note_to_midi(note) or note
  local octave_diff = math.floor((nm - midis[1]) / 12)
  local aligned = {}
  for i, m in ipairs(midis) do aligned[i] = m + 12 * octave_diff end
  local idx = nearest_index(nm, aligned, true)
  return transpose_note(T.note(names[idx + 1]), T.interval_from_semitones(12 * octave_diff))
end

local function step_and_offset(step)
  local as_number = tonumber(step)
  local offset = 0
  if not as_number then
    local s = tostring(step)
    local num, acc = s:match("^(-?%d+)([#bsf]*)$")
    if not num then error('invalid scale step "' .. s .. '", expected number or integer with optional # b suffixes', 0) end
    as_number = tonumber(num)
    for ch in acc:gmatch(".") do offset = offset + ((ch == "#" or ch == "s") and 1 or -1) end
  end
  return as_number, offset
end

local function copy(t) local r = {}; for k, v in pairs(t) do r[k] = v end; return r end

local function flat_join(v)
  if not P.is_list(v) then return tostring(v) end
  local parts = {}
  for _, x in ipairs(v) do parts[#parts + 1] = flat_join(x) end
  return table.concat(parts, " ")
end

register("scale", 1, function(scale, pat)
  if P.is_list(scale) then scale = flat_join(scale) end
  scale = tostring(scale)
  return pat:with_haps(function(haps)
    local out = {}
    for _, h in ipairs(haps) do
      local v = h.value
      local is_obj = is_map(v)
      local hv = is_obj and v or { n = v }
      local rest = copy(hv)
      local note, n, value = rest.note, rest.n, rest.value
      rest.note, rest.n, rest.value = nil, nil, nil
      local x = note
      if x == nil then x = n end
      if x == nil then x = value end
      if x == nil then
        out[#out + 1] = h                         -- Strudel logs an error and passes the value through
      else
        local scale_note
        local ok = true
        if type(x) == "string" and T.note(x) then
          scale_note = nearest_scale_note(scale, x)
        else
          -- an invalid step or scale name removes the event (Strudel logs the error and drops it)
          local okc, res = pcall(function()
            local num, off = step_and_offset(x)
            local sn = scale_step(num, scale)
            if off ~= 0 then sn = T.transpose_name(sn, T.interval_from_semitones(off)) end
            return sn
          end)
          if okc then scale_note = res else ok = false end
        end
        if ok then
          local nv
          if is_obj then nv = rest; nv.note = scale_note; nv[T.SCALE] = scale
          else nv = scale_note end
          out[#out + 1] = P.hap(h.whole, h.part, nv)
        end
      end
    end
    return out
  end)
end)

register({ "scaleTranspose", "scaleTrans", "strans" }, 1, function(offset, pat)
  return pat:fmap(function(v)
    if not is_map(v) or v[T.SCALE] == nil then
      error("can only use scaleTranspose after .scale", 0)
    end
    local r = copy(v)
    r.note = scale_offset(v[T.SCALE], tonumber(offset), v.note)
    return r
  end)
end)

--------------------------------------------------------------------------------
-- transpose(intervalOrSemitones): numbers are semitones, strings intervals ("5P", "3m")
--------------------------------------------------------------------------------
register({ "transpose", "trans" }, 1, function(by, pat)
  return pat:fmap(function(v)
    local obj = is_map(v)
    local nv = obj and v.note
    if nv == nil then nv = v end
    local target
    if type(nv) == "number" then
      local semis
      if type(by) == "number" then semis = by
      elseif type(by) == "string" then local iv = T.interval(by); semis = iv and iv.sm or 0 end
      target = nv + (semis or 0)
    else
      if type(nv) ~= "string" or not T.note(nv) then return v end    -- Strudel: warning, value unchanged
      local iv
      if tonumber(by) then iv = T.interval_from_semitones(tonumber(by)) else iv = T.interval(tostring(by)) end
      target = iv and T.transpose_name(nv, iv) or nv
    end
    if obj then local r = copy(v); r.note = target; return r end
    return target
  end)
end)

return T

end
__preload["strudel.slicing"] = function(...)
-- strudel/slicing.lua
-- Sample slicing: chop, striate, slice, splice, bite, squeeze, loopAt, fit.  Ports of the control-related functions
-- of @strudel/core (AGPL-3.0-or-later). They only produce the controls begin / end / speed / unit; the host does the cutting.
--
-- loopAt / splice / fit need the length of a cycle in seconds ("cps"). The host passes it with Strudel.events(..., cps);
-- without it Strudel's own defaults are used (0.5 for loopAt, 1 for splice and fit).

local P = require("strudel.pattern")
local Fraction = require("strudel.fraction")
local of, ONE = Fraction.of, Fraction.ONE
local Pattern, register, reify, pure, silence, is_map = P.Pattern, P.register, P.reify, P.pure, P.silence, P.is_map

local S = {}
P.controls = P.controls or {}      -- state.controls of Strudel; only _cps is used

local function copy(t) local r = {}; for k, v in pairs(t) do r[k] = v end; return r end

register("chop", 1, function(n, pat)
  local slices = {}
  for i = 0, n - 1 do slices[i + 1] = { begin = i / n, ["end"] = (i + 1) / n } end
  local function merge(a, b)
    if a.begin ~= nil and a["end"] ~= nil then
      local d = a["end"] - a.begin
      b = { begin = a.begin + b.begin * d, ["end"] = a.begin + b["end"] * d }
    end
    local r = copy(a)
    for k, v in pairs(b) do r[k] = v end
    return r
  end
  return pat:squeeze_bind(function(o)
    local items = {}
    for i, so in ipairs(slices) do items[i] = merge(o, so) end
    return P.sequence(table.unpack(items))
  end)
end)

register("striate", 1, function(n, pat)
  local slices = {}
  for i = 0, n - 1 do slices[i + 1] = { begin = i / n, ["end"] = (i + 1) / n } end
  return pat:set(P.slowcat(table.unpack(slices))):_fast(n)
end)

-- slice(n, i, o): n = number of slices (or an array of boundaries), i = which slice, o = the pattern (or sound name)
function S.slice(npat, ipat, opat)
  npat, ipat, opat = reify(npat), reify(ipat), reify(opat)
  return npat:inner_bind(function(n)
    return ipat:outer_bind(function(i)
      return opat:outer_bind(function(o)
        if not is_map(o) then o = { s = o } end
        local b, e
        if P.is_list(n) then b, e = n[i + 1], n[i + 2] else b, e = i / n, (i + 1) / n end
        local m = { begin = b, ["end"] = e, _slices = n }
        for k, v in pairs(o) do m[k] = v end
        return pure(m)
      end)
    end)
  end)
end

function S.splice(npat, ipat, opat)
  local sliced = S.slice(npat, ipat, opat)
  return P.new(function(sp)
    local cps = P.controls._cps or 1
    local out = {}
    for _, h in ipairs(sliced.query(sp)) do
      local v = h.value
      local dur = (h.whole.e - h.whole.b):float()
      local nv = { speed = (cps / v._slices / dur) * (v.speed or 1), unit = "c" }
      for k, x in pairs(v) do nv[k] = x end
      out[#out + 1] = P.hap(h.whole, h.part, nv)
    end
    return out
  end)
end

Pattern.slice = function(self, n, i) return S.slice(n, i, self) end
Pattern.splice = function(self, n, i) return S.splice(n, i, self) end
P.api.slice, P.api.splice = Pattern.slice, Pattern.splice

register({ "loopAt", "loopat" }, 1, function(factor, pat)
  return P.new(function(sp)
    local cps = P.controls._cps or 0.5
    return pat:speed((1 / factor) * cps):unit("c"):_slow(factor).query(sp)
  end)
end)

register("fit", 0, function(pat)
  return pat:with_haps(function(haps)
    local out = {}
    for i, h in ipairs(haps) do
      local v = h.value
      local slicedur = (v["end"] ~= nil and v["end"] or 1) - (v.begin ~= nil and v.begin or 0)
      local nv = copy(v)
      nv.speed = ((P.controls._cps or 1) / (h.whole.e - h.whole.b):float()) * slicedur
      nv.unit = "c"
      out[i] = P.hap(h.whole, h.part, nv)
    end
    return out
  end)
end)

-- bite(n, i): cuts the pattern into n parts and plays part i, squeezed into the event
function S.bite(npat, ipat, pat)
  npat, ipat = reify(npat), reify(ipat)
  return ipat:fmap(function(i)
    return function(n)
      local a = of(i) / of(n)
      a = a - (a.n >= 0 and a:floor() or (ONE * 0 - ((ONE * 0 - a):floor())))        -- JS Fraction.mod(1): the sign of the dividend stays
      local b = a + ONE / of(n)
      return pat:_zoom(a, b)
    end
  end):app_left(npat):squeeze_join()
end
Pattern.bite = function(self, n, i) return S.bite(n, i, self) end
P.api.bite = Pattern.bite

-- squeeze(ipat, { pat, pat, ... }): ipat picks which of the patterns plays in each event (squeezed into it)
function S.squeeze(pat, xs)
  local list = {}
  for i, x in ipairs(xs) do list[i] = reify(x) end
  if #list == 0 then return silence end
  return reify(pat):fmap(function(i)
    local key = (math.floor(i + 0.5) % #list)
    return list[key + 1]
  end):squeeze_join()
end

return S

end
__preload["strudel.pick"] = function(...)
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

end
__preload["strudel.controls"] = function(...)
-- strudel/controls.lua
-- Controls (s, n, note, gain, ...): functions that turn plain values into maps  {s="bd", n=3}.
-- Same semantics as Strudel's registerControl: `s("bd:3:0.5")` sets s, n and gain from the list.
-- Controls that only make sense for a synth/sampler (lpf, room, delay ...) are accepted but ignored;
-- the ones used are recorded in controls.used_ignored so the host can warn.

local P = require("strudel.pattern")
local Pattern, reify, is_map, is_list = P.Pattern, P.reify, P.is_map, P.is_list

local C = { globals = {}, used_ignored = {}, known = {}, ignored = {} }

local function copy(t) local r = {}; for k, v in pairs(t) do r[k] = v end; return r end

-- note name -> midi number  (Strudel: c3 = 48, default octave 3)
local CHROMA = { c = 0, d = 2, e = 4, f = 5, g = 7, a = 9, b = 11 }
local ACC = { ["#"] = 1, b = -1, s = 1, f = -1 }
function C.note_to_midi(note, default_octave)
  if type(note) ~= "string" then return nil end
  local pc, acc, oct = note:match("^([a-gA-G])([#bsf]*)(-?%d*)$")
  if not pc then return nil end
  local off = 0
  for ch in acc:gmatch(".") do off = off + ACC[ch] end
  local o = (oct ~= "") and tonumber(oct) or (default_octave or 3)
  return (o + 1) * 12 + CHROMA[pc:lower()] + off
end
P.note_to_midi = C.note_to_midi

local function create_param(names)
  local multi = type(names) == "table"
  local list = multi and names or { names }
  local name = list[1]
  local function with_val(xs)
    local bag
    if is_map(xs) and xs.value ~= nil then bag = copy(xs); xs = xs.value; bag.value = nil end
    if multi and is_list(xs) then
      local result = bag or {}
      for i, x in ipairs(xs) do if i <= #list then result[list[i]] = x end end
      return result
    elseif bag then bag[name] = xs; return bag
    else return { [name] = xs } end
  end
  return function(value, pat)
    if not pat then return reify(value):fmap(with_val) end
    if value == nil then return pat:fmap(with_val) end
    return pat:op_in_set(reify(value):fmap(with_val))
  end
end

function C.register_control(names, aliases, ignored)
  local list = type(names) == "table" and names or { names }
  local f = create_param(names)
  local all = { list[1] }
  for _, a in ipairs(aliases or {}) do all[#all + 1] = a end
  for _, nm in ipairs(all) do
    C.known[nm] = list[1]
    local g = function(value)
      if ignored then C.used_ignored[nm] = true end
      return f(value, nil)
    end
    local m = function(self, value)
      if ignored then C.used_ignored[nm] = true end
      return f(value, self)
    end
    C.globals[nm] = g
    Pattern[nm] = m
    P.api[nm] = m
    if ignored then C.ignored[nm] = true end
  end
end

-- controls that REAPER can render
C.register_control({ "s", "n", "gain" }, { "sound" })
C.register_control({ "note", "n" })
C.register_control("n")
C.register_control("gain")
C.register_control("velocity", { "vel" })
C.register_control("pan")
C.register_control("legato")
C.register_control("clip")
C.register_control("speed")
C.register_control("channel")
C.register_control("midichan")                       -- same as channel for the host
C.register_control("postgain")                       -- multiplies the volume / velocity (after gain)
C.register_control("octave", { "oct" })              -- shifts MIDI notes by n octaves  (NB: in Strudel .o() is `orbit`, not octave)
C.register_control("bank")                           -- sound lookup prefix: bank("RolandTR909").s("bd") -> RolandTR909_bd
C.register_control("begin"); C.register_control("end")
C.register_control("loop"); C.register_control("cut"); C.register_control("unit")
C.register_control("ccn"); C.register_control("ccv"); C.register_control("progNum"); C.register_control("midibend")

-- accepted, but no effect when rendering a project
for _, nm in ipairs({
  "lpf", "cutoff", "lp", "hpf", "hcutoff", "hp", "resonance", "lpq", "hpq", "bandf", "bpf", "bandq", "bpq",
  "room", "size", "roomsize", "sz", "rsize", "delay", "delaytime", "delayfeedback", "delayfb", "delayt",
  "attack", "att", "decay", "dec", "sustain", "sus", "release", "rel", "shape", "crush", "coarse", "distort",
  "vowel", "detune", "det", "unison", "phaser", "phaserdepth", "tremolo",
  "lpenv", "lpa", "lpd", "lps", "lpr", "hpenv", "acidenv", "fm", "fmi", "fmh", "duck", "duckdepth", "compressor",
  "accelerate", "amp", "slide", "wt", "warp", "sync", "clip",
}) do
  if not C.known[nm] then C.register_control(nm, nil, true) end
end
C.register_control("orbit", { "o" }, true)            -- (ignored: mixer output)
-- visual / analysis helpers: accepted and ignored
C.visual = { "scope", "pianoroll", "punchcard", "spiral", "wordfall", "spectrum", "tscope", "fscope", "pitchwheel",
  "_scope", "_pianoroll", "_punchcard", "_spiral", "_wordfall", "_spectrum", "viz", "draw", "log", "hush" }

return C

end
__preload["strudel.mini"] = function(...)
-- strudel/mini.lua
-- Mini-notation:  "bd [sn sn] <hh oh>*2 bd(3,8,2) hh? ~ a:3 c@3 d!2 {a b c}%4 [a|b] a . b c"
-- A hand-written recursive-descent parser for the grammar of Strudel's mini-notation, followed by a
-- builder that produces Patterns with the same structure and the same seeds for `?` and `|`.

local P = require("strudel.pattern")
local Fraction = require("strudel.fraction")
local Sig = require("strudel.signal")
require("strudel.library")
local of = Fraction.of
local reify, pure, silence, stack = P.reify, P.pure, P.silence, P.stack

local M = {}

--------------------------------------------------------------------------------
-- parser  ->  AST
--   { type="pattern", children={...}, alignment="fastcat|stack|rand|feet|polymeter|polymeter_slowcat",
--     seed=, steps=<slice> }
--   { type="element", source=<node>, ops={...}, weight=1, reps=1 }
--   { type="atom", value="bd" }
--------------------------------------------------------------------------------
local function parse(src)
  local pos, seed = 1, 0
  local n = #src

  local function fail(msg)
    local ctx = src:sub(math.max(1, pos - 12), pos + 12)
    error(string.format('mini: %s at position %d near "%s" in "%s"', msg, pos, ctx, src), 0)
  end
  local function ws() pos = src:find("[^ \n\r\t]", pos) or (n + 1) end
  local function peek(s) return src:sub(pos, pos + #s - 1) == s end
  local function take(s) if peek(s) then pos = pos + #s; return true end; return false end

  local function number()
    local m = src:match("^%-?%d+", pos)
    if not m then return nil end
    local e = pos + #m
    local frac = src:match("^%.%d+", e)
    if frac then m = m .. frac; e = e + #frac end
    local ex = src:match("^[eE][%+%-]?%d+", e)
    if ex then m = m .. ex; e = e + #ex end
    pos = e
    return tonumber(m)
  end

  local parse_stack_or_choose, parse_sequence, parse_slice_with_ops, parse_slice

  local function is_step_char(b)
    return (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b >= 128
      or b == 126 or b == 45 or b == 35 or b == 46 or b == 94 or b == 95   -- ~ - # . ^ _
  end

  local function parse_step()
    local p0 = pos
    ws()
    local s = pos
    while pos <= n and is_step_char(src:byte(pos)) do pos = pos + 1 end
    if pos == s then pos = p0; return nil end
    local tok = src:sub(s, pos - 1)
    if tok == "." or tok == "_" then pos = p0; return nil end
    ws()
    return { type = "atom", value = tok }
  end

  local function parse_polymeter_stack()
    local head = parse_sequence()
    local list = { head }
    ws()
    while peek(",") do
      pos = pos + 1
      list[#list + 1] = parse_sequence()
      ws()
    end
    return { type = "pattern", children = list, alignment = "polymeter" }
  end

  function parse_slice()
    local p0 = pos
    ws()
    local node
    if peek("[") then
      pos = pos + 1; ws()
      node = parse_stack_or_choose()
      ws()
      if not take("]") then fail("expected ']'") end
    elseif peek("{") then
      pos = pos + 1; ws()
      node = parse_polymeter_stack()
      ws()
      if not take("}") then fail("expected '}'") end
      if peek("%") then pos = pos + 1; node.steps = parse_slice() end
    elseif peek("<") then
      pos = pos + 1; ws()
      node = parse_polymeter_stack()
      ws()
      if not take(">") then fail("expected '>'") end
      node.alignment = "polymeter_slowcat"
    else
      pos = p0
      return parse_step()
    end
    ws()
    return node
  end

  function parse_slice_with_ops()
    local s = parse_slice()
    if not s then return nil end
    local el = { type = "element", source = s, ops = {}, weight = 1, reps = 1 }
    local raw = {}
    while true do
      ws()
      local c = src:sub(pos, pos)
      if c == "@" or c == "_" then
        pos = pos + 1
        raw[#raw + 1] = { t = "weight", a = number() }
      elseif c == "!" then
        pos = pos + 1
        raw[#raw + 1] = { t = "replicate", a = number() }
      elseif c == "(" then
        pos = pos + 1; ws()
        local pulse = parse_slice_with_ops(); if not pulse then fail("expected number of pulses") end
        ws(); if not take(",") then fail("expected ','") end
        local step = parse_slice_with_ops(); if not step then fail("expected number of steps") end
        ws(); take(","); ws()
        local rot = parse_slice_with_ops()
        ws(); if not take(")") then fail("expected ')'") end
        raw[#raw + 1] = { t = "bjorklund", pulse = pulse, step = step, rotation = rot }
      elseif c == "/" then
        pos = pos + 1
        local a = parse_slice(); if not a then fail("expected a value after '/'") end
        raw[#raw + 1] = { t = "stretch", type = "slow", amount = a }
      elseif c == "*" then
        pos = pos + 1
        local a = parse_slice(); if not a then fail("expected a value after '*'") end
        raw[#raw + 1] = { t = "stretch", type = "fast", amount = a }
      elseif c == "?" then
        pos = pos + 1
        raw[#raw + 1] = { t = "degradeBy", amount = number() }
      elseif peek("..") then
        pos = pos + 2
        local a = parse_slice(); if not a then fail("expected a value after '..'") end
        raw[#raw + 1] = { t = "range", element = a }
      elseif c == ":" then
        pos = pos + 1
        local a = parse_slice(); if not a then fail("expected a value after ':'") end
        raw[#raw + 1] = { t = "tail", element = a }
      else
        break
      end
    end
    -- apply the operators in order (this is where `?` gets its seed, like the reference grammar)
    for _, op in ipairs(raw) do
      if op.t == "weight" then
        el.weight = (el.weight or 1) + (op.a or 2) - 1
      elseif op.t == "replicate" then
        local reps = (el.reps or 1) + (op.a or 2) - 1
        el.reps = reps
        local kept = {}
        for _, o in ipairs(el.ops) do if o.t ~= "replicate" then kept[#kept + 1] = o end end
        el.ops = kept
        el.ops[#el.ops + 1] = { t = "replicate", amount = reps }
        el.weight = reps
      elseif op.t == "degradeBy" then
        el.ops[#el.ops + 1] = { t = "degradeBy", amount = op.amount, seed = seed }
        seed = seed + 1
      else
        el.ops[#el.ops + 1] = op
      end
    end
    return el
  end

  function parse_sequence()
    ws()
    take("^")
    local els = {}
    while true do
      local e = parse_slice_with_ops()
      if not e then break end
      els[#els + 1] = e
    end
    if #els == 0 then fail("expected a step") end
    return { type = "pattern", children = els, alignment = "fastcat" }
  end

  function parse_stack_or_choose()
    local head = parse_sequence()
    ws()
    local c = src:sub(pos, pos)
    if c == "," then
      local list = { head }
      while true do
        ws()
        if not take(",") then break end
        list[#list + 1] = parse_sequence()
      end
      return { type = "pattern", children = list, alignment = "stack" }
    elseif c == "|" then
      local list = { head }
      while true do
        ws()
        if not take("|") then break end
        list[#list + 1] = parse_sequence()
      end
      local node = { type = "pattern", children = list, alignment = "rand", seed = seed }
      seed = seed + 1
      return node
    elseif c == "." and not peek("..") then
      local list = { head }
      while true do
        ws()
        if not (peek(".") and not peek("..")) then break end
        pos = pos + 1
        list[#list + 1] = parse_sequence()
      end
      local node = { type = "pattern", children = list, alignment = "feet", seed = seed }
      seed = seed + 1
      return node
    end
    return head
  end

  ws()
  local ast = parse_stack_or_choose()
  ws()
  if pos <= n then fail("unexpected '" .. src:sub(pos, pos) .. "'") end
  return ast
end
M.parse = parse

--------------------------------------------------------------------------------
-- builder  AST -> Pattern
--------------------------------------------------------------------------------
local RAND_OFFSET = 0.0003
local build

local function number_or_string(s)
  local v = tonumber(s)
  if v ~= nil and not s:match("^%s*$") then return v end
  return s
end

local function apply_options(pat, child)
  local ops = child.ops
  if not ops then return pat end
  for _, op in ipairs(ops) do
    if op.t == "stretch" then
      pat = reify(pat)[op.type](reify(pat), build(op.amount))
    elseif op.t == "replicate" then
      pat = reify(pat):_repeatCycles(op.amount):_fast(op.amount)
    elseif op.t == "bjorklund" then
      if op.rotation then
        pat = pat:euclidRot(build(op.pulse), build(op.step), build(op.rotation))
      else
        pat = pat:euclid(build(op.pulse), build(op.step))
      end
    elseif op.t == "degradeBy" then
      pat = reify(pat):degrade_by_with(Sig.rand:early(RAND_OFFSET * op.seed), op.amount or 0.5)
    elseif op.t == "tail" then
      local friend = build(op.element)
      pat = pat:app_left(friend, function(a, b)
        if P.is_list(a) then
          local r = { table.unpack(a) }
          r[#r + 1] = b
          return P.list(r)
        end
        return P.list({ a, b })
      end)
    elseif op.t == "range" then
      local friend = build(op.element)
      pat = reify(pat)
      pat = pat:squeeze_bind(function(a)
        return friend:bind(function(b)
          local items = {}
          local step = a < b and 1 or -1
          for i = 0, math.floor(math.abs(b - a)) do items[#items + 1] = a + i * step end
          return P.fastcat(table.unpack(items))
        end)
      end)
    end
  end
  return pat
end

function build(ast)
  if ast.type == "element" then return build(ast.source) end
  if ast.type == "atom" then
    if ast.value == "~" or ast.value == "-" then return silence end
    return pure(number_or_string(ast.value))
  end
  -- pattern
  local children = {}
  for i, child in ipairs(ast.children) do
    children[i] = apply_options(build(child), child)
  end
  local al = ast.alignment
  if al == "stack" then
    return stack(table.unpack(children))
  elseif al == "polymeter_slowcat" then
    local aligned = {}
    for i, c in ipairs(children) do aligned[i] = c:_slow(c.weight) end
    return stack(table.unpack(aligned))
  elseif al == "polymeter" then
    local spc
    if ast.steps then
      spc = build(ast.steps):fmap(function(x) return of(x) end)
    else
      spc = pure(of(#children > 0 and children[1].weight or 1))
    end
    local aligned = {}
    for i, c in ipairs(children) do
      aligned[i] = c:fast(spc:fmap(function(x) return x / c.weight end))
    end
    return stack(table.unpack(aligned))
  elseif al == "rand" then
    return Sig.choose_in_with(Sig.rand:early(RAND_OFFSET * ast.seed):segment(1), children)
  elseif al == "feet" then
    return P.fastcat(table.unpack(children))
  end
  -- fastcat: always weighted (timecat), like the reference implementation
  local pairs_, total = {}, Fraction.ZERO
  for i, el in ipairs(ast.children) do
    local w = of(el.weight or 1)
    pairs_[i] = { w, children[i] }
    total = total + w
  end
  local pat = P.timecat(pairs_)
  pat.weight = total
  return pat
end

function M.mini(str)
  return build(parse(str))
end

P.set_string_parser(M.mini)
return M

end
__preload["strudel.lang"] = function(...)
-- strudel/lang.lua
-- A small, safe front end for Strudel's JavaScript syntax:
--     $: s("bd*2, ~ sn").fast(2).every(4, x => x.rev())
-- Tokenizer + parser + evaluator over a WHITELIST of functions. Nothing is compiled with load(),
-- so pasted code can never reach os / io. Unknown or unsupported functions are reported with their
-- line number instead of being silently skipped (skipping could change the rhythm).

local P = require("strudel.pattern")
local Fraction = require("strudel.fraction")
local Sig = require("strudel.signal")
require("strudel.library")
local Lib = require("strudel.library")
require("strudel.tonal")
local Slice = require("strudel.slicing")
local Pick = require("strudel.pick")
local C = require("strudel.controls")
local Mini = require("strudel.mini")

local Lang = {}

--------------------------------------------------------------------------------
-- tokenizer
--------------------------------------------------------------------------------
local function tokenize(src)
  local toks, i, n, line = {}, 1, #src, 1
  local function err(msg) error({ msg = msg, line = line }, 0) end
  local function add(t, v, extra) toks[#toks + 1] = { t = t, v = v, line = line, ws_before = extra } end
  while i <= n do
    local c = src:sub(i, i)
    if c == "\n" then line = line + 1; i = i + 1
    elseif c:match("%s") then i = i + 1
    elseif src:sub(i, i + 1) == "//" then
      local e = src:find("\n", i, true) or (n + 1)
      i = e
    elseif src:sub(i, i + 1) == "/*" then
      local e = src:find("*/", i + 2, true)
      if not e then err("unterminated comment") end
      for _ in src:sub(i, e):gmatch("\n") do line = line + 1 end
      i = e + 2
    elseif c == '"' or c == "'" or c == "`" then
      local q, j, buf = c, i + 1, {}
      local start_line = line
      while true do
        if j > n then line = start_line; err("unterminated string") end
        local d = src:sub(j, j)
        if d == "\\" then
          local nx = src:sub(j + 1, j + 1)
          local map = { n = "\n", t = "\t", r = "\r" }
          buf[#buf + 1] = map[nx] or nx
          j = j + 2
        elseif d == q then break
        else
          if d == "\n" then
            if q ~= "`" then err("unterminated string") end
            line = line + 1
          end
          if q == "`" and d == "$" and src:sub(j + 1, j + 1) == "{" then err("template strings with ${...} are not supported") end
          buf[#buf + 1] = d
          j = j + 1
        end
      end
      toks[#toks + 1] = { t = "str", v = table.concat(buf), line = start_line }
      i = j + 1
    elseif c:match("%d") or (c == "." and src:sub(i + 1, i + 1):match("%d")) then
      local m = src:match("^%d*%.?%d*[eE][%+%-]?%d+", i) or src:match("^%d*%.?%d*", i)
      -- a trailing "." followed by a letter is a method call on an integer (1.fast) -> not valid JS anyway
      toks[#toks + 1] = { t = "num", v = tonumber(m), line = line }
      i = i + #m
    elseif c:match("[%a_$]") then
      local m = src:match("^[%w_$]+", i)
      add("id", m)
      i = i + #m
    else
      local three, two = src:sub(i, i + 2), src:sub(i, i + 1)
      if three == "===" or three == "!==" or three == "..." then add("p", three); i = i + 3
      elseif two == "=>" or two == "==" or two == "!=" or two == "<=" or two == ">=" or two == "&&" or two == "||" then add("p", two); i = i + 2
      elseif c:match("[%(%)%[%]{},%.;:%+%-%*/%%?=<>!&|]") then add("p", c); i = i + 1
      else err("unexpected character '" .. c .. "'") end
    end
  end
  toks[#toks + 1] = { t = "eof", v = "<end>", line = line }
  return toks
end

--------------------------------------------------------------------------------
-- parser
--------------------------------------------------------------------------------
local function parse(src)
  local toks = tokenize(src)
  local p = 1
  local function cur() return toks[p] end
  local function err(msg, tok) tok = tok or cur(); error({ msg = msg, line = tok.line }, 0) end
  local function is(v) local t = toks[p]; return t.t == "p" and t.v == v end
  local function is_id(v) local t = toks[p]; return t.t == "id" and (v == nil or t.v == v) end
  local function accept(v) if is(v) then p = p + 1; return true end; return false end
  local function expect(v)
    if not accept(v) then err("expected '" .. v .. "' but found '" .. tostring(cur().v) .. "'") end
  end

  local parse_expr, parse_assign

  local function parse_args()
    local args = {}
    expect("(")
    while not is(")") do
      if is("...") then err("spread arguments are not supported") end
      args[#args + 1] = parse_expr()
      if not accept(",") then break end
    end
    expect(")")
    return args
  end

  -- arrow function ahead?  ident =>   |   ( [ident {, ident}] ) =>
  local function arrow_ahead()
    local t = toks[p]
    if t.t == "id" and toks[p + 1].t == "p" and toks[p + 1].v == "=>" then return true end
    if t.t == "p" and t.v == "(" then
      local q = p + 1
      while toks[q].t == "id" or (toks[q].t == "p" and toks[q].v == ",") do q = q + 1 end
      return toks[q].t == "p" and toks[q].v == ")" and toks[q + 1].t == "p" and toks[q + 1].v == "=>"
    end
    return false
  end

  local function parse_arrow()
    local line = cur().line
    local params = {}
    if accept("(") then
      while not is(")") do
        params[#params + 1] = cur().v; p = p + 1
        if not accept(",") then break end
      end
      expect(")")
    else
      params[1] = cur().v; p = p + 1
    end
    expect("=>")
    local body
    if accept("{") then
      -- block body: only `return <expr>;`
      if not is_id("return") then err("only arrow functions of the form  x => expr  or  x => { return expr }  are supported") end
      p = p + 1
      body = parse_expr()
      accept(";")
      expect("}")
    else
      body = parse_expr()
    end
    return { k = "fn", params = params, body = body, line = line }
  end

  local function parse_primary()
    local t = cur()
    if arrow_ahead() then return parse_arrow() end
    if t.t == "num" then p = p + 1; return { k = "lit", v = t.v, line = t.line } end
    if t.t == "str" then p = p + 1; return { k = "str", v = t.v, line = t.line } end
    if t.t == "id" then
      if t.v == "true" then p = p + 1; return { k = "lit", v = true, line = t.line } end
      if t.v == "false" then p = p + 1; return { k = "lit", v = false, line = t.line } end
      if t.v == "await" then p = p + 1; return parse_primary() end
      if t.v == "function" or t.v == "class" or t.v == "new" or t.v == "if" or t.v == "for" or t.v == "while" or t.v == "return" then
        err("'" .. t.v .. "' is not supported (only patterns, method chains and simple arrow functions)")
      end
      p = p + 1
      return { k = "id", v = t.v, line = t.line }
    end
    if t.t == "p" then
      if t.v == "(" then p = p + 1; local e = parse_expr(); expect(")"); return e end
      if t.v == "[" then
        p = p + 1
        local items = {}
        while not is("]") do
          items[#items + 1] = parse_expr()
          if not accept(",") then break end
        end
        expect("]")
        return { k = "array", items = items, line = t.line }
      end
      if t.v == "{" then
        p = p + 1
        local fields = {}
        while not is("}") do
          local k = cur()
          if k.t ~= "id" and k.t ~= "str" and k.t ~= "num" then err("expected a name in the object") end
          p = p + 1
          expect(":")
          fields[#fields + 1] = { key = k.v, e = parse_expr() }
          if not accept(",") then break end
        end
        expect("}")
        return { k = "object", fields = fields, line = t.line }
      end
    end
    err("unexpected '" .. tostring(t.v) .. "'")
  end

  local function parse_postfix()
    local e = parse_primary()
    while true do
      local t = cur()
      if is(".") then
        p = p + 1
        local name = cur()
        if name.t ~= "id" then err("expected a method name after '.'") end
        p = p + 1
        if is("(") then
          e = { k = "mcall", obj = e, name = name.v, args = parse_args(), line = name.line }
        else
          e = { k = "prop", obj = e, name = name.v, line = name.line }
        end
      elseif is("(") then
        e = { k = "call", fn = e, args = parse_args(), line = t.line }
      elseif is("[") and t.line == toks[p - 1].line then
        p = p + 1
        local idx = parse_expr()
        expect("]")
        e = { k = "index", obj = e, idx = idx, line = t.line }
      else
        break
      end
    end
    return e
  end

  local function parse_unary()
    if is("-") then local t = cur(); p = p + 1; return { k = "neg", e = parse_unary(), line = t.line } end
    if is("+") then p = p + 1; return parse_unary() end
    return parse_postfix()
  end
  local function parse_mul()
    local e = parse_unary()
    while is("*") or is("/") or is("%") do
      local op, t = cur().v, cur(); p = p + 1
      e = { k = "bin", op = op, a = e, b = parse_unary(), line = t.line }
    end
    return e
  end
  local function parse_add()
    local e = parse_mul()
    while is("+") or is("-") do
      local op, t = cur().v, cur(); p = p + 1
      e = { k = "bin", op = op, a = e, b = parse_mul(), line = t.line }
    end
    return e
  end
  function parse_expr()
    local e = parse_add()
    if is("?") or is("==") or is("===") or is("<") or is(">") or is("&&") or is("||") then
      err("operator '" .. cur().v .. "' is not supported")
    end
    return e
  end

  local prog = {}
  while cur().t ~= "eof" do
    if accept(";") then goto continue end
    do
      local t = cur()
      local st = { line = t.line }
      if t.t == "id" and (t.v == "const" or t.v == "let" or t.v == "var") then
        p = p + 1
        local name = cur()
        if name.t ~= "id" then err("expected a name") end
        p = p + 1
        expect("=")
        st.k, st.name, st.e = "decl", name.v, parse_expr()
      elseif t.t == "id" and toks[p + 1].t == "p" and toks[p + 1].v == ":" and t.line == toks[p + 1].line then
        p = p + 2
        st.k, st.label, st.e = "expr", t.v, parse_expr()
      elseif t.t == "id" and toks[p + 1].t == "p" and toks[p + 1].v == "=" and not (toks[p + 2].t == "p" and toks[p + 2].v == "=") then
        p = p + 2
        st.k, st.name, st.e = "decl", t.v, parse_expr()
      else
        st.k, st.e = "expr", parse_expr()
      end
      accept(";")
      prog[#prog + 1] = st
    end
    ::continue::
  end
  return prog
end

--------------------------------------------------------------------------------
-- globals (the whitelist)
--------------------------------------------------------------------------------
local function curried(name)
  local nargs = P.arity[name]
  local f = P.api[name]
  local function collect(have)
    return function(...)
      local args = { table.unpack(have) }
      for _, a in ipairs({ ... }) do args[#args + 1] = a end
      if #args >= nargs + 1 then
        return f(args[nargs + 1], table.unpack(args, 1, nargs))
      end
      return collect(args)
    end
  end
  return collect({})
end

local function make_globals()
  local G = {}
  for name in pairs(P.api) do
    if P.arity[name] then G[name] = curried(name) end
  end
  for name, f in pairs(C.globals) do G[name] = f end
  G.silence = P.silence
  G.stack = function(...) return P.stack(...) end
  G.cat, G.slowcat = P.slowcat, P.slowcat
  G.fastcat, G.seq, G.sequence = P.fastcat, P.fastcat, P.fastcat
  G.timeCat = function(...)
    local pairs_ = {}
    for i, a in ipairs({ ... }) do pairs_[i] = a end
    return P.timecat(pairs_)
  end
  G.timecat = G.timeCat
  G.sine, G.cosine, G.saw, G.isaw, G.square, G.tri, G.rand = Sig.sine, Sig.cosine, Sig.saw, Sig.isaw, Sig.square, Sig.tri, Sig.rand
  G.sine2, G.saw2, G.rand2 = Sig.sine2, Sig.saw2, Sig.rand2
  G.irand, G.run = Sig.irand, Sig.run
  -- 0.2 globals (all of them exist in Strudel)
  G.stepcat, G.arrange, G.polymeter = Lib.stepcat, Lib.arrange, Lib.polymeter
  G.pm, G.polyrhythm, G.pr = Lib.polymeter, G.stack, G.stack
  G.perlin, G.berlin = Sig.perlin, Sig.berlin
  G.choose, G.chooseIn, G.chooseOut = Sig.choose, Sig.choose_in, Sig.choose
  G.chooseWith = function(pat, xs) return Sig.choose_with(P.reify(pat), xs) end
  G.chooseInWith = function(pat, xs) return Sig.choose_in_with(P.reify(pat), xs) end
  G.chooseCycles, G.randcat = Sig.choose_cycles, Sig.choose_cycles
  G.wchoose = Sig.wchoose
  G.wchooseCycles, G.wrandcat = Sig.wchoose_cycles, Sig.wchoose_cycles
  G.squeeze = Slice.squeeze
  G.pick, G.pickmod = Pick.pick, Pick.pickmod
  G.rev = function(p) return P.api.rev(P.reify(p)) end
  G.mini = function(s) return Mini.mini(s) end
  G.id = function(x) return x end
  return G
end

-- statement-level helpers that Strudel code often starts with: harmless here
local NOOP = {
  setcps = "tempo comes from the REAPER project", setcpm = "tempo comes from the REAPER project",
  setCps = "tempo comes from the REAPER project", setCpm = "tempo comes from the REAPER project",
  samples = "sounds come from the folder chosen in the window", hush = false, useRNG = "always the default generator",
  registerSynthSounds = false, initHydra = false, setDefaultVoicings = false, aliasBank = false,
}

--------------------------------------------------------------------------------
-- evaluator
--------------------------------------------------------------------------------
local function evaluate(prog, opts)
  opts = opts or {}
  local G = make_globals()
  local warnings, warned = {}, {}
  local function warn(key, msg)
    if not warned[key] then warned[key] = true; warnings[#warnings + 1] = msg end
  end
  local env = {}
  local layers = {}
  local eval

  local function fail(node, msg) error({ msg = msg, line = node.line }, 0) end

  local function lookup(node, name)
    if env[name] ~= nil then return env[name] end
    if G[name] ~= nil then return G[name] end
    if NOOP[name] ~= nil then
      return function()
        if NOOP[name] then warn("noop:" .. name, name .. "(): ignored, " .. NOOP[name]) end
        return nil
      end
    end
    fail(node, "unknown name '" .. name .. "' (not part of the supported Strudel subset)")
  end

  local function as_receiver(node, v)
    if P.is_pattern(v) then return v end
    if type(v) == "string" then return Mini.mini(v) end
    if type(v) == "number" or type(v) == "boolean" then return P.pure(v) end
    if P.is_list(v) then return P.sequence(table.unpack(v)) end
    fail(node, "cannot call a pattern method on this value")
  end

  local visual = {}
  for _, nm in ipairs(C.visual) do visual[nm] = true end

  function eval(node, scope)
    local k = node.k
    if k == "lit" then return node.v
    elseif k == "str" then return node.v
    elseif k == "id" then
      if scope and scope[node.v] ~= nil then return scope[node.v] end
      return lookup(node, node.v)
    elseif k == "array" then
      local items = {}
      for i, it in ipairs(node.items) do items[i] = eval(it, scope) end
      return P.list(items)
    elseif k == "object" then
      local o = {}
      for _, f in ipairs(node.fields) do
        local key = f.key
        if type(key) == "number" and key == math.floor(key) then key = string.format("%d", key) end
        o[tostring(key)] = eval(f.e, scope)
      end
      return P.obj(o)
    elseif k == "neg" then
      local v = eval(node.e, scope)
      if type(v) ~= "number" then fail(node, "cannot negate a non-number") end
      return -v
    elseif k == "bin" then
      local a, b = eval(node.a, scope), eval(node.b, scope)
      if type(a) == "string" and node.op == "+" then return a .. tostring(b) end
      if type(a) ~= "number" or type(b) ~= "number" then
        fail(node, "operator '" .. node.op .. "' only works on numbers (use .add() / .mul() on patterns)")
      end
      if node.op == "+" then return a + b elseif node.op == "-" then return a - b
      elseif node.op == "*" then return a * b
      elseif node.op == "/" then return a / b
      else return math.fmod(a, b) end
    elseif k == "fn" then
      local params, body = node.params, node.body
      return function(...)
        local sc = setmetatable({}, { __index = scope })
        local args = { ... }
        for i, nm in ipairs(params) do sc[nm] = args[i] end
        return eval(body, sc)
      end
    elseif k == "prop" then
      local obj = eval(node.obj, scope)
      fail(node, "'." .. node.name .. "' is not supported here")
    elseif k == "index" then
      local obj, idx = eval(node.obj, scope), eval(node.idx, scope)
      if P.is_list(obj) and type(idx) == "number" then return obj[idx + 1] end
      fail(node, "indexing is only supported on arrays")
    elseif k == "call" then
      local fn = eval(node.fn, scope)
      if type(fn) ~= "function" then fail(node, "this is not a function") end
      local args = {}
      for i, a in ipairs(node.args) do args[i] = eval(a, scope) end
      local ok, res = pcall(fn, table.unpack(args, 1, #node.args))
      if not ok then
        if type(res) == "table" then error(res, 0) end
        error({ msg = Lang.clean_error(res), line = node.line }, 0)
      end
      return res
    elseif k == "mcall" then
      local obj = eval(node.obj, scope)
      local name = node.name
      if visual[name] then
        warn("vis:" .. name, "." .. name .. "(): ignored (visual only)")
        return obj
      end
      local f = P.api[name]
      if not f then
        fail(node, "unknown method '." .. name .. "()' (not part of the supported Strudel subset)")
      end
      local recv = as_receiver(node, obj)
      local args = {}
      for i, a in ipairs(node.args) do args[i] = eval(a, scope) end
      local ok, res = pcall(f, recv, table.unpack(args, 1, #node.args))
      if not ok then
        if type(res) == "table" then error(res, 0) end
        error({ msg = "." .. name .. "(): " .. Lang.clean_error(res), line = node.line }, 0)
      end
      return res
    end
    fail(node, "unsupported expression")
  end

  local any_label = false
  for _, st in ipairs(prog) do if st.label then any_label = true; break end end
  local last_bare
  for _, st in ipairs(prog) do
    if st.k == "decl" then
      env[st.name] = eval(st.e)
    else
      local v = eval(st.e)
      if st.label then
        local muted = st.label:sub(1, 1) == "_"
        if v ~= nil and not muted then
          if not P.is_pattern(v) then v = (type(v) == "string") and Mini.mini(v) or nil end
          if not v then fail(st, "the value after '" .. st.label .. ":' is not a pattern") end
          layers[#layers + 1] = { label = (st.label ~= "$") and st.label or nil, pattern = v, line = st.line }
        end
      elseif v ~= nil then
        last_bare = { pattern = v, line = st.line }
      end
    end
  end
  if not any_label and last_bare then
    local v = last_bare.pattern
    if type(v) == "string" then v = Mini.mini(v) end
    if not P.is_pattern(v) then fail({ line = last_bare.line }, "the last expression is not a pattern") end
    layers[1] = { pattern = v, line = last_bare.line }
  end
  local ig = {}
  for nm in pairs(C.used_ignored) do ig[#ig + 1] = nm end
  table.sort(ig)
  if #ig > 0 then
    warnings[#warnings + 1] = "ignored (no effect in a REAPER project): " .. table.concat(ig, ", ")
  end
  return { layers = layers, warnings = warnings }
end

function Lang.clean_error(e)
  e = tostring(e)
  e = e:gsub("^[^\n]-%.lua:%d+: ", "")
  return e
end

-- code -> { layers = { {label=, pattern=, line=} }, warnings = { "..." } }   or   nil, "line N: message"
function Lang.run(code)
  C.used_ignored = {}
  local ok, res = pcall(function() return evaluate(parse(code)) end)
  if ok then return res end
  if type(res) == "table" and res.msg then
    return nil, (res.line and ("line " .. res.line .. ": ") or "") .. res.msg, res.line
  end
  return nil, Lang.clean_error(res)
end

Lang.tokenize = tokenize
Lang.parse = parse
return Lang

end
__preload["strudel"] = function(...)
-- strudel: the module entry point.
--   local Strudel = require("strudel")
--   local r, err = Strudel.run('$: s("bd*2 sn").fast(2)')        -- r.layers[i].pattern, r.warnings
--   local events = Strudel.events(r.layers[1].pattern, 0, 4)       -- onsets in cycles 0..4
local P = require("strudel.pattern")
local Fraction = require("strudel.fraction")
require("strudel.signal")
require("strudel.library")
require("strudel.tonal")
require("strudel.slicing")
require("strudel.pick")
local Controls = require("strudel.controls")
local Mini = require("strudel.mini")
local Lang = require("strudel.lang")

local Strudel = {
  VERSION = "0.2.0",
  Fraction = Fraction, Pattern = P, Mini = Mini, Lang = Lang, Controls = Controls,
  run = Lang.run,
  mini = Mini.mini,
}

-- All events whose ONSET lies in [from, to) cycles, sorted by time:
--   { { b = Fraction, e = Fraction, value = {...} }, ... }     (b/e = start/end of the whole event)
--   opts.cps_fn(cycle) -> cycles per second (the host's tempo): needed by loopAt / splice / fit. Without it Strudel's
--   defaults are used (loopAt 0.5, splice and fit 1). With it the pattern is queried one cycle at a time.
function Strudel.events(pattern, from, to, opts)
  local out = {}
  local function add(haps)
    for _, h in ipairs(haps) do
      if P.has_onset(h) then out[#out + 1] = { b = h.whole.b, e = h.whole.e, value = h.value } end
    end
  end
  if opts and opts.cps_fn then
    local ok, err = pcall(function()
      for c = math.floor(from), math.ceil(to) - 1 do
        P.controls._cps = opts.cps_fn(c)
        add(pattern:query_arc(math.max(c, from), math.min(c + 1, to)))
      end
    end)
    P.controls._cps = nil
    if not ok then error(err, 0) end
  else
    add(pattern:query_arc(from, to))
  end
  table.sort(out, function(x, y)
    if x.b ~= y.b then return x.b < y.b end
    return false
  end)
  return out
end

return Strudel

end
__preload["GSCore"] = function(...)
-- GSCore.lua
-- Pure Lua (5.3/5.4). NO reaper.* calls in here, so everything can be tested offline.
--
-- Turns the events of a Strudel pattern (see strudel-lua) into what should exist in the project:
--   * audio items  : one per event with a sound (folder name = sound name, :N or n() = Nth file)
--   * MIDI notes   : one per event with a note (or a General-MIDI drum name)
-- Time handling is injected (`timefn`: cycle position -> seconds), so tempo maps are REAPER's business.

local Strudel = require("strudel")

local Core = {}
Core.VERSION = "0.2.0"

Core.MAX_EVENTS = 20000          -- per pattern; protects REAPER from things like s("bd*512").fast(64)

local AUDIO = { wav = 1, wave = 1, flac = 1, mp3 = 1, ogg = 1, oga = 1, opus = 1,
                aif = 1, aiff = 1, aifc = 1, m4a = 1, wv = 1, caf = 1 }

function Core.is_audio(file)
  local e = tostring(file):match("%.([^%.]+)$")
  return e ~= nil and AUDIO[e:lower()] ~= nil
end
function Core.strip_ext(file) return (tostring(file):gsub("%.[^%.]+$", "")) end

-- sound / folder name -> key (trimmed, case-insensitive)
function Core.norm(s)
  s = tostring(s or "")
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  return s:lower()
end

-- 32-bit FNV-1a + murmur3 finaliser (signatures only, not security)
function Core.hash32(s)
  local h = 2166136261
  for i = 1, #s do h = ((h ~ s:byte(i)) * 16777619) & 0xFFFFFFFF end
  h = h ~ (h >> 16); h = (h * 0x85ebca6b) & 0xFFFFFFFF
  h = h ~ (h >> 13); h = (h * 0xc2b2ae35) & 0xFFFFFFFF
  h = h ~ (h >> 16)
  return h
end
function Core.hex(s) return string.format("%08x", Core.hash32(s)) end

-- signature of a scanned sound folder: names + counts (lengths are handled by the plan itself)
function Core.groups_sig(groups)
  local ids = {}
  for id in pairs(groups) do ids[#ids + 1] = id end
  table.sort(ids)
  local parts = {}
  for _, id in ipairs(ids) do
    local g = groups[id]
    local names = {}
    for i, s in ipairs(g.sounds) do names[i] = s.file end
    parts[#parts + 1] = id .. ":" .. table.concat(names, "|")
  end
  return Core.hex(table.concat(parts, "\n"))
end

local function fmt(v) return string.format("%.6f", v) end
Core.fmt = fmt

--------------------------------------------------------------------------------
-- General MIDI drum names (used when a pattern has s("bd sn hh") but is rendered as MIDI)
--   GM_BASE   always on
--   GM_ALIAS  Strudel's short drum names (sd rim lt mt ht cr rd cb perc): only with "Standard drum aliases" switched on
--------------------------------------------------------------------------------
Core.GM_BASE = {
  bd = 36, kick = 36, bd2 = 35, sn = 38, snare = 38, rs = 37, sidestick = 37, cp = 39, clap = 39,
  lowtom = 41, midtom = 47, hightom = 50, tom = 45,
  hh = 42, hihat = 42, ch = 42, closedhat = 42, ph = 44, pedalhat = 44, oh = 46, openhat = 46,
  crash = 49, cy = 49, ride = 51, cowbell = 56, tb = 54, tambourine = 54,
  sh = 70, shaker = 70, cabasa = 69, clave = 75, wood = 76,
}
Core.GM_ALIAS = { sd = 38, rim = 37, lt = 41, mt = 47, ht = 50, cr = 49, rd = 51, cb = 56, perc = 60 }

-- the aliases are also looked up as sample folders: with the switch on, s("sd") finds a folder called sn / snare, and
-- s("snare") finds a folder called sd (the first name of a row is Strudel's)
Core.ALIAS_GROUPS = {
  { "sd", "sn", "snare", "snaredrum" }, { "rim", "rs", "rimshot", "sidestick" }, { "lt", "lowtom", "tomlow" },
  { "mt", "midtom", "tommid" }, { "ht", "hightom", "tomhigh" }, { "cr", "crash", "cy" }, { "rd", "ride" },
  { "cb", "cowbell" }, { "perc", "percussion" },
}
local GROUP_OF = {}
for _, g in ipairs(Core.ALIAS_GROUPS) do for _, nm in ipairs(g) do GROUP_OF[nm] = g end end

-- everything GM_DRUMS knew in 0.1 (kept for callers that want the full table)
Core.GM_DRUMS = {}
for k, v in pairs(Core.GM_BASE) do Core.GM_DRUMS[k] = v end
for k, v in pairs(Core.GM_ALIAS) do Core.GM_DRUMS[k] = v end

function Core.gm_note(name, aliases)
  local n = Core.norm(name)
  if Core.GM_BASE[n] then return Core.GM_BASE[n] end
  if aliases then
    if Core.GM_ALIAS[n] then return Core.GM_ALIAS[n] end
    local g = GROUP_OF[n]
    if g then return Core.GM_ALIAS[g[1]] end
  end
  return nil
end

-- the sound folders to try for  s(name).bank(bank): "<bank>_<name>" first (Strudel's naming), then "<name>";
-- with aliases on every equivalent name is tried in each of the two steps
function Core.sound_candidates(name, bank, aliases)
  local names = { Core.norm(name) }
  if aliases and GROUP_OF[names[1]] then
    for _, nm in ipairs(GROUP_OF[names[1]]) do if nm ~= names[1] then names[#names + 1] = nm end end
  end
  local out = {}
  local b = (type(bank) == "string") and Core.norm(bank) or ""
  if b ~= "" then for _, nm in ipairs(names) do out[#out + 1] = { id = b .. "_" .. nm, banked = true } end end
  for _, nm in ipairs(names) do out[#out + 1] = { id = nm } end
  return out
end

function Core.find_group(groups, name, bank, aliases)
  local cands = Core.sound_candidates(name, bank, aliases)
  for _, c in ipairs(cands) do
    if groups[c.id] then return groups[c.id], c end
  end
  return nil, cands
end

--------------------------------------------------------------------------------
-- planning one pattern
--------------------------------------------------------------------------------
local function clamp(x, lo, hi) if x < lo then return lo elseif x > hi then return hi end; return x end
local function num(v, default)
  if type(v) == "number" then return v end
  if type(v) == "string" then return tonumber(v) or default end
  return default
end
local function truthy(v) return v ~= nil and v ~= false and v ~= 0 and v ~= "" end

-- Strudel's valueToMidi: a number, or a note name (c3 = 48)
local function note_number(nv)
  if type(nv) == "number" then return nv end
  if type(nv) == "string" then return Strudel.Controls.note_to_midi(nv) or tonumber(nv) end
  return nil
end

Core.DEFAULT_ROOT_NOTE = 36      -- Strudel's sampler plays a sample unchanged at note 36 (c2 in Strudel naming)

-- spec = {
--   name=, guid=, layers = { {pattern=, label=} }, mode = "audio"|"midi"|"both",
--   groups = { [id] = {name=, sounds={ {file,name,path} }, path=} },
--   cycles = <number of cycles the pattern item covers>,
--   timefn = function(cycle_position_float) -> seconds,
--   lenfn  = function(path) -> seconds | nil,
--   aliases = bool            -- "Standard drum aliases" (sd rim lt mt ht cr rd cb perc)
--   root_note = number        -- MIDI note at which a sample plays unchanged (default 36)
-- }
-- returns plan = { audio = {items}, midi = {layers}, warnings = {..}, events = n }   or  nil, message
function Core.plan_pattern(spec)
  local plan = { audio = {}, midi = {}, warnings = {}, events = 0 }
  local warned = {}
  local function warn(key, msg)
    if not warned[key] then warned[key] = true; plan.warnings[#plan.warnings + 1] = msg end
  end
  local want_audio, want_midi = spec.mode ~= "midi", spec.mode ~= "audio"
  local cycles = spec.cycles
  if not (cycles and cycles > 0) then return plan end
  local upto = math.ceil(cycles - 1e-9)
  local timefn = spec.timefn
  local aliases = spec.aliases and true or false
  local root = spec.root_note or Core.DEFAULT_ROOT_NOTE
  -- cycles per second at cycle c (tempo map aware): loopAt / splice / fit need it
  local function cps_fn(c)
    local d = timefn(c + 1) - timefn(c)
    if d <= 0 then return 0.5 end
    return 1 / d
  end

  for li, layer in ipairs(spec.layers or {}) do
    local ok, evs = pcall(Strudel.events, layer.pattern, 0, upto, { cps_fn = cps_fn })
    if not ok then return nil, "layer " .. li .. ": " .. Strudel.Lang.clean_error(evs) end
    if #evs > Core.MAX_EVENTS then
      return nil, string.format("%d events in %d cycles is too many (limit %d) - shorten the pattern item or the pattern.", #evs, upto, Core.MAX_EVENTS)
    end
    local seen = {}
    local notes, ctls = {}, {}
    for _, ev in ipairs(evs) do
      local t0 = ev.b:float()
      if t0 < cycles - 1e-9 then
        plan.events = plan.events + 1
        local v = ev.value
        local t1 = ev.e:float()
        if type(v) ~= "table" or getmetatable(v) ~= nil then
          warn("noctl" .. li, "layer " .. li .. ": values are not controls - write s(\"bd sn\") or note(\"c e g\").")
        else
          local pos = timefn(t0)
          local made_audio = false
          local has_ctl = false
          local sname = type(v.s) == "string" and v.s or nil

          -- ------------------------------------------------ audio
          if want_audio and sname then
            local g, c = Core.find_group(spec.groups, sname, v.bank, aliases)
            if not g then
              local tried = {}
              for _, x in ipairs(c) do tried[#tried + 1] = x.id end
              warn("nosnd:" .. sname, "no sound folder named '" .. sname .. "'" .. (#tried > 1 and (" (tried " .. table.concat(tried, ", ") .. ")") or ""))
            else
              if v.bank and not c.banked then
                warn("nobank:" .. tostring(v.bank) .. sname, "no folder '" .. tostring(v.bank) .. "_" .. sname .. "', using '" .. g.name .. "'")
              end
              if #g.sounds == 0 then
                warn("empty:" .. sname, "folder '" .. g.name .. "' has no audio files")
              else
                local n = math.floor(num(v.n, 0))
                local snd = g.sounds[(n % #g.sounds) + 1]
                local slen = spec.lenfn and spec.lenfn(snd.path)
                local speed = num(v.speed, 1)
                if not slen then
                  warn("badfile:" .. snd.path, "could not read " .. snd.file)
                elseif speed == 0 then
                  -- speed 0 plays nothing (Strudel too)
                else
                  local reverse = speed < 0
                  local rate = math.abs(speed)
                  -- pitch: note(...) repitches the sample, rate = 2^((note - root) / 12)
                  local nn = note_number(v.note)
                  if nn then rate = rate * 2 ^ ((nn - root) / 12) end
                  if v.unit == "c" then rate = rate * slen end        -- unit "c": speed counts cycles (loopAt, splice, fit)
                  rate = clamp(rate, 0.01, 100)
                  -- begin / end: a part of the file (fractions); a reversed sound is cut from the reversed file
                  local b, e = clamp(num(v.begin, 0), 0, 1), clamp(num(v["end"], 1), 0, 1)
                  if e <= b then
                    warn("beginend", "begin must be smaller than end - event skipped")
                  else
                    local offs = (reverse and (1 - e) or b) * slen
                    local region = (e - b) * slen
                    local len = region / rate
                    local looped = truthy(v.loop)
                    local ev_len = timefn(t1) - pos
                    if looped then len = ev_len end
                    local fade
                    local lim = num(v.legato, nil) or num(v.clip, nil)
                    if lim and lim > 0 then
                      local cut = timefn(t0 + (t1 - t0) * lim) - pos
                      if cut > 0 and (looped or cut < len) then len = cut; fade = 0.005 end
                    end
                    local k = string.format("%s|%d|%s|%s", spec.guid, li, tostring(ev.b), snd.file)
                    seen[k] = (seen[k] or 0) + 1
                    if seen[k] > 1 then k = k .. "#" .. seen[k] end
                    local cutg = num(v.cut, 0)
                    plan.audio[#plan.audio + 1] = {
                      key = k, owner = spec.guid, gid = Core.norm(g.name), gname = g.name, sound = snd,
                      pos = pos, len = len, fade = fade,
                      vol = clamp(num(v.gain, 1) * num(v.velocity, 1) * num(v.postgain, 1), 0, 16),
                      pan = clamp(num(v.pan, 0.5) * 2 - 1, -1, 1), rate = rate,
                      offs = offs, reverse = reverse or nil, loop = looped or nil, cut = (cutg > 0) and cutg or nil,
                    }
                    made_audio = true
                  end
                end
              end
            end
          end

          -- ------------------------------------------------ MIDI
          if want_midi then
            local chan_base = num(v.midichan, nil) or num(v.channel, nil)
            local pitch, drum
            local nv = v.note
            if type(nv) == "number" then pitch = nv
            elseif type(nv) == "string" then
              pitch = Strudel.Controls.note_to_midi(nv) or tonumber(nv)
              if not pitch then warn("badnote:" .. nv, "'" .. nv .. "' is not a note") end
            elseif sname and Core.gm_note(sname, aliases) then
              pitch, drum = Core.gm_note(sname, aliases), true
            elseif not sname and type(v.n) == "number" then
              pitch = v.n                       -- n("60 64") without a sound: the number is the MIDI note
            end
            local chan = clamp(math.floor(chan_base or (drum and 10 or 1)), 1, 16)

            -- controllers (Strudel's midi output): ccn + ccv, progNum, midibend
            if v.ccn ~= nil and v.ccv ~= nil then
              local cn, cv = num(v.ccn, nil), num(v.ccv, nil)
              if not cn or cn < 0 or cn > 127 then warn("badccn", "ccn must be a controller number 0-127")
              elseif not cv or cv < 0 or cv > 1 then warn("badccv", "ccv must be a number between 0 and 1")
              else
                ctls[#ctls + 1] = { kind = "cc", pos = pos, chan = chan, a = math.floor(cn), b = math.floor(cv * 127 + 0.5) }
                has_ctl = true
              end
            end
            if v.progNum ~= nil then
              local pn = num(v.progNum, nil)
              if not pn or pn < 0 or pn > 127 then warn("badprog", "progNum must be a number between 0 and 127")
              else ctls[#ctls + 1] = { kind = "pc", pos = pos, chan = chan, a = math.floor(pn), b = 0 }; has_ctl = true end
            end
            if v.midibend ~= nil then
              local mb = num(v.midibend, nil)
              if not mb or mb < -1 or mb > 1 then warn("badbend", "midibend must be a number between -1 and 1")
              else
                local w = clamp(math.floor((mb + 1) / 2 * 16383 + 0.5), 0, 16383)
                ctls[#ctls + 1] = { kind = "pb", pos = pos, chan = chan, a = w & 127, b = w >> 7 }
                has_ctl = true
              end
            end

            if pitch then
              -- octave(n) shifts the notes (a synth in Strudel; samples ignore it there too)
              pitch = math.floor(pitch + 12 * num(v.octave, 0) + 0.5)
              if pitch < 0 or pitch > 127 then
                warn("range" .. pitch, "note " .. pitch .. " is outside 0-127")
              else
                local lim = num(v.legato, nil) or num(v.clip, nil) or 1
                local stop = timefn(t0 + (t1 - t0) * lim)
                if stop <= pos then stop = pos + 0.001 end
                notes[#notes + 1] = {
                  pos = pos, stop = stop, pitch = pitch,
                  vel = clamp(math.floor(127 * num(v.velocity, 0.8) * num(v.gain, 1) * num(v.postgain, 1) + 0.5), 1, 127),
                  chan = chan,
                }
              end
            elseif not made_audio and sname and want_midi and not want_audio and not has_ctl then
              warn("nomidi:" .. sname, "no MIDI note for sound '" .. sname .. "' - use note(...) or a General MIDI drum name (bd sn hh oh cp ...)")
            elseif not made_audio and not has_ctl and not sname and not v.note and not v.n then
              warn("nothing" .. li, "layer " .. li .. ": an event has neither s(), note() nor n()")
            end
          end
        end
      end
    end
    if #notes > 0 or #ctls > 0 then
      plan.midi[#plan.midi + 1] = { layer = li, label = layer.label, owner = spec.guid, notes = notes, ctls = ctls }
    end
  end

  -- cut groups: a new item of a group stops the one that is still sounding (all layers of this pattern)
  local by_cut = {}
  for _, it in ipairs(plan.audio) do
    if it.cut then
      by_cut[it.cut] = by_cut[it.cut] or {}
      table.insert(by_cut[it.cut], it)
    end
  end
  for _, list in pairs(by_cut) do
    table.sort(list, function(x, y) if x.pos ~= y.pos then return x.pos < y.pos end; return x.key < y.key end)
    for i = 1, #list - 1 do
      local cur, nxt = list[i], list[i + 1]
      if nxt.pos < cur.pos + cur.len - 1e-9 and nxt.pos > cur.pos then
        cur.len = nxt.pos - cur.pos
        cur.fade = cur.fade or 0.005
      end
    end
  end
  return plan
end

--------------------------------------------------------------------------------
-- voices: items of the same sound that overlap in time go to duplicate tracks (as in PrototypeSequence)
--------------------------------------------------------------------------------
local EPS = 1e-7
function Core.allocate_voices(items)
  local by_path = {}
  for _, it in ipairs(items) do
    local l = by_path[it.sound.path]
    if not l then l = {}; by_path[it.sound.path] = l end
    l[#l + 1] = it
  end
  for _, list in pairs(by_path) do
    table.sort(list, function(a, b)
      if a.pos ~= b.pos then return a.pos < b.pos end
      return a.key < b.key
    end)
    local ends = {}
    for _, it in ipairs(list) do
      local v
      for i = 1, #ends do
        if ends[i] <= it.pos + EPS then v = i; break end
      end
      if not v then v = #ends + 1 end
      ends[v] = it.pos + it.len
      it.voice = v
    end
  end
end

--------------------------------------------------------------------------------
-- composing all patterns into the wanted project structure
--   plans = list of { pattern = <info>, plan = <plan_pattern result> }
-- returns {
--   groups = { {id=, name=, tracks = { {id=, name=, path=, voice=, items={...}} }} },   -- audio, sorted
--   midi   = { {id=, name=, owner=, layer=, notes=, pos=, len=, sig=} },                -- one per pattern layer
--   items  = flat audio list, sig = "hex" }
--------------------------------------------------------------------------------
local function voice_id(path, v) return v == 1 and path or (path .. "#" .. v) end
local function voice_name(name, v) return v == 1 and name or (name .. " (" .. v .. ")") end

function Core.compose(plans)
  local all = {}
  for _, p in ipairs(plans) do
    if p.plan then for _, it in ipairs(p.plan.audio) do all[#all + 1] = it end end
  end
  Core.allocate_voices(all)

  local gmap, glist = {}, {}
  for _, it in ipairs(all) do
    local g = gmap[it.gid]
    if not g then g = { id = it.gid, name = it.gname, tmap = {}, tracks = {} }; gmap[it.gid] = g; glist[#glist + 1] = g end
    local tid = voice_id(it.sound.path, it.voice)
    local t = g.tmap[tid]
    if not t then
      t = { id = tid, name = voice_name(it.sound.name, it.voice), path = it.sound.path, voice = it.voice,
            file = it.sound.file:lower(), items = {} }
      g.tmap[tid] = t
      g.tracks[#g.tracks + 1] = t
    end
    it.track_id = tid
    t.items[#t.items + 1] = it
  end
  table.sort(glist, function(a, b) return a.id < b.id end)
  for _, g in ipairs(glist) do
    table.sort(g.tracks, function(a, b)
      if a.file ~= b.file then return a.file < b.file end
      return a.voice < b.voice
    end)
    g.tmap = nil
  end

  local midi = {}
  for _, p in ipairs(plans) do
    if p.plan then
      for _, ml in ipairs(p.plan.midi) do
        local nm = p.pattern.name
        if ml.label then nm = nm .. " " .. ml.label
        elseif p.nlayers and p.nlayers > 1 then nm = nm .. " $" .. ml.layer end
        local parts = { fmt(p.pattern.pos), fmt(p.pattern.len) }
        for _, n in ipairs(ml.notes) do
          parts[#parts + 1] = string.format("%s,%s,%d,%d,%d", fmt(n.pos), fmt(n.stop), n.pitch, n.vel, n.chan)
        end
        for _, c in ipairs(ml.ctls or {}) do
          parts[#parts + 1] = string.format("%s:%s,%d,%d,%d", c.kind, fmt(c.pos), c.chan, c.a, c.b)
        end
        midi[#midi + 1] = {
          id = "midi:" .. p.pattern.guid .. ":" .. ml.layer, name = nm, owner = p.pattern.guid, layer = ml.layer,
          notes = ml.notes, ctls = ml.ctls or {}, pos = p.pattern.pos, len = p.pattern.len, sig = Core.hex(table.concat(parts, ";")),
        }
      end
    end
  end

  -- one signature for the whole result (what would be written into the project)
  local sp = {}
  for _, g in ipairs(glist) do
    for _, t in ipairs(g.tracks) do
      for _, it in ipairs(t.items) do sp[#sp + 1] = Core.item_sig(it) .. "@" .. t.id end
    end
  end
  for _, m in ipairs(midi) do sp[#sp + 1] = m.id .. "=" .. m.sig end
  table.sort(sp)
  return { groups = glist, midi = midi, items = all, sig = Core.hex(table.concat(sp, "\n")) }
end

-- what makes an audio item's wanted state: if this string is unchanged, the item is left alone
function Core.item_sig(it)
  return string.format("%s:%s:%s:%.4f:%.4f:%.6f:%s:%s:%s%s", it.key, fmt(it.pos), fmt(it.len), it.vol, it.pan, it.rate,
    it.fade and fmt(it.fade) or "-", fmt(it.offs or 0), it.reverse and "R" or "-", it.loop and "L" or "-")
end

return Core

end
__preload["GSReaper"] = function(...)
-- GSReaper.lua
-- Everything that touches REAPER lives here. The logic (what should exist) is in GSCore.
--
-- PATTERN ITEMS   an EMPTY item on the timeline. Its notes (P_NOTES) hold the code; P_EXT tags hold the settings.
--                 Move / resize / copy it like any item: the generated content follows.
-- MANAGED TRACKS  root "GINGERSNAP" -> collapsed group folders (one per sound folder, plus "MIDI") -> one track per
--                 sound file (duplicate "voice" tracks where the same sound overlaps) / per pattern layer (MIDI).
-- GENERATED ITEMS tagged with GS_KEY (identity), GS_OWN (owner pattern GUID) and GS_SIG (what was written).
--                 An item is only rewritten when its wanted state changed, so hand edits survive until then.

local r = reaper
local Core = require("GSCore")

local RA = {}
local SECTION = "Gingersnap"

-- tags
local E_ROLE, E_ID = "P_EXT:GS_ROLE", "P_EXT:GS_ID"                       -- tracks
local E_KEY, E_OWN, E_SIG = "P_EXT:GS_KEY", "P_EXT:GS_OWN", "P_EXT:GS_SIG" -- generated items
local E_REV = "P_EXT:GS_REV"                                                  -- generated audio item: currently reversed by us
local E_PAT, E_NAME, E_MODE, E_CYC, E_OFF = "P_EXT:GS_PAT", "P_EXT:GS_NAME", "P_EXT:GS_MODE", "P_EXT:GS_CYC", "P_EXT:GS_OFF"

RA.DEFAULT_CYCLE_QN = 4          -- one cycle = 4 quarter notes = one bar of 4/4
RA.DEFAULT_CYCLES = 4            -- new pattern items are 4 cycles long

--------------------------------------------------------------------------------
-- small helpers
--------------------------------------------------------------------------------
local function tget(tr, k) local ok, v = r.GetSetMediaTrackInfo_String(tr, k, "", false); return ok and v or "" end
local function tset(tr, k, v) r.GetSetMediaTrackInfo_String(tr, k, v, true) end
local function iget(it, k) local ok, v = r.GetSetMediaItemInfo_String(it, k, "", false); return ok and v or "" end
local function iset(it, k, v) r.GetSetMediaItemInfo_String(it, k, v, true) end
local function tidx0(tr) return math.floor(r.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER") + 0.5) - 1 end
local fmt = Core.fmt

local function set_track_val(tr, k, v)
  if r.GetMediaTrackInfo_Value(tr, k) ~= v then r.SetMediaTrackInfo_Value(tr, k, v) end
end
local function set_name(tr, name)
  local ok, cur = r.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
  if not ok or cur ~= name then r.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true) end
end
local function new_track(role, id, name)
  local idx = r.CountTracks(0)
  r.InsertTrackAtIndex(idx, false)
  local tr = r.GetTrack(0, idx)
  tset(tr, E_ROLE, role); tset(tr, E_ID, id)
  set_name(tr, name)
  return tr
end

--------------------------------------------------------------------------------
-- settings
--   PROJECT (saved in the .rpp): root (sounds folder), mode (live / frozen), sig (what was last rendered)
--   GLOBAL  (reaper-extstate.ini): default_root, follow
-- Values are only written when they differ from what is stored, so opening the window does not dirty the project.
--------------------------------------------------------------------------------
local written = {}
local function pset(k, v)
  v = v or ""
  if written[k] ~= v then r.SetProjExtState(0, SECTION, k, v); written[k] = v end
end
local function gset(k, v)
  if r.GetExtState(SECTION, k) ~= v then r.SetExtState(SECTION, k, v, true) end
end

function RA.load_cfg()
  written = {}
  local function pget(k) local _, v = r.GetProjExtState(0, SECTION, k); written[k] = v; return v end
  local cfg = { root = pget("root"), mode = pget("mode") }
  cfg.follow = (r.GetExtState(SECTION, "follow") ~= "0")
  cfg.aliases = (r.GetExtState(SECTION, "aliases") == "1")                -- standard drum aliases (sd rim lt mt ht cr rd cb perc): off by default
  cfg.root_note = tonumber(r.GetExtState(SECTION, "root_note")) or Core.DEFAULT_ROOT_NOTE
  cfg.default_root = r.GetExtState(SECTION, "default_root")
  cfg.inherited = false
  if cfg.root == "" and cfg.default_root ~= "" then cfg.root = cfg.default_root; cfg.inherited = true end
  cfg.mode = (cfg.mode == "frozen") and "frozen" or "live"
  return cfg
end
function RA.save_cfg(cfg)
  if not cfg.inherited then pset("root", cfg.root) end
  pset("mode", cfg.mode)
  RA.save_prefs(cfg)
end
function RA.save_prefs(cfg)
  gset("follow", cfg.follow and "1" or "0")
  gset("aliases", cfg.aliases and "1" or "0")
  gset("root_note", tostring(cfg.root_note or Core.DEFAULT_ROOT_NOTE))
  if cfg.default_root and cfg.default_root ~= "" then gset("default_root", cfg.default_root) end
end
function RA.load_sig() local _, v = r.GetProjExtState(0, SECTION, "sig"); written.sig = v; return v ~= "" and v or nil end
function RA.save_sig(s) pset("sig", s or "") end

--------------------------------------------------------------------------------
-- sound folders  root/<sound name>/<files>      (one level, like PrototypeSequence)
--------------------------------------------------------------------------------
function RA.clean_path(p)
  p = tostring(p or ""):gsub("^%s+", ""):gsub("%s+$", "")
  p = p:gsub('^"(.*)"$', "%1")
  if #p > 1 then p = p:gsub("[/\\]+$", "") end
  return p
end
local function is_dir(p)
  if r.EnumerateSubdirectories(p, 0) or r.EnumerateFiles(p, 0) then return true end
  if r.file_exists and r.file_exists(p) then return false end
  return not Core.is_audio(p)
end
function RA.resolve_root(p)
  p = RA.clean_path(p)
  if p == "" then return "" end
  if is_dir(p) then return p end
  return (p:gsub("[/\\][^/\\]*$", ""))
end

function RA.scan(root)
  local groups, n = {}, 0
  if not root or root == "" then return groups, 0 end
  r.EnumerateSubdirectories(root, -1)
  local i = 0
  while true do
    local d = r.EnumerateSubdirectories(root, i)
    if not d then break end
    i = i + 1
    if d:sub(1, 1) ~= "." then
      local id = Core.norm(d)
      if id ~= "" and not groups[id] then
        local path = root .. "/" .. d
        r.EnumerateFiles(path, -1)
        local sounds, j = {}, 0
        while true do
          local f = r.EnumerateFiles(path, j)
          if not f then break end
          j = j + 1
          if Core.is_audio(f) and f:sub(1, 1) ~= "." then
            sounds[#sounds + 1] = { file = f, name = Core.strip_ext(f), path = path .. "/" .. f }
          end
        end
        table.sort(sounds, function(a, b) return a.file:lower() < b.file:lower() end)
        groups[id] = { name = d, sounds = sounds, path = path }
        n = n + 1
      end
    end
  end
  return groups, n
end

local len_cache = {}
function RA.clear_len_cache() len_cache = {} end
function RA.file_len(path)
  local v = len_cache[path]
  if v == nil then
    v = false
    local src = r.PCM_Source_CreateFromFile(path)
    if src then
      local len, is_qn = r.GetMediaSourceLength(src)
      if len and not is_qn and len > 0 then v = len end
      if r.PCM_Source_Destroy then r.PCM_Source_Destroy(src) end
    end
    len_cache[path] = v
  end
  return v or nil
end

--------------------------------------------------------------------------------
-- time: cycles <-> quarter notes <-> seconds (tempo map aware)
--------------------------------------------------------------------------------
function RA.qn_of(t) return r.TimeMap2_timeToQN(0, t) end
function RA.time_of_qn(q) return r.TimeMap2_QNToTime(0, q) end

-- changes whenever the tempo map changes (part of the signature of every pattern)
function RA.tempo_fp()
  local parts = { string.format("%.4f", r.Master_GetTempo and r.Master_GetTempo() or 120) }
  local n = r.CountTempoTimeSigMarkers and r.CountTempoTimeSigMarkers(0) or 0
  for i = 0, n - 1 do
    local _, t, _, _, bpm, num, den, lin = r.GetTempoTimeSigMarker(0, i)
    parts[#parts + 1] = string.format("%.5f/%.4f/%s/%s/%s", t or 0, bpm or 0, tostring(num), tostring(den), tostring(lin))
  end
  return table.concat(parts, ";")
end

--------------------------------------------------------------------------------
-- pattern items
--------------------------------------------------------------------------------
local function valid_item(it) return it and (not r.ValidatePtr2 or r.ValidatePtr2(0, it, "MediaItem*")) end
RA.valid_item = valid_item

local function read_pattern(it)
  local guid = iget(it, "GUID")
  local cyc = tonumber(iget(it, E_CYC))
  if not cyc or cyc <= 0 then cyc = RA.DEFAULT_CYCLE_QN end
  local mode = iget(it, E_MODE)
  if mode ~= "midi" and mode ~= "both" then mode = "audio" end
  local pos, len = r.GetMediaItemInfo_Value(it, "D_POSITION"), r.GetMediaItemInfo_Value(it, "D_LENGTH")
  local qn0 = RA.qn_of(pos)
  return {
    item = it, guid = guid, code = iget(it, "P_NOTES"), name = iget(it, E_NAME), mode = mode, cycle_qn = cyc,
    off = iget(it, E_OFF) == "1", pos = pos, len = len, selected = r.IsMediaItemSelected(it),
    cycles = (RA.qn_of(pos + len) - qn0) / cyc,
    track = r.GetMediaItemTrack(it),
  }
end

-- all pattern items of the project, in timeline order
function RA.read_patterns()
  local out = {}
  for i = 0, r.CountMediaItems(0) - 1 do
    local it = r.GetMediaItem(0, i)
    if r.CountTakes(it) == 0 and iget(it, E_PAT) == "1" then out[#out + 1] = read_pattern(it) end
  end
  table.sort(out, function(a, b)
    if a.pos ~= b.pos then return a.pos < b.pos end
    return a.guid < b.guid
  end)
  return out
end

local function tag_pattern(it, name, mode, cyc)
  iset(it, E_PAT, "1")
  iset(it, E_NAME, name)
  iset(it, E_MODE, mode or "audio")
  iset(it, E_CYC, tostring(cyc or RA.DEFAULT_CYCLE_QN))
  local col = r.ColorToNative and r.ColorToNative(120, 200, 140) or 0
  r.SetMediaItemInfo_Value(it, "I_CUSTOMCOLOR", col | 0x1000000)
end

local function pattern_track()
  local tr = r.GetSelectedTrack(0, 0)
  if tr and tget(tr, E_ROLE) == "" then return tr end
  for i = 0, r.CountTracks(0) - 1 do              -- an existing plain "Patterns" track
    local t = r.GetTrack(0, i)
    local ok, nm = r.GetSetMediaTrackInfo_String(t, "P_NAME", "", false)
    if ok and nm == "Patterns" and tget(t, E_ROLE) == "" then return t end
  end
  r.InsertTrackAtIndex(0, true)
  tr = r.GetTrack(0, 0)
  set_name(tr, "Patterns")
  return tr
end

local function next_name(existing)
  local n = 0
  for _, p in ipairs(existing or {}) do
    local k = tonumber((p.name or ""):match("^Pattern (%d+)$"))
    if k and k > n then n = k end
  end
  return "Pattern " .. (n + 1)
end

-- creates an empty item at the edit cursor (or the start of the time selection) and turns it into a pattern
function RA.new_pattern(code, existing, mode)
  local ok, res = pcall(function()
    local tr = pattern_track()
    local s, e = r.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
    local pos = (e and s and e > s) and s or r.GetCursorPosition()
    local qn0 = RA.qn_of(pos)
    local len = RA.time_of_qn(qn0 + RA.DEFAULT_CYCLES * RA.DEFAULT_CYCLE_QN) - pos
    if e and s and e > s then len = e - s end
    local it = r.AddMediaItemToTrack(tr)
    r.SetMediaItemInfo_Value(it, "D_POSITION", pos)
    r.SetMediaItemInfo_Value(it, "D_LENGTH", len)
    iset(it, "P_NOTES", code)
    tag_pattern(it, next_name(existing), mode)
    r.UpdateItemInProject(it)
    return it
  end)
  if not ok then return nil, res end
  return res
end

-- turns the selected EMPTY items into patterns (their notes become the code)
function RA.adopt_selected(default_code, existing)
  local n = 0
  local sel = {}
  for i = 0, r.CountSelectedMediaItems(0) - 1 do sel[#sel + 1] = r.GetSelectedMediaItem(0, i) end
  for _, it in ipairs(sel) do
    if r.CountTakes(it) == 0 and iget(it, E_PAT) ~= "1" and iget(it, E_KEY) == "" then
      if iget(it, "P_NOTES") == "" then iset(it, "P_NOTES", default_code) end
      tag_pattern(it, next_name(existing), "audio")
      existing = existing or {}
      existing[#existing + 1] = { name = iget(it, E_NAME) }
      n = n + 1
    end
  end
  return n
end

function RA.set_code(it, code) if valid_item(it) and iget(it, "P_NOTES") ~= code then iset(it, "P_NOTES", code) end end
function RA.set_name(it, name) if valid_item(it) then iset(it, E_NAME, name) end end
function RA.set_mode(it, mode) if valid_item(it) then iset(it, E_MODE, mode) end end
function RA.set_cycle(it, qn) if valid_item(it) then iset(it, E_CYC, tostring(qn)) end end
function RA.set_off(it, off) if valid_item(it) then iset(it, E_OFF, off and "1" or "") end end

function RA.select_pattern(it, move_cursor)
  if not valid_item(it) then return end
  for i = r.CountSelectedMediaItems(0) - 1, 0, -1 do r.SetMediaItemSelected(r.GetSelectedMediaItem(0, i), false) end
  r.SetMediaItemSelected(it, true)
  if move_cursor then r.SetEditCurPos(r.GetMediaItemInfo_Value(it, "D_POSITION"), true, false) end
  r.UpdateArrange()
end

function RA.delete_pattern(it)
  if not valid_item(it) then return end
  r.DeleteTrackMediaItem(r.GetMediaItemTrack(it), it)
  r.UpdateArrange()
end

--------------------------------------------------------------------------------
-- track bookkeeping
--------------------------------------------------------------------------------
function RA.index_tracks()
  local ex = { list = {}, groups = {}, snds = {}, midis = {} }
  for i = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    local role = tget(tr, E_ROLE)
    if role ~= "" then
      local id = tget(tr, E_ID)
      local rec = { tr = tr, role = role, id = id }
      ex.list[#ex.list + 1] = rec
      if role == "root" then
        if ex.root then rec.dup = true else ex.root = tr end
      elseif role == "group" then
        if ex.groups[id] then rec.dup = true else ex.groups[id] = tr end
      elseif role == "snd" then
        if ex.snds[id] then rec.dup = true else ex.snds[id] = tr end
      elseif role == "midi" then
        if ex.midis[id] then rec.dup = true else ex.midis[id] = tr end
      end
    end
  end
  return ex
end

local function save_selection()
  local s = {}
  for i = 0, r.CountSelectedTracks(0) - 1 do s[r.GetSelectedTrack(0, i)] = true end
  local items = {}
  for i = 0, r.CountSelectedMediaItems(0) - 1 do items[#items + 1] = r.GetSelectedMediaItem(0, i) end
  return s, items
end
local function restore_selection(s, items)
  for i = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    r.SetTrackSelected(tr, s[tr] == true)
  end
  for i = r.CountSelectedMediaItems(0) - 1, 0, -1 do r.SetMediaItemSelected(r.GetSelectedMediaItem(0, i), false) end
  for _, it in ipairs(items) do if valid_item(it) then r.SetMediaItemSelected(it, true) end end
end

local function order_tracks(D)
  for _ = 1, 4 do
    local moved = false
    for i = 2, #D do
      local want = tidx0(D[1]) + i - 1
      local cur = tidx0(D[i])
      if cur ~= want then
        r.SetOnlyTrackSelected(D[i])
        r.ReorderSelectedTracks((cur > want) and want or (want + 1), 0)
        moved = true
      end
    end
    if not moved then break end
  end
end

function RA.apply_depths(root, layout)
  if #layout == 0 then set_track_val(root, "I_FOLDERDEPTH", 0); return end
  set_track_val(root, "I_FOLDERDEPTH", 1)
  for gi, L in ipairs(layout) do
    set_track_val(L.track, "I_FOLDERDEPTH", 1)
    set_track_val(L.track, "I_FOLDERCOMPACT", 2)
    for ki, kt in ipairs(L.kids) do
      local d = 0
      if ki == #L.kids then d = (gi == #layout) and -2 or -1 end
      set_track_val(kt, "I_FOLDERDEPTH", d)
    end
  end
end

local function untag_item(it)
  for _, k in ipairs({ E_KEY, E_OWN, E_SIG, E_REV }) do if iget(it, k) ~= "" then iset(it, k, "") end end
end
local function release_track(tr)
  for i = 0, r.CountTrackMediaItems(tr) - 1 do untag_item(r.GetTrackMediaItem(tr, i)) end
  tset(tr, E_ROLE, ""); tset(tr, E_ID, "")
  set_track_val(tr, "I_FOLDERDEPTH", 0)
end

local function with_undo(label, fn)
  local sel, items = save_selection()
  r.PreventUIRefresh(1)
  r.Undo_BeginBlock2(0)
  local ok, res = pcall(fn)
  restore_selection(sel, items)
  r.PreventUIRefresh(-1)
  r.TrackList_AdjustWindows(false)
  r.UpdateArrange()
  r.Undo_EndBlock2(0, label, -1)
  if not ok then return nil, res end
  return res
end

--------------------------------------------------------------------------------
-- SYNC: make the GINGERSNAP tracks / items match the composed plan
--------------------------------------------------------------------------------
-- reverse = REAPER's own "Item properties: Toggle take reverse" (action 41051); it acts on the selected items.
-- NOT verified in real REAPER (offline tests only see the fake). The reversed state is remembered in a tag, and the
-- item is turned back before every rewrite so that start offset / length mean the same thing as for a normal item.
local TOGGLE_TAKE_REVERSE = 41051
local function set_reverse(it, want)
  local have = iget(it, E_REV) == "1"
  if have == want then return end
  for i = r.CountSelectedMediaItems(0) - 1, 0, -1 do r.SetMediaItemSelected(r.GetSelectedMediaItem(0, i), false) end
  r.SetMediaItemSelected(it, true)
  r.Main_OnCommand(TOGGLE_TAKE_REVERSE, 0)
  r.SetMediaItemSelected(it, false)
  iset(it, E_REV, want and "1" or "")
end

local function apply_audio_item(it, wi)
  set_reverse(it, false)
  r.SetMediaItemInfo_Value(it, "D_POSITION", wi.pos)
  r.SetMediaItemInfo_Value(it, "D_LENGTH", wi.len)
  r.SetMediaItemInfo_Value(it, "D_VOL", wi.vol)
  r.SetMediaItemInfo_Value(it, "D_FADEOUTLEN", wi.fade or 0)
  r.SetMediaItemInfo_Value(it, "B_LOOPSRC", wi.loop and 1 or 0)
  local take = r.GetActiveTake(it)
  if take then
    r.SetMediaItemTakeInfo_Value(take, "D_PAN", wi.pan)
    r.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", wi.rate)
    r.SetMediaItemTakeInfo_Value(take, "B_PPITCH", 0)
    r.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", wi.offs or 0)
  end
  if wi.reverse then set_reverse(it, true) end
end

local function build_midi_item(tr, m)
  local it = r.CreateNewMIDIItemInProj(tr, m.pos, m.pos + m.len, false)
  if not it then return nil end
  local take = r.GetActiveTake(it)
  if take then
    r.MIDI_DisableSort(take)
    for _, n in ipairs(m.notes) do
      local s = r.MIDI_GetPPQPosFromProjTime(take, n.pos)
      local e = r.MIDI_GetPPQPosFromProjTime(take, n.stop)
      r.MIDI_InsertNote(take, false, false, s, e, n.chan - 1, n.pitch, n.vel, true)
    end
    -- controllers: Strudel's ccn / ccv, progNum, midibend
    local CHANMSG = { cc = 0xB0, pc = 0xC0, pb = 0xE0 }
    for _, c in ipairs(m.ctls or {}) do
      r.MIDI_InsertCC(take, false, false, r.MIDI_GetPPQPosFromProjTime(take, c.pos), CHANMSG[c.kind], c.chan - 1, c.a, c.b)
    end
    r.MIDI_Sort(take)
  end
  return it
end

-- comp = Core.compose(...);  valid = { [pattern guid] = true } (patterns that exist and are switched on)
function RA.sync(comp)
  local st = { tracks_new = 0, tracks_del = 0, items_new = 0, items_upd = 0, items_del = 0, midi_new = 0, bad = {} }

  local res, err = with_undo("Gingersnap: render", function()
    local ex = RA.index_tracks()
    local root = ex.root
    local need_root = (#comp.groups > 0) or (#comp.midi > 0)
    if not root and need_root then root = new_track("root", "GINGERSNAP", "GINGERSNAP"); st.tracks_new = st.tracks_new + 1 end

    -- 1. wanted tracks --------------------------------------------------------------
    local D, layout, want_tr, track_of = { root }, {}, {}, {}
    if root then want_tr[root] = true end
    if #comp.midi > 0 then
      local gt = ex.groups["@midi"]
      if not gt then gt = new_track("group", "@midi", "MIDI"); st.tracks_new = st.tracks_new + 1 end
      want_tr[gt] = true; D[#D + 1] = gt
      local L = { track = gt, kids = {} }
      for _, m in ipairs(comp.midi) do
        local tr = ex.midis[m.id]
        if not tr then tr = new_track("midi", m.id, m.name); st.tracks_new = st.tracks_new + 1 end
        want_tr[tr] = true; D[#D + 1] = tr; L.kids[#L.kids + 1] = tr; track_of[m.id] = tr
      end
      layout[#layout + 1] = L
    end
    for _, g in ipairs(comp.groups) do
      local gt = ex.groups[g.id]
      if not gt then gt = new_track("group", g.id, g.name); st.tracks_new = st.tracks_new + 1 end
      want_tr[gt] = true; D[#D + 1] = gt
      local L = { track = gt, kids = {} }
      for _, t in ipairs(g.tracks) do
        local tr = ex.snds[t.id]
        if not tr then tr = new_track("snd", t.id, t.name); st.tracks_new = st.tracks_new + 1 end
        want_tr[tr] = true; D[#D + 1] = tr; L.kids[#L.kids + 1] = tr; track_of[t.id] = tr
      end
      layout[#layout + 1] = L
    end

    -- 2. what exists: generated items by key (duplicates are removed) --------------
    local have, dups = {}, {}
    for _, rec in ipairs(ex.list) do
      if rec.role == "snd" or rec.role == "midi" then
        for i = 0, r.CountTrackMediaItems(rec.tr) - 1 do
          local it = r.GetTrackMediaItem(rec.tr, i)
          local key = iget(it, E_KEY)
          if key ~= "" then
            if have[key] then dups[#dups + 1] = { tr = rec.tr, it = it } else have[key] = { it = it, tr = rec.tr } end
          end
        end
      end
    end
    for _, d in ipairs(dups) do r.DeleteTrackMediaItem(d.tr, d.it); st.items_del = st.items_del + 1 end

    -- 3. audio items ---------------------------------------------------------------
    local wanted = {}
    for _, g in ipairs(comp.groups) do
      for _, t in ipairs(g.tracks) do
        local tr = track_of[t.id]
        for _, wi in ipairs(t.items) do
          wanted[wi.key] = true
          local rec = have[wi.key]
          local it = rec and rec.it
          if it and rec.tr ~= tr then r.MoveMediaItemToTrack(it, tr); rec.tr = tr end
          local fresh = false
          if not it then
            local src = r.PCM_Source_CreateFromFile(t.path)
            if not src then
              st.bad[t.path] = true
            else
              it = r.AddMediaItemToTrack(tr)
              local take = r.AddTakeToMediaItem(it)
              r.SetMediaItemTake_Source(take, src)
              r.GetSetMediaItemTakeInfo_String(take, "P_NAME", wi.sound.name, true)
              iset(it, E_KEY, wi.key); iset(it, E_OWN, wi.owner)
              st.items_new = st.items_new + 1
              fresh = true
            end
          end
          if it then
            local sig = Core.item_sig(wi)
            if fresh or iget(it, E_SIG) ~= sig then
              apply_audio_item(it, wi)
              iset(it, E_SIG, sig)
              if not fresh then st.items_upd = st.items_upd + 1 end
            end
          end
        end
      end
    end

    -- 4. MIDI items ----------------------------------------------------------------
    for _, m in ipairs(comp.midi) do
      wanted[m.id] = true
      local tr = track_of[m.id]
      local rec = have[m.id]
      if rec and rec.tr ~= tr then r.MoveMediaItemToTrack(rec.it, tr); rec.tr = tr end
      if not (rec and iget(rec.it, E_SIG) == m.sig) then
        if rec then r.DeleteTrackMediaItem(rec.tr, rec.it); st.items_del = st.items_del + 1 end
        local it = build_midi_item(tr, m)
        if it then
          iset(it, E_KEY, m.id); iset(it, E_OWN, m.owner); iset(it, E_SIG, m.sig)
          st.midi_new = st.midi_new + 1
        end
      end
    end

    -- 5. stale items and obsolete tracks --------------------------------------------
    for key, rec in pairs(have) do
      if not wanted[key] then r.DeleteTrackMediaItem(rec.tr, rec.it); st.items_del = st.items_del + 1 end
    end
    for _, rec in ipairs(ex.list) do
      local tr = rec.tr
      if rec.dup then
        release_track(tr)                                   -- a copy of a managed track: keep it, just not managed
      elseif not want_tr[tr] then
        if r.CountTrackMediaItems(tr) == 0 and (rec.role ~= "root" or not need_root) then
          r.DeleteTrack(tr); st.tracks_del = st.tracks_del + 1
        else                                                -- has content that is not ours: hand it back
          release_track(tr)
        end
      end
    end

    -- 6. order + folder structure ----------------------------------------------------
    if root then
      order_tracks(D)
      RA.apply_depths(root, layout)
    end
    return st
  end)
  if not res then return nil, err end
  return st
end

--------------------------------------------------------------------------------
-- freeze / detach
--------------------------------------------------------------------------------
-- keep everything a pattern generated as ordinary items and switch the pattern off
function RA.freeze_pattern(pat)
  local n = 0
  for i = 0, r.CountMediaItems(0) - 1 do
    local it = r.GetMediaItem(0, i)
    if iget(it, E_OWN) == pat.guid then untag_item(it); n = n + 1 end
  end
  RA.set_off(pat.item, true)
  return n
end

-- stop managing everything: tags removed, tracks and items stay as ordinary ones, patterns switched off
function RA.detach()
  local st = { tracks = 0, items = 0 }
  local res, err = with_undo("Gingersnap: detach", function()
    for _, rec in ipairs(RA.index_tracks().list) do release_track(rec.tr); st.tracks = st.tracks + 1 end
    for i = 0, r.CountMediaItems(0) - 1 do
      local it = r.GetMediaItem(0, i)
      if iget(it, E_KEY) ~= "" or iget(it, E_OWN) ~= "" then untag_item(it); st.items = st.items + 1 end
      if iget(it, E_PAT) == "1" then iset(it, E_OFF, "1") end
    end
    return st
  end)
  if not res then return nil, err end
  return st
end

-- number of managed tracks / generated items (for the status line)
function RA.managed_info()
  local info = { tracks = 0, items = 0 }
  for i = 0, r.CountTracks(0) - 1 do
    if tget(r.GetTrack(0, i), E_ROLE) ~= "" then info.tracks = info.tracks + 1 end
  end
  return info
end

function RA.show_root()
  local ex = RA.index_tracks()
  if ex.root then r.SetOnlyTrackSelected(ex.root); r.SetMixerScroll(ex.root); r.Main_OnCommand(40913, 0) end
end

return RA

end
__preload["GSApp"] = function(...)
-- GSApp.lua
-- State + main tick. No drawing in here. The UI only reads the fields and calls the methods below.
--
--   live   : every change of a pattern (code, position, length, settings), of the tempo map or of the sound
--            folders is rendered into the project (after DEBOUNCE seconds of quiet)
--   frozen : nothing is touched any more (button: Render once)

local r = reaper
local Core = require("GSCore")
local RA = require("GSReaper")
local Strudel = require("strudel")

local App = {}
App.__index = App

local DEBOUNCE = 0.35            -- seconds after the last project change before rendering
local CODE_IDLE = 0.4            -- seconds after the last keystroke before the code is written into the item
local DEFAULT_CODE = '// 1 cycle = 1 bar. Edit me - the timeline follows.\n$: s("bd*2, ~ sn, hh*4")\n'

function App.new()
  local self = setmetatable({}, App)
  self.proj = r.EnumProjects(-1)
  self.cfg = RA.load_cfg()
  self.groups, self.ngroups, self.gsig = {}, 0, ""
  self.patterns = {}            -- pattern items, timeline order (RA.read_patterns)
  self.info = { tracks = 0 }
  self.evals = {}               -- code -> { res=, err= }
  self.plans = {}               -- guid -> { insig=, plan=, err= }
  self.status = {}              -- guid -> { err=, warnings={}, events=n }
  self.comp = nil
  self.cur = nil                -- guid of the pattern shown in the editor
  self.edit = { guid = nil, code = "", t = nil }
  self.last_count = -1
  self.last_sig = RA.load_sig()
  self.last_sel = nil
  self.pending_t, self.force = nil, false
  self.msg, self.err = nil, nil
  if self.cfg.root ~= "" then self:rescan() end
  return self
end

function App:save() RA.save_cfg(self.cfg) end
function App:live() return self.cfg.mode == "live" end

--------------------------------------------------------------------------------
-- sound folder
--------------------------------------------------------------------------------
function App:rescan()
  RA.clear_len_cache()
  self.groups, self.ngroups = RA.scan(self.cfg.root)
  self.gsig = Core.groups_sig(self.groups)
  self.plans = {}                          -- lengths / files may have changed
  self.last_count = -1
  if self.cfg.root == "" then self.msg = nil
  elseif self.ngroups == 0 then self.err = "No sub-folders found in " .. self.cfg.root .. " (one sub-folder per sound: root/bd/*.wav)"; return
  end
  self.err = nil
end

function App:update_folder()
  self:rescan()
  self.last_sig = nil
  if self.err == nil then self.msg = string.format("Folder re-read: %d sounds.", self.ngroups) end
end

function App:set_root(path)
  local p = RA.resolve_root(path)
  if p == "" then return end
  self.cfg.root = p
  self.cfg.inherited = false
  if self.cfg.default_root == "" then self.cfg.default_root = p end
  self:rescan()
  self:save()
end
function App:make_default()
  if self.cfg.root == "" then return end
  self.cfg.default_root = self.cfg.root
  RA.save_prefs(self.cfg)
  self.msg = "Default folder for new projects: " .. self.cfg.root
end
function App:use_default()
  if self.cfg.default_root == "" then return end
  self:set_root(self.cfg.default_root)
end

function App:freeze_all() self.cfg.mode = "frozen"; self.pending_t = nil; self:save(); self.msg = "Frozen: the project is left alone." end
function App:go_live() self.cfg.mode = "live"; self.last_sig = nil; self.last_count = -1; self:save(); self.msg = nil end
function App:render_now() self.force = true end
function App:set_follow(on) self.cfg.follow = on and true or false; RA.save_prefs(self.cfg) end
-- "Standard drum aliases": sd rim lt mt ht cr rd cb perc (folder lookup and General MIDI drums). Global, off by default.
function App:set_aliases(on) self.cfg.aliases = on and true or false; RA.save_prefs(self.cfg); self.last_count = -1 end
-- the note at which a sample plays unchanged when a pattern uses note(...) (Strudel: 36 = c2). Accepts 36 or a note name.
function App:set_root_note(text)
  local n = tonumber(text) or Strudel.Controls.note_to_midi((tostring(text or ""):gsub("%s", "")))
  if not n then self.err = "Root note: write a MIDI number (36) or a note name (c2)."; return false end
  self.cfg.root_note = math.max(0, math.min(127, math.floor(n + 0.5)))
  RA.save_prefs(self.cfg); self.last_count = -1; self.err = nil
  return true
end
function App:show_root() RA.show_root() end

function App:detach()
  local st, err = RA.detach()
  self.cfg.mode = "frozen"; self.pending_t = nil; self.last_sig = nil; RA.save_sig(nil); self:save()
  if not st then self.err = tostring(err); return end
  self.err = nil
  self.msg = string.format("Detached %d tracks: they are ordinary tracks now. Patterns are switched off.", st.tracks)
end

--------------------------------------------------------------------------------
-- patterns
--------------------------------------------------------------------------------
function App:pattern(guid)
  for _, p in ipairs(self.patterns) do if p.guid == guid then return p end end
end
function App:current() return self.cur and self:pattern(self.cur) or nil end

function App:default_code()
  -- use real folder names when there are some
  local ids = {}
  for id in pairs(self.groups) do ids[#ids + 1] = id end
  table.sort(ids)
  if #ids >= 2 then
    local a, b = self.groups[ids[1]].name, self.groups[ids[2]].name
    return string.format('// 1 cycle = 1 bar. Edit me - the timeline follows.\n$: s("%s*2, ~ %s")\n', a, b)
  elseif #ids == 1 then
    return string.format('// 1 cycle = 1 bar. Edit me - the timeline follows.\n$: s("%s*4")\n', self.groups[ids[1]].name)
  end
  return DEFAULT_CODE
end

function App:select(guid, move_cursor)
  local p = self:pattern(guid)
  if not p then return end
  self:commit_code()
  self.cur = guid
  self.edit = { guid = guid, code = p.code, t = nil }
  RA.select_pattern(p.item, move_cursor)
  self.last_sel = guid
end

function App:new_pattern()
  local it, err = RA.new_pattern(self:default_code(), self.patterns, "audio")
  if not it then self.err = "Could not create the pattern item: " .. tostring(err); return end
  self.err = nil
  self:refresh()
  for _, p in ipairs(self.patterns) do
    if p.item == it then self:select(p.guid, false) break end
  end
  self.msg = "Pattern item created. Move / resize it on the timeline; it is rendered while you edit."
end

function App:adopt()
  local n = RA.adopt_selected(self:default_code(), self.patterns)
  if n == 0 then self.err = "Select an EMPTY item first (Insert > Empty item). Its notes become the code."; return end
  self.err = nil
  self:refresh()
  self.msg = n .. " item(s) turned into patterns."
end

-- the editor buffer -> the item's notes (debounced from tick)
function App:set_edit_code(code)
  if code == self.edit.code then return end
  self.edit.code = code
  self.edit.t = r.time_precise()
end
function App:commit_code()
  local e = self.edit
  if e.t and e.guid then
    local p = self:pattern(e.guid)
    if p then RA.set_code(p.item, e.code); p.code = e.code end
    e.t = nil
    self.last_count = -1
  end
end

local function on_pattern(self, guid, fn)
  local p = self:pattern(guid)
  if p and RA.valid_item(p.item) then fn(p); self.last_count = -1 end
end
function App:set_mode(guid, audio, midi)
  local mode = (audio and midi) and "both" or (midi and "midi" or "audio")
  on_pattern(self, guid, function(p) RA.set_mode(p.item, mode) end)
end
function App:set_cycle(guid, qn)
  qn = tonumber(qn) or RA.DEFAULT_CYCLE_QN
  qn = math.max(0.25, math.min(64, qn))
  on_pattern(self, guid, function(p) RA.set_cycle(p.item, qn) end)
end
function App:set_name(guid, name)
  name = tostring(name or ""):gsub("[\r\n]", " ")
  if name == "" then name = "Pattern" end
  on_pattern(self, guid, function(p) RA.set_name(p.item, name) end)
end
function App:set_off(guid, off) on_pattern(self, guid, function(p) RA.set_off(p.item, off) end) end
function App:delete_pattern(guid)
  local p = self:pattern(guid)
  if not p then return end
  RA.delete_pattern(p.item)
  if self.cur == guid then self.cur = nil; self.edit = { guid = nil, code = "" } end
  self.last_count = -1
  self.msg = "Pattern deleted; its generated items are removed on the next render."
end
function App:freeze_pattern(guid)
  local p = self:pattern(guid)
  if not p then return end
  self:commit_code()
  local n = RA.freeze_pattern(p)
  self.last_count = -1
  self.pending_t = nil
  self.last_sig = nil
  self.msg = string.format("Frozen %d items: they are ordinary items now, and the pattern is switched off.", n)
end

--------------------------------------------------------------------------------
-- evaluation and planning (cached: only patterns whose inputs changed are recomputed)
--------------------------------------------------------------------------------
function App:evaluate(code)
  local e = self.evals[code]
  if not e then
    local res, err = Strudel.run(code)
    e = { res = res, err = err }
    local n = 0
    for _ in pairs(self.evals) do n = n + 1 end
    if n > 200 then self.evals = {} end
    self.evals[code] = e
  end
  return e
end

function App:plan_for(p, tempo_fp)
  local insig = Core.hex(table.concat({ p.code, p.mode, tostring(p.cycle_qn), Core.fmt(p.pos), Core.fmt(p.len), tempo_fp, self.gsig, self.cfg.root,
    tostring(self.cfg.aliases), tostring(self.cfg.root_note) }, "\1"))
  local c = self.plans[p.guid]
  if c and c.insig == insig then return c end
  c = { insig = insig }
  local e = self:evaluate(p.code)
  if not e.res then
    c.err = e.err or "cannot evaluate"
  else
    local qn0 = RA.qn_of(p.pos)
    local plan, err = Core.plan_pattern({
      guid = p.guid, name = p.name, layers = e.res.layers, mode = p.mode, groups = self.groups,
      cycles = p.cycles, lenfn = RA.file_len, aliases = self.cfg.aliases, root_note = self.cfg.root_note,
      timefn = function(cyc) return RA.time_of_qn(qn0 + cyc * p.cycle_qn) end,
    })
    if not plan then c.err = err
    else
      c.plan, c.nlayers = plan, #e.res.layers
      c.warnings = {}
      for _, w in ipairs(e.res.warnings) do c.warnings[#c.warnings + 1] = w end
      for _, w in ipairs(plan.warnings) do c.warnings[#c.warnings + 1] = w end
      if #e.res.layers == 0 then c.warnings[#c.warnings + 1] = "no pattern found - start a line with  $:  (e.g.  $: s(\"bd sn\"))" end
    end
  end
  self.plans[p.guid] = c
  return c
end

-- reads the pattern items and recomputes the wanted result
function App:refresh()
  self.patterns = RA.read_patterns()
  local tempo = RA.tempo_fp()
  local plans, status, live_guid = {}, {}, {}
  for _, p in ipairs(self.patterns) do
    live_guid[p.guid] = true
    if p.name == "" then p.name = "Pattern" end
    if p.off then
      status[p.guid] = { off = true }
    else
      local c = self:plan_for(p, tempo)
      status[p.guid] = { err = c.err, warnings = c.warnings or {}, events = c.plan and c.plan.events or 0 }
      if c.plan then plans[#plans + 1] = { pattern = p, plan = c.plan, nlayers = c.nlayers } end
    end
  end
  for g in pairs(self.plans) do if not live_guid[g] then self.plans[g] = nil end end
  self.status = status
  -- an error in any pattern pauses rendering: its old output stays exactly as it is until the code works again
  self.blocked = nil
  for _, p in ipairs(self.patterns) do
    local st = status[p.guid]
    if st and st.err then self.blocked = (p.name ~= "" and p.name or "Pattern") .. ": " .. st.err; break end
  end
  self.comp = Core.compose(plans)
  self.sig = self.comp.sig .. "|" .. tostring(#self.patterns)
  -- keep the editor on a pattern that still exists
  if self.cur and not live_guid[self.cur] then self.cur = nil; self.edit = { guid = nil, code = "" } end
  if not self.cur and self.patterns[1] then
    self.cur = self.patterns[1].guid
    self.edit = { guid = self.cur, code = self.patterns[1].code, t = nil }
  end
  -- external edits (item notes changed in REAPER) show up in the editor unless we are typing
  local cp = self:current()
  if cp and not self.edit.t and cp.code ~= self.edit.code then self.edit.code = cp.code end
  if self.sig ~= self.last_sig then self.pending_t = r.time_precise() end
end

--------------------------------------------------------------------------------
-- render
--------------------------------------------------------------------------------
function App:run_sync()
  self.force = false
  self.pending_t = nil
  self:commit_code()
  if not self.comp then self:refresh() end
  if self.blocked then
    self.msg = "Rendering paused - fix the error first (the previous result stays in the project)."
    return
  end
  local st, err = RA.sync(self.comp)
  if not st then self.err = "Render failed: " .. tostring(err); return end
  self.err = nil
  self.last_stats = st
  local bad = 0
  for _ in pairs(st.bad) do bad = bad + 1 end
  if bad > 0 then self.err = bad .. " sound file(s) could not be loaded." end
  self.last_sig = self.sig
  RA.save_sig(self.sig)
  if self.cfg.inherited then self.cfg.inherited = false; self:save() end
  self.last_count = r.GetProjectStateChangeCount(0)       -- our own edits are not a reason to render again
  self.info = RA.managed_info()
  self.msg = string.format("Rendered: +%d audio items, %d MIDI items, ~%d changed, -%d removed; +%d/-%d tracks.",
    st.items_new, st.midi_new, st.items_upd, st.items_del, st.tracks_new, st.tracks_del)
end

-- another project tab became active: settings are per project
function App:switch_project(proj)
  self.proj = proj
  self.cfg = RA.load_cfg()
  self.last_sig = RA.load_sig()
  self.pending_t, self.force = nil, false
  self.msg, self.err = nil, nil
  self.cur, self.edit, self.plans, self.patterns, self.comp = nil, { guid = nil, code = "" }, {}, {}, nil
  self:rescan()
end

function App:tick()
  local now = r.time_precise()
  local proj = r.EnumProjects(-1)
  if proj ~= self.proj then self:switch_project(proj) end

  -- typed code -> item notes
  if self.edit.t and now - self.edit.t >= CODE_IDLE then self:commit_code() end

  local cnt = r.GetProjectStateChangeCount(0)
  if cnt ~= self.last_count then
    self.last_count = cnt
    self:refresh()
    if self.sig == self.last_sig then self.pending_t = nil end
  end

  -- follow the REAPER selection: clicking a pattern item on the timeline opens it in the editor
  if self.cfg.follow and not self.edit.t then
    local sel
    for _, p in ipairs(self.patterns) do if p.selected then sel = p.guid; break end end
    if sel ~= self.last_sel then
      self.last_sel = sel
      if sel and sel ~= self.cur then
        self.cur = sel
        local p = self:pattern(sel)
        self.edit = { guid = sel, code = p and p.code or "", t = nil }
      end
    end
  end

  if self.force then
    self:run_sync()
  elseif self:live() and self.pending_t and now - self.pending_t >= DEBOUNCE then
    self:run_sync()
  end
end

return App

end
__preload["GSUI"] = function(...)
-- GSUI.lua
-- ReaImGui front-end. Only reads app state and calls App methods.
-- Style/API follows PrototypeSequence (r.ImGui_* functions, colours as 0xRRGGBBAA).

local r = reaper
local Core = require("GSCore")

local UI = {}
UI.__index = UI

local COL_HEAD = 0xFFCC44FF
local COL_OK   = 0x5FE07FFF
local COL_BAD  = 0xFF5F5FFF
local COL_WARN = 0xFFAA33FF
local COL_DIM  = 0x999999FF
local COL_LIVE = 0x5FE07FFF
local COL_FROZ = 0x6FB7FFFF
local COL_CUR  = 0x8542FA4F     -- current pattern row: same as the theme's Header colour
local BG = 0x181A1AFF
local THEME = {
  { "WindowBg", BG }, { "PopupBg", BG }, { "ChildBg", BG },
  { "FrameBg", 0x47297A8A }, { "FrameBgHovered", 0x8542FA66 }, { "FrameBgActive", 0x8542FAAB },
  { "Button", 0x8542FA66 }, { "ButtonHovered", 0x8542FAFF }, { "ButtonActive", 0x650FFAFF },
  { "SliderGrab", 0x793DE0FF }, { "SliderGrabActive", 0x8542FAFF }, { "CheckMark", 0x8542FAFF },
  { "Header", 0x8542FA4F }, { "HeaderHovered", 0x8542FACC }, { "HeaderActive", 0x8542FAFF },
  { "PlotHistogram", 0x8542FAFF }, { "TitleBgActive", 0x47297AFF },
}

-- pushes the theme and returns how many colours were pushed
-- (a colour name missing in an older ReaImGui is skipped instead of raising an error)
local function push_theme(ctx)
  local n = 0
  for _, c in ipairs(THEME) do
    local get = r["ImGui_Col_" .. c[1]]
    if get then r.ImGui_PushStyleColor(ctx, get(), c[2]); n = n + 1 end
  end
  return n
end


UI.EXAMPLES = {
  { "drums", '$: s("bd*2, ~ sn, hh*8").gain(0.8)' },
  { "euclid", '$: s("bd(3,8), ~ sn(2,8,2), hh*8").gain(0.7)' },
  { "random", '$: s("hh*16").gain(rand.range(0.3,0.9)).degradeBy(0.3)\n$: s("bd sn").sometimes(x => x.speed(2))' },
  { "MIDI bass", '// switch on "MIDI notes" above\n$: note("<c2 e2 g2 a2>*4").legato(0.5)\nlead: note("c4 [e4 g4] <a4 b4>").off(1/8, x => x.add(note(7)))' },
}

function UI.new(app)
  local self = setmetatable({}, UI)
  self.A = app
  self.ctx = r.ImGui_CreateContext("Gingersnap")
  self.title = "Gingersnap v" .. Core.VERSION .. " - minimal Strudel subset for REAPER###gingersnap_main"
  self.path_buf = nil
  self.name_buf, self.name_guid = nil, nil
  self.cyc_buf, self.cyc_guid = nil, nil
  self.confirm_detach, self.confirm_delete, self.confirm_freeze = false, false, false
  return self
end

--------------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------------
local function fmt_pos(p)
  local ok, s = pcall(r.format_timestr_pos, p, "", 2)         -- 2 = measures.beats
  return (ok and s and s ~= "") and s or string.format("%.3f", p)
end

function UI:tip(text)
  local ctx = self.ctx
  if r.ImGui_IsItemHovered(ctx) and r.ImGui_SetTooltip then r.ImGui_SetTooltip(ctx, text) end
end

function UI:disable_if(cond)
  if cond and r.ImGui_BeginDisabled then
    r.ImGui_BeginDisabled(self.ctx, true)
    return function() r.ImGui_EndDisabled(self.ctx) end
  end
  return function() end
end

function UI:heading(text)
  local ctx = self.ctx
  r.ImGui_Spacing(ctx)
  r.ImGui_TextColored(ctx, COL_HEAD, text)
  r.ImGui_Separator(ctx)
end

-- coloured text that wraps at the window edge
function UI:wrapped(color, text)
  local ctx = self.ctx
  if r.ImGui_PushTextWrapPos then r.ImGui_PushTextWrapPos(ctx, 0) end
  r.ImGui_TextColored(ctx, color, text)
  if r.ImGui_PopTextWrapPos then r.ImGui_PopTextWrapPos(ctx) end
end

function UI:dropped_path()
  local ctx = self.ctx
  local path
  if r.ImGui_BeginDragDropTarget(ctx) then
    local a, b = r.ImGui_AcceptDragDropPayloadFiles(ctx)
    local rv, count = a, b
    if type(a) ~= "boolean" then count = a; rv = (a or 0) > 0 end
    if rv and (count or 0) > 0 then
      local x, y = r.ImGui_GetDragDropPayloadFile(ctx, 0)
      path = (type(x) == "string") and x or y
    end
    r.ImGui_EndDragDropTarget(ctx)
  end
  return path
end

function UI:browse()
  local A = self.A
  if r.JS_Dialog_BrowseForFolder then
    local rv, folder = r.JS_Dialog_BrowseForFolder("Sounds root folder (one sub-folder per sound)", A.cfg.root or "")
    if rv == 1 and folder and folder ~= "" then A:set_root(folder); self.path_buf = nil end
  else
    local ok, file = r.GetUserFileNameForRead(A.cfg.root or "", "Pick any file inside the sounds root folder", "")
    if ok and file and file ~= "" then A:set_root(file); self.path_buf = nil end
  end
end

--------------------------------------------------------------------------------
-- sounds folder
--------------------------------------------------------------------------------
function UI:draw_folder()
  local ctx, A = self.ctx, self.A
  self:heading("Sounds folder  (folder name = sound name:  bd/  ->  s(\"bd\"),  s(\"bd:3\") = 4th file)")

  local w = select(1, r.ImGui_GetContentRegionAvail(ctx))
  local SQ = 46
  local label = (A.cfg.root ~= "") and (A.cfg.root .. "\n(click to change, or drop another folder here)")
    or "Drop the sounds root folder here\n(click to browse)"
  if r.ImGui_Button(ctx, label .. "##drop", w - SQ - 6, SQ) then self:browse() end
  local dropped = self:dropped_path()                -- must come right after the drop-zone button
  if dropped then A:set_root(dropped); self.path_buf = nil end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "Re-\nscan##scan", SQ, SQ) then A:update_folder(); self.path_buf = nil end
  self:tip("Re-read the sounds folder (new / removed files, changed lengths) and render again")

  r.ImGui_SetNextItemWidth(ctx, w)
  self.path_buf = self.path_buf or A.cfg.root
  local changed, buf = r.ImGui_InputText(ctx, "##path", self.path_buf, r.ImGui_InputTextFlags_EnterReturnsTrue())
  if changed then self.path_buf = buf; A:set_root(buf); self.path_buf = nil
  else self.path_buf = buf end

  local cfg = A.cfg
  local same = (cfg.default_root == cfg.root)
  if cfg.inherited then r.ImGui_TextColored(ctx, COL_DIM, "Default folder in use (saved into the project with the first render).  ")
  elseif cfg.root ~= "" then r.ImGui_TextColored(ctx, COL_DIM, "Saved with this project.  ") end
  r.ImGui_SameLine(ctx)
  local done = self:disable_if(cfg.root == "" or same)
  if r.ImGui_SmallButton(ctx, "Make this the default") then A:make_default() end
  done()
  self:tip("New projects will start with this folder")
  r.ImGui_SameLine(ctx)
  done = self:disable_if(cfg.default_root == "" or same)
  if r.ImGui_SmallButton(ctx, "Use the default here") then A:use_default(); self.path_buf = nil end
  done()
  self:tip("Switch this project to the default folder (" .. (cfg.default_root ~= "" and cfg.default_root or "none yet") .. ")")

  if A.ngroups > 0 then
    local ids = {}
    for id in pairs(A.groups) do ids[#ids + 1] = id end
    table.sort(ids)
    for i, id in ipairs(ids) do
      local g = A.groups[id]
      if i > 1 then r.ImGui_SameLine(ctx) end
      r.ImGui_TextColored(ctx, #g.sounds > 0 and COL_OK or COL_WARN, string.format("%s (%d)", g.name, #g.sounds))
    end
  elseif A.cfg.root ~= "" then
    r.ImGui_TextColored(ctx, COL_BAD, "no sub-folders found")
  end
end

--------------------------------------------------------------------------------
-- pattern list
--------------------------------------------------------------------------------
function UI:draw_patterns()
  local ctx, A = self.ctx, self.A
  self:heading(string.format("Patterns (%d)  - empty items on the timeline; their notes hold the code", #A.patterns))

  if r.ImGui_Button(ctx, "New pattern") then A:new_pattern() end
  self:tip("Insert an empty pattern item at the edit cursor (or the time selection) on the selected track")
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "Use selected empty item") then A:adopt() end
  self:tip("Turn the selected EMPTY item(s) (Insert > Empty item) into patterns; their notes become the code")
  r.ImGui_SameLine(ctx)
  if A:live() then
    r.ImGui_TextColored(ctx, COL_LIVE, "LIVE")
    r.ImGui_SameLine(ctx)
    if r.ImGui_SmallButton(ctx, "Freeze all") then A:freeze_all() end
    self:tip("Stop rendering automatically; the project is left alone")
    r.ImGui_SameLine(ctx)
    if r.ImGui_SmallButton(ctx, "Render now") then A:render_now() end
  else
    r.ImGui_TextColored(ctx, COL_FROZ, "FROZEN")
    r.ImGui_SameLine(ctx)
    if r.ImGui_SmallButton(ctx, "Go live") then A:go_live() end
    r.ImGui_SameLine(ctx)
    if r.ImGui_SmallButton(ctx, "Render once") then A:render_now() end
  end
  r.ImGui_SameLine(ctx)
  local ch, v = r.ImGui_Checkbox(ctx, "Follow selection", A.cfg.follow)
  if ch then A:set_follow(v) end
  self:tip("Clicking a pattern item on the timeline opens it in the editor")

  -- global settings (the same for every project)
  local cha, va = r.ImGui_Checkbox(ctx, "Standard drum aliases", A.cfg.aliases)
  if cha then A:set_aliases(va) end
  self:tip("Off by default. On: the Strudel drum names sd rim lt mt ht cr rd cb perc work as General MIDI drums, and\n"
    .. "as sample folders s(\"sd\") also finds a folder called sn / snare (and the other way round).")
  r.ImGui_SameLine(ctx)
  r.ImGui_SetNextItemWidth(ctx, 60)
  if not self.root_buf then self.root_buf = tostring(A.cfg.root_note) end
  local chr, rb = r.ImGui_InputText(ctx, "Sample root note##root", self.root_buf, r.ImGui_InputTextFlags_EnterReturnsTrue())
  if chr then
    self.root_buf = rb
    if not A:set_root_note(rb) then self.root_buf = tostring(A.cfg.root_note) end
  end
  self:tip("The note at which a sample plays unchanged (MIDI number or name, default 36 = c2, like Strudel).\n"
    .. "note(\"c3\").s(\"piano\") then plays the sample 12 semitones higher: rate = 2^((note - root) / 12).")

  if #A.patterns == 0 then
    r.ImGui_TextColored(ctx, COL_DIM, "No pattern yet: click \"New pattern\".")
    return
  end
  local flags = r.ImGui_TableFlags_RowBg() | r.ImGui_TableFlags_ScrollY() | r.ImGui_TableFlags_Resizable()
  local h = math.min(#A.patterns * 22 + 26, 130)
  if r.ImGui_BeginTable(ctx, "patterns", 5, flags, 0, h) then
    r.ImGui_TableSetupScrollFreeze(ctx, 0, 1)
    r.ImGui_TableSetupColumn(ctx, "Name", r.ImGui_TableColumnFlags_WidthStretch(), 2)
    r.ImGui_TableSetupColumn(ctx, "Position", r.ImGui_TableColumnFlags_WidthFixed(), 90)
    r.ImGui_TableSetupColumn(ctx, "Cycles", r.ImGui_TableColumnFlags_WidthFixed(), 55)
    r.ImGui_TableSetupColumn(ctx, "Output", r.ImGui_TableColumnFlags_WidthFixed(), 80)
    r.ImGui_TableSetupColumn(ctx, "Status", r.ImGui_TableColumnFlags_WidthStretch(), 3)
    r.ImGui_TableHeadersRow(ctx)
    for i, p in ipairs(A.patterns) do
      local st = A.status[p.guid] or {}
      r.ImGui_TableNextRow(ctx)
      if A.cur == p.guid then r.ImGui_TableSetBgColor(ctx, r.ImGui_TableBgTarget_RowBg0(), COL_CUR) end
      r.ImGui_TableNextColumn(ctx)
      if r.ImGui_Selectable(ctx, ((p.name ~= "") and p.name or "Pattern") .. "##pat" .. i, A.cur == p.guid) then A:select(p.guid, true) end
      r.ImGui_TableNextColumn(ctx)
      r.ImGui_Text(ctx, fmt_pos(p.pos))
      r.ImGui_TableNextColumn(ctx)
      r.ImGui_Text(ctx, string.format("%.3g", p.cycles))
      r.ImGui_TableNextColumn(ctx)
      r.ImGui_Text(ctx, ({ audio = "audio", midi = "MIDI", both = "audio+MIDI" })[p.mode])
      r.ImGui_TableNextColumn(ctx)
      if st.off then r.ImGui_TextColored(ctx, COL_DIM, "off")
      elseif st.err then r.ImGui_TextColored(ctx, COL_BAD, "error")
      elseif st.warnings and #st.warnings > 0 then r.ImGui_TextColored(ctx, COL_WARN, string.format("%d events, %d warning(s)", st.events or 0, #st.warnings))
      else r.ImGui_TextColored(ctx, COL_OK, string.format("%d events", st.events or 0)) end
    end
    r.ImGui_EndTable(ctx)
  end
end

--------------------------------------------------------------------------------
-- editor for the current pattern
--------------------------------------------------------------------------------
function UI:draw_editor()
  local ctx, A = self.ctx, self.A
  local p = A:current()
  if not p then return end
  self:heading("Pattern: " .. ((p.name ~= "") and p.name or "Pattern"))

  -- name
  if self.name_guid ~= p.guid then self.name_guid, self.name_buf = p.guid, p.name end
  r.ImGui_SetNextItemWidth(ctx, 170)
  local nch, nb = r.ImGui_InputText(ctx, "name", self.name_buf)
  self.name_buf = nb
  if r.ImGui_IsItemDeactivatedAfterEdit(ctx) then A:set_name(p.guid, nb) end
  r.ImGui_SameLine(ctx)

  -- output switches (same code, different results)
  local audio, midi = p.mode ~= "midi", p.mode ~= "audio"
  local c1, a2 = r.ImGui_Checkbox(ctx, "Audio items", audio)
  self:tip("Events with s(\"...\") become items from the sound folders")
  r.ImGui_SameLine(ctx)
  local c2, m2 = r.ImGui_Checkbox(ctx, "MIDI notes", midi)
  self:tip("Events with note(...) / n(...) / a General MIDI drum name (bd sn hh ...) become MIDI notes, one track per $: line")
  if c1 or c2 then
    if c1 then audio = a2 end
    if c2 then midi = m2 end
    if not audio and not midi then audio = true end
    A:set_mode(p.guid, audio, midi)
  end
  r.ImGui_SameLine(ctx)
  local on = not p.off
  local c3, on2 = r.ImGui_Checkbox(ctx, "On", on)
  if c3 then A:set_off(p.guid, not on2) end
  self:tip("Off: the pattern's generated items are removed")

  -- cycle length
  if self.cyc_guid ~= p.guid then self.cyc_guid, self.cyc_buf = p.guid, p.cycle_qn end
  r.ImGui_SetNextItemWidth(ctx, 90)
  local _, cv = r.ImGui_InputDouble(ctx, "beats per cycle", self.cyc_buf, 0, 0, "%.2f")
  self.cyc_buf = cv
  if r.ImGui_IsItemDeactivatedAfterEdit(ctx) then A:set_cycle(p.guid, cv) end
  self:tip("Length of ONE cycle in quarter notes (4 = a bar of 4/4). The item is " .. string.format("%.3g", p.cycles) .. " cycles long.")
  r.ImGui_SameLine(ctx)
  if r.ImGui_SmallButton(ctx, "Freeze") then self.confirm_freeze = true end
  self:tip("Keep everything this pattern generated as ordinary items and switch the pattern off")
  r.ImGui_SameLine(ctx)
  if r.ImGui_SmallButton(ctx, "Delete pattern") then self.confirm_delete = true end
  if self.confirm_freeze then
    self:wrapped(COL_WARN, "Freeze: generated items become ordinary items (never touched again); the pattern is switched off.")
    if r.ImGui_Button(ctx, "Yes, freeze") then A:freeze_pattern(p.guid); self.confirm_freeze = false end
    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, "Cancel##freeze") then self.confirm_freeze = false end
  end
  if self.confirm_delete then
    self:wrapped(COL_WARN, "Delete the pattern item and everything it generated?")
    if r.ImGui_Button(ctx, "Yes, delete") then A:delete_pattern(p.guid); self.confirm_delete = false end
    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, "Cancel##delete") then self.confirm_delete = false end
  end

  -- examples
  r.ImGui_TextColored(ctx, COL_DIM, "examples:")
  for _, ex in ipairs(UI.EXAMPLES) do
    r.ImGui_SameLine(ctx)
    if r.ImGui_SmallButton(ctx, ex[1] .. "##ex") then A:set_edit_code(ex[2]) end
  end
  r.ImGui_SameLine(ctx)
  r.ImGui_TextColored(ctx, COL_DIM, "  (replaces the code)")

  -- the editor
  local w, avail_h = r.ImGui_GetContentRegionAvail(ctx)
  local h = math.max(140, (avail_h or 300) - 120)
  local flags = r.ImGui_InputTextFlags_AllowTabInput()
  local changed, buf = r.ImGui_InputTextMultiline(ctx, "##code", A.edit.code, w, h, flags)
  if changed then A:set_edit_code(buf) end

  -- result of the evaluation
  local st = A.status[p.guid] or {}
  if st.err then
    self:wrapped(COL_BAD, st.err)
  else
    if st.warnings then
      for _, wmsg in ipairs(st.warnings) do self:wrapped(COL_WARN, wmsg) end
    end
    if not st.off and #(st.warnings or {}) == 0 then
      r.ImGui_TextColored(ctx, COL_DIM, string.format("%d events in %.3g cycles.", st.events or 0, p.cycles))
    end
  end
end

--------------------------------------------------------------------------------
-- frame
--------------------------------------------------------------------------------
function UI:draw()
  local A = self.A
  local ctx = self.ctx
  self:draw_folder()
  self:draw_patterns()
  self:draw_editor()

  local info = A.info or { tracks = 0 }
  if (info.tracks or 0) > 0 then
    r.ImGui_TextColored(ctx, COL_DIM, string.format("Managed: %d tracks (GINGERSNAP folder)", info.tracks))
    r.ImGui_SameLine(ctx)
    if r.ImGui_SmallButton(ctx, "Show") then A:show_root() end
    r.ImGui_SameLine(ctx)
    if r.ImGui_SmallButton(ctx, "Detach...") then self.confirm_detach = true end
    self:tip("Stop managing everything for good: tracks and items stay, as ordinary ones")
  end
  if self.confirm_detach then
    self:wrapped(COL_WARN, "Detach: all GINGERSNAP tracks and items become ordinary. Patterns are switched off.")
    if r.ImGui_Button(ctx, "Yes, detach") then A:detach(); self.confirm_detach = false end
    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, "Cancel##detach") then self.confirm_detach = false end
  end
  if A.err then self:wrapped(COL_BAD, A.err)
  elseif A.msg then self:wrapped(COL_DIM, A.msg) end
end

-- returns false when the window has been closed
function UI:frame()
  local ctx = self.ctx
  local pushed = push_theme(ctx)
  r.ImGui_SetNextWindowSize(ctx, 780, 860, r.ImGui_Cond_FirstUseEver())
  local visible, open = r.ImGui_Begin(ctx, self.title, true)
  if visible then
    local ok, e = pcall(self.draw, self)
    if not ok then self.A.err = "UI error: " .. tostring(e) end
    r.ImGui_End(ctx)
  end
  if pushed > 0 then r.ImGui_PopStyleColor(ctx, pushed) end   -- also when the window is collapsed: the colour stack must stay balanced
  return open
end

return UI

end

local r = reaper
local dir = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""
package.path = dir .. "?.lua;" .. package.path

if not r.ImGui_CreateContext then
  r.MB("This script needs the ReaImGui extension.\n\nInstall it via ReaPack (Extensions > ReaPack > Browse packages > 'ReaImGui').", "Gingersnap", 0)
  return
end

local App = require("GSApp")
local UI  = require("GSUI")

local EXT = "GingersnapApp"

-- single instance: running the action a second time asks the running one to close
local hb_age = os.time() - (tonumber(r.GetExtState(EXT, "hb")) or 0)
if r.GetExtState(EXT, "running") == "1" and hb_age < 3 then
  r.SetExtState(EXT, "stop", "1", false)
  return
end
r.SetExtState(EXT, "running", "1", false)
r.SetExtState(EXT, "stop", "0", false)
r.SetExtState(EXT, "hb", tostring(os.time()), false)

local _, _, sec, cmdid = r.get_action_context()
local function set_toggle(on)
  if cmdid and cmdid ~= 0 then r.SetToggleCommandState(sec, cmdid, on and 1 or 0); r.RefreshToolbar2(sec, cmdid) end
end
set_toggle(true)

local app = App.new()
local ui = UI.new(app)

local function shutdown()
  pcall(app.commit_code, app)
  app:save()
  set_toggle(false)
  r.SetExtState(EXT, "running", "0", false)
  r.SetExtState(EXT, "stop", "0", false)
end
r.atexit(shutdown)

local last_hb, last_err = 0, nil
local function loop()
  if r.GetExtState(EXT, "stop") == "1" then shutdown(); return end
  local now = r.time_precise()
  if now - last_hb > 1 then r.SetExtState(EXT, "hb", tostring(os.time()), false); last_hb = now end

  local ok, err = pcall(app.tick, app)
  if not ok and tostring(err) ~= last_err then
    last_err = tostring(err)
    app.err = "Error: " .. last_err
  end
  if ui:frame() then r.defer(loop) else shutdown() end
end

loop()

