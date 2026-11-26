// WebAssembly references at the JavaScript boundary (GC and typed function
// references): Exported GC Objects, the type checks of ToWebAssemblyValue,
// i31 numbers, JavaScript values of every kind kept as externrefs in every
// place WebAssembly stores them (struct fields, arrays, globals, tables,
// exception payloads, the any hierarchy), objects kept by both collectors
// and cycles through both heaps collected; the JS string builtins and
// string constants. Modules are assembled by a small encoder.

// ---- a small module encoder ----
function uleb(n) {
  var out = [];
  do {
    var b = n & 0x7f;
    n = Math.floor(n / 128);
    if (n) b |= 0x80;
    out.push(b);
  } while (n);
  return out;
}
function sleb(n) {
  var out = [];
  for (;;) {
    var b = n & 0x7f;
    n >>= 7;
    if ((n === 0 && (b & 0x40) === 0) || (n === -1 && (b & 0x40) !== 0)) { out.push(b); return out; }
    out.push(b | 0x80);
  }
}
function name(text) {
  var bytes = Array.from(new TextEncoder().encode(text));
  return uleb(bytes.length).concat(bytes);
}
function vec(items) {
  var out = uleb(items.length);
  for (var i = 0; i < items.length; i++) out = out.concat(items[i]);
  return out;
}
function sec(id, body) { return [id].concat(uleb(body.length), body); }
function wasm(sections) {
  var out = [0, 0x61, 0x73, 0x6d, 1, 0, 0, 0];
  for (var i = 0; i < sections.length; i++) out = out.concat(sections[i]);
  return new Uint8Array(out);
}
var I32 = [0x7f], I64 = [0x7e], EXTERN = [0x6f], ANY = [0x6e], EQ = [0x6d], I31 = [0x6c], STRUCT = [0x6b];
function ref(index) { return [0x64].concat(sleb(index)); }
function refNull(index) { return [0x63].concat(sleb(index)); }
function func(params, results) { return [0x60].concat(vec(params), vec(results)); }
function body(code) { var b = vec([]).concat(code, [0x0b]); return uleb(b.length).concat(b); }
function exportFunc(text, index) { return name(text).concat([0], uleb(index)); }
function threw(f, Kind) {
  try { f(); } catch (e) { return Kind === undefined || e instanceof Kind; }
  return false;
}
var W = WebAssembly;

// ---- a module of structs, arrays, i31s and the any and extern hierarchies ----
var types = [
  [0x5f].concat(vec([EXTERN.concat([1])])),        // 0 struct (mut externref)
  [0x5e].concat(EXTERN, [1]),                       // 1 array (mut externref)
  [0x5f].concat(vec([I32.concat([0])])),            // 2 struct i32
  func([EXTERN], [ref(0)]),                         // 3
  func([refNull(0)], [EXTERN]),                     // 4
  func([refNull(0), EXTERN], []),                   // 5
  func([EXTERN], [EXTERN]),                         // 6
  func([I32], [ref(1)]),                            // 7
  func([refNull(1), I32, EXTERN], []),              // 8
  func([refNull(1), I32], [EXTERN]),                // 9
  func([ANY], [I32]),                               // 10
  func([EQ, EQ], [I32]),                            // 11
  func([I32], [ref(2)]),                            // 12
  func([refNull(2)], [I32]),                        // 13
  func([], [ANY]),                                  // 14
  func([ANY], []),                                  // 15
  func([EXTERN], []),                               // 16
  func([], [EXTERN]),                               // 17
  func([I32], [ANY]),                               // 18
  func([EXTERN], [ANY]),                            // 19
  func([ANY], [EXTERN]),                            // 20
  func([I32], [])                                   // 21
];
var functions = [
  ["makeBox", 3, [0x20, 0, 0xfb, 0x00, 0]],
  ["unbox", 4, [0x20, 0, 0xfb, 0x02, 0, 0]],
  ["setBox", 5, [0x20, 0, 0x20, 1, 0xfb, 0x05, 0, 0]],
  ["roundTrip", 6, [0x20, 0, 0xfb, 0x1a, 0xfb, 0x1b]],
  ["makeArray", 7, [0x20, 0, 0xfb, 0x07, 1]],
  ["arraySet", 8, [0x20, 0, 0x20, 1, 0x20, 2, 0xfb, 0x0e, 1]],
  ["arrayGet", 9, [0x20, 0, 0x20, 1, 0xfb, 0x0b, 1]],
  ["isI31", 10, [0x20, 0, 0xfb, 0x14, 0x6c]],
  ["refEq", 11, [0x20, 0, 0x20, 1, 0xd3]],
  ["makePoint", 12, [0x20, 0, 0xfb, 0x00, 2]],
  ["pointX", 13, [0x20, 0, 0xfb, 0x02, 2, 0]],
  ["getStored", 14, [0x23, 0]],
  ["setStored", 15, [0x20, 0, 0x24, 0]],
  ["setExtern", 16, [0x20, 0, 0x24, 1]],
  ["getExtern", 17, [0x23, 1]],
  ["makeI31", 18, [0x20, 0, 0xfb, 0x1c]],
  ["internalize", 19, [0x20, 0, 0xfb, 0x1a]],
  ["externalize", 20, [0x20, 0, 0xfb, 0x1b]],
  // allocate: fills the heap with garbage so libwasm collects by itself
  ["churn", 21, [0x03, 0x40, 0x41, 32, 0xfb, 0x07, 1, 0x1a, 0x20, 0, 0x41, 1, 0x6b, 0x22, 0, 0x0d, 0, 0x0b]]
];
var refModule = new W.Module(wasm([
  sec(1, vec(types)),
  sec(3, vec(functions.map(function (f) { return uleb(f[1]); }))),
  sec(4, vec([EXTERN.concat([0, 4])])),
  sec(6, vec([
    [0x63, 0x6e, 1, 0xd0, 0x6e, 0x0b],
    [0x63, 0x6f, 1, 0xd0, 0x6f, 0x0b],
    [0x63, 0x6b, 1, 0xd0, 0x6b, 0x0b]
  ])),
  sec(7, vec(functions.map(function (f, i) { return exportFunc(f[0], i); }).concat([
    name("table").concat([1, 0]), name("stored").concat([3, 0]), name("externGlobal").concat([3, 1]),
    name("structGlobal").concat([3, 2])]))),
  sec(10, vec(functions.map(function (f) { return body(f[2]); })))
]));
var r = new W.Instance(refModule).exports;

