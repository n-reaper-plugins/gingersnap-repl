-- GSCore.lua
-- Pure Lua (5.3/5.4). NO reaper.* calls in here, so everything can be tested offline.
--
-- Turns the events of a Strudel pattern (see strudel-lua) into what should exist in the project:
--   * audio items  : one per event with a sound (folder name = sound name, :N or n() = Nth file)
--   * MIDI notes   : one per event with a note (or a General-MIDI drum name)
-- Time handling is injected (`timefn`: cycle position -> seconds), so tempo maps are REAPER's business.

local Strudel = require("strudel")

local Core = {}
Core.VERSION = "0.2.0"

Core.MAX_EVENTS = 20000          -- per pattern; protects REAPER from things like s("bd*512").fast(64)

local AUDIO = { wav = 1, wave = 1, flac = 1, mp3 = 1, ogg = 1, oga = 1, opus = 1,
                aif = 1, aiff = 1, aifc = 1, m4a = 1, wv = 1, caf = 1 }

function Core.is_audio(file)
  local e = tostring(file):match("%.([^%.]+)$")
  return e ~= nil and AUDIO[e:lower()] ~= nil
end
function Core.strip_ext(file) return (tostring(file):gsub("%.[^%.]+$", "")) end

-- sound / folder name -> key (trimmed, case-insensitive)
function Core.norm(s)
  s = tostring(s or "")
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  return s:lower()
end

-- 32-bit FNV-1a + murmur3 finaliser (signatures only, not security)
function Core.hash32(s)
  local h = 2166136261
  for i = 1, #s do h = ((h ~ s:byte(i)) * 16777619) & 0xFFFFFFFF end
  h = h ~ (h >> 16); h = (h * 0x85ebca6b) & 0xFFFFFFFF
  h = h ~ (h >> 13); h = (h * 0xc2b2ae35) & 0xFFFFFFFF
  h = h ~ (h >> 16)
  return h
end
function Core.hex(s) return string.format("%08x", Core.hash32(s)) end

