-- Unit tests of strudel-lua that do not need the reference: fractions, the random generator (reference values
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

-- 0.2: functions that do not exist in Strudel 1.2.6 are NOT provided (clear errors, not silent no-ops) ----------------
for _, name in ipairs({ "sew", "stitch", "rolled", "rolledBy", "euclidOff", "euclidInv", "cc", "pitchbend", "cycleChoose" }) do
  local r, err = Strudel.run('$: s("a").' .. name .. '(1)')
  T.ok(not r and err and err:find("unknown method"), name .. "() is not in Strudel 1.2.6: unknown method error")
end

-- 0.2: object literals only as pick / inhabit lookups; bad lookups and scales are explained ---------------------------
local r2 = run('$: "a b".pick({a: s("x*2"), b: s("y*2")})')
local e2 = Strudel.events(r2.layers[1].pattern, 0, 1)
T.eq(#e2, 2, "pick with an object lookup")
T.eq(e2[2].value.s, "y", "second event picks b")
local okq, qerr = pcall(Strudel.events, run('$: "c".pick({a: s("x")})').layers[1].pattern, 0, 1)
T.ok(not okq and tostring(qerr):find("no entry named 'c'"), "pick: unknown key is reported")
local r3, e3 = Strudel.run('$: s("a").fast({a: 1})')
T.ok(not r3 or true, "an object where a number is expected does not crash the parser")
T.ok(select(2, Strudel.run('$: s("a") + {')) ~= nil, "unterminated object: parse error with a line number")
T.eq(#Strudel.events(run('$: n("0 1").scale("nonsense")').layers[1].pattern, 0, 1), 0, "unknown scale: events dropped (Strudel logs and drops them)")
local okq2 = pcall(Strudel.events, run('$: n(1).scaleTranspose(1)').layers[1].pattern, 0, 1)
T.ok(not okq2, "scaleTranspose without scale: error")

-- 0.2: tempo for loopAt / splice / fit is passed per cycle (Strudel.events opts.cps_fn) -----------------------------
local pat = run('$: s("a").loopAt(2)').layers[1].pattern
local evs = Strudel.events(pat, 0, 2, { cps_fn = function() return 0.25 end })
T.ok(math.abs(evs[1].value.speed - (1 / 2) * 0.25) < 1e-12, "loopAt uses the cps given by the host: speed = 1/2 * 0.25")
T.eq(evs[1].value.unit, "c", "and unit c")
evs = Strudel.events(pat, 0, 2)
T.ok(math.abs(evs[1].value.speed - 0.25) < 1e-12, "without cps Strudel's default 0.5 is used")

T.done("test_units")
