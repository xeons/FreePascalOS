// IndexedDB cursors and index queries (after web-platform-tests
// IndexedDB/idbcursor-advance.htm, idbcursor-continue.htm,
// idbcursor-continuePrimaryKey.htm, idbcursor-direction-index.htm,
// idbindex_getAll.htm and idbcursor_update_index.htm): advance and
// continue to a key, continuePrimaryKey, the four directions over an
// index with duplicate keys, ranges, counts, getAll with a count, and
// updating and deleting through a cursor while iterating.
var log = {};
function collect(request, name, map) {
  var items = [];
  request.onsuccess = function () {
    var cursor = request.result;
    if (!cursor) {
      log[name] = items.join(" ");
      return;
    }
    items.push(map(cursor));
    if (name === "advance") cursor.advance(2);
    else cursor.continue();
  };
}

var opening = indexedDB.open("cursors", 1);
opening.onupgradeneeded = function () {
  var store = opening.result.createObjectStore("s", { keyPath: "id" });
  store.createIndex("color", "color");
  var colors = ["red", "blue", "red", "green", "blue", "red"];
  for (var id = 1; id <= 6; id++) store.add({ id: id, color: colors[id - 1] });
};
opening.onsuccess = function () {
  var db = opening.result;
  var transaction = db.transaction("s", "readwrite");
  var store = transaction.objectStore("s");
  var index = store.index("color");
  var pair = function (c) { return c.key + "=" + c.primaryKey; };
  collect(store.openCursor(), "advance", function (c) { return c.key; });
  collect(index.openCursor(null, "next"), "next", pair);
  collect(index.openCursor(null, "nextunique"), "nextunique", pair);
  collect(index.openCursor(null, "prev"), "prev", pair);
  collect(index.openCursor(null, "prevunique"), "prevunique", pair);
  collect(index.openKeyCursor(IDBKeyRange.bound("blue", "green")), "range", pair);
  collect(store.openKeyCursor(IDBKeyRange.bound(2, 5, true, true), "prev"), "storeRange", function (c) { return c.key; });
  index.count("red").onsuccess = function (e) { log.count = e.target.result; };
  index.getAll("red", 2).onsuccess = function (e) { log.getAll = e.target.result.map(function (r) { return r.id; }).join(); };
  index.getAllKeys().onsuccess = function (e) { log.getAllKeys = e.target.result.join(); };
  index.getKey("green").onsuccess = function (e) { log.getKey = e.target.result; };
  store.getAll(null, 3).onsuccess = function (e) { log.limit = e.target.result.length; };

  var jumped = [];
  var jumping = index.openCursor();
  jumping.onsuccess = function () {
    var cursor = jumping.result;
    if (!cursor) {
      log.continueKey = jumped.join(" ");
      return;
    }
    jumped.push(pair(cursor));
    if (cursor.key === "blue" && cursor.primaryKey === 2) cursor.continue("red");
    else if (cursor.key === "red" && cursor.primaryKey === 1) cursor.continuePrimaryKey("red", 6);
    else cursor.continue();
  };

  var errors = [];
  var checking = index.openCursor(null, "nextunique");
  checking.onsuccess = function () {
    var cursor = checking.result;
    if (!cursor) return;
    try { cursor.continuePrimaryKey("z", 1); } catch (e) { errors.push(e.name); }
    try { cursor.continue("a"); } catch (e) { errors.push(e.name); }
    try { cursor.advance(0); } catch (e) { errors.push(e.name); }
    cursor.continue();
    try { cursor.continue(); } catch (e) { errors.push(e.name); }
    log.errors = errors.join();
    checking.onsuccess = null;
  };

  transaction.oncomplete = function () {
    var writer = db.transaction("s", "readwrite");
    var changing = writer.objectStore("s").index("color").openCursor("red");
    changing.onsuccess = function () {
      var cursor = changing.result;
      if (!cursor) return;
      if (cursor.primaryKey === 1) cursor.update({ id: 1, color: "crimson" });
      if (cursor.primaryKey === 3) cursor.delete();
      cursor.continue();
    };
    var mismatch = null;
    var other = writer.objectStore("s").openCursor(2);
    other.onsuccess = function () {
      if (!other.result) return;
      try { other.result.update({ id: 99 }); } catch (e) { mismatch = e.name; }
      log.mismatch = mismatch;
    };
    writer.oncomplete = function () {
      db.transaction("s").objectStore("s").getAll().onsuccess = function (e) {
        log.after = e.target.result.map(function (r) { return r.id + r.color; }).join();
      };
    };
  };
};

function after() {
  check("advance(2)", log.advance === "1 3 5");
  check("next over an index", log.next === "blue=2 blue=5 green=4 red=1 red=3 red=6");
  check("nextunique", log.nextunique === "blue=2 green=4 red=1");
  check("prev", log.prev === "red=6 red=3 red=1 green=4 blue=5 blue=2");
  check("prevunique takes each key's first record", log.prevunique === "red=1 green=4 blue=2");
  check("an index range", log.range === "blue=2 blue=5 green=4");
  check("an open store range backwards", log.storeRange === "4 3");
  check("count, getAll with a count, getAllKeys, getKey", log.count === 3 && log.getAll === "1,3" &&
    log.getAllKeys === "2,5,4,1,3,6" && log.getKey === 4 && log.limit === 3);
  check("continue(key) and continuePrimaryKey", log.continueKey === "blue=2 red=1 red=6");
  check("cursor argument checks", log.errors === "InvalidAccessError,DataError,TypeError,InvalidStateError");
  check("update with another in-line key is a DataError", log.mismatch === "DataError");
  check("update and delete while iterating", log.after === "1crimson,2blue,4green,5blue,6red");
}
