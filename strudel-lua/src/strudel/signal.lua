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
