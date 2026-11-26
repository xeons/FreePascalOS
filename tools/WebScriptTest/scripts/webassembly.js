// The WebAssembly namespace (platform/57-webassembly.js over libwasm): the
// API surface, conversions both ways, errors, traps, promises, streaming,
// memory buffers, tables, globals, externref values kept by the collector,
// re-entrant calls, structured clone and workers. Modules are assembled
// here by a small encoder of the binary format.

// ---- a small module encoder ----
var T = { i32: 0x7f, i64: 0x7e, f32: 0x7d, f64: 0x7c, v128: 0x7b, funcref: 0x70, externref: 0x6f };
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
function vector(items) {
  var out = uleb(items.length);
  for (var i = 0; i < items.length; i++) out = out.concat(items[i]);
  return out;
}
function section(id, body) { return [id].concat(uleb(body.length), body); }
function limits(min, max) { return max === undefined ? [0].concat(uleb(min)) : [1].concat(uleb(min), uleb(max)); }
// spec: types [[params, results]], imports [{module, name, func: typeIndex | memory: [min, max] |
// table: [type, min, max] | global: [type, mutable]}], funcs [{type, locals: [type...], code: [...]}],
// tables, memories, globals [{type, mutable, init: [...]}], exports [[name, kind, index]], start,
// elements [{offset, funcs}], data [{offset, bytes}], custom [[name, bytes]]
function assemble(spec) {
  var out = [0, 0x61, 0x73, 0x6d, 1, 0, 0, 0];
  var kinds = { func: 0, table: 1, memory: 2, global: 3 };
  if (spec.types) out = out.concat(section(1, vector(spec.types.map(function (t) {
    return [0x60].concat(vector(t[0].map(function (x) { return [x]; })), vector(t[1].map(function (x) { return [x]; })));
  }))));
  if (spec.imports) out = out.concat(section(2, vector(spec.imports.map(function (i) {
    var head = name(i.module).concat(name(i.name));
    if (i.func !== undefined) return head.concat([0], uleb(i.func));
    if (i.table) return head.concat([1, i.table[0]], limits(i.table[1], i.table[2]));
    if (i.memory) return head.concat([2], limits(i.memory[0], i.memory[1]));
    return head.concat([3, i.global[0], i.global[1] ? 1 : 0]);
  }))));
  if (spec.funcs) out = out.concat(section(3, vector(spec.funcs.map(function (f) { return uleb(f.type); }))));
  if (spec.tables) out = out.concat(section(4, vector(spec.tables.map(function (t) {
    return [t[0]].concat(limits(t[1], t[2]));
  }))));
  if (spec.memories) out = out.concat(section(5, vector(spec.memories.map(function (m) {
    return limits(m[0], m[1]);
  }))));
  if (spec.globals) out = out.concat(section(6, vector(spec.globals.map(function (g) {
    return [g.type, g.mutable ? 1 : 0].concat(g.init, [0x0b]);
  }))));
  if (spec.exports) out = out.concat(section(7, vector(spec.exports.map(function (e) {
    return name(e[0]).concat([kinds[e[1]]], uleb(e[2]));
  }))));
  if (spec.start !== undefined) out = out.concat(section(8, uleb(spec.start)));
  if (spec.elements) out = out.concat(section(9, vector(spec.elements.map(function (e) {
    return [0, 0x41].concat(sleb(e.offset), [0x0b], vector(e.funcs.map(function (f) { return uleb(f); })));
  }))));
  if (spec.funcs) out = out.concat(section(10, vector(spec.funcs.map(function (f) {
    var locals = vector((f.locals || []).map(function (t) { return [1, t]; }));
    var body = locals.concat(f.code, [0x0b]);
    return uleb(body.length).concat(body);
  }))));
  if (spec.data) out = out.concat(section(11, vector(spec.data.map(function (d) {
    return [0, 0x41].concat(sleb(d.offset), [0x0b], uleb(d.bytes.length), d.bytes);
  }))));
  if (spec.custom) for (var c = 0; c < spec.custom.length; c++)
    out = out.concat(section(0, name(spec.custom[c][0]).concat(spec.custom[c][1])));
  return new Uint8Array(out);
}
function threw(f, Kind) {
  try { f(); } catch (e) { return Kind === undefined || e instanceof Kind; }
  return false;
}
var W = WebAssembly;

