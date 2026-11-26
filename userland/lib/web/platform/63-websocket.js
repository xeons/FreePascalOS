// WebSockets Standard: WebSocket and CloseEvent over the environment's
// connections (natives.webSocketOpen and friends, events coming back as
// natives.onWebSocketEvent). The constructor checks the URL (http: and
// https: become ws: and wss:, no fragment) and the subprotocols (tokens,
// no repeats); everything Fetch decides - mixed content, CSP
// connect-src, HSTS - is decided when the connection is made and fails
// it like a network error. send() counts what it queues in
// bufferedAmount, which goes down as the bytes leave; close() checks
// the code (1000 or 3000-4999) and the reason (at most 123 bytes of
// UTF-8). Messages arrive as strings, Blobs or ArrayBuffers
// (binaryType). The interface exists only where the environment can
// open connections.
(function (natives, global, internal) {
  "use strict";
  if (typeof natives.webSocketSupported !== "function" || !natives.webSocketSupported()) return;
  const CONNECTING = 0, OPEN = 1, CLOSING = 2, CLOSED = 3;
  const socketData = new WeakMap();
  const sockets = new Map();
  const closeData = new WeakMap();
  const MessageEventClass = global.MessageEvent;
  const URLClass = global.URL;

  class CloseEvent extends Event {
    constructor(type, eventInitDict) {
      if (arguments.length < 1)
        throw new TypeError("Failed to construct 'CloseEvent': 1 argument required, but only 0 present.");
      super(type, eventInitDict);
      const init = eventInitDict == null ? {} : eventInitDict;
      let code = init.code === undefined ? 0 : Number(init.code);
      code = Number.isFinite(code) ? Math.trunc(code) & 0xFFFF : 0;
      closeData.set(this, { wasClean: !!init.wasClean, code: code,
        reason: init.reason === undefined ? "" : String(init.reason) });
    }
    get wasClean() { return closeState(this).wasClean; }
    get code() { return closeState(this).code; }
    get reason() { return closeState(this).reason; }
  }
  function closeState(object) {
    const state = closeData.get(object);
    if (state === undefined) throw new TypeError("Illegal invocation");
    return state;
  }
  internal.finishInterface(CloseEvent, "CloseEvent");

  function socketState(object) {
    const state = socketData.get(object);
    if (state === undefined) throw new TypeError("Illegal invocation");
    return state;
  }

  function baseUrl() {
    return global.document ? global.document.baseURI : global.location.href;
  }

  function isToken(text) {
    return text.length > 0 && /^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/.test(text);
  }

  // The bytes send() queues: a string as UTF-8, a Blob's or a buffer's.
  function payloadOf(data) {
    if (data instanceof global.Blob) return { isText: false, bytes: internal.blobBytes(data) };
    if (internal.isBufferSource(data)) return { isText: false, bytes: internal.bufferBytes(data) };
    return { isText: true, bytes: internal.encodeText(data) };
  }

  class WebSocket extends EventTarget {
    constructor(url, protocols) {
      if (arguments.length < 1)
        throw new TypeError("Failed to construct 'WebSocket': 1 argument required, but only 0 present.");
      super();
      const text = String(url);
      let parsed;
      try {
        parsed = new URLClass(text, baseUrl());
      } catch (error) {
        throw internal.domException("Failed to construct 'WebSocket': The URL '" + text + "' is invalid.", "SyntaxError");
      }
      if (parsed.protocol === "http:") parsed.protocol = "ws:";
      else if (parsed.protocol === "https:") parsed.protocol = "wss:";
      if (parsed.protocol !== "ws:" && parsed.protocol !== "wss:")
        throw internal.domException("Failed to construct 'WebSocket': The URL's scheme must be either 'http', " +
          "'https', 'ws', or 'wss'. '" + parsed.protocol.slice(0, -1) + "' is not allowed.", "SyntaxError");
      if (parsed.href.indexOf("#") >= 0)
        throw internal.domException("Failed to construct 'WebSocket': The URL contains a fragment identifier ('" +
          parsed.hash + "'). Fragment identifiers are not allowed in WebSocket URLs.", "SyntaxError");
      let list;
      if (protocols === undefined) list = [];
      else if (typeof protocols === "string" || protocols === null || typeof protocols !== "object") list = [String(protocols)];
      else list = Array.from(protocols, String);
      for (let index = 0; index < list.length; index++) {
        if (!isToken(list[index]))
          throw internal.domException("Failed to construct 'WebSocket': The subprotocol '" + list[index] +
            "' is invalid.", "SyntaxError");
        if (list.indexOf(list[index]) !== index)
          throw internal.domException("Failed to construct 'WebSocket': The subprotocol '" + list[index] +
            "' is duplicated.", "SyntaxError");
      }
      const state = { url: parsed.href, origin: parsed.origin, readyState: CONNECTING, bufferedAmount: 0,
        extensions: "", protocol: "", binaryType: "blob", id: -1 };
      socketData.set(this, state);
      const id = natives.webSocketOpen(parsed.href, list);
      state.id = id;
      if (id < 0) {
        const socket = this;
        internal.queueTask(function () { closed(socket, state, false, 1006, "", true); });
        return;
      }
      sockets.set(id, this);
    }
    get url() { return socketState(this).url; }
    get readyState() { return socketState(this).readyState; }
    get bufferedAmount() { return socketState(this).bufferedAmount; }
    get extensions() { return socketState(this).extensions; }
    get protocol() { return socketState(this).protocol; }
    get binaryType() { return socketState(this).binaryType; }
    set binaryType(value) {
      const state = socketState(this);
      const text = String(value);
      if (text === "blob" || text === "arraybuffer") state.binaryType = text;
    }
    close(code, reason) {
      const state = socketState(this);
      let closeCode = -1;
      if (code !== undefined) {
        let number = Number(code);
        number = Number.isNaN(number) ? 0 : Math.min(Math.max(Math.round(number), 0), 65535);
        if (number !== 1000 && (number < 3000 || number > 4999))
          throw internal.domException("Failed to execute 'close' on 'WebSocket': The close code must be either 1000, " +
            "or between 3000 and 4999. " + number + " is neither.", "InvalidAccessError");
        closeCode = number;
      }
      let reasonText = "";
      if (reason !== undefined) {
        const bytes = internal.encodeText(reason);
        if (bytes.length > 123)
          throw internal.domException("Failed to execute 'close' on 'WebSocket': The close reason must not be greater " +
            "than 123 UTF-8 bytes.", "SyntaxError");
        reasonText = internal.decodeText(bytes);
        if (closeCode < 0) closeCode = 1000;
      }
      if (state.readyState === CLOSING || state.readyState === CLOSED) return;
      // Before it opened this fails the connection; after, it starts the
      // closing handshake.
      state.readyState = CLOSING;
      if (state.id >= 0) natives.webSocketClose(state.id, closeCode, reasonText);
    }
    send(data) {
      const state = socketState(this);
      if (arguments.length < 1)
        throw new TypeError("Failed to execute 'send' on 'WebSocket': 1 argument required, but only 0 present.");
      if (state.readyState === CONNECTING)
        throw internal.domException("Failed to execute 'send' on 'WebSocket': Still in CONNECTING state.",
          "InvalidStateError");
      const payload = payloadOf(data);
      state.bufferedAmount += payload.bytes.length;
      if (state.readyState === OPEN) natives.webSocketSend(state.id, payload.isText, payload.bytes);
    }
  }
  for (const [name, value] of [["CONNECTING", CONNECTING], ["OPEN", OPEN], ["CLOSING", CLOSING], ["CLOSED", CLOSED]]) {
    Object.defineProperty(WebSocket, name, { value: value, enumerable: true });
    Object.defineProperty(WebSocket.prototype, name, { value: value, enumerable: true });
  }
  for (const name of ["open", "error", "close", "message"]) internal.defineHandler(WebSocket.prototype, name);
  internal.finishInterface(WebSocket, "WebSocket");

  function closed(socket, state, wasClean, code, reason, failed) {
    state.readyState = CLOSED;
    if (state.id >= 0) sockets.delete(state.id);
    if (failed) internal.fire(socket, new Event("error"));
    internal.fire(socket, new CloseEvent("close", { wasClean: wasClean, code: code, reason: reason }));
  }

  natives.onWebSocketEvent = function (id, kind, a, b, c, d) {
    const socket = sockets.get(id);
    if (socket === undefined) return;
    const state = socketData.get(socket);
    if (kind === "open") {
      if (state.readyState !== CONNECTING) return;
      state.readyState = OPEN;
      state.protocol = a;
      state.extensions = b;
      internal.fire(socket, new Event("open"));
    } else if (kind === "message") {
      if (state.readyState !== OPEN) return;
      let data = b;
      if (!a) data = state.binaryType === "blob" ? internal.makeBlob(b, "") : b.buffer.slice(b.byteOffset,
        b.byteOffset + b.byteLength);
      internal.fire(socket, new MessageEventClass("message", { data: data, origin: state.origin }));
    } else if (kind === "sent") {
      state.bufferedAmount = Math.max(0, state.bufferedAmount - a);
    } else if (kind === "closing") {
      if (state.readyState === OPEN) state.readyState = CLOSING;
    } else if (kind === "close") {
      closed(socket, state, a, b, c, d);
    }
  };
})
