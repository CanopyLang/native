#!/usr/bin/env node
// validate-vectors.js — IOS-9 device-free validator for the cross-platform layout/style test-vector
// corpus (host/shared/test-vectors/layout-vectors.json).
//
// The corpus is the SINGLE source of truth that BOTH hand-written hosts run against (the Android
// instrumentation runner CanopyLayoutVectorTest.java drives real Yoga on a device; the iOS XCTest
// runner CanopyLayoutVectorTests.mm drives real Yoga on a Simulator). Neither host can run on this
// Linux build box. So this validator is the CI-cheap, device-free guard that the corpus itself is
// well-formed and self-consistent BEFORE either host runs it:
//
//   (1) STRUCTURAL: every vector has the required shape (id, root, tree/expect), ids are unique,
//       every styled node carries an `expect` frame, and dims stay integral under the declared
//       density sweep so the deliberate Android(px)/iOS(points) divergence normalizes EXACTLY with
//       no sub-pixel rounding gap (the IOS-9 "normalize the divergence" requirement).
//   (2) ORACLE: it lays out every layoutVector with an INDEPENDENT, from-scratch flexbox-subset
//       engine (NOT Yoga — a second implementation, so a corpus typo cannot agree with itself) and
//       asserts the engine's frames match the corpus `expect`. A corpus whose expected frames are
//       wrong fails here, on Linux, long before a device run. The supported subset is exactly the
//       keys the layoutVectors use (see SUPPORTED below); any vector using an unsupported key is a
//       hard error so the corpus can never silently outgrow the oracle.
//   (3) COLOR + STYLE: the color vectors are checked against a faithful CSS color reference (the
//       same contract CanopyColor.mm / parseColor on Android implement); the style-effect vectors
//       are checked for shape (the per-host effect assertions live in the runners).
//
// Exit 0 = corpus is internally consistent and every expected frame/color is reproduced by the
//          independent oracle. Exit 1 = a malformed vector or a wrong expected value (with a diff).
//
// Run:  node host/shared/test-vectors/validate-vectors.js
'use strict';

const fs = require('fs');
const path = require('path');

const CORPUS = path.join(__dirname, 'layout-vectors.json');
const TOL = 0.01;

let failures = 0;
const fail = (msg) => { console.error('  FAIL — ' + msg); failures++; };
const ok = (msg) => { console.log('  OK   — ' + msg); };

// ---------------------------------------------------------------------------------------------
// (2) The INDEPENDENT flexbox-subset layout oracle. Deliberately a second implementation of the
// CSS-flexbox subset the corpus uses, so it cannot rubber-stamp a corpus typo. It supports exactly:
//   width/height (px or "N%"), min/maxWidth/Height, padding[/Top/.../Horizontal/Vertical],
//   margin[...], flexDirection (column/row), justifyContent (flex-start/center/flex-end/
//   space-between), alignItems/alignSelf (stretch/flex-start/center/flex-end), flexGrow, gap,
//   position absolute + top/left, display none.
// Frames are computed in a single logical unit (no density — the corpus is already logical).
// ---------------------------------------------------------------------------------------------

const SUPPORTED = new Set([
  'width', 'height', 'minWidth', 'minHeight', 'maxWidth', 'maxHeight',
  'padding', 'paddingTop', 'paddingBottom', 'paddingLeft', 'paddingRight',
  'paddingHorizontal', 'paddingVertical',
  'margin', 'marginTop', 'marginBottom', 'marginLeft', 'marginRight',
  'marginHorizontal', 'marginVertical',
  'flexDirection', 'justifyContent', 'alignItems', 'alignSelf',
  'flex', 'flexGrow', 'gap', 'position', 'top', 'left', 'right', 'bottom', 'display',
]);

function num(v) { return typeof v === 'number' ? v : (typeof v === 'string' && v.endsWith('%') ? null : parseFloat(v)); }
function pct(v, base) { return (typeof v === 'string' && v.endsWith('%')) ? (parseFloat(v) / 100) * base : null; }

