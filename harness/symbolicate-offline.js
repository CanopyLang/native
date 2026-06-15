// symbolicate-offline.js — AND-10 OFFLINE crash symbolicator for canopy/native release builds.
//
// A shipped release is doubly unreadable: the JS frames point at `canopy.bundle.js:LINE:COL`
// (the optimized bundle carries NO in-app map), and the Java/host frames are R8-obfuscated
// (`com.canopyhost.a.b(SourceFile:13)`). This tool retraces BOTH, offline and device-free,
// against the artifacts the build archives keyed to the bundle's buildId:
//
//   • JS frames  -> `<Module>.can:line`        via the archived `canopy.<buildId>.map`
//                   (the EXACT VLQ/index logic the in-app symbolicator uses — we drive the
//                    REAL `_Native_symbolicate` from package/external/native.js, never a fork).
//   • Java frames -> `OriginalClass.method(File.java:line)` via R8 `mapping.txt`
//                   (a minimal, dependency-free retracer over the documented R8 map format;
//                    `retrace` from build-tools would also work, but this stays hermetic).
//
// Usage (programmatic — see run-symbolicate-offline.js):
//   const { symbolicateOffline } = require('./symbolicate-offline');
//   symbolicateOffline(stackString, { mapText, mappingText })   -> symbolicated stack string
//
// Usage (CLI):
//   node symbolicate-offline.js --map canopy.<buildId>.map --mapping mapping.txt < stack.txt
//   node symbolicate-offline.js --map ... --mapping ... --stack "Error\n  at ..."
//
// Best-effort, exactly like the in-app path: any frame we cannot resolve is left UNTOUCHED,
// so symbolication never hides the underlying crash.

'use strict';

// ---------------------------------------------------------------------------
// JS frames: reuse the REAL in-app symbolicator (VLQ decode + lazy index) so the
// offline result is byte-identical to what the device red-box would show. We load
// the mini-runtime (installs the F2..F9 globals native.js touches at module load),
// then native.js, and feed it the archived map via globalThis.__canopy_sourcemap.
// ---------------------------------------------------------------------------
function symbolicateJs(stack, mapText) {
  if (!mapText) { return stack; }
  // mini-runtime installs the globals native.js references when required.
  require('./mini-runtime');
  // Force a fresh native.js + a fresh lazy source-map index for THIS map.
  delete require.cache[require.resolve('../package/external/native.js')];
  globalThis.__canopy_sourcemap = mapText;
  const native = require('../package/external/native.js');
  try {
    return native._Native_symbolicate(stack);
  } finally {
    delete globalThis.__canopy_sourcemap;
    delete require.cache[require.resolve('../package/external/native.js')];
  }
}

// ---------------------------------------------------------------------------
// Java frames: a minimal R8 `mapping.txt` retracer.
//
// The R8 map (header `# compiler: R8`) is a flat text file of:
//   <originalClass> -> <obfuscatedClass>:
//       [<obfStart>:<obfEnd>:]<retType> <origMethod>(<args>)[:<srcStart>[:<srcEnd>]] -> <obfMethod>
//       <origType> <origField> -> <obfField>
//   (lines beginning with '#' are comments / JSON metadata; ignored)
//
// To retrace `obf.Class.obfMethod(SourceFile:N)`:
//   1. find the class whose obfuscated name == obf.Class           -> originalClass
//   2. among that class's methods named obfMethod, pick the one whose [obfStart..obfEnd]
//      range contains N (or, if none carry a range, the lone match)
//   3. map N through that method's source range to the original source line, and emit
//      `originalClass.origMethod(SimpleClassName.java:srcLine)`.
// ---------------------------------------------------------------------------

