// High Resolution Time, Performance Timeline, User Timing and Navigation
// Timing (Level 2, with the legacy performance.timing and
// performance.navigation): performance.now() and timeOrigin from the
// window's clock, marks and measures, the navigation entry from the
// loader's timestamps, PerformanceObserver.
(function (natives, global, internal) {
  "use strict";
  const token = internal.token;
  const entryData = new WeakMap();

  function data(object) {
    const value = entryData.get(object);
    if (value === undefined) throw new TypeError("Illegal invocation");
    return value;
  }

  class PerformanceEntry {
    constructor(key, fields) {
      if (key !== token) internal.illegal();
      entryData.set(this, fields);
    }
    get name() { return data(this).name; }
    get entryType() { return data(this).entryType; }
    get startTime() { return data(this).startTime; }
    get duration() { return data(this).duration; }
    toJSON() {
      const result = {};
      for (let prototype = Object.getPrototypeOf(this); prototype && prototype !== Object.prototype;
        prototype = Object.getPrototypeOf(prototype))
        for (const key of Object.getOwnPropertyNames(prototype)) {
          const descriptor = Object.getOwnPropertyDescriptor(prototype, key);
          if (descriptor.get && !(key in result)) result[key] = this[key];
        }
      return result;
    }
  }
  internal.finishInterface(PerformanceEntry, "PerformanceEntry");

  function checkDetail(detail) {
    return detail === undefined ? null : structuredClone(detail);
  }

  class PerformanceMark extends PerformanceEntry {
    constructor(markName, markOptions) {
      const options = markOptions == null ? {} : markOptions;
      const name = String(markName);
      let startTime;
      if (options.startTime !== undefined) {
        startTime = Number(options.startTime);
        if (startTime < 0) throw new TypeError("startTime cannot be negative");
      } else startTime = natives.now();
      super(token, { name: name, entryType: "mark", startTime: startTime, duration: 0,
        detail: checkDetail(options.detail) });
    }
    get detail() { return data(this).detail; }
  }
  internal.finishInterface(PerformanceMark, "PerformanceMark");

  class PerformanceMeasure extends PerformanceEntry {
    constructor(key, fields) {
      if (key !== token) internal.illegal();
      super(token, fields);
    }
    get detail() { return data(this).detail; }
  }
  internal.finishInterface(PerformanceMeasure, "PerformanceMeasure");

  class PerformanceResourceTiming extends PerformanceEntry {
    constructor(key, fields) {
      if (key !== token) internal.illegal();
      super(token, fields);
    }
    get initiatorType() { return data(this).initiatorType; }
    get deliveryType() { return ""; }
    get nextHopProtocol() { return data(this).nextHopProtocol || ""; }
    get workerStart() { return 0; }
    get redirectStart() { return 0; }
    get redirectEnd() { return 0; }
    get fetchStart() { return data(this).fetchStart; }
    get domainLookupStart() { return data(this).fetchStart; }
    get domainLookupEnd() { return data(this).fetchStart; }
    get connectStart() { return data(this).fetchStart; }
    get connectEnd() { return data(this).fetchStart; }
    get secureConnectionStart() { return 0; }
    get requestStart() { return data(this).requestStart; }
    get responseStart() { return data(this).responseStart; }
    get responseEnd() { return data(this).responseEnd; }
    get transferSize() { return data(this).transferSize || 0; }
    get encodedBodySize() { return data(this).encodedBodySize || 0; }
    get decodedBodySize() { return data(this).decodedBodySize || 0; }
    get responseStatus() { return data(this).responseStatus || 0; }
    get renderBlockingStatus() { return "non-blocking"; }
    get serverTiming() { return []; }
  }
  internal.finishInterface(PerformanceResourceTiming, "PerformanceResourceTiming");

  class PerformanceNavigationTiming extends PerformanceResourceTiming {
    constructor(key, fields) {
      if (key !== token) internal.illegal();
      super(token, fields);
    }
    get unloadEventStart() { return 0; }
    get unloadEventEnd() { return 0; }
    get domInteractive() { return timing().domInteractive || 0; }
    get domContentLoadedEventStart() { return timing().domContentLoadedEventStart || 0; }
    get domContentLoadedEventEnd() { return timing().domContentLoadedEventEnd || 0; }
    get domComplete() { return timing().domComplete || 0; }
    get loadEventStart() { return timing().loadEventStart || 0; }
    get loadEventEnd() { return timing().loadEventEnd || 0; }
    get duration() { return timing().loadEventEnd || 0; }
    get responseEnd() { return timing().responseEnd || data(this).responseEnd; }
    get type() { return timing().type || "navigate"; }
    get redirectCount() { return timing().redirectCount || 0; }
    get activationStart() { return 0; }
    get criticalCHRestart() { return 0; }
    get notRestoredReasons() { return null; }
  }
  internal.finishInterface(PerformanceNavigationTiming, "PerformanceNavigationTiming");

  // The loader's timestamps (milliseconds from the time origin), fresh on
  // every read: the later ones fill in as the page loads.
  function timing() {
    return natives.navigationTiming() || {};
  }

  let navigationEntry = null;
  function navigationEntries() {
    if (navigationEntry === null) {
      const times = timing();
      navigationEntry = new PerformanceNavigationTiming(token, {
        name: global.document ? global.document.URL : "", entryType: "navigation", startTime: 0,
        initiatorType: "navigation", fetchStart: times.fetchStart || 0, requestStart: times.requestStart || 0,
        responseStart: times.responseStart || 0, responseEnd: times.responseEnd || 0,
        nextHopProtocol: times.nextHopProtocol, transferSize: times.transferSize,
        encodedBodySize: times.encodedBodySize, decodedBodySize: times.decodedBodySize,
        responseStatus: times.responseStatus
      });
    }
    return [navigationEntry];
  }

  const userEntries = [];
  const observers = [];

  function byStartTime(a, b) {
    return a.startTime - b.startTime;
  }

  function allEntries() {
    return navigationEntries().concat(userEntries).sort(byStartTime);
  }

  function queueEntry(entry) {
    for (const observer of observers) {
      const state = observerData.get(observer);
      if (state.types.indexOf(entry.entryType) < 0) continue;
      state.buffer.push(entry);
      if (!state.queued) {
        state.queued = true;
        internal.queueTask(function () {
          state.queued = false;
          if (state.buffer.length === 0 || observers.indexOf(observer) < 0) return;
          const list = new PerformanceObserverEntryList(token, state.buffer.splice(0));
          state.callback.call(observer, list, observer, { droppedEntriesCount: 0 });
        });
      }
    }
  }

  // The timestamp a measure's start or end names: a mark's name, a
  // navigation timing attribute, or a number.
  function resolveTime(value) {
    if (typeof value === "number") {
      if (value < 0) throw new TypeError("a timestamp cannot be negative");
      return value;
    }
    const name = String(value);
    for (let index = userEntries.length - 1; index >= 0; index--)
      if (userEntries[index].entryType === "mark" && userEntries[index].name === name)
        return userEntries[index].startTime;
    const times = timing();
    if (name in times && typeof times[name] === "number") {
      if (times[name] === 0)
        throw internal.domException("'" + name + "' is empty: either the event hasn't happened yet, or it would " +
          "provide cross-origin timing information.", "InvalidAccessError");
      return times[name];
    }
    throw new SyntaxError("The mark '" + name + "' does not exist.");
  }

  class PerformanceTiming {
    constructor(key) {
      if (key !== token) internal.illegal();
    }
    toJSON() {
      const result = {};
      for (const key of Object.getOwnPropertyNames(PerformanceTiming.prototype))
        if (key !== "constructor" && key !== "toJSON") result[key] = this[key];
      return result;
    }
  }
  const legacyTimingNames = ["navigationStart", "unloadEventStart", "unloadEventEnd", "redirectStart",
    "redirectEnd", "fetchStart", "domainLookupStart", "domainLookupEnd", "connectStart", "connectEnd",
    "secureConnectionStart", "requestStart", "responseStart", "responseEnd", "domLoading", "domInteractive",
    "domContentLoadedEventStart", "domContentLoadedEventEnd", "domComplete", "loadEventStart", "loadEventEnd"];
  const legacyAliases = { navigationStart: "startTime", domainLookupStart: "fetchStart", domainLookupEnd: "fetchStart",
    connectStart: "fetchStart", connectEnd: "fetchStart", domLoading: "responseStart" };
  for (const name of legacyTimingNames) {
    Object.defineProperty(PerformanceTiming.prototype, name, {
      get: function () {
        const times = timing();
        const key = legacyAliases[name] || name;
        if (key === "startTime") return Math.round(natives.timeOrigin());
        const value = times[key];
        if (typeof value !== "number" || (value === 0 && key !== "fetchStart")) return 0;
        return Math.round(natives.timeOrigin() + value);
      },
      configurable: true,
      enumerable: true
    });
  }
  internal.finishInterface(PerformanceTiming, "PerformanceTiming");

  class PerformanceNavigation {
    constructor(key) {
      if (key !== token) internal.illegal();
    }
    get type() {
      const type = timing().type;
      return type === "reload" ? 1 : type === "back_forward" ? 2 : 0;
    }
    get redirectCount() { return timing().redirectCount || 0; }
    toJSON() { return { type: this.type, redirectCount: this.redirectCount }; }
  }
  PerformanceNavigation.TYPE_NAVIGATE = 0;
  PerformanceNavigation.TYPE_RELOAD = 1;
  PerformanceNavigation.TYPE_BACK_FORWARD = 2;
  PerformanceNavigation.TYPE_RESERVED = 255;
  internal.finishInterface(PerformanceNavigation, "PerformanceNavigation");

  let timingObject = null;
  let navigationObject = null;

  class Performance extends EventTarget {
    constructor(key) {
      if (key !== token) internal.illegal();
      super();
    }
    now() { return natives.now(); }
    get timeOrigin() { return natives.timeOrigin(); }
    get timing() {
      if (timingObject === null) timingObject = new PerformanceTiming(token);
      return timingObject;
    }
    get navigation() {
      if (navigationObject === null) navigationObject = new PerformanceNavigation(token);
      return navigationObject;
    }
    getEntries() { return allEntries(); }
    getEntriesByType(type) {
      const wanted = String(type);
      return allEntries().filter(function (entry) { return entry.entryType === wanted; });
    }
    getEntriesByName(name, type) {
      const wanted = String(name);
      const wantedType = type === undefined ? undefined : String(type);
      return allEntries().filter(function (entry) {
        return entry.name === wanted && (wantedType === undefined || entry.entryType === wantedType);
      });
    }
    mark(markName, markOptions) {
      const entry = new PerformanceMark(markName, markOptions);
      userEntries.push(entry);
      queueEntry(entry);
      return entry;
    }
    clearMarks(markName) { clearUserEntries("mark", markName); }
    measure(measureName, startOrOptions, endMark) {
      const name = String(measureName);
      let start = 0;
      let end;
      let detail = null;
      if (startOrOptions !== null && typeof startOrOptions === "object") {
        const options = startOrOptions;
        if (endMark !== undefined) throw new TypeError("end mark given with options");
        if (options.start !== undefined && options.end !== undefined && options.duration !== undefined)
          throw new TypeError("start, end and duration cannot all be given");
        if (options.start !== undefined) start = resolveTime(options.start);
        if (options.end !== undefined) end = resolveTime(options.end);
        if (options.duration !== undefined) {
          const duration = Number(options.duration);
          if (options.start !== undefined) end = start + duration;
          else if (end !== undefined) start = end - duration;
        }
        detail = checkDetail(options.detail);
      } else if (startOrOptions !== undefined) start = resolveTime(startOrOptions);
      if (end === undefined) end = endMark !== undefined ? resolveTime(endMark) : natives.now();
      const entry = new PerformanceMeasure(token, { name: name, entryType: "measure", startTime: start,
        duration: end - start, detail: detail });
      userEntries.push(entry);
      queueEntry(entry);
      return entry;
    }
    clearMeasures(measureName) { clearUserEntries("measure", measureName); }
    clearResourceTimings() {}
    setResourceTimingBufferSize(maxSize) {}
    get onresourcetimingbufferfull() { return null; }
    set onresourcetimingbufferfull(value) {}
    toJSON() {
      return { timeOrigin: this.timeOrigin, timing: this.timing.toJSON(), navigation: this.navigation.toJSON() };
    }
  }
  internal.finishInterface(Performance, "Performance");

  function clearUserEntries(type, name) {
    for (let index = userEntries.length - 1; index >= 0; index--)
      if (userEntries[index].entryType === type && (name === undefined || userEntries[index].name === String(name)))
        userEntries.splice(index, 1);
  }

  class PerformanceObserverEntryList {
    constructor(key, entries) {
      if (key !== token) internal.illegal();
      entryData.set(this, entries.slice().sort(byStartTime));
    }
    getEntries() { return data(this).slice(); }
    getEntriesByType(type) {
      return data(this).filter(function (entry) { return entry.entryType === String(type); });
    }
    getEntriesByName(name, type) {
      return data(this).filter(function (entry) {
        return entry.name === String(name) && (type === undefined || entry.entryType === String(type));
      });
    }
  }
  internal.finishInterface(PerformanceObserverEntryList, "PerformanceObserverEntryList");

  const supportedTypes = ["mark", "measure", "navigation"];
  const observerData = new WeakMap();

  class PerformanceObserver {
    constructor(callback) {
      if (typeof callback !== "function") throw new TypeError("The callback provided as parameter 1 is not a function.");
      observerData.set(this, { callback: callback, types: [], buffer: [], queued: false });
    }
    observe(options) {
      const state = observerData.get(this);
      if (state === undefined) throw new TypeError("Illegal invocation");
      const settings = options == null ? {} : options;
      let types;
      if (settings.entryTypes !== undefined) {
        if (settings.type !== undefined) throw new TypeError("type and entryTypes cannot both be given");
        types = Array.from(settings.entryTypes, String);
      } else if (settings.type !== undefined) types = [String(settings.type)];
      else throw new TypeError("observe() needs type or entryTypes");
      types = types.filter(function (type) { return supportedTypes.indexOf(type) >= 0; });
      for (const type of types) if (state.types.indexOf(type) < 0) state.types.push(type);
      if (observers.indexOf(this) < 0) observers.push(this);
      if (settings.buffered)
        for (const entry of allEntries()) if (types.indexOf(entry.entryType) >= 0) queueEntry(entry);
    }
    disconnect() {
      const index = observers.indexOf(this);
      if (index >= 0) observers.splice(index, 1);
      const state = observerData.get(this);
      if (state) { state.types = []; state.buffer = []; }
    }
    takeRecords() {
      const state = observerData.get(this);
      return state ? state.buffer.splice(0) : [];
    }
    static get supportedEntryTypes() { return supportedTypes.slice(); }
  }
  internal.finishInterface(PerformanceObserver, "PerformanceObserver");

  let performanceObject = null;
  internal.defineGetter(global, "performance", function () {
    if (performanceObject === null) performanceObject = new Performance(token);
    return performanceObject;
  });
})
