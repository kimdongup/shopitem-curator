// Download only the Korean/symbol fallback assets referenced by the pinned SDK.
// Font bytes are unmodified; licenses live alongside them in web/font-fallback.
const fs = require('node:fs');
const path = require('node:path');
const {execFileSync} = require('node:child_process');
const sdk = process.argv[2];
if (!sdk) throw new Error('Usage: node tool/vendor_flutter_fonts.cjs /path/to/flutter');
const source = fs.readFileSync(path.join(sdk,
  'bin/cache/flutter_web_sdk/lib/_engine/engine/font_fallback_data.dart'), 'utf8');
const files = [...new Set([...source.matchAll(/'(notosans(?:kr|symbols2)\/v\d+\/[A-Za-z0-9_.-]+\.woff2)'/g)].map(match => match[1]))];
if (files.length !== 130) throw new Error('Pinned Flutter 3.47.2 fallback font list changed; review before vendoring.');
for (const file of files) {
  const destination = path.join('web/font-fallback', file);
  fs.mkdirSync(path.dirname(destination), {recursive: true});
  execFileSync('curl', ['--fail', '--silent', '--show-error', '--location', '--proto', '=https',
    '--max-time', '30', 'https://fonts.gstatic.com/s/' + file, '-o', destination]);
  if (fs.readFileSync(destination).subarray(0, 4).toString() !== 'wOF2') throw new Error('Invalid font download.');
}
console.log(`Vendored ${files.length} unmodified fallback fonts.`);
