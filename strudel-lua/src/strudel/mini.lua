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
