-- strudel: the module entry point.
--   local Strudel = require("strudel")
--   local r, err = Strudel.run('$: s("bd*2 sn").fast(2)')        -- r.layers[i].pattern, r.warnings
--   local events = Strudel.events(r.layers[1].pattern, 0, 4)       -- onsets in cycles 0..4
local P = require("strudel.pattern")
local Fraction = require("strudel.fraction")
require("strudel.signal")
require("strudel.library")
local Controls = require("strudel.controls")
local Mini = require("strudel.mini")
local Lang = require("strudel.lang")

local Strudel = {
  VERSION = "0.1.0",
  Fraction = Fraction, Pattern = P, Mini = Mini, Lang = Lang, Controls = Controls,
  run = Lang.run,
  mini = Mini.mini,
}

-- All events whose ONSET lies in [from, to) cycles, sorted by time:
--   { { b = Fraction, e = Fraction, value = {...} }, ... }     (b/e = start/end of the whole event)
function Strudel.events(pattern, from, to)
  local out = {}
  for _, h in ipairs(pattern:query_arc(from, to)) do
    if P.has_onset(h) then out[#out + 1] = { b = h.whole.b, e = h.whole.e, value = h.value } end
  end
  table.sort(out, function(x, y)
    if x.b ~= y.b then return x.b < y.b end
    return false
  end)
  return out
end

return Strudel