// Parse mapping.txt once into { byObfClass: { obfName -> { orig, methods: [ {obf, orig, obfStart, obfEnd, srcStart, srcEnd, fileName} ] } } }.
function parseR8Mapping(text) {
  const byObfClass = Object.create(null);
  let cur = null;        // current class record
  let pendingFile = null; // sourceFile fileName from a `# {"id":"sourceFile",...}` comment under the class header
  const lines = text.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (line.length === 0) { continue; }
    if (line.charCodeAt(0) === 35 /* '#' */) {
      // Class-level sourceFile metadata: `# {"id":"sourceFile","fileName":"Foo.java"}`.
      const fm = /"id"\s*:\s*"sourceFile"[^}]*"fileName"\s*:\s*"([^"]+)"/.exec(line);
      if (fm && cur) { cur.fileName = fm[1]; }
      continue;
    }
    // Method/field lines are indented; class lines are not.
    if (line.charCodeAt(0) !== 32 /* ' ' */ && line.charCodeAt(0) !== 9 /* tab */) {
      // Class line:  original -> obfuscated:
      const m = /^(.+?) -> (.+?):$/.exec(line);
      if (m) {
        cur = { orig: m[1].trim(), fileName: null, methods: Object.create(null) };
        byObfClass[m[2].trim()] = cur;
        pendingFile = null;
      } else {
        cur = null;
      }
      continue;
    }
    if (!cur) { continue; }
    const body = line.trim();
    // Only method lines (have a '(') interest us for line retrace.
    const arrow = body.lastIndexOf(' -> ');
    if (arrow < 0) { continue; }
    const lhs = body.slice(0, arrow);
    const obfMethod = body.slice(arrow + 4).trim();
    if (lhs.indexOf('(') < 0) { continue; } // a field, not a method
    // lhs forms:
    //   retType name(args)
    //   obfStart:obfEnd:retType name(args)
    //   obfStart:obfEnd:retType name(args):srcStart:srcEnd
    //   obfStart:obfEnd:retType name(args):srcStart
    let obfStart = null, obfEnd = null, srcStart = null, srcEnd = null, sig = lhs;
    // Leading `obfStart:obfEnd:` prefix.
    const pre = /^(\d+):(\d+):(.*)$/.exec(lhs);
    if (pre) { obfStart = +pre[1]; obfEnd = +pre[2]; sig = pre[3]; }
    // Trailing `:srcStart[:srcEnd]` suffix (after the closing paren of the signature).
    const closeParen = sig.lastIndexOf(')');
    let head = sig, tail = '';
    if (closeParen >= 0) { head = sig.slice(0, closeParen + 1); tail = sig.slice(closeParen + 1); }
    const sm = /^:(\d+)(?::(\d+))?$/.exec(tail);
    if (sm) { srcStart = +sm[1]; if (sm[2] !== undefined) srcEnd = +sm[2]; }
    // `head` is `retType origMethodName(args)` — pull the original method name.
    const nm = /([A-Za-z_$][\w$.]*)\s*\(/.exec(head);
    const origMethod = nm ? nm[1].split('.').pop() : obfMethod;
    const arr = cur.methods[obfMethod] || (cur.methods[obfMethod] = []);
    arr.push({ origMethod: origMethod, obfStart: obfStart, obfEnd: obfEnd, srcStart: srcStart, srcEnd: srcEnd });
  }
  return { byObfClass: byObfClass };
}

// Map an obfuscated method's reported line N to its original source line, using the
// method record's obf range and source range (R8's standard linear mapping).
function mapMethodLine(rec, n) {
  if (n == null || rec.srcStart == null) { return rec.srcStart; }
  if (rec.obfStart != null && rec.obfEnd != null && rec.srcEnd != null && rec.obfEnd !== rec.obfStart) {
    // Linear interpolation across the residual range (the common R8 inlined-range case).
    const offset = n - rec.obfStart;
    return rec.srcStart + offset;
  }
  // Single-line or only a srcStart known: the original source line is srcStart.
  return rec.srcStart;
}

// Derive the original `File.java` for a class: explicit sourceFile metadata wins, else
// the simple class name + ".java" (R8's `-renamesourcefileattribute SourceFile` convention).
function classFileName(orig, fileName) {
  if (fileName && fileName.indexOf('R8$$') < 0) { return fileName; }
  let simple = orig;
  const dot = simple.lastIndexOf('.');
  if (dot >= 0) { simple = simple.slice(dot + 1); }
  const dollar = simple.indexOf('$');
  if (dollar >= 0) { simple = simple.slice(0, dollar); }
  return simple + '.java';
}

