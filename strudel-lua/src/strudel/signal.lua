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

-- t: time as a float (cycles)  ->  [0, 1)
function M.time_to_rand(t)
  local y = t / 300
  local frac = y - trunc(y)
  local seed = xorwise(trunc(frac * 536870912))
  return math.abs(math.fmod(seed, 536870912) / 536870912)
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

return M
