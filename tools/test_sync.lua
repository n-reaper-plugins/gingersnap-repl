-- Offline tests of GSReaper + GSApp against the fake REAPER: structure, tags, diffing, time mapping, MIDI.
package.path = "./src/?.lua;./strudel-lua/src/?.lua;./tools/?.lua;" .. package.path
local T = require("t")
local Mock = require("mock_reaper")
local M = Mock.install()
local S = M.S
local r = reaper

local App = require("GSApp")
local RA = require("GSReaper")

M.make_sounds("/snd", { bd = { "a.wav", "b.wav" }, sn = { "s.wav" }, hh = { "h.wav" } },
  { ["a.wav"] = 0.3, ["b.wav"] = 0.4, ["s.wav"] = 0.25, ["h.wav"] = 0.1 })

local function names(t) local o = {}; for i, x in ipairs(t) do o[i] = (x:gsub("^%s+", "")) end; return table.concat(o, " / ") end
local function run(app, secs)
  for _ = 1, math.ceil(secs / 0.2) do S.clock = S.clock + 0.2; app:tick() end
end

local app = App.new()
app:set_root("/snd")
T.eq(app.ngroups, 3, "3 sound folders found")

-- the pattern track and a new pattern item ---------------------------------------------------
local drums = M.new_user_track("Drums")
r.SetOnlyTrackSelected(drums)
S.edit_cursor = 2                                   -- 2 s = 4 quarter notes = bar 2
app:new_pattern()
local pats = RA.read_patterns()
T.eq(#pats, 1, "one pattern item")
T.eq(#pats[1].item.takes, 0, "pattern item is EMPTY (no take)")
T.eq(pats[1].pos, 2, "at the edit cursor")
T.eq(pats[1].len, 8, "4 cycles x 4 beats at 120 bpm = 8 s")
T.eq(pats[1].cycles, 4, "4 cycles")
T.ok(pats[1].code:find('s%("bd%*2, ~ hh"%)'), "default code uses real folder names: " .. pats[1].code)
T.eq(pats[1].item.track, drums, "item is on the selected track")

run(app, 1)
local st = M.structure()
T.eq(names(st), "Drums / GINGERSNAP / bd / a / hh / h", "tracks: GINGERSNAP > bd > a, hh > h  (got " .. names(st) .. ")")
local _, bal = M.structure()
T.eq(bal, 0, "folder structure balanced")
local a_items = M.items_of("a")
T.eq(#a_items, 8, "bd*2 in 4 cycles = 8 items")
table.sort(a_items, function(x, y) return x.p.D_POSITION < y.p.D_POSITION end)
T.eq(a_items[1].p.D_POSITION, 2, "first bd at the item start")
T.eq(a_items[2].p.D_POSITION, 3, "second bd half a cycle later (1 s)")
T.eq(a_items[3].p.D_POSITION, 4, "next cycle starts 2 s later")
T.eq(a_items[1].p.D_LENGTH, 0.3, "natural length")
T.eq(a_items[1].takes[1].src.path, "/snd/bd/a.wav", "source file")
T.eq(#M.items_of("h"), 4, "~ hh -> 1 per cycle")
T.eq(M.items_of("h")[1].p.D_POSITION, 3, "hh on the 2nd half of the cycle")
T.eq(a_items[1].ext.GS_OWN, pats[1].guid, "generated item is tagged with its owner")

-- idempotent: no re-render when nothing changed
local undo0 = S.undo
run(app, 2)
T.eq(S.undo, undo0, "no work when nothing changed")

-- hand edits survive while the plan does not change -----------------------------------------
M.items_of("a")[1].p.D_VOL = 0.42
app:render_now(); run(app, 0.4)
T.eq(M.items_of("a")[1].p.D_VOL, 0.42, "hand-edited volume survives a re-render")

-- changing the code ---------------------------------------------------------------------------
app:set_edit_code('$: s("sn*4").gain(0.5)')
run(app, 1.5)
T.eq(names((M.structure())), "Drums / GINGERSNAP / sn / s", "code change replaces the groups")
T.eq(#M.items_of("s"), 16, "sn*4 x 4 cycles")
T.eq(M.items_of("s")[1].p.D_VOL, 0.5, "gain -> item volume")
T.eq(pats[1].item.notes, '$: s("sn*4").gain(0.5)', "code is stored in the item notes")

-- the item drives the time range ---------------------------------------------------------------
local it = pats[1].item
r.SetMediaItemInfo_Value(it, "D_POSITION", 10)
run(app, 1)
local s_items = M.items_of("s")
table.sort(s_items, function(x, y) return x.p.D_POSITION < y.p.D_POSITION end)
T.eq(s_items[1].p.D_POSITION, 10, "moving the item moves the result")
T.eq(#s_items, 16, "same amount")
r.SetMediaItemInfo_Value(it, "D_LENGTH", 4)          -- 2 cycles
run(app, 1)
T.eq(#M.items_of("s"), 8, "resizing the item to 2 cycles keeps 8 events")
r.SetMediaItemInfo_Value(it, "D_LENGTH", 5)          -- 2.5 cycles: the half cycle still has 2 onsets
run(app, 1)
T.eq(#M.items_of("s"), 10, "2.5 cycles -> 10 events")

-- tempo change follows (beats, not seconds) ------------------------------------------------------
r.SetMediaItemInfo_Value(it, "D_LENGTH", 4)
run(app, 1)
M.set_tempo(60)                                     -- 1 quarter note = 1 s: the item (pos 10, 4 s) is 1 cycle now
run(app, 1)
s_items = M.items_of("s")
table.sort(s_items, function(x, y) return x.p.D_POSITION < y.p.D_POSITION end)
T.eq(#s_items, 4, "60 bpm: the 4 s item holds one cycle of sn*4")
T.eq(s_items[2].p.D_POSITION, 11, "60 bpm: hits every second")
M.set_tempo(120)
run(app, 1)

-- beats per cycle ------------------------------------------------------------------------------------
app:set_cycle(pats[1].guid, 2)                        -- 1 cycle = 2 quarter notes = 1 s
run(app, 1)
s_items = M.items_of("s")
table.sort(s_items, function(x, y) return x.p.D_POSITION < y.p.D_POSITION end)
T.eq(s_items[2].p.D_POSITION, 10.25, "cycle of 2 beats: sn*4 -> every 0.25 s")
T.eq(#s_items, 16, "item of 4 s = 4 cycles of 1 s")
app:set_cycle(pats[1].guid, 4)
run(app, 1)

-- MIDI and both --------------------------------------------------------------------------------------
app:set_edit_code('$: s("sn(3,8)")\nbass: note("c2 e2")')
app:set_mode(pats[1].guid, false, true)
run(app, 1.5)
local struct = names((M.structure()))
T.eq(struct, "Drums / GINGERSNAP / MIDI / Pattern 1 $1 / Pattern 1 bass", "MIDI only: one track per layer (got " .. struct .. ")")
local mt = M.track_named("Pattern 1 bass")
T.eq(#mt.items, 1, "one MIDI item per layer")
T.eq(#mt.items[1].takes[1].notes, 2 * 2, "4 notes in the 2 cycles of the item")
T.eq(mt.items[1].takes[1].notes[1].pitch, 36, "c2 = 36")
T.eq(mt.items[1].p.D_POSITION, 10, "MIDI item spans the pattern item")
T.eq(mt.items[1].p.D_LENGTH, 4, "and has its length")
local dr = M.track_named("Pattern 1 $1").items[1].takes[1].notes
T.eq(#dr, 6, "sn(3,8) x 2 cycles = 6 drum notes")
T.eq(dr[1].pitch, 38, "sn -> GM 38")
T.eq(dr[1].chan, 9, "channel 10 (0-based 9)")

app:set_mode(pats[1].guid, true, true)
run(app, 1.5)
struct = names((M.structure()))
T.ok(struct:find("MIDI") and struct:find("sn"), "both: MIDI group and audio group (" .. struct .. ")")
T.eq(#M.items_of("s"), 6, "audio items too")

-- errors pause rendering and keep the old result -----------------------------------------------------
local before = #S.items
app:set_edit_code('$: s("sn*4").nope(2)')
run(app, 1.5)
T.ok(app.status[pats[1].guid].err:find("line 1"), "error mentions the line: " .. tostring(app.status[pats[1].guid].err))
T.ok(app.status[pats[1].guid].err:find("nope"), "error names the unknown method")
T.eq(#S.items, before, "old result is kept while the code has an error")
app:set_edit_code('$: s("bd")')
run(app, 1.5)
T.ok(not app.blocked, "fixed code renders again")

-- a second pattern via Insert > Empty item -------------------------------------------------------------
local e = M.add_empty_item(drums, 30, 4, '$: s("hh*4")')
M.select_item(e)
app:adopt()
run(app, 1.5)
T.eq(#RA.read_patterns(), 2, "two patterns")
T.eq(#M.items_of("h"), 8, "second pattern's hh items")
T.eq(e.ext.GS_PAT, "1", "adopted item is tagged")

-- follow selection: clicking a pattern item on the timeline opens it in the editor -----------------------
local eg = e.guid
M.select_item(e)
run(app, 0.5)
T.eq(app.cur, eg, "selecting the item on the timeline switches the editor")
T.eq(app.edit.code, '$: s("hh*4")', "editor shows that item's code")
e.notes = '$: s("hh*2")'                            -- edited in REAPER's item-notes window
M.touch(); run(app, 0.5)
T.eq(app.edit.code, '$: s("hh*2")', "external edits of the notes reach the editor")
app:set_edit_code('$: s("hh*4")'); run(app, 1)
M.select_item(pats[1].item); run(app, 0.5)
T.eq(app.cur, pats[1].guid, "and back")

-- the same sound in two patterns shares tracks; overlaps get voices -----------------------------------
local e2 = M.add_empty_item(drums, 30, 4, '$: s("hh*4")')
M.select_item(e2); app:adopt(); run(app, 1.5)
local hs = M.items_of("h")
T.eq(#hs + #M.items_of("h (2)"), 16, "two hh patterns x 8 items")
T.ok(#M.items_of("h (2)") > 0, "identical overlapping patterns use a second voice track")
for _, tr in ipairs({ "h", "h (2)" }) do
  local xs = M.items_of(tr)
  table.sort(xs, function(a, b) return a.p.D_POSITION < b.p.D_POSITION end)
  for i = 2, #xs do
    T.ok(xs[i].p.D_POSITION >= xs[i - 1].p.D_POSITION + xs[i - 1].p.D_LENGTH - 1e-9, "no overlap on " .. tr)
  end
end
r.DeleteTrackMediaItem(drums, e2); run(app, 1.5)
T.eq(M.track_named("h (2)"), nil, "the voice track disappears with the pattern")

-- freeze a pattern: items stay, ordinary ----------------------------------------------------------------
local pats2 = RA.read_patterns()
local second = pats2[2]
local n_before = #M.items_of("h")
app:freeze_pattern(second.guid)
run(app, 1.5)
T.eq(#M.items_of("h"), n_before, "frozen items stay")
T.eq(M.items_of("h")[1].ext.GS_OWN, nil, "and are untagged")
T.eq(second.item.ext.GS_OFF, "1", "frozen pattern is switched off")

-- deleting the pattern item removes what it generated -----------------------------------------------------
app:delete_pattern(pats[1].guid)
run(app, 1.5)
T.eq(M.track_named("sn"), nil, "sn group gone")
T.eq(M.track_named("bd"), nil, "bd group gone")

-- detach ------------------------------------------------------------------------------------------------------
app:detach()
local left = 0
for _, t in ipairs(S.tracks) do if t.ext.GS_ROLE then left = left + 1 end end
T.eq(left, 0, "no managed tracks after detach")
T.ok(M.track_named("GINGERSNAP") ~= nil, "tracks stay as ordinary ones")

-- project state is not dirtied by merely looking --------------------------------------------------------------
local app2 = App.new()
local w = S.writes
app2:tick(); app2:save()
T.eq(S.writes, w, "opening the window writes nothing into the project")

T.done("test_sync")
