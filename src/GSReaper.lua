-- GSReaper.lua
-- Everything that touches REAPER lives here. The logic (what should exist) is in GSCore.
--
-- PATTERN ITEMS   an EMPTY item on the timeline. Its notes (P_NOTES) hold the code; P_EXT tags hold the settings.
--                 Move / resize / copy it like any item: the generated content follows.
-- MANAGED TRACKS  root "GINGERSNAP" -> collapsed group folders (one per sound folder, plus "MIDI") -> one track per
--                 sound file (duplicate "voice" tracks where the same sound overlaps) / per pattern layer (MIDI).
-- GENERATED ITEMS tagged with GS_KEY (identity), GS_OWN (owner pattern GUID) and GS_SIG (what was written).
--                 An item is only rewritten when its wanted state changed, so hand edits survive until then.

local r = reaper
local Core = require("GSCore")

local RA = {}
local SECTION = "Gingersnap"

-- tags
local E_ROLE, E_ID = "P_EXT:GS_ROLE", "P_EXT:GS_ID"                       -- tracks
local E_KEY, E_OWN, E_SIG = "P_EXT:GS_KEY", "P_EXT:GS_OWN", "P_EXT:GS_SIG" -- generated items
local E_REV = "P_EXT:GS_REV"                                                  -- generated audio item: currently reversed by us
local E_PAT, E_NAME, E_MODE, E_CYC, E_OFF = "P_EXT:GS_PAT", "P_EXT:GS_NAME", "P_EXT:GS_MODE", "P_EXT:GS_CYC", "P_EXT:GS_OFF"

RA.DEFAULT_CYCLE_QN = 4          -- one cycle = 4 quarter notes = one bar of 4/4
RA.DEFAULT_CYCLES = 4            -- new pattern items are 4 cycles long

--------------------------------------------------------------------------------
-- small helpers
--------------------------------------------------------------------------------
local function tget(tr, k) local ok, v = r.GetSetMediaTrackInfo_String(tr, k, "", false); return ok and v or "" end
local function tset(tr, k, v) r.GetSetMediaTrackInfo_String(tr, k, v, true) end
local function iget(it, k) local ok, v = r.GetSetMediaItemInfo_String(it, k, "", false); return ok and v or "" end
local function iset(it, k, v) r.GetSetMediaItemInfo_String(it, k, v, true) end
local function tidx0(tr) return math.floor(r.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER") + 0.5) - 1 end
local fmt = Core.fmt

local function set_track_val(tr, k, v)
  if r.GetMediaTrackInfo_Value(tr, k) ~= v then r.SetMediaTrackInfo_Value(tr, k, v) end
end
local function set_name(tr, name)
  local ok, cur = r.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
  if not ok or cur ~= name then r.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true) end
end
local function new_track(role, id, name)
  local idx = r.CountTracks(0)
  r.InsertTrackAtIndex(idx, false)
  local tr = r.GetTrack(0, idx)
  tset(tr, E_ROLE, role); tset(tr, E_ID, id)
  set_name(tr, name)
  return tr
end

--------------------------------------------------------------------------------
-- settings
--   PROJECT (saved in the .rpp): root (sounds folder), mode (live / frozen), sig (what was last rendered)
--   GLOBAL  (reaper-extstate.ini): default_root, follow
-- Values are only written when they differ from what is stored, so opening the window does not dirty the project.
--------------------------------------------------------------------------------
local written = {}
local function pset(k, v)
  v = v or ""
  if written[k] ~= v then r.SetProjExtState(0, SECTION, k, v); written[k] = v end
end
local function gset(k, v)
  if r.GetExtState(SECTION, k) ~= v then r.SetExtState(SECTION, k, v, true) end
end

function RA.load_cfg()
  written = {}
  local function pget(k) local _, v = r.GetProjExtState(0, SECTION, k); written[k] = v; return v end
  local cfg = { root = pget("root"), mode = pget("mode") }
  cfg.follow = (r.GetExtState(SECTION, "follow") ~= "0")
  cfg.aliases = (r.GetExtState(SECTION, "aliases") == "1")                -- standard drum aliases (sd rim lt mt ht cr rd cb perc): off by default
  cfg.root_note = tonumber(r.GetExtState(SECTION, "root_note")) or Core.DEFAULT_ROOT_NOTE
  cfg.default_root = r.GetExtState(SECTION, "default_root")
  cfg.inherited = false
  if cfg.root == "" and cfg.default_root ~= "" then cfg.root = cfg.default_root; cfg.inherited = true end
  cfg.mode = (cfg.mode == "frozen") and "frozen" or "live"
  return cfg
