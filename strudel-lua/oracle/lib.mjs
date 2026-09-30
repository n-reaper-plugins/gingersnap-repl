// Oracle: real Strudel core+mini (AGPL-3.0-or-later), loaded WITHOUT the repl/audio parts.
import * as pattern from './node_modules/@strudel/core/pattern.mjs';
import * as signal from './node_modules/@strudel/core/signal.mjs';
import * as euclid from './node_modules/@strudel/core/euclid.mjs';
import * as controls from './node_modules/@strudel/core/controls.mjs';
import * as pick from './node_modules/@strudel/core/pick.mjs';
import * as util from './node_modules/@strudel/core/util.mjs';
import * as mini from './node_modules/@strudel/mini/mini.mjs';
import Fraction from './node_modules/@strudel/core/fraction.mjs';

export const scope = { ...pattern, ...signal, ...euclid, ...controls, ...pick, ...mini, Fraction };
export { Fraction, mini, pattern, util };

// string literals -> mini("...") like the real transpiler does
export function transpile(code) {
  return code.replace(/"((?:[^"\\]|\\.)*)"/g, (_, s) => `mini("${s}")`);
}
export function evaluate(code) {
  const names = Object.keys(scope);
  const fn = new Function(...names, `return (${transpile(code)});`);
  return fn(...names.map((n) => scope[n]));
}
const fr = (x) => (x === undefined || x === null ? null : x.toFraction());
export function haps(pat, from, to, onsetsOnly = true) {
  let hs = pat.queryArc(from, to);
  if (onsetsOnly) hs = hs.filter((h) => h.hasOnset());
  return hs.map((h) => ({
    b: fr(h.whole.begin), e: fr(h.whole.end), v: h.value,
  })).sort((a, b) => {
    const A = eval(a.b), B = eval(b.b); if (A !== B) return A - B;
    return JSON.stringify(a.v) < JSON.stringify(b.v) ? -1 : 1;
  });
}
