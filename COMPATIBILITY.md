# Gingersnap v0.1.0 – Strudel compatibility coverage

# 1. Available features

| Area | Feature | Notes |
|---|---|---|
| Mini-notation | sequence, `~` `-`, `[ ]`, `< >`, `{ }`, `{ }%n`, `,`, `\|`, `.` feet | complete |
| Mini-notation | `*` `/` `!` `@` `_` `?` `?0.3` | complete |
| Mini-notation | euclid `(k,n,rot)` | patterned args |
| Mini-notation | `a:3:0.5` lists, `0 .. 3` ranges | complete |
| Language | `$:` / `label:` layers, `_` prefix mutes | one MIDI track per line |
| Language | `const`, `let`, arrow functions, `{ return }` bodies | whitelist evaluator, no `eval` |
| Language | numbers `+ - * / %`, arrays, bare strings as patterns | |
| Language | `//` and `/* */` comments | |
| Constructors | `s sound n note stack cat slowcat fastcat seq sequence timeCat silence run irand mini id` | |
| Signals | `sine cosine saw isaw square tri rand` (+ `sine2 saw2 rand2`) | |
| Methods: arithmetic | `add sub mul div mod pow set keep` | patterned args |
| Methods: time | `fast slow early late rev palindrome iter iterBack ply segment` | |
| Methods: rhythm | `euclid euclidRot struct mask` | |
| Methods: conditional | `every firstOf lastOf when off superimpose layer apply` | |
| Methods: random | `degrade degradeBy undegradeBy sometimes sometimesBy often rarely almostNever almostAlways always never someCycles someCyclesBy` | seeded, legacy RNG only |
| Methods: range | `range range2 round` | |
| Methods: structure | `inside outside zoom linger compress fastGap focus repeatCycles chunk chunkBack` | |
| Methods: effects-like | `jux juxBy hurry echo echoWith stut` | |
| Methods: combine | `stack cat fastcat` | |
| Controls (meaningful) | `s sound n note gain velocity(vel) pan legato clip speed channel` | |
| Controls (ignored, warning) | ~70 synth/sampler controls (`lpf room delay attack vowel orbit` …) | accepted, no effect |
| Ignored helpers | `.scope() .pianoroll()`, `setcps`, `setcpm`, `samples(...)` | no effect |
| Audio output | `s("x")` → item from folder `x`; `:N` / `.n(N)` picks file (sorted, wraps) | one folder level |
| Audio output | `gain`, `velocity` → item volume | |
| Audio output | `pan` → take pan; `speed` → playrate + length | negative speed unsupported |
| Audio output | `legato`/`clip` → item cut + short fade | |
| MIDI output | `s("bd")` → GM drum note, channel 10 | bd 36, sn 38, hh 42, oh 46, cp 39 … |
| MIDI output | `note()` / `n()` → MIDI notes (`c3` = 48) | |
| MIDI output | `velocity`/`gain` → velocity; `legato` → note length | |
| Host | one cycle = N quarter notes (default 4), follows REAPER tempo map | `setcpm` ignored |
| Host | tracks under collapsed GINGERSNAP folder; voice tracks on overlap | `a (2)` |
| Host | keyed diff re-render; hand-edited items survive | |
| Host | LIVE re-render, Freeze, Freeze all, Detach, 1 undo step per render | |
| Host | error pausing with line number; warnings | |
| Host | pattern item = empty item, code in notes | |
| Safety | parsed, never executed; 20 000 event limit | |

# 2. Unsupported vs. current Strudel

"Listed" = explicitly named as not implemented in the README. "Omitted" = not in the supported list, so treated as unsupported (verify with `tools`/`one.lua`).

| Category | Strudel feature | Status |
|---|---|---|
| Tonal | `scale`, `scaleTranspose`/`scaleTrans` | Listed (`scale`) / Omitted |
| Tonal | `chord`, `voicing`, `rootNotes`, `anchor`, `mode`, `dict` | Listed (`voicing`/chords) / Omitted |
| Tonal | `arp`, `arpWith` | Listed (`arp`) / Omitted |
| Tonal | `transpose`/`trans`, `octave`/`o`, `freq`/`hz` | Omitted |
| Tonal | pitching samples by `note` (`note("c e").s("piano")`) | Listed (known limit) |
| Sample slicing | `chop`, `striate` | Listed (`chop`) / Omitted |
| Sample slicing | `slice`, `splice`, `bite`, `squeeze` | Listed (`slice splice bite`) / Omitted |
| Sample slicing | `begin`, `end`, `loop`, `loopAt`, `fit`, `cut`, `unit` | Omitted |
| Sample slicing | negative `speed` (reverse) | Listed (known limit) |
| Sample banks | `bank()` / `RolandTR909_bd` naming, default Strudel drum names (`sd rim lt mt ht cr rd cb`) | Omitted |
| Sample banks | `samples('github:…')`, `samples({...})` | Ignored (no loading) |
| Sample banks | nested sample folders | Listed (one level only) |
| Arrangement | `arrange`, `pick`, `pickF`, `pickRestart`, `pickReset`, `inhabit` | Listed (`arrange`, `pick*`) / Omitted |
| Arrangement | `polymeter`/`polyrhythm` function forms, `ncat`, `stepcat` | Omitted |
| Rhythm | `swing`, `swingBy`, `shuffle`, `scramble` | Listed |
| Rhythm | `ribbon`, `rib` | Listed (`ribbon`) / Omitted |
| Rhythm | `brak`, `press`, `pressBy`, `rolled`, `rolledBy` | Omitted |
| Rhythm | `within`, `plyWith`, `euclidLegato`, `euclidOff`, `euclidInv` | Omitted |
| Rhythm | `sew`, `stitch`, `reset`, `restart`, `ghost` | Omitted |
| Random | `perlin`, `berlin` | Listed (`perlin`) / Omitted |
| Random | `choose`, `chooseWith`, `wchoose`, `cycleChoose` | Omitted |
| Random | non-legacy RNG | Listed (known limit) |
| Control change | `cc`, `ccn`, `ccv`, `nrpn`, `midi()`, `progNum`, `midichan` (only `channel`) | Listed (`cc`, `nrpn`) / Omitted |
| Synth/FX | `sound("sawtooth")` and other synth waveforms, `fm*`, `lpf/hpf/bpf`, `room`, `delay`, `crush`, `coarse`, `phaser`, `vowel`, `duck`, `orbit`, `postgain`, envelopes | Accepted, ignored |
| Language | `register()`, JS objects `{}`, template strings `${}`, `if`, `for`, `function` | Listed (error) |
| Language | `Math.*`, `.map`, array methods, `await` | Omitted |
| Language | operator variants `add.out`, `add.squeeze`, `add.mix`, `add.reset` | Omitted |
| Language | `hush`, `all()`, `.p("name")`, `.color()`, `.tag` | Omitted |
| Input | `mouseX`, `whenKey`, MIDI input, `midin` | Omitted (n/a offline) |
| Visual | `scope`, `pianoroll`, `punchcard`, `spiral`, `_` visual variants | Ignored |
| Tempo | `setcpm`, `setcps`, `cpm`, `hurry` w/ tempo | `set*` ignored; tempo = REAPER |


