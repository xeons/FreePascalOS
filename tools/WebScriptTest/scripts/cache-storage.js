// The Cache API and navigator.storage (after web-platform-tests
// service-workers/cache-storage/cache-put.https.any.js, cache-match,
// cache-matchAll, cache-keys, cache-delete, cache-storage-keys and
// storage/estimate-indexeddb.https.any.js): caches made, listed in the
// order they were made, deleted; put replaces the entry for the same
// request; match with ignoreSearch, ignoreMethod and Vary; keys and
// delete; what put refuses; estimate grows with stored data; persist.
var log = {};
check("the Cache API is exposed in a secure context", typeof caches === "object" && caches instanceof CacheStorage &&
  typeof Cache === "function" && navigator.storage instanceof StorageManager);

function response(text, init) {
  return new Response(text, init);
}

var started = navigator.storage.estimate().then(function (before) {
  log.quota = before.quota > 0 && before.usage >= 0;
  log.usageBefore = before.usage;
  return caches.open("v1");
}).then(function (cache) {
  log.cache = cache instanceof Cache;
  return cache.put("https://example.test/a.txt?x=1", response("first", { headers: { "Content-Type": "text/plain" } }))
    .then(function () { return cache.put("https://example.test/a.txt?x=1", response("second")); })
    .then(function () {
      return cache.put(new Request("https://example.test/vary"), response("varied",
        { headers: { Vary: "Accept" } }));
    })
    .then(function () { return cache.put("https://example.test/b.txt#fragment", response("bee")); })
    .then(function () { return cache.match("https://example.test/a.txt?x=1"); })
    .then(function (found) { return found.text(); })
    .then(function (text) {
      log.replaced = text;
      return cache.match("https://example.test/a.txt", { ignoreSearch: true });
    })
    .then(function (found) {
      log.ignoreSearch = found !== undefined;
      return cache.match("https://example.test/a.txt");
    })
    .then(function (found) {
      log.searchCounts = found === undefined;
      return cache.match("https://example.test/b.txt");
    })
    .then(function (found) {
      log.fragmentIgnored = found !== undefined && found.status === 200;
      return cache.match(new Request("https://example.test/vary", { headers: { Accept: "text/html" } }));
    })
    .then(function (found) {
      log.varyMismatch = found === undefined;
      return cache.match(new Request("https://example.test/vary", { headers: { Accept: "text/html" } }),
        { ignoreVary: true });
    })
    .then(function (found) {
      log.ignoreVary = found !== undefined;
      return cache.match(new Request("https://example.test/b.txt", { method: "POST" }));
    })
    .then(function (found) {
      log.postMisses = found === undefined;
      return cache.matchAll();
    })
    .then(function (all) {
      log.all = all.length;
      return cache.keys();
    })
    .then(function (requests) {
      log.keys = requests.map(function (r) { return r.url.replace("https://example.test/", ""); }).join(" ");
      return cache.delete("https://example.test/b.txt");
    })
    .then(function (deleted) {
      log.deleted = deleted;
      return cache.delete("https://example.test/never");
    })
    .then(function (deleted) {
      log.notDeleted = deleted === false;
      return cache.put(new Request("https://example.test/p", { method: "POST" }), response("x"))
        .then(function () { log.postPut = "stored"; }, function (e) { log.postPut = e.name; });
    })
    .then(function () {
      return cache.put("https://example.test/partial", response("x", { status: 206 }))
        .then(function () { log.partial = "stored"; }, function (e) { log.partial = e.name; });
    })
    .then(function () {
      var used = response("used");
      return used.text().then(function () {
        return cache.put("https://example.test/used", used).then(function () { log.used = "stored"; },
          function (e) { log.used = e.name; });
      });
    });
}).then(function () {
  return caches.open("v2");
}).then(function () {
  return caches.keys();
}).then(function (names) {
  log.names = names.join();
  return caches.match("https://example.test/vary", { ignoreVary: true });
}).then(function (found) {
  log.storageMatch = found !== undefined;
  return caches.has("v2");
}).then(function (has) {
  log.has = has;
  return caches.delete("v1");
}).then(function (deleted) {
  log.cacheDeleted = deleted;
  return caches.keys();
}).then(function (names) {
  log.namesAfter = names.join();
  return caches.match("https://example.test/vary", { ignoreVary: true });
}).then(function (found) {
  log.goneWithCache = found === undefined;
  return caches.open("big").then(function (cache) {
    return cache.put("https://example.test/big", response(new Uint8Array(100000)));
  });
}).then(function () {
  return navigator.storage.estimate();
}).then(function (after) {
  log.grew = after.usage >= log.usageBefore + 100000;
  return navigator.storage.persisted();
}).then(function (persisted) {
  log.persistedBefore = persisted;
  return navigator.storage.persist();
}).then(function (granted) {
  log.granted = granted;
  return navigator.storage.persisted();
}).then(function (persisted) {
  log.persistedAfter = persisted;
}).catch(function (error) {
  log.failure = String(error);
});

function after() {
  check("no failure " + (log.failure || ""), log.failure === undefined);
  check("estimate before anything", log.quota === true);
  check("open gives a Cache", log.cache === true);
  check("put replaces the entry of the same request", log.replaced === "second");
  check("ignoreSearch", log.ignoreSearch === true && log.searchCounts === true);
  check("fragments never count", log.fragmentIgnored === true);
  check("Vary and ignoreVary", log.varyMismatch === true && log.ignoreVary === true);
  check("a POST request does not match", log.postMisses === true);
  check("matchAll and keys in the order put", log.all === 3 && log.keys === "a.txt?x=1 vary b.txt#fragment");
  check("delete", log.deleted === true && log.notDeleted === true);
  check("put refuses POST, partial responses and used bodies", log.postPut === "TypeError" &&
    log.partial === "TypeError" && log.used === "TypeError");
  check("caches.keys in the order made", log.names === "v1,v2");
  check("caches.match looks in every cache", log.storageMatch === true && log.has === true);
  check("deleting a cache deletes its entries", log.cacheDeleted === true && log.namesAfter === "v2" &&
    log.goneWithCache === true);
  check("estimate counts stored data", log.grew === true);
  check("persist", log.persistedBefore === false && log.granted === true && log.persistedAfter === true);
}
