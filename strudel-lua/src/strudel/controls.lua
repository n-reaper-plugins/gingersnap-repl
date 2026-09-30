-- strudel/controls.lua
-- Controls (s, n, note, gain, ...): functions that turn plain values into maps  {s="bd", n=3}.
-- Same semantics as Strudel's registerControl: `s("bd:3:0.5")` sets s, n and gain from the list.
-- Controls that only make sense for a synth/sampler (lpf, room, delay ...) are accepted but ignored;
-- the ones used are recorded in controls.used_ignored so the host can warn.

local P = require("strudel.pattern")
local Pattern, reify, is_map, is_list = P.Pattern, P.reify, P.is_map, P.is_list

local C = { globals = {}, used_ignored = {}, known = {}, ignored = {} }

local function copy(t) local r = {}; for k, v in pairs(t) do r[k] = v end; return r end

-- note name -> midi number  (Strudel: c3 = 48, default octave 3)
local CHROMA = { c = 0, d = 2, e = 4, f = 5, g = 7, a = 9, b = 11 }
local ACC = { ["#"] = 1, b = -1, s = 1, f = -1 }
function C.note_to_midi(note, default_octave)
  if type(note) ~= "string" then return nil end
  local pc, acc, oct = note:match("^([a-gA-G])([#bsf]*)(-?%d*)$")
  if not pc then return nil end
  local off = 0
  for ch in acc:gmatch(".") do off = off + ACC[ch] end
  local o = (oct ~= "") and tonumber(oct) or (default_octave or 3)
  return (o + 1) * 12 + CHROMA[pc:lower()] + off
end
P.note_to_midi = C.note_to_midi

local function create_param(names)
  local multi = type(names) == "table"
  local list = multi and names or { names }
  local name = list[1]
  local function with_val(xs)
    local bag
    if is_map(xs) and xs.value ~= nil then bag = copy(xs); xs = xs.value; bag.value = nil end
    if multi and is_list(xs) then
      local result = bag or {}
      for i, x in ipairs(xs) do if i <= #list then result[list[i]] = x end end
      return result
    elseif bag then bag[name] = xs; return bag
    else return { [name] = xs } end
  end
  return function(value, pat)
    if not pat then return reify(value):fmap(with_val) end
    if value == nil then return pat:fmap(with_val) end
    return pat:op_in_set(reify(value):fmap(with_val))
  end
end

function C.register_control(names, aliases, ignored)
  local list = type(names) == "table" and names or { names }
  local f = create_param(names)
  local all = { list[1] }
  for _, a in ipairs(aliases or {}) do all[#all + 1] = a end
  for _, nm in ipairs(all) do
    C.known[nm] = list[1]
    local g = function(value)
      if ignored then C.used_ignored[nm] = true end
      return f(value, nil)
    end
    local m = function(self, value)
      if ignored then C.used_ignored[nm] = true end
      return f(value, self)
    end
    C.globals[nm] = g
    Pattern[nm] = m
    P.api[nm] = m
    if ignored then C.ignored[nm] = true end
  end
end

-- controls that REAPER can render
C.register_control({ "s", "n", "gain" }, { "sound" })
C.register_control({ "note", "n" })
C.register_control("n")
C.register_control("gain")
C.register_control("velocity", { "vel" })
C.register_control("pan")
C.register_control("legato")
C.register_control("clip")
C.register_control("speed")
C.register_control("channel", { "midichan" })

-- accepted, but no effect when rendering a project
for _, nm in ipairs({
  "lpf", "cutoff", "lp", "hpf", "hcutoff", "hp", "resonance", "lpq", "hpq", "bandf", "bpf", "bandq", "bpq",
  "room", "size", "roomsize", "sz", "rsize", "delay", "delaytime", "delayfeedback", "delayfb", "delayt",
  "attack", "att", "decay", "dec", "sustain", "sus", "release", "rel", "shape", "crush", "coarse", "distort",
  "vowel", "bank", "orbit", "cut", "detune", "det", "unison", "phaser", "phaserdepth", "tremolo", "postgain",
  "lpenv", "lpa", "lpd", "lps", "lpr", "hpenv", "acidenv", "fm", "fmi", "fmh", "duck", "duckdepth", "compressor",
  "begin", "end", "loop", "loopAt", "chop", "accelerate", "amp", "octave", "slide", "wt", "warp", "sync", "clip",
}) do
  if not C.known[nm] then C.register_control(nm, nil, true) end
end
-- visual / analysis helpers: accepted and ignored
C.visual = { "scope", "pianoroll", "punchcard", "spiral", "wordfall", "spectrum", "tscope", "fscope", "pitchwheel",
  "_scope", "_pianoroll", "_punchcard", "_spiral", "_wordfall", "_spectrum", "viz", "draw", "log", "hush" }

return C