-- signature of a scanned sound folder: names + counts (lengths are handled by the plan itself)
function Core.groups_sig(groups)
  local ids = {}
  for id in pairs(groups) do ids[#ids + 1] = id end
  table.sort(ids)
  local parts = {}
  for _, id in ipairs(ids) do
    local g = groups[id]
    local names = {}
    for i, s in ipairs(g.sounds) do names[i] = s.file end
    parts[#parts + 1] = id .. ":" .. table.concat(names, "|")
  end
  return Core.hex(table.concat(parts, "\n"))
end

local function fmt(v) return string.format("%.6f", v) end
Core.fmt = fmt

--------------------------------------------------------------------------------
-- General MIDI drum names (used when a pattern has s("bd sn hh") but is rendered as MIDI)
--   GM_BASE   always on
--   GM_ALIAS  Strudel's short drum names (sd rim lt mt ht cr rd cb perc): only with "Standard drum aliases" switched on
--------------------------------------------------------------------------------
Core.GM_BASE = {
  bd = 36, kick = 36, bd2 = 35, sn = 38, snare = 38, rs = 37, sidestick = 37, cp = 39, clap = 39,
  lowtom = 41, midtom = 47, hightom = 50, tom = 45,
  hh = 42, hihat = 42, ch = 42, closedhat = 42, ph = 44, pedalhat = 44, oh = 46, openhat = 46,
  crash = 49, cy = 49, ride = 51, cowbell = 56, tb = 54, tambourine = 54,
  sh = 70, shaker = 70, cabasa = 69, clave = 75, wood = 76,
}
Core.GM_ALIAS = { sd = 38, rim = 37, lt = 41, mt = 47, ht = 50, cr = 49, rd = 51, cb = 56, perc = 60 }

-- the aliases are also looked up as sample folders: with the switch on, s("sd") finds a folder called sn / snare, and
-- s("snare") finds a folder called sd (the first name of a row is Strudel's)
Core.ALIAS_GROUPS = {
  { "sd", "sn", "snare", "snaredrum" }, { "rim", "rs", "rimshot", "sidestick" }, { "lt", "lowtom", "tomlow" },
  { "mt", "midtom", "tommid" }, { "ht", "hightom", "tomhigh" }, { "cr", "crash", "cy" }, { "rd", "ride" },
  { "cb", "cowbell" }, { "perc", "percussion" },
}
local GROUP_OF = {}
for _, g in ipairs(Core.ALIAS_GROUPS) do for _, nm in ipairs(g) do GROUP_OF[nm] = g end end

-- everything GM_DRUMS knew in 0.1 (kept for callers that want the full table)
Core.GM_DRUMS = {}
for k, v in pairs(Core.GM_BASE) do Core.GM_DRUMS[k] = v end
for k, v in pairs(Core.GM_ALIAS) do Core.GM_DRUMS[k] = v end

function Core.gm_note(name, aliases)
  local n = Core.norm(name)
  if Core.GM_BASE[n] then return Core.GM_BASE[n] end
  if aliases then
    if Core.GM_ALIAS[n] then return Core.GM_ALIAS[n] end
    local g = GROUP_OF[n]
    if g then return Core.GM_ALIAS[g[1]] end
  end
  return nil
end

-- the sound folders to try for  s(name).bank(bank): "<bank>_<name>" first (Strudel's naming), then "<name>";
-- with aliases on every equivalent name is tried in each of the two steps
function Core.sound_candidates(name, bank, aliases)
  local names = { Core.norm(name) }
  if aliases and GROUP_OF[names[1]] then
    for _, nm in ipairs(GROUP_OF[names[1]]) do if nm ~= names[1] then names[#names + 1] = nm end end
  end
  local out = {}
  local b = (type(bank) == "string") and Core.norm(bank) or ""
  if b ~= "" then for _, nm in ipairs(names) do out[#out + 1] = { id = b .. "_" .. nm, banked = true } end end
  for _, nm in ipairs(names) do out[#out + 1] = { id = nm } end
  return out
end

function Core.find_group(groups, name, bank, aliases)
  local cands = Core.sound_candidates(name, bank, aliases)
  for _, c in ipairs(cands) do
    if groups[c.id] then return groups[c.id], c end
  end
  return nil, cands
end

--------------------------------------------------------------------------------
-- planning one pattern
--------------------------------------------------------------------------------
local function clamp(x, lo, hi) if x < lo then return lo elseif x > hi then return hi end; return x end
local function num(v, default)
  if type(v) == "number" then return v end
  if type(v) == "string" then return tonumber(v) or default end
  return default
end
local function truthy(v) return v ~= nil and v ~= false and v ~= 0 and v ~= "" end

-- Strudel's valueToMidi: a number, or a note name (c3 = 48)
local function note_number(nv)
  if type(nv) == "number" then return nv end
  if type(nv) == "string" then return Strudel.Controls.note_to_midi(nv) or tonumber(nv) end
  return nil
end

Core.DEFAULT_ROOT_NOTE = 36      -- Strudel's sampler plays a sample unchanged at note 36 (c2 in Strudel naming)

-- spec = {
--   name=, guid=, layers = { {pattern=, label=} }, mode = "audio"|"midi"|"both",
--   groups = { [id] = {name=, sounds={ {file,name,path} }, path=} },
--   cycles = <number of cycles the pattern item covers>,
--   timefn = function(cycle_position_float) -> seconds,
--   lenfn  = function(path) -> seconds | nil,
--   aliases = bool            -- "Standard drum aliases" (sd rim lt mt ht cr rd cb perc)
--   root_note = number        -- MIDI note at which a sample plays unchanged (default 36)
-- }
-- returns plan = { audio = {items}, midi = {layers}, warnings = {..}, events = n }   or  nil, message
function Core.plan_pattern(spec)
  local plan = { audio = {}, midi = {}, warnings = {}, events = 0 }
  local warned = {}
  local function warn(key, msg)
    if not warned[key] then warned[key] = true; plan.warnings[#plan.warnings + 1] = msg end
  end
  local want_audio, want_midi = spec.mode ~= "midi", spec.mode ~= "audio"
  local cycles = spec.cycles
  if not (cycles and cycles > 0) then return plan end
  local upto = math.ceil(cycles - 1e-9)
  local timefn = spec.timefn
  local aliases = spec.aliases and true or false
  local root = spec.root_note or Core.DEFAULT_ROOT_NOTE
  -- cycles per second at cycle c (tempo map aware): loopAt / splice / fit need it
  local function cps_fn(c)
    local d = timefn(c + 1) - timefn(c)
    if d <= 0 then return 0.5 end
    return 1 / d
  end

  for li, layer in ipairs(spec.layers or {}) do
    local ok, evs = pcall(Strudel.events, layer.pattern, 0, upto, { cps_fn = cps_fn })
    if not ok then return nil, "layer " .. li .. ": " .. Strudel.Lang.clean_error(evs) end
    if #evs > Core.MAX_EVENTS then
      return nil, string.format("%d events in %d cycles is too many (limit %d) - shorten the pattern item or the pattern.", #evs, upto, Core.MAX_EVENTS)
    end
    local seen = {}
    local notes, ctls = {}, {}
    for _, ev in ipairs(evs) do
      local t0 = ev.b:float()
      if t0 < cycles - 1e-9 then
        plan.events = plan.events + 1
        local v = ev.value
        local t1 = ev.e:float()
        if type(v) ~= "table" or getmetatable(v) ~= nil then
          warn("noctl" .. li, "layer " .. li .. ": values are not controls - write s(\"bd sn\") or note(\"c e g\").")
        else
          local pos = timefn(t0)
          local made_audio = false
          local has_ctl = false
          local sname = type(v.s) == "string" and v.s or nil

          -- ------------------------------------------------ audio
          if want_audio and sname then
            local g, c = Core.find_group(spec.groups, sname, v.bank, aliases)
            if not g then
              local tried = {}
              for _, x in ipairs(c) do tried[#tried + 1] = x.id end
              warn("nosnd:" .. sname, "no sound folder named '" .. sname .. "'" .. (#tried > 1 and (" (tried " .. table.concat(tried, ", ") .. ")") or ""))
            else
              if v.bank and not c.banked then
                warn("nobank:" .. tostring(v.bank) .. sname, "no folder '" .. tostring(v.bank) .. "_" .. sname .. "', using '" .. g.name .. "'")
              end
              if #g.sounds == 0 then
                warn("empty:" .. sname, "folder '" .. g.name .. "' has no audio files")
              else
                local n = math.floor(num(v.n, 0))
                local snd = g.sounds[(n % #g.sounds) + 1]
                local slen = spec.lenfn and spec.lenfn(snd.path)
                local speed = num(v.speed, 1)
                if not slen then
                  warn("badfile:" .. snd.path, "could not read " .. snd.file)
                elseif speed == 0 then
                  -- speed 0 plays nothing (Strudel too)
                else
                  local reverse = speed < 0
                  local rate = math.abs(speed)
                  -- pitch: note(...) repitches the sample, rate = 2^((note - root) / 12)
                  local nn = note_number(v.note)
                  if nn then rate = rate * 2 ^ ((nn - root) / 12) end
                  if v.unit == "c" then rate = rate * slen end        -- unit "c": speed counts cycles (loopAt, splice, fit)
                  rate = clamp(rate, 0.01, 100)
                  -- begin / end: a part of the file (fractions); a reversed sound is cut from the reversed file
                  local b, e = clamp(num(v.begin, 0), 0, 1), clamp(num(v["end"], 1), 0, 1)
                  if e <= b then
                    warn("beginend", "begin must be smaller than end - event skipped")
                  else
                    local offs = (reverse and (1 - e) or b) * slen
                    local region = (e - b) * slen
                    local len = region / rate
                    local looped = truthy(v.loop)
                    local ev_len = timefn(t1) - pos
                    if looped then len = ev_len end
                    local fade
                    local lim = num(v.legato, nil) or num(v.clip, nil)
                    if lim and lim > 0 then
                      local cut = timefn(t0 + (t1 - t0) * lim) - pos
                      if cut > 0 and (looped or cut < len) then len = cut; fade = 0.005 end
                    end
                    local k = string.format("%s|%d|%s|%s", spec.guid, li, tostring(ev.b), snd.file)
                    seen[k] = (seen[k] or 0) + 1
                    if seen[k] > 1 then k = k .. "#" .. seen[k] end
                    local cutg = num(v.cut, 0)
                    plan.audio[#plan.audio + 1] = {
                      key = k, owner = spec.guid, gid = Core.norm(g.name), gname = g.name, sound = snd,
                      pos = pos, len = len, fade = fade,
                      vol = clamp(num(v.gain, 1) * num(v.velocity, 1) * num(v.postgain, 1), 0, 16),
                      pan = clamp(num(v.pan, 0.5) * 2 - 1, -1, 1), rate = rate,
                      offs = offs, reverse = reverse or nil, loop = looped or nil, cut = (cutg > 0) and cutg or nil,
                    }
                    made_audio = true
                  end
                end
              end
            end
          end

          -- ------------------------------------------------ MIDI
          if want_midi then
            local chan_base = num(v.midichan, nil) or num(v.channel, nil)
            local pitch, drum
            local nv = v.note
            if type(nv) == "number" then pitch = nv
            elseif type(nv) == "string" then
              pitch = Strudel.Controls.note_to_midi(nv) or tonumber(nv)
              if not pitch then warn("badnote:" .. nv, "'" .. nv .. "' is not a note") end
            elseif sname and Core.gm_note(sname, aliases) then
              pitch, drum = Core.gm_note(sname, aliases), true
            elseif not sname and type(v.n) == "number" then
              pitch = v.n                       -- n("60 64") without a sound: the number is the MIDI note
            end
            local chan = clamp(math.floor(chan_base or (drum and 10 or 1)), 1, 16)

            -- controllers (Strudel's midi output): ccn + ccv, progNum, midibend
            if v.ccn ~= nil and v.ccv ~= nil then
              local cn, cv = num(v.ccn, nil), num(v.ccv, nil)
              if not cn or cn < 0 or cn > 127 then warn("badccn", "ccn must be a controller number 0-127")
              elseif not cv or cv < 0 or cv > 1 then warn("badccv", "ccv must be a number between 0 and 1")
              else
                ctls[#ctls + 1] = { kind = "cc", pos = pos, chan = chan, a = math.floor(cn), b = math.floor(cv * 127 + 0.5) }
                has_ctl = true
              end
            end
            if v.progNum ~= nil then
              local pn = num(v.progNum, nil)
              if not pn or pn < 0 or pn > 127 then warn("badprog", "progNum must be a number between 0 and 127")
              else ctls[#ctls + 1] = { kind = "pc", pos = pos, chan = chan, a = math.floor(pn), b = 0 }; has_ctl = true end
            end
            if v.midibend ~= nil then
              local mb = num(v.midibend, nil)
              if not mb or mb < -1 or mb > 1 then warn("badbend", "midibend must be a number between -1 and 1")
              else
                local w = clamp(math.floor((mb + 1) / 2 * 16383 + 0.5), 0, 16383)
                ctls[#ctls + 1] = { kind = "pb", pos = pos, chan = chan, a = w & 127, b = w >> 7 }
                has_ctl = true
              end
            end

            if pitch then
              -- octave(n) shifts the notes (a synth in Strudel; samples ignore it there too)
              pitch = math.floor(pitch + 12 * num(v.octave, 0) + 0.5)
              if pitch < 0 or pitch > 127 then
                warn("range" .. pitch, "note " .. pitch .. " is outside 0-127")
              else
                local lim = num(v.legato, nil) or num(v.clip, nil) or 1
                local stop = timefn(t0 + (t1 - t0) * lim)
                if stop <= pos then stop = pos + 0.001 end
                notes[#notes + 1] = {
                  pos = pos, stop = stop, pitch = pitch,
                  vel = clamp(math.floor(127 * num(v.velocity, 0.8) * num(v.gain, 1) * num(v.postgain, 1) + 0.5), 1, 127),
                  chan = chan,
                }
              end
            elseif not made_audio and sname and want_midi and not want_audio and not has_ctl then
              warn("nomidi:" .. sname, "no MIDI note for sound '" .. sname .. "' - use note(...) or a General MIDI drum name (bd sn hh oh cp ...)")
            elseif not made_audio and not has_ctl and not sname and not v.note and not v.n then
              warn("nothing" .. li, "layer " .. li .. ": an event has neither s(), note() nor n()")
            end
          end
        end
      end
    end
    if #notes > 0 or #ctls > 0 then
      plan.midi[#plan.midi + 1] = { layer = li, label = layer.label, owner = spec.guid, notes = notes, ctls = ctls }
    end
  end

  -- cut groups: a new item of a group stops the one that is still sounding (all layers of this pattern)
  local by_cut = {}
  for _, it in ipairs(plan.audio) do
    if it.cut then
      by_cut[it.cut] = by_cut[it.cut] or {}
      table.insert(by_cut[it.cut], it)
    end
  end
  for _, list in pairs(by_cut) do
    table.sort(list, function(x, y) if x.pos ~= y.pos then return x.pos < y.pos end; return x.key < y.key end)
    for i = 1, #list - 1 do
      local cur, nxt = list[i], list[i + 1]
      if nxt.pos < cur.pos + cur.len - 1e-9 and nxt.pos > cur.pos then
        cur.len = nxt.pos - cur.pos
        cur.fade = cur.fade or 0.005
      end
    end
  end
  return plan
end

--------------------------------------------------------------------------------
-- voices: items of the same sound that overlap in time go to duplicate tracks (as in PrototypeSequence)
--------------------------------------------------------------------------------
local EPS = 1e-7
function Core.allocate_voices(items)
  local by_path = {}
  for _, it in ipairs(items) do
    local l = by_path[it.sound.path]
    if not l then l = {}; by_path[it.sound.path] = l end
    l[#l + 1] = it
  end
  for _, list in pairs(by_path) do
    table.sort(list, function(a, b)
      if a.pos ~= b.pos then return a.pos < b.pos end
      return a.key < b.key
    end)
    local ends = {}
    for _, it in ipairs(list) do
      local v
      for i = 1, #ends do
        if ends[i] <= it.pos + EPS then v = i; break end
      end
      if not v then v = #ends + 1 end
      ends[v] = it.pos + it.len
      it.voice = v
    end
  end
end

--------------------------------------------------------------------------------
-- composing all patterns into the wanted project structure
--   plans = list of { pattern = <info>, plan = <plan_pattern result> }
-- returns {
--   groups = { {id=, name=, tracks = { {id=, name=, path=, voice=, items={...}} }} },   -- audio, sorted
--   midi   = { {id=, name=, owner=, layer=, notes=, pos=, len=, sig=} },                -- one per pattern layer
--   items  = flat audio list, sig = "hex" }
--------------------------------------------------------------------------------
local function voice_id(path, v) return v == 1 and path or (path .. "#" .. v) end
local function voice_name(name, v) return v == 1 and name or (name .. " (" .. v .. ")") end

function Core.compose(plans)
  local all = {}
  for _, p in ipairs(plans) do
    if p.plan then for _, it in ipairs(p.plan.audio) do all[#all + 1] = it end end
  end
  Core.allocate_voices(all)

  local gmap, glist = {}, {}
  for _, it in ipairs(all) do
    local g = gmap[it.gid]
    if not g then g = { id = it.gid, name = it.gname, tmap = {}, tracks = {} }; gmap[it.gid] = g; glist[#glist + 1] = g end
    local tid = voice_id(it.sound.path, it.voice)
    local t = g.tmap[tid]
    if not t then
      t = { id = tid, name = voice_name(it.sound.name, it.voice), path = it.sound.path, voice = it.voice,
            file = it.sound.file:lower(), items = {} }
      g.tmap[tid] = t
      g.tracks[#g.tracks + 1] = t
    end
    it.track_id = tid
    t.items[#t.items + 1] = it
  end
  table.sort(glist, function(a, b) return a.id < b.id end)
  for _, g in ipairs(glist) do
    table.sort(g.tracks, function(a, b)
      if a.file ~= b.file then return a.file < b.file end
      return a.voice < b.voice
    end)
    g.tmap = nil
  end

  local midi = {}
  for _, p in ipairs(plans) do
    if p.plan then
      for _, ml in ipairs(p.plan.midi) do
        local nm = p.pattern.name
        if ml.label then nm = nm .. " " .. ml.label
        elseif p.nlayers and p.nlayers > 1 then nm = nm .. " $" .. ml.layer end
        local parts = { fmt(p.pattern.pos), fmt(p.pattern.len) }
        for _, n in ipairs(ml.notes) do
          parts[#parts + 1] = string.format("%s,%s,%d,%d,%d", fmt(n.pos), fmt(n.stop), n.pitch, n.vel, n.chan)
        end
        for _, c in ipairs(ml.ctls or {}) do
          parts[#parts + 1] = string.format("%s:%s,%d,%d,%d", c.kind, fmt(c.pos), c.chan, c.a, c.b)
        end
        midi[#midi + 1] = {
          id = "midi:" .. p.pattern.guid .. ":" .. ml.layer, name = nm, owner = p.pattern.guid, layer = ml.layer,
          notes = ml.notes, ctls = ml.ctls or {}, pos = p.pattern.pos, len = p.pattern.len, sig = Core.hex(table.concat(parts, ";")),
        }
      end
    end
  end

  -- one signature for the whole result (what would be written into the project)
  local sp = {}
  for _, g in ipairs(glist) do
    for _, t in ipairs(g.tracks) do
      for _, it in ipairs(t.items) do sp[#sp + 1] = Core.item_sig(it) .. "@" .. t.id end
    end
  end
  for _, m in ipairs(midi) do sp[#sp + 1] = m.id .. "=" .. m.sig end
  table.sort(sp)
  return { groups = glist, midi = midi, items = all, sig = Core.hex(table.concat(sp, "\n")) }
end

-- what makes an audio item's wanted state: if this string is unchanged, the item is left alone
function Core.item_sig(it)
  return string.format("%s:%s:%s:%.4f:%.4f:%.6f:%s:%s:%s%s", it.key, fmt(it.pos), fmt(it.len), it.vol, it.pan, it.rate,
    it.fade and fmt(it.fade) or "-", fmt(it.offs or 0), it.reverse and "R" or "-", it.loop and "L" or "-")
end

return Core
