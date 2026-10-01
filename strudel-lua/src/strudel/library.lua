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
