#!/usr/bin/env node
// validate-beforeafter.js — L-I4 device-free validator for the before/after wipe-compositor
// test-vector corpus (host/shared/test-vectors/beforeafter-vectors.json).
//
// The corpus is the SINGLE source of truth that BOTH hand-written hosts run against. Both the Android
// BeforeAfterView and the iOS CanopyBeforeAfterView delegate their numeric rules to ONE shared header,
// host/shared/cpp/CanopyBeforeAfter.h, so they cannot drift; the two host runners
// (CanopyBeforeAfterVectorTest [emulator, via JNI into the real header] and
// CanopyBeforeAfterVectorTests.mm [Simulator, the real ObjC++ view path]) assert the corpus on device.
// Neither host can run on this Linux build box. So this validator is the CI-cheap, device-free guard
// that the corpus itself is well-formed AND that every expected value is reproduced by an INDEPENDENT,
// from-scratch reimplementation of the same math (NOT the shared header — a second implementation, so
// a corpus typo cannot agree with itself). A wrong expected value fails here, on Linux, long before a
// device run.
//
//   (1) STRUCTURAL: every vector has the required shape, ids are unique across all sets.
//   (2) ORACLE: an independent JS reimplementation of clamp / split / drag / snap-target / snap-eased
//       / snap-tween / cover-rect / commit-payload reproduces every `expect`. The %g payload formatter
//       is reimplemented here (6 significant digits, trailing zeros stripped) and is the one piece most
//       likely to drift between the two hosts (Java toString vs C printf %g) — so it is asserted hard.
//
// Exit 0 = corpus internally consistent and every expected value reproduced by the independent oracle.
// Exit 1 = a malformed vector or a wrong expected value (with a diff).
//
// Run:  node host/shared/test-vectors/validate-beforeafter.js
'use strict';

const fs = require('fs');
const path = require('path');

const CORPUS = path.join(__dirname, 'beforeafter-vectors.json');

let failures = 0;
const fail = (msg) => { console.error('  FAIL — ' + msg); failures++; };
const ok = (msg) => { console.log('  OK   — ' + msg); };

// ---------------------------------------------------------------------------------------------
// The INDEPENDENT oracle: a second implementation of canopy::beforeafter::*. Deliberately NOT a port
// of the header — written from the contract so it cannot rubber-stamp a header/corpus co-typo.
// ---------------------------------------------------------------------------------------------

function clampFraction(f) {
  if (f < 0) return 0;
  if (f > 1) return 1;
  return f;
}

// round(clamp(wipe)*width) — round half away from zero (Math.round in Java, std::lround in C++).
// JS Math.round rounds half toward +Infinity, which equals round-half-away-from-zero for the
// non-negative products this function ever sees (wipe and width are both >= 0 after clamping).
function splitColumn(wipe, width) {
  return Math.round(clampFraction(wipe) * width);
}

function dragFraction(x, width) {
  if (width <= 0) return 0;
  return clampFraction(x / width);
}

function snapTarget(wipe) {
  return wipe >= 0.5 ? 0 : 1;
}

function snapEased(t) {
  if (t < 0) t = 0;
  if (t > 1) t = 1;
  const inv = 1 - t;
  return 1 - inv * inv;
}

function snapValue(from, to, elapsed, duration) {
  const t = duration > 0 ? elapsed / duration : 1;
  const eased = snapEased(t);
  return from + (to - from) * eased;
}

function coverRect(viewW, viewH, bmpW, bmpH) {
  if (viewW <= 0 || viewH <= 0 || bmpW <= 0 || bmpH <= 0) {
    return { left: 0, top: 0, width: 0, height: 0 };
  }
  const scale = Math.max(viewW / bmpW, viewH / bmpH);
  const dw = bmpW * scale;
  const dh = bmpH * scale;
  return { left: (viewW - dw) / 2, top: (viewH - dh) / 2, width: dw, height: dh };
}

// An independent reimplementation of C's printf %g (default precision 6 significant digits, trailing
// zeros and a trailing '.' stripped, no exponent for the small in-range magnitudes the wipe uses).
// This is the exact wire format both hosts must emit; reproducing it here from scratch is what makes
// the payload vectors a real anti-drift check rather than an echo.
function formatG(v) {
  if (v === 0) return '0';
  // %g picks %e or %f by exponent; for fractions in [0,1] the exponent is <= 0 and > -5, so %g always
  // uses fixed notation with 6 significant digits. Compute significant-digit rounding directly.
  const sign = v < 0 ? '-' : '';
  const a = Math.abs(v);
  const exp = Math.floor(Math.log10(a));        // position of the most-significant digit
  const decimals = Math.max(0, 6 - 1 - exp);    // digits after the point for 6 sig-figs
  let s = a.toFixed(decimals);
  if (s.indexOf('.') >= 0) {
    s = s.replace(/0+$/, '').replace(/\.$/, '');  // strip trailing zeros, then a dangling point
  }
  return sign + s;
}

function commitPayloadJson(fraction) {
  return '{"fraction":' + formatG(clampFraction(fraction)) + '}';
}

