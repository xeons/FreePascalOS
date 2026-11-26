// Shared helpers of the platform scripts (Web.Script.Platform runs every
// platform/*.js in file name order, each a function of the natives, the
// global object and this shared object). Interfaces written here behave
// like WebIDL ones: their members are accessor pairs and methods on the
// prototype, not enumerable on instances, constructors that cannot be
// called throw "Illegal constructor", and their functions read as native
// code.
(function (natives, global, internal) {
  "use strict";
  const defineProperty = Object.defineProperty;

  // A data property as WebIDL makes one: writable, configurable, not
  // enumerable on the global.
  internal.define = function (target, name, value) {
    defineProperty(target, name, { value: value, writable: true, configurable: true, enumerable: false });
  };

  // A [Replaceable] readonly attribute of the window.
  internal.defineGetter = function (target, name, getter, enumerable) {
    defineProperty(target, name, {
      get: getter,
      set: function (value) {
        defineProperty(this, name, { value: value, writable: true, configurable: true, enumerable: true });
      },
      configurable: true,
      enumerable: enumerable !== false
    });
  };

  // Makes a class's prototype members WebIDL-like: methods not
  // enumerable is what class syntax gives already; accessors become
  // enumerable as in WebIDL, and the class gets its toStringTag.
  internal.finishInterface = function (Class, name) {
    const prototype = Class.prototype;
    for (const key of Object.getOwnPropertyNames(prototype)) {
      if (key === "constructor") continue;
      const descriptor = Object.getOwnPropertyDescriptor(prototype, key);
      descriptor.enumerable = true;
      defineProperty(prototype, key, descriptor);
    }
    defineProperty(prototype, Symbol.toStringTag, { value: name, configurable: true });
    internal.define(global, name, Class);
    return Class;
  };

  // Dispatches an event the user agent fires (a message from
  // postMessage, a socket's open, a request's progress): isTrusted is
  // true, as for the engine's own events. Script's dispatchEvent makes
  // it false, and page scripts cannot reach this.
  const dispatchTrusted = natives.dispatchTrusted;
  internal.fire = function (target, event) {
    const outcome = dispatchTrusted === undefined ? undefined : dispatchTrusted(target, event);
    return outcome === undefined ? target.dispatchEvent(event) : outcome;
  };

  // The token interfaces made only by the engine pass to their
  // constructors; script calling them gets a TypeError.
  internal.token = Symbol("platform");
  internal.illegal = function () {
    throw new TypeError("Illegal constructor");
  };

  internal.toByteString = function (value) {
    const text = String(value);
    for (let index = 0; index < text.length; index++)
      if (text.charCodeAt(index) > 255) throw new TypeError("Cannot convert to a ByteString: " + text);
    return text;
  };

  internal.domException = function (message, name) {
    return new DOMException(message, name);
  };

  // UTF-8 bytes of a string (USVString conversion first).
  internal.encodeText = function (text) {
    return new TextEncoder().encode(String(text));
  };
  internal.decodeText = function (bytes) {
    return new TextDecoder().decode(bytes);
  };

  internal.isBufferSource = function (value) {
    return value instanceof ArrayBuffer || ArrayBuffer.isView(value);
  };
  // A copy of a BufferSource's bytes.
  internal.bufferBytes = function (value) {
    if (value instanceof ArrayBuffer) return new Uint8Array(value.slice(0));
    return new Uint8Array(value.buffer.slice(value.byteOffset, value.byteOffset + value.byteLength));
  };

  internal.queueTask = function (callback) {
    global.setTimeout(callback, 0);
  };

  // An event handler IDL attribute (HTML Standard 8.1.8.1) of a platform
  // interface: one listener is added the first time a handler is set,
  // and it calls whatever handler is current.
  internal.defineHandler = function (prototype, name) {
    const states = new WeakMap();
    defineProperty(prototype, "on" + name, {
      get: function () {
        const state = states.get(this);
        return state === undefined ? null : state.handler;
      },
      set: function (value) {
        let state = states.get(this);
        const handler = typeof value === "function" || (value !== null && typeof value === "object") ? value : null;
        if (state === undefined) {
          if (handler === null) return;
          state = { handler: null };
          states.set(this, state);
          this.addEventListener(name, function (event) {
            const current = state.handler;
            if (current === null) return;
            const result = typeof current === "function" ? current.call(this, event) : undefined;
            if (result === false) event.preventDefault();
          });
        }
        state.handler = handler;
      },
      configurable: true,
      enumerable: true
    });
  };

  // ProgressEvent (XMLHttpRequest Standard 6), used by FileReader and
  // XMLHttpRequest.
  const progressData = new WeakMap();
  class ProgressEvent extends Event {
    constructor(type, eventInitDict) {
      super(type, eventInitDict);
      const init = eventInitDict == null ? {} : eventInitDict;
      progressData.set(this, { lengthComputable: !!init.lengthComputable, loaded: Number(init.loaded) || 0,
        total: Number(init.total) || 0 });
    }
    get lengthComputable() { return progressData.get(this).lengthComputable; }
    get loaded() { return progressData.get(this).loaded; }
    get total() { return progressData.get(this).total; }
  }
  internal.finishInterface(ProgressEvent, "ProgressEvent");
})
