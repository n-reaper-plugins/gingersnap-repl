-- Offline tests of the 0.2 features: planner (GSCore) and REAPER layer (GSReaper / GSApp) against the fake REAPER.
package.path = "./src/?.lua;./strudel-lua/src/?.lua;./tools/?.lua;" .. package.path
local T = require("t")
local Mock = require("mock_reaper")
local M = Mock.install()
local S = M.S
local r = reaper
local Core = require("GSCore")
local Strudel = require("strudel")
local App = require("GSApp")
local RA = require("GSReaper")

local function sounds(...) local t = {}; for i, n in ipairs({ ... }) do t[n] = { name = n, path = "/s/" .. n, sounds = { { file = "a.wav", name = "a", path = "/s/" .. n .. "/a.wav" }, { file = "b.wav", name = "b", path = "/s/" .. n .. "/b.wav" } } } end; return t end
local function near(a, b) return math.abs(a - b) < 1e-6 end
-- 2 s per cycle; every file is 1 s long
local function timefn(c) return 10 + c * 2 end
local function plan(code, o)
  o = o or {}
  local res, err = Strudel.run(code)
  assert(res, err)
  local p, e = Core.plan_pattern({ guid = "G", name = "P", layers = res.layers, mode = o.mode or "audio", groups = o.groups or sounds("bd", "sn", "tr909_bd"),
    cycles = o.cycles or 1, timefn = o.timefn or timefn, lenfn = function() return 1 end, aliases = o.aliases, root_note = o.root })
  assert(p, e)
  return p
end

