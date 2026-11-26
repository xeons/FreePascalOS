// IndexedDB's object stores, indexes and cursors (Indexed Database API
// 3.0, 4.5-4.8): the checks each method makes before a request is placed,
// in the standard's order, and the request's operation, which the
// transaction runs once it has started (83-indexeddb.js). Values are
// cloned when they are stored (80-structured-serialize.js), keys and
// index keys computed here from the clone (81-indexeddb-keys.js); the
// service keeps the records and indexes and answers range queries.
(function (natives, global, internal) {
  "use strict";
  const idb = internal.idb;
  if (idb === undefined) return;
  const backend = internal.idbBackend;
  const keys = internal.idbKeys;
  const token = internal.token;
  const Op = backend.Op;
  const RequestWriter = backend.RequestWriter;
  const domError = idb.domError;
  const directions = ["next", "nextunique", "prev", "prevunique"];
  const MaximumCount = 4294967295;

  function serialize(value) {
    return internal.structuredSerialize(value);
  }
  function deserialize(bytes) {
    return internal.structuredDeserialize(bytes);
  }

  // [EnforceRange] unsigned long (undefined: Fallback).
  function enforceCount(value, what, fallback) {
    if (value === undefined) return fallback;
    const number = Number(value);
    if (!isFinite(number)) throw new TypeError("Failed to execute '" + what + "': Value is not of type 'unsigned " +
      "long'.");
    const integer = Math.trunc(number);
    if (integer < 0 || integer > MaximumCount) throw new TypeError("Failed to execute '" + what + "': Value is " +
      "outside the 'unsigned long' value range.");
    return integer;
  }

  function directionOf(value, what) {
    const text = value === undefined ? "next" : String(value);
    const code = directions.indexOf(text);
    if (code < 0) throw new TypeError("Failed to execute '" + what + "': The provided value '" + text + "' is not " +
      "a valid enum value of type IDBCursorDirection.");
    return code;
  }

  function liveIndexes(storeMeta) {
    return storeMeta.indexes.filter(function (index) { return !index.deleted; });
  }

  function keyPathValue(path) {
    return Array.isArray(path) ? path.slice() : path;
  }

  // ---- shared checks ----

  function checkActive(transaction, what) {
    if (!idb.isActive(transaction)) throw idb.inactiveError(what);
  }
  function checkWritable(transaction, what) {
    if (idb.transactionState(transaction).mode === "readonly") throw domError("Failed to execute '" + what +
      "': The transaction is read-only.", "ReadOnlyError");
  }
  function checkUpgrade(transaction, what) {
    if (idb.transactionState(transaction).mode !== "versionchange") throw domError("Failed to execute '" + what +
      "': The database is not running a version change transaction.", "InvalidStateError");
  }
  function checkNotDeleted(meta, what) {
    if (meta.deleted) throw domError("Failed to execute '" + what + "': The object store or index has been " +
      "deleted.", "InvalidStateError");
  }

  // ---- operations on the service ----

  function sourceIds(storeMeta, indexMeta) {
    return [storeMeta.id, indexMeta === null ? 0 : indexMeta.id];
  }

  function retrieve(transactionId, storeMeta, indexMeta, range, withValue) {
    const writer = new RequestWriter(Op.Get);
    const ids = sourceIds(storeMeta, indexMeta);
    writer.u32(transactionId);
    writer.u32(ids[0]);
    writer.u32(ids[1]);
    writer.range(range);
    writer.byte(withValue ? 0 : 1);
    const reader = backend.call(writer);
    if (!reader.boolean()) return null;
    const result = { key: reader.key(), primaryKey: reader.key() };
    if (withValue) result.value = reader.bytesItem();
    return result;
  }

  function retrieveAll(transactionId, storeMeta, indexMeta, range, count, what) {
    const writer = new RequestWriter(Op.GetAll);
    const ids = sourceIds(storeMeta, indexMeta);
    writer.u32(transactionId);
    writer.u32(ids[0]);
    writer.u32(ids[1]);
    writer.range(range);
    writer.u32(count);
    writer.byte(what);
    const reader = backend.call(writer);
    const total = reader.u32();
    const items = [];
    for (let index = 0; index < total; index++) {
      if (what === 0) items.push(deserialize(reader.bytesItem()));
      else if (what === 1) items.push(keys.decode(reader.key()));
      else items.push({ key: reader.key(), primaryKey: reader.key(), value: reader.bytesItem() });
    }
    return items;
  }

  function countRecords(transactionId, storeMeta, indexMeta, range) {
    const writer = new RequestWriter(Op.Count);
    const ids = sourceIds(storeMeta, indexMeta);
    writer.u32(transactionId);
    writer.u32(ids[0]);
    writer.u32(ids[1]);
    writer.range(range);
    return backend.call(writer).f64();
  }

  function writeIndexKeys(writer, storeMeta, clone) {
    const indexes = liveIndexes(storeMeta);
    writer.u32(indexes.length);
    for (const index of indexes) {
      const indexKeys = keys.indexKeys(clone, index.keyPath, index.multiEntry);
      writer.u32(index.id);
      writer.u32(indexKeys.length);
      for (const key of indexKeys) writer.key(key);
    }
  }

  function putRecord(transactionId, storeMeta, key, bytes, clone, noOverwrite) {
    const writer = new RequestWriter(Op.Put);
    writer.u32(transactionId);
    writer.u32(storeMeta.id);
    writer.byte(noOverwrite ? 1 : 0);
    writer.key(key);
    writer.raw(bytes);
    writeIndexKeys(writer, storeMeta, clone);
    backend.call(writer);
  }

  function deleteRange(transactionId, storeMeta, range) {
    const writer = new RequestWriter(Op.Delete);
    writer.u32(transactionId);
    writer.u32(storeMeta.id);
    writer.range(range);
    backend.call(writer);
  }

  function generateKey(transactionId, storeMeta) {
    const writer = new RequestWriter(Op.GenerateKey);
    writer.u32(transactionId);
    writer.u32(storeMeta.id);
    return keys.encode(backend.call(writer).f64());
  }

  // "store a record into an object store" (5.1), the checks first.
  function storeValue(storeObject, value, key, noOverwrite, what) {
    const state = storeState(storeObject);
    const transaction = state.transaction;
    const meta = state.meta;
    checkNotDeleted(meta, what);
    checkActive(transaction, what);
    checkWritable(transaction, what);
    if (meta.keyPath !== null && key !== undefined) throw keys.dataError("Failed to execute '" + what + "': The " +
      "object store uses in-line keys and the key parameter was provided.");
    if (meta.keyPath === null && !meta.autoIncrement && key === undefined) throw keys.dataError("Failed to execute '" +
      what + "': The object store uses out-of-line keys and has no key generator and the key parameter was not " +
      "provided.");
    let encodedKey = null;
    if (key !== undefined) {
      encodedKey = keys.encode(key);
      if (encodedKey === null) throw keys.dataError("Failed to execute '" + what + "': The parameter is not a valid " +
        "key.");
    }
    let bytes;
    let clone;
    idb.withInactive(transaction, function () {
      bytes = serialize(value);
      clone = deserialize(bytes);
    });
    let needsKey = false;
    if (meta.keyPath !== null) {
      const extracted = keys.extractKey(clone, meta.keyPath);
      if (extracted === false) throw keys.dataError("Failed to execute '" + what + "': Evaluating the object " +
        "store's key path yielded a value that is not a valid key.");
      if (extracted !== null) encodedKey = extracted;
      else {
        if (!meta.autoIncrement) throw keys.dataError("Failed to execute '" + what + "': Evaluating the object " +
          "store's key path did not yield a value.");
        if (!keys.canInjectKey(clone, meta.keyPath)) throw keys.dataError("Failed to execute '" + what + "': A " +
          "generated key could not be inserted into the value.");
        needsKey = true;
      }
    } else if (encodedKey === null) needsKey = true;
    return idb.placeRequest(transaction, storeObject, function (transactionId) {
      let finalKey = encodedKey;
      let finalBytes = bytes;
      if (needsKey) {
        finalKey = generateKey(transactionId, meta);
        if (meta.keyPath !== null) {
          keys.injectKey(clone, meta.keyPath, finalKey);
          finalBytes = serialize(clone);
        }
      }
      putRecord(transactionId, meta, finalKey, finalBytes, clone, noOverwrite);
      return keys.decode(finalKey);
    });
  }

  // ---- IDBObjectStore ----

  const storeData = new WeakMap();
  function storeState(object) {
    const state = storeData.get(object);
    if (state === undefined) throw new TypeError("Illegal invocation");
    return state;
  }

  class IDBObjectStore {
    constructor(key) {
      if (key !== token) internal.illegal();
    }
    get name() { return storeState(this).meta.name; }
    set name(value) {
      const state = storeState(this);
      const text = String(value);
      const what = "name' on 'IDBObjectStore";
      checkUpgrade(state.transaction, what);
      checkNotDeleted(state.meta, what);
      checkActive(state.transaction, what);
      if (state.meta.name === text) return;
      const dbState = idb.databaseState(idb.transactionState(state.transaction).db);
      for (const store of dbState.stores) if (store.name === text) throw domError("Failed to set the 'name' " +
        "property on 'IDBObjectStore': An object store with the specified name already exists.", "ConstraintError");
      const writer = new RequestWriter(Op.RenameStore);
      writer.u32(idb.transactionState(state.transaction).backendId);
      writer.u32(state.meta.id);
      writer.name(text);
      backend.call(writer);
      state.meta.name = text;
    }
    get keyPath() { return keyPathValue(storeState(this).meta.keyPath); }
    get indexNames() {
      return idb.makeStringList(liveIndexes(storeState(this).meta).map(function (index) { return index.name; }));
    }
    get transaction() { return storeState(this).transaction; }
    get autoIncrement() { return storeState(this).meta.autoIncrement; }
    put(value, key) {
      if (arguments.length < 1) throw new TypeError("Failed to execute 'put' on 'IDBObjectStore': 1 argument " +
        "required, but only 0 present.");
      return storeValue(this, value, key, false, "put' on 'IDBObjectStore");
    }
    add(value, key) {
      if (arguments.length < 1) throw new TypeError("Failed to execute 'add' on 'IDBObjectStore': 1 argument " +
        "required, but only 0 present.");
      return storeValue(this, value, key, true, "add' on 'IDBObjectStore");
    }
    delete(query) {
      if (arguments.length < 1) throw new TypeError("Failed to execute 'delete' on 'IDBObjectStore': 1 argument " +
        "required, but only 0 present.");
      const state = storeState(this);
      const what = "delete' on 'IDBObjectStore";
      checkNotDeleted(state.meta, what);
      checkActive(state.transaction, what);
      checkWritable(state.transaction, what);
      const range = keys.rangeOf(query, true, what);
      const meta = state.meta;
      return idb.placeRequest(state.transaction, this, function (transactionId) {
        deleteRange(transactionId, meta, range);
        return undefined;
      });
    }
    clear() {
      const state = storeState(this);
      const what = "clear' on 'IDBObjectStore";
      checkNotDeleted(state.meta, what);
      checkActive(state.transaction, what);
      checkWritable(state.transaction, what);
      const meta = state.meta;
      return idb.placeRequest(state.transaction, this, function (transactionId) {
        const writer = new RequestWriter(Op.Clear);
        writer.u32(transactionId);
        writer.u32(meta.id);
        backend.call(writer);
        return undefined;
      });
    }
    get(query) {
      if (arguments.length < 1) throw new TypeError("Failed to execute 'get' on 'IDBObjectStore': 1 argument " +
        "required, but only 0 present.");
      return retrievalRequest(this, null, query, "get' on 'IDBObjectStore", true, "value");
    }
    getKey(query) {
      if (arguments.length < 1) throw new TypeError("Failed to execute 'getKey' on 'IDBObjectStore': 1 argument " +
        "required, but only 0 present.");
      return retrievalRequest(this, null, query, "getKey' on 'IDBObjectStore", true, "key");
    }
    getAll(query, count) {
      return retrievalRequest(this, null, query, "getAll' on 'IDBObjectStore", false, "all", count);
    }
    getAllKeys(query, count) {
      return retrievalRequest(this, null, query, "getAllKeys' on 'IDBObjectStore", false, "allKeys", count);
    }
    count(query) {
      return retrievalRequest(this, null, query, "count' on 'IDBObjectStore", false, "count");
    }
    openCursor(query, direction) {
      return openCursor(this, null, query, direction, false, "openCursor' on 'IDBObjectStore");
    }
    openKeyCursor(query, direction) {
      return openCursor(this, null, query, direction, true, "openKeyCursor' on 'IDBObjectStore");
    }
    index(name) {
      if (arguments.length < 1) throw new TypeError("Failed to execute 'index' on 'IDBObjectStore': 1 argument " +
        "required, but only 0 present.");
      const state = storeState(this);
      const what = "index' on 'IDBObjectStore";
      if (idb.transactionState(state.transaction).state === "finished") throw domError("Failed to execute '" + what +
        "': The transaction has finished.", "InvalidStateError");
      checkNotDeleted(state.meta, what);
      const text = String(name);
      let found = null;
      for (const index of liveIndexes(state.meta)) if (index.name === text) found = index;
      if (found === null) throw domError("Failed to execute '" + what + "': The specified index was not found.",
        "NotFoundError");
      let object = state.indexObjects.get(found);
      if (object === undefined) {
        object = new IDBIndex(token);
        indexData.set(object, { store: this, transaction: state.transaction, storeMeta: state.meta, meta: found });
        state.indexObjects.set(found, object);
      }
      return object;
    }
    createIndex(name, keyPath, options) {
      if (arguments.length < 2) throw new TypeError("Failed to execute 'createIndex' on 'IDBObjectStore': 2 " +
        "arguments required, but only " + arguments.length + " present.");
      return createIndex(this, String(name), keyPath, options);
    }
    deleteIndex(name) {
      if (arguments.length < 1) throw new TypeError("Failed to execute 'deleteIndex' on 'IDBObjectStore': 1 " +
        "argument required, but only 0 present.");
      deleteIndex(this, String(name));
    }
  }
  internal.finishInterface(IDBObjectStore, "IDBObjectStore");

  internal.idbMakeObjectStore = function (transaction, meta) {
    const object = new IDBObjectStore(token);
    storeData.set(object, { transaction: transaction, meta: meta, indexObjects: new Map() });
    return object;
  };

  // get, getKey, getAll, getAllKeys and count of a store or an index.
  function retrievalRequest(storeObject, indexObject, query, what, refuseNull, kind, count) {
    let transaction;
    let storeMeta;
    let indexMeta = null;
    let source;
    if (indexObject !== null) {
      const state = indexState(indexObject);
      transaction = state.transaction;
      storeMeta = state.storeMeta;
      indexMeta = state.meta;
      source = indexObject;
      checkNotDeleted(indexMeta, what);
      checkNotDeleted(storeMeta, what);
    } else {
      const state = storeState(storeObject);
      transaction = state.transaction;
      storeMeta = state.meta;
      source = storeObject;
      checkNotDeleted(storeMeta, what);
    }
    checkActive(transaction, what);
    const range = keys.rangeOf(query, refuseNull, what);
    const limit = kind === "all" || kind === "allKeys" ? enforceCount(count, what, 0) : 0;
    return idb.placeRequest(transaction, source, function (transactionId) {
      switch (kind) {
        case "value": {
          const found = retrieve(transactionId, storeMeta, indexMeta, range, true);
          return found === null ? undefined : deserialize(found.value);
        }
        case "key": {
          const found = retrieve(transactionId, storeMeta, indexMeta, range, false);
          return found === null ? undefined : keys.decode(found.primaryKey);
        }
        case "all": return retrieveAll(transactionId, storeMeta, indexMeta, range, limit, 0);
        case "allKeys": return retrieveAll(transactionId, storeMeta, indexMeta, range, limit, 1);
        default: return countRecords(transactionId, storeMeta, indexMeta, range);
      }
    });
  }

  // ---- schema changes (4.4, 4.5) ----

  function upgradeOf(db, what) {
    const dbState = idb.databaseState(db);
    const transaction = dbState.upgrade;
    if (transaction === null || idb.transactionState(transaction).state === "finished")
      throw domError("Failed to execute '" + what + "': The database is not running a version change transaction.",
        "InvalidStateError");
    checkActive(transaction, what);
    return transaction;
  }

  internal.idbCreateObjectStore = function (db, name, options) {
    const what = "createObjectStore' on 'IDBDatabase";
    if (name === undefined && arguments.length < 2) throw new TypeError("Failed to execute '" + what + "': 1 " +
      "argument required, but only 0 present.");
    const text = String(name);
    const transaction = upgradeOf(db, what);
    const dbState = idb.databaseState(db);
    let keyPath = null;
    let autoIncrement = false;
    if (options != null) {
      if (options.keyPath !== undefined && options.keyPath !== null) {
        keyPath = keys.normalizeKeyPath(options.keyPath);
        if (keyPath === null) throw domError("Failed to execute '" + what + "': The keyPath option is not a valid " +
          "key path.", "SyntaxError");
      }
      autoIncrement = !!options.autoIncrement;
    }
    for (const store of dbState.stores) if (store.name === text) throw domError("Failed to execute '" + what +
      "': An object store with the specified name already exists.", "ConstraintError");
    if (autoIncrement && (keyPath === "" || Array.isArray(keyPath))) throw domError("Failed to execute '" + what +
      "': The autoIncrement option was set but the keyPath option was empty or an array.", "InvalidAccessError");
    const writer = new RequestWriter(Op.CreateStore);
    writer.u32(idb.transactionState(transaction).backendId);
    writer.name(text);
    writer.keyPath(keyPath);
    writer.boolean(autoIncrement);
    const id = backend.call(writer).u32();
    dbState.stores.push({ id: id, name: text, keyPath: keyPath, autoIncrement: autoIncrement, deleted: false,
      indexes: [] });
    return transaction.objectStore(text);
  };

  internal.idbDeleteObjectStore = function (db, name) {
    const what = "deleteObjectStore' on 'IDBDatabase";
    const text = String(name);
    const transaction = upgradeOf(db, what);
    const dbState = idb.databaseState(db);
    let found = -1;
    for (let index = 0; index < dbState.stores.length; index++) if (dbState.stores[index].name === text) found = index;
    if (found < 0) throw domError("Failed to execute '" + what + "': The specified object store was not found.",
      "NotFoundError");
    const meta = dbState.stores[found];
    const writer = new RequestWriter(Op.DeleteStore);
    writer.u32(idb.transactionState(transaction).backendId);
    writer.u32(meta.id);
    backend.call(writer);
    meta.deleted = true;
    for (const index of meta.indexes) index.deleted = true;
    dbState.stores.splice(found, 1);
  };

  function createIndex(storeObject, name, keyPathValue_, options) {
    const what = "createIndex' on 'IDBObjectStore";
    const state = storeState(storeObject);
    const transaction = state.transaction;
    checkUpgrade(transaction, what);
    checkNotDeleted(state.meta, what);
    checkActive(transaction, what);
    for (const index of liveIndexes(state.meta)) if (index.name === name) throw domError("Failed to execute '" +
      what + "': An index with the specified name already exists.", "ConstraintError");
    const keyPath = keys.normalizeKeyPath(keyPathValue_);
    if (keyPath === null) throw domError("Failed to execute '" + what + "': The keyPath argument contains an " +
      "invalid key path.", "SyntaxError");
    const unique = options != null && !!options.unique;
    const multiEntry = options != null && !!options.multiEntry;
    if (multiEntry && Array.isArray(keyPath)) throw domError("Failed to execute '" + what + "': The keyPath " +
      "argument was an array and the multiEntry option is true.", "InvalidAccessError");
    const transactionId = idb.transactionState(transaction).backendId;
    const writer = new RequestWriter(Op.CreateIndex);
    writer.u32(transactionId);
    writer.u32(state.meta.id);
    writer.name(name);
    writer.keyPath(keyPath);
    writer.boolean(unique);
    writer.boolean(multiEntry);
    const meta = { id: backend.call(writer).u32(), name: name, keyPath: keyPath, unique: unique,
      multiEntry: multiEntry, deleted: false };
    state.meta.indexes.push(meta);
    // The entries of the records already stored.
    try {
      const records = retrieveAll(transactionId, state.meta, null, keys.rangeOf(undefined, false, what), 0, 2);
      const populate = new RequestWriter(Op.PopulateIndex);
      populate.u32(transactionId);
      populate.u32(state.meta.id);
      populate.u32(meta.id);
      populate.u32(records.length);
      for (const record of records) {
        const indexKeys = keys.indexKeys(deserialize(record.value), keyPath, multiEntry);
        populate.key(record.primaryKey);
        populate.u32(indexKeys.length);
        for (const key of indexKeys) populate.key(key);
      }
      backend.call(populate);
    } catch (error) {
      backend.queueTask(function () { idb.abortTransaction(transaction, error); });
    }
    return storeObject.index(name);
  }

  function deleteIndex(storeObject, name) {
    const what = "deleteIndex' on 'IDBObjectStore";
    const state = storeState(storeObject);
    const transaction = state.transaction;
    checkUpgrade(transaction, what);
    checkNotDeleted(state.meta, what);
    checkActive(transaction, what);
    let found = -1;
    for (let index = 0; index < state.meta.indexes.length; index++)
      if (state.meta.indexes[index].name === name && !state.meta.indexes[index].deleted) found = index;
    if (found < 0) throw domError("Failed to execute '" + what + "': The specified index was not found.",
      "NotFoundError");
    const meta = state.meta.indexes[found];
    const writer = new RequestWriter(Op.DeleteIndex);
    writer.u32(idb.transactionState(transaction).backendId);
    writer.u32(state.meta.id);
    writer.u32(meta.id);
    backend.call(writer);
    meta.deleted = true;
    state.meta.indexes.splice(found, 1);
  }

  // ---- IDBIndex ----

  const indexData = new WeakMap();
  function indexState(object) {
    const state = indexData.get(object);
    if (state === undefined) throw new TypeError("Illegal invocation");
    return state;
  }

  class IDBIndex {
    constructor(key) {
      if (key !== token) internal.illegal();
    }
    get name() { return indexState(this).meta.name; }
    set name(value) {
      const state = indexState(this);
      const text = String(value);
      const what = "name' on 'IDBIndex";
      checkUpgrade(state.transaction, what);
      checkNotDeleted(state.meta, what);
      checkNotDeleted(state.storeMeta, what);
      checkActive(state.transaction, what);
      if (state.meta.name === text) return;
      for (const index of liveIndexes(state.storeMeta)) if (index.name === text) throw domError("Failed to set the " +
        "'name' property on 'IDBIndex': An index with the specified name already exists.", "ConstraintError");
      const writer = new RequestWriter(Op.RenameIndex);
      writer.u32(idb.transactionState(state.transaction).backendId);
      writer.u32(state.storeMeta.id);
      writer.u32(state.meta.id);
      writer.name(text);
      backend.call(writer);
      state.meta.name = text;
    }
    get objectStore() { return indexState(this).store; }
    get keyPath() { return keyPathValue(indexState(this).meta.keyPath); }
    get multiEntry() { return indexState(this).meta.multiEntry; }
    get unique() { return indexState(this).meta.unique; }
    get(query) {
      if (arguments.length < 1) throw new TypeError("Failed to execute 'get' on 'IDBIndex': 1 argument required, " +
        "but only 0 present.");
      return retrievalRequest(null, this, query, "get' on 'IDBIndex", true, "value");
    }
    getKey(query) {
      if (arguments.length < 1) throw new TypeError("Failed to execute 'getKey' on 'IDBIndex': 1 argument " +
        "required, but only 0 present.");
      return retrievalRequest(null, this, query, "getKey' on 'IDBIndex", true, "key");
    }
    getAll(query, count) {
      return retrievalRequest(null, this, query, "getAll' on 'IDBIndex", false, "all", count);
    }
    getAllKeys(query, count) {
      return retrievalRequest(null, this, query, "getAllKeys' on 'IDBIndex", false, "allKeys", count);
    }
    count(query) {
      return retrievalRequest(null, this, query, "count' on 'IDBIndex", false, "count");
    }
    openCursor(query, direction) {
      return openCursor(null, this, query, direction, false, "openCursor' on 'IDBIndex");
    }
    openKeyCursor(query, direction) {
      return openCursor(null, this, query, direction, true, "openKeyCursor' on 'IDBIndex");
    }
  }
  internal.finishInterface(IDBIndex, "IDBIndex");

  // ---- cursors (2.11, 4.8) ----

  const cursorData = new WeakMap();
  function cursorState(object) {
    const state = cursorData.get(object);
    if (state === undefined) throw new TypeError("Illegal invocation");
    return state;
  }

  // One step of "iterate a cursor" on the service.
  function seek(transactionId, state, target, targetPrimary, count) {
    const writer = new RequestWriter(Op.Seek);
    const ids = sourceIds(state.storeMeta, state.indexMeta);
    writer.u32(transactionId);
    writer.u32(ids[0]);
    writer.u32(ids[1]);
    writer.range(state.range);
    writer.byte(state.direction);
    writer.boolean(state.position !== null);
    writer.key(state.position);
    writer.key(state.objectStorePosition);
    writer.boolean(target !== null);
    writer.key(target);
    writer.boolean(targetPrimary !== null);
    writer.key(targetPrimary);
    writer.u32(count);
    writer.boolean(!state.keyOnly);
    const reader = backend.call(writer);
    if (!reader.boolean()) return { found: false };
    const step = { found: true, key: reader.key(), primaryKey: reader.key() };
    if (!state.keyOnly) step.value = reader.bytesItem();
    return step;
  }

  // Places the cursor's request again (or the first time).
  function iterate(cursor, target, targetPrimary, count) {
    const state = cursorState(cursor);
    state.gotValue = false;
    idb.placeRequest(state.transaction, state.source, function (transactionId) {
      return seek(transactionId, state, target, targetPrimary, count);
    }, state.request);
  }

  function applyStep(cursor, outcome) {
    const state = cursorState(cursor);
    if ("error" in outcome) return;
    const step = outcome.result;
    if (!step.found) {
      state.position = null;
      state.objectStorePosition = null;
      state.key = undefined;
      state.primaryKey = undefined;
      state.value = undefined;
      outcome.result = null;
      return;
    }
    state.position = step.key;
    state.objectStorePosition = step.primaryKey;
    state.key = keys.decode(step.key);
    state.primaryKey = state.indexMeta === null ? state.key : keys.decode(step.primaryKey);
    state.value = state.keyOnly ? undefined : deserialize(step.value);
    state.gotValue = true;
    outcome.result = cursor;
  }

  function openCursor(storeObject, indexObject, query, direction, keyOnly, what) {
    let transaction;
    let storeMeta;
    let indexMeta = null;
    let source;
    if (indexObject !== null) {
      const state = indexState(indexObject);
      transaction = state.transaction;
      storeMeta = state.storeMeta;
      indexMeta = state.meta;
      source = indexObject;
      checkNotDeleted(indexMeta, what);
      checkNotDeleted(storeMeta, what);
    } else {
      const state = storeState(storeObject);
      transaction = state.transaction;
      storeMeta = state.meta;
      source = storeObject;
      checkNotDeleted(storeMeta, what);
    }
    checkActive(transaction, what);
    const range = keys.rangeOf(query, false, what);
    const code = directionOf(direction, what);
    const cursor = keyOnly ? new IDBCursor(token) : new IDBCursorWithValue(token);
    const request = idb.newRequest(transaction);
    cursorData.set(cursor, { transaction: transaction, source: source, storeMeta: storeMeta, indexMeta: indexMeta,
      direction: code, range: range, request: request, keyOnly: keyOnly, position: null, objectStorePosition: null,
      key: undefined, primaryKey: undefined, value: undefined, gotValue: false });
    idb.requestState(request).onDone = function (outcome) { applyStep(cursor, outcome); };
    iterate(cursor, null, null, 1);
    return request;
  }

  function checkCursor(cursor, what) {
    const state = cursorState(cursor);
    checkActive(state.transaction, what);
    if (state.storeMeta.deleted || (state.indexMeta !== null && state.indexMeta.deleted))
      throw domError("Failed to execute '" + what + "': The cursor's source or effective object store has been " +
        "deleted.", "InvalidStateError");
    if (!state.gotValue) throw domError("Failed to execute '" + what + "': The cursor is being iterated or has " +
      "iterated past its end.", "InvalidStateError");
    return state;
  }

  class IDBCursor {
    constructor(key) {
      if (key !== token) internal.illegal();
    }
    get source() { return cursorState(this).source; }
    get direction() { return directions[cursorState(this).direction]; }
    get key() { return cursorState(this).key; }
    get primaryKey() { return cursorState(this).primaryKey; }
    get request() { return cursorState(this).request; }
    advance(count) {
      const what = "advance' on 'IDBCursor";
      const steps = enforceCount(count, what, undefined);
      if (steps === undefined) throw new TypeError("Failed to execute '" + what + "': 1 argument required, but only " +
        "0 present.");
      if (steps === 0) throw new TypeError("Failed to execute '" + what + "': A count argument with value 0 (zero) " +
        "was supplied, must be greater than 0.");
      checkCursor(this, what);
      iterate(this, null, null, steps);
    }
    continue(key) {
      const what = "continue' on 'IDBCursor";
      const state = checkCursor(this, what);
      let target = null;
      if (key !== undefined) {
        target = keys.encode(key);
        if (target === null) throw keys.dataError("Failed to execute '" + what + "': The parameter is not a valid " +
          "key.");
        const forward = state.direction <= 1;
        if (forward ? target <= state.position : target >= state.position)
          throw keys.dataError("Failed to execute '" + what + "': The parameter is " + (forward ? "less" : "greater") +
            " than or equal to this cursor's position.");
      }
      iterate(this, target, null, 1);
    }
    continuePrimaryKey(key, primaryKey) {
      const what = "continuePrimaryKey' on 'IDBCursor";
      if (arguments.length < 2) throw new TypeError("Failed to execute '" + what + "': 2 arguments required, but " +
        "only " + arguments.length + " present.");
      const state = cursorState(this);
      checkActive(state.transaction, what);
      if (state.storeMeta.deleted || (state.indexMeta !== null && state.indexMeta.deleted))
        throw domError("Failed to execute '" + what + "': The cursor's source or effective object store has been " +
          "deleted.", "InvalidStateError");
      if (state.indexMeta === null) throw domError("Failed to execute '" + what + "': The cursor's source is not an " +
        "index.", "InvalidAccessError");
      if (state.direction === 1 || state.direction === 3) throw domError("Failed to execute '" + what + "': The " +
        "cursor's direction is not 'next' or 'prev'.", "InvalidAccessError");
      if (!state.gotValue) throw domError("Failed to execute '" + what + "': The cursor is being iterated or has " +
        "iterated past its end.", "InvalidStateError");
      const target = keys.encode(key);
      if (target === null) throw keys.dataError("Failed to execute '" + what + "': The key parameter is not a " +
        "valid key.");
      const targetPrimary = keys.encode(primaryKey);
      if (targetPrimary === null) throw keys.dataError("Failed to execute '" + what + "': The primaryKey parameter " +
        "is not a valid key.");
      if (state.direction === 0 && (target < state.position || (target === state.position &&
        targetPrimary <= state.objectStorePosition)))
        throw keys.dataError("Failed to execute '" + what + "': The parameters are less than or equal to this " +
          "cursor's position.");
      if (state.direction === 2 && (target > state.position || (target === state.position &&
        targetPrimary >= state.objectStorePosition)))
        throw keys.dataError("Failed to execute '" + what + "': The parameters are greater than or equal to this " +
          "cursor's position.");
      iterate(this, target, targetPrimary, 1);
    }
    update(value) {
      const what = "update' on 'IDBCursor";
      if (arguments.length < 1) throw new TypeError("Failed to execute '" + what + "': 1 argument required, but " +
        "only 0 present.");
      const state = cursorState(this);
      checkActive(state.transaction, what);
      checkWritable(state.transaction, what);
      if (state.storeMeta.deleted || (state.indexMeta !== null && state.indexMeta.deleted))
        throw domError("Failed to execute '" + what + "': The cursor's source or effective object store has been " +
          "deleted.", "InvalidStateError");
      if (!state.gotValue) throw domError("Failed to execute '" + what + "': The cursor is being iterated or has " +
        "iterated past its end.", "InvalidStateError");
      if (state.keyOnly) throw domError("Failed to execute '" + what + "': The cursor is a key cursor.",
        "InvalidStateError");
      let bytes;
      let clone;
      idb.withInactive(state.transaction, function () {
        bytes = serialize(value);
        clone = deserialize(bytes);
      });
      const storeMeta = state.storeMeta;
      const primary = state.objectStorePosition;
      if (storeMeta.keyPath !== null && keys.extractKey(clone, storeMeta.keyPath) !== primary)
        throw keys.dataError("Failed to execute '" + what + "': The effective object store of this cursor uses " +
          "in-line keys and evaluating the key path of the value parameter results in a different value than the " +
          "cursor's effective key.");
      const request = idb.newRequest(state.transaction);
      return idb.placeRequest(state.transaction, this, function (transactionId) {
        putRecord(transactionId, storeMeta, primary, bytes, clone, false);
        return keys.decode(primary);
      }, request);
    }
    delete() {
      const what = "delete' on 'IDBCursor";
      const state = cursorState(this);
      checkActive(state.transaction, what);
      checkWritable(state.transaction, what);
      if (state.storeMeta.deleted || (state.indexMeta !== null && state.indexMeta.deleted))
        throw domError("Failed to execute '" + what + "': The cursor's source or effective object store has been " +
          "deleted.", "InvalidStateError");
      if (!state.gotValue) throw domError("Failed to execute '" + what + "': The cursor is being iterated or has " +
        "iterated past its end.", "InvalidStateError");
      if (state.keyOnly) throw domError("Failed to execute '" + what + "': The cursor is a key cursor.",
        "InvalidStateError");
      const storeMeta = state.storeMeta;
      const primary = state.objectStorePosition;
      const request = idb.newRequest(state.transaction);
      return idb.placeRequest(state.transaction, this, function (transactionId) {
        deleteRange(transactionId, storeMeta, { lower: primary, upper: primary, lowerOpen: false, upperOpen: false });
        return undefined;
      }, request);
    }
  }
  internal.finishInterface(IDBCursor, "IDBCursor");

  class IDBCursorWithValue extends IDBCursor {
    constructor(key) {
      super(key);
    }
    get value() { return cursorState(this).value; }
  }
  internal.finishInterface(IDBCursorWithValue, "IDBCursorWithValue");

  // For the Cache API: the same operations without a page's transaction.
  internal.idbOperations = {
    retrieve: retrieve,
    retrieveAll: retrieveAll,
    countRecords: countRecords,
    putRecord: putRecord,
    deleteRange: deleteRange,
    generateKey: generateKey
  };
})