// ---- Exported GC Objects ----
var box = r.makeBox("payload");
check("a struct is an object with a null prototype", typeof box === "object" && Object.getPrototypeOf(box) === null);
check("it has no properties and refuses new ones", box.anything === undefined && box[0] === undefined &&
  Object.getOwnPropertyNames(box).length === 0 && !Object.isExtensible(box) && !("x" in box) &&
  threw(function () { box.x = 1; }, TypeError) && threw(function () { "use strict"; delete box.x; }, TypeError) &&
  threw(function () { Object.defineProperty(box, "x", { value: 1 }); }, TypeError) &&
  threw(function () { Object.setPrototypeOf(box, {}); }, TypeError) &&
  threw(function () { Object.preventExtensions(box); }, TypeError) && threw(function () { Object.freeze(box); }, TypeError));
check("Object.prototype.toString on it", Object.prototype.toString.call(box) === "[object Object]" &&
  threw(function () { String(box); }, TypeError));
check("a struct passed back to WebAssembly is the same struct", r.unbox(box) === "payload");
r.setStored(box);
check("identity: the same struct is the same object", r.getStored() === box && r.stored.value === box);
var map = new WeakMap([[box, 1]]);
check("a struct is a WeakMap key", map.get(r.getStored()) === 1);
var array = r.makeArray(3);
check("an array is an object of its own kind too", typeof array === "object" && array !== box &&
  Object.getPrototypeOf(array) === null && r.arrayGet(array, 0) === null);

// ---- type checks (ToWebAssemblyValue) ----
check("a struct of the wrong type is a TypeError", threw(function () { r.unbox(r.makePoint(1)); }, TypeError) &&
  threw(function () { r.pointX(box); }, TypeError) && threw(function () { r.unbox({}); }, TypeError) &&
  threw(function () { r.unbox(1); }, TypeError) && r.pointX(r.makePoint(7)) === 7);
check("null passes for a nullable type (struct.get then traps)", threw(function () { r.unbox(null); },
  W.RuntimeError));
check("eqref takes structs and i31 numbers, not strings or objects", r.refEq(box, box) === 1 &&
  r.refEq(box, array) === 0 && r.refEq(5, 5) === 1 && r.refEq(5, 6) === 0 &&
  threw(function () { r.refEq("s", 1); }, TypeError) && threw(function () { r.refEq({}, 1); }, TypeError));
check("a struct global refuses an array", threw(function () { r.structGlobal.value = array; }, TypeError) &&
  (r.structGlobal.value = box, r.structGlobal.value === box));
check("i31 numbers", r.isI31(5) === 1 && r.isI31(-(2 ** 30)) === 1 && r.isI31(2 ** 30 - 1) === 1 &&
  r.isI31(2 ** 30) === 0 && r.isI31(1.5) === 0 && r.isI31(-0) === 0 && r.isI31("5") === 0 && r.isI31(box) === 0);
