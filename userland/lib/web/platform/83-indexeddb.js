// IndexedDB (Indexed Database API 3.0): the factory (window.indexedDB),
// connections (IDBDatabase), transactions with their lifetime, requests
// and their events. Object stores, indexes and cursors are in
// 84-indexeddb-stores.js; the data lives in the storage service
// (82-indexeddb-backend.js), in the browser process when there is one.
//
// How requests run: a transaction asks the service to start once no
// earlier transaction of this window with an overlapping scope (either
// readwrite) is unfinished; the service also keeps transactions of other
// windows and processes apart and says "wait" (asked again 10 ms later).
// A started transaction executes each request at once and in order, and
// queues a task per request that fires its success or error event; while
// the event is dispatched the transaction is active, and it stays active
// through the microtasks that follow (promise wrappers keep working), until
// the end of that microtask checkpoint (natives.requestCheckpointCleanup).
// An inactive transaction whose requests are all delivered commits.
// Aborting reverts the service's changes; requests not delivered yet get
// AbortError error events, then the transaction an abort event.
(function (natives, global, internal) {
  "use strict";
  const backend = internal.idbBackend;
  if (backend === undefined) return;
  const keys = internal.idbKeys;
  const token = internal.token;
  const Op = backend.Op;
  const Outcome = backend.Outcome;
  const RequestWriter = backend.RequestWriter;
  const MaximumVersion = 9007199254740991;

  function domError(message, name) {
    return new DOMException(message, name);
  }
  function inactiveError(what) {
    return domError("Failed to execute '" + what + "': The transaction is not active.", "TransactionInactiveError");
  }

  // ---- DOMStringList ----

  const stringLists = new WeakMap();
  class DOMStringList {
    constructor(key) {
      if (key !== token) internal.illegal();
    }
    get length() { return stringLists.get(this).length; }
    item(index) {
      const list = stringLists.get(this);
      const position = Number(index) >>> 0;
      return position < list.length ? list[position] : null;
    }
    contains(text) {
      return stringLists.get(this).indexOf(String(text)) >= 0;
    }
    [Symbol.iterator]() {
      return stringLists.get(this).slice()[Symbol.iterator]();
    }
  }
  internal.finishInterface(DOMStringList, "DOMStringList");
  function makeStringList(names) {
    const list = new DOMStringList(token);
    const sorted = names.slice().sort(keys.compareStrings);
    stringLists.set(list, sorted);
    for (let index = 0; index < sorted.length; index++)
      Object.defineProperty(list, index, { value: sorted[index], enumerable: true, configurable: true });
    return list;
  }
  // Names sort by code unit, as strings compare.
  keys.compareStrings = function (a, b) { return a < b ? -1 : (a > b ? 1 : 0); };

  // ---- events ----

  const versionData = new WeakMap();
  class IDBVersionChangeEvent extends Event {
    constructor(type, eventInitDict) {
      if (arguments.length < 1) throw new TypeError("Failed to construct 'IDBVersionChangeEvent': 1 argument " +
        "required, but only 0 present.");
      super(type, eventInitDict);
      const init = eventInitDict == null ? {} : eventInitDict;
      versionData.set(this, { oldVersion: init.oldVersion === undefined ? 0 : Number(init.oldVersion),
        newVersion: init.newVersion === undefined || init.newVersion === null ? null : Number(init.newVersion) });
    }
    get oldVersion() { return versionData.get(this).oldVersion; }
    get newVersion() { return versionData.get(this).newVersion; }
  }
  internal.finishInterface(IDBVersionChangeEvent, "IDBVersionChangeEvent");

  // Dispatches an event; whether a listener threw, and whether it was
  // canceled.
  function fire(target, event) {
    const before = natives.reportedErrors();
    const notCanceled = internal.fire(target, event);
    return { threw: natives.reportedErrors() !== before, canceled: !notCanceled };
  }

  // ---- requests ----

  const requestData = new WeakMap();
  function requestState(object) {
    const state = requestData.get(object);
    if (state === undefined) throw new TypeError("Illegal invocation");
    return state;
  }

  class IDBRequest extends EventTarget {
    constructor(key) {
      if (key !== token) internal.illegal();
      super();
      requestData.set(this, { source: null, transaction: null, readyState: "pending", result: undefined,
        error: null, done: false });
    }
    get result() {
      const state = requestState(this);
      if (state.readyState !== "done") throw domError("Failed to read the 'result' property from 'IDBRequest': " +
        "The request has not finished.", "InvalidStateError");
      return state.result;
    }
    get error() {
      const state = requestState(this);
      if (state.readyState !== "done") throw domError("Failed to read the 'error' property from 'IDBRequest': " +
        "The request has not finished.", "InvalidStateError");
      return state.error;
    }
    get source() { return requestState(this).source; }
    get transaction() { return requestState(this).transaction; }
    get readyState() { return requestState(this).readyState; }
  }
  internal.defineHandler(IDBRequest.prototype, "success");
  internal.defineHandler(IDBRequest.prototype, "error");
  internal.finishInterface(IDBRequest, "IDBRequest");

  class IDBOpenDBRequest extends IDBRequest {
    constructor(key) {
      super(key);
    }
  }
  internal.defineHandler(IDBOpenDBRequest.prototype, "blocked");
  internal.defineHandler(IDBOpenDBRequest.prototype, "upgradeneeded");
  internal.finishInterface(IDBOpenDBRequest, "IDBOpenDBRequest");

  // ---- the cleanup of transactions at the end of a checkpoint ----

  const activeAfterTask = [];
  let cleanupTimer = 0;
  function cleanupTransactions() {
    if (cleanupTimer !== 0) {
      global.clearTimeout(cleanupTimer);
      cleanupTimer = 0;
    }
    const list = activeAfterTask.splice(0);
    for (const transaction of list) {
      const state = transactionData.get(transaction);
      if (state.state === "active") state.state = "inactive";
    }
    for (const transaction of list) maybeCommit(transaction);
  }
  natives.onCheckpointCleanup = cleanupTransactions;
  function deactivateLater(transaction) {
    if (activeAfterTask.indexOf(transaction) < 0) activeAfterTask.push(transaction);
    natives.requestCheckpointCleanup();
    // Where no checkpoint follows, the next task does it.
    if (cleanupTimer === 0) cleanupTimer = global.setTimeout(function () {
      cleanupTimer = 0;
      cleanupTransactions();
    }, 0);
  }

  // ---- transactions ----

  const transactionData = new WeakMap();
  function transactionState(object) {
    const state = transactionData.get(object);
    if (state === undefined) throw new TypeError("Illegal invocation");
    return state;
  }
  // This window's unfinished transactions, in the order they were made.
  const unfinished = [];

  class IDBTransaction extends EventTarget {
    constructor(key) {
      if (key !== token) internal.illegal();
      super();
    }
    get objectStoreNames() {
      const state = transactionState(this);
      if (state.mode === "versionchange")
        return makeStringList(databaseState(state.db).stores.map(function (store) { return store.name; }));
      return makeStringList(state.scope.map(function (store) { return store.name; }));
    }
    get mode() { return transactionState(this).mode; }
    get durability() { return transactionState(this).durability; }
    get db() { return transactionState(this).db; }
    get error() { return transactionState(this).error; }
    objectStore(name) {
      if (arguments.length < 1) throw new TypeError("Failed to execute 'objectStore' on 'IDBTransaction': 1 " +
        "argument required, but only 0 present.");
      const state = transactionState(this);
      if (state.state === "finished") throw domError("Failed to execute 'objectStore' on 'IDBTransaction': The " +
        "transaction has finished.", "InvalidStateError");
      const text = String(name);
      const stores = state.mode === "versionchange" ? databaseState(state.db).stores : state.scope;
      let meta = null;
      for (const store of stores) if (store.name === text && !store.deleted) meta = store;
      if (meta === null) throw domError("Failed to execute 'objectStore' on 'IDBTransaction': The specified object " +
        "store was not found.", "NotFoundError");
      let object = state.storeObjects.get(meta);
      if (object === undefined) {
        object = internal.idbMakeObjectStore(this, meta);
        state.storeObjects.set(meta, object);
      }
      return object;
    }
    commit() {
      const state = transactionState(this);
      if (state.state !== "active") throw domError("Failed to execute 'commit' on 'IDBTransaction': The " +
        "transaction is not active.", "InvalidStateError");
      startCommit(this);
    }
    abort() {
      const state = transactionState(this);
      if (state.state === "committing" || state.state === "finished") throw domError("Failed to execute 'abort' " +
        "on 'IDBTransaction': The transaction has already been committed or aborted.", "InvalidStateError");
      abortTransaction(this, null);
    }
  }
  internal.defineHandler(IDBTransaction.prototype, "abort");
  internal.defineHandler(IDBTransaction.prototype, "complete");
  internal.defineHandler(IDBTransaction.prototype, "error");
  internal.finishInterface(IDBTransaction, "IDBTransaction");

  function newTransaction(db, mode, scope, durability) {
    const transaction = new IDBTransaction(token);
    transactionData.set(transaction, {
      db: db, mode: mode, scope: scope, durability: durability, state: "active", started: false, backendId: 0,
      waiting: [], requests: [], error: null, storeObjects: new Map(), snapshot: null, openRequest: null,
      retryTimer: 0
    });
    natives.setEventParent(transaction, db);
    unfinished.push(transaction);
    databaseState(db).transactions.push(transaction);
    deactivateLater(transaction);
    return transaction;
  }

  function overlaps(a, b) {
    if (a.db !== b.db && databaseState(a.db).name !== databaseState(b.db).name) return false;
    if (a.mode === "versionchange" || b.mode === "versionchange") return true;
    if (a.mode === "readonly" && b.mode === "readonly") return false;
    for (const store of a.scope) for (const other of b.scope) if (store.name === other.name) return true;
    return false;
  }

  // Starts every transaction that may start now (2.7.2).
  function startTransactions() {
    for (const transaction of unfinished.slice()) {
      const state = transactionData.get(transaction);
      if (state.started || state.state === "finished" || state.retryTimer !== 0) continue;
      const position = unfinished.indexOf(transaction);
      let blocked = false;
      for (let earlier = 0; earlier < position && !blocked; earlier++)
        if (overlaps(transactionData.get(unfinished[earlier]), state)) blocked = true;
      if (!blocked) startTransaction(transaction);
    }
  }

  function startTransaction(transaction) {
    const state = transactionData.get(transaction);
    const writer = new RequestWriter(Op.Begin);
    writer.u32(databaseState(state.db).connection);
    writer.byte(state.mode === "readwrite" ? 1 : 0);
    writer.u32(state.scope.length);
    for (const store of state.scope) writer.u32(store.id);
    let reader;
    try {
      reader = backend.call(writer);
    } catch (error) {
      abortTransaction(transaction, error);
      return;
    }
    if (reader.byte() === Outcome.Wait) {
      state.retryTimer = global.setTimeout(function () {
        state.retryTimer = 0;
        startTransactions();
      }, 10);
      return;
    }
    state.backendId = reader.u32();
    beginExecuting(transaction);
  }

  function beginExecuting(transaction) {
    const state = transactionData.get(transaction);
    state.started = true;
    const waiting = state.waiting.splice(0);
    for (const request of waiting) execute(transaction, request);
    maybeCommit(transaction);
  }

  // Places a request (2.7.1 "asynchronously execute a request"): its
  // operation runs as soon as the transaction has started.
  function placeRequest(transaction, source, operation, request) {
    const state = transactionData.get(transaction);
    if (request === undefined) {
      request = new IDBRequest(token);
      natives.setEventParent(request, transaction);
    }
    const requestState_ = requestData.get(request);
    requestState_.source = source;
    requestState_.transaction = transaction;
    requestState_.readyState = "pending";
    requestState_.done = false;
    requestState_.operation = operation;
    state.requests.push(request);
    if (state.started) execute(transaction, request);
    else state.waiting.push(request);
    return request;
  }

  function execute(transaction, request) {
    const state = transactionData.get(transaction);
    const requestState_ = requestData.get(request);
    let outcome;
    try {
      outcome = { result: requestState_.operation(state.backendId) };
    } catch (error) {
      outcome = { error: error };
    }
    backend.queueTask(function () { deliver(transaction, request, outcome); });
  }

  function deliver(transaction, request, outcome) {
    const state = transactionData.get(transaction);
    const requestState_ = requestData.get(request);
    if (requestState_.done || state.state === "finished") return;
    requestState_.done = true;
    requestState_.readyState = "done";
    const position = state.requests.indexOf(request);
    if (position >= 0) state.requests.splice(position, 1);
    if (requestState_.onDone !== undefined) requestState_.onDone(outcome);
    const wasInactive = state.state === "inactive";
    if (wasInactive) state.state = "active";
    if (!("error" in outcome)) {
      requestState_.result = outcome.result;
      requestState_.error = null;
      const fired = fire(request, new Event("success"));
      if (fired.threw && state.state !== "finished") abortTransaction(transaction, domError("A request's success " +
        "handler threw an exception.", "AbortError"));
    } else {
      requestState_.result = undefined;
      requestState_.error = asDomException(outcome.error);
      const fired = fire(request, new Event("error", { bubbles: true, cancelable: true }));
      if (state.state !== "finished") {
        if (fired.threw) abortTransaction(transaction, domError("A request's error handler threw an exception.",
          "AbortError"));
        else if (!fired.canceled) abortTransaction(transaction, requestState_.error);
      }
    }
    if (state.state === "active" && wasInactive) deactivateLater(transaction);
    else maybeCommit(transaction);
  }

  function asDomException(error) {
    if (error instanceof DOMException) return error;
    return domError(String(error && error.message !== undefined ? error.message : error), "UnknownError");
  }

  // An inactive transaction with nothing left to deliver commits.
  function maybeCommit(transaction) {
    const state = transactionData.get(transaction);
    if (state.state !== "inactive" || state.requests.length > 0) return;
    if (!state.started) return;
    startCommit(transaction);
  }

  function startCommit(transaction) {
    const state = transactionData.get(transaction);
    state.state = "committing";
    if (!state.started) return;
    // After the events already queued.
    backend.queueTask(function () { finishCommit(transaction); });
  }

  function finishCommit(transaction) {
    const state = transactionData.get(transaction);
    if (state.state !== "committing") return;
    if (state.requests.length > 0) {
      backend.queueTask(function () { finishCommit(transaction); });
      return;
    }
    const writer = new RequestWriter(Op.Commit);
    writer.u32(state.backendId);
    try {
      backend.call(writer);
    } catch (error) {
      state.backendId = 0;
      abortTransaction(transaction, error);
      return;
    }
    state.state = "finished";
    forget(transaction);
    fire(transaction, new Event("complete"));
    if (state.mode === "versionchange") upgradeFinished(transaction, true);
    afterTransaction(transaction);
  }

  function forget(transaction) {
    const state = transactionData.get(transaction);
    let position = unfinished.indexOf(transaction);
    if (position >= 0) unfinished.splice(position, 1);
    const list = databaseState(state.db).transactions;
    position = list.indexOf(transaction);
    if (position >= 0) list.splice(position, 1);
    if (state.retryTimer !== 0) {
      global.clearTimeout(state.retryTimer);
      state.retryTimer = 0;
    }
  }

  function afterTransaction(transaction) {
    const state = transactionData.get(transaction);
    const dbState = databaseState(state.db);
    if (dbState.closePending && dbState.transactions.length === 0) finishClose(state.db);
    startTransactions();
  }

  // "abort a transaction" (5.5.4).
  function abortTransaction(transaction, error) {
    const state = transactionData.get(transaction);
    if (state.state === "finished") return;
    if (state.started && state.backendId !== 0) {
      const writer = new RequestWriter(Op.Abort);
      writer.u32(state.backendId);
      try {
        backend.call(writer);
      } catch (ignored) {
        // The service has forgotten it already.
      }
    }
    if (state.mode === "versionchange") revertSchema(transaction);
    state.state = "finished";
    state.error = error;
    forget(transaction);
    state.waiting.length = 0;
    const pending = state.requests.splice(0);
    for (const request of pending) {
      const requestState_ = requestData.get(request);
      if (requestState_.done) continue;
      requestState_.done = true;
      backend.queueTask(function () {
        requestState_.readyState = "done";
        requestState_.result = undefined;
        requestState_.error = domError("The transaction was aborted.", "AbortError");
        if (requestState_.onDone !== undefined) requestState_.onDone({ error: requestState_.error });
        fire(request, new Event("error", { bubbles: true, cancelable: true }));
      });
    }
    backend.queueTask(function () {
      fire(transaction, new Event("abort", { bubbles: true }));
      if (state.mode === "versionchange") upgradeFinished(transaction, false);
      afterTransaction(transaction);
    });
  }

  function revertSchema(transaction) {
    const state = transactionData.get(transaction);
    const dbState = databaseState(state.db);
    const snapshot = state.snapshot;
    if (snapshot === null) return;
    for (const store of dbState.stores) if (snapshot.stores.indexOf(store) < 0) {
      store.deleted = true;
      for (const index of store.indexes) index.deleted = true;
    }
    for (let position = 0; position < snapshot.stores.length; position++) {
      const store = snapshot.stores[position];
      const saved = snapshot.details[position];
      store.name = saved.name;
      store.deleted = false;
      for (const index of store.indexes) if (saved.indexes.indexOf(index) < 0) index.deleted = true;
      store.indexes = saved.indexes.slice();
      for (let item = 0; item < store.indexes.length; item++) {
        store.indexes[item].name = saved.indexNames[item];
        store.indexes[item].deleted = false;
      }
    }
    dbState.stores = snapshot.stores.slice();
    dbState.version = snapshot.oldVersion;
  }

  // ---- connections ----

  const databaseData = new WeakMap();
  function databaseState(object) {
    const state = databaseData.get(object);
    if (state === undefined) throw new TypeError("Illegal invocation");
    return state;
  }
  const connections = new Map();

  function schemaToStores(schema) {
    return schema.map(function (store) {
      return { id: store.id, name: store.name, keyPath: store.keyPath, autoIncrement: store.autoIncrement,
        deleted: false, indexes: store.indexes.map(function (index) {
          return { id: index.id, name: index.name, keyPath: index.keyPath, unique: index.unique,
            multiEntry: index.multiEntry, deleted: false };
        }) };
    });
  }

  class IDBDatabase extends EventTarget {
    constructor(key) {
      if (key !== token) internal.illegal();
      super();
    }
    get name() { return databaseState(this).name; }
    get version() { return databaseState(this).version; }
    get objectStoreNames() {
      return makeStringList(databaseState(this).stores.map(function (store) { return store.name; }));
    }
    transaction(storeNames, mode, options) {
      if (arguments.length < 1) throw new TypeError("Failed to execute 'transaction' on 'IDBDatabase': 1 argument " +
        "required, but only 0 present.");
      const state = databaseState(this);
      const modeText = mode === undefined ? "readonly" : String(mode);
      if (modeText !== "readonly" && modeText !== "readwrite")
        throw new TypeError("Failed to execute 'transaction' on 'IDBDatabase': The provided value '" + modeText +
          "' is not a valid enum value of type IDBTransactionMode.");
      let durability = "default";
      if (options != null && options.durability !== undefined) {
        durability = String(options.durability);
        if (["default", "strict", "relaxed"].indexOf(durability) < 0)
          throw new TypeError("Failed to execute 'transaction' on 'IDBDatabase': The provided value '" + durability +
            "' is not a valid enum value of type IDBTransactionDurability.");
      }
      if (state.closePending) throw domError("Failed to execute 'transaction' on 'IDBDatabase': The database " +
        "connection is closing.", "InvalidStateError");
      if (state.upgrade !== null && transactionData.get(state.upgrade).state !== "finished")
        throw domError("Failed to execute 'transaction' on 'IDBDatabase': A version change transaction is running.",
          "InvalidStateError");
      let names;
      if (typeof storeNames === "string" || storeNames instanceof String) names = [String(storeNames)];
      else if (storeNames !== null && typeof storeNames === "object" && typeof storeNames[Symbol.iterator] === "function")
        names = Array.from(storeNames, String);
      else names = [String(storeNames)];
      const scope = [];
      for (const name of names) {
        let found = null;
        for (const store of state.stores) if (store.name === name) found = store;
        if (found === null) throw domError("Failed to execute 'transaction' on 'IDBDatabase': One of the specified " +
          "object stores was not found.", "NotFoundError");
        if (scope.indexOf(found) < 0) scope.push(found);
      }
      if (scope.length === 0) throw domError("Failed to execute 'transaction' on 'IDBDatabase': The transaction " +
        "scope is empty.", "InvalidAccessError");
      scope.sort(function (a, b) { return keys.compareStrings(a.name, b.name); });
      const transaction = newTransaction(this, modeText, scope, durability);
      startTransactions();
      return transaction;
    }
    close() {
      closeConnection(this, false);
    }
    createObjectStore(name, options) {
      return internal.idbCreateObjectStore(this, name, options);
    }
    deleteObjectStore(name) {
      internal.idbDeleteObjectStore(this, name);
    }
  }
  internal.defineHandler(IDBDatabase.prototype, "abort");
  internal.defineHandler(IDBDatabase.prototype, "close");
  internal.defineHandler(IDBDatabase.prototype, "error");
  internal.defineHandler(IDBDatabase.prototype, "versionchange");
  internal.finishInterface(IDBDatabase, "IDBDatabase");

  function newConnection(name, connection, version, schema) {
    const db = new IDBDatabase(token);
    databaseData.set(db, { name: name, connection: connection, version: version, stores: schemaToStores(schema),
      closePending: false, closed: false, transactions: [], upgrade: null });
    connections.set(connection, db);
    return db;
  }

  // "close a database connection" (forced: the service closed it).
  function closeConnection(db, forced) {
    const state = databaseState(db);
    if (state.closePending) return;
    state.closePending = true;
    if (forced) {
      for (const transaction of state.transactions.slice())
        abortTransaction(transaction, domError("The database connection was closed.", "AbortError"));
    }
    if (state.transactions.length === 0) finishClose(db);
    if (forced) backend.queueTask(function () { fire(db, new Event("close")); });
  }

  function finishClose(db) {
    const state = databaseState(db);
    if (state.closed) return;
    state.closed = true;
    connections.delete(state.connection);
    const writer = new RequestWriter(Op.Close);
    writer.u32(state.connection);
    try {
      backend.call(writer);
    } catch (ignored) {
      // Already closed by the service.
    }
  }

  backend.onNotice(1, function (reader) {
    const connection = reader.u32();
    const oldVersion = reader.f64();
    const newVersion = reader.f64();
    const db = connections.get(connection);
    if (db === undefined || databaseState(db).closePending) return;
    fire(db, new IDBVersionChangeEvent("versionchange", { oldVersion: oldVersion,
      newVersion: newVersion < 0 ? null : newVersion }));
  });
  backend.onNotice(2, function (reader) {
    const db = connections.get(reader.u32());
    if (db !== undefined) closeConnection(db, true);
  });

  // ---- opening and deleting (4.1, 4.2) ----

  let nextToken = 1;
  // Requests waiting for other connections: asked again when the
  // service's blocked notice comes (after the others' versionchange
  // events), and every 10 ms until they are closed.
  const waiting = new Map();
  backend.onNotice(3, function (reader) {
    const retry = waiting.get(reader.u32());
    if (retry !== undefined) retry();
  });
  function waitAgain(requestToken, round, attempt) {
    const state = { done: false, timer: 0 };
    const again = function () {
      if (state.done) return;
      state.done = true;
      waiting.delete(requestToken);
      if (state.timer !== 0) global.clearTimeout(state.timer);
      attempt(round + 1);
    };
    waiting.set(requestToken, again);
    state.timer = global.setTimeout(again, 10);
  }

  function finishRequest(request, result, error) {
    const state = requestData.get(request);
    state.readyState = "done";
    state.result = result;
    state.error = error;
  }

  function attemptOpen(request, name, version, requestToken, round) {
    const state = requestData.get(request);
    const writer = new RequestWriter(Op.Open);
    writer.byte(0);
    writer.name(name);
    writer.f64(version === undefined ? 0 : version);
    writer.u32(requestToken);
    let reader;
    try {
      reader = backend.call(writer);
    } catch (error) {
      finishRequest(request, undefined, error);
      fire(request, new Event("error", { bubbles: true, cancelable: true }));
      return;
    }
    const outcome = reader.byte();
    if (outcome === Outcome.Wait) {
      const others = reader.u32();
      const current = reader.f64();
      if (others > 0 && round > 0 && !state.blockedFired) {
        state.blockedFired = true;
        fire(request, new IDBVersionChangeEvent("blocked", { oldVersion: current,
          newVersion: version === undefined ? current : version }));
      }
      waitAgain(requestToken, round, function (next) { attemptOpen(request, name, version, requestToken, next); });
      return;
    }
    const connection = reader.u32();
    if (outcome === Outcome.Done) {
      const openedVersion = reader.f64();
      const db = newConnection(name, connection, openedVersion, backend.readSchema(reader));
      finishRequest(request, db, null);
      fire(request, new Event("success"));
      return;
    }
    const transactionId = reader.u32();
    const oldVersion = reader.f64();
    const newVersion = reader.f64();
    const db = newConnection(name, connection, newVersion, backend.readSchema(reader));
    const dbState = databaseState(db);
    const transaction = newTransaction(db, "versionchange", [], "default");
    const transactionState_ = transactionData.get(transaction);
    dbState.upgrade = transaction;
    transactionState_.backendId = transactionId;
    transactionState_.started = true;
    transactionState_.openRequest = request;
    transactionState_.snapshot = { oldVersion: oldVersion, stores: dbState.stores.slice(),
      details: dbState.stores.map(function (store) {
        return { name: store.name, indexes: store.indexes.slice(),
          indexNames: store.indexes.map(function (index) { return index.name; }) };
      }) };
    finishRequest(request, db, null);
    state.transaction = transaction;
    const fired = fire(request, new IDBVersionChangeEvent("upgradeneeded", { oldVersion: oldVersion,
      newVersion: newVersion }));
    if (fired.threw && transactionState_.state !== "finished")
      abortTransaction(transaction, domError("The upgradeneeded handler threw an exception.", "AbortError"));
    else maybeCommit(transaction);
  }

  // The upgrade transaction ended: the open request succeeds or fails.
  function upgradeFinished(transaction, committed) {
    const state = transactionData.get(transaction);
    const request = state.openRequest;
    const db = state.db;
    const dbState = databaseState(db);
    dbState.upgrade = null;
    const requestState_ = requestData.get(request);
    requestState_.transaction = null;
    if (committed && !dbState.closePending) {
      finishRequest(request, db, null);
      fire(request, new Event("success"));
      return;
    }
    if (!dbState.closePending) {
      dbState.closePending = true;
      finishClose(db);
    }
    finishRequest(request, undefined, domError(committed ? "The connection was closed before the upgrade " +
      "finished." : "The version change transaction was aborted.", "AbortError"));
    fire(request, new Event("error", { bubbles: true, cancelable: true }));
  }

  function attemptDelete(request, name, requestToken, round) {
    const state = requestData.get(request);
    const writer = new RequestWriter(Op.DeleteDatabase);
    writer.byte(0);
    writer.name(name);
    writer.u32(requestToken);
    let reader;
    try {
      reader = backend.call(writer);
    } catch (error) {
      finishRequest(request, undefined, error);
      fire(request, new Event("error", { bubbles: true, cancelable: true }));
      return;
    }
    const outcome = reader.byte();
    if (outcome === Outcome.Wait) {
      const others = reader.u32();
      const current = reader.f64();
      if (others > 0 && round > 0 && !state.blockedFired) {
        state.blockedFired = true;
        fire(request, new IDBVersionChangeEvent("blocked", { oldVersion: current, newVersion: null }));
      }
      waitAgain(requestToken, round, function (next) { attemptDelete(request, name, requestToken, next); });
      return;
    }
    const oldVersion = reader.f64();
    finishRequest(request, undefined, null);
    fire(request, new IDBVersionChangeEvent("success", { oldVersion: oldVersion, newVersion: null }));
  }

  function checkAccess(what) {
    if (!backend.allowed()) throw domError("Failed to execute '" + what + "' on 'IDBFactory': Access to the " +
      "Indexed Database API is denied in this context.", "SecurityError");
  }

  // [EnforceRange] unsigned long long.
  function enforceVersion(value) {
    const number = Number(value);
    if (!isFinite(number)) throw new TypeError("Failed to execute 'open' on 'IDBFactory': Value is not of type " +
      "'unsigned long long'.");
    const integer = Math.trunc(number);
    if (integer < 0 || integer > MaximumVersion) throw new TypeError("Failed to execute 'open' on 'IDBFactory': " +
      "Value is outside the 'unsigned long long' value range.");
    return integer;
  }

  class IDBFactory {
    constructor(key) {
      if (key !== token) internal.illegal();
    }
    open(name, version) {
      if (arguments.length < 1) throw new TypeError("Failed to execute 'open' on 'IDBFactory': 1 argument " +
        "required, but only 0 present.");
      const text = String(name);
      let requested;
      if (version !== undefined) {
        requested = enforceVersion(version);
        if (requested === 0) throw new TypeError("Failed to execute 'open' on 'IDBFactory': The version provided " +
          "must not be 0.");
      }
      checkAccess("open");
      const request = new IDBOpenDBRequest(token);
      const requestToken = nextToken++;
      backend.queueTask(function () { attemptOpen(request, text, requested, requestToken, 0); });
      return request;
    }
    deleteDatabase(name) {
      if (arguments.length < 1) throw new TypeError("Failed to execute 'deleteDatabase' on 'IDBFactory': 1 " +
        "argument required, but only 0 present.");
      const text = String(name);
      checkAccess("deleteDatabase");
      const request = new IDBOpenDBRequest(token);
      const requestToken = nextToken++;
      backend.queueTask(function () { attemptDelete(request, text, requestToken, 0); });
      return request;
    }
    databases() {
      try {
        checkAccess("databases");
      } catch (error) {
        return Promise.reject(error);
      }
      return new Promise(function (resolve, reject) {
        backend.queueTask(function () {
          try {
            const reader = backend.call(new RequestWriter(Op.Databases));
            const count = reader.u32();
            const list = [];
            for (let index = 0; index < count; index++) list.push({ name: reader.name(), version: reader.f64() });
            resolve(list);
          } catch (error) {
            reject(error);
          }
        });
      });
    }
    cmp(first, second) {
      if (arguments.length < 2) throw new TypeError("Failed to execute 'cmp' on 'IDBFactory': 2 arguments required, " +
        "but only " + arguments.length + " present.");
      const a = keys.encode(first);
      const b = keys.encode(second);
      if (a === null || b === null) throw keys.dataError("Failed to execute 'cmp' on 'IDBFactory': The parameter " +
        "is not a valid key.");
      return keys.compare(a, b);
    }
  }
  internal.finishInterface(IDBFactory, "IDBFactory");

  let factory = null;
  internal.defineGetter(global, "indexedDB", function () {
    if (factory === null) factory = new IDBFactory(token);
    return factory;
  });

  internal.idb = {
    domError: domError,
    inactiveError: inactiveError,
    makeStringList: makeStringList,
    transactionState: transactionState,
    databaseState: databaseState,
    requestState: requestState,
    placeRequest: placeRequest,
    abortTransaction: abortTransaction,
    IDBRequest: IDBRequest,
    IDBTransaction: IDBTransaction,
    newRequest: function (transaction) {
      const request = new IDBRequest(token);
      natives.setEventParent(request, transaction);
      return request;
    },
    // A transaction's state, for checks: active only while it may take
    // requests.
    isActive: function (transaction) { return transactionData.get(transaction).state === "active"; },
    // While a value is cloned the transaction is inactive (getters
    // cannot make requests).
    withInactive: function (transaction, callback) {
      const state = transactionData.get(transaction);
      const saved = state.state;
      state.state = "inactive";
      try {
        return callback();
      } finally {
        if (state.state === "inactive") state.state = saved;
      }
    }
  };
})