// ---- the surface ----
check("WebAssembly is a namespace object", typeof W === "object" && String(W) === "[object WebAssembly]" &&
  Object.getOwnPropertyDescriptor(window, "WebAssembly").enumerable === false && threw(function () { W(); }, TypeError));
check("its interfaces", ["Module", "Instance", "Memory", "Table", "Global", "CompileError", "LinkError",
  "RuntimeError"].every(function (n) { return typeof W[n] === "function"; }) && W.validate.length === 1 &&
  W.instantiate.length === 1 && W.Module.customSections.length === 2 && W.Table.prototype.set.length === 1 &&
  W.Global.length === 1 && W.Instance.length === 1);
check("constructors need new", threw(function () { W.Module(new Uint8Array(8)); }, TypeError) &&
  threw(function () { W.Memory({ initial: 1 }); }, TypeError));
check("errors subclass Error", Object.getPrototypeOf(W.CompileError) === Error &&
  Object.getPrototypeOf(W.RuntimeError.prototype) === Error.prototype && new W.LinkError("x").message === "x" &&
  W.LinkError("y") instanceof W.LinkError && W.CompileError.prototype.name === "CompileError" &&
  !(Symbol.toStringTag in W.RuntimeError.prototype) && W.CompileError.length === 1);
check("platform functions read as native code", String(W.compile).indexOf("[native code]") > 0);

// ---- a module of most things ----
// type 0: (i32, i32) -> i32   type 1: (i64) -> i64   type 2: () -> ()   type 3: (f32) -> f32
// type 4: (i32) -> (i32, i64)  type 5: (externref) -> externref  type 6: (i32) -> i32
var main = assemble({
  types: [[[T.i32, T.i32], [T.i32]], [[T.i64], [T.i64]], [[], []], [[T.f32], [T.f32]],
    [[T.i32], [T.i32, T.i64]], [[T.externref], [T.externref]], [[T.i32], [T.i32]]],
  imports: [{ module: "env", name: "callback", func: 6 }, { module: "env", name: "seed", global: [T.i32, false] }],
  funcs: [
    { type: 0, code: [0x20, 0, 0x20, 1, 0x6a] },                           // 1 add
    { type: 1, code: [0x20, 0, 0x42, 1, 0x7c] },                           // 2 inc64
    { type: 2, code: [0x00] },                                             // 3 trap
    { type: 3, code: [0x20, 0] },                                          // 4 same32
    { type: 4, code: [0x20, 0, 0x20, 0, 0xac] },                           // 5 pair (i64.extend_i32_s)
    { type: 5, code: [0x20, 0] },                                          // 6 identity
    { type: 6, code: [0x20, 0, 0x10, 0] },                                 // 7 viaImport
    { type: 2, code: [0x10, 8] },                                          // 8 recurse
    { type: 6, code: [0x23, 0, 0x20, 0, 0x6a] },                           // 9 plusSeed
    { type: 6, code: [0x20, 0, 0x40, 0] },                                 // 10 grow (memory.grow)
    { type: 6, code: [0x20, 0, 0x28, 2, 0] },                              // 11 load
    { type: 2, code: [0x03, 0x40, 0x0c, 0, 0x0b] }                         // 12 spin (loop br 0)
  ],
  tables: [[T.funcref, 2, 10]],
  memories: [[1, 4]],
  globals: [{ type: T.i32, mutable: true, init: [0x41, 7] }, { type: T.i64, mutable: false, init: [0x42, 5] },
    { type: T.externref, mutable: true, init: [0xd0, T.externref] }],
  exports: [["add", "func", 1], ["inc64", "func", 2], ["trap", "func", 3], ["same32", "func", 4], ["pair", "func", 5],
    ["identity", "func", 6], ["viaImport", "func", 7], ["recurse", "func", 8], ["plusSeed", "func", 9],
    ["grow", "func", 10], ["load", "func", 11], ["spin", "func", 12], ["table", "table", 0], ["memory", "memory", 0],
    ["counter", "global", 1], ["big", "global", 2], ["ref", "global", 3], ["callback", "func", 0]],
  elements: [{ offset: 0, funcs: [1, 9] }],
  data: [{ offset: 16, bytes: [0x2a, 0, 0, 0] }],
  custom: [["note", [1, 2, 3]], ["note", [4]]]
});
check("validate", W.validate(main) && !W.validate(new Uint8Array([0, 0x61, 0x73, 0x6d, 2, 0, 0, 0])) &&
  threw(function () { W.validate("text"); }, TypeError));
