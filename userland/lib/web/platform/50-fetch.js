// The Fetch Standard's script side: Headers, Request, Response, fetch(),
// AbortController and AbortSignal (DOM 3.3), and XMLHttpRequest. The
// network part is the engine's fetch layer (CORS, cookies, redirects,
// the cache), reached through natives.fetchStart; its results come back
// as natives.onFetchEvent(id, kind, ...) calls.
(function (natives, global, internal) {
  "use strict";
  const token = internal.token;

  // ---- AbortController and AbortSignal ----

  const signalData = new WeakMap();
  function signalState(object) {
    const state = signalData.get(object);
    if (state === undefined) throw new TypeError("Illegal invocation");
    return state;
  }
  class AbortSignal extends EventTarget {
    constructor(key) {
      if (key !== token) internal.illegal();
      super();
      signalData.set(this, { aborted: false, reason: undefined, algorithms: [], dependents: [] });
    }
    get aborted() { return signalState(this).aborted; }
    get reason() { return signalState(this).reason; }
    throwIfAborted() {
      const state = signalState(this);
      if (state.aborted) throw state.reason;
    }
    static abort(reason) {
      const signal = new AbortSignal(token);
      signalAbort(signal, reason);
      return signal;
    }
    static timeout(milliseconds) {
      const signal = new AbortSignal(token);
      global.setTimeout(function () {
        signalAbort(signal, internal.domException("signal timed out", "TimeoutError"));
      }, Number(milliseconds));
      return signal;
    }
    static any(signals) {
      const result = new AbortSignal(token);
      const list = Array.from(signals);
      for (const signal of list)
        if (signal.aborted) {
          signalAbort(result, signal.reason);
          return result;
        }
      for (const signal of list) signalState(signal).dependents.push(result);
      return result;
    }
  }
  internal.defineHandler(AbortSignal.prototype, "abort");
  internal.finishInterface(AbortSignal, "AbortSignal");

  function signalAbort(signal, reason) {
    const state = signalState(signal);
    if (state.aborted) return;
    state.aborted = true;
    state.reason = reason === undefined ? internal.domException("signal is aborted without reason", "AbortError") :
      reason;
    for (const algorithm of state.algorithms.splice(0)) algorithm();
    internal.fire(signal, new Event("abort"));
    for (const dependent of state.dependents.splice(0)) signalAbort(dependent, state.reason);
  }
  internal.onAbort = function (signal, algorithm) {
    signalState(signal).algorithms.push(algorithm);
  };

  const controllerData = new WeakMap();
  class AbortController {
    constructor() {
      controllerData.set(this, new AbortSignal(token));
    }
    get signal() { return controllerData.get(this); }
    abort(reason) { signalAbort(controllerData.get(this), reason); }
  }
  internal.finishInterface(AbortController, "AbortController");

  // ---- Headers ----

  const forbiddenRequestHeaders = ["accept-charset", "accept-encoding", "access-control-request-headers",
    "access-control-request-method", "connection", "content-length", "cookie", "cookie2", "date", "dnt", "expect",
    "host", "keep-alive", "origin", "referer", "set-cookie", "te", "trailer", "transfer-encoding", "upgrade", "via"];
  const tokenPattern = /^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/;

  function normalizeValue(value) {
    return internal.toByteString(value).replace(/^[\t\n\r ]+|[\t\n\r ]+$/g, "");
  }
  function checkName(name) {
    const text = internal.toByteString(name);
    if (!tokenPattern.test(text)) throw new TypeError("Failed to execute on 'Headers': Invalid name");
    return text;
  }
  function checkValue(value) {
    const text = normalizeValue(value);
    if (/[\0\r\n]/.test(text)) throw new TypeError("Failed to execute on 'Headers': Invalid value");
    return text;
  }
  function isForbidden(name) {
    const lower = name.toLowerCase();
    return forbiddenRequestHeaders.indexOf(lower) >= 0 || lower.startsWith("proxy-") || lower.startsWith("sec-");
  }

  const headersData = new WeakMap();
  function headersState(object) {
    const state = headersData.get(object);
    if (state === undefined) throw new TypeError("Illegal invocation");
    return state;
  }
  class Headers {
    constructor(init) {
      headersData.set(this, { list: [], guard: "none" });
      if (init !== undefined) fillHeaders(this, init);
    }
    append(name, value) { appendHeader(this, name, value); }
    delete(name) {
      const state = headersState(this);
      const lower = checkName(name).toLowerCase();
      if (state.guard === "immutable") throw new TypeError("Headers are immutable");
      if (state.guard === "request" && isForbidden(lower)) return;
      state.list = state.list.filter(function (entry) { return entry[0].toLowerCase() !== lower; });
    }
    get(name) {
      const lower = checkName(name).toLowerCase();
      const values = headersState(this).list.filter(function (entry) { return entry[0].toLowerCase() === lower; })
        .map(function (entry) { return entry[1]; });
      return values.length === 0 ? null : values.join(", ");
    }
    getSetCookie() {
      return headersState(this).list.filter(function (entry) { return entry[0].toLowerCase() === "set-cookie"; })
        .map(function (entry) { return entry[1]; });
    }
    has(name) {
      const lower = checkName(name).toLowerCase();
      return headersState(this).list.some(function (entry) { return entry[0].toLowerCase() === lower; });
    }
    set(name, value) {
      const state = headersState(this);
      const checkedName = checkName(name);
      const checkedValue = checkValue(value);
      if (state.guard === "immutable") throw new TypeError("Headers are immutable");
      if (state.guard === "request" && isForbidden(checkedName)) return;
      const lower = checkedName.toLowerCase();
      const index = state.list.findIndex(function (entry) { return entry[0].toLowerCase() === lower; });
      if (index < 0) state.list.push([checkedName, checkedValue]);
      else {
        state.list[index] = [state.list[index][0], checkedValue];
        state.list = state.list.filter(function (entry, at) { return at <= index || entry[0].toLowerCase() !== lower; });
      }
    }
    forEach(callback, thisArgument) {
      for (const [name, value] of sortedPairs(this)) callback.call(thisArgument, value, name, this);
    }
    *entries() { yield* sortedPairs(this); }
    *keys() { for (const pair of sortedPairs(this)) yield pair[0]; }
    *values() { for (const pair of sortedPairs(this)) yield pair[1]; }
    [Symbol.iterator]() { return this.entries(); }
  }
  internal.finishInterface(Headers, "Headers");

  function appendHeader(headers, name, value) {
    const state = headersState(headers);
    const checkedName = checkName(name);
    const checkedValue = checkValue(value);
    if (state.guard === "immutable") throw new TypeError("Headers are immutable");
    if (state.guard === "request" && isForbidden(checkedName)) return;
    state.list.push([checkedName, checkedValue]);
  }
  function fillHeaders(headers, init) {
    if (init instanceof Headers) {
      for (const entry of headersState(init).list) appendHeader(headers, entry[0], entry[1]);
    } else if (init !== null && typeof init === "object" && typeof init[Symbol.iterator] === "function") {
      for (const pair of init) {
        const items = Array.from(pair);
        if (items.length !== 2) throw new TypeError("Failed to construct 'Headers': Invalid value");
        appendHeader(headers, items[0], items[1]);
      }
    } else if (init !== null && typeof init === "object") {
      for (const key of Object.keys(init)) appendHeader(headers, key, init[key]);
    } else throw new TypeError("Failed to construct 'Headers': The provided value is not of type " +
      "'(record<ByteString, ByteString> or sequence<sequence<ByteString>>)'.");
  }
  function sortedPairs(headers) {
    const groups = new Map();
    const cookies = [];
    for (const entry of headersState(headers).list) {
      const lower = entry[0].toLowerCase();
      if (lower === "set-cookie") cookies.push(entry[1]);
      else if (groups.has(lower)) groups.set(lower, groups.get(lower) + ", " + entry[1]);
      else groups.set(lower, entry[1]);
    }
    const pairs = Array.from(groups);
    for (const cookie of cookies) pairs.push(["set-cookie", cookie]);
    return pairs.sort(function (a, b) { return a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0; });
  }
  function headersWithGuard(list, guard) {
    const headers = new Headers();
    const state = headersState(headers);
    state.list = list;
    state.guard = guard;
    return headers;
  }
  internal.headerList = function (headers) { return headersState(headers).list; };

  // ---- bodies ----

  // Fetch's "extract a body": the bytes and the Content-Type it implies.
  function extractBody(object) {
    if (typeof object === "string") return { bytes: internal.encodeText(object), type: "text/plain;charset=UTF-8" };
    if (object instanceof URLSearchParams)
      return { bytes: internal.encodeText(object.toString()), type: "application/x-www-form-urlencoded;charset=UTF-8" };
    if (object instanceof Blob) return { bytes: internal.blobBytes(object), type: object.type || null };
    if (internal.isBufferSource(object)) return { bytes: internal.bufferBytes(object), type: null };
    if (object instanceof FormData) return multipartBody(object);
    if (object instanceof ReadableStream) return { stream: object, type: null };
    return { bytes: internal.encodeText(String(object)), type: "text/plain;charset=UTF-8" };
  }
  internal.extractBody = extractBody;

  function multipartBody(form) {
    const boundary = "----formdata-libweb-" + global.crypto.randomUUID().replace(/-/g, "");
    const parts = [];
    function escapeName(text) {
      return String(text).replace(/\n/g, "%0A").replace(/\r/g, "%0D").replace(/"/g, "%22");
    }
    for (const [name, value] of internal.formEntries(form)) {
      let head = "--" + boundary + "\r\nContent-Disposition: form-data; name=\"" + escapeName(name) + "\"";
      if (value instanceof Blob) {
        head += "; filename=\"" + escapeName(value.name) + "\"\r\nContent-Type: " +
          (value.type || "application/octet-stream") + "\r\n\r\n";
        parts.push(internal.encodeText(head), internal.blobBytes(value), internal.encodeText("\r\n"));
      } else {
        parts.push(internal.encodeText(head + "\r\n\r\n" + String(value).replace(/\r\n|\r|\n/g, "\r\n") + "\r\n"));
      }
    }
    parts.push(internal.encodeText("--" + boundary + "--\r\n"));
    let total = 0;
    for (const part of parts) total += part.length;
    const bytes = new Uint8Array(total);
    let offset = 0;
    for (const part of parts) {
      bytes.set(part, offset);
      offset += part.length;
    }
    return { bytes: bytes, type: "multipart/form-data; boundary=" + boundary };
  }

  // The Body mixin over a body record { stream, used }.
  const bodyData = new WeakMap();
  function bodyOf(object) {
    const state = bodyData.get(object);
    if (state === undefined) throw new TypeError("Illegal invocation");
    return state;
  }
  function consume(object, convert) {
    let state;
    try {
      state = bodyOf(object);
    } catch (error) {
      return Promise.reject(error);
    }
    if (state.stream !== null && (internal.streamIsDisturbed(state.stream) || internal.streamIsLocked(state.stream)))
      return Promise.reject(new TypeError("Failed to execute on '" + (object instanceof Request ? "Request" :
        "Response") + "': body stream already read"));
    state.used = true;
    const bytes = state.stream === null ? Promise.resolve(new Uint8Array(0)) : internal.readAllBytes(state.stream);
    return bytes.then(function (data) { return convert(data, state); });
  }
  function mimeTypeOf(object) {
    const type = object.headers.get("content-type");
    return type === null ? "" : type;
  }
  function defineBodyMembers(Class) {
    Object.defineProperty(Class.prototype, "body", {
      get: function () { return bodyOf(this).stream; }, configurable: true, enumerable: true });
    Object.defineProperty(Class.prototype, "bodyUsed", {
      get: function () {
        const state = bodyOf(this);
        return state.stream !== null && internal.streamIsDisturbed(state.stream);
      }, configurable: true, enumerable: true });
    const methods = {
      arrayBuffer: function () { return consume(this, function (bytes) { return bytes.buffer; }); },
      bytes: function () { return consume(this, function (bytes) { return bytes; }); },
      blob: function () {
        const type = mimeTypeOf(this);
        return consume(this, function (bytes) { return internal.makeBlob(bytes, type); });
      },
      text: function () { return consume(this, function (bytes) { return internal.decodeText(bytes); }); },
      json: function () { return consume(this, function (bytes) { return JSON.parse(internal.decodeText(bytes)); }); },
      formData: function () {
        const type = mimeTypeOf(this);
        return consume(this, function (bytes) {
          if (/^application\/x-www-form-urlencoded/i.test(type)) {
            const form = new FormData();
            // The body is parsed as it is: a leading "?" is a name's.
            const text = internal.decodeText(bytes);
            for (const [name, value] of new URLSearchParams(text.charAt(0) === "?" ? "?" + text : text))
              form.append(name, value);
            return form;
          }
          throw new TypeError("Could not parse content as FormData.");
        });
      }
    };
    for (const name of Object.keys(methods))
      Object.defineProperty(Class.prototype, name, { value: methods[name], writable: true, configurable: true });
  }
  function bodyRecord(init) {
    if (init.stream !== undefined) return { stream: init.stream, used: false };
    return { stream: internal.streamOfBytes(init.bytes), used: false, bytes: init.bytes };
  }

  // ---- Request ----

  const requestData = new WeakMap();
  function requestState(object) {
    const state = requestData.get(object);
    if (state === undefined) throw new TypeError("Illegal invocation");
    return state;
  }
  const requestModes = ["navigate", "same-origin", "no-cors", "cors"];
  const credentialsModes = ["omit", "same-origin", "include"];
  const cacheModes = ["default", "no-store", "reload", "no-cache", "force-cache", "only-if-cached"];
  const redirectModes = ["follow", "error", "manual"];
  const referrerPolicies = ["", "no-referrer", "no-referrer-when-downgrade", "same-origin", "origin",
    "strict-origin", "origin-when-cross-origin", "strict-origin-when-cross-origin", "unsafe-url"];

  function enumValue(value, allowed, name) {
    const text = String(value);
    if (allowed.indexOf(text) < 0)
      throw new TypeError("Failed to construct 'Request': The provided value '" + text + "' is not a valid enum " +
        "value of type " + name + ".");
    return text;
  }
  function baseUrl() {
    return global.document ? global.document.baseURI : global.location.href;
  }

  class Request {
    constructor(input, init) {
      const options = init == null ? {} : init;
      let source = null;
      let state;
      if (input instanceof Request) {
        source = requestState(input);
        state = Object.assign({}, source);
        state.headerList = source.headerList.map(function (entry) { return entry.slice(); });
      } else {
        let parsed;
        try {
          parsed = new URL(String(input), baseUrl());
        } catch (error) {
          throw new TypeError("Failed to construct 'Request': Invalid URL");
        }
        if (parsed.username || parsed.password)
          throw new TypeError("Failed to construct 'Request': Request cannot be constructed from a URL that " +
            "includes credentials: " + String(input));
        state = { method: "GET", url: parsed.href, headerList: [], mode: "cors", credentials: "same-origin",
          cache: "default", redirect: "follow", referrer: "about:client", referrerPolicy: "", integrity: "",
          keepalive: false, signal: null, priority: "auto", destination: "", duplex: "half" };
      }
      if (options.method !== undefined) {
        const method = internal.toByteString(options.method);
        if (!tokenPattern.test(method)) throw new TypeError("Failed to construct 'Request': '" + method +
          "' is not a valid HTTP method.");
        const upper = method.toUpperCase();
        if (["CONNECT", "TRACE", "TRACK"].indexOf(upper) >= 0)
          throw new TypeError("Failed to construct 'Request': '" + method + "' HTTP method is unsupported.");
        state.method = ["DELETE", "GET", "HEAD", "OPTIONS", "POST", "PUT", "PATCH"].indexOf(upper) >= 0 ? upper :
          method;
      }
      if (options.mode !== undefined) {
        state.mode = enumValue(options.mode, requestModes, "RequestMode");
        if (state.mode === "navigate") throw new TypeError("Failed to construct 'Request': Cannot construct a " +
          "Request with a RequestInit whose mode member is set as 'navigate'.");
      }
      if (options.credentials !== undefined) state.credentials = enumValue(options.credentials, credentialsModes,
        "RequestCredentials");
      if (options.cache !== undefined) state.cache = enumValue(options.cache, cacheModes, "RequestCache");
      if (options.redirect !== undefined) state.redirect = enumValue(options.redirect, redirectModes,
        "RequestRedirect");
      if (options.referrerPolicy !== undefined) state.referrerPolicy = enumValue(options.referrerPolicy,
        referrerPolicies, "ReferrerPolicy");
      if (options.referrer !== undefined) {
        const referrer = String(options.referrer);
        state.referrer = referrer === "" ? "no-referrer" : new URL(referrer, baseUrl()).href;
      }
      if (options.integrity !== undefined) state.integrity = String(options.integrity);
      if (options.keepalive !== undefined) state.keepalive = !!options.keepalive;
      if (options.priority !== undefined) state.priority = String(options.priority);
      if (options.signal !== undefined) state.signal = options.signal;
      if (state.cache === "only-if-cached" && state.mode !== "same-origin")
        throw new TypeError("Failed to construct 'Request': 'only-if-cached' can be set only with 'same-origin' " +
          "mode");
      requestData.set(this, state);
      const ownSignal = new AbortSignal(token);
      const followed = state.signal;
      state.signal = ownSignal;
      if (followed) {
        if (followed.aborted) signalAbort(ownSignal, followed.reason);
        else internal.onAbort(followed, function () { signalAbort(ownSignal, followed.reason); });
      }
      if (options.headers !== undefined) {
        state.headerList = [];
        state.headers = headersWithGuard(state.headerList, state.mode === "no-cors" ? "request-no-cors" : "request");
        fillHeaders(state.headers, options.headers);
        state.headerList = internal.headerList(state.headers);
      } else state.headers = headersWithGuard(state.headerList, "request");
      let body = null;
      if (options.body !== undefined && options.body !== null) {
        if (state.method === "GET" || state.method === "HEAD")
          throw new TypeError("Failed to construct 'Request': Request with GET/HEAD method cannot have body.");
        const extracted = extractBody(options.body);
        if (extracted.type && !state.headers.has("content-type")) state.headers.append("Content-Type", extracted.type);
        body = bodyRecord(extracted);
      } else if (source !== null && bodyData.has(input)) {
        const sourceBody = bodyData.get(input);
        if (sourceBody.stream !== null && internal.streamIsDisturbed(sourceBody.stream))
          throw new TypeError("Failed to construct 'Request': Cannot construct a Request with a Request object " +
            "that has already been used.");
        body = sourceBody.bytes !== undefined ? bodyRecord({ bytes: sourceBody.bytes }) : sourceBody;
      }
      bodyData.set(this, body === null ? { stream: null, used: false } : body);
    }
    get method() { return requestState(this).method; }
    get url() { return requestState(this).url; }
    get headers() { return requestState(this).headers; }
    get destination() { return requestState(this).destination; }
    get referrer() {
      const referrer = requestState(this).referrer;
      return referrer === "no-referrer" ? "" : referrer;
    }
    get referrerPolicy() { return requestState(this).referrerPolicy; }
    get mode() { return requestState(this).mode; }
    get credentials() { return requestState(this).credentials; }
    get cache() { return requestState(this).cache; }
    get redirect() { return requestState(this).redirect; }
    get integrity() { return requestState(this).integrity; }
    get keepalive() { return requestState(this).keepalive; }
    get isReloadNavigation() { return false; }
    get isHistoryNavigation() { return false; }
    get signal() { return requestState(this).signal; }
    get duplex() { return "half"; }
    clone() {
      const body = bodyOf(this);
      if (body.stream !== null && internal.streamIsDisturbed(body.stream))
        throw new TypeError("Failed to execute 'clone' on 'Request': Request body is already used");
      const copy = new Request(this);
      if (body.stream !== null && body.bytes === undefined) {
        const branches = body.stream.tee();
        body.stream = branches[0];
        bodyData.set(copy, { stream: branches[1], used: false });
      }
      return copy;
    }
  }
  defineBodyMembers(Request);
  internal.finishInterface(Request, "Request");

  // ---- Response ----

  const responseData = new WeakMap();
  function responseState(object) {
    const state = responseData.get(object);
    if (state === undefined) throw new TypeError("Illegal invocation");
    return state;
  }
  const nullBodyStatuses = [101, 103, 204, 205, 304];
  const redirectStatuses = [301, 302, 303, 307, 308];

  class Response {
    constructor(body, init) {
      const options = init == null ? {} : init;
      const status = options.status === undefined ? 200 : Number(options.status) >>> 0;
      if (status < 200 || status > 599)
        throw new RangeError("Failed to construct 'Response': The status provided (" + status + ") is outside the " +
          "range [200, 599].");
      const statusText = options.statusText === undefined ? "" : internal.toByteString(options.statusText);
      if (/[\r\n]/.test(statusText)) throw new TypeError("Failed to construct 'Response': Invalid statusText");
      const headerList = [];
      const headers = headersWithGuard(headerList, "response");
      if (options.headers !== undefined) fillHeaders(headers, options.headers);
      let record = { stream: null, used: false };
      if (body !== undefined && body !== null) {
        if (nullBodyStatuses.indexOf(status) >= 0)
          throw new TypeError("Failed to construct 'Response': Response with null body status cannot have body");
        const extracted = extractBody(body);
        if (extracted.type && !headers.has("content-type")) headers.append("Content-Type", extracted.type);
        record = bodyRecord(extracted);
      }
      responseData.set(this, { type: "default", url: "", status: status, statusText: statusText, headers: headers,
        redirected: false });
      bodyData.set(this, record);
    }
    static error() {
      const response = new Response(null, { status: 200 });
      const state = responseState(response);
      state.type = "error";
      state.status = 0;
      setGuard(state.headers, "immutable");
      return response;
    }
    static redirect(url, status) {
      const code = status === undefined ? 302 : Number(status);
      if (redirectStatuses.indexOf(code) < 0)
        throw new RangeError("Failed to execute 'redirect' on 'Response': Invalid status code");
      const parsed = new URL(String(url), baseUrl());
      const response = new Response(null, { status: code, headers: { Location: parsed.href } });
      setGuard(responseState(response).headers, "immutable");
      return response;
    }
    static json(data, init) {
      const text = JSON.stringify(data);
      if (text === undefined) throw new TypeError("Failed to execute 'json' on 'Response': The data is not JSON " +
        "serializable");
      const response = new Response(text, init);
      responseState(response).headers.set("Content-Type", "application/json");
      return response;
    }
    get type() { return responseState(this).type; }
    get url() {
      const url = responseState(this).url;
      const hash = url.indexOf("#");
      return hash < 0 ? url : url.slice(0, hash);
    }
    get redirected() { return responseState(this).redirected; }
    get status() { return responseState(this).status; }
    get ok() {
      const status = responseState(this).status;
      return status >= 200 && status <= 299;
    }
    get statusText() { return responseState(this).statusText; }
    get headers() { return responseState(this).headers; }
    clone() {
      const state = responseState(this);
      const body = bodyOf(this);
      if (body.stream !== null && internal.streamIsDisturbed(body.stream))
        throw new TypeError("Failed to execute 'clone' on 'Response': Response body is already used");
      const copy = new Response(null);
      const copyState = Object.assign({}, state);
      copyState.headers = headersWithGuard(internal.headerList(state.headers).map(function (entry) {
        return entry.slice();
      }), headersState(state.headers).guard);
      responseData.set(copy, copyState);
      if (body.stream === null) bodyData.set(copy, { stream: null, used: false });
      else if (body.bytes !== undefined) bodyData.set(copy, bodyRecord({ bytes: body.bytes }));
      else {
        const branches = body.stream.tee();
        body.stream = branches[0];
        bodyData.set(copy, { stream: branches[1], used: false });
      }
      return copy;
    }
  }
  defineBodyMembers(Response);
  internal.finishInterface(Response, "Response");

  function setGuard(headers, guard) {
    headersState(headers).guard = guard;
  }

  // For the Cache API (86-cache-storage.js): what a request and a
  // response are, a response's body bytes, and a response made again
  // from what was kept.
  internal.requestRecord = function (request) {
    const state = requestState(request);
    return { url: state.url, method: state.method, mode: state.mode, credentials: state.credentials,
      headers: internal.headerList(state.headers).map(function (entry) { return entry.slice(); }) };
  };
  internal.responseRecord = function (response) {
    const state = responseState(response);
    return { type: state.type, url: state.url, status: state.status, statusText: state.statusText,
      redirected: state.redirected, headers: internal.headerList(state.headers).map(function (entry) {
        return entry.slice();
      }) };
  };
  internal.bodyUnusable = function (object) {
    const body = bodyOf(object);
    return body.stream !== null && (internal.streamIsDisturbed(body.stream) || internal.streamIsLocked(body.stream));
  };
  internal.readBodyBytes = function (object) {
    return consume(object, function (bytes) { return bytes; });
  };
  internal.makeStoredResponse = function (record, bytes) {
    const response = new Response(null);
    responseData.set(response, { type: record.type, url: record.url, status: record.status,
      statusText: record.statusText, redirected: record.redirected,
      headers: headersWithGuard(record.headers.map(function (entry) { return entry.slice(); }), "immutable") });
    if (nullBodyStatuses.indexOf(record.status) >= 0 || record.type === "error") bodyData.set(response,
      { stream: null, used: false });
    else bodyData.set(response, bodyRecord({ bytes: bytes }));
    return response;
  };

  // ---- requests and responses as snapshots (a service worker's fetch
  // event and its answer) ----

  // The body of an opaque response: script never reads it, but a service
  // worker hands it to the page that asked.
  const opaqueBodies = new WeakMap();

  // A Response made by the engine: Record has type, url, status,
  // statusText, headerList ([name, value] pairs), redirected and bytes (a
  // Uint8Array, or null for no body).
  internal.makeResponse = function (record) {
    const response = new Response(null);
    const state = responseState(response);
    state.type = record.type;
    state.url = record.url || "";
    state.status = record.type === "opaque" ? 0 : record.status;
    state.statusText = record.type === "opaque" ? "" : record.statusText;
    state.redirected = !!record.redirected;
    state.headers = headersWithGuard(record.type === "opaque" ? [] :
      record.headerList.map(function (entry) { return entry.slice(); }), "immutable");
    const bytes = record.bytes === null || record.bytes === undefined ? null : record.bytes;
    if (record.type === "opaque") {
      bodyData.set(response, { stream: null, used: false });
      opaqueBodies.set(response, Promise.resolve(bytes === null ? new Uint8Array(0) : bytes));
    } else bodyData.set(response, bytes === null ? { stream: null, used: false } : bodyRecord({ bytes: bytes }));
    return response;
  };

  internal.isResponse = function (value) {
    return value !== null && typeof value === "object" && responseData.has(value);
  };
  internal.isRequest = function (value) {
    return value !== null && typeof value === "object" && requestData.has(value);
  };

  // A promise of Response's record (above), its body read to the end
  // (so the body is used afterwards).
  internal.responseSnapshot = function (response) {
    const state = responseState(response);
    const record = { type: state.type === "default" ? "basic" : state.type, url: state.url, status: state.status,
      statusText: state.statusText, redirected: state.redirected,
      headerList: internal.headerList(state.headers).map(function (entry) { return entry.slice(); }), bytes: null };
    if (opaqueBodies.has(response)) {
      return opaqueBodies.get(response).then(function (bytes) {
        record.bytes = bytes;
        return record;
      });
    }
    const body = bodyOf(response);
    if (body.stream === null) return Promise.resolve(record);
    body.used = true;
    const bytes = body.bytes !== undefined && !internal.streamIsDisturbed(body.stream) ? Promise.resolve(body.bytes) :
      internal.readAllBytes(body.stream);
    if (body.bytes !== undefined) internal.readAllBytes(body.stream).catch(function () {});
    return bytes.then(function (data) {
      record.bytes = data;
      return record;
    });
  };

  // A request's record: method, url, headerList, mode, credentials,
  // cache, redirect, referrer, referrerPolicy, integrity, destination,
  // keepalive and bytes (a promise of the body, null for none).
  internal.requestSnapshot = function (request) {
    const state = requestState(request);
    const body = bodyOf(request);
    return { method: state.method, url: state.url,
      headerList: state.headerList.map(function (entry) { return entry.slice(); }), mode: state.mode,
      credentials: state.credentials, cache: state.cache, redirect: state.redirect, referrer: state.referrer,
      referrerPolicy: state.referrerPolicy, integrity: state.integrity, destination: state.destination,
      keepalive: state.keepalive,
      bytes: body.stream === null ? null : body.bytes !== undefined ? Promise.resolve(body.bytes) :
        internal.readAllBytes(body.stream) };
  };

  // A Request made by the engine (a fetch event's): a record as above
  // with bytes a Uint8Array or null; mode may be navigate. The headers
  // are immutable.
  internal.makeRequest = function (record) {
    const request = new Request(record.url, record.bytes === null || record.method === "GET" || record.method === "HEAD" ?
      { method: record.method } : { method: record.method, body: record.bytes });
    const state = requestState(request);
    state.mode = record.mode;
    state.credentials = record.credentials;
    state.cache = record.cache;
    state.redirect = record.redirect;
    state.referrer = record.referrer === "" ? "no-referrer" : record.referrer;
    state.referrerPolicy = record.referrerPolicy;
    state.integrity = record.integrity;
    state.destination = record.destination;
    state.headerList = record.headerList.map(function (entry) { return entry.slice(); });
    state.headers = headersWithGuard(state.headerList, "immutable");
    return request;
  };

  // ---- the network ----

  const pending = new Map();
  natives.onFetchEvent = function (id, kind, a, b, c, d, e) {
    const entry = pending.get(id);
    if (entry === undefined) return;
    if (kind === "response") entry.onResponse(a, b, c, d, e);
    else if (kind === "data") entry.onData(a);
    else if (kind === "end") {
      pending.delete(id);
      entry.onEnd();
    } else if (kind === "error") {
      pending.delete(id);
      entry.onError(a);
    }
  };

  // Starts a fetch of a request state and body bytes; handlers get the
  // response head, the body pieces, the end or a network error.
  function startFetch(state, bytes, handlers) {
    const id = natives.fetchStart({
      method: state.method, url: state.url, headers: state.headerList.map(function (entry) { return entry.slice(); }),
      body: bytes, mode: state.mode, credentials: state.credentials, cache: state.cache, redirect: state.redirect,
      referrer: state.referrer, referrerPolicy: state.referrerPolicy, keepalive: state.keepalive,
      integrity: state.integrity, priority: state.priority, destination: state.destination || ""
    });
    pending.set(id, handlers);
    return id;
  }
  function abortFetch(id) {
    if (pending.delete(id)) natives.fetchAbort(id);
  }
  internal.startFetch = startFetch;
  internal.abortFetch = abortFetch;

  function fetchBlobUrl(state) {
    const object = internal.blobUrls.get(state.url.split("#")[0]);
    if (object === undefined || state.method !== "GET") return Promise.reject(new TypeError("Failed to fetch"));
    const bytes = internal.blobBytes(object);
    const response = new Response(null);
    const responseStateValue = responseState(response);
    responseStateValue.type = "basic";
    responseStateValue.url = state.url;
    responseStateValue.headers = headersWithGuard([["Content-Type", object.type], ["Content-Length",
      String(bytes.length)]], "immutable");
    bodyData.set(response, bodyRecord({ bytes: bytes.slice() }));
    return Promise.resolve(response);
  }

  function joinChunks(chunks) {
    let total = 0;
    for (const chunk of chunks) total += chunk.length;
    const bytes = new Uint8Array(total);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.length;
    }
    return bytes;
  }

  internal.define(global, "fetch", function fetch(input, init) {
    let request;
    try {
      request = new Request(input, init);
    } catch (error) {
      return Promise.reject(error);
    }
    const state = requestState(request);
    if (state.signal.aborted) return Promise.reject(state.signal.reason);
    if (state.url.startsWith("blob:")) return fetchBlobUrl(state);
    const body = bodyOf(request);
    const bodyBytes = body.stream === null ? Promise.resolve(null) :
      body.bytes !== undefined ? Promise.resolve(body.bytes) : internal.readAllBytes(body.stream);
    return bodyBytes.then(function (bytes) {
      if (state.signal.aborted) return Promise.reject(state.signal.reason);
      return new Promise(function (resolve, reject) {
        let controller = null;
        let finished = false;
        let opaqueDone = null;
        const queued = [];
        let ended = false;
        let failure = null;
        const id = startFetch(state, bytes, {
          onResponse: function (status, statusText, headerList, url, details) {
            const response = new Response(null);
            const responseStateValue = responseState(response);
            responseStateValue.type = details.type;
            responseStateValue.status = status;
            responseStateValue.statusText = statusText;
            responseStateValue.url = url;
            responseStateValue.redirected = details.redirected;
            responseStateValue.headers = headersWithGuard(headerList, "immutable");
            if (details.type === "opaque") {
              bodyData.set(response, { stream: null, used: false });
              opaqueBodies.set(response, new Promise(function (resolveBody) {
                opaqueDone = resolveBody;
              }));
            } else if (state.method === "HEAD" || nullBodyStatuses.indexOf(status) >= 0)
              bodyData.set(response, { stream: null, used: false });
            else bodyData.set(response, {
              stream: new ReadableStream({
                start: function (streamController) {
                  controller = streamController;
                  for (const chunk of queued.splice(0)) controller.enqueue(chunk);
                  if (failure !== null) controller.error(failure);
                  else if (ended) controller.close();
                },
                cancel: function () {
                  if (!finished) abortFetch(id);
                }
              }, { highWaterMark: Infinity }),
              used: false
            });
            resolve(response);
          },
          onData: function (chunk) {
            if (controller !== null) controller.enqueue(chunk);
            else queued.push(chunk);
          },
          onEnd: function () {
            finished = true;
            ended = true;
            if (controller !== null) try { controller.close(); } catch (error) {}
            if (opaqueDone !== null) opaqueDone(joinChunks(queued.splice(0)));
          },
          onError: function (message) {
            finished = true;
            if (opaqueDone !== null) opaqueDone(new Uint8Array(0));
            failure = new TypeError("Failed to fetch");
            if (controller !== null) controller.error(failure);
            reject(failure);
          }
        });
        internal.onAbort(state.signal, function () {
          if (finished) return;
          finished = true;
          abortFetch(id);
          if (controller !== null) controller.error(state.signal.reason);
          reject(state.signal.reason);
        });
      });
    });
  });

  // ---- XMLHttpRequest ----

  const xhrData = new WeakMap();
  function xhrState(object) {
    const state = xhrData.get(object);
    if (state === undefined) throw new TypeError("Illegal invocation");
    return state;
  }

  class XMLHttpRequestEventTarget extends EventTarget {
    constructor(key) {
      if (key !== token) internal.illegal();
      super();
    }
  }
  for (const name of ["loadstart", "progress", "abort", "error", "load", "timeout", "loadend"])
    internal.defineHandler(XMLHttpRequestEventTarget.prototype, name);
  internal.finishInterface(XMLHttpRequestEventTarget, "XMLHttpRequestEventTarget");

  class XMLHttpRequestUpload extends XMLHttpRequestEventTarget {
    constructor(key) {
      if (key !== token) internal.illegal();
      super(token);
    }
  }
  internal.finishInterface(XMLHttpRequestUpload, "XMLHttpRequestUpload");

  const UNSENT = 0, OPENED = 1, HEADERS_RECEIVED = 2, LOADING = 3, DONE = 4;

  class XMLHttpRequest extends XMLHttpRequestEventTarget {
    constructor() {
      super(token);
      xhrData.set(this, { readyState: UNSENT, method: "GET", url: "", headerList: [], withCredentials: false,
        timeout: 0, responseType: "", sendFlag: false, status: 0, statusText: "", responseHeaders: [],
        responseUrl: "", chunks: [], received: 0, total: 0, response: null, fetchId: null, timer: null,
        upload: new XMLHttpRequestUpload(token), overrideMime: null, errorFlag: false });
    }
    get readyState() { return xhrState(this).readyState; }
    open(method, url, async, username, password) {
      const state = xhrState(this);
      const methodText = internal.toByteString(method);
      if (!tokenPattern.test(methodText)) throw internal.domException("'" + methodText + "' is not a valid HTTP " +
        "method.", "SyntaxError");
      const upper = methodText.toUpperCase();
      if (["CONNECT", "TRACE", "TRACK"].indexOf(upper) >= 0)
        throw internal.domException("'" + methodText + "' HTTP method is unsupported.", "SecurityError");
      let parsed;
      try {
        parsed = new URL(String(url), baseUrl());
      } catch (error) {
        throw internal.domException("Failed to execute 'open' on 'XMLHttpRequest': Invalid URL", "SyntaxError");
      }
      if (arguments.length >= 3 && !async)
        console.warn("Synchronous XMLHttpRequest is not supported: the request runs asynchronously.");
      abortRunning(state);
      state.method = ["DELETE", "GET", "HEAD", "OPTIONS", "POST", "PUT", "PATCH"].indexOf(upper) >= 0 ? upper :
        methodText;
      state.url = parsed.href;
      state.headerList = [];
      state.sendFlag = false;
      state.response = null;
      state.documentResponse = undefined;
      state.chunks = [];
      state.received = 0;
      state.status = 0;
      state.statusText = "";
      state.responseHeaders = [];
      state.errorFlag = false;
      if (state.readyState !== OPENED) {
        state.readyState = OPENED;
        internal.fire(this, new Event("readystatechange"));
      }
    }
    setRequestHeader(name, value) {
      const state = xhrState(this);
      if (state.readyState !== OPENED || state.sendFlag)
        throw internal.domException("Failed to execute 'setRequestHeader' on 'XMLHttpRequest': The object's state " +
          "must be OPENED.", "InvalidStateError");
      const checkedName = checkName(name);
      const checkedValue = checkValue(value);
      if (isForbidden(checkedName)) return;
      const lower = checkedName.toLowerCase();
      const existing = state.headerList.find(function (entry) { return entry[0].toLowerCase() === lower; });
      if (existing) existing[1] += ", " + checkedValue;
      else state.headerList.push([checkedName, checkedValue]);
    }
    get timeout() { return xhrState(this).timeout; }
    set timeout(value) { xhrState(this).timeout = Number(value) >>> 0; }
    get withCredentials() { return xhrState(this).withCredentials; }
    set withCredentials(value) { xhrState(this).withCredentials = !!value; }
    get upload() { return xhrState(this).upload; }
    send(body) {
      const target = this;
      const state = xhrState(this);
      if (state.readyState !== OPENED || state.sendFlag)
        throw internal.domException("Failed to execute 'send' on 'XMLHttpRequest': The object's state must be " +
          "OPENED.", "InvalidStateError");
      let bytes = null;
      if (body !== undefined && body !== null && state.method !== "GET" && state.method !== "HEAD") {
        let extracted;
        if (body instanceof Document) extracted = { bytes: internal.encodeText(new XMLSerializerLike().serialize(body)),
          type: "text/html;charset=UTF-8" };
        else extracted = extractBody(body);
        bytes = extracted.bytes;
        if (extracted.type && !state.headerList.some(function (entry) { return entry[0].toLowerCase() === "content-type"; }))
          state.headerList.push(["Content-Type", extracted.type]);
      }
      state.sendFlag = true;
      state.errorFlag = false;
      fireXhrProgress(this, "loadstart", 0, 0, false);
      if (bytes !== null) fireXhrProgress(state.upload, "loadstart", 0, bytes.length, true);
      if (state.readyState !== OPENED || !state.sendFlag) return;
      const requestStateValue = { method: state.method, url: state.url, headerList: state.headerList, mode: "cors",
        credentials: state.withCredentials ? "include" : "same-origin", cache: "default", redirect: "follow",
        referrer: "about:client", referrerPolicy: "", keepalive: false, integrity: "", priority: "auto",
        destination: "" };
      if (state.url.startsWith("blob:")) {
        fetchBlobUrl(requestStateValue).then(function (response) {
          return response.arrayBuffer().then(function (buffer) {
            receiveHead(target, state, 200, "OK", internal.headerList(response.headers), state.url);
            receiveData(target, state, new Uint8Array(buffer));
            receiveEnd(target, state);
          });
        }, function () { failRequest(target, state, "error"); });
        return;
      }
      state.fetchId = startFetch(requestStateValue, bytes, {
        onResponse: function (status, statusText, headerList, url, details) {
          if (bytes !== null) {
            fireXhrProgress(state.upload, "progress", bytes.length, bytes.length, true);
            fireXhrProgress(state.upload, "load", bytes.length, bytes.length, true);
            fireXhrProgress(state.upload, "loadend", bytes.length, bytes.length, true);
          }
          receiveHead(target, state, status, statusText, headerList, url);
        },
        onData: function (chunk) { receiveData(target, state, chunk); },
        onEnd: function () {
          state.fetchId = null;
          receiveEnd(target, state);
        },
        onError: function () {
          state.fetchId = null;
          failRequest(target, state, "error");
        }
      });
      if (state.timeout > 0)
        state.timer = global.setTimeout(function () {
          if (state.fetchId !== null) {
            abortFetch(state.fetchId);
            state.fetchId = null;
            failRequest(target, state, "timeout");
          }
        }, state.timeout);
    }
    abort() {
      const state = xhrState(this);
      const running = state.fetchId !== null;
      abortRunning(state);
      if ((state.readyState === OPENED && state.sendFlag) || state.readyState === HEADERS_RECEIVED ||
        state.readyState === LOADING || running) {
        failRequest(this, state, "abort");
      }
      if (state.readyState === DONE) {
        state.readyState = UNSENT;
        state.response = null;
        state.documentResponse = undefined;
      }
    }
    get responseURL() {
      const url = xhrState(this).responseUrl;
      const hash = url.indexOf("#");
      return hash < 0 ? url : url.slice(0, hash);
    }
    get status() { return xhrState(this).status; }
    get statusText() { return xhrState(this).statusText; }
    getResponseHeader(name) {
      const state = xhrState(this);
      if (state.readyState < HEADERS_RECEIVED || state.errorFlag) return null;
      const lower = String(name).toLowerCase();
      const values = state.responseHeaders.filter(function (entry) { return entry[0].toLowerCase() === lower; })
        .map(function (entry) { return entry[1]; });
      return values.length === 0 ? null : values.join(", ");
    }
    getAllResponseHeaders() {
      const state = xhrState(this);
      if (state.readyState < HEADERS_RECEIVED || state.errorFlag) return "";
      const headers = headersWithGuard(state.responseHeaders.slice(), "immutable");
      let text = "";
      for (const [name, value] of sortedPairs(headers)) text += name + ": " + value + "\r\n";
      return text;
    }
    overrideMimeType(mime) {
      const state = xhrState(this);
      if (state.readyState === LOADING || state.readyState === DONE)
        throw internal.domException("Failed to execute 'overrideMimeType' on 'XMLHttpRequest': MimeType cannot be " +
          "overridden when the state is LOADING or DONE.", "InvalidStateError");
      state.overrideMime = String(mime);
    }
    get responseType() { return xhrState(this).responseType; }
    set responseType(value) {
      const state = xhrState(this);
      const type = String(value);
      if (["", "arraybuffer", "blob", "document", "json", "text"].indexOf(type) < 0) return;
      if (state.readyState === LOADING || state.readyState === DONE)
        throw internal.domException("Failed to set the 'responseType' property on 'XMLHttpRequest': The response " +
          "type cannot be set if the object's state is LOADING or DONE.", "InvalidStateError");
      state.responseType = type;
    }
    get response() {
      const state = xhrState(this);
      if (state.responseType === "" || state.responseType === "text") {
        if (state.readyState < LOADING) return "";
        return responseText(state);
      }
      if (state.readyState !== DONE || state.errorFlag) return null;
      if (state.response !== null) return state.response;
      const bytes = responseBytes(state);
      if (state.responseType === "arraybuffer") state.response = bytes.buffer;
      else if (state.responseType === "blob") state.response = internal.makeBlob(bytes, contentTypeOf(state));
      else if (state.responseType === "json") {
        try {
          state.response = JSON.parse(internal.decodeText(bytes));
        } catch (error) {
          state.response = null;
        }
      } else if (state.responseType === "document") {
        state.response = documentResponse(state, bytes);
      }
      return state.response;
    }
    get responseText() {
      const state = xhrState(this);
      if (state.responseType !== "" && state.responseType !== "text")
        throw internal.domException("Failed to read the 'responseText' property from 'XMLHttpRequest': The value is " +
          "only accessible if the object's 'responseType' is '' or 'text' (was '" + state.responseType + "').",
          "InvalidStateError");
      if (state.readyState < LOADING) return "";
      return responseText(state);
    }
    get responseXML() {
      const state = xhrState(this);
      if (state.responseType !== "" && state.responseType !== "document")
        throw internal.domException("The value is only accessible if the object's 'responseType' is '' or " +
          "'document'.", "InvalidStateError");
      if (state.readyState !== DONE || state.errorFlag) return null;
      if (state.responseType === "document") return this.response;
      if (state.documentResponse === undefined) state.documentResponse = documentResponse(state, responseBytes(state));
      return state.documentResponse;
    }
  }
  XMLHttpRequest.UNSENT = UNSENT;
  XMLHttpRequest.OPENED = OPENED;
  XMLHttpRequest.HEADERS_RECEIVED = HEADERS_RECEIVED;
  XMLHttpRequest.LOADING = LOADING;
  XMLHttpRequest.DONE = DONE;
  for (const [name, value] of [["UNSENT", UNSENT], ["OPENED", OPENED], ["HEADERS_RECEIVED", HEADERS_RECEIVED],
    ["LOADING", LOADING], ["DONE", DONE]])
    Object.defineProperty(XMLHttpRequest.prototype, name, { value: value, enumerable: true });
  internal.defineHandler(XMLHttpRequest.prototype, "readystatechange");
  internal.finishInterface(XMLHttpRequest, "XMLHttpRequest");

  function XMLSerializerLike() {}
  XMLSerializerLike.prototype.serialize = function (document) {
    return document.documentElement ? document.documentElement.outerHTML : "";
  };

  // The document a response is (XMLHttpRequest's "document response"):
  // HTML only when responseType is "document", XML for an XML MIME type,
  // null for anything else or XML that is not well-formed.
  function documentResponse(state, bytes) {
    const essence = contentTypeOf(state).split(";")[0].trim().toLowerCase();
    const isXml = essence === "" || essence === "text/xml" || essence === "application/xml" || /\+xml$/.test(essence);
    const parser = new global.DOMParser();
    if (essence === "text/html") {
      if (state.responseType !== "document") return null;
      return parser.parseFromString(internal.decodeText(bytes), "text/html");
    }
    if (!isXml) return null;
    const document = parser.parseFromString(internal.decodeText(bytes), "application/xml");
    const root = document.documentElement;
    if (root !== null && root.localName === "parsererror" &&
      root.namespaceURI === "http://www.mozilla.org/newlayout/xml/parsererror.xml") return null;
    return document;
  }
  function contentTypeOf(state) {
    if (state.overrideMime !== null) return state.overrideMime;
    const entry = state.responseHeaders.find(function (item) { return item[0].toLowerCase() === "content-type"; });
    return entry ? entry[1] : "";
  }
  function responseBytes(state) {
    const bytes = new Uint8Array(state.received);
    let offset = 0;
    for (const chunk of state.chunks) {
      bytes.set(chunk, offset);
      offset += chunk.length;
    }
    state.chunks = [bytes];
    return bytes;
  }
  function responseText(state) {
    if (state.textCacheLength !== state.received) {
      const type = contentTypeOf(state);
      const match = /charset=["']?([\w.:-]+)/i.exec(type);
      let label = match ? match[1] : "utf-8";
      let text;
      try {
        text = new TextDecoder(label).decode(responseBytes(state));
      } catch (error) {
        text = internal.decodeText(responseBytes(state));
      }
      state.textCache = text;
      state.textCacheLength = state.received;
    }
    return state.textCache;
  }
  function fireXhrProgress(target, type, loaded, total, computable) {
    internal.fire(target, new ProgressEvent(type, { lengthComputable: !!computable, loaded: loaded, total: total }));
  }
  function abortRunning(state) {
    if (state.fetchId !== null) {
      abortFetch(state.fetchId);
      state.fetchId = null;
    }
    if (state.timer !== null) {
      global.clearTimeout(state.timer);
      state.timer = null;
    }
  }
  function receiveHead(target, state, status, statusText, headerList, url) {
    state.status = status;
    state.statusText = statusText;
    state.responseHeaders = headerList;
    state.responseUrl = url;
    const length = state.responseHeaders.find(function (entry) { return entry[0].toLowerCase() === "content-length"; });
    state.total = length ? Number(length[1]) || 0 : 0;
    state.readyState = HEADERS_RECEIVED;
    internal.fire(target, new Event("readystatechange"));
  }
  function receiveData(target, state, chunk) {
    if (state.readyState === DONE || state.readyState === UNSENT) return;
    state.chunks.push(chunk);
    state.received += chunk.length;
    if (state.readyState === HEADERS_RECEIVED) state.readyState = LOADING;
    internal.fire(target, new Event("readystatechange"));
    fireXhrProgress(target, "progress", state.received, state.total, state.total > 0);
  }
  function receiveEnd(target, state) {
    if (state.timer !== null) {
      global.clearTimeout(state.timer);
      state.timer = null;
    }
    if (state.readyState === UNSENT) return;
    state.readyState = DONE;
    state.sendFlag = false;
    internal.fire(target, new Event("readystatechange"));
    fireXhrProgress(target, "load", state.received, state.total, state.total > 0);
    fireXhrProgress(target, "loadend", state.received, state.total, state.total > 0);
  }
  function failRequest(target, state, kind) {
    if (state.timer !== null) {
      global.clearTimeout(state.timer);
      state.timer = null;
    }
    state.readyState = DONE;
    state.sendFlag = false;
    state.errorFlag = true;
    state.status = 0;
    state.statusText = "";
    state.responseHeaders = [];
    state.chunks = [];
    state.received = 0;
    internal.fire(target, new Event("readystatechange"));
    fireXhrProgress(target, kind, 0, 0, false);
    fireXhrProgress(target, "loadend", 0, 0, false);
  }
})
