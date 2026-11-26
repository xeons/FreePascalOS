// IndexedDB values and keys: what structured serialization keeps through
// the storage service (Blob, File, typed arrays sharing a buffer, Map,
// Set, Date, RegExp, BigInt, errors, cycles, holes), what it refuses
// (DataCloneError, thrown at once), and the order of every key type
// (after web-platform-tests IndexedDB/keyorder.htm and key_valid.html).
var results = {};
var request = indexedDB.open("values", 1);
request.onupgradeneeded = function () {
  var db = request.result;
  db.createObjectStore("things");
  db.createObjectStore("keys");
};
request.onsuccess = function () {
  var db = request.result;
  var transaction = db.transaction(["things", "keys"], "readwrite");
  var things = transaction.objectStore("things");
  var buffer = new ArrayBuffer(8);
  var shared = { name: "shared" };
  var cyclic = { label: "cycle" };
  cyclic.self = cyclic;
  var sparse = [1, , 3];
  sparse.extra = "x";
  var map = new Map([["a", 1], [shared, shared]]);
  var value = {
    blob: new Blob(["blob text"], { type: "text/plain" }),
    file: new File(["file text"], "notes.txt", { type: "text/plain", lastModified: 12345 }),
    bytes: new Uint8Array([1, 2, 3]),
    halves: [new Uint16Array(buffer, 0, 2), new Uint8Array(buffer, 4, 4)],
    view: new DataView(new ArrayBuffer(4)),
    floats: new Float64Array([0.5, -Infinity]),
    big: 12345678901234567890n,
    map: map,
    set: new Set([1, "two", shared]),
    date: new Date(1700000000000),
    regexp: /ab+c/gi,
    error: new RangeError("out of range"),
    exception: new DOMException("gone", "NotFoundError"),
    boxed: [new String("s"), new Number(5), new Boolean(false)],
    cyclic: cyclic,
    sparse: sparse,
    text: "lone \ud800 surrogate and é中",
    negativeZero: -0,
    nothing: undefined
  };
  value.halves[0][0] = 513;
  value.view.setInt16(0, -2);
  things.put(value, "everything");
  var refused = [];
  [function () {}, Symbol("s"), document.body, new WeakMap()].forEach(function (bad) {
    try { things.put({ bad: bad }, "bad"); } catch (e) { refused.push(e.name); }
  });
  results.refused = refused.join();
  var keys = transaction.objectStore("keys");
  var allKeys = [[1], "b", new Date(2), new Uint8Array([2]).buffer, -Infinity, "a", 3, [0, "x"], new Date(1),
    Infinity, new Uint8Array([1, 0]), "", [], [[]], -0.5, new Uint8Array([])];
  allKeys.forEach(function (key, index) { keys.put(index, key); });
  var invalid = [];
  [NaN, null, {}, [NaN], new Date(NaN), true].forEach(function (bad) {
    try { keys.put(0, bad); } catch (e) { invalid.push(e.name); }
  });
  results.invalid = invalid.join();
  things.get("everything").onsuccess = function (e) { results.back = e.target.result; };
  keys.getAllKeys().onsuccess = function (e) { results.keys = e.target.result; };
  keys.getAll().onsuccess = function (e) { results.order = e.target.result.join(); };
  transaction.oncomplete = function () {
    var back = results.back;
    results.blobType = back.blob instanceof Blob && back.blob.type;
    results.fileName = back.file instanceof File && back.file.name + ":" + back.file.lastModified;
    back.blob.text().then(function (text) { results.blobText = text; });
    back.file.text().then(function (text) { results.fileText = text; });
  };
};

function after() {
  var back = results.back;
  check("non-serializable values throw DataCloneError at once", results.refused ===
    "DataCloneError,DataCloneError,DataCloneError,DataCloneError");
  check("invalid keys throw DataError", results.invalid === "DataError,DataError,DataError,DataError,DataError,DataError");
  check("a value comes back", back !== undefined && back !== null);
  if (!back) return;
  check("Blob and File keep their bytes and attributes", results.blobType === "text/plain" &&
    results.fileName === "notes.txt:12345" && results.blobText === "blob text" && results.fileText === "file text");
  check("typed arrays", back.bytes instanceof Uint8Array && back.bytes.join() === "1,2,3" &&
    back.floats[1] === -Infinity && back.view.getInt16(0) === -2);
  check("views of one buffer still share it", back.halves[0].buffer === back.halves[1].buffer &&
    back.halves[0][0] === 513 && back.halves[0].buffer.byteLength === 8);
  check("BigInt", back.big === 12345678901234567890n);
  check("Map and Set keep entries and shared objects", back.map instanceof Map && back.map.get("a") === 1 &&
    back.set instanceof Set && back.set.has("two") && Array.from(back.map.keys())[1] === Array.from(back.set)[2]);
  check("Date and RegExp", back.date instanceof Date && back.date.getTime() === 1700000000000 &&
    back.regexp instanceof RegExp && back.regexp.source === "ab+c" && back.regexp.flags === "gi");
  check("errors", back.error instanceof RangeError && back.error.message === "out of range" &&
    back.exception instanceof DOMException && back.exception.name === "NotFoundError");
  check("boxed primitives", back.boxed[0] instanceof String && back.boxed[0].valueOf() === "s" &&
    back.boxed[1].valueOf() === 5 && back.boxed[2].valueOf() === false);
  check("cycles", back.cyclic.self === back.cyclic && back.cyclic.label === "cycle");
  check("holes and extra properties of arrays", back.sparse.length === 3 && !(1 in back.sparse) &&
    back.sparse[2] === 3 && back.sparse.extra === "x");
  check("strings keep lone surrogates", back.text === "lone \ud800 surrogate and é中");
  check("negative zero and undefined", Object.is(back.negativeZero, -0) && "nothing" in back &&
    back.nothing === undefined);
  check("keys sort: numbers, dates, strings, binary, arrays (got " + results.order + ")",
    results.order === "4,14,6,9,8,2,11,5,1,15,10,3,12,7,0,13");
}