var module = new W.Module(main);
check("Module", module instanceof W.Module && String(module) === "[object WebAssembly.Module]");
var exportsList = W.Module.exports(module);
check("Module.exports", exportsList.length === 18 && exportsList[0].name === "add" && exportsList[0].kind === "function" &&
  exportsList[12].kind === "table" && exportsList[13].kind === "memory" && exportsList[14].kind === "global");
var importsList = W.Module.imports(module);
check("Module.imports", importsList.length === 2 && importsList[0].module === "env" &&
  importsList[0].name === "callback" && importsList[1].kind === "global");
var sections = W.Module.customSections(module, "note");
check("Module.customSections", sections.length === 2 && sections[0] instanceof ArrayBuffer &&
  new Uint8Array(sections[0]).join() === "1,2,3" && W.Module.customSections(module, "none").length === 0);
check("CompileError", threw(function () { new W.Module(new Uint8Array([0, 0x61, 0x73, 0x6d, 1, 0, 0, 0, 1])); },
  W.CompileError));

var calls = [];
var imports = { env: { callback: function (x) { calls.push(x); return x * 2; }, seed: 100 } };
var instance = new W.Instance(module, imports);
var e = instance.exports;
check("exports object", Object.getPrototypeOf(e) === null && Object.isFrozen(e) && e === instance.exports &&
  Object.keys(e).join() === exportsList.map(function (x) { return x.name; }).join());
check("Exported Function", e.add.name === "1" && e.add.length === 2 && e.add === e.add &&
  Object.getPrototypeOf(e.add) === Function.prototype && !("prototype" in e.add) &&
  threw(function () { new e.add(1, 2); }, TypeError));
check("i32 conversions", e.add(2, 3) === 5 && e.add("4", { valueOf: function () { return 1; } }) === 5 &&
  e.add(0x7fffffff, 1) === -0x80000000 && e.add() === 0);
check("i64 as BigInt", e.inc64(41n) === 42n && e.inc64(-1n) === 0n && e.inc64(2n ** 64n + 1n) === 2n &&
  threw(function () { e.inc64(1); }, TypeError));
check("f32 rounding", e.same32(0.1) === Math.fround(0.1) && Number.isNaN(e.same32(NaN)));
var pair = e.pair(-3);
check("multiple results as an array", Array.isArray(pair) && pair[0] === -3 && pair[1] === -3n);
var token = { token: true };
check("externref holds any value", e.identity(token) === token && e.identity("s") === "s" &&
  e.identity(undefined) === undefined && e.identity(null) === null && e.identity(0) === 0 &&
  Object.is(e.identity(-0), -0));
check("imports called from WebAssembly", e.viaImport(21) === 42 && calls.join() === "21");
check("a number becomes a constant global import", e.plusSeed(1) === 101);
check("a re-exported import is an Exported Function", typeof e.callback === "function" &&
  e.callback !== imports.env.callback && e.callback(5) === 10);
check("data segments", e.load(16) === 42);

// traps and errors
var trap = null;
try { e.trap(); } catch (error) { trap = error; }
check("a trap is a RuntimeError", trap instanceof W.RuntimeError && trap instanceof Error &&
  /unreachable/.test(trap.message) && /wasm-function\[3\]/.test(trap.stack));
var tooDeep = null;
try { e.recurse(); } catch (error) { tooDeep = error; }
check("call stack exhaustion is a RangeError", tooDeep instanceof RangeError);
var thrown = { mine: true };
var caught = null;
var throwing = new W.Instance(module, { env: { callback: function () { throw thrown; }, seed: 0 } });
try { throwing.exports.viaImport(1); } catch (error) { caught = error; }
check("an import's exception goes through WebAssembly unchanged", caught === thrown);
check("LinkError for a wrong import", threw(function () {
  new W.Instance(module, { env: { callback: 5, seed: 0 } });
}, W.LinkError) && threw(function () { new W.Instance(module, { env: { callback: function () {}, seed: 1n } }); },
  W.LinkError) && threw(function () { new W.Instance(module); }, TypeError) &&
  threw(function () { new W.Instance(module, { env: 1 }); }, TypeError));

