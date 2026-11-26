// The Fullscreen API (requestFullscreen, exitFullscreen,
// fullscreenElement, fullscreenEnabled, fullscreenchange and
// fullscreenerror) and the Pointer Lock API (requestPointerLock,
// exitPointerLock, pointerLockElement, pointerlockchange and
// pointerlockerror; movementX and movementY are MouseEvent's). The host
// (the browser window, through the script environment) is asked for the
// mode and refuses without a user gesture; the document's fullscreen
// element (:fullscreen) and pointer lock element are the DOM's. The
// change events fire at the next animation frame, as the specifications
// say for fullscreen. An element in a frame needs allowfullscreen on
// its iframe.
(function (natives, global, internal) {
  "use strict";
  const requestFrame = global.requestAnimationFrame;
  const Document = global.Document;
  const Element = global.Element;

  function fire(target, type) {
    if (target === null) return;
    const event = new Event(type, { bubbles: true, composed: true });
    try {
      target.dispatchEvent(event);
    } catch (error) {
      natives.reportError(error);
    }
  }

  function atNextFrame(callback) {
    requestFrame.call(global, function () { callback(); });
  }

  // The element retargeted against Root (a shadow host stands for what
  // is in its shadow tree), if that lands in Root's tree.
  function elementForRoot(element, root) {
    let current = element;
    while (current !== null) {
      const currentRoot = current.getRootNode();
      if (currentRoot === root) return current;
      if (!(currentRoot instanceof ShadowRoot)) return null;
      current = currentRoot.host;
    }
    return null;
  }

  function fullscreenEnabled(document) {
    if (document !== global.document) return false;
    try {
      const frame = global.frameElement;
      if (frame !== null && !frame.hasAttribute("allowfullscreen")) return false;
    } catch (error) {
      return false;
    }
    return true;
  }

  function isFullscreenable(element) {
    const namespace = element.namespaceURI;
    if (namespace !== "http://www.w3.org/1999/xhtml" && namespace !== "http://www.w3.org/2000/svg" &&
        namespace !== "http://www.w3.org/1998/Math/MathML")
      return false;
    return element.localName !== "dialog";
  }

  // ---- Fullscreen ----

  let fullscreenElement = null;

  internal.define(Element.prototype, "requestFullscreen", function requestFullscreen(options) {
    const element = this;
    const document = element.ownerDocument;
    return new Promise(function (resolve, reject) {
      let refused = !element.isConnected || document !== global.document || !isFullscreenable(element) ||
        !fullscreenEnabled(document);
      let permission = "unsupported";
      if (!refused && element !== fullscreenElement) {
        permission = natives.fullscreenRequest(true);
        refused = permission !== "granted";
      }
      if (refused) {
        atNextFrame(function () {
          fire(element.isConnected ? element : document, "fullscreenerror");
          reject(new TypeError(permission === "denied" ? "Fullscreen needs a user gesture" :
            "This element cannot be shown fullscreen here"));
        });
        return;
      }
      fullscreenElement = element;
      natives.setFullscreenElement(element);
      atNextFrame(function () {
        fire(element.isConnected ? element : document, "fullscreenchange");
        resolve(undefined);
      });
    });
  });

  // Leaves fullscreen; AskHost: false when the host left already.
  function exitFullscreen(askHost) {
    const element = fullscreenElement;
    fullscreenElement = null;
    if (askHost) natives.fullscreenRequest(false);
    natives.setFullscreenElement(null);
    return element;
  }

  internal.define(Document.prototype, "exitFullscreen", function exitFullscreen_() {
    const document = this;
    return new Promise(function (resolve, reject) {
      if (fullscreenElement === null || document !== global.document) {
        reject(new TypeError("The document is not fullscreen"));
        return;
      }
      const element = exitFullscreen(true);
      atNextFrame(function () {
        fire(element !== null && element.isConnected ? element : document, "fullscreenchange");
        resolve(undefined);
      });
    });
  });

  natives.onFullscreenEnded = function () {
    if (fullscreenElement === null) return;
    const element = exitFullscreen(false);
    atNextFrame(function () { fire(element.isConnected ? element : global.document, "fullscreenchange"); });
  };
  natives.onFullscreenElementRemoved = function () {
    if (fullscreenElement === null) return;
    fullscreenElement = null;
    internal.queueTask(function () {
      natives.fullscreenRequest(false);
      atNextFrame(function () { fire(global.document, "fullscreenchange"); });
    });
  };

  Object.defineProperty(Document.prototype, "fullscreenElement", { configurable: true, enumerable: true,
    get: function () { return this === global.document ? elementForRoot(natives.fullscreenElement(), this) : null; } });
  Object.defineProperty(Document.prototype, "fullscreenEnabled", { configurable: true, enumerable: true,
    get: function () { return fullscreenEnabled(this); } });
  Object.defineProperty(Document.prototype, "fullscreen", { configurable: true, enumerable: true,
    get: function () { return this === global.document && natives.fullscreenElement() !== null; } });
  Object.defineProperty(global.ShadowRoot.prototype, "fullscreenElement", { configurable: true, enumerable: true,
    get: function () { return elementForRoot(natives.fullscreenElement(), this); } });
  internal.defineHandler(Document.prototype, "fullscreenchange");
  internal.defineHandler(Document.prototype, "fullscreenerror");
  internal.defineHandler(Element.prototype, "fullscreenchange");
  internal.defineHandler(Element.prototype, "fullscreenerror");

  // ---- Pointer Lock ----

  let pointerLockElement = null;

  internal.define(Element.prototype, "requestPointerLock", function requestPointerLock(options) {
    const element = this;
    const document = element.ownerDocument;
    return new Promise(function (resolve, reject) {
      if (!element.isConnected || document !== global.document) {
        internal.queueTask(function () {
          fire(document, "pointerlockerror");
          reject(new DOMException("The element is not in this window's document", "WrongDocumentError"));
        });
        return;
      }
      let permission = "granted";
      if (element !== pointerLockElement && pointerLockElement === null) permission = natives.pointerLockRequest(true);
      if (permission !== "granted") {
        internal.queueTask(function () {
          fire(document, "pointerlockerror");
          if (permission === "denied")
            reject(new DOMException("Pointer lock needs a user gesture", "NotAllowedError"));
          else
            reject(new DOMException("The pointer cannot be locked here", "NotSupportedError"));
        });
        return;
      }
      pointerLockElement = element;
      natives.setPointerLockElement(element);
      internal.queueTask(function () {
        fire(document, "pointerlockchange");
        resolve(undefined);
      });
    });
  });

  function unlock(askHost) {
    pointerLockElement = null;
    if (askHost) natives.pointerLockRequest(false);
    natives.setPointerLockElement(null);
  }

  internal.define(Document.prototype, "exitPointerLock", function exitPointerLock() {
    if (pointerLockElement === null || this !== global.document) return;
    unlock(true);
    const document = this;
    internal.queueTask(function () { fire(document, "pointerlockchange"); });
  });

  natives.onPointerLockEnded = function () {
    if (pointerLockElement === null) return;
    unlock(false);
    internal.queueTask(function () { fire(global.document, "pointerlockchange"); });
  };
  natives.onPointerLockElementRemoved = function () {
    if (pointerLockElement === null) return;
    pointerLockElement = null;
    internal.queueTask(function () {
      natives.pointerLockRequest(false);
      fire(global.document, "pointerlockchange");
    });
  };

  Object.defineProperty(Document.prototype, "pointerLockElement", { configurable: true, enumerable: true,
    get: function () { return this === global.document ? elementForRoot(natives.pointerLockElement(), this) : null; } });
  Object.defineProperty(global.ShadowRoot.prototype, "pointerLockElement", { configurable: true, enumerable: true,
    get: function () { return elementForRoot(natives.pointerLockElement(), this); } });
  internal.defineHandler(Document.prototype, "pointerlockchange");
  internal.defineHandler(Document.prototype, "pointerlockerror");
})
