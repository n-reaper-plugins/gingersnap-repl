// Print onset events of ONE expression as evaluated by real Strudel (for diffing against test/one.lua)
const lib = await import(new URL('./lib.mjs', import.meta.url));
const to = Number(process.argv[3] || 8);
const sortKeys = (k, v) => (v && typeof v === 'object' && !Array.isArray(v) ? Object.fromEntries(Object.entries(v).sort(([a], [b]) => (a < b ? -1 : 1))) : v);
const pat = lib.evaluate(process.argv[2]);
const rows = pat.queryArc(0, to).filter((h) => h.hasOnset()).map((h) => `${h.whole.begin.toFraction()} ${h.whole.end.toFraction()} ${JSON.stringify(h.value, sortKeys)}`);
console.log(rows.sort().join('\n'));
