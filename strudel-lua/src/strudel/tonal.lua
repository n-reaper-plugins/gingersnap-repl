-- strudel/tonal.lua
-- scale(), scaleTranspose(), transpose(): ports of @strudel/tonal (AGPL-3.0-or-later) over a small pitch
-- arithmetic that follows tonal.js (MIT) for what is needed here: note names, intervals, scale types.
-- The scale table (scales.lua) is generated from tonal's own dictionary.

local P = require("strudel.pattern")
local Scales = require("strudel.scales")
local register, is_map = P.register, P.is_map

local T = {}

-- hidden key on control maps: the name of the scale a value came from (Strudel keeps it in hap.context)
T.SCALE = setmetatable({}, { __tostring = function() return "<scale>" end })
P.SCALE = T.SCALE

local function jsmod(n, m) return ((n % m) + m) % m end
local STEP_SEMI = { 0, 2, 4, 5, 7, 9, 11 }       -- C D E F G A B  (index = step + 1)
local STEP_LETTER = "CDEFGAB"
local LETTER_STEP = { c = 0, d = 1, e = 2, f = 3, g = 4, a = 5, b = 6 }

--------------------------------------------------------------------------------
-- notes
--------------------------------------------------------------------------------
-- "c#4" -> { step=0, alt=1, oct=4|nil, pc="C#" , name="C#4" }   (nil if it is not a note)
function T.note(str)
  if type(str) ~= "string" then return nil end
  local l, acc, oct = str:match("^([a-gA-G])([#bsf]*)(-?%d*)$")
  if not l then return nil end
  local alt = 0
  for ch in acc:gmatch(".") do alt = alt + ((ch == "#" or ch == "s") and 1 or -1) end
  local n = { step = LETTER_STEP[l:lower()], alt = alt, oct = (oct ~= "") and tonumber(oct) or nil }
  local pc = STEP_LETTER:sub(n.step + 1, n.step + 1) .. (alt > 0 and string.rep("#", alt) or string.rep("b", -alt))
  n.pc, n.name = pc, pc .. (n.oct and tostring(n.oct) or "")
  return n
end

local function note_name(step, alt, oct)
  local pc = STEP_LETTER:sub(step + 1, step + 1) .. (alt > 0 and string.rep("#", alt) or string.rep("b", -alt))
  return pc .. (oct and tostring(oct) or "")
end

--------------------------------------------------------------------------------
-- intervals:  { ds = diatonic steps (signed), sm = semitones (signed) }
--------------------------------------------------------------------------------
local PERFECT = { [0] = true, [3] = true, [4] = true }
function T.interval(str)
  if type(str) ~= "string" then return nil end
  local num, q = str:match("^([-+]?%d+)([dmMPA]+)$")
  if not num then q, num = str:match("^([dmMPA]+)([-+]?%d+)$") end
  if not num then return nil end
  num = tonumber(num)
  if num == 0 then return nil end
  local dir = num < 0 and -1 or 1
  local a = math.abs(num)
  local step, oct = (a - 1) % 7, (a - 1) // 7
  local alt
  local c = #q
  if q:match("^A+$") then alt = c
  elseif q == "P" and PERFECT[step] then alt = 0
  elseif q == "M" and not PERFECT[step] then alt = 0
  elseif q == "m" and not PERFECT[step] then alt = -1
  elseif q:match("^d+$") then alt = PERFECT[step] and -c or -(c + 1)
  else return nil end
  return { ds = dir * (step + 7 * oct), sm = dir * (STEP_SEMI[step + 1] + alt + 12 * oct) }
end

local IN = { 1, 2, 2, 3, 3, 4, 5, 5, 6, 6, 7, 7 }
function T.interval_from_semitones(n)
  local d = n < 0 and -1 or 1
  local a = math.abs(n)
  local c, o = a % 12, a // 12
  return { ds = d * (IN[c + 1] - 1 + 7 * o), sm = n }
end

-- transposes a note table by an interval table; keeps "no octave" if the note had none
local function transpose_note(n, iv, extra_octaves)
  local nd = n.step + 7 * (n.oct or 0)
  local nm = STEP_SEMI[n.step + 1] + n.alt + 12 * (n.oct or 0)
  local dd, dm = nd + iv.ds + 7 * (extra_octaves or 0), nm + iv.sm + 12 * (extra_octaves or 0)
  local step, oct = dd % 7, dd // 7
  local alt = dm - (STEP_SEMI[step + 1] + 12 * oct)
  return note_name(step, alt, n.oct and oct or nil)
