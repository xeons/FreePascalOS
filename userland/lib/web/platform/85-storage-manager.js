// The Storage Standard's StorageManager (navigator.storage, secure
// contexts only): estimate() is the bytes the origin's IndexedDB
// databases and Cache API caches take and the quota the storage service
// grants it; persist() marks the origin's storage persistent (kept by the
// service with the origin's data; nothing evicts storage here, and a
// page's own request is granted as the other browsers grant one for a
// site in use) and persisted() says whether it is.
(function (natives, global, internal) {
  "use strict";
  const backend = internal.idbBackend;
  if (backend === undefined || !global.isSecureContext) return;
  const token = internal.token;
  const Op = backend.Op;

  function ask(operation, read) {
    return new Promise(function (resolve, reject) {
      if (!backend.allowed()) {
        reject(new TypeError("Storage is not available in this context."));
        return;
      }
      backend.queueTask(function () {
        try {
          resolve(read(backend.call(new backend.RequestWriter(operation))));
        } catch (error) {
          reject(error);
        }
      });
    });
  }

  class StorageManager {
    constructor(key) {
      if (key !== token) internal.illegal();
    }
    estimate() {
      return ask(Op.Estimate, function (reader) {
        const usage = reader.f64();
        return { usage: usage, quota: reader.f64() };
      });
    }
    persist() {
      return ask(Op.Persist, function (reader) { return reader.boolean(); });
    }
    persisted() {
      return ask(Op.Persisted, function (reader) { return reader.boolean(); });
    }
  }
  internal.finishInterface(StorageManager, "StorageManager");

  let manager = null;
  const NavigatorPrototype = global.Navigator === undefined ? null : global.Navigator.prototype;
  if (NavigatorPrototype !== null)
    Object.defineProperty(NavigatorPrototype, "storage", {
      get: function () {
        if (manager === null) manager = new StorageManager(token);
        return manager;
      },
      configurable: true,
      enumerable: true
    });
})