function edge(style, base, side) {
  // side in {top,bottom,left,right}; resolves base/{H,V}/per-edge in CSS precedence order.
  const horiz = side === 'left' || side === 'right';
  let v = 0;
  if (style[base] != null) v = num(style[base]);
  if (style[base + (horiz ? 'Horizontal' : 'Vertical')] != null) v = num(style[base + (horiz ? 'Horizontal' : 'Vertical')]);
  const cap = side.charAt(0).toUpperCase() + side.slice(1);
  if (style[base + cap] != null) v = num(style[base + cap]);
  return v || 0;
}

function clampDim(v, style, axis) {
  const minK = axis === 'w' ? 'minWidth' : 'minHeight';
  const maxK = axis === 'w' ? 'maxWidth' : 'maxHeight';
  if (style[maxK] != null && v > num(style[maxK])) v = num(style[maxK]);
  if (style[minK] != null && v < num(style[minK])) v = num(style[minK]);
  return v;
}

// Lay out `node` into the parent content box (availW x availH at content origin). Mutates node.frame
// (left/top relative to the parent content box, width/height). Returns the node's outer main-axis size.
function layout(node, availW, availH) {
  const s = node.style || {};
  for (const k of Object.keys(s)) {
    if (!SUPPORTED.has(k)) throw new Error(`vector uses unsupported style key '${k}' (oracle would silently skip it)`);
  }
  if (s.display === 'none') { node.frame = { left: 0, top: 0, width: 0, height: 0 }; return { collapsed: true }; }

  // Resolve this node's own box from explicit width/height or %.
  let w = s.width != null ? (pct(s.width, availW) != null ? pct(s.width, availW) : num(s.width)) : null;
  let h = s.height != null ? (pct(s.height, availH) != null ? pct(s.height, availH) : num(s.height)) : null;

  // Padding insets the content box for children.
  const pl = edge(s, 'padding', 'left'), pr = edge(s, 'padding', 'right');
  const pt = edge(s, 'padding', 'top'), pb = edge(s, 'padding', 'bottom');

  const row = s.flexDirection === 'row' || s.flexDirection === 'row-reverse';
  const allKids = node.children || [];
  // display:none children collapse to a zero frame and leave the flow entirely (no reserved space).
  for (const c of allKids) {
    if ((c.style || {}).display === 'none') c.frame = { left: 0, top: 0, width: 0, height: 0 };
  }
  const inFlow = allKids.filter((c) => (c.style || {}).display !== 'none');
  const children = inFlow.filter((c) => (c.style || {}).position !== 'absolute');
  const absChildren = inFlow.filter((c) => (c.style || {}).position === 'absolute');

  // Determine this node's resolved size. For the root it is given; for children with no explicit
  // size it may be stretched/grown by the parent (handled by the parent), so default to avail.
  let myW = w != null ? w : availW;
  let myH = h != null ? h : availH;
  myW = clampDim(myW, s, 'w');
  myH = clampDim(myH, s, 'h');

  const contentW = myW - pl - pr;
  const contentH = myH - pt - pb;
  const mainSize = row ? contentW : contentH;
  const crossSize = row ? contentH : contentW;
  const gap = s.gap != null ? num(s.gap) : 0;

  // First pass: each in-flow child's base main-axis size (explicit dim, else 0 for flexGrow nodes).
  const metrics = children.map((c) => {
    const cs = c.style || {};
    const mMainStart = row ? edge(cs, 'margin', 'left') : edge(cs, 'margin', 'top');
    const mMainEnd = row ? edge(cs, 'margin', 'right') : edge(cs, 'margin', 'bottom');
    let base;
    if (row) base = cs.width != null ? (pct(cs.width, contentW) != null ? pct(cs.width, contentW) : num(cs.width)) : 0;
    else base = cs.height != null ? (pct(cs.height, contentH) != null ? pct(cs.height, contentH) : num(cs.height)) : 0;
    const grow = cs.flex != null ? num(cs.flex) : (cs.flexGrow != null ? num(cs.flexGrow) : 0);
    return { c, cs, base: base || 0, grow, mMainStart, mMainEnd };
  });

  const totalGap = metrics.length > 0 ? gap * (metrics.length - 1) : 0;
  const usedBase = metrics.reduce((a, m) => a + m.base + m.mMainStart + m.mMainEnd, 0) + totalGap;
  const freeSpace = mainSize - usedBase;
  const totalGrow = metrics.reduce((a, m) => a + m.grow, 0);

  // Distribute free space to flexGrow children (clamped by max on the main axis).
  for (const m of metrics) {
    let size = m.base;
    if (totalGrow > 0 && freeSpace > 0 && m.grow > 0) size = m.base + (freeSpace * m.grow) / totalGrow;
    size = clampDim(size, m.cs, row ? 'w' : 'h');
    m.mainResolved = size;
  }

  // justifyContent → leading offset + inter-item spacing.
  const justify = s.justifyContent || 'flex-start';
  const consumed = metrics.reduce((a, m) => a + m.mainResolved + m.mMainStart + m.mMainEnd, 0) + totalGap;
  const slack = mainSize - consumed;
  let leading = 0, between = gap;
  if (justify === 'center') leading = slack / 2;
  else if (justify === 'flex-end') leading = slack;
  else if (justify === 'space-between' && metrics.length > 1) between = gap + slack / (metrics.length - 1);

  // Place children.
  let cursor = leading;
  const align = s.alignItems || 'stretch';
  for (const m of metrics) {
    const cs = m.cs;
    cursor += m.mMainStart;
    // Cross-axis size: explicit dim, else stretch fills cross, else 0 → content (we treat as 0 for
    // pure containers; the corpus always gives leaf cross dims or relies on stretch).
    const selfAlign = (cs.alignSelf && cs.alignSelf !== 'auto') ? cs.alignSelf : align;
    let crossDim;
    if (row) crossDim = cs.height != null ? (pct(cs.height, crossSize) != null ? pct(cs.height, crossSize) : num(cs.height)) : null;
    else crossDim = cs.width != null ? (pct(cs.width, crossSize) != null ? pct(cs.width, crossSize) : num(cs.width)) : null;
    const mCrossStart = row ? edge(cs, 'margin', 'top') : edge(cs, 'margin', 'left');
    const mCrossEnd = row ? edge(cs, 'margin', 'bottom') : edge(cs, 'margin', 'right');
    let crossResolved;
    if (crossDim != null) crossResolved = crossDim;
    else if (selfAlign === 'stretch') crossResolved = crossSize - mCrossStart - mCrossEnd;
    else crossResolved = 0;
    crossResolved = clampDim(crossResolved, cs, row ? 'h' : 'w');

    let crossOffset = mCrossStart;
    if (crossDim != null || selfAlign !== 'stretch') {
      if (selfAlign === 'center') crossOffset = mCrossStart + (crossSize - mCrossStart - mCrossEnd - crossResolved) / 2;
      else if (selfAlign === 'flex-end') crossOffset = crossSize - mCrossEnd - crossResolved;
    }

    const mainStart = cursor;
    // Recurse: a child's own children lay out in ITS content box.
    const childW = row ? m.mainResolved : crossResolved;
    const childH = row ? crossResolved : m.mainResolved;
    m.c.frame = {
      left: pl + (row ? mainStart : crossOffset),
      top: pt + (row ? crossOffset : mainStart),
      width: childW,
      height: childH,
    };
    if (m.c.children && m.c.children.length) layoutInPlace(m.c, childW, childH);
    cursor += m.mainResolved + m.mMainEnd + between;
  }

  // Absolute children: positioned by top/left within the parent content box, out of flow.
  for (const c of absChildren) {
    const cs = c.style || {};
    const cw = cs.width != null ? num(cs.width) : 0;
    const ch = cs.height != null ? num(cs.height) : 0;
    c.frame = {
      left: pl + (cs.left != null ? num(cs.left) : 0),
      top: pt + (cs.top != null ? num(cs.top) : 0),
      width: cw,
      height: ch,
    };
    if (c.children && c.children.length) layoutInPlace(c, cw, ch);
  }

  node.frame = node.frame || { left: 0, top: 0, width: myW, height: myH };
  node._size = { width: myW, height: myH };
  return { width: myW, height: myH };
}

