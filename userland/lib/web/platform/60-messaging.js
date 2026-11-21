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

  // Taken now: page script may replace window.structuredClone, and the
  // clones below read objects of other realms.
  const structuredCloneOf = global.structuredClone;
  const freeze = Object.freeze;
  const createObject = Object.create;
  function clone(message) {
    return structuredCloneOf(message);
  }

  // The MessagePorts of a transfer argument: a sequence, or an options
  // dictionary with transfer (StructuredSerializeOptions). Other
  // transferables (ArrayBuffers) are copied by the clone instead.
  internal.movePort = function (port) {
    return movePort(port);
  };
  internal.transferredPorts = function (transferOrOptions) {
    let transfer = transferOrOptions;
    if (transfer !== null && typeof transfer === "object" && !(Symbol.iterator in transfer))
      transfer = transfer.transfer;
    if (transfer === undefined || transfer === null) return [];
    const ports = [];
    for (const item of Array.from(transfer))
      if (item instanceof MessagePort) {
        if (ports.indexOf(item) >= 0)
          throw internal.domException("Failed to execute 'postMessage': A MessagePort appears twice in the " +
            "transfer list.", "DataCloneError");
        if (portState(item).transferred)
          throw internal.domException("Failed to execute 'postMessage': A MessagePort could not be cloned " +
            "because it was transferred.", "DataCloneError");
        ports.push(item);
      }
    return ports;
  };

  // MessageChannel and MessagePort.
  //
  // The windows of a page and its frames are realms of one heap, but a
  // port must not carry its realm to another (a cross-origin frame
  // would reach this realm's objects through it). A port sent to
  // another realm stays here as a relay and the receiving realm makes
  // a port of its own: the two talk through endpoints, frozen objects
  // without a prototype whose functions clone what they are given into
  // their own realm (exportPort and importEndpoint below). Only these
  // scripts ever hold another realm's endpoints.
  const portData = new WeakMap();
  function portState(port) {
    const state = portData.get(port);
    if (state === undefined) throw new TypeError("Illegal invocation");
    return state;
  }

  // A message for Target (a port of this realm, entangled with the
  // sender): dispatched, or passed on when Target was sent elsewhere.
  function deliverToPort(target, data, ports) {
    const state = portState(target);
    if (state.closed) return;
    if (state.relay !== null) {
      state.relay.post(data, ports.map(exportPort));
      return;
    }
    state.queue.push({ data: data, ports: ports });
    if (state.started) flushPort(target);
  }

  // Port is going to another realm: from now on it relays, and the
  // endpoint is how the other realm's port reaches it.
  function exportPort(port) {
    const state = portState(port);
    state.transferred = true;
    const endpoint = createObject(null);
    endpoint.post = function (data, endpoints) {
      // From the other realm's port: as if this port had sent it.
      const cloned = clone(data);
      const ports = importEndpoints(endpoints);
      if (state.closed) return;
      if (state.remote !== null) state.remote.post(cloned, ports.map(exportPort));
      else if (state.other !== null) deliverToPort(state.other, cloned, ports);
    };
    endpoint.connect = function (sink) {
      state.relay = sink;
      const queued = state.queue;
      state.queue = [];
      for (let index = 0; index < queued.length; index++)
        sink.post(queued[index].data, queued[index].ports.map(exportPort));
    };
    endpoint.close = function () {
      closePort(port);
    };
    return freeze(endpoint);
  }

  // A port transferred within this realm: a new port object takes its
  // place in the entanglement (and its queue), the old one is dead.
  function movePort(port) {
    const state = portState(port);
    const moved = new MessagePort(token);
    const movedState = portState(moved);
    state.transferred = true;
    movedState.other = state.other;
    movedState.remote = state.remote;
    movedState.queue = state.queue;
    state.other = null;
    state.remote = null;
    state.queue = [];
    if (movedState.other !== null) portState(movedState.other).other = moved;
    if (movedState.remote !== null) movedState.remote.connect(sinkFor(moved));
    return moved;
  }

  // What another realm's endpoint calls to reach Port.
  function sinkFor(port) {
    const state = portState(port);
    const sink = createObject(null);
    sink.post = function (data, endpoints) {
      const cloned = clone(data);
      deliverToPort(port, cloned, importEndpoints(endpoints));
    };
    sink.close = function () {
      state.remote = null;
      closePort(port);
    };
    return freeze(sink);
  }

  // The port of this realm for another realm's endpoint.
  function importEndpoint(endpoint) {
    const port = new MessagePort(token);
    portState(port).remote = endpoint;
    endpoint.connect(sinkFor(port));
    return port;
  }

  // Endpoints (an array of another realm, read by index only).
  function importEndpoints(endpoints) {
    const ports = [];
    const count = endpoints.length;
    for (let index = 0; index < count; index++) ports.push(importEndpoint(endpoints[index]));
    return ports;
  }

  function closePort(port) {
    const state = portState(port);
    if (state.closed) return;
    state.closed = true;
    const other = state.other;
    state.other = null;
    if (other !== null) closePort(other);
    const remote = state.remote;
    state.remote = null;
    if (remote !== null) remote.close();
    const relay = state.relay;
    state.relay = null;
    if (relay !== null) relay.close();
  }

  // Asked by another realm's postMessage for the ports a script of this
  // realm transferred: their endpoints.
  natives.onExportPorts = function (transferOrOptions) {
    const endpoints = internal.transferredPorts(transferOrOptions).map(exportPort);
    return freeze(endpoints);
  };

  // The ports a postMessage call to this realm's window delivers: the
  // caller's own when the caller is this realm, else ports made here
  // for the caller realm's endpoints.
  function receivedPorts(transferOrOptions) {
    const endpoints = natives.exportPorts(transferOrOptions);
    if (endpoints === undefined) return internal.transferredPorts(transferOrOptions).map(movePort);
    return importEndpoints(endpoints);
  }

  // window.postMessage, run in the target window's realm.
  internal.define(global, "postMessage", function postMessage(message, targetOriginOrOptions, transfer) {
    if (arguments.length < 1) throw new TypeError("Failed to execute 'postMessage' on 'Window': 1 argument required.");
    let targetOrigin = "/";
    let transferList;
    if (targetOriginOrOptions !== null && typeof targetOriginOrOptions === "object") {
      if (targetOriginOrOptions.targetOrigin !== undefined) targetOrigin = String(targetOriginOrOptions.targetOrigin);
      transferList = targetOriginOrOptions.transfer;
    } else {
      if (targetOriginOrOptions !== undefined) targetOrigin = String(targetOriginOrOptions);
      transferList = transfer;
    }
    const incumbent = natives.incumbentWindow();
    const source = incumbent.window;
    const sourceOrigin = incumbent.origin;
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
    const messagePorts = transferList === undefined || transferList === null ? [] : receivedPorts(transferList);
    internal.queueTask(function () {
      if (targetOrigin !== "*" && targetOrigin !== global.origin) {
        for (const port of messagePorts) closePort(port);
        return;
      }
      global.dispatchEvent(new MessageEvent("message", { data: data, origin: sourceOrigin, source: source,
        ports: messagePorts }));
    });
  });

  class MessagePort extends EventTarget {
    constructor(key) {
      if (key !== token) internal.illegal();
      super();
      portData.set(this, { other: null, remote: null, relay: null, started: false, closed: false,
        transferred: false, queue: [], onmessage: null, scheduled: false });
    }
    postMessage(message, transferOrOptions) {
      const state = portState(this);
      const ports = internal.transferredPorts(transferOrOptions);
      if (ports.indexOf(this) >= 0)
        throw internal.domException("Failed to execute 'postMessage' on 'MessagePort': Port at index 0 " +
          "contains the source port.", "DataCloneError");
      if (state.closed || state.transferred) return;
      if (state.remote !== null) {
        state.remote.post(message, ports.map(exportPort));
        return;
      }
      if (state.other === null) return;
      const data = clone(message);
      deliverToPort(state.other, data, ports.map(movePort));
    }
    start() {
      const state = portState(this);
      if (state.started) return;
      state.started = true;
      flushPort(this);
    }
    close() {
      closePort(this);
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
        const message = state.queue.shift();
        port.dispatchEvent(new MessageEvent("message", { data: message.data, ports: message.ports }));
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