// re-entrancy: the import calls back into the instance
var reentrant = null;
reentrant = new W.Instance(module, { env: { callback: function (x) {
  return x > 0 ? reentrant.exports.viaImport(x - 1) + 1 : 0;
}, seed: 0 } });
check("re-entrant calls", reentrant.exports.viaImport(50) === 50);

// ---- memory ----
var memory = e.memory;
var buffer = memory.buffer;
check("Memory", memory instanceof W.Memory && memory === e.memory && buffer === memory.buffer &&
  buffer.byteLength === 65536 && new Uint8Array(buffer)[16] === 42 && Object.isExtensible(buffer));
check("the buffer cannot be detached by script", threw(function () { buffer.transfer(); }, TypeError) &&
  buffer.byteLength === 65536);
check("grow returns the old size and detaches the buffer", memory.grow(1) === 1 && buffer.byteLength === 0 &&
  buffer.detached && memory.buffer.byteLength === 131072 && new Uint8Array(memory.buffer)[16] === 42);
var before = memory.buffer;
check("memory.grow in WebAssembly detaches it too", e.grow(1) === 2 && before.detached &&
  memory.buffer.byteLength === 3 * 65536);
check("growing past the maximum", threw(function () { memory.grow(10); }, RangeError) && e.grow(10) === -1);
var made = new W.Memory({ initial: 1, maximum: 2 });
check("new Memory", made.buffer.byteLength === 65536 && threw(function () { new W.Memory({}); }, TypeError) &&
  threw(function () { new W.Memory({ initial: 2, maximum: 1 }); }, RangeError) &&
  threw(function () { new W.Memory({ initial: -1 }); }, TypeError) &&
  threw(function () { new W.Memory({ initial: 1, maximum: 2, shared: true }); }, TypeError));
var resizable = made.toResizableBuffer();
check("toResizableBuffer", resizable.resizable && resizable.maxByteLength === 131072 && made.buffer === resizable);
resizable.resize(131072);
check("resizing grows the memory", made.buffer === resizable && resizable.byteLength === 131072 &&
  threw(function () { resizable.resize(65536); }, RangeError));
check("toFixedLengthBuffer", made.toFixedLengthBuffer() !== resizable && resizable.detached &&
  !made.buffer.resizable);

// ---- tables ----
var table = e.table;
check("Table", table instanceof W.Table && table.length === 2 && table.get(0) === e.add &&
  table.get(1)(1) === 101 && threw(function () { table.get(2); }, RangeError));
table.set(1, e.inc64);
check("Table.set with an Exported Function", table.get(1) === e.inc64 &&
  threw(function () { table.set(0, function () {}); }, TypeError));
check("Table.grow", table.grow(2) === 2 && table.length === 4 && table.get(3) === null &&
  threw(function () { table.grow(100); }, RangeError));
var refs = new W.Table({ element: "externref", initial: 2 }, "start");
check("an externref table", refs.get(0) === "start" && refs.length === 2);
check("Table descriptors", threw(function () { new W.Table({ element: "i32", initial: 1 }); }, TypeError) &&
  new W.Table({ element: "anyfunc", initial: 1 }).get(0) === null);

// ---- globals ----
check("exported globals", e.counter.value === 7 && e.big.value === 5n && e.counter === e.counter &&
  e.counter.valueOf() === 7);
e.counter.value = 9;
check("a mutable global set from script", e.counter.value === 9);
check("an immutable global", threw(function () { e.big.value = 1n; }, TypeError));
var g = new W.Global({ value: "i64", mutable: true }, 3n);
check("new Global", g.value === 3n && new W.Global({ value: "f32" }).value === 0 &&
  new W.Global({ value: "externref" }).value === undefined &&
  threw(function () { new W.Global({ value: "v128" }); }, TypeError) &&
  threw(function () { new W.Global({ value: "i32" }, 1n); }, TypeError));