// Lay out a node's children into its content box without changing the node's own frame.
function layoutInPlace(node, w, h) {
  const saved = node.frame;
  layout(node, w, h);
  node.frame = saved; // keep the frame the parent already assigned
}

function runOracle(v) {
  const root = JSON.parse(JSON.stringify(v.tree));
  const rs = root.style || {};
  // The root is laid out in the available surface (v.root). Its OWN frame is its resolved size:
  // an explicit width/height on the root takes that size (a fixed-size leaf root); otherwise it
  // fills the available surface. This mirrors a Yoga root sized by YGNodeCalculateLayout(avail).
  layout(root, v.root.width, v.root.height);
  const rootW = rs.width != null ? (pct(rs.width, v.root.width) != null ? pct(rs.width, v.root.width) : num(rs.width)) : v.root.width;
  const rootH = rs.height != null ? (pct(rs.height, v.root.height) != null ? pct(rs.height, v.root.height) : num(rs.height)) : v.root.height;
  root.frame = { left: 0, top: 0, width: clampDim(rootW, rs, 'w'), height: clampDim(rootH, rs, 'h') };
  return root;
}

function approx(a, b) { return Math.abs(a - b) <= TOL; }

function compareFrames(node, prefix, vid) {
  const e = node.expect;
  if (e) {
    const f = node.frame;
    for (const k of ['left', 'top', 'width', 'height']) {
      if (!approx(f[k], e[k])) {
        fail(`${vid} ${prefix}: ${k} expected ${e[k]} but oracle computed ${f[k]}`);
      }
    }
  }
  const kids = node.children || [];
  for (let i = 0; i < kids.length; i++) compareFrames(kids[i], `${prefix}/${i}`, vid);
}

