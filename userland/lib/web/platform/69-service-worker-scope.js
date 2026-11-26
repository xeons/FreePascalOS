// A service worker's side (Service Workers, sections 4 and 5), run in
// the worker's agent window (Web.Workers.Agents): the
// ServiceWorkerGlobalScope (clients, registration, serviceWorker,
// skipWaiting, importScripts, the install, activate, fetch and message
// events) made by 65-workers.js's runner, with ExtendableEvent,
// FetchEvent, ExtendableMessageEvent, Clients, Client and WindowClient
// defined in the scope only. Web.Script.NativeServiceWorkers tells the
// agent what to do (natives.onServiceWorker*); what the script does is
// reported back (natives.sw*).
//
// The update check fetches the script here (Service-Worker: script, no
// redirects, the HTTP cache bypassed unless updateViaCache is 'all'). A
// fetch event's respondWith hands back the response's whole record and
// body; without respondWith the request goes to the network.
(function (natives, global, internal) {
  "use strict";
  if (!global.isSecureContext) return;
  const token = internal.token;
  const defineProperty = Object.defineProperty;
  const scopeInterfaces = {};

  // As internal.finishInterface, but the interface goes on the worker's
  // scope only ([Exposed=ServiceWorker]).
  function finishScopeInterface(Class, name) {
    const prototype = Class.prototype;
    for (const key of Object.getOwnPropertyNames(prototype)) {
      if (key === "constructor") continue;
      const descriptor = Object.getOwnPropertyDescriptor(prototype, key);
      descriptor.enumerable = true;
      defineProperty(prototype, key, descriptor);
    }
    defineProperty(prototype, Symbol.toStringTag, { value: name, configurable: true });
    scopeInterfaces[name] = Class;
  }

  // ---- events ----

  const extendData = new WeakMap();
  function extendState(event) {
    const state = extendData.get(event);
    if (state === undefined) throw new TypeError("Illegal invocation");
    return state;
  }

  class ExtendableEvent extends Event {
    constructor(type, eventInitDict) {
      super(type, eventInitDict);
      extendData.set(this, { dispatching: false, pending: 0, rejected: false, waiters: [], respondWith: null,
        responded: false });
    }
    waitUntil(promise) {
      const state = extendState(this);
      if (arguments.length < 1)
        throw new TypeError("Failed to execute 'waitUntil' on 'ExtendableEvent': 1 argument required.");
      if (!state.dispatching && state.pending === 0)
        throw internal.domException("Failed to execute 'waitUntil' on 'ExtendableEvent': The event handler is " +
          "already finished.", "InvalidStateError");
      state.pending++;
      Promise.resolve(promise).then(function () {
        settle(state, false);
      }, function () {
        settle(state, true);
      });
    }
  }
  finishScopeInterface(ExtendableEvent, "ExtendableEvent");

  function settle(state, rejected) {
    if (rejected) state.rejected = true;
    // A microtask later, so that waitUntil may be called again from a
    // promise reaction of the one that settled.
    Promise.resolve().then(function () {
      state.pending--;
      if (state.pending === 0 && !state.dispatching) for (const waiter of state.waiters.splice(0)) waiter();
    });
  }

  // A promise that settles when the event's extensions all did: true
  // when none was rejected.
  function lifetimeOf(event) {
    const state = extendState(event);
    return new Promise(function (resolve) {
      const finish = function () { resolve(!state.rejected); };
      if (state.pending === 0) finish();
      else state.waiters.push(finish);
    });
  }

  // Dispatches Event at the scope with the dispatch flag set; True when
  // a listener threw (reported to the console).
  function dispatchExtendable(event) {
    const state = extendState(event);
    state.dispatching = true;
    let threw = false;
    try {
      runner.deliver(event);
    } catch (error) {
      threw = true;
      console.error(error && error.stack ? error.stack : String(error));
    } finally {
      state.dispatching = false;
    }
    return threw;
  }

  const fetchEventData = new WeakMap();
  class FetchEvent extends ExtendableEvent {
    constructor(type, eventInitDict) {
      if (arguments.length < 2 || eventInitDict === null || typeof eventInitDict !== "object" ||
          !internal.isRequest(eventInitDict.request))
        throw new TypeError("Failed to construct 'FetchEvent': required member request is undefined.");
      super(type, eventInitDict);
      fetchEventData.set(this, { request: eventInitDict.request,
        clientId: eventInitDict.clientId === undefined ? "" : String(eventInitDict.clientId),
        resultingClientId: eventInitDict.resultingClientId === undefined ? "" : String(eventInitDict.resultingClientId),
        replacesClientId: eventInitDict.replacesClientId === undefined ? "" : String(eventInitDict.replacesClientId),
        preloadResponse: eventInitDict.preloadResponse === undefined ? Promise.resolve(undefined) :
          eventInitDict.preloadResponse,
        handled: eventInitDict.handled === undefined ? Promise.resolve(undefined) : eventInitDict.handled });
    }
    get request() { return fetchEventData.get(this).request; }
    get clientId() { return fetchEventData.get(this).clientId; }
    get resultingClientId() { return fetchEventData.get(this).resultingClientId; }
    get replacesClientId() { return fetchEventData.get(this).replacesClientId; }
    get preloadResponse() { return fetchEventData.get(this).preloadResponse; }
    get handled() { return fetchEventData.get(this).handled; }
    respondWith(r) {
      const state = extendState(this);
      if (arguments.length < 1)
        throw new TypeError("Failed to execute 'respondWith' on 'FetchEvent': 1 argument required.");
      if (!state.dispatching)
        throw internal.domException("Failed to execute 'respondWith' on 'FetchEvent': The event handler is " +
          "already finished.", "InvalidStateError");
      if (state.responded)
        throw internal.domException("Failed to execute 'respondWith' on 'FetchEvent': The event has already been " +
          "responded to.", "InvalidStateError");
      state.responded = true;
      const promise = Promise.resolve(r);
      state.respondWith = promise;
      this.waitUntil(promise);
      this.stopImmediatePropagation();
    }
  }
  finishScopeInterface(FetchEvent, "FetchEvent");

  const messageData = new WeakMap();
  class ExtendableMessageEvent extends ExtendableEvent {
    constructor(type, eventInitDict) {
      super(type, eventInitDict);
      const init = eventInitDict == null ? {} : eventInitDict;
      messageData.set(this, { data: init.data === undefined ? null : init.data,
        origin: init.origin === undefined ? "" : String(init.origin),
        lastEventId: init.lastEventId === undefined ? "" : String(init.lastEventId),
        source: init.source === undefined ? null : init.source,
        ports: init.ports === undefined ? [] : Array.from(init.ports) });
    }
    get data() { return messageData.get(this).data; }
    get origin() { return messageData.get(this).origin; }
    get lastEventId() { return messageData.get(this).lastEventId; }
    get source() { return messageData.get(this).source; }
    get ports() { return Object.freeze(messageData.get(this).ports.slice()); }
  }
  finishScopeInterface(ExtendableMessageEvent, "ExtendableMessageEvent");

  // ---- clients ----

  const clientData = new WeakMap();
  function clientState(client) {
    const state = clientData.get(client);
    if (state === undefined) throw new TypeError("Illegal invocation");
    return state;
  }

  class Client {
    constructor(key, info) {
      if (key !== token) internal.illegal();
      clientData.set(this, { id: info[0], url: info[1], type: info[2], frameType: info[3], focused: info[4],
        visibilityState: info[5] });
    }
    get id() { return clientState(this).id; }
    get url() { return clientState(this).url; }
    get type() { return clientState(this).type; }
    get frameType() { return clientState(this).frameType; }
    postMessage(message, transferOrOptions) {
      const state = clientState(this);
      if (arguments.length < 1) throw new TypeError("Failed to execute 'postMessage' on 'Client': 1 argument required.");
      const ports = internal.transferredPorts(transferOrOptions);
      const text = internal.serializeMessage(message, ports);
      natives.swClientPost(state.id, text, ports.map(internal.portToLink));
    }
  }
  finishScopeInterface(Client, "Client");

  class WindowClient extends Client {
    constructor(key, info) {
      super(key, info);
    }
    get focused() { return clientState(this).focused; }
    get visibilityState() { return clientState(this).visibilityState; }
    get ancestorOrigins() { return Object.freeze([]); }
    focus() {
      clientState(this);
      // Only a notification click may focus a window; there are none.
      return Promise.reject(internal.domException("Failed to execute 'focus' on 'WindowClient': Not allowed to focus " +
        "a window.", "InvalidAccessError"));
    }
    navigate(url) {
      const state = clientState(this);
      let target;
      try {
        target = new URL(String(url), scriptUrl).href;
      } catch (error) {
        return Promise.reject(new TypeError("Failed to execute 'navigate' on 'WindowClient': Invalid URL."));
      }
      if (target.startsWith("about:"))
        return Promise.reject(new TypeError("Failed to execute 'navigate' on 'WindowClient': about: URLs are not " +
          "allowed."));
      if (!natives.swClientNavigate(state.id, target))
        return Promise.reject(new TypeError("Failed to execute 'navigate' on 'WindowClient': The client is not " +
          "controlled by this worker."));
      // The new document is another client, made later: not known yet.
      return Promise.resolve(null);
    }
  }
  finishScopeInterface(WindowClient, "WindowClient");

  function clientFor(info) {
    return info[2] === "window" ? new WindowClient(token, info) : new Client(token, info);
  }

  const clientTypes = ["window", "worker", "sharedworker", "all"];
  class Clients {
    constructor(key) {
      if (key !== token) internal.illegal();
    }
    get(id) {
      try {
        const info = natives.swClient(String(id));
        return Promise.resolve(info === null ? undefined : clientFor(info));
      } catch (error) {
        return Promise.reject(error);
      }
    }
    matchAll(options) {
      try {
        const settings = options === undefined || options === null ? {} : options;
        const type = settings.type === undefined ? "window" : String(settings.type);
        if (clientTypes.indexOf(type) < 0)
          throw new TypeError("Failed to execute 'matchAll' on 'Clients': The provided value '" + type +
            "' is not a valid enum value of type ClientType.");
        return Promise.resolve(natives.swClients(!!settings.includeUncontrolled, type).map(clientFor));
      } catch (error) {
        return Promise.reject(error);
      }
    }
    openWindow(url) {
      try {
        new URL(String(url), scriptUrl);
      } catch (error) {
        return Promise.reject(new TypeError("Failed to execute 'openWindow' on 'Clients': Invalid URL."));
      }
      // Only a notification click may open a window; there are none.
      return Promise.reject(internal.domException("Failed to execute 'openWindow' on 'Clients': Not allowed to " +
        "open a window.", "InvalidAccessError"));
    }
    claim() {
      if (natives.swClaim()) return Promise.resolve(undefined);
      return Promise.reject(internal.domException("Failed to execute 'claim' on 'Clients': Only the active worker " +
        "can claim clients.", "InvalidStateError"));
    }
  }
  finishScopeInterface(Clients, "Clients");

  // ---- the worker ----

  let runner = null;
  let scriptUrl = "";
  let registrationInfo = null;
  let workerInfo = null;
  const clientsObject = new Clients(token);

  function setupScope(scope) {
    for (const name of Object.keys(scopeInterfaces)) scope[name] = scopeInterfaces[name];
    for (const name of ["ServiceWorker", "ServiceWorkerRegistration", "NavigationPreloadManager",
      "ServiceWorkerContainer"])
      scope[name] = global[name];
    scope.clients = clientsObject;
    scope.registration = internal.serviceWorkerRegistrationFor(registrationInfo);
    scope.serviceWorker = internal.serviceWorkerFor(workerInfo);
    scope.skipWaiting = function skipWaiting() {
      natives.swSkipWaiting();
      return Promise.resolve(undefined);
    };
  }

  natives.onServiceWorkerStart = function (workerId, url, registration, state) {
    scriptUrl = url;
    registrationInfo = registration;
    workerInfo = [workerId, url, state];
    runner = internal.createWorkerRunner({
      url: url,
      kind: "ServiceWorkerGlobalScope",
      handlers: ["install", "activate", "fetch", "message", "messageerror"],
      setup: setupScope
    });
  };

  natives.onServiceWorkerFetchScript = function (useCache) {
    global.fetch(scriptUrl, { mode: "same-origin", credentials: "same-origin", redirect: "error",
      cache: useCache ? "default" : "no-cache", headers: { "Service-Worker": "script" } }).then(function (response) {
      if (!response.ok) throw new Error("A bad HTTP response code (" + response.status + ") was received when " +
        "fetching the script.");
      const type = response.headers.get("content-type") || "";
      const essence = type.split(";")[0].trim().toLowerCase();
      const allowed = response.headers.get("service-worker-allowed") || "";
      // The worker's own policies come with its script.
      const policy = response.headers.get("content-security-policy") || "";
      const reportOnly = response.headers.get("content-security-policy-report-only") || "";
      return response.text().then(function (text) {
        natives.swScriptFetched(true, text, essence, allowed, "", policy, reportOnly);
      });
    }).catch(function (failure) {
      natives.swScriptFetched(false, "", "", "", String(failure && failure.message || failure));
    });
  };

  natives.onServiceWorkerRun = function (source, importUrls, importSources) {
    for (let index = 0; index < importUrls.length; index++)
      runner.state.imports.set(importUrls[index], importSources[index]);
    runner.run(source, function (error) {
      if (error !== undefined) console.error(error);
      const urls = [];
      const sources = [];
      for (const [url, text] of runner.state.imports) {
        urls.push(url);
        sources.push(text);
      }
      natives.swEvaluated(error !== undefined, error === undefined ? "" : error, runner.handles("fetch"), urls, sources);
    });
  };

  natives.onServiceWorkerEvent = function (eventId, type) {
    const event = new ExtendableEvent(type);
    const threw = dispatchExtendable(event);
    lifetimeOf(event).then(function (ok) {
      natives.swEventDone(eventId, ok && !(threw && type === "install"));
    });
  };

  natives.onServiceWorkerFetch = function (fetchId, record, clientId, resultingClientId, preloadHeader, isReload) {
    let resolveHandled;
    const handled = new Promise(function (resolve) { resolveHandled = resolve; });
    let preload = Promise.resolve(undefined);
    if (preloadHeader !== null)
      preload = global.fetch(record.url, { credentials: "include",
        headers: { "Service-Worker-Navigation-Preload": preloadHeader } }).catch(function () { return undefined; });
    let event;
    try {
      event = new FetchEvent("fetch", { request: internal.makeRequest(record), clientId: clientId,
        resultingClientId: resultingClientId, preloadResponse: preload, handled: handled, cancelable: true });
    } catch (error) {
      natives.swFetchRespond(fetchId, "fallback");
      return;
    }
    dispatchExtendable(event);
    const state = extendState(event);
    if (state.respondWith === null) {
      resolveHandled(undefined);
      natives.swFetchRespond(fetchId, "fallback");
      return;
    }
    state.respondWith.then(function (response) {
      if (!internal.isResponse(response)) throw new TypeError("respondWith: not a Response");
      if (internal.bodyUnusable(response)) throw new TypeError("respondWith: the body is already used");
      return internal.responseSnapshot(response);
    }).then(function (answer) {
      resolveHandled(undefined);
      natives.swFetchRespond(fetchId, "response", [answer.type, answer.url, answer.status, answer.statusText,
        answer.headerList], answer.bytes === null ? new Uint8Array(0) : answer.bytes);
    }, function (failure) {
      console.error("The FetchEvent for \"" + record.url + "\" resulted in a network error: " +
        String(failure && failure.message || failure));
      resolveHandled(undefined);
      natives.swFetchRespond(fetchId, "error");
    });
  };

  natives.onServiceWorkerMessage = function (eventId, text, ids, source) {
    let sourceObject = null;
    let origin = "";
    if (source !== null) {
      sourceObject = source[0] === "client" ? clientFor(source[1]) : internal.serviceWorkerFor(source[1]);
      origin = new URL(source[1][1]).origin;
    }
    let received;
    try {
      received = internal.receiveThroughLink(text, ids);
    } catch (error) {
      const failed = new ExtendableMessageEvent("messageerror", { origin: origin, source: sourceObject });
      dispatchExtendable(failed);
      natives.swEventDone(eventId, true);
      return;
    }
    const event = new ExtendableMessageEvent("message", { data: received.data, origin: origin, source: sourceObject,
      ports: received.ports });
    dispatchExtendable(event);
    lifetimeOf(event).then(function (ok) { natives.swEventDone(eventId, ok); });
  };
})
