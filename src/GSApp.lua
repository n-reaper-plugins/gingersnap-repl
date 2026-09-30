-- GSApp.lua
-- State + main tick. No drawing in here. The UI only reads the fields and calls the methods below.
--
--   live   : every change of a pattern (code, position, length, settings), of the tempo map or of the sound
--            folders is rendered into the project (after DEBOUNCE seconds of quiet)
--   frozen : nothing is touched any more (button: Render once)

local r = reaper
local Core = require("GSCore")
local RA = require("GSReaper")
local Strudel = require("strudel")

local App = {}
App.__index = App

local DEBOUNCE = 0.35            -- seconds after the last project change before rendering
local CODE_IDLE = 0.4            -- seconds after the last keystroke before the code is written into the item
local DEFAULT_CODE = '// 1 cycle = 1 bar. Edit me - the timeline follows.\n$: s("bd*2, ~ sn, hh*4")\n'

function App.new()
  local self = setmetatable({}, App)
  self.proj = r.EnumProjects(-1)
  self.cfg = RA.load_cfg()
  self.groups, self.ngroups, self.gsig = {}, 0, ""
  self.patterns = {}            -- pattern items, timeline order (RA.read_patterns)
  self.info = { tracks = 0 }
  self.evals = {}               -- code -> { res=, err= }
  self.plans = {}               -- guid -> { insig=, plan=, err= }
  self.status = {}              -- guid -> { err=, warnings={}, events=n }
  self.comp = nil
  self.cur = nil                -- guid of the pattern shown in the editor
  self.edit = { guid = nil, code = "", t = nil }
  self.last_count = -1
  self.last_sig = RA.load_sig()
  self.last_sel = nil
  self.pending_t, self.force = nil, false
  self.msg, self.err = nil, nil
  if self.cfg.root ~= "" then self:rescan() end
  return self
end

function App:save() RA.save_cfg(self.cfg) end
function App:live() return self.cfg.mode == "live" end

--------------------------------------------------------------------------------
-- sound folder
--------------------------------------------------------------------------------
function App:rescan()
  RA.clear_len_cache()
  self.groups, self.ngroups = RA.scan(self.cfg.root)
  self.gsig = Core.groups_sig(self.groups)
  self.plans = {}                          -- lengths / files may have changed
  self.last_count = -1
  if self.cfg.root == "" then self.msg = nil
  elseif self.ngroups == 0 then self.err = "No sub-folders found in " .. self.cfg.root .. " (one sub-folder per sound: root/bd/*.wav)"; return
  end
  self.err = nil
end

function App:update_folder()
  self:rescan()
  self.last_sig = nil
  if self.err == nil then self.msg = string.format("Folder re-read: %d sounds.", self.ngroups) end
end

function App:set_root(path)
  local p = RA.resolve_root(path)
  if p == "" then return end
  self.cfg.root = p
  self.cfg.inherited = false
  if self.cfg.default_root == "" then self.cfg.default_root = p end
  self:rescan()
  self:save()
end
function App:make_default()
  if self.cfg.root == "" then return end
  self.cfg.default_root = self.cfg.root
  RA.save_prefs(self.cfg)
  self.msg = "Default folder for new projects: " .. self.cfg.root
end
function App:use_default()
  if self.cfg.default_root == "" then return end
  self:set_root(self.cfg.default_root)
end

function App:freeze_all() self.cfg.mode = "frozen"; self.pending_t = nil; self:save(); self.msg = "Frozen: the project is left alone." end
function App:go_live() self.cfg.mode = "live"; self.last_sig = nil; self.last_count = -1; self:save(); self.msg = nil end
function App:render_now() self.force = true end
function App:set_follow(on) self.cfg.follow = on and true or false; RA.save_prefs(self.cfg) end
function App:show_root() RA.show_root() end

function App:detach()
  local st, err = RA.detach()
  self.cfg.mode = "frozen"; self.pending_t = nil; self.last_sig = nil; RA.save_sig(nil); self:save()
  if not st then self.err = tostring(err); return end
  self.err = nil
  self.msg = string.format("Detached %d tracks: they are ordinary tracks now. Patterns are switched off.", st.tracks)
end

--------------------------------------------------------------------------------
-- patterns
--------------------------------------------------------------------------------
function App:pattern(guid)
  for _, p in ipairs(self.patterns) do if p.guid == guid then return p end end
end
function App:current() return self.cur and self:pattern(self.cur) or nil end