-- ---------------------------------------------------------------- aliases + bank
local p = plan('s("sd")')
T.eq(#p.audio, 0, "aliases off: sd is not sn")
T.ok(p.warnings[1] and p.warnings[1]:find("sd"), "aliases off: warning names the sound")
p = plan('s("sd")', { aliases = true })
T.eq(#p.audio, 1, "aliases on: s(sd) finds the sn folder")
T.eq(p.audio[1].gname, "sn", "folder used")
p = plan('s("snare")', { aliases = true, groups = sounds("sd") })
T.eq(#p.audio, 1, "aliases on: s(snare) finds a folder called sd")
p = plan('s("cr rd cb")', { aliases = true, groups = sounds("crash", "ride", "cowbell") })
T.eq(#p.audio, 3, "cr / rd / cb find crash / ride / cowbell")
p = plan('s("bd").bank("tr909")')
T.eq(p.audio[1].gname, "tr909_bd", "bank prefix: tr909_bd")
p = plan('s("bd").bank("nope")')
T.eq(p.audio[1].gname, "bd", "unknown bank falls back to the plain name")
T.ok(p.warnings[1] and p.warnings[1]:find("nope_bd"), "and says so")
p = plan('s("sd").bank("tr909")', { aliases = true, groups = sounds("tr909_sn", "sn") })
T.eq(p.audio[1].gname, "tr909_sn", "bank + alias: tr909_sn")

-- GM drum names for MIDI
local names = { "sd", "rim", "lt", "mt", "ht", "cr", "rd", "cb", "perc" }
local notes = { 38, 37, 41, 47, 50, 49, 51, 56, 60 }
p = plan('s("sd rim lt mt ht cr rd cb perc")', { mode = "midi", aliases = false })
T.eq(#(p.midi[1] and p.midi[1].notes or {}), 0, "aliases off: the nine short names make no MIDI notes")
p = plan('s("sd rim lt mt ht cr rd cb perc")', { mode = "midi", aliases = true })
for i, nm in ipairs(names) do T.eq(p.midi[1].notes[i] and p.midi[1].notes[i].pitch, notes[i], "aliases on: " .. nm .. " -> GM " .. notes[i]) end
T.eq(p.midi[1].notes[1].chan, 10, "drums on channel 10")
p = plan('s("bd sn hh")', { mode = "midi", aliases = false })
T.eq(#p.midi[1].notes, 3, "bd / sn / hh work without the aliases switch")

-- ---------------------------------------------------------------- repitch with note()
p = plan('s("bd").note("c2")')
T.ok(near(p.audio[1].rate, 1), "note c2 = root 36: unchanged")
p = plan('s("bd").note("c3")')
T.ok(near(p.audio[1].rate, 2), "note c3 = +12: rate 2")
T.ok(near(p.audio[1].len, 0.5), "and half the length")
p = plan('s("bd").note(33)')
T.ok(near(p.audio[1].rate, 2 ^ (-3 / 12)), "note 33: three semitones down")
p = plan('s("bd").note(60).speed(0.5)', { root = 60 })
T.ok(near(p.audio[1].rate, 0.5), "root note setting (60): note 60 is unchanged, speed 0.5 stays")
p = plan('s("bd").note("c3").speed(2)')
T.ok(near(p.audio[1].rate, 4), "note and speed multiply")
p = plan('s("bd").n(1).note("c2")')
T.eq(p.audio[1].sound.file, "b.wav", "n still picks the file")

-- ---------------------------------------------------------------- begin / end / reverse / speed 0
p = plan('s("bd").begin(0.25).end(0.75)')
T.ok(near(p.audio[1].offs, 0.25) and near(p.audio[1].len, 0.5), "begin/end: start offset 0.25, length 0.5")
p = plan('s("bd").begin(0.25).end(0.75).speed(2)')
T.ok(near(p.audio[1].len, 0.25), "begin/end and speed 2: length 0.25")
p = plan('s("bd").speed(-1)')
T.ok(p.audio[1].reverse and near(p.audio[1].rate, 1), "negative speed: reversed, rate = |speed|")
T.ok(#p.warnings == 0, "no 'not supported' warning any more")
p = plan('s("bd").speed(-2).begin(0.25).end(0.5)')
T.ok(near(p.audio[1].offs, 0.5) and near(p.audio[1].len, 0.125), "reverse + begin/end: cut from the reversed file (offset 1 - end)")
p = plan('s("bd").speed(0)')
T.eq(#p.audio, 0, "speed 0 plays nothing")
p = plan('s("bd").begin(0.8).end(0.2)')
T.eq(#p.audio, 0, "end before begin: skipped")
T.ok(p.warnings[1] and p.warnings[1]:find("begin"), "with a warning")

-- ---------------------------------------------------------------- chop / striate / slice / splice / bite / loopAt / fit
p = plan('s("bd").chop(4)')
T.eq(#p.audio, 4, "chop(4): 4 items")
T.ok(near(p.audio[2].offs, 0.25) and near(p.audio[2].len, 0.25), "second chop: offset 0.25, length 0.25")
T.ok(near(p.audio[2].pos - p.audio[1].pos, 0.5), "spread over the event (2 s cycle / 4)")
p = plan('s("bd").striate(2)')
T.eq(#p.audio, 2, "striate(2): 2 items per event")
p = plan('s("bd").slice(4, "2 0")')
T.ok(near(p.audio[1].offs, 0.5) and near(p.audio[2].offs, 0), "slice(4, '2 0')")
p = plan('s("bd").splice(4, "0 2")')
T.ok(near(p.audio[1].len, 1) and near(p.audio[2].len, 1), "splice: every slice is stretched over its event (1 s of a 2 s cycle)")
T.ok(near(p.audio[2].offs, 0.5), "splice: second slice starts at the middle of the file")
p = plan('s("bd").loopAt(2)', { cycles = 2 })
T.eq(#p.audio, 1, "loopAt(2): one item")
T.ok(near(p.audio[1].len, 4), "loopAt(2): the 1 s file is stretched over 2 cycles = 4 s")
p = plan('s("bd bd").fit()')
T.ok(near(p.audio[1].len, 1), "fit: the file fills its event (1 s)")
p = plan('s("bd*2").fit()', { timefn = function(c) return 10 + c * 4 end })
T.ok(near(p.audio[1].len, 2), "fit follows a slower tempo (4 s per cycle: events are 2 s)")
p = plan('n("0 .. 3").bite(2, "1 0")')
T.eq(#p.audio, 0, "bite on n() without a sound: nothing audible, nothing broken")

-- ---------------------------------------------------------------- loop / cut / postgain / legato
p = plan('s("bd").loop(1)')
T.ok(p.audio[1].loop and near(p.audio[1].len, 2), "loop: item is as long as the event (2 s), looping")
p = plan('s("bd*4").cut(1)', { groups = sounds("bd") })
-- 4 events 0.5 s apart, 1 s files: the first three are cut at the next onset
T.ok(near(p.audio[1].len, 0.5) and near(p.audio[3].len, 0.5) and near(p.audio[4].len, 1), "cut(1): earlier items stop at the next onset")
T.ok(p.audio[1].fade, "and get a short fade")
p = plan('s("bd*4")', { groups = sounds("bd") })
T.ok(near(p.audio[1].len, 1), "no cut: items overlap as before")
p = plan('s("bd bd").cut("1 2")')
T.ok(near(p.audio[1].len, 1), "different cut groups do not cut each other")
p = plan('s("bd").gain(0.5).postgain(0.5)')
T.ok(near(p.audio[1].vol, 0.25), "postgain multiplies the volume")
p = plan('note("c3").postgain(0.5)', { mode = "midi" })
T.eq(p.midi[1].notes[1].vel, 51, "postgain on MIDI velocity: 127 * 0.8 * 0.5 = 50.8")

-- ---------------------------------------------------------------- MIDI: octave, midichan, cc, progNum, midibend
p = plan('note("c3").octave(1)', { mode = "midi" })
T.eq(p.midi[1].notes[1].pitch, 60, "octave(1): c3 -> 60")
p = plan('note("c3").oct(-1)', { mode = "midi" })
T.eq(p.midi[1].notes[1].pitch, 36, "oct(-1)")
p = plan('note("c3").o(2)', { mode = "midi" })
T.eq(p.midi[1].notes[1].pitch, 48, "o() is Strudel's orbit, not octave: the note is unchanged")
p = plan('note("c3").midichan(5)', { mode = "midi" })
T.eq(p.midi[1].notes[1].chan, 5, "midichan")
p = plan('note("c3").ccn(74).ccv(0.5)', { mode = "midi" })
T.eq(#p.midi[1].ctls, 1, "ccn + ccv: one controller event")
local c = p.midi[1].ctls[1]
T.ok(c.kind == "cc" and c.a == 74 and c.b == 64 and c.chan == 1, "cc 74 = 64 (0.5 * 127 rounded) on channel 1")
p = plan('s("x x").ccn("1 2").ccv("0.25 1")', { mode = "midi" })
T.eq(#p.midi[1].ctls, 2, "controller events without any note")
T.eq(#p.warnings, 0, "no 'neither s nor note' warning for them")
p = plan('note("c").progNum("<5>")', { mode = "midi" })
T.ok(p.midi[1].ctls[1].kind == "pc" and p.midi[1].ctls[1].a == 5, "progNum -> program change")
p = plan('note("c").midibend(-1)', { mode = "midi" })
T.ok(p.midi[1].ctls[1].kind == "pb" and p.midi[1].ctls[1].a == 0 and p.midi[1].ctls[1].b == 0, "midibend -1 = 0")
p = plan('note("c").midibend(1)', { mode = "midi" })
T.ok(p.midi[1].ctls[1].a == 127 and p.midi[1].ctls[1].b == 127, "midibend 1 = 16383")
p = plan('note("c").midibend(0)', { mode = "midi" })
T.ok(p.midi[1].ctls[1].a == 0 and p.midi[1].ctls[1].b == 64, "midibend 0 = 8192")
p = plan('note("c").ccn(1).ccv(2)', { mode = "midi" })
T.ok(p.warnings[1] and p.warnings[1]:find("ccv"), "ccv out of range: warning")
p = plan('note("c").progNum(200)', { mode = "midi" })
T.ok(p.warnings[1] and p.warnings[1]:find("progNum"), "progNum out of range: warning")

-- tonal: scale() output goes straight to MIDI
p = plan('n("0 2 4").scale("C:major")', { mode = "midi", cycles = 1 })
T.eq(p.midi[1].notes[1].pitch .. "," .. p.midi[1].notes[2].pitch .. "," .. p.midi[1].notes[3].pitch, "48,52,55", "scale C:major: c3 e3 g3")
p = plan('n("0 2").scale("D:minor").scaleTranspose(1)', { mode = "midi" })
T.eq(p.midi[1].notes[1].pitch, 52, "scaleTranspose: D3 + 1 step = E3")
p = plan('note("c3 e3").transpose(12)', { mode = "midi" })
T.eq(p.midi[1].notes[1].pitch, 60, "transpose(12)")
p = plan('note("c3").transpose("5P")', { mode = "midi" })
T.eq(p.midi[1].notes[1].pitch, 55, "transpose('5P')")

-- signatures: the new fields change the signature (so changed items are rewritten)
local a = { key = "k", pos = 1, len = 1, vol = 1, pan = 0, rate = 1 }
local b = { key = "k", pos = 1, len = 1, vol = 1, pan = 0, rate = 1, offs = 0.5 }
local d = { key = "k", pos = 1, len = 1, vol = 1, pan = 0, rate = 1, reverse = true }
T.ok(Core.item_sig(a) ~= Core.item_sig(b) and Core.item_sig(a) ~= Core.item_sig(d), "start offset and reverse are part of the item signature")

-- ---------------------------------------------------------------- the REAPER layer
M.make_sounds("/snd", { bd = { "a.wav" }, sn = { "s.wav" } }, { ["a.wav"] = 1, ["s.wav"] = 1 })
local app = App.new()
app:set_root("/snd")
local tr = M.new_user_track("P")
r.SetOnlyTrackSelected(tr)
local function run(secs) for _ = 1, math.ceil(secs / 0.2) do S.clock = S.clock + 0.2; app:tick() end end
local it = M.add_empty_item(tr, 0, 8, '$: s("bd").begin(0.25).end(0.75).speed(-1).loop(0)')
app:adopt()          -- selects nothing: adopt works on the selection
r.SetMediaItemSelected(it, true)
app:adopt()
run(1)
local ai = M.items_of("a")
T.eq(#ai, 4, "4 bars of one bd each")
local tk = ai[1].takes[1]
T.ok(near(tk.p.D_STARTOFFS, 0.25), "D_STARTOFFS = (1 - end) * length = 0.25 s (reverse cuts from the reversed file)")
T.ok(ai[1].p.reversed, "reversed through the toggle-take-reverse action")
T.eq(ai[1].ext.GS_REV, "1", "and remembered in a tag")
T.ok(near(ai[1].p.D_LENGTH, 0.5), "item length 0.5 s")
-- rewrite: reverse is toggled back before the change and set again (state stays reversed, exactly one net toggle)
local n0 = #S.commands
app.cfg.root_note = 36
it.notes = '$: s("bd").begin(0).end(0.5).speed(-1)'
M.touch()
run(1)
ai = M.items_of("a")
T.ok(ai[1].p.reversed, "still reversed after an edit")
T.ok(near(ai[1].takes[1].p.D_STARTOFFS, 0.5), "new offset (1 - 0.5) * 1 s")
T.ok(#S.commands > n0, "toggled again")
it.notes = '$: s("bd")'
M.touch()
run(1)
ai = M.items_of("a")
T.ok(not ai[1].p.reversed, "back to normal: not reversed")
T.ok(near(ai[1].takes[1].p.D_STARTOFFS, 0), "offset 0")
T.eq(ai[1].ext.GS_REV, nil, "tag cleared")

-- loop flag
it.notes = '$: s("bd").loop(1)'
M.touch(); run(1)
ai = M.items_of("a")
T.eq(ai[1].p.B_LOOPSRC, 1, "loop sets B_LOOPSRC")

-- settings: global, saved, part of the render
T.eq(app.cfg.aliases, false, "aliases are off by default")
it.notes = '$: s("sd")'
M.touch(); run(1)
T.eq(#M.items_of("s"), 0, "s(sd) renders nothing with aliases off")
app:set_aliases(true)
run(1)
T.eq(#M.items_of("s"), 4, "switching aliases on re-renders: s(sd) now finds sn")
T.eq(S.ext["Gingersnap/aliases"], "1", "saved in the global ExtState")
T.eq(RA.load_cfg().aliases, true, "and loaded again")
T.ok(app:set_root_note("c3") and app.cfg.root_note == 48, "root note 'c3' = 48")
T.ok(app:set_root_note("60") and app.cfg.root_note == 60, "root note 60")
T.ok(not app:set_root_note("nonsense"), "bad root note refused")
T.eq(app.cfg.root_note, 60, "and left as it was")
T.eq(S.ext["Gingersnap/root_note"], "60", "root note saved")

-- MIDI controllers reach the take
it.notes = '$: note("c3").ccn(74).ccv(0.5)\n$: note("e3").progNum(3).midibend(0)'
app:set_mode(RA.read_patterns()[1].guid, false, true)
M.touch(); run(1)
local found_cc, found_pc, found_pb
for _, t in ipairs(S.tracks) do
  if t.ext.GS_ROLE == "midi" then
    for _, x in ipairs(t.items) do
      for _, c in ipairs(x.takes[1] and x.takes[1].ccs or {}) do
        if c.msg1 == 0xB0 and c.a == 74 and c.b == 64 then found_cc = true end
        if c.msg1 == 0xC0 and c.a == 3 then found_pc = true end
        if c.msg1 == 0xE0 and c.a == 0 and c.b == 64 then found_pb = true end
      end
    end
  end
end
T.ok(found_cc, "CC 74 = 64 inserted as 0xB0")
T.ok(found_pc, "program change 3 inserted as 0xC0")
T.ok(found_pb, "pitch bend 0 inserted as 0xE0 (lsb 0, msb 64)")

T.done("test_v02")
