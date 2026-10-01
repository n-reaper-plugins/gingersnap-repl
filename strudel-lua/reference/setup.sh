#!/usr/bin/env bash
# Installs REAL Strudel (@strudel/core + @strudel/mini, AGPL-3.0-or-later) next to this file, headless, so it can
# be used as the reference in the tests. Needs node + npm and network access. Nothing here is shipped with the plugin.
set -e
cd "$(dirname "$0")"
[ -f package.json ] || echo '{"name":"strudel-reference","private":true,"type":"module"}' > package.json
npm install --no-audit --no-fund @strudel/core@1.2.6 @strudel/mini@1.2.6 @strudel/tonal@1.2.6
C=node_modules/@strudel/core
# the published bundle imports browser-only audio code; load the plain source files instead
cat > $C/shim.mjs <<'EOS'
export * from './pattern.mjs';
export * from './signal.mjs';
export * from './euclid.mjs';
export * from './controls.mjs';
export * from './pick.mjs';
export * from './hap.mjs';
export * from './timespan.mjs';
export * from './util.mjs';
export * from './logger.mjs';
export { default as Fraction } from './fraction.mjs';
EOS
sed -i 's#"main": "dist/index.mjs"#"main": "shim.mjs"#' $C/package.json
echo "reference ready. Regenerate the golden data with:  node reference/gen.mjs   (from strudel-lua/)"
# the published @tonaljs packages point "main" at a file that does not exist (only dist/index.cjs is shipped): fix them (also nested copies)
find node_modules -path '*@tonaljs/*/package.json' | while read -r p; do
  d=$(dirname "$p")
  if [ -f "$d/dist/index.cjs" ] && [ ! -f "$d/dist/index.js" ]; then sed -i 's#"main": "dist/index.js"#"main": "dist/index.cjs"#' "$p"; fi
done
