// Streams (the default reader parts of ReadableStream the Fetch Standard
// and pages use), File API (Blob, File, FileReader, blob: URLs) and
// FormData.
(function (natives, global, internal) {
  "use strict";
  const token = internal.token;

  // ---- ReadableStream ----

  const streamData = new WeakMap();
  function stream(object) {
    const state = streamData.get(object);
    if (state === undefined) throw new TypeError("Illegal invocation");
    return state;
  }

  class ReadableStreamDefaultController {
    constructor(key, state) {
      if (key !== token) internal.illegal();
      streamData.set(this, state);
    }
    get desiredSize() {
      const state = stream(this);
      if (state.state === "errored") return null;
      if (state.state === "closed") return 0;
      return state.highWaterMark - state.queue.length;
    }
    enqueue(chunk) {
      const state = stream(this);
      if (state.closeRequested || state.state !== "readable") throw new TypeError("The stream is not readable.");
      if (state.readRequests.length > 0) state.readRequests.shift().resolve({ value: chunk, done: false });
      else state.queue.push(chunk);
      pullIfNeeded(state);
    }
    close() {
      const state = stream(this);
      if (state.closeRequested || state.state !== "readable") throw new TypeError("The stream is not readable.");
      state.closeRequested = true;
      if (state.queue.length === 0) finishClose(state);
    }
    error(reason) {
      errorStream(stream(this), reason);
    }
  }
  internal.finishInterface(ReadableStreamDefaultController, "ReadableStreamDefaultController");

  function finishClose(state) {
    state.state = "closed";
    for (const request of state.readRequests.splice(0)) request.resolve({ value: undefined, done: true });
    if (state.reader) state.reader.closedResolve();
  }

  function errorStream(state, reason) {
    if (state.state !== "readable") return;
    state.state = "errored";
    state.storedError = reason;
    state.queue = [];
    for (const request of state.readRequests.splice(0)) request.reject(reason);
    if (state.reader) state.reader.closedReject(reason);
  }

  function pullIfNeeded(state) {
    if (!state.started || state.pulling || state.closeRequested || state.state !== "readable") return;
    if (state.source.pull === undefined) return;
    if (state.queue.length >= state.highWaterMark && state.readRequests.length === 0) return;
    state.pulling = true;
    Promise.resolve().then(function () {
      return state.source.pull.call(state.source, state.controller);
    }).then(function () {
      state.pulling = false;
      if (state.queue.length < state.highWaterMark || state.readRequests.length > 0) pullIfNeeded(state);
    }, function (error) {
      errorStream(state, error);
    });
  }

  class ReadableStream {
    constructor(underlyingSource, strategy) {
      const source = underlyingSource == null ? {} : underlyingSource;
      if (source.type === "bytes") {
        // Byte streams are read as default streams of Uint8Array chunks.
      }
      const highWaterMark = strategy && strategy.highWaterMark !== undefined ? Number(strategy.highWaterMark) : 1;
      const state = { source: source, queue: [], readRequests: [], state: "readable", closeRequested: false,
        started: false, pulling: false, highWaterMark: highWaterMark, reader: null, storedError: undefined,
        disturbed: false };
      streamData.set(this, state);
      state.controller = new ReadableStreamDefaultController(token, state);
      const started = source.start === undefined ? undefined : source.start.call(source, state.controller);
      Promise.resolve(started).then(function () {
        state.started = true;
        pullIfNeeded(state);
      }, function (error) {
        errorStream(state, error);
      });
    }
    get locked() { return stream(this).reader !== null; }
    cancel(reason) {
      const state = stream(this);
      if (state.reader !== null) return Promise.reject(new TypeError("The stream is locked."));
      return cancelStream(state, reason);
    }
    getReader(options) {
      if (options && options.mode === "byob")
        throw new TypeError("BYOB readers are not supported.");
      return new ReadableStreamDefaultReader(this);
    }
    tee() {
      const reader = this.getReader();
      let controllers = [];
      function pump() {
        return reader.read().then(function (result) {
          if (result.done) {
            for (const controller of controllers) try { controller.close(); } catch (error) {}
            return;
          }
          for (const controller of controllers) try { controller.enqueue(result.value); } catch (error) {}
          return pump();
        }, function (error) {
          for (const controller of controllers) controller.error(error);
        });
      }
      const branches = [0, 1].map(function () {
        return new ReadableStream({ start: function (controller) { controllers.push(controller); } });
      });
      pump();
      return branches;
    }
    pipeTo(destination, options) {
      const reader = this.getReader();
      const writer = destination.getWriter();
      function pump() {
        return reader.read().then(function (result) {
          if (result.done) return writer.close();
          return writer.write(result.value).then(pump);
        });
      }
      return pump();
    }
    pipeThrough(transform, options) {
      this.pipeTo(transform.writable, options);
      return transform.readable;
    }
    values(options) {
      const reader = this.getReader();
      const preventCancel = !!(options && options.preventCancel);
      return {
        next: function () { return reader.read(); },
        return: function (value) {
          if (!preventCancel) reader.cancel(value);
          else reader.releaseLock();
          return Promise.resolve({ value: value, done: true });
        },
        [Symbol.asyncIterator]: function () { return this; }
      };
    }
    [Symbol.asyncIterator](options) { return this.values(options); }
    static from(asyncIterable) {
      const iterator = asyncIterable[Symbol.asyncIterator] ? asyncIterable[Symbol.asyncIterator]() :
        asyncIterable[Symbol.iterator]();
      return new ReadableStream({
        pull: function (controller) {
          return Promise.resolve(iterator.next()).then(function (result) {
            if (result.done) controller.close();
            else controller.enqueue(result.value);
          });
        }
      });
    }
  }
  internal.finishInterface(ReadableStream, "ReadableStream");

  function cancelStream(state, reason) {
    state.disturbed = true;
    if (state.state === "closed") return Promise.resolve();
    if (state.state === "errored") return Promise.reject(state.storedError);
    state.queue = [];
    finishClose(state);
    const cancel = state.source.cancel;
    return Promise.resolve(cancel === undefined ? undefined : cancel.call(state.source, reason)).then(function () {});
  }

  const readerData = new WeakMap();
  class ReadableStreamDefaultReader {
    constructor(streamObject) {
      const state = stream(streamObject);
      if (state.reader !== null) throw new TypeError("ReadableStreamDefaultReader constructor can only accept " +
        "readable streams that are not yet locked to a reader");
      const reader = { stream: state, closed: null, closedResolve: null, closedReject: null };
      reader.closed = new Promise(function (resolve, reject) {
        reader.closedResolve = resolve;
        reader.closedReject = reject;
      });
      reader.closed.catch(function () {});
      if (state.state === "closed") reader.closedResolve();
      else if (state.state === "errored") reader.closedReject(state.storedError);
      state.reader = reader;
      readerData.set(this, reader);
    }
    get closed() { return readerData.get(this).closed; }
    read() {
      const reader = readerData.get(this);
      if (reader === undefined) return Promise.reject(new TypeError("Illegal invocation"));
      const state = reader.stream;
      if (state === null) return Promise.reject(new TypeError("The reader is released."));
      state.disturbed = true;
      if (state.queue.length > 0) {
        const chunk = state.queue.shift();
        if (state.closeRequested && state.queue.length === 0) finishClose(state);
        else pullIfNeeded(state);
        return Promise.resolve({ value: chunk, done: false });
      }
      if (state.state === "closed") return Promise.resolve({ value: undefined, done: true });
      if (state.state === "errored") return Promise.reject(state.storedError);
      return new Promise(function (resolve, reject) {
        state.readRequests.push({ resolve: resolve, reject: reject });
        pullIfNeeded(state);
      });
    }
    releaseLock() {
      const reader = readerData.get(this);
      if (reader.stream === null) return;
      for (const request of reader.stream.readRequests.splice(0)) request.reject(new TypeError("The reader was released."));
      reader.stream.reader = null;
      reader.stream = null;
    }
    cancel(reason) {
      const reader = readerData.get(this);
      if (reader.stream === null) return Promise.reject(new TypeError("The reader is released."));
      return cancelStream(reader.stream, reason);
    }
  }
  internal.finishInterface(ReadableStreamDefaultReader, "ReadableStreamDefaultReader");

  // WritableStream and TransformStream enough for pipeThrough of
  // TextDecoderStream-like transforms.
  const writableData = new WeakMap();
  class WritableStream {
    constructor(underlyingSink) {
      writableData.set(this, { sink: underlyingSink == null ? {} : underlyingSink, locked: false });
      const state = writableData.get(this);
      if (state.sink.start) state.sink.start.call(state.sink, {});
    }
    get locked() { return writableData.get(this).locked; }
    getWriter() {
      const state = writableData.get(this);
      if (state.locked) throw new TypeError("The stream is locked.");
      state.locked = true;
      let chain = Promise.resolve();
      return {
        write: function (chunk) {
          chain = chain.then(function () { return state.sink.write ? state.sink.write.call(state.sink, chunk, {}) : undefined; });
          return chain;
        },
        close: function () {
          chain = chain.then(function () { return state.sink.close ? state.sink.close.call(state.sink) : undefined; });
          return chain;
        },
        abort: function (reason) { return Promise.resolve(state.sink.abort ? state.sink.abort.call(state.sink, reason) : undefined); },
        releaseLock: function () { state.locked = false; },
        get ready() { return chain; },
        get closed() { return chain; },
        get desiredSize() { return 1; }
      };
    }
  }
  internal.finishInterface(WritableStream, "WritableStream");

  class TransformStream {
    constructor(transformer) {
      const settings = transformer == null ? {} : transformer;
      let readableController;
      const readable = new ReadableStream({ start: function (controller) { readableController = controller; } });
      const controller = {
        enqueue: function (chunk) { readableController.enqueue(chunk); },
        error: function (reason) { readableController.error(reason); },
        terminate: function () { readableController.close(); },
        get desiredSize() { return readableController.desiredSize; }
      };
      if (settings.start) settings.start.call(settings, controller);
      const writable = new WritableStream({
        write: function (chunk) {
          if (settings.transform) return settings.transform.call(settings, chunk, controller);
          controller.enqueue(chunk);
        },
        close: function () {
          return Promise.resolve(settings.flush ? settings.flush.call(settings, controller) : undefined).then(function () {
            readableController.close();
          });
        }
      });
      streamData.set(this, { readable: readable, writable: writable });
    }
    get readable() { return streamData.get(this).readable; }
    get writable() { return streamData.get(this).writable; }
  }
  internal.finishInterface(TransformStream, "TransformStream");

  class TextDecoderStream extends TransformStream {
    constructor(label, options) {
      const decoder = new TextDecoder(label === undefined ? "utf-8" : label, options);
      super({
        transform: function (chunk, controller) {
          const text = decoder.decode(chunk, { stream: true });
          if (text) controller.enqueue(text);
        },
        flush: function (controller) {
          const text = decoder.decode();
          if (text) controller.enqueue(text);
        }
      });
    }
  }
  internal.finishInterface(TextDecoderStream, "TextDecoderStream");

  class TextEncoderStream extends TransformStream {
    constructor() {
      const encoder = new TextEncoder();
      super({ transform: function (chunk, controller) { controller.enqueue(encoder.encode(String(chunk))); } });
    }
  }
  internal.finishInterface(TextEncoderStream, "TextEncoderStream");

  // A stream of the given chunks (Uint8Array), closed after them.
  internal.streamOfBytes = function (bytes) {
    return new ReadableStream({
      start: function (controller) {
        if (bytes.length > 0) controller.enqueue(bytes);
        controller.close();
      }
    });
  };
  internal.streamIsDisturbed = function (streamObject) {
    return stream(streamObject).disturbed;
  };
  internal.streamIsLocked = function (streamObject) {
    return stream(streamObject).reader !== null;
  };
  // Every byte of a stream, concatenated (a promise of a Uint8Array).
  internal.readAllBytes = function (streamObject) {
    const reader = streamObject.getReader();
    const chunks = [];
    let total = 0;
    function next() {
      return reader.read().then(function (result) {
        if (result.done) {
          const bytes = new Uint8Array(total);
          let offset = 0;
          for (const chunk of chunks) {
            bytes.set(chunk, offset);
            offset += chunk.length;
          }
          return bytes;
        }
        // Fetch's "fully read": every chunk must be a Uint8Array (of any
        // realm); anything else errors the read.
        const chunk = result.value;
        if (!ArrayBuffer.isView(chunk) || Object.prototype.toString.call(chunk) !== "[object Uint8Array]") {
          reader.cancel().catch(function () {});
          throw new TypeError("Failed to read the body: a chunk is not a Uint8Array");
        }
        chunks.push(chunk);
        total += chunk.length;
        return next();
      });
    }
    return next();
  };

  // ---- Blob and File ----

  const blobData = new WeakMap();
  function blob(object) {
    const state = blobData.get(object);
    if (state === undefined) throw new TypeError("Illegal invocation");
    return state;
  }
  function normalizeType(type) {
    const text = type === undefined ? "" : String(type);
    for (let index = 0; index < text.length; index++) {
      const code = text.charCodeAt(index);
      if (code < 0x20 || code > 0x7e) return "";
    }
    return text.toLowerCase();
  }

  class Blob {
    constructor(blobParts, options) {
      const parts = [];
      let total = 0;
      if (blobParts !== undefined) {
        if (blobParts === null || typeof blobParts !== "object" || typeof blobParts[Symbol.iterator] !== "function")
          throw new TypeError("Failed to construct 'Blob': The provided value cannot be converted to a sequence.");
        const endings = options && options.endings === "native" ? "native" : "transparent";
        for (const part of blobParts) {
          let bytes;
          if (part instanceof Blob) bytes = blob(part).bytes;
          else if (internal.isBufferSource(part)) bytes = internal.bufferBytes(part);
          else {
            let text = String(part);
            if (endings === "native") text = text.replace(/\r\n|\r/g, "\n");
            bytes = internal.encodeText(text);
          }
          parts.push(bytes);
          total += bytes.length;
        }
      }
      const bytes = new Uint8Array(total);
      let offset = 0;
      for (const part of parts) {
        bytes.set(part, offset);
        offset += part.length;
      }
      blobData.set(this, { bytes: bytes, type: normalizeType(options ? options.type : undefined) });
    }
    get size() { return blob(this).bytes.length; }
    get type() { return blob(this).type; }
    slice(start, end, contentType) {
      const bytes = blob(this).bytes;
      const size = bytes.length;
      function clamp(value, fallback) {
        if (value === undefined) return fallback;
        const number = Math.trunc(Number(value)) || 0;
        return number < 0 ? Math.max(size + number, 0) : Math.min(number, size);
      }
      const from = clamp(start, 0);
      const to = clamp(end, size);
      const result = new Blob();
      blobData.set(result, { bytes: bytes.slice(from, Math.max(from, to)), type: normalizeType(contentType) });
      return result;
    }
    arrayBuffer() { return Promise.resolve(blob(this).bytes.slice().buffer); }
    bytes() { return Promise.resolve(blob(this).bytes.slice()); }
    text() { return Promise.resolve(internal.decodeText(blob(this).bytes)); }
    stream() { return internal.streamOfBytes(blob(this).bytes.slice()); }
  }
  internal.finishInterface(Blob, "Blob");
  internal.blobBytes = function (object) { return blob(object).bytes; };
  internal.makeBlob = function (bytes, type) {
    const result = new Blob();
    blobData.set(result, { bytes: bytes, type: normalizeType(type) });
    return result;
  };

  const fileData = new WeakMap();
  class File extends Blob {
    constructor(fileBits, fileName, options) {
      if (arguments.length < 2) throw new TypeError("Failed to construct 'File': 2 arguments required, but only " +
        arguments.length + " present.");
      super(fileBits, options);
      fileData.set(this, { name: String(fileName).replace(/\//g, ":"),
        lastModified: options && options.lastModified !== undefined ? Number(options.lastModified) : Date.now() });
    }
    get name() { return fileData.get(this).name; }
    get lastModified() { return fileData.get(this).lastModified; }
    get webkitRelativePath() { return ""; }
  }
  internal.finishInterface(File, "File");
  // A File over bytes already copied (structured deserialization).
  internal.makeFile = function (bytes, type, name, lastModified) {
    const result = new File([], name, { type: type, lastModified: lastModified });
    blobData.set(result, { bytes: bytes, type: normalizeType(type) });
    return result;
  };

  // FileReader
  const readerStates = new WeakMap();
  class FileReader extends EventTarget {
    constructor() {
      super();
      readerStates.set(this, { readyState: 0, result: null, error: null, handlers: {} });
    }
    get readyState() { return readerStates.get(this).readyState; }
    get result() { return readerStates.get(this).result; }
    get error() { return readerStates.get(this).error; }
    readAsArrayBuffer(object) { readBlob(this, object, function (bytes) { return bytes.slice().buffer; }); }
    readAsBinaryString(object) {
      readBlob(this, object, function (bytes) {
        let text = "";
        for (let index = 0; index < bytes.length; index++) text += String.fromCharCode(bytes[index]);
        return text;
      });
    }
    readAsText(object, encoding) {
      readBlob(this, object, function (bytes) {
        return new TextDecoder(encoding === undefined ? "utf-8" : encoding).decode(bytes);
      });
    }
    readAsDataURL(object) {
      readBlob(this, object, function (bytes, type) {
        let binary = "";
        for (let index = 0; index < bytes.length; index++) binary += String.fromCharCode(bytes[index]);
        return "data:" + (type || "application/octet-stream") + ";base64," + btoa(binary);
      });
    }
    abort() {
      const state = readerStates.get(this);
      if (state.readyState === 1) {
        state.readyState = 2;
        state.result = null;
        state.aborted = true;
        fireProgress(this, "abort");
        fireProgress(this, "loadend");
      }
    }
  }
  FileReader.EMPTY = 0;
  FileReader.LOADING = 1;
  FileReader.DONE = 2;
  for (const name of ["loadstart", "progress", "load", "abort", "error", "loadend"])
    internal.defineHandler(FileReader.prototype, name);
  internal.finishInterface(FileReader, "FileReader");

  function fireProgress(target, type, loaded, total) {
    internal.fire(target, new ProgressEvent(type, { lengthComputable: total !== undefined, loaded: loaded || 0,
      total: total || 0 }));
  }
  internal.fireProgress = fireProgress;

  function readBlob(reader, object, convert) {
    const state = readerStates.get(reader);
    if (!(object instanceof Blob)) throw new TypeError("parameter 1 is not of type 'Blob'.");
    if (state.readyState === 1) throw internal.domException("The object is already busy reading Blobs.",
      "InvalidStateError");
    state.readyState = 1;
    state.result = null;
    state.aborted = false;
    const bytes = blob(object).bytes;
    const type = blob(object).type;
    internal.queueTask(function () {
      if (state.aborted) return;
      fireProgress(reader, "loadstart", 0, bytes.length);
      state.readyState = 2;
      state.result = convert(bytes, type);
      fireProgress(reader, "progress", bytes.length, bytes.length);
      fireProgress(reader, "load", bytes.length, bytes.length);
      fireProgress(reader, "loadend", bytes.length, bytes.length);
    });
  }

  // blob: URLs (fetch and XMLHttpRequest resolve them here).
  const blobUrls = new Map();
  internal.blobUrls = blobUrls;
  internal.define(URL, "createObjectURL", function createObjectURL(object) {
    if (!(object instanceof Blob)) throw new TypeError("Failed to execute 'createObjectURL' on 'URL': Overload " +
      "resolution failed.");
    const origin = global.origin === "null" ? "null" : global.origin;
    const url = "blob:" + origin + "/" + global.crypto.randomUUID();
    blobUrls.set(url, object);
    return url;
  });
  internal.define(URL, "revokeObjectURL", function revokeObjectURL(url) {
    blobUrls.delete(String(url));
  });

  // ---- FormData (XMLHttpRequest Standard 5) ----

  const formData = new WeakMap();
  function entries(object) {
    const list = formData.get(object);
    if (list === undefined) throw new TypeError("Illegal invocation");
    return list;
  }
  function entryValue(value, fileName, argumentCount) {
    if (value instanceof Blob) {
      if (!(value instanceof File) || fileName !== undefined)
        return new File([value], fileName !== undefined ? String(fileName) : value instanceof File ? value.name :
          "blob", { type: value.type });
      return value;
    }
    return String(value);
  }
  class FormData {
    constructor(form, submitter) {
      const list = [];
      formData.set(this, list);
      if (form !== undefined) {
        if (!(form instanceof HTMLFormElement))
          throw new TypeError("Failed to construct 'FormData': parameter 1 is not of type 'HTMLFormElement'.");
        for (const element of form.elements) {
          if (!element.name || element.disabled) continue;
          const type = (element.type || "").toLowerCase();
          if (type === "submit" || type === "button" || type === "reset" || type === "image") {
            if (element !== submitter) continue;
          }
          if ((type === "checkbox" || type === "radio") && !element.checked) continue;
          if (type === "file") continue;
          if (element.localName === "select") {
            for (const option of element.options) if (option.selected && !option.disabled)
              list.push([element.name, option.value]);
            continue;
          }
          list.push([element.name, type === "checkbox" || type === "radio" ? (element.value || "on") :
            String(element.value)]);
        }
      }
    }
    append(name, value, fileName) { entries(this).push([String(name), entryValue(value, fileName)]); }
    delete(name) {
      const list = entries(this);
      const wanted = String(name);
      for (let index = list.length - 1; index >= 0; index--) if (list[index][0] === wanted) list.splice(index, 1);
    }
    get(name) {
      const wanted = String(name);
      for (const entry of entries(this)) if (entry[0] === wanted) return entry[1];
      return null;
    }
    getAll(name) {
      const wanted = String(name);
      return entries(this).filter(function (entry) { return entry[0] === wanted; })
        .map(function (entry) { return entry[1]; });
    }
    has(name) {
      const wanted = String(name);
      return entries(this).some(function (entry) { return entry[0] === wanted; });
    }
    set(name, value, fileName) {
      const list = entries(this);
      const wanted = String(name);
      const entry = [wanted, entryValue(value, fileName)];
      const index = list.findIndex(function (item) { return item[0] === wanted; });
      if (index < 0) list.push(entry);
      else {
        list[index] = entry;
        for (let later = list.length - 1; later > index; later--) if (list[later][0] === wanted) list.splice(later, 1);
      }
    }
    *entries() { for (const entry of entries(this).slice()) yield [entry[0], entry[1]]; }
    *keys() { for (const entry of entries(this).slice()) yield entry[0]; }
    *values() { for (const entry of entries(this).slice()) yield entry[1]; }
    forEach(callback, thisArgument) {
      for (const entry of entries(this).slice()) callback.call(thisArgument, entry[1], entry[0], this);
    }
    [Symbol.iterator]() { return this.entries(); }
  }
  internal.finishInterface(FormData, "FormData");
  internal.formEntries = entries;
})
