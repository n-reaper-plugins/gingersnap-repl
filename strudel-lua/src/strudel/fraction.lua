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
