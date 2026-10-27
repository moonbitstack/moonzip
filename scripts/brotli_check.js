// Check moonzip's brotli streams against libbrotli, which is what Node's `zlib`
// module is.
//
//     moon run src/examples/vectors | node scripts/brotli_check.js
//
// Python has no brotli in its standard library, so the half of the conformance
// check that lives in `conformance.py` cannot cover this format. Node 22 bundles
// libbrotli behind `zlib.brotliCompressSync`, which makes `node` the judge -- the
// same two-way arrangement every other format here has, with a different referee.

const zlib = require('zlib');

const lines = require('fs').readFileSync(0, 'utf8').split('\n');
let checked = 0;
let failed = 0;
for (const line of lines) {
  const parts = line.trim().split(/\s+/);
  if (parts[0] !== 'brotli') continue;
  const kind = parts[1];
  const window = parts[2];
  const want = Number(parts[3]) >>> 0;
  const blob = Buffer.from(parts[4], 'hex');
  try {
    const out = zlib.brotliDecompressSync(blob);
    const got = zlib.crc32(out) >>> 0;
    if (got !== want) {
      failed++;
      console.log(`FAIL brotli ${kind} window=${window}: crc ${got} not ${want}`);
      continue;
    }
    checked++;
  } catch (e) {
    failed++;
    console.log(`FAIL brotli ${kind} window=${window}: ${e.message}`);
  }
}
console.log(`brotli: ${checked} streams read back by libbrotli, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