// ---------------------------------------------------------------------------------------------

function approx(a, b, tol) { return Math.abs(a - b) <= tol; }

function main() {
  console.log('==> L-I4 before/after wipe-compositor test-vector corpus validator\n');
  const corpus = JSON.parse(fs.readFileSync(CORPUS, 'utf8'));
  const tol = corpus.tolerance != null ? corpus.tolerance : 0.0001;
  const dur = corpus.snapDurationSeconds != null ? corpus.snapDurationSeconds : 0.26;

  // -- ids unique across every section --
  const ids = new Set();
  const sets = ['clampVectors', 'splitVectors', 'dragVectors', 'snapTargetVectors',
                'snapEasedVectors', 'snapTweenVectors', 'coverVectors', 'payloadVectors'];
  let total = 0;
  for (const setName of sets) {
    for (const v of (corpus[setName] || [])) {
      total++;
      if (!v.id) fail(`a vector in ${setName} has no id`);
      else if (ids.has(v.id)) fail(`duplicate vector id '${v.id}'`);
      else ids.add(v.id);
    }
  }
  if (ids.size === total) ok(`${total} vectors, all ids unique`);

  console.log('\n-- clamp vectors (clampFraction):');
  for (const v of (corpus.clampVectors || [])) {
    const got = clampFraction(v.input);
    if (approx(got, v.expect, tol)) ok(`${v.id} (${v.input} -> ${got})`);
    else fail(`${v.id}: clamp(${v.input}) expected ${v.expect} got ${got}`);
  }

  console.log('\n-- split vectors (splitColumn = round(clamp(wipe)*width)):');
  for (const v of (corpus.splitVectors || [])) {
    const got = splitColumn(v.wipe, v.width);
    if (got === v.expect) ok(`${v.id} (wipe ${v.wipe} × w ${v.width} -> ${got})`);
    else fail(`${v.id}: splitColumn(${v.wipe},${v.width}) expected ${v.expect} got ${got}`);
  }

  console.log('\n-- drag vectors (dragFraction = clamp01(x/width)):');
  for (const v of (corpus.dragVectors || [])) {
    const got = dragFraction(v.x, v.width);
    if (approx(got, v.expect, tol)) ok(`${v.id} (x ${v.x} / w ${v.width} -> ${got})`);
    else fail(`${v.id}: dragFraction(${v.x},${v.width}) expected ${v.expect} got ${got}`);
  }

  console.log('\n-- snap-target vectors ((wipe>=0.5)?0:1):');
  for (const v of (corpus.snapTargetVectors || [])) {
    const got = snapTarget(v.wipe);
    if (got === v.expect) ok(`${v.id} (from ${v.wipe} -> ${got})`);
    else fail(`${v.id}: snapTarget(${v.wipe}) expected ${v.expect} got ${got}`);
  }

  console.log('\n-- snap-eased vectors (1-(1-t)^2):');
  for (const v of (corpus.snapEasedVectors || [])) {
    const got = snapEased(v.t);
    if (approx(got, v.expect, tol)) ok(`${v.id} (t ${v.t} -> ${got})`);
    else fail(`${v.id}: snapEased(${v.t}) expected ${v.expect} got ${got}`);
  }

  console.log('\n-- snap-tween vectors (snapValue over the shared duration):');
  for (const v of (corpus.snapTweenVectors || [])) {
    const got = snapValue(v.from, v.to, v.elapsed, dur);
    if (approx(got, v.expect, tol)) ok(`${v.id} (${v.from}->${v.to} @${v.elapsed}s -> ${got})`);
    else fail(`${v.id}: snapValue(${v.from},${v.to},${v.elapsed}) expected ${v.expect} got ${got}`);
  }

  console.log('\n-- cover vectors (center-crop cover rect):');
  for (const v of (corpus.coverVectors || [])) {
    const got = coverRect(v.viewW, v.viewH, v.bmpW, v.bmpH);
    const e = v.expect;
    if (approx(got.left, e.left, tol) && approx(got.top, e.top, tol) &&
        approx(got.width, e.width, tol) && approx(got.height, e.height, tol)) {
      ok(`${v.id}`);
    } else {
      fail(`${v.id}: cover expected ${JSON.stringify(e)} got ${JSON.stringify(got)}`);
    }
  }

  console.log('\n-- payload vectors (commitPayloadJson — the exact wipeCommit wire bytes):');
  for (const v of (corpus.payloadVectors || [])) {
    const got = commitPayloadJson(v.fraction);
    if (got === v.expect) ok(`${v.id} (${v.fraction} -> ${got})`);
    else fail(`${v.id}: commitPayloadJson(${v.fraction}) expected '${v.expect}' got '${got}'`);
  }

  console.log('');
  if (failures === 0) {
    console.log('ALL GREEN — the before/after wipe-compositor corpus is well-formed and every expected');
    console.log('            value is reproduced by an independent oracle.');
    process.exit(0);
  } else {
    console.error(`CORPUS INVALID — ${failures} problem(s). Fix beforeafter-vectors.json (the single source of truth).`);
    process.exit(1);
  }
}

main();
