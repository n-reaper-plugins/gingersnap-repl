-- GSUI.lua
-- ReaImGui front-end. Only reads app state and calls App methods.
-- Style/API follows PrototypeSequence (r.ImGui_* functions, colours as 0xRRGGBBAA).

local r = reaper
local Core = require("GSCore")

local UI = {}
UI.__index = UI

local COL_HEAD = 0xFFCC44FF
local COL_OK   = 0x5FE07FFF
local COL_BAD  = 0xFF5F5FFF
local COL_WARN = 0xFFAA33FF
local COL_DIM  = 0x999999FF
local COL_LIVE = 0x5FE07FFF
local COL_FROZ = 0x6FB7FFFF
local COL_CUR  = 0x2E5E8A80

UI.EXAMPLES = {
  { "drums", '$: s("bd*2, ~ sn, hh*8").gain(0.8)' },
  { "euclid", '$: s("bd(3,8), ~ sn(2,8,2), hh*8").gain(0.7)' },
  { "random", '$: s("hh*16").gain(rand.range(0.3,0.9)).degradeBy(0.3)\n$: s("bd sn").sometimes(x => x.speed(2))' },
  { "MIDI bass", '// switch on "MIDI notes" above\n$: note("<c2 e2 g2 a2>*4").legato(0.5)\nlead: note("c4 [e4 g4] <a4 b4>").off(1/8, x => x.add(note(7)))' },
}

function UI.new(app)
  local self = setmetatable({}, UI)
  self.A = app
  self.ctx = r.ImGui_CreateContext("Gingersnap")
  self.title = "Gingersnap v" .. Core.VERSION .. " - minimal Strudel subset for REAPER###gingersnap_main"
  self.path_buf = nil
  self.name_buf, self.name_guid = nil, nil
  self.cyc_buf, self.cyc_guid = nil, nil
  self.confirm_detach, self.confirm_delete, self.confirm_freeze = false, false, false
  return self
end

--------------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------------
local function fmt_pos(p)
  local ok, s = pcall(r.format_timestr_pos, p, "", 2)         -- 2 = measures.beats
  return (ok and s and s ~= "") and s or string.format("%.3f", p)
end

function UI:tip(text)
  local ctx = self.ctx
  if r.ImGui_IsItemHovered(ctx) and r.ImGui_SetTooltip then r.ImGui_SetTooltip(ctx, text) end
end

function UI:disable_if(cond)
  if cond and r.ImGui_BeginDisabled then
    r.ImGui_BeginDisabled(self.ctx, true)
    return function() r.ImGui_EndDisabled(self.ctx) end
  end
  return function() end
end

function UI:heading(text)
  local ctx = self.ctx
  r.ImGui_Spacing(ctx)
  r.ImGui_TextColored(ctx, COL_HEAD, text)
  r.ImGui_Separator(ctx)
end

-- coloured text that wraps at the window edge
function UI:wrapped(color, text)
  local ctx = self.ctx
  if r.ImGui_PushTextWrapPos then r.ImGui_PushTextWrapPos(ctx, 0) end
  r.ImGui_TextColored(ctx, color, text)
  if r.ImGui_PopTextWrapPos then r.ImGui_PopTextWrapPos(ctx) end
end

function UI:dropped_path()
  local ctx = self.ctx
  local path
  if r.ImGui_BeginDragDropTarget(ctx) then
    local a, b = r.ImGui_AcceptDragDropPayloadFiles(ctx)
    local rv, count = a, b
    if type(a) ~= "boolean" then count = a; rv = (a or 0) > 0 end
    if rv and (count or 0) > 0 then
      local x, y = r.ImGui_GetDragDropPayloadFile(ctx, 0)
      path = (type(x) == "string") and x or y
    end
    r.ImGui_EndDragDropTarget(ctx)
  end
  return path
end

function UI:browse()
  local A = self.A
  if r.JS_Dialog_BrowseForFolder then
    local rv, folder = r.JS_Dialog_BrowseForFolder("Sounds root folder (one sub-folder per sound)", A.cfg.root or "")
    if rv == 1 and folder and folder ~= "" then A:set_root(folder); self.path_buf = nil end
  else
    local ok, file = r.GetUserFileNameForRead(A.cfg.root or "", "Pick any file inside the sounds root folder", "")
    if ok and file and file ~= "" then A:set_root(file); self.path_buf = nil end
  end
end

