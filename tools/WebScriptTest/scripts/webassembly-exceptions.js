// WebAssembly exception handling in the JS API (WebAssembly.Tag,
// WebAssembly.Exception, WebAssembly.JSTag; JavaScript exceptions through
// WebAssembly frames, WebAssembly exceptions out of them, identity both
// ways), memory64 and table64 (address types, BigInt sizes and indices),
// and both in a dedicated worker. Modules are assembled by a small encoder.

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
function func(params, results) { return [0x60].concat(vec(params), vec(results)); }
function body(code) { var b = vec([]).concat(code, [0x0b]); return uleb(b.length).concat(b); }
function exportOf(text, kind, index) { return name(text).concat([kind], uleb(index)); }
function threw(f, Kind) {
  try { f(); } catch (e) { return Kind === undefined || e instanceof Kind; }
  return false;
}
function thrown(f) {
  try { f(); } catch (e) { return e; }
  return "nothing thrown";
}
var W = WebAssembly;
var I32 = [0x7f], EXTERN = [0x6f];

// ---- the interfaces ----
check("Tag, Exception and JSTag exist", typeof W.Tag === "function" && typeof W.Exception === "function" &&
  W.JSTag instanceof W.Tag && W.JSTag === W.JSTag && W.Tag.length === 1 && W.Exception.length === 2 &&
  String(W.Tag.prototype) === "[object WebAssembly.Tag]" &&
  String(W.Exception.prototype) === "[object WebAssembly.Exception]" &&
  Object.getOwnPropertyDescriptor(W, "JSTag").get !== undefined);
check("Tag needs new and a parameters sequence", threw(function () { W.Tag({ parameters: [] }); }, TypeError) &&
  threw(function () { new W.Tag({}); }, TypeError) && threw(function () { new W.Tag({ parameters: ["i16"] }); },
  TypeError) && new W.Tag({ parameters: ["i32", "externref", "anyref"] }) instanceof W.Tag);
var tagI32 = new W.Tag({ parameters: ["i32"] });
var tagRef = new W.Tag({ parameters: ["externref"] });
var exn = new W.Exception(tagI32, [42]);
check("an Exception made from JavaScript", exn instanceof W.Exception && !(exn instanceof Error) &&
  exn.is(tagI32) && !exn.is(tagRef) && exn.getArg(tagI32, 0) === 42 && exn.stack === undefined &&
  threw(function () { exn.getArg(tagRef, 0); }, TypeError) && threw(function () { exn.getArg(tagI32, 1); }, RangeError));
check("Exception checks its payload", threw(function () { new W.Exception(tagI32, []); }, TypeError) &&
  threw(function () { new W.Exception(tagI32, [1n]); }, TypeError) &&
  threw(function () { new W.Exception(tagI32, 5); }, TypeError) &&
  threw(function () { new W.Exception(W.JSTag, [{}]); }, TypeError));
check("traceStack gives a stack", typeof new W.Exception(tagI32, [1], { traceStack: true }).stack === "string");
class MyException extends W.Exception {}
check("Exception can be subclassed", new MyException(tagI32, [1]) instanceof MyException);

// ---- a module that throws and catches ----
// imports: env.js (func () -> ()), env.jsTag (tag (externref)), env.tagI32 (tag (i32))
// tags: 2 (externref), 3 (i32), exported
var types = [func([EXTERN], []), func([I32], []), func([], []), func([], [EXTERN]),
  func([], [I32])];
var bodies = [
  [0x20, 0, 0x08, 2],                                                                   // throwRef(v)
  [0x20, 0, 0x08, 3],                                                                   // throwI32(n)
  [0x02, 0x6f, 0x1f, 0x40, 0x01, 0x00, 0x00, 0x00, 0x10, 0x00, 0x0b, 0xd0, 0x6f, 0x0f, 0x0b],   // catchJs
  [0x02, 0x69, 0x1f, 0x40, 0x01, 0x03, 0x00, 0x10, 0x00, 0x0b, 0x0f, 0x0b, 0x0a],             // rethrowAll
  [0x02, 0x40, 0x1f, 0x40, 0x01, 0x02, 0x00, 0x10, 0x00, 0x0b, 0x41, 0x00, 0x0f, 0x0b, 0x41, 0x01], // catchAll
  [0x02, 0x7f, 0x1f, 0x40, 0x01, 0x00, 0x01, 0x00, 0x10, 0x00, 0x0b, 0x41, 0x7f, 0x0f, 0x0b],   // catchI32
  [0x20, 0, 0x08, 0],                                                                   // throwJs(v)
  [0x02, 0x40, 0x1f, 0x40, 0x01, 0x02, 0x00, 0x00, 0x0b, 0x0b]                         // trapInside
];
var exceptionModule = new W.Module(wasm([
  sec(1, vec(types)),
  sec(2, vec([name("env").concat(name("js"), [0, 2]), name("env").concat(name("jsTag"), [4, 0, 0]),
    name("env").concat(name("tagI32"), [4, 0, 1])])),
  sec(3, vec([[0], [1], [3], [2], [4], [4], [0], [2]])),
  sec(13, vec([[0, 0], [0, 1]])),
  sec(7, vec([exportOf("throwRef", 0, 1), exportOf("throwI32", 0, 2), exportOf("catchJs", 0, 3),
    exportOf("rethrowAll", 0, 4), exportOf("catchAll", 0, 5), exportOf("catchI32", 0, 6), exportOf("throwJs", 0, 7), exportOf("trapInside", 0, 8),
    exportOf("refTag", 4, 2), exportOf("i32Tag", 4, 3), exportOf("importedTag", 4, 1)])),
  sec(10, vec(bodies.map(body)))
]));
check("Module descriptors list tags", W.Module.imports(exceptionModule)[1].kind === "tag" &&
  W.Module.exports(exceptionModule)[8].kind === "tag");