check("an i31 comes out as a Number", r.makeI31(-7) === -7 && r.makeI31(2 ** 30) === -(2 ** 30) &&
  r.makeI31(0x7fffffff) === -1);
check("anyref takes any value; host values round-trip", r.externalize(r.internalize(box)) === box &&
  r.externalize(r.internalize("text")) === "text");
check("JS-made globals of the GC types", new W.Global({ value: "anyref", mutable: true }, box).value === box &&
  new W.Global({ value: "eqref" }, 3).value === 3 && threw(function () { new W.Global({ value: "i31ref" }, "x"); },
  TypeError) && threw(function () { new W.Global({ value: "structref" }, array); }, TypeError) &&
  new W.Global({ value: "arrayref" }, array).value === array &&
  threw(function () { new W.Global({ value: "exnref" }); }, TypeError));
var anyTable = new W.Table({ element: "anyref", initial: 2 });
anyTable.set(0, box);
anyTable.set(1, 42);
check("a JS-made anyref table", anyTable.get(0) === box && anyTable.get(1) === 42);

// ---- typed function references ----
// seven: () -> i32, inc: (i32) -> i32, callRef: ((ref $seven's type)) -> i32 by call_ref
var typed = new W.Instance(new W.Module(wasm([
  sec(1, vec([func([], [I32]), func([I32], [I32]), func([ref(0)], [I32]), func([], [[0x63, 0]])])),
  sec(3, vec([[0], [1], [2], [3]])),
  sec(7, vec([exportFunc("seven", 0), exportFunc("inc", 1), exportFunc("callRef", 2), exportFunc("nothing", 3)])),
  sec(10, vec([body([0x41, 7]), body([0x20, 0, 0x41, 1, 0x6a]), body([0x20, 0, 0x14, 0]), body([0xd0, 0])]))
]))).exports;
check("a typed function reference takes an Exported Function of its type", typed.callRef(typed.seven) === 7);
check("and refuses others, null and JavaScript functions", threw(function () { typed.callRef(typed.inc); },
  TypeError) && threw(function () { typed.callRef(null); }, TypeError) &&
  threw(function () { typed.callRef(function () { return 7; }); }, TypeError) && typed.nothing() === null);

// ---- every kind of JavaScript value as an externref, in every place ----
var symbol = Symbol("s"), object = { o: 1 }, big = 12345678901234567890n;
var values = [1, 3, -1, 2 ** 30 - 1, 2 ** 30, 2 ** 30 + 1, -(2 ** 30) - 1, 2 ** 31 + 1, 2 ** 53 - 1, 4.5, -0, 0,
  NaN, Infinity, -Infinity, 5e-324, true, false, undefined, "", "odd", big, symbol, object, box, array, r.unbox];
function same(a, b) { return Object.is(a, b); }
function allKept(store, load) {
  var copies = values.map(function (v, i) { return store(v, i); });
  gc();
  return values.every(function (v, i) { return same(load(copies[i], i), v); });
}
var bigArray = r.makeArray(values.length);
var externTable = new W.Table({ element: "externref", initial: values.length });
var exnTag = new W.Tag({ parameters: ["externref"] });
check("externref values through a call", allKept(function (v) { return r.roundTrip(v); },
  function (v) { return v; }));
check("externref values in struct fields", allKept(function (v) { return r.makeBox(v); },
  function (b) { return r.unbox(b); }));
check("externref values in a struct field set from JavaScript", allKept(function (v) {
  var b = r.makeBox(null); r.setBox(b, v); return b; }, function (b) { return r.unbox(b); }));
check("externref values in an array", allKept(function (v, i) { r.arraySet(bigArray, i, v); return null; },
  function (unused, i) { return r.arrayGet(bigArray, i); }));
check("externref values in a module's global", values.every(function (v) {
  r.setExtern(v); gc(); return same(r.getExtern(), v) && same(r.externGlobal.value, v); }));
check("externref values in a JavaScript-made global", values.every(function (v) {
  var g = new W.Global({ value: "externref", mutable: true }, v); gc();
  var ok = same(g.value, v); g.value = v; return ok && same(g.value, v); }));
check("externref values in a table", allKept(function (v, i) { externTable.set(i, v); return null; },
  function (unused, i) { return externTable.get(i); }) && values.every(function (v) {
  r.table.set(1, v); gc(); return same(r.table.get(1), v); }));
check("externref values through the any hierarchy", allKept(function (v) { return r.internalize(v); },
  function (a) { return r.externalize(a); }));
check("externref values as exception payloads", allKept(function (v) { return new W.Exception(exnTag, [v]); },
  function (e) { return e.getArg(exnTag, 0); }));
