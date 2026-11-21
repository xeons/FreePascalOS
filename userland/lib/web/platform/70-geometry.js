// Geometry and CSSOM View: DOMRectReadOnly, DOMRect, DOMRectList,
// DOMPointReadOnly, DOMPoint; element boxes (getBoundingClientRect,
// getClientRects, offset*, client*, scroll*, scrolling), the window's
// scroll position and scrolling, elementFromPoint, and getComputedStyle
// - all answered by the layout through the natives.
(function (natives, global, internal) {
  "use strict";
  const token = internal.token;
  const rectData = new WeakMap();

  class DOMRectReadOnly {
    constructor(x, y, width, height) {
      rectData.set(this, { x: Number(x) || 0, y: Number(y) || 0, width: Number(width) || 0,
        height: Number(height) || 0 });
    }
    static fromRect(other) {
      const rect = other == null ? {} : other;
      return new this(rect.x, rect.y, rect.width, rect.height);
    }
    get x() { return rectData.get(this).x; }
    get y() { return rectData.get(this).y; }
    get width() { return rectData.get(this).width; }
    get height() { return rectData.get(this).height; }
    get top() { const r = rectData.get(this); return Math.min(r.y, r.y + r.height); }
    get right() { const r = rectData.get(this); return Math.max(r.x, r.x + r.width); }
    get bottom() { const r = rectData.get(this); return Math.max(r.y, r.y + r.height); }
    get left() { const r = rectData.get(this); return Math.min(r.x, r.x + r.width); }
    toJSON() {
      return { x: this.x, y: this.y, width: this.width, height: this.height, top: this.top, right: this.right,
        bottom: this.bottom, left: this.left };
    }
  }
  internal.finishInterface(DOMRectReadOnly, "DOMRectReadOnly");

  class DOMRect extends DOMRectReadOnly {
    get x() { return rectData.get(this).x; }
    set x(value) { rectData.get(this).x = Number(value); }
    get y() { return rectData.get(this).y; }
    set y(value) { rectData.get(this).y = Number(value); }
    get width() { return rectData.get(this).width; }
    set width(value) { rectData.get(this).width = Number(value); }
    get height() { return rectData.get(this).height; }
    set height(value) { rectData.get(this).height = Number(value); }
  }
  internal.finishInterface(DOMRect, "DOMRect");

  const listData = new WeakMap();
  class DOMRectList {
    constructor(key, rects) {
      if (key !== token) internal.illegal();
      listData.set(this, rects);
      for (let index = 0; index < rects.length; index++)
        Object.defineProperty(this, index, { value: rects[index], enumerable: true });
    }
    get length() { return listData.get(this).length; }
    item(index) {
      const rects = listData.get(this);
      return index >= 0 && index < rects.length ? rects[index] : null;
    }
    [Symbol.iterator]() { return listData.get(this)[Symbol.iterator](); }
  }
  internal.finishInterface(DOMRectList, "DOMRectList");

  const pointData = new WeakMap();
  class DOMPointReadOnly {
    constructor(x, y, z, w) {
      pointData.set(this, { x: Number(x) || 0, y: Number(y) || 0, z: Number(z) || 0, w: w === undefined ? 1 : Number(w) });
    }
    static fromPoint(other) {
      const point = other == null ? {} : other;
      return new this(point.x, point.y, point.z, point.w);
    }
    get x() { return pointData.get(this).x; }
    get y() { return pointData.get(this).y; }
    get z() { return pointData.get(this).z; }
    get w() { return pointData.get(this).w; }
    toJSON() { return { x: this.x, y: this.y, z: this.z, w: this.w }; }
  }
  internal.finishInterface(DOMPointReadOnly, "DOMPointReadOnly");
  class DOMPoint extends DOMPointReadOnly {
    get x() { return pointData.get(this).x; }
    set x(value) { pointData.get(this).x = Number(value); }
    get y() { return pointData.get(this).y; }
    set y(value) { pointData.get(this).y = Number(value); }
    get z() { return pointData.get(this).z; }
    set z(value) { pointData.get(this).z = Number(value); }
    get w() { return pointData.get(this).w; }
    set w(value) { pointData.get(this).w = Number(value); }
  }
  internal.finishInterface(DOMPoint, "DOMPoint");

  function viewportScroll() {
    return natives.viewportScroll();
  }

  // The border box relative to the viewport.
  function clientRect(element) {
    const box = natives.elementBox(element);
    if (box === null) return new DOMRect(0, 0, 0, 0);
    const scroll = viewportScroll();
    return new DOMRect(box[0] - scroll[0], box[1] - scroll[1], box[2], box[3]);
  }

  function getter(prototype, name, get, set) {
    Object.defineProperty(prototype, name, { get: get, set: set, configurable: true, enumerable: true });
  }
  function method(prototype, name, value) {
    Object.defineProperty(prototype, name, { value: value, writable: true, configurable: true, enumerable: true });
  }

  const ElementPrototype = global.Element.prototype;
  method(ElementPrototype, "getBoundingClientRect", function getBoundingClientRect() {
    return clientRect(this);
  });
  method(ElementPrototype, "getClientRects", function getClientRects() {
    const box = natives.elementBox(this);
    return new DOMRectList(token, box === null ? [] : [clientRect(this)]);
  });

  function scrollGeometry(element) {
    return natives.scrollGeometry(element) || [0, 0, 0, 0, 0, 0, 0, 0];
  }
  function isViewportElement(element) {
    return element === element.ownerDocument.scrollingElement;
  }
  getter(ElementPrototype, "clientTop", function () { return Math.round(scrollGeometry(this)[1]); });
  getter(ElementPrototype, "clientLeft", function () { return Math.round(scrollGeometry(this)[0]); });
  getter(ElementPrototype, "clientWidth", function () {
    if (isViewportElement(this)) return global.innerWidth;
    return Math.round(scrollGeometry(this)[2]);
  });
  getter(ElementPrototype, "clientHeight", function () {
    if (isViewportElement(this)) return global.innerHeight;
    return Math.round(scrollGeometry(this)[3]);
  });
  getter(ElementPrototype, "scrollWidth", function () {
    if (isViewportElement(this)) return Math.max(global.innerWidth, Math.round(scrollGeometry(this)[4]));
    return Math.round(scrollGeometry(this)[4]);
  });
  getter(ElementPrototype, "scrollHeight", function () {
    if (isViewportElement(this)) return Math.max(global.innerHeight, Math.round(scrollGeometry(this)[5]));
    return Math.round(scrollGeometry(this)[5]);
  });
  getter(ElementPrototype, "scrollLeft", function () {
    if (isViewportElement(this)) return viewportScroll()[0];
    return scrollGeometry(this)[6];
  }, function (value) {
    if (isViewportElement(this)) natives.scrollTo(null, Number(value) || 0, viewportScroll()[1]);
    else natives.scrollTo(this, Number(value) || 0, scrollGeometry(this)[7]);
  });
  getter(ElementPrototype, "scrollTop", function () {
    if (isViewportElement(this)) return viewportScroll()[1];
    return scrollGeometry(this)[7];
  }, function (value) {
    if (isViewportElement(this)) natives.scrollTo(null, viewportScroll()[0], Number(value) || 0);
    else natives.scrollTo(this, scrollGeometry(this)[6], Number(value) || 0);
  });

  function scrollTarget(args, currentX, currentY, relative) {
    let x = currentX, y = currentY;
    if (args.length === 1 && args[0] !== null && typeof args[0] === "object") {
      if (args[0].left !== undefined) x = relative ? currentX + Number(args[0].left) : Number(args[0].left);
      if (args[0].top !== undefined) y = relative ? currentY + Number(args[0].top) : Number(args[0].top);
    } else if (args.length >= 2) {
      x = relative ? currentX + Number(args[0]) : Number(args[0]);
      y = relative ? currentY + Number(args[1]) : Number(args[1]);
    }
    return [isFinite(x) ? x : 0, isFinite(y) ? y : 0];
  }
  function elementScroll(element, args, relative) {
    if (isViewportElement(element)) {
      const scroll = viewportScroll();
      const target = scrollTarget(args, scroll[0], scroll[1], relative);
      natives.scrollTo(null, target[0], target[1]);
      return;
    }
    const geometry = scrollGeometry(element);
    const target = scrollTarget(args, geometry[6], geometry[7], relative);
    natives.scrollTo(element, target[0], target[1]);
  }
  method(ElementPrototype, "scroll", function scroll() { elementScroll(this, arguments, false); });
  method(ElementPrototype, "scrollTo", function scrollTo() { elementScroll(this, arguments, false); });
  method(ElementPrototype, "scrollBy", function scrollBy() { elementScroll(this, arguments, true); });
  method(ElementPrototype, "scrollIntoView", function scrollIntoView(argument) {
    const box = natives.elementBox(this);
    if (box === null) return;
    const scroll = viewportScroll();
    let block = "start";
    if (argument === false) block = "end";
    else if (argument !== null && typeof argument === "object" && argument.block !== undefined) block = argument.block;
    let top = box[1];
    if (block === "end") top = box[1] + box[3] - global.innerHeight;
    else if (block === "center") top = box[1] + box[3] / 2 - global.innerHeight / 2;
    else if (block === "nearest") {
      if (box[1] >= scroll[1] && box[1] + box[3] <= scroll[1] + global.innerHeight) return;
      top = box[1] < scroll[1] ? box[1] : box[1] + box[3] - global.innerHeight;
    }
    natives.scrollTo(null, scroll[0], Math.max(0, top));
  });

  // HTMLElement's offset* (CSSOM View 7).
  function computed(element, name) {
    return natives.computedValue(element, name);
  }
  function offsetParentOf(element) {
    if (natives.elementBox(element) === null) return null;
    const body = element.ownerDocument.body;
    if (element === body || element === element.ownerDocument.documentElement) return null;
    if (computed(element, "position") === "fixed") return null;
    for (let ancestor = element.parentElement; ancestor !== null; ancestor = ancestor.parentElement) {
      if (ancestor === body) return body;
      if (computed(ancestor, "position") !== "static") return ancestor;
      const name = ancestor.localName;
      if ((name === "td" || name === "th" || name === "table") && computed(element, "position") === "static")
        return ancestor;
    }
    return null;
  }
  const HTMLElementPrototype = global.HTMLElement.prototype;
  getter(HTMLElementPrototype, "offsetParent", function () { return offsetParentOf(this); });
  function offset(element, index) {
    const box = natives.elementBox(element);
    if (box === null) return 0;
    if (index >= 2) return Math.round(box[index]);
    const parent = offsetParentOf(element);
    if (parent === null || parent === element.ownerDocument.body) return Math.round(box[index]);
    const parentBox = natives.elementBox(parent);
    const parentBorder = scrollGeometry(parent);
    return Math.round(box[index] - parentBox[index] - parentBorder[index]);
  }
  getter(HTMLElementPrototype, "offsetLeft", function () { return offset(this, 0); });
  getter(HTMLElementPrototype, "offsetTop", function () { return offset(this, 1); });
  getter(HTMLElementPrototype, "offsetWidth", function () { return offset(this, 2); });
  getter(HTMLElementPrototype, "offsetHeight", function () { return offset(this, 3); });

  // The window's scroll position and scrolling.
  function windowScroll(args, relative) {
    const scroll = viewportScroll();
    const target = scrollTarget(args, scroll[0], scroll[1], relative);
    natives.scrollTo(null, target[0], target[1]);
  }
  for (const name of ["scrollX", "pageXOffset"])
    internal.defineGetter(global, name, function () { return viewportScroll()[0]; });
  for (const name of ["scrollY", "pageYOffset"])
    internal.defineGetter(global, name, function () { return viewportScroll()[1]; });
  internal.define(global, "scroll", function scroll() { windowScroll(arguments, false); });
  internal.define(global, "scrollTo", function scrollTo() { windowScroll(arguments, false); });
  internal.define(global, "scrollBy", function scrollBy() { windowScroll(arguments, true); });

  const DocumentPrototype = global.Document.prototype;
  method(DocumentPrototype, "elementFromPoint", function elementFromPoint(x, y) {
    return natives.elementAtPoint(Number(x), Number(y));
  });
  method(DocumentPrototype, "elementsFromPoint", function elementsFromPoint(x, y) {
    const result = [];
    for (let element = natives.elementAtPoint(Number(x), Number(y)); element !== null; element = element.parentElement)
      result.push(element);
    return result;
  });
  getter(DocumentPrototype, "scrollingElement", function () {
    return this.compatMode === "BackCompat" ? this.body : this.documentElement;
  });

  // getComputedStyle: a read-only CSSStyleProperties of the computed
  // values (a proxy that answers by property name, camel-cased or not).
  let names = null;
  function propertyNames() {
    if (names === null) names = natives.computedNames();
    return names;
  }
  function dashed(name) {
    if (name.indexOf("-") >= 0 || name.toLowerCase() === name) return name.toLowerCase();
    let result = name.replace(/[A-Z]/g, function (letter) { return "-" + letter.toLowerCase(); });
    if (result.indexOf("webkit-") === 0) result = "-" + result;
    return result;
  }
  const CSSStylePropertiesPrototype = global.CSSStyleProperties.prototype;
  const readOnly = function () {
    throw internal.domException("Failed to execute 'setProperty' on 'CSSStyleDeclaration': These styles are " +
      "computed, and therefore the property is read-only.", "NoModificationAllowedError");
  };
  internal.define(global, "getComputedStyle", function getComputedStyle(element, pseudoElement) {
    if (!(element instanceof global.Element))
      throw new TypeError("Failed to execute 'getComputedStyle' on 'Window': parameter 1 is not of type 'Element'.");
    const target = Object.create(CSSStylePropertiesPrototype);
    const members = {
      getPropertyValue: function getPropertyValue(property) {
        const name = String(property);
        if (name.indexOf("--") === 0) return natives.computedValue(element, name);
        return natives.computedValue(element, name.toLowerCase());
      },
      getPropertyPriority: function getPropertyPriority() { return ""; },
      item: function item(index) {
        const list = propertyNames();
        return index >= 0 && index < list.length ? list[index] : "";
      },
      setProperty: readOnly,
      removeProperty: readOnly
    };
    return new Proxy(target, {
      get: function (object, key) {
        if (typeof key !== "string") return Reflect.get(object, key);
        if (key in members) return members[key];
        if (key === "length") return propertyNames().length;
        if (key === "cssText") return "";
        if (key === "parentRule") return null;
        if (key === "cssFloat") return natives.computedValue(element, "float");
        if (/^\d+$/.test(key)) return members.item(Number(key));
        if (key in object) return Reflect.get(object, key);
        return natives.computedValue(element, dashed(key));
      },
      set: function () { readOnly(); },
      has: function (object, key) { return typeof key === "string" ? true : Reflect.has(object, key); }
    });
  });
})