var thrower = null;
var x = new W.Instance(exceptionModule, { env: { js: function () { thrower(); }, jsTag: W.JSTag, tagI32: tagI32 } })
  .exports;
check("exported tags are Tags, one object each", x.refTag instanceof W.Tag && x.refTag === x.refTag &&
  x.importedTag === tagI32 && x.refTag !== x.i32Tag);
check("a tag import must be a Tag", threw(function () {
  new W.Instance(exceptionModule, { env: { js: function () {}, jsTag: {}, tagI32: tagI32 } }); }, W.LinkError) &&
  threw(function () {
  new W.Instance(exceptionModule, { env: { js: function () {}, jsTag: W.JSTag, tagI32: tagRef } }); }, W.LinkError));
var fromWasm = thrown(function () { x.throwI32(7); });
check("a WebAssembly exception comes out as a WebAssembly.Exception", fromWasm instanceof W.Exception &&
  fromWasm.is(x.i32Tag) && fromWasm.getArg(x.i32Tag, 0) === 7 && !(fromWasm instanceof Error));
var payload = { p: true };
var refException = thrown(function () { x.throwRef(payload); });
check("its externref payload is the value thrown", refException.getArg(x.refTag, 0) === payload);
var error = new Error("from JavaScript");
thrower = function () { throw error; };
check("a JavaScript exception is caught by catch $JSTag as its value", x.catchJs() === error);
check("and by catch_all", x.catchAll() === 1);
check("rethrown by throw_ref it comes out unchanged", thrown(function () { x.rethrowAll(); }) === error);
thrower = function () { throw 42; };
check("a thrown number too", x.catchJs() === 42 && thrown(function () { x.rethrowAll(); }) === 42);
thrower = function () { throw 4.5; };
check("and an odd one", thrown(function () { x.rethrowAll(); }) === 4.5 && x.catchJs() === 4.5);
thrower = function () { throw exn; };
check("a WebAssembly.Exception thrown into WebAssembly keeps its identity", x.catchI32() === 42 &&
  thrown(function () { x.rethrowAll(); }) === exn && thrown(function () { x.catchJs(); }) === exn);
var caught = null;
thrower = function () { try { x.throwI32(9); } catch (e) { caught = e; throw e; } };
var again = thrown(function () { x.rethrowAll(); });
check("an exception out of WebAssembly and back is the same object", again === caught &&
  thrown(function () { x.catchI32(); }) === caught && caught.getArg(x.i32Tag, 0) === 9);
check("throw with the JavaScript tag throws the value", thrown(function () { x.throwJs(payload); }) === payload);
thrower = function () { throw new W.Exception(x.refTag, [payload]); };
check("catch_all sees WebAssembly.Exceptions made in JavaScript", x.catchAll() === 1 &&
  thrown(function () { x.catchI32(); }).is(x.refTag));
thrower = function () { throw new W.Exception(tagRef, [1]); };
check("an Exception of another tag passes through", thrown(function () { x.catchI32(); }).is(tagRef));
gc();
check("exceptions survive a collection", refException.getArg(x.refTag, 0) === payload &&
  thrown(function () { x.rethrowAll(); }).getArg(tagRef, 0) === 1);
check("a trap is not caught by catch_all", threw(function () { x.trapInside(); }, W.RuntimeError));
thrower = function () { new W.Instance(new W.Module(wasm([sec(1, vec([func([], [])])), sec(3, vec([[0]])),
  sec(8, uleb(0)), sec(10, vec([body([0x00])]))]))); };
check("but the RuntimeError of a trap in a nested call, once JavaScript, is", x.catchAll() === 1 &&
  x.catchJs() instanceof W.RuntimeError);
check("exnref types cannot cross to JavaScript", threw(function () {
  new W.Instance(new W.Module(wasm([sec(1, vec([func([[0x69]], [])])), sec(3, vec([[0]])),
    sec(7, vec([exportOf("f", 0, 0)])), sec(10, vec([body([])]))]))).exports.f(null); }, TypeError));

