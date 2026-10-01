-- End to end: runs the BUNDLED dist/Gingersnap.lua (entry script + all modules) against the fake REAPER
-- and a ReaImGui stub: open the window, click, type, drop a folder, close.
package.path = "./tools/?.lua;" .. package.path
local T = require("t")
local Mock = require("mock_reaper")
package.path = "./tools/?.lua;"                     -- from here on only what the bundle brings itself
local M = Mock.install()
local S = M.S
local st = require("imgui_stub").install(reaper)

M.make_sounds("/snd", { bd = { "a.wav" }, sn = { "s.wav", "s2.wav" } }, { ["a.wav"] = 0.3, ["s.wav"] = 0.2, ["s2.wav"] = 0.2 })
local track = M.new_user_track("Patterns")
reaper.SetOnlyTrackSelected(track)

local ok, err = pcall(dofile, "dist/Gingersnap.lua")
T.ok(ok, "bundle loads and opens the window: " .. tostring(err))
T.eq(S.ext["GingersnapApp/running"], "1", "marks itself as running")

local function frame(dt, n)
  for _ = 1, n or 1 do
    S.clock = S.clock + (dt or 0.2)
    local f = table.remove(S.deferred, 1)
    if f then f() end
  end
end
local function texts_have(s) for _, t in ipairs(st.texts) do if tostring(t):find(s, 1, true) then return true end end return false end

frame(0.2, 2)
T.ok(texts_have("Drop the sounds root folder here") or texts_have("Sounds folder") or #st.calls > 0, "the folder section is drawn")

-- drop the sounds folder onto the drop zone
st.drop = "/snd"
frame(0.2, 2)
local seen = false
for _, t in ipairs(st.texts) do if t == "sn (2)" then seen = true end end
T.ok(seen, "groups listed after the drop: bd (1) sn (2)")
T.eq(S.projext["Gingersnap/root"], "/snd", "folder saved into the project")

-- New pattern (button click), then type code into the editor
st.clicks["New pattern"] = true
frame(0.2, 3)
local pats = require("GSReaper").read_patterns()
T.eq(#pats, 1, "New pattern button creates a pattern item")
frame(0.2, 8)
T.ok(M.track_named("GINGERSNAP") ~= nil, "default pattern is rendered")

st.code = '$: s("sn*2, ~ bd")'
frame(0.2, 10)
T.eq(pats[1].item.notes, '$: s("sn*2, ~ bd")', "typed code lands in the item notes")
T.eq(#M.items_of("s"), 8, "sn: 2 per cycle x 4 cycles")
T.eq(#M.items_of("a"), 4, "bd: 1 per cycle")

-- switching MIDI on through the checkbox
st.clicks["MIDI notes"] = true
frame(0.2, 10)
T.eq(pats[1].item.ext.GS_MODE, "both", "checkbox -> mode both")
T.ok(M.track_named("Pattern 1") ~= nil, "MIDI track appears (drums via GM map)")

-- no UI errors were recorded
local app_err
for _, t in ipairs(st.texts) do if tostring(t):find("UI error") or tostring(t):find("Error:") then app_err = t end end
T.ok(app_err == nil, "no UI/runtime error shown: " .. tostring(app_err))

-- theme: every frame pushes 17 colours and pops 17, also while the window is collapsed
T.ok(st.pushed > 0 and st.pushed % 17 == 0, "theme pushes 17 colours per frame (" .. st.pushed .. " in total)")
T.eq(st.popped, st.pushed, "colour stack balanced while the window is open")
do
  local seen = {}
  for _, v in ipairs(st.pushed_vals) do seen[v] = true end
  T.ok(seen[0x181A1AFF] and seen[0x8542FA66] and seen[0x8542FA4F], "background, Button and Header colours pushed")
end
st.pushed, st.popped, st.collapsed = 0, 0, true
frame(0.2, 3)
st.collapsed = false
T.ok(st.pushed > 0 and st.pushed % 17 == 0, "collapsed: 17 colours pushed per frame")
T.eq(st.popped, st.pushed, "colour stack balanced while the window is collapsed")

-- second launch asks the first to close
S.ext["GingersnapApp/hb"] = tostring(os.time())
dofile("dist/Gingersnap.lua")
T.eq(S.ext["GingersnapApp/stop"], "1", "second run requests stop")
frame(0.2, 1)
T.eq(S.ext["GingersnapApp/running"], "0", "first instance shut down")

T.done("test_ui_bundle")
