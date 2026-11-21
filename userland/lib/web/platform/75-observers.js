// IntersectionObserver and ResizeObserver over the layout's answers. The
// observations are computed in a task soon after observe() and then
// every 200 ms while something is observed (a page at rest costs a few
// box lookups, not a frame every 16 ms).
(function (natives, global, internal) {
  "use strict";
  const token = internal.token;
  const CheckInterval = 200;
  const active = new Set();
  let timer = null;

  function schedule(delay) {
    if (timer !== null || active.size === 0) return;
    timer = global.setTimeout(function () {
      timer = null;
      for (const observer of Array.from(active)) {
        try {
          observer[checkKey]();
        } catch (error) {
          natives.reportError(error);
        }
      }
      schedule(CheckInterval);
    }, delay);
  }
  const checkKey = Symbol("check");

  function viewportRect() {
    return new DOMRectReadOnly(0, 0, global.innerWidth, global.innerHeight);
  }
  function parseMargin(text) {
    const parts = String(text === undefined ? "0px" : text).trim().split(/\s+/);
    const values = parts.map(function (part) {
      const number = parseFloat(part);
      if (isNaN(number)) throw new SyntaxError("Failed to construct 'IntersectionObserver': rootMargin must be " +
        "specified in pixels or percent.");
      return { value: number, percent: /%$/.test(part) };
    });
    while (values.length < 4) values.push(values[values.length === 3 ? 1 : values.length === 2 ? 0 : 0]);
    return values;
  }

  // ---- IntersectionObserver ----

  const entryData = new WeakMap();
  class IntersectionObserverEntry {
    constructor(init) {
      entryData.set(this, init);
    }
    get time() { return entryData.get(this).time; }
    get rootBounds() { return entryData.get(this).rootBounds; }
    get boundingClientRect() { return entryData.get(this).boundingClientRect; }
    get intersectionRect() { return entryData.get(this).intersectionRect; }
    get isIntersecting() { return entryData.get(this).isIntersecting; }
    get isVisible() { return false; }
    get intersectionRatio() { return entryData.get(this).intersectionRatio; }
    get target() { return entryData.get(this).target; }
  }
  internal.finishInterface(IntersectionObserverEntry, "IntersectionObserverEntry");

  const observerData = new WeakMap();
  function state(observer) {
    const value = observerData.get(observer);
    if (value === undefined) throw new TypeError("Illegal invocation");
    return value;
  }

  class IntersectionObserver {
    constructor(callback, options) {
      if (typeof callback !== "function")
        throw new TypeError("Failed to construct 'IntersectionObserver': The callback provided as parameter 1 is " +
          "not a function.");
      const settings = options == null ? {} : options;
      let thresholds = settings.threshold === undefined ? [0] :
        Array.isArray(settings.threshold) ? settings.threshold.map(Number) : [Number(settings.threshold)];
      for (const value of thresholds)
        if (!(value >= 0 && value <= 1)) throw new RangeError("Failed to construct 'IntersectionObserver': Threshold " +
          "values must be numbers between 0 and 1");
      thresholds = thresholds.sort(function (a, b) { return a - b; });
      observerData.set(this, { callback: callback, root: settings.root === undefined ? null : settings.root,
        margin: parseMargin(settings.rootMargin), marginText: settings.rootMargin === undefined ? "0px 0px 0px 0px" :
        String(settings.rootMargin), thresholds: thresholds, targets: new Map(), records: [] });
      Object.defineProperty(this, checkKey, { value: function () { checkIntersections(this); } });
    }
    get root() { return state(this).root; }
    get rootMargin() { return state(this).marginText; }
    get thresholds() { return Object.freeze(state(this).thresholds.slice()); }
    get delay() { return 0; }
    get trackVisibility() { return false; }
    observe(target) {
      if (!(target instanceof global.Element))
        throw new TypeError("Failed to execute 'observe' on 'IntersectionObserver': parameter 1 is not of type " +
          "'Element'.");
      const data = state(this);
      if (!data.targets.has(target)) data.targets.set(target, { previousIndex: -1, previousIntersecting: undefined });
      active.add(this);
      schedule(0);
    }
    unobserve(target) {
      const data = state(this);
      data.targets.delete(target);
      if (data.targets.size === 0) active.delete(this);
    }
    disconnect() {
      const data = state(this);
      data.targets.clear();
      active.delete(this);
    }
    takeRecords() { return state(this).records.splice(0); }
  }
  internal.finishInterface(IntersectionObserver, "IntersectionObserver");

  function rootBoundsOf(data) {
    if (data.root !== null && data.root.nodeType === 1) {
      const rect = data.root.getBoundingClientRect();
      return new DOMRectReadOnly(rect.x + data.root.clientLeft, rect.y + data.root.clientTop, data.root.clientWidth,
        data.root.clientHeight);
    }
    const base = viewportRect();
    const m = data.margin;
    const top = m[0].percent ? m[0].value * base.height / 100 : m[0].value;
    const right = m[1].percent ? m[1].value * base.width / 100 : m[1].value;
    const bottom = m[2].percent ? m[2].value * base.height / 100 : m[2].value;
    const left = m[3].percent ? m[3].value * base.width / 100 : m[3].value;
    return new DOMRectReadOnly(base.x - left, base.y - top, base.width + left + right, base.height + top + bottom);
  }

  function checkIntersections(observer) {
    const data = observerData.get(observer);
    const now = natives.now();
    const rootBounds = rootBoundsOf(data);
    for (const [target, record] of data.targets) {
      let rect = new DOMRectReadOnly(0, 0, 0, 0);
      let intersection = new DOMRectReadOnly(0, 0, 0, 0);
      let intersecting = false;
      let ratio = 0;
      if (target.isConnected && natives.elementBox(target) !== null) {
        rect = target.getBoundingClientRect();
        const left = Math.max(rect.left, rootBounds.left);
        const top = Math.max(rect.top, rootBounds.top);
        const right = Math.min(rect.right, rootBounds.right);
        const bottom = Math.min(rect.bottom, rootBounds.bottom);
        if (right >= left && bottom >= top) {
          intersecting = true;
          intersection = new DOMRectReadOnly(left, top, right - left, bottom - top);
          const area = rect.width * rect.height;
          ratio = area > 0 ? (intersection.width * intersection.height) / area : 1;
        }
      }
      let index = -1;
      if (intersecting) {
        index = 0;
        while (index < data.thresholds.length && data.thresholds[index] <= ratio) index++;
      }
      if (index !== record.previousIndex || intersecting !== record.previousIntersecting) {
        record.previousIndex = index;
        record.previousIntersecting = intersecting;
        data.records.push(new IntersectionObserverEntry({ time: now, rootBounds: data.root === null ? rootBounds : null,
          boundingClientRect: rect, intersectionRect: intersection, isIntersecting: intersecting,
          intersectionRatio: ratio, target: target }));
      }
    }
    if (data.records.length > 0) data.callback.call(observer, data.records.splice(0), observer);
  }

  // ---- ResizeObserver ----

  const sizeData = new WeakMap();
  class ResizeObserverSize {
    constructor(key, inline, block) {
      if (key !== token) internal.illegal();
      sizeData.set(this, { inline: inline, block: block });
    }
    get inlineSize() { return sizeData.get(this).inline; }
    get blockSize() { return sizeData.get(this).block; }
  }
  internal.finishInterface(ResizeObserverSize, "ResizeObserverSize");

  const resizeEntryData = new WeakMap();
  class ResizeObserverEntry {
    constructor(key, init) {
      if (key !== token) internal.illegal();
      resizeEntryData.set(this, init);
    }
    get target() { return resizeEntryData.get(this).target; }
    get contentRect() { return resizeEntryData.get(this).contentRect; }
    get borderBoxSize() { return Object.freeze([resizeEntryData.get(this).borderBox]); }
    get contentBoxSize() { return Object.freeze([resizeEntryData.get(this).contentBox]); }
    get devicePixelContentBoxSize() { return Object.freeze([resizeEntryData.get(this).deviceBox]); }
  }
  internal.finishInterface(ResizeObserverEntry, "ResizeObserverEntry");

  function boxSizes(target) {
    const box = natives.elementBox(target);
    if (box === null) return null;
    const style = global.getComputedStyle(target);
    const number = function (name) { return parseFloat(style.getPropertyValue(name)) || 0; };
    const paddingLeft = number("padding-left"), paddingTop = number("padding-top");
    const contentWidth = Math.max(0, box[2] - number("border-left-width") - number("border-right-width") -
      paddingLeft - number("padding-right"));
    const contentHeight = Math.max(0, box[3] - number("border-top-width") - number("border-bottom-width") -
      paddingTop - number("padding-bottom"));
    return { border: [box[2], box[3]], content: [contentWidth, contentHeight], paddingLeft: paddingLeft,
      paddingTop: paddingTop };
  }

  const resizeData = new WeakMap();
  class ResizeObserver {
    constructor(callback) {
      if (typeof callback !== "function")
        throw new TypeError("Failed to construct 'ResizeObserver': The callback provided as parameter 1 is not a " +
          "function.");
      resizeData.set(this, { callback: callback, targets: new Map() });
      Object.defineProperty(this, checkKey, { value: function () { checkSizes(this); } });
    }
    observe(target, options) {
      if (!(target instanceof global.Element))
        throw new TypeError("Failed to execute 'observe' on 'ResizeObserver': parameter 1 is not of type 'Element'.");
      const data = resizeData.get(this);
      data.targets.set(target, { box: options && options.box ? String(options.box) : "content-box", last: null });
      active.add(this);
      schedule(0);
    }
    unobserve(target) {
      const data = resizeData.get(this);
      data.targets.delete(target);
      if (data.targets.size === 0) active.delete(this);
    }
    disconnect() {
      resizeData.get(this).targets.clear();
      active.delete(this);
    }
  }
  internal.finishInterface(ResizeObserver, "ResizeObserver");

  function checkSizes(observer) {
    const data = resizeData.get(observer);
    const entries = [];
    const ratio = global.devicePixelRatio || 1;
    for (const [target, record] of data.targets) {
      const sizes = target.isConnected ? boxSizes(target) : null;
      const current = sizes === null ? [0, 0] : record.box === "border-box" ? sizes.border : sizes.content;
      if (record.last !== null && record.last[0] === current[0] && record.last[1] === current[1]) continue;
      if (record.last === null && current[0] === 0 && current[1] === 0 && sizes === null) {
        record.last = current;
        continue;
      }
      record.last = current;
      const content = sizes === null ? [0, 0] : sizes.content;
      const border = sizes === null ? [0, 0] : sizes.border;
      entries.push(new ResizeObserverEntry(token, {
        target: target,
        contentRect: new DOMRectReadOnly(sizes === null ? 0 : sizes.paddingLeft, sizes === null ? 0 : sizes.paddingTop,
          content[0], content[1]),
        borderBox: new ResizeObserverSize(token, border[0], border[1]),
        contentBox: new ResizeObserverSize(token, content[0], content[1]),
        deviceBox: new ResizeObserverSize(token, Math.round(content[0] * ratio), Math.round(content[1] * ratio))
      }));
    }
    if (entries.length > 0) data.callback.call(observer, entries, observer);
  }
})
