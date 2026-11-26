// IndexedDB: opening and upgrading, object stores with in-line and
// out-of-line keys and key generators, add/put/get/getAll/count/delete,
// indexes (unique, multiEntry), cursors, transactions' lifetime,
// auto-commit, abort and the events that come with them.
var log = [];
check("indexedDB is exposed", typeof indexedDB === "object" && indexedDB instanceof IDBFactory &&
  String(indexedDB) === "[object IDBFactory]");
check("cmp orders keys by type then value", indexedDB.cmp(1, 2) === -1 && indexedDB.cmp("a", 1) === 1 &&
  indexedDB.cmp([1], "z") === 1 && indexedDB.cmp(new Date(5), 9e99) === 1 && indexedDB.cmp(-0, 0) === 0 &&
  indexedDB.cmp(new Uint8Array([1]).buffer, "z") === 1 && indexedDB.cmp([1, 2], [1, 2]) === 0 &&
  indexedDB.cmp([1], [1, 0]) === -1 && indexedDB.cmp("ab", "b") === -1 && indexedDB.cmp(-Infinity, -1) === -1);
var cmpError = null;
try { indexedDB.cmp({}, 1); } catch (e) { cmpError = e.name; }
check("cmp refuses non-keys", cmpError === "DataError");
var rangeError = null;
try { IDBKeyRange.bound(2, 1); } catch (e) { rangeError = e.name; }
check("key ranges", IDBKeyRange.only(3).lower === 3 && IDBKeyRange.lowerBound(1, true).lowerOpen &&
  IDBKeyRange.upperBound("x").upper === "x" && IDBKeyRange.bound(1, 5).includes(3) &&
  !IDBKeyRange.bound(1, 5, true).includes(1) && rangeError === "DataError");
var versionError = null;
try { indexedDB.open("x", 0); } catch (e) { versionError = e.name; }
check("open refuses version 0", versionError === "TypeError");

var opened = indexedDB.open("library", 2);
check("open returns a pending IDBOpenDBRequest", opened instanceof IDBOpenDBRequest && opened.readyState === "pending");
opened.onupgradeneeded = function (event) {
  log.push("upgradeneeded " + event.oldVersion + " " + event.newVersion);
  var db = opened.result;
  check("upgrade transaction", opened.transaction.mode === "versionchange" && opened.transaction.db === db &&
    db.version === 2);
  var books = db.createObjectStore("books", { keyPath: "isbn" });
  books.createIndex("by_title", "title", { unique: true });
  books.createIndex("by_author", "author");
  books.createIndex("by_tag", "tags", { multiEntry: true });
  books.put({ title: "Quarry Memories", author: "Fred", isbn: 123456, tags: ["stone", "memoir"] });
  books.put({ title: "Water Buffaloes", author: "Fred", isbn: 234567, tags: ["animals"] });
  books.put({ title: "Bedrock Nights", author: "Barney", isbn: 345678, tags: ["stone", "night", "stone"] });
  var counter = db.createObjectStore("counter", { autoIncrement: true });
  counter.add("first");
  counter.add("second");
  counter.put("tenth", 10);
  counter.add("eleventh").onsuccess = function (e) { log.push("generated " + e.target.result); };
  var nested = db.createObjectStore("nested", { keyPath: "a.b", autoIncrement: true });
  nested.add({ name: "x" }).onsuccess = function (e) { log.push("injected " + e.target.result); };
  var duplicateName = null;
  try { db.createObjectStore("books"); } catch (e) { duplicateName = e.name; }
  check("a second store of the same name is a ConstraintError", duplicateName === "ConstraintError");
  check("objectStoreNames sorted", Array.from(db.objectStoreNames).join() === "books,counter,nested" &&
    db.objectStoreNames.contains("books") && db.objectStoreNames.item(0) === "books" && db.objectStoreNames[1] === "counter");
};
opened.onsuccess = function () {
  log.push("open success");
  var db = opened.result;
  check("opened database", db instanceof IDBDatabase && db.name === "library" && db.version === 2 &&
    opened.transaction === null);
  readBack(db);
};
opened.onerror = function () { log.push("open error " + opened.error.name); };

function readBack(db) {
  var transaction = db.transaction(["books", "counter", "nested"]);
  check("readonly transaction", transaction.mode === "readonly" && transaction.durability === "default" &&
    Array.from(transaction.objectStoreNames).join() === "books,counter,nested");
  var books = transaction.objectStore("books");
  check("the same store object", transaction.objectStore("books") === books && books.keyPath === "isbn" &&
    Array.from(books.indexNames).join() === "by_author,by_tag,by_title");
  books.get(234567).onsuccess = function (e) { log.push("get " + e.target.result.title); };
  books.index("by_title").get("Bedrock Nights").onsuccess = function (e) { log.push("by title " + e.target.result.isbn); };
  books.index("by_author").getAll("Fred").onsuccess = function (e) {
    log.push("by author " + e.target.result.map(function (b) { return b.isbn; }).join());
  };
  books.index("by_tag").getAllKeys("stone").onsuccess = function (e) { log.push("by tag " + e.target.result.join()); };
  books.index("by_tag").count().onsuccess = function (e) { log.push("tag entries " + e.target.result); };
  books.count(IDBKeyRange.lowerBound(200000)).onsuccess = function (e) { log.push("count " + e.target.result); };
  transaction.objectStore("counter").getAllKeys().onsuccess = function (e) { log.push("counter keys " + e.target.result.join()); };
  transaction.objectStore("nested").getAll().onsuccess = function (e) { log.push("nested " + JSON.stringify(e.target.result)); };
  var cursorKeys = [];
  books.openCursor(null, "prev").onsuccess = function (e) {
    var cursor = e.target.result;
    if (cursor) {
      cursorKeys.push(cursor.key + ":" + cursor.value.title);
      cursor.continue();
    } else log.push("cursor " + cursorKeys.join());
  };
  var uniqueAuthors = [];
  books.index("by_author").openKeyCursor(null, "nextunique").onsuccess = function (e) {
    var cursor = e.target.result;
    if (cursor) {
      uniqueAuthors.push(cursor.key + "=" + cursor.primaryKey);
      cursor.continue();
    } else log.push("unique authors " + uniqueAuthors.join());
  };
  transaction.oncomplete = function () {
    log.push("read complete");
    writeAndFail(db);
  };
  var inactive = null;
  setTimeout(function () {
    try { books.get(1); } catch (e) { inactive = e.name; }
    check("a transaction is inactive outside its tasks", inactive === "TransactionInactiveError");
  }, 0);
}

