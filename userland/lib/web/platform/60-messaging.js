// Cross-document messaging (HTML Standard 9.3, 9.4, 9.5): window.postMessage
// (the message structured-cloned, delivered in a task as a MessageEvent
// with the sender's origin and window), MessageChannel and MessagePort,
// BroadcastChannel among this window and its frames.
(function (natives, global, internal) {
  "use strict";
  const token = internal.token;
  const eventData = new WeakMap();

  class MessageEvent extends Event {
    constructor(type, eventInitDict) {
      super(type, eventInitDict);
      const init = eventInitDict == null ? {} : eventInitDict;
      eventData.set(this, { data: init.data === undefined ? null : init.data,
        origin: init.origin === undefined ? "" : String(init.origin),
        lastEventId: init.lastEventId === undefined ? "" : String(init.lastEventId),
        source: init.source === undefined ? null : init.source,
        ports: init.ports === undefined ? [] : Array.from(init.ports) });
    }
    get data() { return eventData.get(this).data; }
    get origin() { return eventData.get(this).origin; }
    get lastEventId() { return eventData.get(this).lastEventId; }
    get source() { return eventData.get(this).source; }
    get ports() { return Object.freeze(eventData.get(this).ports.slice()); }
    initMessageEvent(type, bubbles, cancelable, data, origin, lastEventId, source, ports) {
      const state = eventData.get(this);
      this.initEvent(type, bubbles, cancelable);
      state.data = data === undefined ? null : data;
      state.origin = origin === undefined ? "" : String(origin);
      state.lastEventId = lastEventId === undefined ? "" : String(lastEventId);
      state.source = source === undefined ? null : source;
      state.ports = ports === undefined ? [] : Array.from(ports);
    }
  }
  internal.finishInterface(MessageEvent, "MessageEvent");

  function clone(message, transfer) {
    return structuredClone(message);
  }

  // window.postMessage, run in the target window's realm.
  internal.define(global, "postMessage", function postMessage(message, targetOriginOrOptions, transfer) {
    if (arguments.length < 1) throw new TypeError("Failed to execute 'postMessage' on 'Window': 1 argument required.");
    let targetOrigin = "/";
    let ports = [];
    if (targetOriginOrOptions !== null && typeof targetOriginOrOptions === "object") {
      if (targetOriginOrOptions.targetOrigin !== undefined) targetOrigin = String(targetOriginOrOptions.targetOrigin);
      if (targetOriginOrOptions.transfer !== undefined) ports = Array.from(targetOriginOrOptions.transfer);
    } else if (targetOriginOrOptions !== undefined) {
      targetOrigin = String(targetOriginOrOptions);
      if (transfer !== undefined) ports = Array.from(transfer);
    }
    const source = natives.incumbentWindow();
    const sourceOrigin = source.origin;
    if (targetOrigin === "/") targetOrigin = sourceOrigin;
    else if (targetOrigin !== "*") {
      let parsed;
      try {
        parsed = new URL(targetOrigin);
      } catch (error) {
        throw internal.domException("Failed to execute 'postMessage' on 'Window': Invalid target origin '" +
          targetOrigin + "' in a call to 'postMessage'.", "SyntaxError");
      }
      targetOrigin = parsed.origin;
    }
    const data = clone(message);
    const messagePorts = ports.filter(function (port) { return port instanceof MessagePort; });
    internal.queueTask(function () {
      if (targetOrigin !== "*" && targetOrigin !== global.origin) return;
      global.dispatchEvent(new MessageEvent("message", { data: data, origin: sourceOrigin, source: source,
        ports: messagePorts }));
    });
  });

  // MessageChannel and MessagePort.
  const portData = new WeakMap();
  function portState(port) {
    const state = portData.get(port);
    if (state === undefined) throw new TypeError("Illegal invocation");
    return state;
  }
  class MessagePort extends EventTarget {
    constructor(key) {
      if (key !== token) internal.illegal();
      super();
      portData.set(this, { other: null, started: false, closed: false, queue: [], onmessage: null });
    }
    postMessage(message, transferOrOptions) {
      const state = portState(this);
      if (state.closed || state.other === null) return;
      const data = clone(message);
      const target = state.other;
      const targetState = portState(target);
      targetState.queue.push(data);
      if (targetState.started) flushPort(target);
    }
    start() {
      const state = portState(this);
      if (state.started) return;
      state.started = true;
      flushPort(this);
    }
    close() {
      const state = portState(this);
      state.closed = true;
      if (state.other !== null) portState(state.other).other = null;
      state.other = null;
    }
    get onmessage() { return portState(this).onmessage; }
    set onmessage(value) {
      const state = portState(this);
      if (state.onmessage) this.removeEventListener("message", state.onmessage);
      state.onmessage = typeof value === "function" ? value : null;
      if (state.onmessage) {
        this.addEventListener("message", state.onmessage);
        this.start();
      }
    }
  }
  internal.defineHandler(MessagePort.prototype, "messageerror");
  internal.finishInterface(MessagePort, "MessagePort");

  function flushPort(port) {
    const state = portState(port);
    if (state.scheduled) return;
    state.scheduled = true;
    internal.queueTask(function () {
      state.scheduled = false;
      while (state.queue.length > 0 && !state.closed) {
        const data = state.queue.shift();
        port.dispatchEvent(new MessageEvent("message", { data: data }));
      }
    });
  }

  const channelData = new WeakMap();
  class MessageChannel {
    constructor() {
      const port1 = new MessagePort(token);
      const port2 = new MessagePort(token);
      portState(port1).other = port2;
      portState(port2).other = port1;
      channelData.set(this, { port1: port1, port2: port2 });
    }
    get port1() { return channelData.get(this).port1; }
    get port2() { return channelData.get(this).port2; }
  }
  internal.finishInterface(MessageChannel, "MessageChannel");

  // BroadcastChannel: channels of one name in this realm.
  const channels = new Map();
  const broadcastData = new WeakMap();
  class BroadcastChannel extends EventTarget {
    constructor(name) {
      if (arguments.length < 1) throw new TypeError("Failed to construct 'BroadcastChannel': 1 argument required.");
      super();
      const channelName = String(name);
      broadcastData.set(this, { name: channelName, closed: false });
      if (!channels.has(channelName)) channels.set(channelName, new Set());
      channels.get(channelName).add(this);
    }
    get name() { return broadcastData.get(this).name; }
    postMessage(message) {
      const state = broadcastData.get(this);
      if (state.closed) throw internal.domException("Failed to execute 'postMessage' on 'BroadcastChannel': " +
        "Channel is closed", "InvalidStateError");
      const data = clone(message);
      const sender = this;
      const origin = global.origin;
      for (const receiver of channels.get(state.name) || []) {
        if (receiver === sender) continue;
        internal.queueTask(function () {
          if (!broadcastData.get(receiver).closed)
            receiver.dispatchEvent(new MessageEvent("message", { data: data, origin: origin }));
        });
      }
    }
    close() {
      const state = broadcastData.get(this);
      state.closed = true;
      const set = channels.get(state.name);
      if (set) set.delete(this);
    }
  }
  internal.defineHandler(BroadcastChannel.prototype, "message");
  internal.defineHandler(BroadcastChannel.prototype, "messageerror");
  internal.finishInterface(BroadcastChannel, "BroadcastChannel");
})
