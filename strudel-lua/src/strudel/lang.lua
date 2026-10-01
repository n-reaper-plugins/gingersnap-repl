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
