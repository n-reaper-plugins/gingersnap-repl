-- Offline tests of GSCore (pure logic): planning, voices, GM drums, signatures.
package.path = "./src/?.lua;./strudel-lua/src/?.lua;./tools/?.lua;" .. package.path
local T = require("t")
local Core = require("GSCore")
local Strudel = require("strudel")

local groups = {
  bd = { name = "bd", path = "/s/bd", sounds = { { file = "a.wav", name = "a", path = "/s/bd/a.wav" }, { file = "b.wav", name = "b", path = "/s/bd/b.wav" }, { file = "c.wav", name = "c", path = "/s/bd/c.wav" } } },
  hh = { name = "HH", path = "/s/HH", sounds = { { file = "h1.wav", name = "h1", path = "/s/HH/h1.wav" } } },
}
local lens = { ["/s/bd/a.wav"] = 0.3, ["/s/bd/b.wav"] = 0.6, ["/s/bd/c.wav"] = 0.2, ["/s/HH/h1.wav"] = 0.1 }
-- 2 seconds per cycle, pattern item starts at 10 s
local function timefn(c) return 10 + c * 2 end
local function plan(code, mode, cycles)
  local r, err = Strudel.run(code)
  assert(r, err)
  return Core.plan_pattern({ guid = "G", name = "P", layers = r.layers, mode = mode or "audio", groups = groups,
    cycles = cycles or 1, timefn = timefn, lenfn = function(p) return lens[p] end })
end

-- folder = sound name, :N = Nth file (0-based, wraps), n() too, case-insensitive
local p = plan('s("bd bd:1 bd:4 BD").n("0 1 2 3")')          -- .n() overrides the :N of the mini-notation
T.eq(#p.audio, 4, "4 audio items")
T.eq(p.audio[1].sound.file, "a.wav", "bd -> first file")
T.eq(p.audio[2].sound.file, "b.wav", "n(1) -> second file")
T.eq(p.audio[3].sound.file, "c.wav", "n(2) -> third file")
T.eq(p.audio[4].sound.file, "a.wav", "n(3) wraps around to the first")
p = plan('s("bd:1 bd:4")')
T.eq(p.audio[1].sound.file, "b.wav", "bd:1")
T.eq(p.audio[2].sound.file, "b.wav", "bd:4 wraps to (4 mod 3)=1 -> b")
p = plan('s("bd").n("-1")')
T.eq(p.audio[1].sound.file, "c.wav", "negative n wraps from the end")

-- timing: 4 events in one cycle of 2 seconds
p = plan('s("bd*4")')
T.eq(#p.audio, 4, "bd*4")
T.eq(p.audio[2].pos, 10.5, "second hit at 10.5")
T.eq(p.audio[1].len, 0.3, "natural length")

-- only events whose onset is inside the item are kept
p = plan('s("bd*4")', "audio", 0.5)
T.eq(#p.audio, 2, "half a cycle -> 2 events")
p = plan('s("bd*4")', "audio", 2.5)
T.eq(#p.audio, 10, "2.5 cycles -> 10 events")

-- gain / velocity / pan / speed / legato
p = plan('s("hh").gain(0.5).velocity(0.5).pan(0).speed(2)')
T.eq(p.audio[1].vol, 0.25, "gain*velocity")
T.eq(p.audio[1].pan, -1, "pan 0 -> -1")
T.eq(p.audio[1].rate, 2, "speed -> rate")
T.eq(p.audio[1].len, 0.05, "length = file / speed")
p = plan('s("bd").clip(0.1)')          -- 0.1 of a 2 s event = 0.2 s < 0.3 s file
T.ok(math.abs(p.audio[1].len - 0.2) < 1e-9, "clip trims the item")
T.ok(p.audio[1].fade, "trimmed item gets a fade")

-- unknown sounds are reported, not silently dropped
p = plan('s("bd kick")')
T.eq(#p.audio, 1, "unknown sound skipped")
T.ok(p.warnings[1] and p.warnings[1]:find("kick"), "warning names the sound")

-- MIDI: note names (Strudel: c3 = 48), n() as number, GM drums
p = plan('note("c3 e3 g3")', "midi")
T.eq(#p.midi, 1, "one midi layer")
T.eq(p.midi[1].notes[1].pitch, 48, "c3 = 48")
T.eq(p.midi[1].notes[2].pitch, 52, "e3 = 52")
T.eq(p.midi[1].notes[3].vel, 102, "default velocity 0.8*127")
p = plan('n("60 64")', "midi")
T.eq(p.midi[1].notes[2].pitch, 64, "n without s = midi note")
p = plan('s("bd sn hh")', "midi")
T.eq(p.midi[1].notes[1].pitch, 36, "bd -> 36")
T.eq(p.midi[1].notes[2].pitch, 38, "sn -> 38")
T.eq(p.midi[1].notes[1].chan, 10, "drums on channel 10")
T.eq(#p.audio, 0, "midi mode makes no audio")
p = plan('s("bd").gain(0.5)', "midi")
T.eq(p.midi[1].notes[1].vel, 51, "gain scales the velocity")
p = plan('note("c e").legato(0.5)', "midi")
T.eq(p.midi[1].notes[1].stop - p.midi[1].notes[1].pos, 0.5, "legato 0.5 of a 1 s event")

-- both: an event with a known sound AND a mappable drum name gives audio + midi
p = plan('s("bd sn")', "both")
T.eq(#p.audio, 1, "audio only for the sound that exists (bd)")
T.eq(#p.midi[1].notes, 2, "midi for both drums")

-- layers
p = plan('$: s("bd")\nbass: note("c2")', "both")
T.eq(#p.midi, 2, "2 layers -> 2 midi entries (bd is a drum)")
T.eq(p.midi[2].label, "bass", "label kept")

-- limit
local r = Strudel.run('s("bd*512").fast(64)')
local q, err = Core.plan_pattern({ guid = "G", name = "P", layers = r.layers, mode = "audio", groups = groups, cycles = 8, timefn = timefn, lenfn = function() return 1 end })
T.ok(q == nil and err:find("too many"), "event limit")

-- voices: overlapping items of one sound get duplicate tracks
p = plan('s("bd*8")')             -- 0.25 s apart, files 0.3 s long -> always overlapping the next
local comp = Core.compose({ { pattern = { guid = "G", name = "P", pos = 10, len = 2 }, plan = p } })
T.eq(#comp.groups, 1, "one group")
local voices = 0
for _, t in ipairs(comp.groups[1].tracks) do voices = math.max(voices, t.voice) end
T.eq(voices, 2, "two voices are enough")
for _, t in ipairs(comp.groups[1].tracks) do
  table.sort(t.items, function(a, b) return a.pos < b.pos end)
  for i = 2, #t.items do
    T.ok(t.items[i].pos >= t.items[i - 1].pos + t.items[i - 1].len - 1e-9, "no overlap inside a track")
  end
end
T.eq(comp.groups[1].tracks[2].name, "a (2)", "voice track name")

-- signature: stable, and changes when anything changes
local c2 = Core.compose({ { pattern = { guid = "G", name = "P", pos = 10, len = 2 }, plan = plan('s("bd*8")') } })
T.eq(comp.sig, c2.sig, "same plan -> same signature")
local c3 = Core.compose({ { pattern = { guid = "G", name = "P", pos = 10, len = 2 }, plan = plan('s("bd*8").gain(0.5)') } })
T.ok(comp.sig ~= c3.sig, "different plan -> different signature")

-- groups signature
T.ok(Core.groups_sig(groups) == Core.groups_sig(groups), "groups sig stable")

T.done("test_core")
