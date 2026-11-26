// The way from the IndexedDB, Cache API and StorageManager scripts to
// the storage service (Web.IndexedDb.Service): requests and replies in
// its byte format (Web.IndexedDb.Wire) through natives.idbExecute. The
// service answers at once; the scripts deliver results to the page in
// tasks of their own. A failed request becomes the DOMException the
// service named.
(function (natives, global, internal) {
  "use strict";
  if (typeof natives.idbAccess !== "function" || natives.idbAccess() === 0) return;

  const Op = {
    Open: 1, DeleteDatabase: 2, Databases: 3, Close: 4, Begin: 5, Commit: 6, Abort: 7, CreateStore: 8,
    DeleteStore: 9, RenameStore: 10, CreateIndex: 11, DeleteIndex: 12, RenameIndex: 13, PopulateIndex: 14,
    GenerateKey: 15, Put: 16, Delete: 17, Clear: 18, Get: 19, GetAll: 20, Count: 21, Seek: 22, Estimate: 23,
    Persist: 24, Persisted: 25
  };
  const Outcome = { Done: 1, Upgrade: 2, Wait: 3 };
  const statusNames = ["", "ConstraintError", "QuotaExceededError", "NotFoundError", "VersionError",
    "InvalidStateError", "UnknownError", "DataError", "AbortError", "SecurityError"];
  const ByteWriter = internal.ByteWriter;

  class RequestWriter extends ByteWriter {
    constructor(operation) {
      super();
      this.byte(operation);
    }
    // A key: its binary string, a byte per character.
    key(text) {
      this.u32(text === null ? 0 : text.length);
      if (text === null) return;
      this.reserve(text.length);
      for (let index = 0; index < text.length; index++) this.bytes[this.length++] = text.charCodeAt(index);
    }
    // A name: its UTF-16 code units, so that names stay as the page gave.
    name(text) {
      const value = String(text);
      this.u32(value.length * 2);
      this.reserve(value.length * 2);
      for (let index = 0; index < value.length; index++) {
        const unit = value.charCodeAt(index);
        this.bytes[this.length++] = unit & 255;
        this.bytes[this.length++] = unit >> 8;
      }
    }
    boolean(value) {
      this.byte(value ? 1 : 0);
    }
    // A key path as the service keeps it: 0 none, 1 a string, 2 a list.
    keyPath(path) {
      const out = new RequestWriter(path === null ? 0 : (typeof path === "string" ? 1 : 2));
      if (typeof path === "string") out.name(path);
      else if (path !== null) {
        out.u32(path.length);
        for (const item of path) out.name(item);
      }
      this.raw(out.result());
    }
    // A key range (flags, then the bounds there are).
    range(state) {
      let flags = 0;
      if (state.lower !== null) flags |= 1;
      if (state.upper !== null) flags |= 2;
      if (state.lowerOpen) flags |= 4;
      if (state.upperOpen) flags |= 8;
      this.byte(flags);
      if (state.lower !== null) this.key(state.lower);
      if (state.upper !== null) this.key(state.upper);
    }
  }

  class ReplyReader {
    constructor(bytes) {
      this.bytes = bytes;
      this.view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
      this.position = 0;
    }
    need(count) {
      if (this.position + count > this.bytes.length)
        throw new DOMException("The storage service answered with too little.", "UnknownError");
    }
    byte() {
      this.need(1);
      return this.bytes[this.position++];
    }
    boolean() {
      return this.byte() !== 0;
    }
    u32() {
      this.need(4);
      const value = this.view.getUint32(this.position, true);
      this.position += 4;
      return value;
    }
    f64() {
      this.need(8);
      const value = this.view.getFloat64(this.position, true);
      this.position += 8;
      return value;
    }
    bytesItem() {
      const count = this.u32();
      this.need(count);
      const bytes = this.bytes.subarray(this.position, this.position + count);
      this.position += count;
      return bytes;
    }
    key() {
      const bytes = this.bytesItem();
      let text = "";
      for (let index = 0; index < bytes.length; index += 4096)
        text += String.fromCharCode.apply(null, bytes.subarray(index, index + 4096));
      return text;
    }
    name() {
      const bytes = this.bytesItem();
      const units = [];
      for (let index = 0; index + 1 < bytes.length; index += 2) units.push(bytes[index] | (bytes[index + 1] << 8));
      let text = "";
      for (let index = 0; index < units.length; index += 4096)
        text += String.fromCharCode.apply(null, units.slice(index, index + 4096));
      return text;
    }
    keyPath() {
      const inner = new ReplyReader(this.bytesItem());
      const kind = inner.byte();
      if (kind === 0) return null;
      if (kind === 1) return inner.name();
      const count = inner.u32();
      const paths = [];
      for (let index = 0; index < count; index++) paths.push(inner.name());
      return paths;
    }
    // The service's message (ASCII).
    text() {
      const bytes = this.bytesItem();
      let text = "";
      for (let index = 0; index < bytes.length; index++) text += String.fromCharCode(bytes[index]);
      return text;
    }
  }

  // Sends a request; the reader of the answer, or the DOMException the
  // service named.
  function call(writer) {
    const reply = natives.idbExecute(writer.result());
    if (reply === null) throw new DOMException("The storage service is not available.", "UnknownError");
    const reader = new ReplyReader(reply);
    const status = reader.byte();
    if (status !== 0) {
      const message = reader.text();
      throw new DOMException(message, statusNames[status] || "UnknownError");
    }
    return new ReplyReader(reader.bytesItem());
  }

  // The service's schema of a database: stores with their indexes.
  function readSchema(reader) {
    const stores = [];
    const count = reader.u32();
    for (let index = 0; index < count; index++) {
      const store = { id: reader.u32(), name: reader.name(), keyPath: reader.keyPath(), autoIncrement: reader.boolean(),
        indexes: [] };
      const indexCount = reader.u32();
      for (let item = 0; item < indexCount; item++)
        store.indexes.push({ id: reader.u32(), name: reader.name(), keyPath: reader.keyPath(), unique: reader.boolean(),
          multiEntry: reader.boolean() });
      stores.push(store);
    }
    return stores;
  }

  // Tasks of their own (the environment's, never clamped like nested
  // timers; a timer where it has none).
  const queued = new Map();
  let nextTask = 1;
  natives.onQueuedTask = function (id) {
    const callback = queued.get(id);
    if (callback === undefined) return;
    queued.delete(id);
    callback();
  };
  function queueTask(callback) {
    const id = nextTask++;
    queued.set(id, callback);
    if (!natives.queueTask(id)) global.setTimeout(function () { natives.onQueuedTask(id); }, 0);
  }

  // Notices of the service, by kind, to whoever listens.
  const noticeHandlers = [];
  natives.onIndexedDbNotice = function (bytes) {
    const reader = new ReplyReader(bytes);
    const kind = reader.byte();
    const handler = noticeHandlers[kind];
    if (handler !== undefined) handler(reader);
  };

  internal.idbBackend = {
    Op: Op,
    Outcome: Outcome,
    RequestWriter: RequestWriter,
    call: call,
    readSchema: readSchema,
    queueTask: queueTask,
    onNotice: function (kind, handler) { noticeHandlers[kind] = handler; },
    allowed: function () { return natives.idbAccess() === 1; }
  };
})
