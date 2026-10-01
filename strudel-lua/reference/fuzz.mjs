// Deterministic fuzzer: writes test/cases_fuzz.txt with random mini-notation strings and random method chains.
// Both are then checked against real Strudel by gen.mjs / test_reference.lua.  Usage: node reference/fuzz.mjs [seed] [--v02]   (--v02: only the 0.2 functions, written to cases_fuzz_v02.txt)
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const here = path.dirname(fileURLToPath(import.meta.url));
let a = Number(process.argv.slice(2).find((x) => /^\d+$/.test(x)) || 12345) >>> 0;
const rnd = () => { a |= 0; a = (a + 0x6d2b79f5) | 0; let t = Math.imul(a ^ (a >>> 15), 1 | a); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
const pick = (xs) => xs[Math.floor(rnd() * xs.length)];
const int = (lo, hi) => lo + Math.floor(rnd() * (hi - lo + 1));

const words = ['a', 'b', 'c', 'd', 'e', 'bd', 'sn', 'hh', '1', '2', '3', 'c3', 'e4', '0.5'];
function atom(d) {
  const r = rnd();
  if (d > 2 || r < 0.55) return rnd() < 0.12 ? '~' : pick(words) + (rnd() < 0.1 ? ':' + int(0, 5) : '');
  if (r < 0.75) return '[' + seq(d + 1) + (rnd() < 0.25 ? ', ' + seq(d + 1) : rnd() < 0.15 ? ' | ' + seq(d + 1) : '') + ']';
  if (r < 0.9) return '<' + seq(d + 1) + (rnd() < 0.2 ? ', ' + seq(d + 1) : '') + '>';
  return '{' + seq(d + 1) + ', ' + seq(d + 1) + '}' + (rnd() < 0.6 ? '%' + int(2, 6) : '');
}
function elem(d) {
  let s = atom(d);
  const n = rnd() < 0.5 ? 0 : rnd() < 0.7 ? 1 : 2;
  for (let i = 0; i < n; i++) {
    const r = rnd();
    if (r < 0.2) s += '*' + pick(['2', '3', '1.5', '4', '<2 3>']);
    else if (r < 0.32) s += '/' + pick(['2', '3', '1.5']);
    else if (r < 0.42) s += '!' + (rnd() < 0.5 ? int(2, 4) : '');
    else if (r < 0.52) s += '@' + pick(['2', '3', '1.5']);
    else if (r < 0.66) s += '?' + (rnd() < 0.4 ? pick(['0.3', '0.7']) : '');
    else if (r < 0.84) s += '(' + int(1, 7) + ',' + int(2, 9) + (rnd() < 0.4 ? ',' + int(0, 4) : '') + ')';
    else s += ' _';
  }
  return s;
}
function seq(d = 0) {
  const n = int(1, d > 1 ? 3 : 4);
  const xs = [];
  for (let i = 0; i < n; i++) xs.push(elem(d));
  return xs.join(rnd() < 0.08 ? ' . ' : ' ');
}

const methods = [
  () => `.fast(${pick(['2', '3', '"<1 2>"', '"2 4"', '1.5'])})`,
  () => `.slow(${pick(['2', '3', '"<1 2 4>"'])})`,
  () => `.early(${pick(['0.25', '"<0 0.25>"', '1/3'])})`,
  () => `.late(${pick(['0.25', '"<0 0.5>"', '1/8'])})`,
  () => '.rev()', () => '.palindrome()',
  () => `.ply(${pick(['2', '3', '"<2 3>"'])})`,
  () => `.iter(${pick(['3', '4'])})`, () => `.iterBack(${pick(['3', '4'])})`,
  () => `.every(${pick(['2', '3', '"<2 3>"'])}, x=>x.${pick(['fast(2)', 'rev()', 'late(0.25)', 'ply(2)'])})`,
  () => `.off(${pick(['0.25', '1/8', '"<0.125 0.25>"'])}, x=>x.gain(0.5))`,
  () => `.superimpose(x=>x.${pick(['late(0.125)', 'fast(2)', 'rev()'])})`,
  () => `.segment(${pick(['2', '3', '4'])})`,
  () => `.struct("${seq(2)}")`, () => `.mask("${seq(2)}")`,
  () => `.euclid(${int(1, 6)},${int(3, 9)})`, () => `.euclidRot(${int(1, 6)},${int(3, 9)},${int(0, 5)})`,
  () => `.degradeBy(${pick(['0.2', '0.5', '0.8'])})`, () => '.degrade()',
  () => `.sometimes(x=>x.${pick(['fast(2)', 'rev()', 'gain(0.3)'])})`,
  () => `.sometimesBy(${pick(['0.3', '0.7', '"<0.2 0.8>"'])}, x=>x.gain(0.1))`,
  () => `.often(x=>x.speed(2))`, () => `.rarely(x=>x.speed(2))`, () => `.someCyclesBy(0.5, x=>x.speed(2))`,
  () => `.chunk(${pick(['2', '3', '4'])}, x=>x.gain(0.1))`,
  () => `.inside(${pick(['2', '3'])}, x=>x.rev())`,
  () => `.zoom(${pick(['0.25,0.75', '0,0.5', '0.5,1'])})`,
  () => `.linger(${pick(['0.25', '0.5', '0.75'])})`,
  () => `.compress(${pick(['0.25,0.75', '0,0.5'])})`,
  () => `.jux(rev)`, () => `.hurry(${pick(['2', '"<1 2>"'])})`,
  () => `.echo(3, 0.125, 0.5)`, () => `.stut(3, 0.5, 0.125)`,
  () => `.add(${pick(['n(2)', 'n("<1 2>")'])})`,
];
const methodsV02 = [
  () => `.swing(${pick(['2', '4', '\"<2 4>\"'])})`, () => `.swingBy(${pick(['1/3', '0.5', '\"<0 0.25>\"'])}, ${pick(['2', '4'])})`,
  () => '.brak()', () => '.press()', () => `.pressBy(${pick(['0.25', '1/3', '\"<0 0.5>\"'])})`,
  () => `.shuffle(${pick(['2', '3', '4'])})`, () => `.scramble(${pick(['2', '3', '4'])})`,
  () => `.ribbon(${pick(['0', '1', '0.5'])}, ${pick(['1', '2', '3'])})`,
  () => `.within(${pick(['0,0.5', '0.25,0.75', '0.5,1'])}, x=>x.${pick(['fast(2)', 'rev()', 'late(0.125)'])})`,
  () => `.plyWith(${pick(['2', '3'])}, x=>x.add(n(1)))`,
  () => `.euclidLegato(${int(1, 6)},${int(3, 9)})`, () => `.euclidLegatoRot(${int(1, 6)},${int(3, 9)},${int(0, 5)})`,
  () => `.reset(\"${seq(2)}\")`, () => `.restart(\"${seq(2)}\")`,
  () => `.chop(${pick(['2', '3', '\"<2 4>\"'])})`, () => `.striate(${pick(['2', '3', '\"<2 4>\"'])})`,
  () => `.slice(${pick(['4', '8'])}, \"${pick(['0 2', '0 [1 3] 2', '<0 1> 2 3'])}\")`,
  () => `.bite(${pick(['2', '4'])}, \"${pick(['0 1', '1 0 [2 3]', '<0 1> 2'])}\")`,
  () => `.loopAt(${pick(['1', '2', '\"<1 2>\"'])})`, () => '.fit()',
  () => `.gain(perlin)`, () => `.pan(berlin)`, () => `.gain(choose(0.2, 0.5, 1))`,
];
const starts = [
  () => `s("${seq()}")`, () => `n("${seq()}")`, () => `note("${seq()}")`,
  () => `s("${seq()}").n("${seq(2)}")`, () => `"${seq()}"`,
];

const V02 = process.argv.includes('--v02');
const lines = ['# generated by reference/fuzz.mjs -- do not edit'];
if (!V02) for (let i = 0; i < 350; i++) lines.push(`"${seq()}"`);
for (let i = 0; i < (V02 ? 300 : 250); i++) {
  const st = V02 ? pick(starts.slice(0, 4)) : pick(starts);
  let s = st();
  const raw = s.startsWith('"');          // plain values: skip the methods that need control maps
  const k = int(1, 3);
  for (let j = 0; j < k; j++) {
    let m;
    do { m = pick(V02 ? methodsV02 : methods)(); } while (raw && /gain|speed|jux|hurry|echo|stut|add\(n/.test(m));
    s += m;
  }
  lines.push(s);
}
fs.writeFileSync(path.join(here, V02 ? '../test/cases_fuzz_v02.txt' : '../test/cases_fuzz.txt'), lines.join('\n') + '\n');
console.log('wrote', lines.length - 1, 'fuzz cases');
