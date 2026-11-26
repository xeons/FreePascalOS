// Service workers, the page's side (Service Workers, section 3):
// navigator.serviceWorker (ServiceWorkerContainer: register, controller,
// ready, getRegistration(s), startMessages and the client message
// queue), ServiceWorkerRegistration (installing, waiting, active, scope,
// updateViaCache, update, unregister, updatefound, navigationPreload),
// ServiceWorker (scriptURL, state, statechange, postMessage) and
// NavigationPreloadManager, in secure contexts only. The registrations,
// jobs and workers are the process's (Web.Workers.ServiceWorkers through
// Web.Script.NativeServiceWorkers): this realm keeps one object per
// registration and per worker and applies the updates it is sent, in
// order, before the events they come with. A worker's scope (69-service-
// worker-scope.js) uses the same objects for self.registration and
// self.serviceWorker.
(function (natives, global, internal) {
  "use strict";
  if (!global.isSecureContext) return;
  const token = internal.token;
  const workerData = new WeakMap();
  const workerObjects = new Map();
  const registrationData = new WeakMap();
  const registrationObjects = new Map();
  const pendingRequests = new Map();

  function errorOf(value) {
    if (value[0] === "TypeError") return new TypeError(value[1]);
    return internal.domException(value[1], value[0]);
  }

  // A promise of a request the natives answer later (Start: returns the
  // request's id; it may throw).
  function request(start, convert) {
    let id;
    try {
      id = start();
    } catch (error) {
      return Promise.reject(error);
    }
    return new Promise(function (resolve, reject) {
      pendingRequests.set(id, { resolve: resolve, reject: reject, convert: convert });
    });
  }

  natives.onServiceWorkerReply = function (id, ok, value) {
    const entry = pendingRequests.get(id);
    if (entry === undefined) return;
    pendingRequests.delete(id);
    if (ok) entry.resolve(entry.convert(value));
    else entry.reject(errorOf(value));
  };

  // ---- ServiceWorker ----

  function workerState(worker) {
    const state = workerData.get(worker);
    if (state === undefined) throw new TypeError("Illegal invocation");
    return state;
  }

  class ServiceWorker extends EventTarget {
    constructor(key, info) {
      if (key !== token) internal.illegal();
      super();
      workerData.set(this, { id: info[0], url: info[1], state: info[2] });
    }
    get scriptURL() { return workerState(this).url; }
    get state() { return workerState(this).state; }
    postMessage(message, transferOrOptions) {
      const state = workerState(this);
      if (arguments.length < 1)
        throw new TypeError("Failed to execute 'postMessage' on 'ServiceWorker': 1 argument required.");
      if (state.state === "redundant")
        throw internal.domException("Failed to execute 'postMessage' on 'ServiceWorker': The worker is redundant.",
          "InvalidStateError");
      const ports = internal.transferredPorts(transferOrOptions);
      const text = internal.serializeMessage(message, ports);
      natives.swPostMessage(state.id, text, ports.map(internal.portToLink));
    }
  }
  internal.defineHandler(ServiceWorker.prototype, "statechange");
  internal.defineHandler(ServiceWorker.prototype, "error");
  internal.finishInterface(ServiceWorker, "ServiceWorker");

  function workerFor(info) {
    if (info === null || info === undefined) return null;
    let worker = workerObjects.get(info[0]);
    if (worker === undefined) {
      worker = new ServiceWorker(token, info);
      workerObjects.set(info[0], worker);
    }
    return worker;
  }
  internal.serviceWorkerFor = workerFor;

  // ---- NavigationPreloadManager ----

  const preloadData = new WeakMap();
  function preloadCall(manager, operation, value) {
    try {
      const registration = preloadData.get(manager);
      if (registration === undefined) throw new TypeError("Illegal invocation");
      return Promise.resolve(natives.swPreload(registrationState(registration).id, operation, value));
    } catch (error) {
      return Promise.reject(error);
    }
  }
  class NavigationPreloadManager {
    constructor(key, registration) {
      if (key !== token) internal.illegal();
      preloadData.set(this, registration);
    }
    enable() { return preloadCall(this, "enable").then(function () { return undefined; }); }
    disable() { return preloadCall(this, "disable").then(function () { return undefined; }); }
    setHeaderValue(value) {
      const text = internal.toByteString(value);
      return preloadCall(this, "header", text).then(function () { return undefined; });
    }
    getState() {
      return preloadCall(this, "state").then(function (state) {
        return { enabled: state[0], headerValue: state[1] };
      });
    }
  }
  internal.finishInterface(NavigationPreloadManager, "NavigationPreloadManager");

  // ---- ServiceWorkerRegistration ----

  function registrationState(registration) {
    const state = registrationData.get(registration);
    if (state === undefined) throw new TypeError("Illegal invocation");
    return state;
  }

  function applyRegistration(state, info) {
    state.scope = info[1];
    state.updateViaCache = info[2];
    state.installing = workerFor(info[3]);
    state.waiting = workerFor(info[4]);
    state.active = workerFor(info[5]);
  }

  class ServiceWorkerRegistration extends EventTarget {
    constructor(key, info) {
      if (key !== token) internal.illegal();
      super();
      const state = { id: info[0], preload: null };
      applyRegistration(state, info);
      registrationData.set(this, state);
    }
    get installing() { return registrationState(this).installing; }
    get waiting() { return registrationState(this).waiting; }
    get active() { return registrationState(this).active; }
    get scope() { return registrationState(this).scope; }
    get updateViaCache() { return registrationState(this).updateViaCache; }
    get navigationPreload() {
      const state = registrationState(this);
      if (state.preload === null) state.preload = new NavigationPreloadManager(token, this);
      return state.preload;
    }
    update() {
      const registration = this;
      return request(function () { return natives.swUpdate(registrationState(registration).id); }, registrationFor);
    }
    unregister() {
      const registration = this;
      return request(function () { return natives.swUnregister(registrationState(registration).id); },
        function (value) { return value; });
    }
  }
  internal.defineHandler(ServiceWorkerRegistration.prototype, "updatefound");
  internal.finishInterface(ServiceWorkerRegistration, "ServiceWorkerRegistration");

  function registrationFor(info) {
    if (info === null || info === undefined) return undefined;
    let registration = registrationObjects.get(info[0]);
    if (registration === undefined) {
      registration = new ServiceWorkerRegistration(token, info);
      registrationObjects.set(info[0], registration);
    }
    return registration;
  }
  internal.serviceWorkerRegistrationFor = registrationFor;

  // ---- ServiceWorkerContainer ----

  const containerData = new WeakMap();
  function containerState(container) {
    const state = containerData.get(container);
    if (state === undefined) throw new TypeError("Illegal invocation");
    return state;
  }
  function baseUrl() {
    return global.document ? global.document.baseURI : global.location.href;
  }
  const updateViaCacheValues = ["imports", "all", "none"];
  const workerTypes = ["classic", "module"];

  class ServiceWorkerContainer extends EventTarget {
    constructor(key) {
      if (key !== token) internal.illegal();
      super();
      const state = { ready: null, resolveReady: null, queue: [], messagesEnabled: false };
      state.ready = new Promise(function (resolve) { state.resolveReady = resolve; });
      containerData.set(this, state);
    }
    get controller() {
      containerState(this);
      return workerFor(natives.swController());
    }
    get ready() {
      const state = containerState(this);
      checkReady(this);
      return state.ready;
    }
    register(scriptURL, options) {
      const settings = options === undefined || options === null ? {} : options;
      return request(function () {
        if (scriptURL === undefined) throw new TypeError("Failed to execute 'register' on 'ServiceWorkerContainer': " +
          "1 argument required.");
        let url;
        let scope = null;
        try {
          url = new URL(String(scriptURL), baseUrl()).href;
          if (settings.scope !== undefined) scope = new URL(String(settings.scope), baseUrl()).href;
        } catch (error) {
          throw new TypeError("Failed to execute 'register' on 'ServiceWorkerContainer': Invalid URL.");
        }
        const updateViaCache = settings.updateViaCache === undefined ? "imports" : String(settings.updateViaCache);
        if (updateViaCacheValues.indexOf(updateViaCache) < 0)
          throw new TypeError("Failed to execute 'register' on 'ServiceWorkerContainer': The provided value '" +
            updateViaCache + "' is not a valid enum value of type ServiceWorkerUpdateViaCache.");
        const type = settings.type === undefined ? "classic" : String(settings.type);
        if (workerTypes.indexOf(type) < 0)
          throw new TypeError("Failed to execute 'register' on 'ServiceWorkerContainer': The provided value '" +
            type + "' is not a valid enum value of type WorkerType.");
        return natives.swRegister(url, scope, updateViaCache, type);
      }, registrationFor);
    }
    getRegistration(clientURL) {
      try {
        containerState(this);
        const url = clientURL === undefined ? global.location.href : new URL(String(clientURL), baseUrl()).href;
        return Promise.resolve(registrationFor(natives.swGetRegistration(url)));
      } catch (error) {
        return Promise.reject(error instanceof TypeError || error instanceof DOMException ? error :
          new TypeError("Failed to execute 'getRegistration' on 'ServiceWorkerContainer': Invalid URL."));
      }
    }
    getRegistrations() {
      try {
        containerState(this);
        return Promise.resolve(natives.swGetRegistrations().map(registrationFor));
      } catch (error) {
        return Promise.reject(error);
      }
    }
    startMessages() {
      const state = containerState(this);
      if (state.messagesEnabled) return;
      state.messagesEnabled = true;
      const container = this;
      internal.queueTask(function () {
        for (const message of state.queue.splice(0)) deliverMessage(container, message);
      });
    }
  }
  internal.defineHandler(ServiceWorkerContainer.prototype, "controllerchange");
  internal.defineHandler(ServiceWorkerContainer.prototype, "messageerror");
  internal.defineHandler(ServiceWorkerContainer.prototype, "message");
  // Setting onmessage enables the client message queue.
  const messageHandler = Object.getOwnPropertyDescriptor(ServiceWorkerContainer.prototype, "onmessage");
  Object.defineProperty(ServiceWorkerContainer.prototype, "onmessage", {
    get: messageHandler.get,
    set: function (value) {
      messageHandler.set.call(this, value);
      this.startMessages();
    },
    configurable: true,
    enumerable: true
  });
  internal.finishInterface(ServiceWorkerContainer, "ServiceWorkerContainer");

  const container = new ServiceWorkerContainer(token);
  Object.defineProperty(global.Navigator.prototype, "serviceWorker", {
    get: function () { return container; }, configurable: true, enumerable: true });

  function checkReady(target) {
    const state = containerState(target);
    if (state.resolveReady === null || !global.location) return;
    let info;
    try {
      info = natives.swGetRegistration(global.location.href);
    } catch (error) {
      return;
    }
    if (info === undefined) return;
    // The realm's object as the updates it was sent left it (the live
    // record may be ahead of them).
    const registration = registrationFor(info);
    if (registrationState(registration).active === null) return;
    const resolve = state.resolveReady;
    state.resolveReady = null;
    resolve(registration);
  }

  function deliverMessage(target, message) {
    let received;
    try {
      received = internal.receiveThroughLink(message.text, message.ids);
    } catch (error) {
      target.dispatchEvent(new MessageEvent("messageerror", { origin: message.origin, source: message.source }));
      return;
    }
    target.dispatchEvent(new MessageEvent("message", { data: received.data, origin: message.origin,
      source: message.source, ports: received.ports }));
  }

  // The client message queue opens by itself once the document is parsed
  // (looked at when a message comes, and while one waits).
  function parsed() {
    return !global.document || global.document.readyState !== "loading";
  }
  function openWhenParsed() {
    if (containerState(container).messagesEnabled) return;
    if (parsed()) container.startMessages();
    else global.setTimeout(openWhenParsed, 50);
  }

  natives.onServiceWorkerUpdate = function (kind, value, text, ids) {
    if (kind === "registration") {
      const registration = registrationObjects.get(value[0]);
      if (registration !== undefined) applyRegistration(registrationState(registration), value);
      checkReady(container);
    } else if (kind === "state") {
      const worker = workerObjects.get(value[0]);
      if (worker === undefined) return;
      const state = workerState(worker);
      if (state.state === value[2]) return;
      state.state = value[2];
      worker.dispatchEvent(new Event("statechange"));
    } else if (kind === "updatefound") {
      const registration = registrationObjects.get(value);
      if (registration !== undefined) registration.dispatchEvent(new Event("updatefound"));
    } else if (kind === "controller") {
      container.dispatchEvent(new Event("controllerchange"));
    } else if (kind === "message") {
      const message = { text: text, ids: ids, source: workerFor(value), origin: new URL(value[1]).origin };
      const state = containerState(container);
      if (state.messagesEnabled) deliverMessage(container, message);
      else {
        // Queued in order; flushed in a task once the queue opens.
        state.queue.push(message);
        openWhenParsed();
      }
    }
  };
})