// ---------------------------------------------------------------------------------------------
// (3) The CSS color reference (the CanopyColor contract: #rgb/#rgba/#rrggbb/#rrggbbaa CSS-alpha-last,
// rgb()/rgba(), hsl(), the named subset the corpus uses, transparent). A SECOND implementation so a
// corpus color typo cannot self-agree.
// ---------------------------------------------------------------------------------------------
const NAMED = { black: [0, 0, 0, 1], white: [255, 255, 255, 1], transparent: [0, 0, 0, 0] };
function clampi(x) { return x < 0 ? 0 : x > 255 ? 255 : Math.round(x); }
function hx(h, a, b) { return parseInt(h.substring(a, b), 16); }
function parseColor(input) {
  let s = String(input).trim();
  if (NAMED[s]) { const n = NAMED[s]; return { r: n[0], g: n[1], b: n[2], a: n[3] }; }
  if (s[0] === '#') {
    const h = s.slice(1);
    if (h.length === 3) return { r: hx(h, 0, 1) * 17, g: hx(h, 1, 2) * 17, b: hx(h, 2, 3) * 17, a: 1 };
    if (h.length === 4) return { r: hx(h, 0, 1) * 17, g: hx(h, 1, 2) * 17, b: hx(h, 2, 3) * 17, a: (hx(h, 3, 4) * 17) / 255 };
    if (h.length === 6) return { r: hx(h, 0, 2), g: hx(h, 2, 4), b: hx(h, 4, 6), a: 1 };
    if (h.length === 8) return { r: hx(h, 0, 2), g: hx(h, 2, 4), b: hx(h, 4, 6), a: hx(h, 6, 8) / 255 };
    return { r: 0, g: 0, b: 0, a: 0 };
  }
  let m = s.match(/^rgba?\(([^)]+)\)$/);
  if (m) {
    const p = m[1].split(',').map((x) => x.trim());
    return { r: clampi(+p[0]), g: clampi(+p[1]), b: clampi(+p[2]), a: p[3] != null ? +p[3] : 1 };
  }
  m = s.match(/^hsla?\(([^)]+)\)$/);
  if (m) {
    const p = m[1].split(',').map((x) => x.trim());
    const hDeg = ((+p[0] % 360) + 360) % 360, sat = parseFloat(p[1]) / 100, lig = parseFloat(p[2]) / 100;
    const c = (1 - Math.abs(2 * lig - 1)) * sat, hp = hDeg / 60, x = c * (1 - Math.abs((hp % 2) - 1));
    let r1 = 0, g1 = 0, b1 = 0;
    if (hp < 1) { r1 = c; g1 = x; } else if (hp < 2) { r1 = x; g1 = c; } else if (hp < 3) { g1 = c; b1 = x; }
    else if (hp < 4) { g1 = x; b1 = c; } else if (hp < 5) { r1 = x; b1 = c; } else { r1 = c; b1 = x; }
    const mm = lig - c / 2;
    return { r: clampi((r1 + mm) * 255), g: clampi((g1 + mm) * 255), b: clampi((b1 + mm) * 255), a: p[3] != null ? +p[3] : 1 };
  }
  return { r: 0, g: 0, b: 0, a: 0 };
}

