// Generates test/golden.json: every case of test/cases.txt evaluated by REAL Strudel (@strudel/core + mini).
// Usage (from strudel-lua/):  node reference/gen.mjs        (needs the reference deps: bash reference/setup.sh)
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const here = path.dirname(fileURLToPath(import.meta.url));
const lib = await import(path.join(here, 'lib.mjs'));
const testDir = path.join(here, '../test');
const cases = fs.readdirSync(testDir).filter((f) => /^cases.*\.txt$/.test(f)).sort()
  .flatMap((f) => fs.readFileSync(path.join(testDir, f), 'utf8').split('\n'))
  .map((l) => l.trim()).filter((l) => l && !l.startsWith('#'));
const CYCLES = 8;
const fr = (x) => x.toFraction();
const out = [];
for (const src of cases) {
  try {
    const pat = lib.evaluate(src);
    const haps = pat.queryArc(0, CYCLES).filter((h) => h.hasOnset());
    const events = haps.map((h) => ({ b: fr(h.whole.begin), e: fr(h.whole.end), v: h.value }));
    out.push({ src, events });
  } catch (e) {
    out.push({ src, error: String(e.message || e) });
  }
}
const bad = out.filter((c) => { try { JSON.stringify(c); return false; } catch { return true; } });
for (const c of bad) { console.log('not serialisable (dropped):', c.src); }
fs.writeFileSync(path.join(here, '../test/golden.json'), JSON.stringify(out.filter((c) => !bad.includes(c))));
console.log(`wrote ${out.length} cases, ${out.filter((c) => c.error).length} rejected by Strudel`);