end
function RA.save_cfg(cfg)
  if not cfg.inherited then pset("root", cfg.root) end
  pset("mode", cfg.mode)
  RA.save_prefs(cfg)
end
function RA.save_prefs(cfg)
  gset("follow", cfg.follow and "1" or "0")
  gset("aliases", cfg.aliases and "1" or "0")
  gset("root_note", tostring(cfg.root_note or Core.DEFAULT_ROOT_NOTE))
  if cfg.default_root and cfg.default_root ~= "" then gset("default_root", cfg.default_root) end
end
function RA.load_sig() local _, v = r.GetProjExtState(0, SECTION, "sig"); written.sig = v; return v ~= "" and v or nil end
function RA.save_sig(s) pset("sig", s or "") end

--------------------------------------------------------------------------------
-- sound folders  root/<sound name>/<files>      (one level, like PrototypeSequence)
--------------------------------------------------------------------------------
function RA.clean_path(p)
  p = tostring(p or ""):gsub("^%s+", ""):gsub("%s+$", "")
  p = p:gsub('^"(.*)"$', "%1")
  if #p > 1 then p = p:gsub("[/\\]+$", "") end
  return p
end
local function is_dir(p)
  if r.EnumerateSubdirectories(p, 0) or r.EnumerateFiles(p, 0) then return true end
  if r.file_exists and r.file_exists(p) then return false end
  return not Core.is_audio(p)
end
function RA.resolve_root(p)
  p = RA.clean_path(p)
  if p == "" then return "" end
  if is_dir(p) then return p end
  return (p:gsub("[/\\][^/\\]*$", ""))
end

