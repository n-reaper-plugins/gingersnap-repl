# Gingersnap changelog — minimal Strudel subset for REAPER

## 0.1.0 — first version (offline-tested only)
* Named Gingersnap (working title was StrudelReaper).
* Pattern items: EMPTY timeline items whose notes hold the code; move / resize / copy them freely.
* Sounds: one folder per sound name; `s("bd:3")` / `n(3)` pick the Nth file (wraps); drop zone + default folder as in PrototypeSequence.
* Output per pattern: audio items, MIDI notes, or both, from the same code. One MIDI track per `$:` / `label:` line.
* Time: 1 cycle = N quarter notes (default 4), follows the tempo map; voice tracks avoid overlapping items.
* Live rendering with debounce, keyed diff (hand edits survive), errors pause rendering, per-pattern Freeze, Detach.
* strudel-lua: mini-notation, whitelist evaluator, ~90 functions, checked against Strudel 1.2.6 (483/483 identical).