end

-- Note.transpose(name, interval-string | interval-table) -> name | nil
function T.transpose_name(name, iv)
  local n = T.note(name)
  if not n then return nil end
  if type(iv) == "string" then iv = T.interval(iv) end
  if not iv then return nil end
  return transpose_note(n, iv)
end

--------------------------------------------------------------------------------
-- scales
--------------------------------------------------------------------------------
local TYPES = {}
for _, row in ipairs(Scales) do
  local st = { name = row[1], intervals = row[3] }
  TYPES[row[1]] = st
  for _, a in ipairs(row[2]) do TYPES[a] = st end
end

-- Scale.get(name)  ->  { tonic = "C" | "", intervals = {...}, notes = {...}, type = "major" }  or nil if unknown
function T.get_scale(src)
  local tonic, typ = "", ""
  local i = src:find(" ", 1, true)
  local tn = i and T.note(src:sub(1, i - 1)) or nil
  if tn then
    tonic, typ = tn.name, src:sub(#tn.name + 2):lower()
  else
    local n = T.note(src)
    if n then tonic, typ = n.name, "" else typ = src:lower() end
  end
  local st = TYPES[typ]
  if not st then return nil, tonic end
  local notes = {}
  if tonic ~= "" then
    local tnote = T.note(tonic)
    for k, iv in ipairs(st.intervals) do notes[k] = transpose_note(tnote, T.interval(iv)) end
  end
  return { tonic = tonic, intervals = st.intervals, notes = notes, type = st.name }
end

local function get_scale(name)
  name = name:gsub(":", " ")
  local sc, tonic = T.get_scale(name)
  if not sc then
    if T.note(name) or tonic == "" then
      error('Scale name ' .. name .. ' is incomplete. Make sure to use ":" instead of spaces, example: .scale("C:major")', 0)
    end
    error('Invalid scale name "' .. name .. '"', 0)
  end
  return sc
end

local function scale_step(step, scale)
  step = math.ceil(step)
  local sc = get_scale(scale)
  local tonic = T.note(sc.tonic ~= "" and sc.tonic or "C")
  local oct = tonic.oct or 3
  local n = #sc.intervals
  local octave_offset = step // n
  local iv = T.interval(sc.intervals[step % n + 1])
  return transpose_note({ step = tonic.step, alt = tonic.alt, oct = oct }, iv, octave_offset)
end

local function scale_offset(scale, offset, note)
  local sc = get_scale(scale)
  local notes = {}
  for i, nm in ipairs(sc.notes) do notes[i] = T.note(nm).pc end
  if offset ~= offset then error('scale offset "' .. tostring(offset) .. '" not a number', 0) end
  local nn = T.note(note)
  if not nn then error('note "' .. tostring(note) .. '" is not a note', 0) end
  local oct = nn.oct or 3
  local index
  for i, pc in ipairs(notes) do if pc == nn.pc then index = i - 1; break end end
  if not index then error('note "' .. note .. '" is not in scale "' .. scale .. '"', 0) end
  local i, o, n = index, oct, nn.pc
  local direction = (offset > 0 and 1) or (offset < 0 and -1) or 0
  while math.abs(i - index) < math.abs(offset) do
    i = i + direction
    local nx = jsmod(i, #notes)
    if direction < 0 and n:sub(1, 1) == "C" then o = o + direction end
    n = notes[nx + 1]
    if direction > 0 and n:sub(1, 1) == "C" then o = o + direction end
  end
  return n .. o
end

local function note_to_midi(name) return P.note_to_midi(name) end

local function nearest_index(target, numbers, prefer_higher)
  local best, best_diff = 0, math.huge
  for i, s in ipairs(numbers) do
    local diff = math.abs(s - target)
    if (not prefer_higher and diff < best_diff) or (prefer_higher and diff <= best_diff) then best, best_diff = i - 1, diff end
  end
  return best
end

local function nearest_scale_note(scale, note)
  local sc = get_scale(scale)
  local tonic = T.note(sc.tonic ~= "" and sc.tonic or "C")
  local pc0 = { step = tonic.step, alt = tonic.alt, oct = 0 }
  local midis, names = {}, {}
  local ivs = { table.unpack(sc.intervals) }
  ivs[#ivs + 1] = "8P"
  for i, iv in ipairs(ivs) do
    names[i] = transpose_note(pc0, T.interval(iv))
    midis[i] = note_to_midi(names[i])
  end
  local nm = type(note) == "string" and note_to_midi(note) or note
  local octave_diff = math.floor((nm - midis[1]) / 12)
  local aligned = {}
  for i, m in ipairs(midis) do aligned[i] = m + 12 * octave_diff end
  local idx = nearest_index(nm, aligned, true)
  return transpose_note(T.note(names[idx + 1]), T.interval_from_semitones(12 * octave_diff))
end

local function step_and_offset(step)
  local as_number = tonumber(step)
  local offset = 0
  if not as_number then
    local s = tostring(step)
    local num, acc = s:match("^(-?%d+)([#bsf]*)$")
    if not num then error('invalid scale step "' .. s .. '", expected number or integer with optional # b suffixes', 0) end
    as_number = tonumber(num)
    for ch in acc:gmatch(".") do offset = offset + ((ch == "#" or ch == "s") and 1 or -1) end
  end
  return as_number, offset
end

local function copy(t) local r = {}; for k, v in pairs(t) do r[k] = v end; return r end

local function flat_join(v)
  if not P.is_list(v) then return tostring(v) end
  local parts = {}
  for _, x in ipairs(v) do parts[#parts + 1] = flat_join(x) end
  return table.concat(parts, " ")
end

register("scale", 1, function(scale, pat)
  if P.is_list(scale) then scale = flat_join(scale) end
  scale = tostring(scale)
  return pat:with_haps(function(haps)
    local out = {}
    for _, h in ipairs(haps) do
      local v = h.value
      local is_obj = is_map(v)
      local hv = is_obj and v or { n = v }
      local rest = copy(hv)
      local note, n, value = rest.note, rest.n, rest.value
      rest.note, rest.n, rest.value = nil, nil, nil
      local x = note
      if x == nil then x = n end
      if x == nil then x = value end
      if x == nil then
        out[#out + 1] = h                         -- Strudel logs an error and passes the value through
      else
        local scale_note
        local ok = true
        if type(x) == "string" and T.note(x) then
          scale_note = nearest_scale_note(scale, x)
        else
          -- an invalid step or scale name removes the event (Strudel logs the error and drops it)
          local okc, res = pcall(function()
            local num, off = step_and_offset(x)
            local sn = scale_step(num, scale)
            if off ~= 0 then sn = T.transpose_name(sn, T.interval_from_semitones(off)) end
            return sn
          end)
          if okc then scale_note = res else ok = false end
        end
        if ok then
          local nv
          if is_obj then nv = rest; nv.note = scale_note; nv[T.SCALE] = scale
          else nv = scale_note end
          out[#out + 1] = P.hap(h.whole, h.part, nv)
        end
      end
    end
    return out
  end)
end)

register({ "scaleTranspose", "scaleTrans", "strans" }, 1, function(offset, pat)
  return pat:fmap(function(v)
    if not is_map(v) or v[T.SCALE] == nil then
      error("can only use scaleTranspose after .scale", 0)
    end
    local r = copy(v)
    r.note = scale_offset(v[T.SCALE], tonumber(offset), v.note)
    return r
  end)
end)

--------------------------------------------------------------------------------
-- transpose(intervalOrSemitones): numbers are semitones, strings intervals ("5P", "3m")
--------------------------------------------------------------------------------
register({ "transpose", "trans" }, 1, function(by, pat)
  return pat:fmap(function(v)
    local obj = is_map(v)
    local nv = obj and v.note
    if nv == nil then nv = v end
    local target
    if type(nv) == "number" then
      local semis
      if type(by) == "number" then semis = by
      elseif type(by) == "string" then local iv = T.interval(by); semis = iv and iv.sm or 0 end
      target = nv + (semis or 0)
    else
      if type(nv) ~= "string" or not T.note(nv) then return v end    -- Strudel: warning, value unchanged
      local iv
      if tonumber(by) then iv = T.interval_from_semitones(tonumber(by)) else iv = T.interval(tostring(by)) end
      target = iv and T.transpose_name(nv, iv) or nv
    end
    if obj then local r = copy(v); r.note = target; return r end
    return target
  end)
end)

return T
