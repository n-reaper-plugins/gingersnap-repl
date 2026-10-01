# Gingersnap v0.2.0 – Strudel compatibility coverage

Reference: **Strudel 1.2.6** (`@strudel/core`, `@strudel/mini`, `@strudel/tonal`). A function is only added when it exists there; everything
that is implemented is diffed against the real thing (`strudel-lua/test/test_reference.lua`).

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
| Methods: tonal | `scale scaleTranspose scaleTrans strans transpose trans` | `scale("C:major")`, all of tonal's 92 scale types; `n(...)` is turned into `note(...)`; `transpose` takes semitones or intervals (`"5P"`) |
| Methods: rhythm 0.2 | `swing swingBy brak press pressBy within plyWith euclidLegato euclidLegatoRot ribbon rib reset restart shuffle scramble` | |
| Methods: sample slicing | `chop striate slice splice bite loopAt fit` + global `squeeze` | `loopAt` / `splice` / `fit` follow the REAPER tempo map |
| Methods: lookup | `pick pickmod pickF pickRestart pickReset pickOut inhabit inhabitmod pickSqueeze` | arrays `[a, b]` and objects `{ a: x, b: y }` |
| Constructors 0.2 | `arrange stepcat polymeter polyrhythm pm pr choose chooseIn chooseOut chooseWith chooseInWith chooseCycles randcat wchoose wchooseCycles wrandcat perlin berlin` | |
| Controls (meaningful) | `s sound n note gain velocity(vel) postgain pan legato clip speed channel midichan bank begin end loop cut unit octave(oct) ccn ccv progNum midibend` | |
| Controls (ignored, warning) | ~70 synth/sampler controls (`lpf room delay attack vowel orbit` …) | accepted, no effect |
| Ignored helpers | `.scope() .pianoroll()`, `setcps`, `setcpm`, `samples(...)` | no effect |
| Audio output | `s("x")` → item from folder `x`; `:N` / `.n(N)` picks file (sorted, wraps) | one folder level |
| Audio output | `gain`, `velocity` → item volume | |
| Audio output | `pan` → take pan; `speed` → playrate + length | negative speed = reversed take (REAPER action, not verified in REAPER) |
| Audio output | `note(...)` repitches the sample: rate = 2^((note − root) / 12) | root note is a setting, default 36 (= Strudel) |
| Audio output | `begin` / `end` → start offset + length; `loop` → looped item; `cut(n)` → earlier items of the group stop at the next onset | `loop` loops the whole file |
| Audio output | `unit("c")` (used by `loopAt`, `splice`, `fit`) → speed counts cycles, from the current tempo | |
| Audio output | `bank("X")` → folder `X_<sound>` first, then `<sound>` | |
| Audio output | `postgain` → multiplies the item volume | |
| Host | optional "Standard drum aliases" (`sd rim lt mt ht cr rd cb perc`) | global setting, off by default; GM drums + folder lookup (`sd` ⇄ `sn`/`snare` …) |
| Audio output | `legato`/`clip` → item cut + short fade | |
| MIDI output | `s("bd")` → GM drum note, channel 10 | bd 36, sn 38, hh 42, oh 46, cp 39 … |
| MIDI output | `note()` / `n()` → MIDI notes (`c3` = 48) | |
| MIDI output | `velocity`/`gain`/`postgain` → velocity; `legato` → note length | |
| MIDI output | `octave` / `oct` shifts the notes (`o` is Strudel's `orbit`: ignored); `midichan` / `channel` pick the channel | |
| MIDI output | `ccn` + `ccv` (0–1 → 0–127), `progNum`, `midibend` (−1…1) → controller events in the same MIDI item | events without a note are fine |
| Host | one cycle = N quarter notes (default 4), follows REAPER tempo map | `setcpm` ignored |
| Host | tracks under collapsed GINGERSNAP folder; voice tracks on overlap | `a (2)` |
| Host | keyed diff re-render; hand-edited items survive | |
| Host | LIVE re-render, Freeze, Freeze all, Detach, 1 undo step per render | |
| Host | error pausing with line number; warnings | |
| Host | pattern item = empty item, code in notes | |
| Safety | parsed, never executed; 20 000 event limit | |

# 2. Not (yet) supported vs. Strudel 1.2.6

"Listed" = named as not implemented in the README. "Omitted" = not in the supported list. Things that do **not exist in Strudel 1.2.6**
are not added to Gingersnap either (marked "not in Strudel").

| Category | Strudel feature | Status |
|---|---|---|
| Tonal | `chord`, `voicing`, `rootNotes`, `anchor`, `mode`, `dict` | planned for 0.2.5 |
| Tonal | `arp`, `arpWith` | planned for 0.2.5 (needs chords) |
| Tonal | `freq`/`hz` | Omitted |
| Sample slicing | `loopBegin`, `loopEnd`, `loopAtCps`, `scrub`, `unit` other than `"c"` | Omitted |
| Sample banks | `samples('github:…')`, `samples({...})` | Ignored (no loading) |
| Sample banks | nested sample folders | Listed (one level only) |
| Arrangement | `ncat`, `stepalt`, `take`, `drop`, `expand`, `contract`, `shrink`, `grow` and the other step functions | Omitted |
| Rhythm | `ghost` | Omitted |
| Rhythm | `sew`, `stitch`, `rolled`, `rolledBy`, `euclidOff`, `euclidInv` | not in Strudel 1.2.6 |
| Random | `cycleChoose` | not in Strudel 1.2.6 (it is called `chooseCycles`, which works) |
| Random | `seed`, `withSeed`, non-legacy RNG | Listed (known limit) |
| Control change | `cc(...)`, `pitchbend` | not in Strudel 1.2.6 (use `ccn` + `ccv`, `midibend`) |
| Control change | `nrpnn`, `nrpv`, `sysex`, `miditouch`, `midicmd`, `midi()`, `midimap` | Omitted |
| Synth/FX | `sound("sawtooth")` and other synth waveforms, `fm*`, `lpf/hpf/bpf`, `room`, `delay`, `crush`, `coarse`, `phaser`, `vowel`, `duck`, `orbit`, envelopes | Accepted, ignored |
| Language | `register()`, template strings `${}`, `if`, `for`, `function` | Listed (error) |
| Language | JS objects other than as the lookup of `pick` / `inhabit` | Omitted |
| Language | `Math.*`, `.map`, array methods, `await` | Omitted |
| Language | operator variants `add.out`, `add.squeeze`, `add.mix`, `add.reset` | Omitted |
| Language | `hush`, `all()`, `.p("name")`, `.color()`, `.tag` | Omitted |
| Input | `mouseX`, `whenKey`, MIDI input, `midin` | Omitted (n/a offline) |
| Visual | `scope`, `pianoroll`, `punchcard`, `spiral`, `_` visual variants | Ignored |
| Tempo | `setcpm`, `setcps`, `cpm`, `hurry` w/ tempo | `set*` ignored; tempo = REAPER |