// ---- memory64 and table64 ----
var memory64 = new W.Memory({ address: "i64", initial: 1n, maximum: 4n });
check("an i64 memory", memory64.buffer.byteLength === 65536 && memory64.grow(1n) === 1n &&
  memory64.buffer.byteLength === 131072 && threw(function () { memory64.grow(1); }, TypeError) &&
  threw(function () { new W.Memory({ address: "i64", initial: -1n }); }, TypeError) &&
  threw(function () { new W.Memory({ address: "i64", initial: 2n ** 64n }); }, TypeError) &&
  threw(function () { new W.Memory({ address: "i128", initial: 1 }); }, TypeError) &&
  threw(function () { memory64.grow(10n); }, RangeError) && new W.Memory({ initial: 1 }).grow(0) === 1);
var table64 = new W.Table({ element: "externref", address: "i64", initial: 2n });
check("an i64 table", table64.length === 2n && table64.get(0n) === undefined && (table64.set(1n, payload),
  table64.get(1n) === payload) && table64.grow(1n, 3) === 2n && table64.get(2n) === 3 &&
  threw(function () { table64.get(1); }, TypeError) && threw(function () { table64.get(5n); }, RangeError));
// imports an i64 memory and an i64 table; load(i64 address) -> i32, size() -> i64
var module64 = new W.Module(wasm([
  sec(1, vec([func([[0x7e]], [I32]), func([], [[0x7e]])])),
  sec(2, vec([name("env").concat(name("memory"), [2, 0x04, 1]),
    name("env").concat(name("table"), [1, 0x6f, 0x04, 1])])),
  sec(3, vec([[0], [1]])),
  sec(7, vec([exportOf("load", 0, 0), exportOf("size", 0, 1), exportOf("memory", 2, 0), exportOf("table", 1, 0)])),
  sec(10, vec([body([0x20, 0, 0x28, 2, 0]), body([0x3f, 0])]))
]));
new Uint8Array(memory64.buffer)[70000] = 9;
var m64 = new W.Instance(module64, { env: { memory: memory64, table: table64 } }).exports;
check("a module of i64 memories and tables", m64.load(70000n) === 9 && m64.size() === 2n &&
  m64.memory === memory64 && m64.table === table64 && threw(function () {
  new W.Instance(module64, { env: { memory: new W.Memory({ initial: 1 }), table: table64 } }); }, W.LinkError));

// ---- in a dedicated worker ----
var workerResult = null;
var workerSource = "onmessage = function (event) {" +
  "  var W = WebAssembly, tag = new W.Tag({ parameters: ['externref'] }), value = { v: 1 }, out = [];" +
  "  var e = new W.Exception(tag, [value]);" +
  "  out.push(e.getArg(tag, 0) === value, W.JSTag instanceof W.Tag, e instanceof W.Exception);" +
  "  var x = new W.Instance(event.data.module, { env: { js: function () { throw value; }, jsTag: W.JSTag," +
  "    tagI32: new W.Tag({ parameters: ['i32'] }) } }).exports;" +
  "  out.push(x.catchJs() === value);" +
  "  try { x.throwI32(3); } catch (c) { out.push(c instanceof W.Exception && c.getArg(x.i32Tag, 0) === 3); }" +
  "  var r = new W.Instance(event.data.references).exports, box = r.makeBox(value);" +
  "  out.push(Object.getPrototypeOf(box) === null && r.unbox(box) === value);" +
  "  out.push(new W.Memory({ address: 'i64', initial: 1n }).grow(0n) === 1n);" +
  "  postMessage(out);" +
  "};";
var referencesModule = new W.Module(wasm([
  sec(1, vec([[0x5f].concat(vec([EXTERN.concat([1])])), func([EXTERN], [[0x64, 0]]), func([[0x63, 0]], [EXTERN])])),
  sec(3, vec([[1], [2]])),
  sec(7, vec([exportOf("makeBox", 0, 0), exportOf("unbox", 0, 1)])),
  sec(10, vec([body([0x20, 0, 0xfb, 0x00, 0]), body([0x20, 0, 0xfb, 0x02, 0, 0])]))
]));
var worker = new Worker(URL.createObjectURL(new Blob([workerSource], { type: "text/javascript" })));
worker.onmessage = function (event) { workerResult = event.data; };
worker.postMessage({ module: exceptionModule, references: referencesModule });

function after() {
  check("a worker has Tag, Exception and JSTag", workerResult !== null && workerResult[0] === true &&
    workerResult[1] === true && workerResult[2] === true);
  check("a worker's JavaScript exceptions go through WebAssembly", workerResult !== null && workerResult[3] === true &&
    workerResult[4] === true);
  check("a worker's GC objects", workerResult !== null && workerResult[5] === true);
  check("a worker's i64 memories", workerResult !== null && workerResult[6] === true);
}
