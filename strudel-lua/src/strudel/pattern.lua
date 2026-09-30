-- strudel/pattern.lua
-- The pattern core: a Pattern is a function  query(span) -> list of haps  (events).
-- Nothing in here knows about audio, MIDI or REAPER.
--
-- strudel-lua is a Lua implementation of the semantics of Strudel
-- (https://strudel.cc) and Tidal. It follows the behaviour of Strudel's @strudel/core and is checked
-- against it (test/oracle). Licensed AGPL-3.0-or-later, see ../../README.md.

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
  return new(function(sp)
    local out = {}
    for i, h in ipairs(pat.query(sp)) do out[i] = H(h.whole, h.part, f(h.value)) end
    return out
  end)
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

--------------------------------------------------------------------------------
-- constructors
--------------------------------------------------------------------------------
local silence = new(function() return {} end)
P.silence = silence

local function pure(v)
  return new(function(sp)
    local out = {}
    for _, sub in ipairs(span_cycles(sp)) do
      out[#out + 1] = H(S(sub.b:sam(), sub.b:next_sam()), sub, v)
    end
    return out
  end, v)
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
