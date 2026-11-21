// Web Storage (HTML Standard 12.2): localStorage (kept per origin in the
// user's settings folder by the environment) and sessionStorage (per
// top-level browsing session). A Storage object is a legacy platform
// object with named properties: a proxy over the natives' storage area
// gives localStorage.key reads, writes and deletes, `in` and Object.keys.
(function (natives, global, internal) {
  "use strict";
  const token = internal.token;
  const kinds = new WeakMap();
  const LocalKind = 0;
  const SessionKind = 1;

  function kindOf(object) {
    const kind = kinds.get(object);
    if (kind === undefined) throw new TypeError("Illegal invocation");
    return kind;
  }

  class Storage {
    constructor(key) {
      if (key !== token) internal.illegal();
    }
    get length() { return natives.storageLength(kindOf(this)); }
    key(index) {
      if (arguments.length < 1) throw new TypeError("Failed to execute 'key' on 'Storage': 1 argument required.");
      const result = natives.storageKey(kindOf(this), Number(index) >>> 0);
      return result === undefined ? null : result;
    }
    getItem(key) {
      if (arguments.length < 1) throw new TypeError("Failed to execute 'getItem' on 'Storage': 1 argument required.");
      const result = natives.storageGet(kindOf(this), String(key));
      return result === undefined ? null : result;
    }
    setItem(key, value) {
      if (arguments.length < 2) throw new TypeError("Failed to execute 'setItem' on 'Storage': 2 arguments required.");
      if (!natives.storageSet(kindOf(this), String(key), String(value)))
        throw internal.domException("Failed to execute 'setItem' on 'Storage': Setting the value of '" + String(key) +
          "' exceeded the quota.", "QuotaExceededError");
    }
    removeItem(key) {
      if (arguments.length < 1) throw new TypeError("Failed to execute 'removeItem' on 'Storage': 1 argument required.");
      natives.storageRemove(kindOf(this), String(key));
    }
    clear() { natives.storageClear(kindOf(this)); }
  }
  internal.finishInterface(Storage, "Storage");

  function onPrototypeChain(key) {
    return key in Storage.prototype;
  }

  function makeStorage(kind) {
    const target = new Storage(token);
    const handler = {
      get: function (object, key, receiver) {
        if (typeof key === "string" && !onPrototypeChain(key)) {
          const value = natives.storageGet(kind, key);
          if (value !== undefined) return value;
        }
        return Reflect.get(object, key, receiver === proxy ? object : receiver);
      },
      set: function (object, key, value, receiver) {
        if (typeof key !== "string") return Reflect.set(object, key, value);
        if (!natives.storageSet(kind, key, String(value)))
          throw internal.domException("Setting the value of '" + key + "' exceeded the quota.", "QuotaExceededError");
        return true;
      },
      has: function (object, key) {
        if (typeof key === "string" && natives.storageGet(kind, key) !== undefined) return true;
        return Reflect.has(object, key);
      },
      deleteProperty: function (object, key) {
        if (typeof key === "string" && natives.storageGet(kind, key) !== undefined) {
          natives.storageRemove(kind, key);
          return true;
        }
        return Reflect.deleteProperty(object, key);
      },
      ownKeys: function (object) {
        const keys = [];
        const count = natives.storageLength(kind);
        for (let index = 0; index < count; index++) keys.push(natives.storageKey(kind, index));
        return keys.concat(Reflect.ownKeys(object).filter(function (key) { return keys.indexOf(key) < 0; }));
      },
      getOwnPropertyDescriptor: function (object, key) {
        if (typeof key === "string" && !onPrototypeChain(key)) {
          const value = natives.storageGet(kind, key);
          if (value !== undefined) return { value: value, writable: true, enumerable: true, configurable: true };
        }
        return Reflect.getOwnPropertyDescriptor(object, key);
      },
      defineProperty: function (object, key, descriptor) {
        if (typeof key === "string" && "value" in descriptor) {
          if (!natives.storageSet(kind, key, String(descriptor.value)))
            throw internal.domException("Setting the value of '" + key + "' exceeded the quota.", "QuotaExceededError");
          return true;
        }
        return Reflect.defineProperty(object, key, descriptor);
      }
    };
    const proxy = new Proxy(target, handler);
    kinds.set(target, kind);
    kinds.set(proxy, kind);
    return proxy;
  }

  const areas = [null, null];
  function area(kind, name) {
    return function () {
      if (!natives.storageAvailable(kind))
        throw internal.domException("Failed to read the '" + name + "' property from 'Window': Access is denied for " +
          "this document.", "SecurityError");
      if (areas[kind] === null) areas[kind] = makeStorage(kind);
      return areas[kind];
    };
  }
  internal.defineGetter(global, "localStorage", area(LocalKind, "localStorage"));
  internal.defineGetter(global, "sessionStorage", area(SessionKind, "sessionStorage"));
})
