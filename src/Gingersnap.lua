-- @description Gingersnap: minimal Strudel subset for REAPER - render patterns into the project (audio items and/or MIDI)
-- @version @@VERSION@@
-- @about
--   Gingersnap is a minimal Strudel subset for REAPER (not affiliated with the Strudel project).
--   Run this action to open the Gingersnap window (needs ReaImGui: ReaPack > ReaTeam Extensions;
--   a folder dialog additionally needs js_ReaScriptAPI, otherwise a file dialog / drag&drop / typing is used).
--   1. Choose a sounds root folder with one sub-folder per sound (root/bd, root/sn, root/hh).
--   2. "New pattern" inserts an EMPTY item on the timeline; its notes hold the code, e.g.  $: s("bd*2, ~ sn")
--   3. The pattern is rendered into the item's time range: audio items on tracks under a GINGERSNAP folder,
--      and/or MIDI notes (one track per $: line). Move or resize the item and the result follows.
--   s("bd:3") = 4th file of folder bd; s("bd").n(3) too.  1 cycle = "beats per cycle" quarter notes (default 4).
--   Run the action again while the window is open to close it.
--   Pattern engine: strudel-lua, a Lua implementation of Strudel's semantics. AGPL-3.0-or-later.

local r = reaper
local dir = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""
package.path = dir .. "?.lua;" .. dir .. "strudel-lua/src/?.lua;" .. package.path

if not r.ImGui_CreateContext then
  r.MB("This script needs the ReaImGui extension.\n\nInstall it via ReaPack (Extensions > ReaPack > Browse packages > 'ReaImGui').", "Gingersnap", 0)
  return
end

local App = require("GSApp")
local UI  = require("GSUI")

local EXT = "GingersnapApp"

-- single instance: running the action a second time asks the running one to close
local hb_age = os.time() - (tonumber(r.GetExtState(EXT, "hb")) or 0)
if r.GetExtState(EXT, "running") == "1" and hb_age < 3 then
  r.SetExtState(EXT, "stop", "1", false)
  return
end
r.SetExtState(EXT, "running", "1", false)
r.SetExtState(EXT, "stop", "0", false)
r.SetExtState(EXT, "hb", tostring(os.time()), false)

local _, _, sec, cmdid = r.get_action_context()
local function set_toggle(on)
  if cmdid and cmdid ~= 0 then r.SetToggleCommandState(sec, cmdid, on and 1 or 0); r.RefreshToolbar2(sec, cmdid) end
end
set_toggle(true)

local app = App.new()
local ui = UI.new(app)

local function shutdown()
  pcall(app.commit_code, app)
  app:save()
  set_toggle(false)
  r.SetExtState(EXT, "running", "0", false)
  r.SetExtState(EXT, "stop", "0", false)
end
r.atexit(shutdown)

local last_hb, last_err = 0, nil
local function loop()
  if r.GetExtState(EXT, "stop") == "1" then shutdown(); return end
  local now = r.time_precise()
  if now - last_hb > 1 then r.SetExtState(EXT, "hb", tostring(os.time()), false); last_hb = now end

  local ok, err = pcall(app.tick, app)
  if not ok and tostring(err) ~= last_err then
    last_err = tostring(err)
    app.err = "Error: " .. last_err
  end
  if ui:frame() then r.defer(loop) else shutdown() end
end

loop()
