-- strudel: the module entry point.
--   local Strudel = require("strudel")
--   local r, err = Strudel.run('$: s("bd*2 sn").fast(2)')        -- r.layers[i].pattern, r.warnings
--   local events = Strudel.events(r.layers[1].pattern, 0, 4)       -- onsets in cycles 0..4
local P = require("strudel.pattern")
local Fraction = require("strudel.fraction")
require("strudel.signal")
require("strudel.library")
require("strudel.tonal")
require("strudel.slicing")
require("strudel.pick")
local Controls = require("strudel.controls")
local Mini = require("strudel.mini")
local Lang = require("strudel.lang")

local Strudel = {
  VERSION = "0.2.0",
  Fraction = Fraction, Pattern = P, Mini = Mini, Lang = Lang, Controls = Controls,
  run = Lang.run,
  mini = Mini.mini,
}

-- All events whose ONSET lies in [from, to) cycles, sorted by time:
--   { { b = Fraction, e = Fraction, value = {...} }, ... }     (b/e = start/end of the whole event)
--   opts.cps_fn(cycle) -> cycles per second (the host's tempo): needed by loopAt / splice / fit. Without it Strudel's
--   defaults are used (loopAt 0.5, splice and fit 1). With it the pattern is queried one cycle at a time.
function Strudel.events(pattern, from, to, opts)
  local out = {}
  local function add(haps)
    for _, h in ipairs(haps) do
      if P.has_onset(h) then out[#out + 1] = { b = h.whole.b, e = h.whole.e, value = h.value } end
    end
  end
  if opts and opts.cps_fn then
    local ok, err = pcall(function()
      for c = math.floor(from), math.ceil(to) - 1 do
        P.controls._cps = opts.cps_fn(c)
        add(pattern:query_arc(math.max(c, from), math.min(c + 1, to)))
      end
    end)
    P.controls._cps = nil
    if not ok then error(err, 0) end
  else
    add(pattern:query_arc(from, to))
  end
  table.sort(out, function(x, y)
    if x.b ~= y.b then return x.b < y.b end
    return false
  end)
  return out
end

return Strudel