// ---------------------------------------------------------------------------------------------
// (1) Structural checks: integral under the density sweep, unique ids, every styled node expects.
// ---------------------------------------------------------------------------------------------
function walkExpects(node, densities, vid) {
  if (node.expect) {
    for (const k of ['left', 'top', 'width', 'height']) {
      const val = node.expect[k];
      for (const d of densities) {
        const px = val * d;
        if (Math.abs(px - Math.round(px)) > 1e-6) {
          fail(`${vid}: expected ${k}=${val} is not integral at density ${d} (px=${px}); pick dims that survive *density and /density so the divergence normalizes exactly`);
        }
      }
    }
  } else {
    fail(`${vid}: a node has no 'expect' frame (every node in a layoutVector must declare its expected frame)`);
  }
  for (const c of (node.children || [])) walkExpects(c, densities, vid);
}

function main() {
  console.log('==> IOS-9 cross-platform test-vector corpus validator (host/shared/test-vectors)\n');
  const corpus = JSON.parse(fs.readFileSync(CORPUS, 'utf8'));
  const densities = corpus.densities || [1.0];

  // -- ids unique across every section --
  const ids = new Set();
  const allVecs = [...(corpus.colorVectors || []), ...(corpus.layoutVectors || []), ...(corpus.styleEffectVectors || [])];
  for (const v of allVecs) {
    if (!v.id) fail('a vector has no id');
    else if (ids.has(v.id)) fail(`duplicate vector id '${v.id}'`);
    else ids.add(v.id);
  }
  if (ids.size === allVecs.length) ok(`${ids.size} vectors, all ids unique`);

  // -- color vectors: independent CSS reference reproduces every expected color --
  console.log('\n-- color vectors (CSS color contract):');
  for (const v of (corpus.colorVectors || [])) {
    const got = parseColor(v.input);
    const e = v.expect;
    if (got.r === e.r && got.g === e.g && got.b === e.b && approx(got.a, e.a)) ok(`${v.id} (${v.input})`);
    else fail(`${v.id} (${v.input}): expected ${JSON.stringify(e)} got ${JSON.stringify(got)}`);
  }

  // -- layout vectors: structural + the independent flexbox oracle reproduces every frame --
  console.log('\n-- layout vectors (structural + independent flexbox oracle):');
  for (const v of (corpus.layoutVectors || [])) {
    if (!v.root || v.root.width == null || v.root.height == null) { fail(`${v.id}: missing root size`); continue; }
    if (!v.tree) { fail(`${v.id}: missing tree`); continue; }
    const beforeFails = failures;
    walkExpects(v.tree, densities, v.id);
    try {
      const laid = runOracle(v);
      compareFrames(laid, 'root', v.id);
    } catch (err) {
      fail(`${v.id}: oracle error — ${err.message}`);
    }
    if (failures === beforeFails) ok(`${v.id} — ${v.description.slice(0, 70)}`);
  }

  // -- style-effect vectors: shape only (the per-host effect is asserted in the runners) --
  console.log('\n-- style-effect vectors (shape):');
  for (const v of (corpus.styleEffectVectors || [])) {
    if (!v.style || !v.expect) { fail(`${v.id}: missing style/expect`); continue; }
    ok(`${v.id} — ${v.description.slice(0, 70)}`);
  }

  console.log('');
  if (failures === 0) {
    console.log('ALL GREEN — the cross-platform test-vector corpus is well-formed, density-normalizable,');
    console.log('            and every expected frame/color is reproduced by an independent oracle.');
    process.exit(0);
  } else {
    console.error(`CORPUS INVALID — ${failures} problem(s). Fix layout-vectors.json (the single source of truth).`);
    process.exit(1);
  }
}

main();
