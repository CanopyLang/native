#!/usr/bin/env node
// run-fuzz-corpus.js — REL-5: replay the PERSISTED reconciler fuzz corpus as a deterministic
// per-commit regression set.
//
// run-stress.js fuzzes the reconciler with a TIME-DERIVED base seed (great for discovery, but every
// CI run exercises different sequences, so a once-seen failure can vanish). This harness pins a fixed
// floor: it runs `run-stress.js --seed N --quick` for each seed in fuzz-corpus/reconciler-seeds.json,
// so those exact mutation sequences are replayed on EVERY commit. Zero changes to run-stress.js (it
// already accepts --seed N for reproducibility) — when a discovery run finds a failing seed, add it
// to the corpus and it becomes a permanent regression case.
'use strict';
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const corpus = JSON.parse(fs.readFileSync(path.join(__dirname, 'fuzz-corpus', 'reconciler-seeds.json'), 'utf8'));
const seeds = corpus.seeds || [];
const stress = path.join(__dirname, 'run-stress.js');

console.log('==> replay reconciler fuzz corpus (REL-5): ' + seeds.length + ' pinned seeds');
let fail = 0;
for (const s of seeds) {
  const r = spawnSync(process.execPath, [stress, '--seed', String(s), '--quick'], { encoding: 'utf8' });
  if (r.status === 0) {
    process.stdout.write('  \x1b[32m✓\x1b[0m seed ' + s + '\n');
  } else {
    fail = 1;
    process.stderr.write('  \x1b[31m✗ seed ' + s + ' FAILED (status ' + r.status + ')\x1b[0m\n');
    // Surface the failing assertions from the child so the regression is diagnosable in CI logs.
    const tail = (r.stdout || '').split('\n').filter(l => /✗|FAIL|seed=/.test(l)).slice(-8).join('\n');
    if (tail) process.stderr.write(tail + '\n');
    if (r.stderr) process.stderr.write(r.stderr.split('\n').slice(-4).join('\n') + '\n');
  }
}
console.log(fail ? '\nreconciler corpus FAILED — a pinned regression seed broke.' : '\nreconciler corpus OK — all pinned seeds pass.');
process.exit(fail);
