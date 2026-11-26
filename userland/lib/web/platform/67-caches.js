// The Cache API (Service Workers, section 5.4 and 5.5): CacheStorage at
// caches and the Cache objects it opens, in secure contexts only. The
// entries live in the process's store (Web.Script.NativeCaches), shared
// by every window and worker of the origin and saved with the profile;
// matching follows "Request Matches Cached Item" (the URL without its
// fragment, ignoreSearch, ignoreMethod, and the cached response's Vary
// unless ignoreVary). put and addAll replace the entries their requests
// match in one batch; every method answers with a promise.
(function (natives, global, internal) {
  "use strict";
  if (!global.isSecureContext) return;
  const token = internal.token;
  const cacheIds = new WeakMap();

  function idOf(cache) {
    const id = cacheIds.get(cache);
    if (id === undefined) throw new TypeError("Illegal invocation");
    return id;
  }

  // A function's result as a promise (exceptions become rejections).
  function promised(work) {
    try {
      return Promise.resolve(work());
    } catch (error) {
      return Promise.reject(error);
    }
  }

  function toRequest(input) {
    return internal.isRequest(input) ? input : new Request(input);
  }

  function withoutFragment(url) {
    const hash = url.indexOf("#");
    return hash < 0 ? url : url.slice(0, hash);
  }
  function withoutQuery(url) {
    const parsed = new URL(url);
    parsed.search = "";
    return parsed.href;
  }

  function headerValue(list, name) {
    const lower = name.toLowerCase();
    const values = [];
    for (const entry of list) if (entry[0].toLowerCase() === lower) values.push(entry[1]);
    return values.length === 0 ? null : values.join(", ");
  }

  function varyNames(responseHeaders) {
    const vary = headerValue(responseHeaders, "vary");
    if (vary === null) return [];
    return vary.split(",").map(function (name) { return name.trim(); }).filter(function (name) { return name !== ""; });
  }

  // Query: { method, url, headerList }; Entry: the store's array.
  function matches(query, entry, options) {
    if (!options.ignoreMethod && query.method !== "GET") return false;
    let queryUrl = withoutFragment(query.url);
    let cachedUrl = withoutFragment(entry[2]);
    if (options.ignoreSearch) {
      queryUrl = withoutQuery(queryUrl);
      cachedUrl = withoutQuery(cachedUrl);
    }
    if (queryUrl !== cachedUrl) return false;
    if (options.ignoreVary) return true;
    for (const name of varyNames(entry[8])) {
      if (name === "*") return false;
      if (headerValue(entry[3], name) !== headerValue(query.headerList, name)) return false;
    }
    return true;
  }

  function queryOf(request) {
    const record = internal.requestRecord(request);
    return { method: record.method, url: record.url, headerList: record.headerList };
  }

  function optionsOf(options) {
    const value = options === undefined || options === null ? {} : options;
    return { ignoreSearch: !!value.ignoreSearch, ignoreMethod: !!value.ignoreMethod, ignoreVary: !!value.ignoreVary,
      cacheName: value.cacheName === undefined ? undefined : String(value.cacheName) };
  }

  function entriesOf(id) {
    const entries = natives.cacheEntries(id);
    return entries === null ? [] : entries;
  }

  function responseOf(id, entry) {
    const body = natives.cacheBody(id, entry[0]);
    return internal.makeResponse({ type: entry[4], url: entry[5], status: entry[6], statusText: entry[7],
      headerList: entry[8], redirected: entry[9], bytes: body === null ? null : body });
  }

  function requestOf(entry) {
    return internal.makeRequest({ method: entry[1], url: entry[2], headerList: entry[3], mode: "cors",
      credentials: "same-origin", cache: "default", redirect: "follow", referrer: "about:client", referrerPolicy: "",
      integrity: "", destination: "", bytes: null });
  }

  // The entries Request (undefined: all) matches.
  function matching(id, request, options) {
    const entries = entriesOf(id);
    if (request === undefined) return entries;
    const query = queryOf(request);
    if (!options.ignoreMethod && query.method !== "GET") return [];
    return entries.filter(function (entry) { return matches(query, entry, options); });
  }

  function checkCacheable(record, method) {
    const scheme = record.url.slice(0, record.url.indexOf(":"));
    if (scheme !== "http" && scheme !== "https")
      throw new TypeError("Failed to execute on 'Cache': Request scheme '" + scheme + "' is unsupported");
    if (method !== "GET") throw new TypeError("Failed to execute on 'Cache': Request method '" + method +
      "' is unsupported");
  }

  function checkResponse(response) {
    if (response.status === 206)
      throw new TypeError("Failed to execute on 'Cache': Partial response (status code 206) is unsupported");
    if (varyNames(internal.headerList(response.headers)).indexOf("*") >= 0)
      throw new TypeError("Failed to execute on 'Cache': Vary header contains *");
  }

  // Writes the pairs (request, response record) as one batch, each one
  // replacing the entries its request matches.
  function writePairs(id, pairs) {
    const operations = [];
    const entries = entriesOf(id);
    for (const pair of pairs) {
      const query = { method: "GET", url: pair.request.url, headerList: pair.request.headerList };
      for (const entry of entries)
        if (matches(query, entry, {}) && !operations.some(function (operation) {
          return operation[0] === "delete" && operation[1] === entry[0];
        }))
          operations.push(["delete", entry[0]]);
      const record = pair.response;
      operations.push(["put", "GET", withoutFragment(pair.request.url), pair.request.headerList, record.type,
        record.url, record.status, record.statusText, record.headerList, record.redirected ? 1 : 0,
        record.bytes === null ? new Uint8Array(0) : record.bytes]);
    }
    const outcome = natives.cacheWrite(id, operations);
    if (outcome === "quota")
      throw internal.domException("Failed to execute on 'Cache': The quota has been exceeded.", "QuotaExceededError");
  }

  class Cache {
    constructor(key, id) {
      if (key !== token) internal.illegal();
      cacheIds.set(this, id);
    }
    match(request, options) {
      const cache = this;
      return this.matchAll(request, options).then(function (responses) {
        idOf(cache);
        return responses.length === 0 ? undefined : responses[0];
      });
    }
    matchAll(request, options) {
      const id = (function (cache) { try { return idOf(cache); } catch (error) { return error; } })(this);
      return promised(function () {
        if (id instanceof Error) throw id;
        const query = request === undefined ? undefined : toRequest(request);
        return matching(id, query, optionsOf(options)).map(function (entry) { return responseOf(id, entry); });
      });
    }
    add(request) {
      if (arguments.length < 1)
        return Promise.reject(new TypeError("Failed to execute 'add' on 'Cache': 1 argument required."));
      return this.addAll([request]);
    }
    addAll(requests) {
      let id;
      let list;
      try {
        id = idOf(this);
        list = Array.from(requests, toRequest);
        for (const request of list) checkCacheable(internal.requestRecord(request), request.method);
      } catch (error) {
        return Promise.reject(error);
      }
      return Promise.all(list.map(function (request) {
        return global.fetch(request).then(function (response) {
          if (response.type === "error" || !response.ok)
            throw new TypeError("Failed to execute 'addAll' on 'Cache': Request failed");
          checkResponse(response);
          return internal.responseRecord(response).then(function (record) {
            return { request: internal.requestRecord(request), response: record };
          });
        });
      })).then(function (pairs) {
        for (let first = 0; first < pairs.length; first++)
          for (let second = first + 1; second < pairs.length; second++)
            if (withoutFragment(pairs[first].request.url) === withoutFragment(pairs[second].request.url))
              throw internal.domException("Failed to execute 'addAll' on 'Cache': duplicate requests",
                "InvalidStateError");
        writePairs(id, pairs);
        return undefined;
      });
    }
    put(request, response) {
      let id;
      let query;
      try {
        id = idOf(this);
        if (arguments.length < 2) throw new TypeError("Failed to execute 'put' on 'Cache': 2 arguments required.");
        query = toRequest(request);
        checkCacheable(internal.requestRecord(query), query.method);
        if (!internal.isResponse(response))
          throw new TypeError("Failed to execute 'put' on 'Cache': parameter 2 is not of type 'Response'.");
        checkResponse(response);
        if (internal.bodyUnusable(response))
          throw new TypeError("Failed to execute 'put' on 'Cache': Response body is already used");
      } catch (error) {
        return Promise.reject(error);
      }
      const requestRecord = internal.requestRecord(query);
      return internal.responseRecord(response).then(function (record) {
        writePairs(id, [{ request: requestRecord, response: record }]);
        return undefined;
      });
    }
    delete(request, options) {
      const id = (function (cache) { try { return idOf(cache); } catch (error) { return error; } })(this);
      return promised(function () {
        if (id instanceof Error) throw id;
        const found = matching(id, toRequest(request), optionsOf(options));
        if (found.length === 0) return false;
        natives.cacheWrite(id, found.map(function (entry) { return ["delete", entry[0]]; }));
        return true;
      });
    }
    keys(request, options) {
      const id = (function (cache) { try { return idOf(cache); } catch (error) { return error; } })(this);
      return promised(function () {
        if (id instanceof Error) throw id;
        const query = request === undefined ? undefined : toRequest(request);
        return matching(id, query, optionsOf(options)).map(requestOf);
      });
    }
  }
  internal.finishInterface(Cache, "Cache");

  const storages = new WeakSet();
  function checkStorage(storage) {
    if (!storages.has(storage)) throw new TypeError("Illegal invocation");
  }

  class CacheStorage {
    constructor(key) {
      if (key !== token) internal.illegal();
      storages.add(this);
    }
    match(request, options) {
      const storage = this;
      return promised(function () {
        checkStorage(storage);
        const settings = optionsOf(options);
        const query = toRequest(request);
        const names = settings.cacheName !== undefined ?
          (natives.cacheHas(settings.cacheName) ? [settings.cacheName] : []) : natives.cacheNames();
        for (const name of names) {
          const id = natives.cacheOpen(name);
          const found = matching(id, query, settings);
          if (found.length > 0) return responseOf(id, found[0]);
        }
        return undefined;
      });
    }
    has(cacheName) {
      const storage = this;
      return promised(function () {
        checkStorage(storage);
        return natives.cacheHas(String(cacheName));
      });
    }
    open(cacheName) {
      const storage = this;
      return promised(function () {
        checkStorage(storage);
        return new Cache(token, natives.cacheOpen(String(cacheName)));
      });
    }
    delete(cacheName) {
      const storage = this;
      return promised(function () {
        checkStorage(storage);
        return natives.cacheDelete(String(cacheName));
      });
    }
    keys() {
      const storage = this;
      return promised(function () {
        checkStorage(storage);
        return natives.cacheNames();
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
