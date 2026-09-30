# strudel-lua

A small, dependency-free implementation of the **[Strudel](https://strudel.cc) pattern language** in pure Lua
(5.3 / 5.4): mini-notation (`"bd*2 [sn cp] <hh oh>(3,8)"`), the JavaScript-style method chains
(`s("bd sn").fast(2).every(4, x => x.rev())`), and the pattern engine underneath (exact rational time,
deterministic randomness, applicative / monadic combination of patterns).

It has **no audio and no REAPER code**. It answers one question: *"which events happen between cycle A and
cycle B?"* — and is used by [Gingersnap](../README.md) (minimal Strudel subset for REAPER) to render patterns into a REAPER project. Any other
host (a game, a MIDI tool, a test bench) can use it the same way.

## License

**AGPL-3.0-or-later.** See [`LICENSE`](LICENSE).

strudel-lua reimplements the semantics of Strudel's `@strudel/core` and `@strudel/mini`
(© Strudel contributors, AGPL-3.0-or-later; https://codeberg.org/uzu/strudel). The behaviour is deliberately
identical, down to the seeds of the random generator, and the Strudel sources were used as the reference while
writing it, so this module is a derivative work and carries the same license. If you use strudel-lua in a
program that users interact with over a network, the AGPL requires you to offer them the source.
Strudel itself is by Alex McLean, Felix Roos and many contributors — please support their work.

## Usage

```lua
package.path = "src/?.lua;" .. package.path
local Strudel = require("strudel")

local r, err = Strudel.run([[
  setcpm(120/4)                                    -- accepted, ignored (the host owns tempo)
  $: s("bd*2, ~ sn:1").fast(2).gain(0.8)
  bass: note("c2 [e2 g2]").every(2, x => x.fast(2))
]])
if not r then print(err) return end                -- "line 3: unknown method '.foo()' ..."

for _, layer in ipairs(r.layers) do                -- one per `$:` / `label:` line
  for _, e in ipairs(Strudel.events(layer.pattern, 0, 4)) do   -- onsets in cycles [0, 4)
    print(layer.label, tostring(e.b), tostring(e.e), e.value.s or e.value.note)   -- b/e are exact fractions
  end
end
for _, w in ipairs(r.warnings) do print("warning:", w) end
```

* `Strudel.run(code)` → `{ layers = { {pattern=, label=, line=} }, warnings = {...} }`, or `nil, "line N: message"`.
* `Strudel.events(pattern, from, to)` → `{ {b=Fraction, e=Fraction, value=table} }` — only events that **start**
  in the range (Strudel's `hasOnset()`), sorted by start. `value` is a control map such as `{s="bd", n=3, gain=0.8}`.
* `Strudel.mini("bd sn")` → a Pattern from mini-notation alone. `pattern:query_arc(b, e)` gives raw haps.
* Time is a `Fraction` (`tostring` gives `"1/3"`, `:float()` a number). Randomness is a pure function of time.

## What is supported

Not everything in Strudel — a deliberate subset that makes sense when *rendering* (no realtime, no audio).

**Mini-notation** — complete: sequences, `~` `-`, `[ ]`, `< >`, `{ }` and `{ }%n`, `,` stack, `|` random
choice, `.` feet, `*` `/` `!` `@` `_` `?` `?0.3`, euclid `(k,n,rot)` with patterned arguments, `a:3:0.5` lists,
`0 .. 3` ranges.

**Language** — `$:` and `label:` layers (a leading `_` mutes), `const` / `let`, arrow functions
(`x => x.fast(2)`, `(x, i) => { return ... }`), numbers with `+ - * / %`, arrays, bare strings as patterns,
`//` and `/* */` comments. There is **no `load()` / `eval`**: code is parsed and evaluated over a whitelist, so
pasted code cannot reach `os`, `io` or the file system. Anything unknown is an error with its line number.

**Constructors** `s sound n note stack cat slowcat fastcat seq sequence timeCat silence run irand mini id`
and the signals `sine cosine saw isaw square tri rand` (`sine2 saw2 rand2`).

**Methods** (all with patterned arguments, e.g. `.fast("<2 4>")`):
`add sub mul div mod pow set keep` · `fast slow early late rev palindrome iter iterBack ply segment` ·
`euclid euclidRot struct mask` · `every firstOf lastOf when off superimpose layer apply` ·
`degrade degradeBy undegradeBy sometimes sometimesBy often rarely almostNever almostAlways always never
someCycles someCyclesBy` · `range range2 round` · `inside outside zoom linger compress fastGap focus repeatCycles
chunk chunkBack` · `jux juxBy hurry echo echoWith stut` · `stack cat fastcat`.

**Controls** that carry meaning: `s sound n note gain velocity(vel) pan legato clip speed channel`.
About 70 synth / sampler controls (`lpf room delay attack vowel orbit ...`) are **accepted and ignored**, listed
in `warnings`. Visual helpers (`.scope() .pianoroll() ...`) and `setcps`/`setcpm`/`samples(...)` are ignored.

**Not implemented** (an error, never silently skipped): `scale`, `arrange`, `voicing`/chords, `arp`, `bite`,
`slice`/`splice`, `chop`, `swing`, `ribbon`, `pick*`, `nrpn`, `cc`, `perlin`, `rand`-based `shuffle`/`scramble`,
`register()`, JS objects, template strings with `${}`, `if`/`for`/`function`.

## Tests — checked against the real thing

`test/test_oracle.lua` compares strudel-lua with **real Strudel 1.2.6** on `test/golden.json`: 483 expressions
(hand-written + fuzzed random mini-notation and method chains), onsets of cycles 0-8, exact rational times.
Currently **483 of 483 identical** (a further 280 generated cases are rejected by Strudel itself and skipped).

```
lua5.4 test/test_oracle.lua        # differential test against the stored golden data (no node needed)
lua5.4 test/test_units.lua         # fractions, RNG reference values, language errors, safety
lua5.4 test/one.lua 's("bd*3").every(2, x=>x.rev())'   # print the events of one expression
```

To regenerate the golden data, or fuzz with new seeds (needs node + npm + network):

```
bash oracle/setup.sh               # installs real Strudel next to oracle/lib.mjs (not shipped)
node oracle/fuzz.mjs 4242          # writes test/cases_fuzz.txt with new random programs
node oracle/gen.mjs                # evaluates every test/cases*.txt with real Strudel -> test/golden.json
lua5.4 test/test_oracle.lua
```

Differences that are known and intended: randomness uses Strudel's default ("legacy") generator only; arithmetic on
control maps and bare numbers behaves like Strudel (a warning, left value kept); events are compared on
onsets, so parts of fragmented events are not compared.
