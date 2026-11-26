// The Cache API (Service Workers, 5.4 and 5.5; window.caches in secure
// contexts): named caches of request and response pairs, on the same
// storage service as IndexedDB, in a database of the origin's own that
// pages cannot open (the service's second namespace, "caches"): a store
// of cache names (each with the order it was made in) and a store of
// entries (generated keys keep the order they were put in) with an index
// by cache name and one by cache name and URL. Each operation is one
// transaction of the service; matching follows "query cache" (fragments
// never count, ignoreSearch, ignoreMethod, ignoreVary and the Vary
// header). Service workers (when there are any) use the same caches.
(function (natives, global, internal) {
  "use strict";
  const backend = internal.idbBackend;
  const operations = internal.idbOperations;
  if (backend === undefined || operations === undefined || !global.isSecureContext) return;
  const keys = internal.idbKeys;
  const token = internal.token;
  const Op = backend.Op;
  const Outcome = backend.Outcome;
  const RequestWriter = backend.RequestWriter;
  const Request = global.Request;
  const Response = global.Response;

  // ---- the database ----

  let connection = null;
  let connecting = null;
  let openToken = 1;

  function retryLater(callback) {
    global.setTimeout(callback, 10);
  }

  function describe(id, schema) {
    const names = schema.filter(function (store) { return store.name === "names"; })[0];
    const entries = schema.filter(function (store) { return store.name === "entries"; })[0];
    const indexId = function (name) {
      return entries.indexes.filter(function (index) { return index.name === name; })[0].id;
    };
    const byCache = { id: indexId("byCache"), keyPath: "cache", multiEntry: false, unique: false, deleted: false };
    const byUrl = { id: indexId("byUrl"), keyPath: "lookup", multiEntry: false, unique: false, deleted: false };
    return { id: id, names: { id: names.id, indexes: [] }, entries: { id: entries.id, indexes: [byCache, byUrl] },
      byCache: byCache, byUrl: byUrl };
  }

  function createSchema(transactionId) {
    function store(name, autoIncrement) {
      const writer = new RequestWriter(Op.CreateStore);
      writer.u32(transactionId);
      writer.name(name);
      writer.keyPath(null);
      writer.boolean(autoIncrement);
      return backend.call(writer).u32();
    }
    function index(storeId, name, keyPath) {
      const writer = new RequestWriter(Op.CreateIndex);
      writer.u32(transactionId);
      writer.u32(storeId);
      writer.name(name);
      writer.keyPath(keyPath);
      writer.boolean(false);
      writer.boolean(false);
      return { id: backend.call(writer).u32(), name: name };
    }
    const namesId = store("names", false);
    const entriesId = store("entries", true);
    const byCache = index(entriesId, "byCache", "cache");
    const byUrl = index(entriesId, "byUrl", "lookup");
    return [{ id: namesId, name: "names", indexes: [] }, { id: entriesId, name: "entries", indexes: [byCache, byUrl] }];
  }

  function connect() {
    if (connection !== null) return Promise.resolve(connection);
    if (connecting !== null) return connecting;
    const requestToken = openToken++;
    connecting = new Promise(function (resolve, reject) {
      function attempt() {
        const writer = new RequestWriter(Op.Open);
        writer.byte(1);
        writer.name("caches");
        writer.f64(1);
        writer.u32(requestToken);
        let reader;
        try {
          reader = backend.call(writer);
          const outcome = reader.byte();
          if (outcome === Outcome.Wait) {
            retryLater(attempt);
            return;
          }
          const id = reader.u32();
          if (outcome === Outcome.Done) {
            reader.f64();
            connection = describe(id, backend.readSchema(reader));
          } else {
            const transactionId = reader.u32();
            const schema = createSchema(transactionId);
            const commit = new RequestWriter(Op.Commit);
            commit.u32(transactionId);
            backend.call(commit);
            connection = describe(id, schema);
          }
          resolve(connection);
        } catch (error) {
          connecting = null;
          reject(error);
        }
      }
      if (!backend.allowed()) {
        connecting = null;
        reject(new DOMException("Access to the Cache API is denied in this context.", "SecurityError"));
        return;
      }
      backend.queueTask(attempt);
    });
    return connecting;
  }

  // Runs Body(transaction id, connection) in a transaction of the
  // service, committed when it returns, aborted when it throws.
  function withTransaction(readWrite, body) {
    return connect().then(function (database) {
      return new Promise(function (resolve, reject) {
        function attempt() {
          let transactionId;
          try {
            const writer = new RequestWriter(Op.Begin);
            writer.u32(database.id);
            writer.byte(readWrite ? 1 : 0);
            writer.u32(2);
            writer.u32(database.names.id);
            writer.u32(database.entries.id);
            const reader = backend.call(writer);
            if (reader.byte() === Outcome.Wait) {
              retryLater(attempt);
              return;
            }
            transactionId = reader.u32();
          } catch (error) {
            reject(error);
            return;
          }
          let result;
          try {
            result = body(transactionId, database);
          } catch (error) {
            const abort = new RequestWriter(Op.Abort);
            abort.u32(transactionId);
            try {
              backend.call(abort);
            } catch (ignored) {
              // Gone already.
            }
            reject(error);
            return;
          }
          try {
            const commit = new RequestWriter(Op.Commit);
            commit.u32(transactionId);
            backend.call(commit);
            resolve(result);
          } catch (error) {
            reject(error);
          }
        }
        backend.queueTask(attempt);
      });
    });
  }

  function only(key) {
    return { lower: key, upper: key, lowerOpen: false, upperOpen: false };
  }
  const everything = { lower: null, upper: null, lowerOpen: true, upperOpen: true };

  function cacheNames(transactionId, database) {
    const records = operations.retrieveAll(transactionId, database.names, null, everything, 0, 2);
    const list = records.map(function (record) {
      return { name: keys.decode(record.primaryKey), created: internal.structuredDeserialize(record.value).created };
    });
    list.sort(function (a, b) { return a.created - b.created; });
    return list;
  }

  function hasCache(transactionId, database, name) {
    return operations.retrieve(transactionId, database.names, null, only(keys.encode(name)), false) !== null;
  }

  function entriesOf(transactionId, database, name, url) {
    const records = url === null ?
      operations.retrieveAll(transactionId, database.entries, database.byCache, only(keys.encode(name)), 0, 2) :
      operations.retrieveAll(transactionId, database.entries, database.byUrl, only(keys.encode([name, url])), 0, 2);
    return records.map(function (record) {
      return { primaryKey: record.primaryKey, entry: internal.structuredDeserialize(record.value) };
    });
  }

  function deleteEntry(transactionId, database, primaryKey) {
    operations.deleteRange(transactionId, database.entries, only(primaryKey));
  }

  function putEntry(transactionId, database, entry) {
    const bytes = internal.structuredSerialize(entry);
    const key = operations.generateKey(transactionId, database.entries);
    operations.putRecord(transactionId, database.entries, key, bytes, entry, false);
  }

  // ---- matching (5.4.4.2 "query cache") ----

  function withoutFragment(url) {
    const hash = url.indexOf("#");
    return hash < 0 ? url : url.slice(0, hash);
  }
  function withoutSearch(url) {
    const question = url.indexOf("?");
    return question < 0 ? url : url.slice(0, question);
  }
  function headerValue(list, name) {
    const values = [];
    for (const entry of list) if (entry[0].toLowerCase() === name) values.push(entry[1]);
    return values.length === 0 ? null : values.join(", ");
  }
  function varyNames(headers) {
    const vary = headerValue(headers, "vary");
    if (vary === null) return [];
    return vary.split(",").map(function (item) { return item.trim().toLowerCase(); }).filter(function (item) {
      return item !== "";
    });
  }

  function requestMatches(query, entry, options) {
    if (!options.ignoreMethod && entry.request.method !== "GET") return false;
    let queryUrl = withoutFragment(query.url);
    let cachedUrl = withoutFragment(entry.request.url);
    if (options.ignoreSearch) {
      queryUrl = withoutSearch(queryUrl);
      cachedUrl = withoutSearch(cachedUrl);
    }
    if (queryUrl !== cachedUrl) return false;
    if (options.ignoreVary || entry.response === null) return true;
    for (const name of varyNames(entry.response.headers)) {
      if (name === "*") return false;
      if (headerValue(query.headers, name) !== headerValue(entry.request.headers, name)) return false;
    }
    return true;
  }

  function optionsOf(value) {
    const options = value == null ? {} : value;
    return { ignoreSearch: !!options.ignoreSearch, ignoreMethod: !!options.ignoreMethod,
      ignoreVary: !!options.ignoreVary, cacheName: options.cacheName === undefined ? undefined :
        String(options.cacheName) };
  }

  function queryCache(transactionId, database, name, query, options) {
    if (query === null) return entriesOf(transactionId, database, name, null);
    if (!options.ignoreMethod && query.method !== "GET") return [];
    const candidates = options.ignoreSearch ? entriesOf(transactionId, database, name, null) :
      entriesOf(transactionId, database, name, withoutFragment(query.url));
    return candidates.filter(function (item) { return requestMatches(query, item.entry, options); });
  }

  function requestOf(value) {
    return internal.requestRecord(value instanceof Request ? value : new Request(value));
  }

  function responseOf(entry) {
    return internal.makeStoredResponse(entry.response, entry.body);
  }

  function checkStorable(request, response, what) {
    if (!/^https?:/i.test(request.url)) throw new TypeError("Failed to execute '" + what + "' on 'Cache': Request " +
      "scheme '" + request.url.split(":")[0] + "' is unsupported");
    if (request.method !== "GET") throw new TypeError("Failed to execute '" + what + "' on 'Cache': Request method '" +
      request.method + "' is unsupported");
    if (response !== null) {
      if (response.status === 206) throw new TypeError("Failed to execute '" + what + "' on 'Cache': Partial " +
        "response (status code 206) is unsupported");
      if (varyNames(response.headers).indexOf("*") >= 0) throw new TypeError("Failed to execute '" + what + "' on " +
        "'Cache': Vary header contains *");
    }
  }

  // Puts each pair, removing the entries each replaces.
  function storePairs(name, pairs) {
    return withTransaction(true, function (transactionId, database) {
      for (const pair of pairs) {
        for (const item of queryCache(transactionId, database, name, pair.request, optionsOf(undefined)))
          deleteEntry(transactionId, database, item.primaryKey);
        const url = withoutFragment(pair.request.url);
        putEntry(transactionId, database, { cache: name, lookup: [name, url], request: pair.request,
          response: pair.response, body: pair.body });
      }
      return undefined;
    });
  }

  // ---- Cache ----

  const cacheData = new WeakMap();
  function cacheName(object) {
    const name = cacheData.get(object);
    if (name === undefined) throw new TypeError("Illegal invocation");
    return name;
  }

  class Cache {
    constructor(key) {
      if (key !== token) internal.illegal();
    }
    match(request, options) {
      return this.matchAll(request, options).then(function (list) { return list.length > 0 ? list[0] : undefined; });
    }
    matchAll(request, options) {
      let name;
      let query = null;
      try {
        name = cacheName(this);
        if (request !== undefined) query = requestOf(request);
      } catch (error) {
        return Promise.reject(error);
      }
      const settings = optionsOf(options);
      return withTransaction(false, function (transactionId, database) {
        return queryCache(transactionId, database, name, query, settings).map(function (item) {
          return responseOf(item.entry);
        });
      });
    }
    add(request) {
      if (arguments.length < 1) return Promise.reject(new TypeError("Failed to execute 'add' on 'Cache': 1 argument " +
        "required, but only 0 present."));
      return this.addAll([request]);
    }
    addAll(requests) {
      let name;
      let list;
      try {
        name = cacheName(this);
        if (requests === null || typeof requests !== "object" || typeof requests[Symbol.iterator] !== "function")
          throw new TypeError("Failed to execute 'addAll' on 'Cache': The provided value cannot be converted to a " +
            "sequence.");
        list = Array.from(requests, function (item) { return item instanceof Request ? item : new Request(item); });
        for (const item of list) checkStorable(internal.requestRecord(item), null, "addAll");
      } catch (error) {
        return Promise.reject(error);
      }
      return Promise.all(list.map(function (item) { return global.fetch(item); })).then(function (responses) {
        for (const response of responses) {
          if (!response.ok) throw new TypeError("Failed to execute 'addAll' on 'Cache': Request failed");
          checkStorable({ url: "https:", method: "GET" }, internal.responseRecord(response), "addAll");
        }
        return Promise.all(responses.map(function (response) { return internal.readBodyBytes(response); }))
          .then(function (bodies) {
            return storePairs(name, list.map(function (item, index) {
              return { request: internal.requestRecord(item), response: internal.responseRecord(responses[index]),
                body: bodies[index] };
            }));
          });
      });
    }
    put(request, response) {
      let name;
      let requestRecord;
      let responseRecord;
      try {
        if (arguments.length < 2) throw new TypeError("Failed to execute 'put' on 'Cache': 2 arguments required, " +
          "but only " + arguments.length + " present.");
        name = cacheName(this);
        requestRecord = requestOf(request);
        if (!(response instanceof Response)) throw new TypeError("Failed to execute 'put' on 'Cache': parameter 2 " +
          "is not of type 'Response'.");
        responseRecord = internal.responseRecord(response);
        checkStorable(requestRecord, responseRecord, "put");
        if (internal.bodyUnusable(response)) throw new TypeError("Failed to execute 'put' on 'Cache': Response body " +
          "is already used");
      } catch (error) {
        return Promise.reject(error);
      }
      return internal.readBodyBytes(response).then(function (body) {
        return storePairs(name, [{ request: requestRecord, response: responseRecord, body: body }]);
      });
    }
    delete(request, options) {
      let name;
      let query;
      try {
        name = cacheName(this);
        query = requestOf(request);
      } catch (error) {
        return Promise.reject(error);
      }
      const settings = optionsOf(options);
      return withTransaction(true, function (transactionId, database) {
        const found = queryCache(transactionId, database, name, query, settings);
        for (const item of found) deleteEntry(transactionId, database, item.primaryKey);
        return found.length > 0;
      });
    }
    keys(request, options) {
      let name;
      let query = null;
      try {
        name = cacheName(this);
        if (request !== undefined) query = requestOf(request);
      } catch (error) {
        return Promise.reject(error);
      }
      const settings = optionsOf(options);
      return withTransaction(false, function (transactionId, database) {
        return queryCache(transactionId, database, name, query, settings).map(function (item) {
          return new Request(item.entry.request.url, { method: item.entry.request.method,
            headers: item.entry.request.headers });
        });
      });
    }
  }
  internal.finishInterface(Cache, "Cache");

  function makeCache(name) {
    const cache = new Cache(token);
    cacheData.set(cache, name);
    return cache;
  }

  // ---- CacheStorage ----

  class CacheStorage {
    constructor(key) {
      if (key !== token) internal.illegal();
    }
    match(request, options) {
      let query;
      try {
        query = requestOf(request);
      } catch (error) {
        return Promise.reject(error);
      }
      const settings = optionsOf(options);
      return withTransaction(false, function (transactionId, database) {
        const names = settings.cacheName !== undefined ?
          (hasCache(transactionId, database, settings.cacheName) ? [settings.cacheName] : []) :
          cacheNames(transactionId, database).map(function (item) { return item.name; });
        for (const name of names) {
          const found = queryCache(transactionId, database, name, query, settings);
          if (found.length > 0) return responseOf(found[0].entry);
        }
        return undefined;
      });
    }
    has(cacheName_) {
      const name = String(cacheName_);
      return withTransaction(false, function (transactionId, database) {
        return hasCache(transactionId, database, name);
      });
    }
    open(cacheName_) {
      const name = String(cacheName_);
      return withTransaction(true, function (transactionId, database) {
        if (!hasCache(transactionId, database, name)) {
          const existing = cacheNames(transactionId, database);
          const created = existing.length === 0 ? 1 : existing[existing.length - 1].created + 1;
          const value = { created: created };
          operations.putRecord(transactionId, database.names, keys.encode(name), internal.structuredSerialize(value),
            value, false);
        }
        return makeCache(name);
      });
    }
    delete(cacheName_) {
      const name = String(cacheName_);
      return withTransaction(true, function (transactionId, database) {
        if (!hasCache(transactionId, database, name)) return false;
        for (const item of entriesOf(transactionId, database, name, null))
          deleteEntry(transactionId, database, item.primaryKey);
        operations.deleteRange(transactionId, database.names, only(keys.encode(name)));
        return true;
      });
    }
    keys() {
      return withTransaction(false, function (transactionId, database) {
        return cacheNames(transactionId, database).map(function (item) { return item.name; });
      });
    }
  }
  internal.finishInterface(CacheStorage, "CacheStorage");

  let storage = null;
  internal.defineGetter(global, "caches", function () {
    if (storage === null) storage = new CacheStorage(token);
    return storage;
  });
})
