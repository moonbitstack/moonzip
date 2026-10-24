#!/usr/bin/env node
// Check moonzip's zstd frames against libzstd, which is what Node's `zlib` is.
//
//     moon run examples/vectors --target native | node scripts/zstd_check.js
//
// Python has no zstd, so the half of the conformance check that lives in
// `conformance.py` cannot cover this format. Node 22 ships the reference
// implementation, which makes `node` the judge instead — the same two-way
// arrangement every other format here has, with a different referee.

const zlib = require('zlib');

const lines = require('fs').readFileSync(0, 'utf8').split('\n');
let checked = 0;
let failed = 0;
for (const line of lines) {
  const parts = line.trim().split(/\s+/);
  if (parts[0] !== 'zstd') continue;
  const kind = parts[1];
  const level = parts[2];
  const want = Number(parts[3]) >>> 0;
  const blob = Buffer.from(parts[4], 'hex');
  try {
    const out = zlib.zstdDecompressSync(blob);
    const got = zlib.crc32(out) >>> 0;
    if (got !== want) {
      failed++;
      console.log(`FAIL zstd ${kind} level=${level}: crc ${got} not ${want}`);
      continue;
    }
    checked++;
  } catch (error) {
    failed++;
    console.log(`FAIL zstd ${kind} level=${level}: ${error.message}`);
  }
}
console.log(`${checked + failed} zstd frames checked, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
