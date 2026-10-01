# Gingersnap changelog — minimal Strudel subset for REAPER

## 0.2.0
Everything below exists in Strudel 1.2.6 and is diffed against it (789 reference expressions, all identical). Nothing was invented.

**Tonal** `scale` (92 scale types from tonal.js; `n` → `note`), `scaleTranspose` / `scaleTrans` / `strans`, `transpose` / `trans`, `octave` / `oct`
(MIDI notes), `.add(note(...))` on note names (checked).
**Samples** `note(...)` repitches a sample (rate = 2^((note − root)/12), root note is a setting, default 36); `begin` / `end`; `chop`, `striate`,
`slice`, `splice`, `bite`, `squeeze`; `loopAt`, `fit` (follow the REAPER tempo map); `loop`; `cut` groups; negative `speed` = reversed take;
`bank("X")` (folder `X_<sound>` first); `postgain`.
**Drum names** new global setting *Standard drum aliases* (off by default): `sd rim lt mt ht cr rd cb perc` as General MIDI drums and as folder
aliases (`sd` ⇄ `sn` / `snare` …). **Behaviour change:** these nine names no longer map to GM drums unless the setting is on.
**Rhythm / structure** `swing`, `swingBy`, `brak`, `press`, `pressBy`, `within`, `plyWith`, `euclidLegato`, `euclidLegatoRot`, `ribbon` / `rib`,
`reset`, `restart`, `shuffle`, `scramble`, `arrange`, `stepcat`, `polymeter` / `polyrhythm` (function forms), `pick`, `pickmod`, `pickF`,
`pickRestart`, `pickReset`, `pickOut`, `inhabit` and their variants (arrays and `{ a: x }` object lookups).
**Random** `choose`, `chooseWith`, `chooseCycles` (= `randcat`), `wchoose`, `wchooseCycles` (= `wrandcat`), `perlin`, `berlin`.
**MIDI** `ccn` + `ccv`, `progNum`, `midibend` → controller / program change / pitch bend events; `midichan` is its own control (same effect as `channel`).
**Not added because they do not exist in Strudel 1.2.6:** `sew`, `stitch`, `rolled` / `rolledBy`, `euclidOff`, `euclidInv`, `cc()`, `pitchbend`,
`cycleChoose` (Strudel calls it `chooseCycles`). `pickmodF` is broken in Strudel 1.2.6 and was left out. `.o()` is Strudel's `orbit`, not octave.
**Moved to 0.2.5:** chords (`chord`, `rootNotes`, `mode`, `anchor`, `voicing`, `dict`) and `arp` / `arpWith`.
**Project** the real-Strudel test harness is now called `reference` (folder `strudel-lua/reference/`, `test_reference.lua`) and includes
`@strudel/tonal`; `fuzz.mjs --v02` fuzzes the new functions. New tests: `tools/test_v02.lua` (100 checks), 19 more unit checks.
**Not verified in real REAPER:** reverse (action 41051), `D_STARTOFFS`, `B_LOOPSRC`, `MIDI_InsertCC`, the two new settings in the window.

## 0.1.1
* **New colour theme**: accent hue 262 degrees (from #4700C2) on ImGui's default dark style, keeping its saturation, brightness and
  translucency (buttons / headers / inputs are see-through instead of solid), window backgrounds #181A1A.
* The current-pattern row highlight uses the theme's Header colour (was blue). LIVE / FROZEN colours are unchanged.
* The theme's colour stack is also popped when the window is collapsed. UI test checks 17 pushed / 17 popped.

## 0.1.0 — first version (offline-tested only)
* Named Gingersnap (working title was StrudelReaper).
* Pattern items: EMPTY timeline items whose notes hold the code; move / resize / copy them freely.
* Sounds: one folder per sound name; `s("bd:3")` / `n(3)` pick the Nth file (wraps); drop zone + default folder as in PrototypeSequence.
* Output per pattern: audio items, MIDI notes, or both, from the same code. One MIDI track per `$:` / `label:` line.
* Time: 1 cycle = N quarter notes (default 4), follows the tempo map; voice tracks avoid overlapping items.
* Live rendering with debounce, keyed diff (hand edits survive), errors pause rendering, per-pattern Freeze, Detach.
* strudel-lua: mini-notation, whitelist evaluator, ~90 functions, checked against Strudel 1.2.6 (483/483 identical).
