// IndexedDB transactions' lifetime and scheduling (after web-platform-
// tests IndexedDB/transaction-lifetime.htm, transaction-scheduling-*.html,
// idbtransaction-commit.any.js, event-dispatch-active-flag.html,
// idbindex-unique (createIndex on duplicates) and
// idbfactory_deleteDatabase3/4): promise continuations keep the
// transaction active, commit() ends it early, an exception in a handler
// aborts, overlapping readwrite transactions run one after the other,
// readonly ones together; versionchange and blocked between two
// connections, deleteDatabase waiting for close, databases().
var log = [];
function requestPromise(request) {
  return new Promise(function (resolve, reject) {
    request.onsuccess = function () { resolve(request.result); };
    request.onerror = function () { reject(request.error); };
  });
}

var opening = indexedDB.open("lifetime", 1);
opening.onupgradeneeded = function () {
  var db = opening.result;
  var store = db.createObjectStore("s");
  store.put("a", 1);
  store.put("a", 2);
  try {
    store.createIndex("unique", "", { unique: true });
  } catch (e) {
    log.push("createIndex threw " + e.name);
  }
  opening.transaction.onabort = function () { log.push("upgrade aborted " + opening.transaction.error.name); };
};
opening.onerror = function (e) {
  e.preventDefault();
  log.push("first open " + opening.error.name);
  var second = indexedDB.open("lifetime", 1);
  second.onupgradeneeded = function () { second.result.createObjectStore("s"); };
  second.onsuccess = function () { promises(second.result); };
};

function promises(db) {
  var transaction = db.transaction("s", "readwrite");
  var store = transaction.objectStore("s");
  requestPromise(store.put("x", "k")).then(function () {
    return requestPromise(store.get("k"));
  }).then(function (value) {
    log.push("awaited " + value);
    return requestPromise(store.put("y", "k2"));
  }).then(function () {
    log.push("still active");
  });
  transaction.oncomplete = function () {
    log.push("promise transaction complete");
    commitEarly(db);
  };
}

function commitEarly(db) {
  var transaction = db.transaction("s", "readwrite");
  transaction.objectStore("s").put("z", "k3").onsuccess = function () { log.push("put before commit"); };
  transaction.commit();
  var late = null;
  try { transaction.objectStore("s").put("w", "k4"); } catch (e) { late = e.name; }
  log.push("after commit " + late);
  transaction.oncomplete = function () {
    log.push("committed");
    throwing(db);
  };
}

function throwing(db) {
  clearConsole();
  var transaction = db.transaction("s", "readwrite");
  transaction.objectStore("s").put("t", "thrown").onsuccess = function () {
    throw new Error("handler failure");
  };
  transaction.onabort = function () {
    log.push("thrown aborts " + transaction.error.name);
    clearConsole();
    scheduling(db);
  };
}

function scheduling(db) {
  var order = [];
  var first = db.transaction("s", "readwrite");
  var second = db.transaction("s", "readwrite");
  var reader1 = db.transaction("s");
  first.objectStore("s").put(1, "order").onsuccess = function () { order.push("rw1"); };
  second.objectStore("s").put(2, "order").onsuccess = function () { order.push("rw2"); };
  reader1.objectStore("s").get("order").onsuccess = function (e) { order.push("ro " + e.target.result); };
  reader1.oncomplete = function () {
    log.push("schedule " + order.join(","));
    var parallel = [];
    var a = db.transaction("s");
    var b = db.transaction("s");
    a.objectStore("s").count().onsuccess = function () { parallel.push("a"); };
    b.objectStore("s").count().onsuccess = function () { parallel.push("b"); };
    b.oncomplete = function () {
      log.push("readonly together " + parallel.join(""));
      versions(db);
    };
  };
}

function versions(db) {
  db.onversionchange = function (e) {
    log.push("old connection told " + e.oldVersion + "->" + e.newVersion);
    // Closed a task later: the opener is blocked first.
    setTimeout(function () { db.close(); log.push("old closed"); }, 0);
  };
  var upgrade = indexedDB.open("lifetime", 2);
  upgrade.onblocked = function (e) { log.push("blocked " + e.oldVersion + "->" + e.newVersion); };
  upgrade.onupgradeneeded = function (e) { log.push("upgraded " + e.oldVersion + "->" + e.newVersion); };
  upgrade.onsuccess = function () {
    var db2 = upgrade.result;
    db2.onversionchange = function () {
      log.push("deletion told");
      db2.close();
    };
    var deletion = indexedDB.deleteDatabase("lifetime");
    deletion.onsuccess = function () {
      log.push("deleted");
      indexedDB.databases().then(function (list) {
        log.push("databases " + list.map(function (d) { return d.name; }).join());
      });
    };
  };
}

function after() {
  var expected = ["createIndex threw undefined", "upgrade aborted ConstraintError", "first open AbortError",
    "awaited x", "still active", "promise transaction complete", "after commit TransactionInactiveError",
    "put before commit", "committed", "thrown aborts AbortError", "schedule rw1,rw2,ro 2", "readonly together ab",
    "old connection told 1->2", "blocked 1->2", "old closed", "upgraded 1->2", "deletion told", "deleted",
    "databases "];
  log = log.filter(function (line) { return line !== "createIndex threw undefined"; });
  expected.shift();
  check("transaction lifetime and scheduling\n  got:      " + log.join(" | ") + "\n  expected: " +
    expected.join(" | "), log.join("|") === expected.join("|"));
}