check("externref values grown into a table", values.every(function (v) {
  var t = new W.Table({ element: "externref", initial: 0 }); t.grow(2, v); gc();
  return same(t.get(0), v) && same(t.get(1), v); }));

// ---- both collectors ----
// Objects only WebAssembly holds live through JavaScript's collections,
// and WebAssembly objects only JavaScript holds through libwasm's own.
(function () {
  for (var i = 0; i < 200; i++) r.arraySet(bigArray, i % values.length, { index: i });
})();
gc();
check("JavaScript objects held only by a WebAssembly array survive a collection",
  r.arrayGet(bigArray, 199 % values.length).index === 199);
var heldBoxes = [];
for (var k = 0; k < 50; k++) heldBoxes.push(r.makeBox({ number: k }));
r.churn(20000);
gc();
r.churn(20000);
check("structs held only by JavaScript survive WebAssembly's own collections",
  heldBoxes.every(function (b, i) { return r.unbox(b).number === i; }));

// A cycle through both heaps: a struct holds a JavaScript object that holds
// the struct. Nothing else does, so both go (WeakRef sees it).
var cycleRef = null, keptRef = null;
(function () {
  var target = { name: "cycle" };
  target.box = r.makeBox(target);
  cycleRef = new WeakRef(target);
  var kept = { name: "kept" };
  kept.box = r.makeBox(kept);
  r.setStored(kept.box);
  keptRef = new WeakRef(kept);
})();

// ---- JS string builtins and string constants ----
var stringTypes = [
  func([EXTERN], [I32]),                         // 0 length
  func([EXTERN, EXTERN], [[0x64, 0x6f]]),        // 1 concat
  func([EXTERN, I32], [I32]),                    // 2 charCodeAt
  func([EXTERN], [[0x64, 0x6f]]),                // 3 cast
  func([EXTERN], [EXTERN])                       // 4 greet
];
function stringModuleBytes(lengthType) {
  return wasm([
    sec(1, vec(stringTypes)),
    sec(2, vec([
      name("wasm:js-string").concat(name("length"), [0], uleb(lengthType)),
      name("wasm:js-string").concat(name("concat"), [0, 1]),
      name("wasm:js-string").concat(name("charCodeAt"), [0, 2]),
      name("wasm:js-string").concat(name("cast"), [0, 3]),
      name("'").concat(name("Hello, "), [3, 0x64, 0x6f, 0]),
      name("env").concat(name("other"), [0, 0])
    ])),
    sec(3, vec([[4]])),
    sec(7, vec([exportFunc("length", 0), exportFunc("concat", 1), exportFunc("charCodeAt", 2), exportFunc("cast", 3),
      exportFunc("greet", 5)])),
    sec(10, vec([body([0x23, 0, 0x20, 0, 0x10, 1])]))
  ]);
}
var stringOptions = { builtins: ["js-string"], importedStringConstants: "'" };
var stringModule = new W.Module(stringModuleBytes(0), stringOptions);
var stringImports = W.Module.imports(stringModule);
check("builtin and string constant imports are not listed", stringImports.length === 1 &&
  stringImports[0].module === "env" && W.Module.imports(new W.Module(stringModuleBytes(0))).length === 6);
var str = new W.Instance(stringModule, { env: { other: function () { return 0; } } }).exports;
check("the string builtins", str.length("héllo") === 5 && str.concat("ab", "cd") === "abcd" &&
  str.charCodeAt("A", 0) === 65 && str.cast("x") === "x" && str.greet("world") === "Hello, world");
check("a builtin traps on a value that is no string", threw(function () { str.length(5); }, W.RuntimeError) &&
  threw(function () { str.cast({}); }, W.RuntimeError) && threw(function () { str.charCodeAt("a", 1); },
  W.RuntimeError));
check("a builtin import of the wrong type is a CompileError", threw(function () {
  new W.Module(stringModuleBytes(2), stringOptions); }, W.CompileError) &&
  W.validate(stringModuleBytes(0), stringOptions) && !W.validate(stringModuleBytes(2), stringOptions) &&
  threw(function () { new W.Module(stringModuleBytes(0), { builtins: ["js-string", "js-string"] }); },
  W.CompileError));
check("without the option the builtins are ordinary imports", threw(function () {
  new W.Instance(new W.Module(stringModuleBytes(0)), {}); }, TypeError));

function after() {
  gc();
  gc();
  check("a cycle through both heaps is collected", cycleRef.deref() === undefined);
  check("an object WebAssembly holds through the cycle is kept", keptRef.deref() !== undefined &&
    keptRef.deref().name === "kept" && r.unbox(r.getStored()) === keptRef.deref());
}
