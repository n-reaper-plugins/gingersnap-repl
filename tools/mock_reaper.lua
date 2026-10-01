-- In-memory fake of the parts of the REAPER API that Gingersnap uses.
-- It checks OUR logic (structure, tags, diffing, main loop, time mapping), not REAPER's behaviour.
package.path = "./src/?.lua;./strudel-lua/src/?.lua;" .. package.path

local M = {}

function M.install()
  local S = {
    tracks = {}, items = {}, ext = {}, projext = {}, fs = {}, filelen = {}, badfiles = {},
    statecount = 1, undo = 0, clock = 0, deferred = {}, atexit = {}, console = {},
    edit_cursor = 0, loop = { 0, 0 }, next_id = 1, bpm = 120, tempo_markers = {}, writes = 0,
  }
  M.S = S
  local function bump() S.statecount = S.statecount + 1 end
  local function guid() S.next_id = S.next_id + 1; return string.format("{00000000-0000-0000-0000-%012d}", S.next_id) end

  ---------------------------------------------------------------- scene helpers
  function M.add_dir(path, dirs, files) S.fs[path] = { dirs = dirs or {}, files = files or {} } end
  function M.make_sounds(root, groups, lens)
    local names = {}
    for g in pairs(groups) do names[#names + 1] = g end
    table.sort(names)
    M.add_dir(root, names, {})
    for _, g in ipairs(names) do
      M.add_dir(root .. "/" .. g, {}, groups[g])
      for _, f in ipairs(groups[g]) do S.filelen[root .. "/" .. g .. "/" .. f] = (lens and lens[f]) or 0.5 end
    end
  end
  function M.touch() bump() end
  function M.new_user_track(name)
    local t = { name = name, ext = {}, items = {}, depth = 0, compact = 0, sel = false, id = S.next_id }
    S.next_id = S.next_id + 1
    S.tracks[#S.tracks + 1] = t
    bump()
    return t
  end
  function M.track_named(name) for _, t in ipairs(S.tracks) do if t.name == name then return t end end end
  function M.items_of(name) local t = M.track_named(name); return t and t.items or {} end
  function M.structure()
    local out, depth = {}, 0
    for _, t in ipairs(S.tracks) do
      out[#out + 1] = string.rep("  ", depth) .. t.name
      depth = depth + t.depth
    end
    return out, depth
  end
  function M.all_items()
    local n = {}
    for _, it in ipairs(S.items) do n[#n + 1] = it end
    return n
  end
  -- Insert > Empty item, as a user would do it
  function M.add_empty_item(track, pos, len, notes)
    local R = reaper
    local it = R.AddMediaItemToTrack(track)
    R.SetMediaItemInfo_Value(it, "D_POSITION", pos)
    R.SetMediaItemInfo_Value(it, "D_LENGTH", len)
    if notes then R.GetSetMediaItemInfo_String(it, "P_NOTES", notes, true) end
    return it
  end
  function M.set_tempo(bpm) S.bpm = bpm; bump() end
  function M.select_item(it)
    for _, x in ipairs(S.items) do x.sel = false end
    it.sel = true
    bump()
  end

  ---------------------------------------------------------------- API
  local R = {}
  reaper = R

  R.ShowConsoleMsg = function(s) S.console[#S.console + 1] = s end
  R.MB = function() return 1 end
  R.atexit = function(f) S.atexit[#S.atexit + 1] = f end
  R.defer = function(f) S.deferred[#S.deferred + 1] = f end
  R.time_precise = function() return S.clock end
  R.get_action_context = function() return true, "x", 0, 0, 0, 0 end
  R.SetToggleCommandState = function() end
  R.RefreshToolbar2 = function() end
  R.GetExtState = function(sec, k) return S.ext[sec .. "/" .. k] or "" end
  R.SetExtState = function(sec, k, v) S.ext[sec .. "/" .. k] = v end
  R.GetProjExtState = function(_, sec, k) local v = S.projext[sec .. "/" .. k]; return v and 1 or 0, v or "" end
  R.SetProjExtState = function(_, sec, k, v) S.writes = S.writes + 1; S.projext[sec .. "/" .. k] = (v ~= "" and v) or nil end
  S.commands = {}
  R.Main_OnCommand = function(id)
    S.commands[#S.commands + 1] = id
    if id == 41051 then                       -- Item properties: Toggle take reverse (acts on the selected items)
      for _, it in ipairs(S.items) do if it.sel then it.p.reversed = not it.p.reversed; bump() end end
    end
  end
  R.EnumProjects = function() return "proj" end
  R.GetProjectStateChangeCount = function() return S.statecount end
  R.PreventUIRefresh = function() end
  R.Undo_BeginBlock2 = function() end
  R.Undo_EndBlock2 = function() S.undo = S.undo + 1 end
  R.TrackList_AdjustWindows = function() end
  R.UpdateArrange = function() end
  R.UpdateItemInProject = function() end
  R.SetMixerScroll = function() end
  R.SetEditCurPos = function(p) S.edit_cursor = p end
  R.GetCursorPosition = function() return S.edit_cursor end
  R.GetSet_LoopTimeRange2 = function() return S.loop[1], S.loop[2] end
  R.format_timestr_pos = function(p) return string.format("%.3f", p) end
  R.ColorToNative = function(a, b, c) return a + b * 256 + c * 65536 end

  -- file system + sources
  R.EnumerateSubdirectories = function(path, i) local d = S.fs[path]; if not d or i < 0 then return nil end; return d.dirs[i + 1] end
  R.EnumerateFiles = function(path, i) local d = S.fs[path]; if not d or i < 0 then return nil end; return d.files[i + 1] end
  R.file_exists = function(p) return p:match("%.%w+$") ~= nil end
  R.PCM_Source_CreateFromFile = function(path)
    if S.badfiles[path] or not S.filelen[path] then return nil end
    return { path = path }
  end
  R.GetMediaSourceLength = function(src) return S.filelen[src.path], false end
  R.PCM_Source_Destroy = function() end

  -- tempo: constant bpm (plus optional markers ignored for the maths, only for fingerprinting)
  local function spq() return 60 / S.bpm end
  R.TimeMap2_timeToQN = function(_, t) return t / spq() end
  R.TimeMap2_QNToTime = function(_, q) return q * spq() end
  R.Master_GetTempo = function() return S.bpm end
  R.CountTempoTimeSigMarkers = function() return #S.tempo_markers end
  R.GetTempoTimeSigMarker = function(_, i) local m = S.tempo_markers[i + 1]; return true, m[1], 0, 0, m[2], 4, 4, false end

  -- tracks
  R.CountTracks = function() return #S.tracks end
  R.GetTrack = function(_, i) return S.tracks[i + 1] end
  R.InsertTrackAtIndex = function(idx, _)
    local t = { name = "", ext = {}, items = {}, depth = 0, compact = 0, sel = false, id = S.next_id }
    S.next_id = S.next_id + 1
    table.insert(S.tracks, idx + 1, t)
    bump()
  end
  R.DeleteTrack = function(t) for i, x in ipairs(S.tracks) do if x == t then table.remove(S.tracks, i); break end end; bump() end
  R.GetSetMediaTrackInfo_String = function(t, k, v, set)
    if k == "P_NAME" then
      if set then t.name = v; bump(); return true end
      return true, t.name
    end
    local e = k:match("^P_EXT:(.+)$")
    if e then
      if set then t.ext[e] = (v ~= "" and v) or nil; bump(); return true end
      return t.ext[e] ~= nil, t.ext[e] or ""
    end
    return false, ""
  end
  R.GetMediaTrackInfo_Value = function(t, k)
    if k == "IP_TRACKNUMBER" then for i, x in ipairs(S.tracks) do if x == t then return i end end
    elseif k == "I_FOLDERDEPTH" then return t.depth
    elseif k == "I_FOLDERCOMPACT" then return t.compact end
    return 0
  end
  R.SetMediaTrackInfo_Value = function(t, k, v)
    if k == "I_FOLDERDEPTH" then t.depth = v elseif k == "I_FOLDERCOMPACT" then t.compact = v end
    bump()
  end
  R.CountSelectedTracks = function() local n = 0; for _, t in ipairs(S.tracks) do if t.sel then n = n + 1 end end; return n end
  R.GetSelectedTrack = function(_, i) local n = 0; for _, t in ipairs(S.tracks) do if t.sel then if n == i then return t end; n = n + 1 end end end
  R.SetTrackSelected = function(t, v) t.sel = v end
  R.SetOnlyTrackSelected = function(t) for _, x in ipairs(S.tracks) do x.sel = (x == t) end end
  R.ReorderSelectedTracks = function(before, _)
    local target = S.tracks[before + 1]
    local moving, rest = {}, {}
    for _, t in ipairs(S.tracks) do if t.sel then moving[#moving + 1] = t else rest[#rest + 1] = t end end
    local pos = #rest + 1
    for i, t in ipairs(rest) do if t == target then pos = i; break end end
    for k, t in ipairs(moving) do table.insert(rest, pos + k - 1, t) end
    S.tracks = rest
    bump()
  end

  -- items
  local function ivalid(it) for _, x in ipairs(S.items) do if x == it then return true end end; return false end
  R.ValidatePtr2 = function(_, p) return p ~= nil and ivalid(p) end
  R.CountMediaItems = function() return #S.items end
  R.GetMediaItem = function(_, i) return S.items[i + 1] end
  R.CountTrackMediaItems = function(t) return #t.items end
  R.GetTrackMediaItem = function(t, i) return t.items[i + 1] end
  R.AddMediaItemToTrack = function(t)
    local it = { track = t, p = { D_POSITION = 0, D_LENGTH = 0, D_VOL = 1, D_FADEOUTLEN = 0, I_CUSTOMCOLOR = 0 },
                 ext = {}, takes = {}, notes = "", guid = guid(), sel = false }
    t.items[#t.items + 1] = it
    S.items[#S.items + 1] = it
    bump()
    return it
  end
  R.DeleteTrackMediaItem = function(t, it)
    for i, x in ipairs(t.items) do if x == it then table.remove(t.items, i); break end end
    for i, x in ipairs(S.items) do if x == it then table.remove(S.items, i); break end end
    bump()
    return true
  end
  R.MoveMediaItemToTrack = function(it, t)
    for i, x in ipairs(it.track.items) do if x == it then table.remove(it.track.items, i); break end end
    it.track = t; t.items[#t.items + 1] = it
    bump()
    return true
  end
  R.GetMediaItemTrack = function(it) return it.track end
  R.CountTakes = function(it) return #it.takes end
  R.GetActiveTake = function(it) return it.takes[1] end
  R.AddTakeToMediaItem = function(it) local tk = { item = it, p = { D_PAN = 0, D_PLAYRATE = 1, B_PPITCH = 1 }, name = "", notes = {} }; it.takes[#it.takes + 1] = tk; return tk end
  R.SetMediaItemTake_Source = function(tk, src) tk.src = src end
  R.GetSetMediaItemTakeInfo_String = function(tk, k, v, set) if k == "P_NAME" and set then tk.name = v end; return true, tk.name end
  R.SetMediaItemTakeInfo_Value = function(tk, k, v) tk.p[k] = v; bump() end
  R.GetMediaItemInfo_Value = function(it, k) return it.p[k] or 0 end
  R.SetMediaItemInfo_Value = function(it, k, v) it.p[k] = v; bump() end
  R.IsMediaItemSelected = function(it) return it.sel end
  R.SetMediaItemSelected = function(it, v) it.sel = v end
  R.CountSelectedMediaItems = function() local n = 0; for _, it in ipairs(S.items) do if it.sel then n = n + 1 end end; return n end
  R.GetSelectedMediaItem = function(_, i) local n = 0; for _, it in ipairs(S.items) do if it.sel then if n == i then return it end; n = n + 1 end end end
  R.GetSetMediaItemInfo_String = function(it, k, v, set)
    if k == "GUID" then return true, it.guid end
    if k == "P_NOTES" then
      if set then it.notes = v; bump(); return true end
      return true, it.notes
    end
    local e = k:match("^P_EXT:(.+)$")
    if e then
      if set then it.ext[e] = (v ~= "" and v) or nil; bump(); return true end
      return it.ext[e] ~= nil, it.ext[e] or ""
    end
    return false, ""
  end

  -- MIDI: PPQ = 960 per quarter note
  R.CreateNewMIDIItemInProj = function(t, s, e)
    local it = R.AddMediaItemToTrack(t)
    R.SetMediaItemInfo_Value(it, "D_POSITION", s)
    R.SetMediaItemInfo_Value(it, "D_LENGTH", e - s)
    local tk = R.AddTakeToMediaItem(it)
    tk.midi = true
    return it
  end
  R.MIDI_DisableSort = function() end
  R.MIDI_Sort = function() end
  R.MIDI_GetPPQPosFromProjTime = function(tk, t) return t / spq() * 960 end
  R.MIDI_InsertCC = function(tk, sel, muted, ppq, msg1, chan, a, b)
    tk.ccs = tk.ccs or {}
    tk.ccs[#tk.ccs + 1] = { ppq = ppq, msg1 = msg1, chan = chan, a = a, b = b }
    return true
  end
  R.MIDI_InsertNote = function(tk, sel, muted, s, e, chan, pitch, vel)
    tk.notes[#tk.notes + 1] = { s = s, e = e, chan = chan, pitch = pitch, vel = vel }
    return true
  end
  return M
end

return M
