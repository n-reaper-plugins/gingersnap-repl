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