function writeAndFail(db) {
  var transaction = db.transaction("books", "readwrite");
  var books = transaction.objectStore("books");
  books.add({ title: "Quarry Memories", author: "Wilma", isbn: 999 }).onerror = function (e) {
    log.push("unique violation " + e.target.error.name);
    e.preventDefault();
  };
  books.put({ title: "New Book", author: "Wilma", isbn: 777 });
  books.add({ title: "Another", isbn: 123456 }).onerror = function (e) {
    log.push("key exists " + e.target.error.name);
  };
  transaction.onerror = function (e) { log.push("transaction saw " + e.target.error.name); };
  db.onerror = function (e) { log.push("database saw " + e.target.error.name); };
  transaction.onabort = function () {
    log.push("aborted " + transaction.error.name);
    db.onerror = null;
    afterAbort(db);
  };
}

function afterAbort(db) {
  var transaction = db.transaction("books", "readwrite");
  var books = transaction.objectStore("books");
  books.get(777).onsuccess = function (e) { log.push("after abort " + e.target.result); };
  books.delete(IDBKeyRange.bound(200000, 300000));
  var cursor = books.openCursor();
  cursor.onsuccess = function () {
    var c = cursor.result;
    if (!c) return;
    if (c.key === 123456) c.update({ title: "Quarry Memories 2", author: "Fred", isbn: 123456, tags: [] });
    else if (c.key === 345678) c.delete();
    c.continue();
  };
  transaction.oncomplete = function () {
    var check_ = db.transaction("books").objectStore("books");
    check_.getAll().onsuccess = function (e) {
      log.push("final " + e.target.result.map(function (b) { return b.title; }).join());
      explicitAbort(db);
    };
  };
}

function explicitAbort(db) {
  var transaction = db.transaction("counter", "readwrite");
  var request = transaction.objectStore("counter").put("gone", 50);
  request.onerror = function (e) {
    log.push("pending request " + e.target.error.name);
    e.preventDefault();
  };
  transaction.abort();
  check("abort finishes the transaction", (function () {
    try { transaction.abort(); } catch (e) { return e.name === "InvalidStateError"; }
    return false;
  })());
  transaction.onabort = function () {
    log.push("explicit abort error " + transaction.error);
    var reader = db.transaction("counter").objectStore("counter");
    reader.get(50).onsuccess = function (e) {
      log.push("counter 50 " + e.target.result);
      reopen(db);
    };
  };
}

function reopen(db) {
  db.onversionchange = function (e) {
    log.push("versionchange " + e.oldVersion + " " + e.newVersion);
    db.close();
  };
  var request = indexedDB.open("library", 3);
  request.onblocked = function () { log.push("blocked"); };
  request.onupgradeneeded = function (e) {
    log.push("upgrade " + e.oldVersion + " " + e.newVersion);
    var upgrade = request.transaction;
    upgrade.objectStore("books").name = "volumes";
    request.result.deleteObjectStore("nested");
    upgrade.abort();
  };
  request.onerror = function (e) {
    log.push("upgrade aborted " + request.error.name);
    e.preventDefault();
    var again = indexedDB.open("library");
    again.onsuccess = function () {
      var db2 = again.result;
      log.push("reopened " + db2.version + " " + Array.from(db2.objectStoreNames).join());
      db2.close();
      var deletion = indexedDB.deleteDatabase("library");
      deletion.onsuccess = function (e) {
        log.push("deleted " + e.oldVersion + " " + e.newVersion);
        indexedDB.databases().then(function (list) { log.push("databases " + list.length); });
      };
    };
  };
}

function after() {
  var expected = [
    "upgradeneeded 0 2", "generated 11", "injected 1", "open success",
    "get Water Buffaloes", "by title 345678", "by author 123456,234567", "by tag 123456,345678", "tag entries 5",
    "count 2", "counter keys 1,2,10,11", "nested [{\"name\":\"x\",\"a\":{\"b\":1}}]",
    "unique authors Barney=345678,Fred=123456",
    "cursor 345678:Bedrock Nights,234567:Water Buffaloes,123456:Quarry Memories", "read complete",
    // preventDefault keeps the transaction, the event still bubbles.
    "unique violation ConstraintError", "transaction saw ConstraintError", "database saw ConstraintError",
    "key exists ConstraintError", "transaction saw ConstraintError", "database saw ConstraintError",
    "aborted ConstraintError",
    "after abort undefined", "final Quarry Memories 2",
    "pending request AbortError", "explicit abort error null", "counter 50 undefined",
    // close() waits for the reading transaction still running: blocked.
    "versionchange 2 3", "blocked", "upgrade 2 3", "upgrade aborted AbortError", "reopened 2 books,counter,nested",
    "deleted 2 null", "databases 0"];
  check("IndexedDB event order" + "\n  got:      " + log.join(" | ") + "\n  expected: " + expected.join(" | "),
    log.join("|") === expected.join("|"));
}
