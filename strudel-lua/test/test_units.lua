-- Unit tests of strudel-lua that do not need the oracle: fractions, the random generator (reference values
-- taken from real Strudel), the language front end (errors, safety, labels, arrow functions).
local here = (arg and arg[0] or ""):match("^(.*)/test/[^/]*$") or "."
package.path = here .. "/src/?.lua;" .. here .. "/test/?.lua;" .. package.path
local T = require("t")
local Strudel = require("strudel")
local F = Strudel.Fraction
local Sig = require("strudel.signal")

-- fractions ------------------------------------------------------------------------------------
T.eq(tostring(F.of(1, 3) + F.of(1, 6)), "1/2", "1/3+1/6")
T.eq(tostring(F.of(1, 3) * 3), "1", "1/3*3 is exactly 1")
T.eq(tostring(F.of(0.1)), "1/10", "0.1 -> 1/10 (like fraction.js)")
T.eq(tostring(F.of(1 / 3)), "1/3", "float 1/3 -> 1/3")
T.eq(tostring(F.of(-7, 2):floor()), "-4", "floor of -3.5")
T.eq(tostring(F.of(-7, 2):ceil()), "-3", "ceil of -3.5")
T.ok(F.of(1, 3) < F.of(1, 2) and F.of(2, 4) == F.of(1, 2), "compare / normalise")
T.ok(not pcall(function() return F.of(1) / F.of(0) end), "division by zero is an error")
local acc = F.ZERO
for _ = 1, 3000 do acc = acc + F.of(1, 3) end
T.eq(tostring(acc), "1000", "3000 x 1/3 has no drift")

-- random numbers: values of real Strudel's `rand` (legacy generator) ------------------------------------
local ref = { { 0, 0 }, { 0.25, 0.36975969187915325 }, { 1 / 3, 0.336072051897645 }, { 1, 0.5195421651005745 },
  { 2.5, 0.45861607417464256 }, { 7, 0.180575393140316 }, { 100.125, 0.6239332370460033 },
  { 299.9, 0.844127181917429 }, { 300, 0 }, { 1234.5678, 0.5668767057359219 } }
for _, p in ipairs(ref) do
  T.ok(math.abs(Sig.time_to_rand(p[1]) - p[2]) < 1e-12, "rand(" .. p[1] .. ") = " .. p[2] .. " (got " .. Sig.time_to_rand(p[1]) .. ")")
end

-- language front end ------------------------------------------------------------------------------------
local function run(code) return Strudel.run(code) end
local function err(code) local r, e = Strudel.run(code); T.ok(r == nil, "expected an error for: " .. code); return e or "" end

local r = run('$: s("bd sn")\n_$: s("hh*4")\nbass: note("c2")')
T.eq(#r.layers, 2, "muted _$: layer is skipped")
T.eq(r.layers[2].label, "bass", "label")

r = run('s("bd")')
T.eq(#r.layers, 1, "a bare expression is a pattern")
r = run('const p = s("bd sn")\n$: p.fast(2)')
T.eq(#Strudel.events(r.layers[1].pattern, 0, 1), 4, "const + $:")
r = run('"c e g".add(12)')
T.eq(#r.layers, 1, "a bare string is mini-notation")
r = run('$: s("bd").every(2, (x) => { return x.rev() })')
T.ok(r ~= nil, "block-bodied arrow function with return")
r = run('$: s("bd") // comment\n/* block */ $: s("sn")')
T.eq(#r.layers, 2, "comments")
r = run('setcpm(120/4)\nsamples("github:x/y")\n$: s("bd").room(0.5).pianoroll()')
T.ok(r ~= nil, "setcpm / samples / visual helpers are accepted")
local joined = table.concat(r.warnings, " | ")
T.ok(joined:find("setcpm"), "setcpm warned")
T.ok(joined:find("room"), "ignored control warned: " .. joined)

T.ok(err('$: s("bd").frobnicate(2)'):find("line 1: unknown method '.frobnicate%(%)'"), "unknown method, with line")
T.ok(err('$: s("bd")\n$: s("sn").nope()'):find("line 2"), "line number of the second statement")
T.ok(err('$: s("bd sn"'):find("line 1"), "unbalanced parenthesis")
T.ok(err('$: s("bd [sn")'):find("mini"), "mini-notation syntax error is reported")
T.ok(err('$: s("bd").fast()'):find("fast"), "missing argument is reported by name")
T.ok(err('$: xyz("bd")'):find("unknown name 'xyz'"), "unknown function")

-- safety: pasted code can not reach the machine ----------------------------------------------------------------
for _, code in ipairs({ 'os.execute("touch /tmp/pwned")', 'io.open("/etc/passwd")', 'require("os")', 'load("x")',
                        'dofile("x")', 'while(true){}', 'function f(){}', 'eval("1")', 'fetch("http://x")',
                        '$: s("bd").constructor("return process")()', '__proto__', 'globalThis.x' }) do
  local rr, e = Strudel.run(code)
  T.ok(rr == nil, "rejected: " .. code .. "  (" .. tostring(e) .. ")")
end
T.ok(not io.open("/tmp/pwned", "r"), "nothing was executed")

-- runaway patterns are bounded by the caller (GSCore limit); here: deep nesting does not hang the parser
local deep = string.rep("[", 200) .. "bd" .. string.rep("]", 200)
local t0 = os.clock()
local ok = pcall(run, 's("' .. deep .. '")')
T.ok(os.clock() - t0 < 2, "deeply nested mini-notation stays fast")

-- fraction-valued function arguments ------------------------------------------------------------------------------
local ev = Strudel.events(run('s("a b").late(1/3)').layers[1].pattern, 0, 1)
T.eq(tostring(ev[1].b), "1/3", "late(1/3) is exact")

T.done("test_units")