function RA.scan(root)
  local groups, n = {}, 0
  if not root or root == "" then return groups, 0 end
  r.EnumerateSubdirectories(root, -1)
  local i = 0
  while true do
    local d = r.EnumerateSubdirectories(root, i)
    if not d then break end
    i = i + 1
    if d:sub(1, 1) ~= "." then
      local id = Core.norm(d)
      if id ~= "" and not groups[id] then
        local path = root .. "/" .. d
        r.EnumerateFiles(path, -1)
        local sounds, j = {}, 0
        while true do
          local f = r.EnumerateFiles(path, j)
          if not f then break end
          j = j + 1
          if Core.is_audio(f) and f:sub(1, 1) ~= "." then
            sounds[#sounds + 1] = { file = f, name = Core.strip_ext(f), path = path .. "/" .. f }
          end
        end
        table.sort(sounds, function(a, b) return a.file:lower() < b.file:lower() end)
        groups[id] = { name = d, sounds = sounds, path = path }
        n = n + 1
      end
    end
  end
  return groups, n
end

local len_cache = {}
function RA.clear_len_cache() len_cache = {} end
function RA.file_len(path)
  local v = len_cache[path]
  if v == nil then
    v = false
    local src = r.PCM_Source_CreateFromFile(path)
    if src then
      local len, is_qn = r.GetMediaSourceLength(src)
      if len and not is_qn and len > 0 then v = len end
      if r.PCM_Source_Destroy then r.PCM_Source_Destroy(src) end
    end
    len_cache[path] = v
  end
  return v or nil
end

--------------------------------------------------------------------------------
-- time: cycles <-> quarter notes <-> seconds (tempo map aware)
--------------------------------------------------------------------------------
function RA.qn_of(t) return r.TimeMap2_timeToQN(0, t) end
function RA.time_of_qn(q) return r.TimeMap2_QNToTime(0, q) end

-- changes whenever the tempo map changes (part of the signature of every pattern)
function RA.tempo_fp()
  local parts = { string.format("%.4f", r.Master_GetTempo and r.Master_GetTempo() or 120) }
  local n = r.CountTempoTimeSigMarkers and r.CountTempoTimeSigMarkers(0) or 0
  for i = 0, n - 1 do
    local _, t, _, _, bpm, num, den, lin = r.GetTempoTimeSigMarker(0, i)
    parts[#parts + 1] = string.format("%.5f/%.4f/%s/%s/%s", t or 0, bpm or 0, tostring(num), tostring(den), tostring(lin))
  end
  return table.concat(parts, ";")
end

--------------------------------------------------------------------------------
-- pattern items
--------------------------------------------------------------------------------
local function valid_item(it) return it and (not r.ValidatePtr2 or r.ValidatePtr2(0, it, "MediaItem*")) end
RA.valid_item = valid_item

local function read_pattern(it)
  local guid = iget(it, "GUID")
  local cyc = tonumber(iget(it, E_CYC))
  if not cyc or cyc <= 0 then cyc = RA.DEFAULT_CYCLE_QN end
  local mode = iget(it, E_MODE)
  if mode ~= "midi" and mode ~= "both" then mode = "audio" end
  local pos, len = r.GetMediaItemInfo_Value(it, "D_POSITION"), r.GetMediaItemInfo_Value(it, "D_LENGTH")
  local qn0 = RA.qn_of(pos)
  return {
    item = it, guid = guid, code = iget(it, "P_NOTES"), name = iget(it, E_NAME), mode = mode, cycle_qn = cyc,
    off = iget(it, E_OFF) == "1", pos = pos, len = len, selected = r.IsMediaItemSelected(it),
    cycles = (RA.qn_of(pos + len) - qn0) / cyc,
    track = r.GetMediaItemTrack(it),
  }
end

-- all pattern items of the project, in timeline order
function RA.read_patterns()
  local out = {}
  for i = 0, r.CountMediaItems(0) - 1 do
    local it = r.GetMediaItem(0, i)
    if r.CountTakes(it) == 0 and iget(it, E_PAT) == "1" then out[#out + 1] = read_pattern(it) end
  end
  table.sort(out, function(a, b)
    if a.pos ~= b.pos then return a.pos < b.pos end
    return a.guid < b.guid
  end)
  return out
end

local function tag_pattern(it, name, mode, cyc)
  iset(it, E_PAT, "1")
  iset(it, E_NAME, name)
  iset(it, E_MODE, mode or "audio")
  iset(it, E_CYC, tostring(cyc or RA.DEFAULT_CYCLE_QN))
  local col = r.ColorToNative and r.ColorToNative(120, 200, 140) or 0
  r.SetMediaItemInfo_Value(it, "I_CUSTOMCOLOR", col | 0x1000000)
end

local function pattern_track()
  local tr = r.GetSelectedTrack(0, 0)
  if tr and tget(tr, E_ROLE) == "" then return tr end
  for i = 0, r.CountTracks(0) - 1 do              -- an existing plain "Patterns" track
    local t = r.GetTrack(0, i)
    local ok, nm = r.GetSetMediaTrackInfo_String(t, "P_NAME", "", false)
    if ok and nm == "Patterns" and tget(t, E_ROLE) == "" then return t end
  end
  r.InsertTrackAtIndex(0, true)
  tr = r.GetTrack(0, 0)
  set_name(tr, "Patterns")
  return tr
end

local function next_name(existing)
  local n = 0
  for _, p in ipairs(existing or {}) do
    local k = tonumber((p.name or ""):match("^Pattern (%d+)$"))
    if k and k > n then n = k end
  end
  return "Pattern " .. (n + 1)
end

-- creates an empty item at the edit cursor (or the start of the time selection) and turns it into a pattern
function RA.new_pattern(code, existing, mode)
  local ok, res = pcall(function()
    local tr = pattern_track()
    local s, e = r.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
    local pos = (e and s and e > s) and s or r.GetCursorPosition()
    local qn0 = RA.qn_of(pos)
    local len = RA.time_of_qn(qn0 + RA.DEFAULT_CYCLES * RA.DEFAULT_CYCLE_QN) - pos
    if e and s and e > s then len = e - s end
    local it = r.AddMediaItemToTrack(tr)
    r.SetMediaItemInfo_Value(it, "D_POSITION", pos)
    r.SetMediaItemInfo_Value(it, "D_LENGTH", len)
    iset(it, "P_NOTES", code)
    tag_pattern(it, next_name(existing), mode)
    r.UpdateItemInProject(it)
    return it
  end)
  if not ok then return nil, res end
  return res
end

-- turns the selected EMPTY items into patterns (their notes become the code)
function RA.adopt_selected(default_code, existing)
  local n = 0
  local sel = {}
  for i = 0, r.CountSelectedMediaItems(0) - 1 do sel[#sel + 1] = r.GetSelectedMediaItem(0, i) end
  for _, it in ipairs(sel) do
    if r.CountTakes(it) == 0 and iget(it, E_PAT) ~= "1" and iget(it, E_KEY) == "" then
      if iget(it, "P_NOTES") == "" then iset(it, "P_NOTES", default_code) end
      tag_pattern(it, next_name(existing), "audio")
      existing = existing or {}
      existing[#existing + 1] = { name = iget(it, E_NAME) }
      n = n + 1
    end
  end
  return n
end

function RA.set_code(it, code) if valid_item(it) and iget(it, "P_NOTES") ~= code then iset(it, "P_NOTES", code) end end
function RA.set_name(it, name) if valid_item(it) then iset(it, E_NAME, name) end end
function RA.set_mode(it, mode) if valid_item(it) then iset(it, E_MODE, mode) end end
function RA.set_cycle(it, qn) if valid_item(it) then iset(it, E_CYC, tostring(qn)) end end
function RA.set_off(it, off) if valid_item(it) then iset(it, E_OFF, off and "1" or "") end end

function RA.select_pattern(it, move_cursor)
  if not valid_item(it) then return end
  for i = r.CountSelectedMediaItems(0) - 1, 0, -1 do r.SetMediaItemSelected(r.GetSelectedMediaItem(0, i), false) end
  r.SetMediaItemSelected(it, true)
  if move_cursor then r.SetEditCurPos(r.GetMediaItemInfo_Value(it, "D_POSITION"), true, false) end
  r.UpdateArrange()
end

function RA.delete_pattern(it)
  if not valid_item(it) then return end
  r.DeleteTrackMediaItem(r.GetMediaItemTrack(it), it)
  r.UpdateArrange()
end

--------------------------------------------------------------------------------
-- track bookkeeping
--------------------------------------------------------------------------------
function RA.index_tracks()
  local ex = { list = {}, groups = {}, snds = {}, midis = {} }
  for i = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    local role = tget(tr, E_ROLE)
    if role ~= "" then
      local id = tget(tr, E_ID)
      local rec = { tr = tr, role = role, id = id }
      ex.list[#ex.list + 1] = rec
      if role == "root" then
        if ex.root then rec.dup = true else ex.root = tr end
      elseif role == "group" then
        if ex.groups[id] then rec.dup = true else ex.groups[id] = tr end
      elseif role == "snd" then
        if ex.snds[id] then rec.dup = true else ex.snds[id] = tr end
      elseif role == "midi" then
        if ex.midis[id] then rec.dup = true else ex.midis[id] = tr end
      end
    end
  end
  return ex
end

local function save_selection()
  local s = {}
  for i = 0, r.CountSelectedTracks(0) - 1 do s[r.GetSelectedTrack(0, i)] = true end
  local items = {}
  for i = 0, r.CountSelectedMediaItems(0) - 1 do items[#items + 1] = r.GetSelectedMediaItem(0, i) end
  return s, items
end
local function restore_selection(s, items)
  for i = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    r.SetTrackSelected(tr, s[tr] == true)
  end
  for i = r.CountSelectedMediaItems(0) - 1, 0, -1 do r.SetMediaItemSelected(r.GetSelectedMediaItem(0, i), false) end
  for _, it in ipairs(items) do if valid_item(it) then r.SetMediaItemSelected(it, true) end end
end

local function order_tracks(D)
  for _ = 1, 4 do
    local moved = false
    for i = 2, #D do
      local want = tidx0(D[1]) + i - 1
      local cur = tidx0(D[i])
      if cur ~= want then
        r.SetOnlyTrackSelected(D[i])
        r.ReorderSelectedTracks((cur > want) and want or (want + 1), 0)
        moved = true
      end
    end
    if not moved then break end
  end
end

function RA.apply_depths(root, layout)
  if #layout == 0 then set_track_val(root, "I_FOLDERDEPTH", 0); return end
  set_track_val(root, "I_FOLDERDEPTH", 1)
  for gi, L in ipairs(layout) do
    set_track_val(L.track, "I_FOLDERDEPTH", 1)
    set_track_val(L.track, "I_FOLDERCOMPACT", 2)
    for ki, kt in ipairs(L.kids) do
      local d = 0
      if ki == #L.kids then d = (gi == #layout) and -2 or -1 end
      set_track_val(kt, "I_FOLDERDEPTH", d)
    end
  end
end

local function untag_item(it)
  for _, k in ipairs({ E_KEY, E_OWN, E_SIG, E_REV }) do if iget(it, k) ~= "" then iset(it, k, "") end end
end
local function release_track(tr)
  for i = 0, r.CountTrackMediaItems(tr) - 1 do untag_item(r.GetTrackMediaItem(tr, i)) end
  tset(tr, E_ROLE, ""); tset(tr, E_ID, "")
  set_track_val(tr, "I_FOLDERDEPTH", 0)
end

local function with_undo(label, fn)
  local sel, items = save_selection()
  r.PreventUIRefresh(1)
  r.Undo_BeginBlock2(0)
  local ok, res = pcall(fn)
  restore_selection(sel, items)
  r.PreventUIRefresh(-1)
  r.TrackList_AdjustWindows(false)
  r.UpdateArrange()
  r.Undo_EndBlock2(0, label, -1)
  if not ok then return nil, res end
  return res
end

--------------------------------------------------------------------------------
-- SYNC: make the GINGERSNAP tracks / items match the composed plan
--------------------------------------------------------------------------------
-- reverse = REAPER's own "Item properties: Toggle take reverse" (action 41051); it acts on the selected items.
-- NOT verified in real REAPER (offline tests only see the fake). The reversed state is remembered in a tag, and the
-- item is turned back before every rewrite so that start offset / length mean the same thing as for a normal item.
local TOGGLE_TAKE_REVERSE = 41051
local function set_reverse(it, want)
  local have = iget(it, E_REV) == "1"
  if have == want then return end
  for i = r.CountSelectedMediaItems(0) - 1, 0, -1 do r.SetMediaItemSelected(r.GetSelectedMediaItem(0, i), false) end
  r.SetMediaItemSelected(it, true)
  r.Main_OnCommand(TOGGLE_TAKE_REVERSE, 0)
  r.SetMediaItemSelected(it, false)
  iset(it, E_REV, want and "1" or "")
end

local function apply_audio_item(it, wi)
  set_reverse(it, false)
  r.SetMediaItemInfo_Value(it, "D_POSITION", wi.pos)
  r.SetMediaItemInfo_Value(it, "D_LENGTH", wi.len)
  r.SetMediaItemInfo_Value(it, "D_VOL", wi.vol)
  r.SetMediaItemInfo_Value(it, "D_FADEOUTLEN", wi.fade or 0)
  r.SetMediaItemInfo_Value(it, "B_LOOPSRC", wi.loop and 1 or 0)
  local take = r.GetActiveTake(it)
  if take then
    r.SetMediaItemTakeInfo_Value(take, "D_PAN", wi.pan)
    r.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", wi.rate)
    r.SetMediaItemTakeInfo_Value(take, "B_PPITCH", 0)
    r.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", wi.offs or 0)
  end
  if wi.reverse then set_reverse(it, true) end
end

local function build_midi_item(tr, m)
  local it = r.CreateNewMIDIItemInProj(tr, m.pos, m.pos + m.len, false)
  if not it then return nil end
  local take = r.GetActiveTake(it)
  if take then
    r.MIDI_DisableSort(take)
    for _, n in ipairs(m.notes) do
      local s = r.MIDI_GetPPQPosFromProjTime(take, n.pos)
      local e = r.MIDI_GetPPQPosFromProjTime(take, n.stop)
      r.MIDI_InsertNote(take, false, false, s, e, n.chan - 1, n.pitch, n.vel, true)
    end
    -- controllers: Strudel's ccn / ccv, progNum, midibend
    local CHANMSG = { cc = 0xB0, pc = 0xC0, pb = 0xE0 }
    for _, c in ipairs(m.ctls or {}) do
      r.MIDI_InsertCC(take, false, false, r.MIDI_GetPPQPosFromProjTime(take, c.pos), CHANMSG[c.kind], c.chan - 1, c.a, c.b)
    end
    r.MIDI_Sort(take)
  end
  return it
end

-- comp = Core.compose(...);  valid = { [pattern guid] = true } (patterns that exist and are switched on)
function RA.sync(comp)
  local st = { tracks_new = 0, tracks_del = 0, items_new = 0, items_upd = 0, items_del = 0, midi_new = 0, bad = {} }

  local res, err = with_undo("Gingersnap: render", function()
    local ex = RA.index_tracks()
    local root = ex.root
    local need_root = (#comp.groups > 0) or (#comp.midi > 0)
    if not root and need_root then root = new_track("root", "GINGERSNAP", "GINGERSNAP"); st.tracks_new = st.tracks_new + 1 end

    -- 1. wanted tracks --------------------------------------------------------------
    local D, layout, want_tr, track_of = { root }, {}, {}, {}
    if root then want_tr[root] = true end
    if #comp.midi > 0 then
      local gt = ex.groups["@midi"]
      if not gt then gt = new_track("group", "@midi", "MIDI"); st.tracks_new = st.tracks_new + 1 end
      want_tr[gt] = true; D[#D + 1] = gt
      local L = { track = gt, kids = {} }
      for _, m in ipairs(comp.midi) do
        local tr = ex.midis[m.id]
        if not tr then tr = new_track("midi", m.id, m.name); st.tracks_new = st.tracks_new + 1 end
        want_tr[tr] = true; D[#D + 1] = tr; L.kids[#L.kids + 1] = tr; track_of[m.id] = tr
      end
      layout[#layout + 1] = L
    end
    for _, g in ipairs(comp.groups) do
      local gt = ex.groups[g.id]
      if not gt then gt = new_track("group", g.id, g.name); st.tracks_new = st.tracks_new + 1 end
      want_tr[gt] = true; D[#D + 1] = gt
      local L = { track = gt, kids = {} }
      for _, t in ipairs(g.tracks) do
        local tr = ex.snds[t.id]
        if not tr then tr = new_track("snd", t.id, t.name); st.tracks_new = st.tracks_new + 1 end
        want_tr[tr] = true; D[#D + 1] = tr; L.kids[#L.kids + 1] = tr; track_of[t.id] = tr
      end
      layout[#layout + 1] = L
    end

    -- 2. what exists: generated items by key (duplicates are removed) --------------
    local have, dups = {}, {}
    for _, rec in ipairs(ex.list) do
      if rec.role == "snd" or rec.role == "midi" then
        for i = 0, r.CountTrackMediaItems(rec.tr) - 1 do
          local it = r.GetTrackMediaItem(rec.tr, i)
          local key = iget(it, E_KEY)
          if key ~= "" then
            if have[key] then dups[#dups + 1] = { tr = rec.tr, it = it } else have[key] = { it = it, tr = rec.tr } end
          end
        end
      end
    end
    for _, d in ipairs(dups) do r.DeleteTrackMediaItem(d.tr, d.it); st.items_del = st.items_del + 1 end

    -- 3. audio items ---------------------------------------------------------------
    local wanted = {}
    for _, g in ipairs(comp.groups) do
      for _, t in ipairs(g.tracks) do
        local tr = track_of[t.id]
        for _, wi in ipairs(t.items) do
          wanted[wi.key] = true
          local rec = have[wi.key]
          local it = rec and rec.it
          if it and rec.tr ~= tr then r.MoveMediaItemToTrack(it, tr); rec.tr = tr end
          local fresh = false
          if not it then
            local src = r.PCM_Source_CreateFromFile(t.path)
            if not src then
              st.bad[t.path] = true
            else
              it = r.AddMediaItemToTrack(tr)
              local take = r.AddTakeToMediaItem(it)
              r.SetMediaItemTake_Source(take, src)
              r.GetSetMediaItemTakeInfo_String(take, "P_NAME", wi.sound.name, true)
              iset(it, E_KEY, wi.key); iset(it, E_OWN, wi.owner)
              st.items_new = st.items_new + 1
              fresh = true
            end
          end
          if it then
            local sig = Core.item_sig(wi)
            if fresh or iget(it, E_SIG) ~= sig then
              apply_audio_item(it, wi)
              iset(it, E_SIG, sig)
              if not fresh then st.items_upd = st.items_upd + 1 end
            end
          end
        end
      end
    end

    -- 4. MIDI items ----------------------------------------------------------------
    for _, m in ipairs(comp.midi) do
      wanted[m.id] = true
      local tr = track_of[m.id]
      local rec = have[m.id]
      if rec and rec.tr ~= tr then r.MoveMediaItemToTrack(rec.it, tr); rec.tr = tr end
      if not (rec and iget(rec.it, E_SIG) == m.sig) then
        if rec then r.DeleteTrackMediaItem(rec.tr, rec.it); st.items_del = st.items_del + 1 end
        local it = build_midi_item(tr, m)
        if it then
          iset(it, E_KEY, m.id); iset(it, E_OWN, m.owner); iset(it, E_SIG, m.sig)
          st.midi_new = st.midi_new + 1
        end
      end
    end

    -- 5. stale items and obsolete tracks --------------------------------------------
    for key, rec in pairs(have) do
      if not wanted[key] then r.DeleteTrackMediaItem(rec.tr, rec.it); st.items_del = st.items_del + 1 end
    end
    for _, rec in ipairs(ex.list) do
      local tr = rec.tr
      if rec.dup then
        release_track(tr)                                   -- a copy of a managed track: keep it, just not managed
      elseif not want_tr[tr] then
        if r.CountTrackMediaItems(tr) == 0 and (rec.role ~= "root" or not need_root) then
          r.DeleteTrack(tr); st.tracks_del = st.tracks_del + 1
        else                                                -- has content that is not ours: hand it back
          release_track(tr)
        end
      end
    end

    -- 6. order + folder structure ----------------------------------------------------
    if root then
      order_tracks(D)
      RA.apply_depths(root, layout)
    end
    return st
  end)
  if not res then return nil, err end
  return st
end

--------------------------------------------------------------------------------
-- freeze / detach
--------------------------------------------------------------------------------
-- keep everything a pattern generated as ordinary items and switch the pattern off
function RA.freeze_pattern(pat)
  local n = 0
  for i = 0, r.CountMediaItems(0) - 1 do
    local it = r.GetMediaItem(0, i)
    if iget(it, E_OWN) == pat.guid then untag_item(it); n = n + 1 end
  end
  RA.set_off(pat.item, true)
  return n
end

-- stop managing everything: tags removed, tracks and items stay as ordinary ones, patterns switched off
function RA.detach()
  local st = { tracks = 0, items = 0 }
  local res, err = with_undo("Gingersnap: detach", function()
    for _, rec in ipairs(RA.index_tracks().list) do release_track(rec.tr); st.tracks = st.tracks + 1 end
    for i = 0, r.CountMediaItems(0) - 1 do
      local it = r.GetMediaItem(0, i)
      if iget(it, E_KEY) ~= "" or iget(it, E_OWN) ~= "" then untag_item(it); st.items = st.items + 1 end
      if iget(it, E_PAT) == "1" then iset(it, E_OFF, "1") end
    end
    return st
  end)
  if not res then return nil, err end
  return st
end

-- number of managed tracks / generated items (for the status line)
function RA.managed_info()
  local info = { tracks = 0, items = 0 }
  for i = 0, r.CountTracks(0) - 1 do
    if tget(r.GetTrack(0, i), E_ROLE) ~= "" then info.tracks = info.tracks + 1 end
  end
  return info
end

function RA.show_root()
  local ex = RA.index_tracks()
  if ex.root then r.SetOnlyTrackSelected(ex.root); r.SetMixerScroll(ex.root); r.Main_OnCommand(40913, 0) end
end

return RA
