// Server-sent events (HTML Standard 9.2): EventSource over the platform
// fetch (internal.startFetch, whose body arrives in pieces as it is
// received). The stream is decoded as UTF-8 piece by piece and parsed
// line by line (CRLF, LF or CR, also split between pieces); a blank line
// dispatches the event built from the data, event and id fields; retry
// sets the reconnection time. When the connection ends or fails after it
// was announced, the source waits that long and connects again, sending
// the last event ID; a response that is not a 200 text/event-stream
// fails it for good.
(function (natives, global, internal) {
  "use strict";
  const CONNECTING = 0, OPEN = 1, CLOSED = 2;
  const defaultReconnectionTime = 3000;
  const sourceData = new WeakMap();
  const MessageEventClass = global.MessageEvent;
  const TextDecoderClass = global.TextDecoder;

  function sourceState(object) {
    const state = sourceData.get(object);
    if (state === undefined) throw new TypeError("Illegal invocation");
    return state;
  }

  function baseUrl() {
    return global.document ? global.document.baseURI : global.location.href;
  }

  function mimeEssence(headerList) {
    for (const entry of headerList)
      if (entry[0].toLowerCase() === "content-type")
        return entry[1].split(";")[0].trim().toLowerCase();
    return "";
  }

  function originOf(url) {
    try {
      return new URL(url).origin;
    } catch (error) {
      return "null";
    }
  }

  class EventSource extends EventTarget {
    constructor(url, eventSourceInitDict) {
      super();
      if (arguments.length < 1)
        throw new TypeError("Failed to construct 'EventSource': 1 argument required, but only 0 present.");
      let parsed;
      try {
        parsed = new URL(String(url), baseUrl());
      } catch (error) {
        throw internal.domException("Failed to construct 'EventSource': The URL '" + String(url) + "' is invalid.",
          "SyntaxError");
      }
      const init = eventSourceInitDict == null ? {} : eventSourceInitDict;
      sourceData.set(this, { url: parsed.href, withCredentials: !!init.withCredentials, readyState: CONNECTING,
        reconnectionTime: defaultReconnectionTime, lastEventId: "", fetchId: null, timer: null, origin: "",
        decoder: null, pending: "", skipLineFeed: false, data: "", eventType: "", idBuffer: "", firstPiece: true });
      connect(this);
    }
    get url() { return sourceState(this).url; }
    get withCredentials() { return sourceState(this).withCredentials; }
    get readyState() { return sourceState(this).readyState; }
    close() {
      const state = sourceState(this);
      stopRunning(state);
      state.readyState = CLOSED;
    }
  }
  for (const [name, value] of [["CONNECTING", CONNECTING], ["OPEN", OPEN], ["CLOSED", CLOSED]]) {
    Object.defineProperty(EventSource, name, { value: value, enumerable: true });
    Object.defineProperty(EventSource.prototype, name, { value: value, enumerable: true });
  }
  for (const name of ["open", "message", "error"]) internal.defineHandler(EventSource.prototype, name);
  internal.finishInterface(EventSource, "EventSource");

  function stopRunning(state) {
    if (state.fetchId !== null) {
      internal.abortFetch(state.fetchId);
      state.fetchId = null;
    }
    if (state.timer !== null) {
      global.clearTimeout(state.timer);
      state.timer = null;
    }
  }

  function connect(source) {
    const state = sourceState(source);
    const headerList = [["Accept", "text/event-stream"]];
    if (state.lastEventId !== "") headerList.push(["Last-Event-ID", state.lastEventId]);
    state.decoder = new TextDecoderClass("utf-8");
    state.pending = "";
    state.skipLineFeed = false;
    state.data = "";
    state.eventType = "";
    state.idBuffer = state.lastEventId;
    state.firstPiece = true;
    let announced = false;
    const request = { method: "GET", url: state.url, headerList: headerList, mode: "cors",
      credentials: state.withCredentials ? "include" : "same-origin", cache: "no-store", redirect: "follow",
      referrer: "about:client", referrerPolicy: "", keepalive: false, integrity: "", priority: "auto",
      destination: "" };
    const id = internal.startFetch(request, null, {
      onResponse: function (status, statusText, responseHeaders, finalUrl) {
        if (state.fetchId !== id) return;
        if (status !== 200 || mimeEssence(responseHeaders) !== "text/event-stream") {
          failConnection(source, state);
          return;
        }
        state.origin = originOf(finalUrl || state.url);
        announced = true;
        if (state.readyState === CLOSED) return;
        state.readyState = OPEN;
        internal.fire(source, new Event("open"));
      },
      onData: function (chunk) {
        if (state.fetchId !== id || !announced) return;
        receiveText(source, state, state.decoder.decode(chunk, { stream: true }));
      },
      onEnd: function () {
        if (state.fetchId !== id) return;
        state.fetchId = null;
        if (announced) {
          receiveText(source, state, state.decoder.decode());
          reestablish(source, state);
        }
      },
      onError: function () {
        if (state.fetchId !== id) return;
        state.fetchId = null;
        reestablish(source, state);
      }
    });
    state.fetchId = id;
  }

  // The connection cannot be made again (wrong status or type).
  function failConnection(source, state) {
    stopRunning(state);
    if (state.readyState === CLOSED) return;
    state.readyState = CLOSED;
    internal.fire(source, new Event("error"));
  }

  function reestablish(source, state) {
    if (state.readyState === CLOSED) return;
    state.readyState = CONNECTING;
    internal.fire(source, new Event("error"));
    if (state.readyState !== CONNECTING) return;
    state.timer = global.setTimeout(function () {
      state.timer = null;
      if (state.readyState === CONNECTING) connect(source);
    }, state.reconnectionTime);
  }

  function receiveText(source, state, text) {
    if (state.firstPiece && text.length > 0) {
      state.firstPiece = false;
      if (text.charCodeAt(0) === 0xFEFF) text = text.slice(1);
    }
    let start = 0;
    let index = 0;
    let buffer = text;
    if (state.skipLineFeed && buffer.charAt(0) === "\n") {
      start = 1;
      index = 1;
    }
    state.skipLineFeed = false;
    while (index < buffer.length) {
      const character = buffer.charAt(index);
      if (character === "\r" || character === "\n") {
        processLine(source, state, state.pending + buffer.slice(start, index));
        state.pending = "";
        if (character === "\r") {
          if (index + 1 < buffer.length) {
            if (buffer.charAt(index + 1) === "\n") index++;
          } else {
            state.skipLineFeed = true;
          }
        }
        start = index + 1;
        if (state.readyState === CLOSED) return;
      }
      index++;
    }
    state.pending += buffer.slice(start);
  }

  function processLine(source, state, line) {
    if (line === "") {
      dispatchMessage(source, state);
      return;
    }
    if (line.charAt(0) === ":") return;
    const colon = line.indexOf(":");
    let field = line;
    let value = "";
    if (colon >= 0) {
      field = line.slice(0, colon);
      value = line.slice(colon + 1);
      if (value.charAt(0) === " ") value = value.slice(1);
    }
    if (field === "event") state.eventType = value;
    else if (field === "data") state.data += value + "\n";
    else if (field === "id") {
      if (value.indexOf("\0") < 0) state.idBuffer = value;
    } else if (field === "retry") {
      if (/^[0-9]+$/.test(value)) state.reconnectionTime = parseInt(value, 10);
    }
  }

  function dispatchMessage(source, state) {
    state.lastEventId = state.idBuffer;
    if (state.data === "") {
      state.eventType = "";
      return;
    }
    const data = state.data.charAt(state.data.length - 1) === "\n" ? state.data.slice(0, -1) : state.data;
    const type = state.eventType === "" ? "message" : state.eventType;
    state.data = "";
    state.eventType = "";
    if (state.readyState === CLOSED) return;
    internal.fire(source, new MessageEventClass(type, { data: data, origin: state.origin,
      lastEventId: state.lastEventId }));
  }
})