// ---- externref values survive collections ----
(function () {
  var kept = { name: "kept in a global" };
  e.ref.value = kept;
  var inTable = { name: "kept in a table" };
  refs.set(1, inTable);
})();
for (var round = 0; round < 3; round++) {
  var garbage = [];
  for (var n = 0; n < 20000; n++) garbage.push({ n: n });
  garbage = null;
  gc();
}
check("externrefs in globals and tables survive collections", e.ref.value.name === "kept in a global" &&
  refs.get(1).name === "kept in a table");
var keptByImport = (function () {
  var secret = { value: 7 };
  return new W.Instance(module, { env: { callback: function () { return secret.value; }, seed: 0 } });
})();
gc();
check("an imported function survives collections", keptByImport.exports.viaImport(0) === 7);

// ---- structured clone ----
var clone = structuredClone(module);
check("structuredClone of a Module", clone instanceof W.Module && clone !== module &&
  new W.Instance(clone, imports).exports.add(1, 2) === 3);
check("Instances cannot be cloned", threw(function () { structuredClone(instance); }));

// ---- a dedicated worker gets a Module by postMessage ----
var workerResult = null;
var workerSource = "onmessage = function (event) {" +
  "  var instance = new WebAssembly.Instance(event.data.module," +
  "    { env: { callback: function (x) { return x; }, seed: 1 } });" +
  "  postMessage([event.data.module instanceof WebAssembly.Module, instance.exports.add(3, 4)," +
  "    typeof WebAssembly.compileStreaming]);" +
  "};";
var worker = new Worker(URL.createObjectURL(new Blob([workerSource], { type: "text/javascript" })));
worker.onmessage = function (event) { workerResult = event.data; };
worker.postMessage({ module: module });

// ---- promises ----
var compiled = null, instantiated = null, fromModule = null, compileError = null, linkError = null,
  streamed = null, wrongType = null, notOk = null, fromFetch = null, textType = null;
var synchronous = true;
W.compile(main).then(function (m) { compiled = { sync: synchronous, module: m }; });
W.instantiate(main, imports).then(function (r) { instantiated = r; });
W.instantiate(module, imports).then(function (i) { fromModule = i; });
W.compile(new Uint8Array(4)).catch(function (error) { compileError = error; });
W.instantiate(module, { env: { callback: 1, seed: 0 } }).catch(function (error) { linkError = error; });
var wasmHeaders = { headers: { "Content-Type": "application/wasm" } };
W.instantiateStreaming(new Response(main, wasmHeaders), imports).then(function (r) { streamed = r; });
W.compileStreaming(new Response(main, { headers: { "Content-Type": "application/wasm;x" } }))
  .catch(function (error) { wrongType = error; });
W.compileStreaming(Promise.resolve(new Response(main, { status: 404, headers: { "Content-Type": "application/wasm" } })))
  .catch(function (error) { notOk = error; });
W.instantiateStreaming(fetch("/module.wasm")).then(function (r) { fromFetch = r; });
W.compileStreaming(fetch("/module-as-text.wasm")).catch(function (error) { textType = error; });
synchronous = false;
check("compile and instantiate settle later", compiled === null && instantiated === null);

function after() {
  check("compile", compiled !== null && !compiled.sync && compiled.module instanceof W.Module);
  check("instantiate(bytes)", instantiated !== null && instantiated.module instanceof W.Module &&
    instantiated.instance instanceof W.Instance && instantiated.instance.exports.add(1, 1) === 2 &&
    Object.getPrototypeOf(instantiated) === Object.prototype);
  check("instantiate(module)", fromModule instanceof W.Instance);
  check("compile rejects with a CompileError", compileError instanceof W.CompileError);
  check("instantiate rejects with a LinkError", linkError instanceof W.LinkError);
  check("instantiateStreaming", streamed !== null && streamed.instance.exports.add(2, 2) === 4);
  check("compileStreaming wants application/wasm", wrongType instanceof TypeError && textType instanceof TypeError);
  check("compileStreaming wants an ok status", notOk instanceof TypeError);
  check("instantiateStreaming(fetch())", fromFetch !== null && fromFetch.instance.exports.add(20, 22) === 42);
  check("a worker instantiates a Module it was sent", workerResult !== null && workerResult[0] === true &&
    workerResult[1] === 7 && workerResult[2] === "function");
}
