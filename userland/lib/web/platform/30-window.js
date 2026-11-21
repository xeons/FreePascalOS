// Smaller parts of the window: the legacy factory functions (Image,
// Option, Audio), animation frames and idle callbacks, screen,
// matchMedia, crypto (getRandomValues, randomUUID, subtle.digest), and
// navigator's plugins, mime types, permissions and sendBeacon.
(function (natives, global, internal) {
  "use strict";
  const token = internal.token;
  const define = internal.define;

  // HTML Standard 4.8.4.1, 4.10.10 and 4.8.9: [LegacyFactoryFunction]s.
  function factory(name, interfaceName, make, length) {
    if (typeof global[interfaceName] !== "function") return;
    const Factory = {
      [name]: function () {
        if (new.target === undefined)
          throw new TypeError("Failed to construct '" + name + "': Please use the 'new' operator, this DOM object " +
            "constructor cannot be called as a function.");
        return make.apply(undefined, arguments);
      }
    }[name];
    Object.defineProperty(Factory, "length", { value: length });
    Object.defineProperty(Factory, "prototype", { value: global[interfaceName].prototype, writable: false });
    define(global, name, Factory);
  }
  factory("Image", "HTMLImageElement", function (width, height) {
    const image = global.document.createElement("img");
    if (width !== undefined) image.width = width;
    if (height !== undefined) image.height = height;
    return image;
  }, 0);
  factory("Option", "HTMLOptionElement", function (text, value, defaultSelected, selected) {
    const option = global.document.createElement("option");
    if (text !== undefined && String(text) !== "") option.text = String(text);
    if (value !== undefined) option.value = String(value);
    if (defaultSelected) option.setAttribute("selected", "");
    if (selected) option.selected = true;
    return option;
  }, 0);
  factory("Audio", "HTMLAudioElement", function (source) {
    const audio = global.document.createElement("audio");
    audio.setAttribute("preload", "auto");
    if (source !== undefined) audio.setAttribute("src", String(source));
    return audio;
  }, 0);

  // Animation frames: the environment's rendering opportunities when it
  // has them, else a 16 ms beat aligned to the clock.
  const frameCallbacks = new Map();
  let nextFrameHandle = 0;
  let frameScheduled = false;
  function runFrame(timestamp) {
    frameScheduled = false;
    const callbacks = Array.from(frameCallbacks);
    frameCallbacks.clear();
    const now = timestamp === undefined ? natives.now() : timestamp;
    for (const [handle, callback] of callbacks) {
      try {
        callback.call(global, now);
      } catch (error) {
        natives.reportError(error);
      }
    }
  }
  natives.onAnimationFrame = runFrame;
  function scheduleFrame() {
    if (frameScheduled) return;
    frameScheduled = true;
    if (natives.requestFrame()) return;
    const now = natives.now();
    global.setTimeout(function () { runFrame(); }, 16 - (now % 16));
  }
  define(global, "requestAnimationFrame", function requestAnimationFrame(callback) {
    if (typeof callback !== "function")
      throw new TypeError("Failed to execute 'requestAnimationFrame' on 'Window': The callback provided as " +
        "parameter 1 is not a function.");
    const handle = ++nextFrameHandle;
    frameCallbacks.set(handle, callback);
    scheduleFrame();
    return handle;
  });
  define(global, "cancelAnimationFrame", function cancelAnimationFrame(handle) {
    frameCallbacks.delete(Number(handle));
  });

  // requestIdleCallback (Cooperative Scheduling of Background Tasks): the
  // callbacks run in a task of their own with up to 50 ms.
  class IdleDeadline {
    constructor(key, deadline, didTimeout) {
      if (key !== token) internal.illegal();
      idleData.set(this, { deadline: deadline, didTimeout: didTimeout });
    }
    timeRemaining() {
      const state = idleData.get(this);
      return Math.max(0, state.deadline - natives.now());
    }
    get didTimeout() { return idleData.get(this).didTimeout; }
  }
  const idleData = new WeakMap();
  internal.finishInterface(IdleDeadline, "IdleDeadline");
  const idleTimers = new Map();
  let nextIdleHandle = 0;
  define(global, "requestIdleCallback", function requestIdleCallback(callback, options) {
    if (typeof callback !== "function")
      throw new TypeError("Failed to execute 'requestIdleCallback' on 'Window': The callback provided as " +
        "parameter 1 is not a function.");
    const handle = ++nextIdleHandle;
    const timeout = options && options.timeout > 0 ? Number(options.timeout) : 0;
    const delay = timeout > 0 ? Math.min(timeout, 1) : 1;
    idleTimers.set(handle, global.setTimeout(function () {
      idleTimers.delete(handle);
      callback.call(global, new IdleDeadline(token, natives.now() + 50, false));
    }, delay));
    return handle;
  });
  define(global, "cancelIdleCallback", function cancelIdleCallback(handle) {
    const timer = idleTimers.get(Number(handle));
    if (timer !== undefined) {
      global.clearTimeout(timer);
      idleTimers.delete(Number(handle));
    }
  });

  // CSSOM View: Screen and ScreenOrientation.
  class ScreenOrientation extends EventTarget {
    constructor(key) {
      if (key !== token) internal.illegal();
      super();
    }
    get type() {
      const size = natives.screen();
      return size.width >= size.height ? "landscape-primary" : "portrait-primary";
    }
    get angle() { return 0; }
    lock() { return Promise.reject(internal.domException("Screen orientation cannot be locked.", "NotSupportedError")); }
    unlock() {}
  }
  internal.finishInterface(ScreenOrientation, "ScreenOrientation");
  let orientation = null;
  class Screen extends EventTarget {
    constructor(key) {
      if (key !== token) internal.illegal();
      super();
    }
    get availWidth() { return natives.screen().availWidth; }
    get availHeight() { return natives.screen().availHeight; }
    get width() { return natives.screen().width; }
    get height() { return natives.screen().height; }
    get colorDepth() { return 24; }
    get pixelDepth() { return 24; }
    get orientation() {
      if (orientation === null) orientation = new ScreenOrientation(token);
      return orientation;
    }
  }
  internal.finishInterface(Screen, "Screen");
  let screenObject = null;
  internal.defineGetter(global, "screen", function () {
    if (screenObject === null) screenObject = new Screen(token);
    return screenObject;
  });
  internal.defineGetter(global, "screenX", function () { return 0; });
  internal.defineGetter(global, "screenLeft", function () { return 0; });
  internal.defineGetter(global, "screenY", function () { return 0; });
  internal.defineGetter(global, "screenTop", function () { return 0; });
  internal.defineGetter(global, "outerWidth", function () { return global.innerWidth; });
  internal.defineGetter(global, "outerHeight", function () { return global.innerHeight; });

  // matchMedia (CSSOM View 4.2): the media environment answers; lists
  // are told of changes when the viewport changes.
  const mediaLists = [];
  class MediaQueryList extends EventTarget {
    constructor(key, media) {
      if (key !== token) internal.illegal();
      super();
      mediaData.set(this, { media: media, matches: natives.matchMedia(media), onchange: null });
    }
    get media() { return mediaData.get(this).media; }
    get matches() { return natives.matchMedia(mediaData.get(this).media); }
    addListener(callback) { if (callback !== null) this.addEventListener("change", callback); }
    removeListener(callback) { if (callback !== null) this.removeEventListener("change", callback); }
    get onchange() { return mediaData.get(this).onchange; }
    set onchange(value) {
      const state = mediaData.get(this);
      if (state.onchange) this.removeEventListener("change", state.onchange);
      state.onchange = typeof value === "function" ? value : null;
      if (state.onchange) this.addEventListener("change", state.onchange);
    }
  }
  const mediaData = new WeakMap();
  internal.finishInterface(MediaQueryList, "MediaQueryList");
  class MediaQueryListEvent extends Event {
    constructor(type, init) {
      super(type, init);
      mediaData.set(this, { media: init && init.media !== undefined ? String(init.media) : "",
        matches: !!(init && init.matches) });
    }
    get media() { return mediaData.get(this).media; }
    get matches() { return mediaData.get(this).matches; }
  }
  internal.finishInterface(MediaQueryListEvent, "MediaQueryListEvent");
  define(global, "matchMedia", function matchMedia(query) {
    const list = new MediaQueryList(token, natives.normalizeMedia(String(query)));
    mediaLists.push(new WeakRef(list));
    return list;
  });
  natives.onMediaChanged = function () {
    for (let index = mediaLists.length - 1; index >= 0; index--) {
      const list = mediaLists[index].deref();
      if (list === undefined) {
        mediaLists.splice(index, 1);
        continue;
      }
      const state = mediaData.get(list);
      const matches = natives.matchMedia(state.media);
      if (matches !== state.matches) {
        state.matches = matches;
        list.dispatchEvent(new MediaQueryListEvent("change", { media: state.media, matches: matches }));
      }
    }
  };

  // Web Cryptography: getRandomValues, randomUUID and subtle.digest.
  const integerArrays = [Int8Array, Uint8Array, Uint8ClampedArray, Int16Array, Uint16Array, Int32Array, Uint32Array,
    BigInt64Array, BigUint64Array];
  class SubtleCrypto {
    constructor(key) {
      if (key !== token) internal.illegal();
    }
    digest(algorithm, data) {
      try {
        const name = String(typeof algorithm === "object" && algorithm !== null ? algorithm.name : algorithm)
          .toUpperCase();
        if (["SHA-1", "SHA-256", "SHA-384", "SHA-512"].indexOf(name) < 0)
          throw internal.domException("Algorithm: Unrecognized name", "NotSupportedError");
        if (!internal.isBufferSource(data))
          throw new TypeError("Failed to execute 'digest' on 'SubtleCrypto': parameter 2 is not of type " +
            "'(ArrayBuffer or ArrayBufferView)'.");
        return Promise.resolve(natives.digest(name, internal.bufferBytes(data)).buffer);
      } catch (error) {
        return Promise.reject(error);
      }
    }
  }
  internal.finishInterface(SubtleCrypto, "SubtleCrypto");
  let subtle = null;
  class Crypto {
    constructor(key) {
      if (key !== token) internal.illegal();
    }
    get subtle() {
      if (subtle === null) subtle = new SubtleCrypto(token);
      return subtle;
    }
    getRandomValues(array) {
      if (!integerArrays.some(function (Type) { return array instanceof Type; }))
        throw internal.domException("Failed to execute 'getRandomValues' on 'Crypto': The provided ArrayBufferView " +
          "is of type '" + Object.prototype.toString.call(array).slice(8, -1) + "', which is not an integer array " +
          "type.", "TypeMismatchError");
      if (array.byteLength > 65536)
        throw internal.domException("Failed to execute 'getRandomValues' on 'Crypto': The ArrayBufferView's byte " +
          "length (" + array.byteLength + ") exceeds the number of bytes of entropy available via this API (65536).",
          "QuotaExceededError");
      natives.randomFill(new Uint8Array(array.buffer, array.byteOffset, array.byteLength));
      return array;
    }
    randomUUID() {
      const bytes = new Uint8Array(16);
      natives.randomFill(bytes);
      bytes[6] = (bytes[6] & 0x0f) | 0x40;
      bytes[8] = (bytes[8] & 0x3f) | 0x80;
      let text = "";
      for (let index = 0; index < 16; index++) {
        if (index === 4 || index === 6 || index === 8 || index === 10) text += "-";
        text += (bytes[index] + 0x100).toString(16).slice(1);
      }
      return text;
    }
  }
  internal.finishInterface(Crypto, "Crypto");
  let cryptoObject = null;
  internal.defineGetter(global, "crypto", function () {
    if (cryptoObject === null) cryptoObject = new Crypto(token);
    return cryptoObject;
  });

  // Navigator: empty plugin and mime type arrays (no plugins), the
  // permissions query, maxTouchPoints, sendBeacon (Beacon API).
  function emptyArrayClass(name, itemName) {
    const Class = class {
      constructor(key) {
        if (key !== token) internal.illegal();
      }
      get length() { return 0; }
      item(index) { return null; }
      namedItem(name) { return null; }
      [Symbol.iterator]() { return [][Symbol.iterator](); }
    };
    if (name === "PluginArray") Class.prototype.refresh = function refresh() {};
    return internal.finishInterface(Class, name);
  }
  const PluginArray = emptyArrayClass("PluginArray");
  const MimeTypeArray = emptyArrayClass("MimeTypeArray");
  const plugins = new PluginArray(token);
  const mimeTypes = new MimeTypeArray(token);
  const NavigatorPrototype = global.Navigator.prototype;
  function navigatorGetter(name, getter) {
    Object.defineProperty(NavigatorPrototype, name, { get: getter, configurable: true, enumerable: true });
  }
  navigatorGetter("plugins", function () { return plugins; });
  navigatorGetter("mimeTypes", function () { return mimeTypes; });
  navigatorGetter("maxTouchPoints", function () { return 0; });
  navigatorGetter("doNotTrack", function () { return null; });

  class PermissionStatus extends EventTarget {
    constructor(key, name, state) {
      if (key !== token) internal.illegal();
      super();
      permissionData.set(this, { name: name, state: state });
    }
    get name() { return permissionData.get(this).name; }
    get state() { return permissionData.get(this).state; }
    get onchange() { return null; }
    set onchange(value) {}
  }
  const permissionData = new WeakMap();
  internal.finishInterface(PermissionStatus, "PermissionStatus");
  const knownPermissions = ["geolocation", "notifications", "push", "midi", "camera", "microphone",
    "background-fetch", "background-sync", "persistent-storage", "screen-wake-lock", "storage-access",
    "clipboard-read", "clipboard-write", "local-fonts", "accelerometer", "gyroscope", "magnetometer"];
  class Permissions {
    constructor(key) {
      if (key !== token) internal.illegal();
    }
    query(descriptor) {
      if (descriptor === null || typeof descriptor !== "object" || descriptor.name === undefined)
        return Promise.reject(new TypeError("Failed to execute 'query' on 'Permissions': Required member is " +
          "undefined."));
      const name = String(descriptor.name);
      if (knownPermissions.indexOf(name) < 0)
        return Promise.reject(new TypeError("Failed to execute 'query' on 'Permissions': The provided value '" +
          name + "' is not a valid enum value of type PermissionName."));
      return Promise.resolve(new PermissionStatus(token, name, "prompt"));
    }
  }
  internal.finishInterface(Permissions, "Permissions");
  let permissions = null;
  navigatorGetter("permissions", function () {
    if (permissions === null) permissions = new Permissions(token);
    return permissions;
  });

  define(NavigatorPrototype, "sendBeacon", function sendBeacon(url, data) {
    if (arguments.length < 1) throw new TypeError("Failed to execute 'sendBeacon' on 'Navigator': 1 argument required.");
    const target = new URL(String(url), global.document.baseURI);
    if (target.protocol !== "http:" && target.protocol !== "https:")
      throw new TypeError("Failed to execute 'sendBeacon' on 'Navigator': Beacons are only supported over HTTP(S).");
    const body = internal.extractBody === undefined || data == null ? null : internal.extractBody(data);
    if (body !== null && body.bytes.length > 65536) return false;
    natives.beacon(target.href, body === null ? null : body.bytes, body === null ? "" : body.type || "");
    return true;
  });
})