function App:default_code()
  -- use real folder names when there are some
  local ids = {}
  for id in pairs(self.groups) do ids[#ids + 1] = id end
  table.sort(ids)
  if #ids >= 2 then
    local a, b = self.groups[ids[1]].name, self.groups[ids[2]].name
    return string.format('// 1 cycle = 1 bar. Edit me - the timeline follows.\n$: s("%s*2, ~ %s")\n', a, b)
  elseif #ids == 1 then
    return string.format('// 1 cycle = 1 bar. Edit me - the timeline follows.\n$: s("%s*4")\n', self.groups[ids[1]].name)
  end
  return DEFAULT_CODE
end

function App:select(guid, move_cursor)
  local p = self:pattern(guid)
  if not p then return end
  self:commit_code()
  self.cur = guid
  self.edit = { guid = guid, code = p.code, t = nil }
  RA.select_pattern(p.item, move_cursor)
  self.last_sel = guid
end

function App:new_pattern()
  local it, err = RA.new_pattern(self:default_code(), self.patterns, "audio")
  if not it then self.err = "Could not create the pattern item: " .. tostring(err); return end
  self.err = nil
  self:refresh()
  for _, p in ipairs(self.patterns) do
    if p.item == it then self:select(p.guid, false) break end
  end
  self.msg = "Pattern item created. Move / resize it on the timeline; it is rendered while you edit."
end

function App:adopt()
  local n = RA.adopt_selected(self:default_code(), self.patterns)
  if n == 0 then self.err = "Select an EMPTY item first (Insert > Empty item). Its notes become the code."; return end
  self.err = nil
  self:refresh()
  self.msg = n .. " item(s) turned into patterns."
end

-- the editor buffer -> the item's notes (debounced from tick)
function App:set_edit_code(code)
  if code == self.edit.code then return end
  self.edit.code = code
  self.edit.t = r.time_precise()
end
function App:commit_code()
  local e = self.edit
  if e.t and e.guid then
    local p = self:pattern(e.guid)
    if p then RA.set_code(p.item, e.code); p.code = e.code end
    e.t = nil
    self.last_count = -1
  end
end

local function on_pattern(self, guid, fn)
  local p = self:pattern(guid)
  if p and RA.valid_item(p.item) then fn(p); self.last_count = -1 end
end
function App:set_mode(guid, audio, midi)
  local mode = (audio and midi) and "both" or (midi and "midi" or "audio")
  on_pattern(self, guid, function(p) RA.set_mode(p.item, mode) end)
end
function App:set_cycle(guid, qn)
  qn = tonumber(qn) or RA.DEFAULT_CYCLE_QN
  qn = math.max(0.25, math.min(64, qn))
  on_pattern(self, guid, function(p) RA.set_cycle(p.item, qn) end)
end
function App:set_name(guid, name)
  name = tostring(name or ""):gsub("[\r\n]", " ")
  if name == "" then name = "Pattern" end
  on_pattern(self, guid, function(p) RA.set_name(p.item, name) end)
end
function App:set_off(guid, off) on_pattern(self, guid, function(p) RA.set_off(p.item, off) end) end
function App:delete_pattern(guid)
  local p = self:pattern(guid)
  if not p then return end
  RA.delete_pattern(p.item)
  if self.cur == guid then self.cur = nil; self.edit = { guid = nil, code = "" } end
  self.last_count = -1
  self.msg = "Pattern deleted; its generated items are removed on the next render."
end
function App:freeze_pattern(guid)
  local p = self:pattern(guid)
  if not p then return end
  self:commit_code()
  local n = RA.freeze_pattern(p)
  self.last_count = -1
  self.pending_t = nil
  self.last_sig = nil
  self.msg = string.format("Frozen %d items: they are ordinary items now, and the pattern is switched off.", n)
end

--------------------------------------------------------------------------------
-- evaluation and planning (cached: only patterns whose inputs changed are recomputed)
--------------------------------------------------------------------------------
function App:evaluate(code)
  local e = self.evals[code]
  if not e then
    local res, err = Strudel.run(code)
    e = { res = res, err = err }
    local n = 0
    for _ in pairs(self.evals) do n = n + 1 end
    if n > 200 then self.evals = {} end
    self.evals[code] = e
  end
  return e
end

function App:plan_for(p, tempo_fp)
  local insig = Core.hex(table.concat({ p.code, p.mode, tostring(p.cycle_qn), Core.fmt(p.pos), Core.fmt(p.len), tempo_fp, self.gsig, self.cfg.root }, "\1"))
  local c = self.plans[p.guid]
  if c and c.insig == insig then return c end
  c = { insig = insig }
  local e = self:evaluate(p.code)
  if not e.res then
    c.err = e.err or "cannot evaluate"
  else
    local qn0 = RA.qn_of(p.pos)
    local plan, err = Core.plan_pattern({
      guid = p.guid, name = p.name, layers = e.res.layers, mode = p.mode, groups = self.groups,
      cycles = p.cycles, lenfn = RA.file_len,
      timefn = function(cyc) return RA.time_of_qn(qn0 + cyc * p.cycle_qn) end,
    })
    if not plan then c.err = err
    else
      c.plan, c.nlayers = plan, #e.res.layers
      c.warnings = {}
      for _, w in ipairs(e.res.warnings) do c.warnings[#c.warnings + 1] = w end
      for _, w in ipairs(plan.warnings) do c.warnings[#c.warnings + 1] = w end
      if #e.res.layers == 0 then c.warnings[#c.warnings + 1] = "no pattern found - start a line with  $:  (e.g.  $: s(\"bd sn\"))" end
    end
  end
  self.plans[p.guid] = c
  return c
end

-- reads the pattern items and recomputes the wanted result
function App:refresh()
  self.patterns = RA.read_patterns()
  local tempo = RA.tempo_fp()
  local plans, status, live_guid = {}, {}, {}
  for _, p in ipairs(self.patterns) do
    live_guid[p.guid] = true
    if p.name == "" then p.name = "Pattern" end
    if p.off then
      status[p.guid] = { off = true }
    else
      local c = self:plan_for(p, tempo)
      status[p.guid] = { err = c.err, warnings = c.warnings or {}, events = c.plan and c.plan.events or 0 }
      if c.plan then plans[#plans + 1] = { pattern = p, plan = c.plan, nlayers = c.nlayers } end
    end
  end
  for g in pairs(self.plans) do if not live_guid[g] then self.plans[g] = nil end end
  self.status = status
  -- an error in any pattern pauses rendering: its old output stays exactly as it is until the code works again
  self.blocked = nil
  for _, p in ipairs(self.patterns) do
    local st = status[p.guid]
    if st and st.err then self.blocked = (p.name ~= "" and p.name or "Pattern") .. ": " .. st.err; break end
  end
  self.comp = Core.compose(plans)
  self.sig = self.comp.sig .. "|" .. tostring(#self.patterns)
  -- keep the editor on a pattern that still exists
  if self.cur and not live_guid[self.cur] then self.cur = nil; self.edit = { guid = nil, code = "" } end
  if not self.cur and self.patterns[1] then
    self.cur = self.patterns[1].guid
    self.edit = { guid = self.cur, code = self.patterns[1].code, t = nil }
  end
  -- external edits (item notes changed in REAPER) show up in the editor unless we are typing
  local cp = self:current()
  if cp and not self.edit.t and cp.code ~= self.edit.code then self.edit.code = cp.code end
  if self.sig ~= self.last_sig then self.pending_t = r.time_precise() end
end

--------------------------------------------------------------------------------
-- render
--------------------------------------------------------------------------------
function App:run_sync()
  self.force = false
  self.pending_t = nil
  self:commit_code()
  if not self.comp then self:refresh() end
  if self.blocked then
    self.msg = "Rendering paused - fix the error first (the previous result stays in the project)."
    return
  end
  local st, err = RA.sync(self.comp)
  if not st then self.err = "Render failed: " .. tostring(err); return end
  self.err = nil
  self.last_stats = st
  local bad = 0
  for _ in pairs(st.bad) do bad = bad + 1 end
  if bad > 0 then self.err = bad .. " sound file(s) could not be loaded." end
  self.last_sig = self.sig
  RA.save_sig(self.sig)
  if self.cfg.inherited then self.cfg.inherited = false; self:save() end
  self.last_count = r.GetProjectStateChangeCount(0)       -- our own edits are not a reason to render again
  self.info = RA.managed_info()
  self.msg = string.format("Rendered: +%d audio items, %d MIDI items, ~%d changed, -%d removed; +%d/-%d tracks.",
    st.items_new, st.midi_new, st.items_upd, st.items_del, st.tracks_new, st.tracks_del)
end

-- another project tab became active: settings are per project
function App:switch_project(proj)
  self.proj = proj
  self.cfg = RA.load_cfg()
  self.last_sig = RA.load_sig()
  self.pending_t, self.force = nil, false
  self.msg, self.err = nil, nil
  self.cur, self.edit, self.plans, self.patterns, self.comp = nil, { guid = nil, code = "" }, {}, {}, nil
  self:rescan()
end

function App:tick()
  local now = r.time_precise()
  local proj = r.EnumProjects(-1)
  if proj ~= self.proj then self:switch_project(proj) end

  -- typed code -> item notes
  if self.edit.t and now - self.edit.t >= CODE_IDLE then self:commit_code() end

  local cnt = r.GetProjectStateChangeCount(0)
  if cnt ~= self.last_count then
    self.last_count = cnt
    self:refresh()
    if self.sig == self.last_sig then self.pending_t = nil end
  end

  -- follow the REAPER selection: clicking a pattern item on the timeline opens it in the editor
  if self.cfg.follow and not self.edit.t then
    local sel
    for _, p in ipairs(self.patterns) do if p.selected then sel = p.guid; break end end
    if sel ~= self.last_sel then
      self.last_sel = sel
      if sel and sel ~= self.cur then
        self.cur = sel
        local p = self:pattern(sel)
        self.edit = { guid = sel, code = p and p.code or "", t = nil }
      end
    end
  end

  if self.force then
    self:run_sync()
  elseif self:live() and self.pending_t and now - self.pending_t >= DEBOUNCE then
    self:run_sync()
  end
end

return App