// Retrace one Java frame `pkg.obf.Class.obfMethod(SourceFile:N)` -> original. Returns the
// rewritten frame text, or the input unchanged if it cannot be resolved.
function retraceJavaFrame(frame, parsed) {
  // Match: <qualified-obf-class>.<method>(<file>[:<line>])
  const m = /^(.*?)\.([^.()\s]+)\(([^():]+)(?::(\d+))?\)\s*$/.exec(frame);
  if (!m) { return frame; }
  const obfClass = m[1];
  const obfMethod = m[2];
  const lineNo = m[4] !== undefined ? +m[4] : null;
  const cls = parsed.byObfClass[obfClass];
  if (!cls) { return frame; }
  const cands = cls.methods[obfMethod];
  if (!cands || cands.length === 0) {
    // Class is known but method isn't in the map (e.g. kept verbatim): retrace the class only.
    return cls.orig + '.' + obfMethod + '(' + classFileName(cls.orig, cls.fileName) + (lineNo != null ? ':' + lineNo : '') + ')';
  }
  // Pick the candidate whose obf range contains lineNo; else the first.
  let rec = cands[0];
  if (lineNo != null) {
    const hit = cands.find(c => c.obfStart != null && c.obfEnd != null && lineNo >= c.obfStart && lineNo <= c.obfEnd);
    if (hit) { rec = hit; }
  }
  const srcLine = mapMethodLine(rec, lineNo);
  const file = classFileName(cls.orig, cls.fileName);
  return cls.orig + '.' + rec.origMethod + '(' + file + (srcLine != null ? ':' + srcLine : '') + ')';
}

// Rewrite every Java frame in a stack string. A "Java frame" is the part after `at ` (or a
// bare `at`-less line) that looks like `qualified.Class.method(File[:line])`.
function symbolicateJava(stack, mappingText) {
  if (!mappingText) { return stack; }
  const parsed = parseR8Mapping(mappingText);
  return stack.replace(/((?:at\s+)?)([\w$.]+\.[\w$<>]+\([^()]*\))/g, function (whole, atPrefix, frame) {
    // Skip JS frames (already handled, or not Java): they contain `.bundle.js` / `.can`.
    if (/\.(?:js|can)\b/.test(frame)) { return whole; }
    const retraced = retraceJavaFrame(frame, parsed);
    return atPrefix + retraced;
  });
}

// ---------------------------------------------------------------------------
// Public: run BOTH passes. JS first (rewrites `canopy.bundle.js:L:C` -> `.can:line`),
// then Java (rewrites the R8-obfuscated frames). Each pass is best-effort + independent.
// ---------------------------------------------------------------------------
function symbolicateOffline(stack, opts) {
  if (typeof stack !== 'string' || stack.length === 0) { return stack; }
  opts = opts || {};
  let out = stack;
  out = symbolicateJs(out, opts.mapText);
  out = symbolicateJava(out, opts.mappingText);
  return out;
}

module.exports = {
  symbolicateOffline,
  symbolicateJs,
  symbolicateJava,
  parseR8Mapping,
  retraceJavaFrame,
};

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------
if (require.main === module) {
  const fs = require('fs');
  const args = process.argv.slice(2);
  let mapPath = null, mappingPath = null, stackArg = null;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--map') { mapPath = args[++i]; }
    else if (args[i] === '--mapping') { mappingPath = args[++i]; }
    else if (args[i] === '--stack') { stackArg = args[++i]; }
  }
  const mapText = mapPath && fs.existsSync(mapPath) ? fs.readFileSync(mapPath, 'utf8') : null;
  const mappingText = mappingPath && fs.existsSync(mappingPath) ? fs.readFileSync(mappingPath, 'utf8') : null;
  const stack = stackArg != null
    ? stackArg.replace(/\\n/g, '\n')
    : fs.readFileSync(0, 'utf8'); // stdin
  process.stdout.write(symbolicateOffline(stack, { mapText: mapText, mappingText: mappingText }) + '\n');
}
