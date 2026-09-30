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
    if b[k] ~= nil then r[k] = op(a[k], b[k]) end
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

return L