--------------------------------------------------------------------------------
-- sounds folder
--------------------------------------------------------------------------------
function UI:draw_folder()
  local ctx, A = self.ctx, self.A
  self:heading("Sounds folder  (folder name = sound name:  bd/  ->  s(\"bd\"),  s(\"bd:3\") = 4th file)")

  local w = select(1, r.ImGui_GetContentRegionAvail(ctx))
  local SQ = 46
  local label = (A.cfg.root ~= "") and (A.cfg.root .. "\n(click to change, or drop another folder here)")
    or "Drop the sounds root folder here\n(click to browse)"
  if r.ImGui_Button(ctx, label .. "##drop", w - SQ - 6, SQ) then self:browse() end
  local dropped = self:dropped_path()                -- must come right after the drop-zone button
  if dropped then A:set_root(dropped); self.path_buf = nil end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "Re-\nscan##scan", SQ, SQ) then A:update_folder(); self.path_buf = nil end
  self:tip("Re-read the sounds folder (new / removed files, changed lengths) and render again")

  r.ImGui_SetNextItemWidth(ctx, w)
  self.path_buf = self.path_buf or A.cfg.root
  local changed, buf = r.ImGui_InputText(ctx, "##path", self.path_buf, r.ImGui_InputTextFlags_EnterReturnsTrue())
  if changed then self.path_buf = buf; A:set_root(buf); self.path_buf = nil
  else self.path_buf = buf end

  local cfg = A.cfg
  local same = (cfg.default_root == cfg.root)
  if cfg.inherited then r.ImGui_TextColored(ctx, COL_DIM, "Default folder in use (saved into the project with the first render).  ")
  elseif cfg.root ~= "" then r.ImGui_TextColored(ctx, COL_DIM, "Saved with this project.  ") end
  r.ImGui_SameLine(ctx)
  local done = self:disable_if(cfg.root == "" or same)
  if r.ImGui_SmallButton(ctx, "Make this the default") then A:make_default() end
  done()
  self:tip("New projects will start with this folder")
  r.ImGui_SameLine(ctx)
  done = self:disable_if(cfg.default_root == "" or same)
  if r.ImGui_SmallButton(ctx, "Use the default here") then A:use_default(); self.path_buf = nil end
  done()
  self:tip("Switch this project to the default folder (" .. (cfg.default_root ~= "" and cfg.default_root or "none yet") .. ")")

  if A.ngroups > 0 then
    local ids = {}
    for id in pairs(A.groups) do ids[#ids + 1] = id end
    table.sort(ids)
    for i, id in ipairs(ids) do
      local g = A.groups[id]
      if i > 1 then r.ImGui_SameLine(ctx) end
      r.ImGui_TextColored(ctx, #g.sounds > 0 and COL_OK or COL_WARN, string.format("%s (%d)", g.name, #g.sounds))
    end
  elseif A.cfg.root ~= "" then
    r.ImGui_TextColored(ctx, COL_BAD, "no sub-folders found")
  end
end

--------------------------------------------------------------------------------
-- pattern list
--------------------------------------------------------------------------------
function UI:draw_patterns()
  local ctx, A = self.ctx, self.A
  self:heading(string.format("Patterns (%d)  - empty items on the timeline; their notes hold the code", #A.patterns))

  if r.ImGui_Button(ctx, "New pattern") then A:new_pattern() end
  self:tip("Insert an empty pattern item at the edit cursor (or the time selection) on the selected track")
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "Use selected empty item") then A:adopt() end
  self:tip("Turn the selected EMPTY item(s) (Insert > Empty item) into patterns; their notes become the code")
  r.ImGui_SameLine(ctx)
  if A:live() then
    r.ImGui_TextColored(ctx, COL_LIVE, "LIVE")
    r.ImGui_SameLine(ctx)
    if r.ImGui_SmallButton(ctx, "Freeze all") then A:freeze_all() end
    self:tip("Stop rendering automatically; the project is left alone")
    r.ImGui_SameLine(ctx)
    if r.ImGui_SmallButton(ctx, "Render now") then A:render_now() end
  else
    r.ImGui_TextColored(ctx, COL_FROZ, "FROZEN")
    r.ImGui_SameLine(ctx)
    if r.ImGui_SmallButton(ctx, "Go live") then A:go_live() end
    r.ImGui_SameLine(ctx)
    if r.ImGui_SmallButton(ctx, "Render once") then A:render_now() end
  end
  r.ImGui_SameLine(ctx)
  local ch, v = r.ImGui_Checkbox(ctx, "Follow selection", A.cfg.follow)
  if ch then A:set_follow(v) end
  self:tip("Clicking a pattern item on the timeline opens it in the editor")

  if #A.patterns == 0 then
    r.ImGui_TextColored(ctx, COL_DIM, "No pattern yet: click \"New pattern\".")
    return
  end
  local flags = r.ImGui_TableFlags_RowBg() | r.ImGui_TableFlags_ScrollY() | r.ImGui_TableFlags_Resizable()
  local h = math.min(#A.patterns * 22 + 26, 130)
  if r.ImGui_BeginTable(ctx, "patterns", 5, flags, 0, h) then
    r.ImGui_TableSetupScrollFreeze(ctx, 0, 1)
    r.ImGui_TableSetupColumn(ctx, "Name", r.ImGui_TableColumnFlags_WidthStretch(), 2)
    r.ImGui_TableSetupColumn(ctx, "Position", r.ImGui_TableColumnFlags_WidthFixed(), 90)
    r.ImGui_TableSetupColumn(ctx, "Cycles", r.ImGui_TableColumnFlags_WidthFixed(), 55)
    r.ImGui_TableSetupColumn(ctx, "Output", r.ImGui_TableColumnFlags_WidthFixed(), 80)
    r.ImGui_TableSetupColumn(ctx, "Status", r.ImGui_TableColumnFlags_WidthStretch(), 3)
    r.ImGui_TableHeadersRow(ctx)
    for i, p in ipairs(A.patterns) do
      local st = A.status[p.guid] or {}
      r.ImGui_TableNextRow(ctx)
      if A.cur == p.guid then r.ImGui_TableSetBgColor(ctx, r.ImGui_TableBgTarget_RowBg0(), COL_CUR) end
      r.ImGui_TableNextColumn(ctx)
      if r.ImGui_Selectable(ctx, ((p.name ~= "") and p.name or "Pattern") .. "##pat" .. i, A.cur == p.guid) then A:select(p.guid, true) end
      r.ImGui_TableNextColumn(ctx)
      r.ImGui_Text(ctx, fmt_pos(p.pos))
      r.ImGui_TableNextColumn(ctx)
      r.ImGui_Text(ctx, string.format("%.3g", p.cycles))
      r.ImGui_TableNextColumn(ctx)
      r.ImGui_Text(ctx, ({ audio = "audio", midi = "MIDI", both = "audio+MIDI" })[p.mode])
      r.ImGui_TableNextColumn(ctx)
      if st.off then r.ImGui_TextColored(ctx, COL_DIM, "off")
      elseif st.err then r.ImGui_TextColored(ctx, COL_BAD, "error")
      elseif st.warnings and #st.warnings > 0 then r.ImGui_TextColored(ctx, COL_WARN, string.format("%d events, %d warning(s)", st.events or 0, #st.warnings))
      else r.ImGui_TextColored(ctx, COL_OK, string.format("%d events", st.events or 0)) end
    end
    r.ImGui_EndTable(ctx)
  end
end

--------------------------------------------------------------------------------
-- editor for the current pattern
--------------------------------------------------------------------------------
function UI:draw_editor()
  local ctx, A = self.ctx, self.A
  local p = A:current()
  if not p then return end
  self:heading("Pattern: " .. ((p.name ~= "") and p.name or "Pattern"))

  -- name
  if self.name_guid ~= p.guid then self.name_guid, self.name_buf = p.guid, p.name end
  r.ImGui_SetNextItemWidth(ctx, 170)
  local nch, nb = r.ImGui_InputText(ctx, "name", self.name_buf)
  self.name_buf = nb
  if r.ImGui_IsItemDeactivatedAfterEdit(ctx) then A:set_name(p.guid, nb) end
  r.ImGui_SameLine(ctx)

  -- output switches (same code, different results)
  local audio, midi = p.mode ~= "midi", p.mode ~= "audio"
  local c1, a2 = r.ImGui_Checkbox(ctx, "Audio items", audio)
  self:tip("Events with s(\"...\") become items from the sound folders")
  r.ImGui_SameLine(ctx)
  local c2, m2 = r.ImGui_Checkbox(ctx, "MIDI notes", midi)
  self:tip("Events with note(...) / n(...) / a General MIDI drum name (bd sn hh ...) become MIDI notes, one track per $: line")
  if c1 or c2 then
    if c1 then audio = a2 end
    if c2 then midi = m2 end
    if not audio and not midi then audio = true end
    A:set_mode(p.guid, audio, midi)
  end
  r.ImGui_SameLine(ctx)
  local on = not p.off
  local c3, on2 = r.ImGui_Checkbox(ctx, "On", on)
  if c3 then A:set_off(p.guid, not on2) end
  self:tip("Off: the pattern's generated items are removed")

  -- cycle length
  if self.cyc_guid ~= p.guid then self.cyc_guid, self.cyc_buf = p.guid, p.cycle_qn end
  r.ImGui_SetNextItemWidth(ctx, 90)
  local _, cv = r.ImGui_InputDouble(ctx, "beats per cycle", self.cyc_buf, 0, 0, "%.2f")
  self.cyc_buf = cv
  if r.ImGui_IsItemDeactivatedAfterEdit(ctx) then A:set_cycle(p.guid, cv) end
  self:tip("Length of ONE cycle in quarter notes (4 = a bar of 4/4). The item is " .. string.format("%.3g", p.cycles) .. " cycles long.")
  r.ImGui_SameLine(ctx)
  if r.ImGui_SmallButton(ctx, "Freeze") then self.confirm_freeze = true end
  self:tip("Keep everything this pattern generated as ordinary items and switch the pattern off")
  r.ImGui_SameLine(ctx)
  if r.ImGui_SmallButton(ctx, "Delete pattern") then self.confirm_delete = true end
  if self.confirm_freeze then
    self:wrapped(COL_WARN, "Freeze: generated items become ordinary items (never touched again); the pattern is switched off.")
    if r.ImGui_Button(ctx, "Yes, freeze") then A:freeze_pattern(p.guid); self.confirm_freeze = false end
    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, "Cancel##freeze") then self.confirm_freeze = false end
  end
  if self.confirm_delete then
    self:wrapped(COL_WARN, "Delete the pattern item and everything it generated?")
    if r.ImGui_Button(ctx, "Yes, delete") then A:delete_pattern(p.guid); self.confirm_delete = false end
    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, "Cancel##delete") then self.confirm_delete = false end
  end

  -- examples
  r.ImGui_TextColored(ctx, COL_DIM, "examples:")
  for _, ex in ipairs(UI.EXAMPLES) do
    r.ImGui_SameLine(ctx)
    if r.ImGui_SmallButton(ctx, ex[1] .. "##ex") then A:set_edit_code(ex[2]) end
  end
  r.ImGui_SameLine(ctx)
  r.ImGui_TextColored(ctx, COL_DIM, "  (replaces the code)")

  -- the editor
  local w, avail_h = r.ImGui_GetContentRegionAvail(ctx)
  local h = math.max(140, (avail_h or 300) - 120)
  local flags = r.ImGui_InputTextFlags_AllowTabInput()
  local changed, buf = r.ImGui_InputTextMultiline(ctx, "##code", A.edit.code, w, h, flags)
  if changed then A:set_edit_code(buf) end

  -- result of the evaluation
  local st = A.status[p.guid] or {}
  if st.err then
    self:wrapped(COL_BAD, st.err)
  else
    if st.warnings then
      for _, wmsg in ipairs(st.warnings) do self:wrapped(COL_WARN, wmsg) end
    end
    if not st.off and #(st.warnings or {}) == 0 then
      r.ImGui_TextColored(ctx, COL_DIM, string.format("%d events in %.3g cycles.", st.events or 0, p.cycles))
    end
  end
end

--------------------------------------------------------------------------------
-- frame
--------------------------------------------------------------------------------
function UI:draw()
  local A = self.A
  local ctx = self.ctx
  self:draw_folder()
  self:draw_patterns()
  self:draw_editor()

  local info = A.info or { tracks = 0 }
  if (info.tracks or 0) > 0 then
    r.ImGui_TextColored(ctx, COL_DIM, string.format("Managed: %d tracks (GINGERSNAP folder)", info.tracks))
    r.ImGui_SameLine(ctx)
    if r.ImGui_SmallButton(ctx, "Show") then A:show_root() end
    r.ImGui_SameLine(ctx)
    if r.ImGui_SmallButton(ctx, "Detach...") then self.confirm_detach = true end
    self:tip("Stop managing everything for good: tracks and items stay, as ordinary ones")
  end
  if self.confirm_detach then
    self:wrapped(COL_WARN, "Detach: all GINGERSNAP tracks and items become ordinary. Patterns are switched off.")
    if r.ImGui_Button(ctx, "Yes, detach") then A:detach(); self.confirm_detach = false end
    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, "Cancel##detach") then self.confirm_detach = false end
  end
  if A.err then self:wrapped(COL_BAD, A.err)
  elseif A.msg then self:wrapped(COL_DIM, A.msg) end
end

-- returns false when the window has been closed
function UI:frame()
  local ctx = self.ctx
  r.ImGui_SetNextWindowSize(ctx, 780, 860, r.ImGui_Cond_FirstUseEver())
  local visible, open = r.ImGui_Begin(ctx, self.title, true)
  if visible then
    local ok, e = pcall(self.draw, self)
    if not ok then self.A.err = "UI error: " .. tostring(e) end
    r.ImGui_End(ctx)
  end
  return open
end

return UI
