// IndexedDB keys, key ranges and key paths (Indexed Database API 3.0,
// 2.8-2.10 and 7). A key is kept as a "binary string": one character per
// byte of its encoding (see Web.IndexedDb.Keys), so that comparing two
// keys is comparing two strings and the service gets the same bytes.
//
//   number  10 + 8 bytes   date   20 + 8 bytes (the time value)
//   string  30 + code units (1 to 3 bytes each, never 0) + 0
//   binary  40 + bytes (1 or 2 bytes each, never 0) + 0
//   array   50 + items + 0
//
// internal.idbKeys has the conversions the other IndexedDB scripts use:
// encode (a value to a key, null when it is not a valid key), decode,
// keyPath checks, evaluation and key injection.
(function (natives, global, internal) {
  "use strict";
  const token = internal.token;
  const TagNumber = 0x10;
  const TagDate = 0x20;
  const TagString = 0x30;
  const TagBinary = 0x40;
  const TagArray = 0x50;
  const getTime = Date.prototype.getTime;
  const isArray = Array.isArray;
  const hasOwn = Object.prototype.hasOwnProperty;
  const detachedOf = Object.getOwnPropertyDescriptor(ArrayBuffer.prototype, "detached");
  const scratch = new DataView(new ArrayBuffer(8));
  const fromCharCode = String.fromCharCode;

  function dataError(message) {
    return new DOMException(message, "DataError");
  }

  function pushDouble(out, tag, value) {
    if (value === 0) value = 0;
    scratch.setFloat64(0, value);
    const negative = (scratch.getUint8(0) & 0x80) !== 0;
    out.push(tag);
    for (let index = 0; index < 8; index++) {
      let byte = scratch.getUint8(index);
      if (negative) byte = 255 - byte;
      else if (index === 0) byte = byte ^ 0x80;
      out.push(byte);
    }
  }

  function pushUnit(out, unit) {
    if (unit < 0x7f) out.push(unit + 1);
    else if (unit < 0x407f) {
      const value = unit - 0x7f;
      out.push(0x80 | (value >> 8), value & 255);
    } else out.push(0xc0 | (unit >> 10), (unit >> 2) & 255, (unit & 3) << 6);
  }

  function isDetached(buffer) {
    return detachedOf !== undefined && detachedOf.get.call(buffer);
  }

  function bufferBytesOf(value) {
    if (value instanceof ArrayBuffer) {
      if (isDetached(value)) return null;
      return new Uint8Array(value);
    }
    if (ArrayBuffer.isView(value)) {
      if (value.buffer instanceof ArrayBuffer && isDetached(value.buffer)) return null;
      return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
    }
    return undefined;
  }

  // "convert a value to a key": false when the value is not a valid key.
  function encodeInto(value, out, seen) {
    if (typeof value === "number") {
      if (value !== value) return false;
      pushDouble(out, TagNumber, value);
      return true;
    }
    if (typeof value === "string") {
      out.push(TagString);
      for (let index = 0; index < value.length; index++) pushUnit(out, value.charCodeAt(index));
      out.push(0);
      return true;
    }
    if (value === null || typeof value !== "object") return false;
    if (value instanceof Date) {
      const time = getTime.call(value);
      if (time !== time) return false;
      pushDouble(out, TagDate, time);
      return true;
    }
    const bytes = bufferBytesOf(value);
    if (bytes === null) return false;
    if (bytes !== undefined) {
      out.push(TagBinary);
      for (let index = 0; index < bytes.length; index++) pushUnit(out, bytes[index]);
      out.push(0);
      return true;
    }
    if (isArray(value)) {
      if (seen.indexOf(value) >= 0) return false;
      seen.push(value);
      out.push(TagArray);
      const length = value.length;
      for (let index = 0; index < length; index++) {
        if (!hasOwn.call(value, index)) return false;
        if (!encodeInto(value[index], out, seen)) return false;
      }
      seen.pop();
      out.push(0);
      return true;
    }
    return false;
  }

  function codesToString(codes) {
    let text = "";
    for (let index = 0; index < codes.length; index += 4096)
      text += fromCharCode.apply(null, codes.slice(index, index + 4096));
    return text;
  }

  function encode(value) {
    const out = [];
    if (!encodeInto(value, out, [])) return null;
    return codesToString(out);
  }

  // A multiEntry index's keys of a value (7.4): each valid item once.
  function encodeMultiEntry(value) {
    if (!isArray(value)) {
      const key = encode(value);
      return key === null ? [] : [key];
    }
    const keys = [];
    for (let index = 0; index < value.length; index++) {
      if (!hasOwn.call(value, index)) continue;
      const key = encode(value[index]);
      if (key !== null && keys.indexOf(key) < 0) keys.push(key);
    }
    return keys;
  }

  function readDouble(key, position) {
    const negative = (key.charCodeAt(position) & 0x80) === 0;
    for (let index = 0; index < 8; index++) {
      let byte = key.charCodeAt(position + index);
      if (negative) byte = 255 - byte;
      else if (index === 0) byte = byte ^ 0x80;
      scratch.setUint8(index, byte);
    }
    return scratch.getFloat64(0);
  }

  function readUnit(key, position) {
    const first = key.charCodeAt(position);
    if (first < 0x80) return [first - 1, position + 1];
    if (first < 0xc0) return [(((first & 0x3f) << 8) | key.charCodeAt(position + 1)) + 0x7f, position + 2];
    return [((first & 0x3f) << 10) | (key.charCodeAt(position + 1) << 2) | (key.charCodeAt(position + 2) >> 6),
      position + 3];
  }

  // "convert a key to a value": [value, position after it].
  function decodeAt(key, position) {
    const tag = key.charCodeAt(position);
    if (tag === TagNumber) return [readDouble(key, position + 1), position + 9];
    if (tag === TagDate) return [new Date(readDouble(key, position + 1)), position + 9];
    if (tag === TagString || tag === TagBinary) {
      const units = [];
      position++;
      while (key.charCodeAt(position) !== 0) {
        const pair = readUnit(key, position);
        units.push(pair[0]);
        position = pair[1];
      }
      if (tag === TagString) return [codesToString(units), position + 1];
      return [new Uint8Array(units).buffer, position + 1];
    }
    if (tag === TagArray) {
      const items = [];
      position++;
      while (key.charCodeAt(position) !== 0) {
        const pair = decodeAt(key, position);
        items.push(pair[0]);
        position = pair[1];
      }
      return [items, position + 1];
    }
    throw new DOMException("The stored key is damaged.", "UnknownError");
  }

  function decode(key) {
    return decodeAt(key, 0)[0];
  }

  function compare(a, b) {
    return a < b ? -1 : (a > b ? 1 : 0);
  }

  function isNumberKey(key) {
    return key.charCodeAt(0) === TagNumber;
  }

  // ---- key paths (2.10, 7.1-7.3) ----

  const identifierPattern = /^[$A-Za-z_\u00aa-\uffff][$A-Za-z0-9_\u00aa-\uffff\u200c\u200d]*$/;

  function validStringKeyPath(path) {
    if (path === "") return true;
    const parts = path.split(".");
    for (const part of parts) if (!identifierPattern.test(part)) return false;
    return true;
  }

  // The key path of an IDL value (DOMString or sequence<DOMString>):
  // null when it is not valid.
  function normalizeKeyPath(value) {
    if (isArray(value) || (value !== null && typeof value === "object" && typeof value[Symbol.iterator] === "function" &&
      typeof value !== "string" && !(value instanceof String))) {
      const paths = [];
      for (const item of value) paths.push(String(item));
      if (paths.length === 0) return null;
      for (const path of paths) if (!validStringKeyPath(path)) return null;
      return paths;
    }
    const path = String(value);
    return validStringKeyPath(path) ? path : null;
  }

  // "evaluate a key path on a value": { value } or null (failure).
  function evaluateString(value, path) {
    if (path === "") return { value: value };
    const parts = path.split(".");
    for (const part of parts) {
      if (typeof value === "string" && part === "length") value = value.length;
      else if (isArray(value) && part === "length") value = value.length;
      else if (typeof global.Blob === "function" && value instanceof global.Blob && (part === "size" ||
        part === "type")) value = value[part];
      else if (typeof global.File === "function" && value instanceof global.File && (part === "name" ||
        part === "lastModified")) value = value[part];
      else if (typeof global.File === "function" && value instanceof global.File && part === "lastModifiedDate")
        value = new Date(value.lastModified);
      else {
        if (value === null || typeof value !== "object") return null;
        if (!hasOwn.call(value, part)) return null;
        value = value[part];
      }
    }
    return { value: value };
  }

  function evaluate(value, path) {
    if (typeof path === "string") return evaluateString(value, path);
    const result = [];
    for (const item of path) {
      const one = evaluateString(value, item);
      if (one === null) return null;
      result.push(one.value);
    }
    return { value: result };
  }

  // "extract a key from a value using a key path": a key, null when the
  // path does not reach a value, false when the value is not a key.
  function extractKey(value, path) {
    const result = evaluate(value, path);
    if (result === null) return null;
    const key = encode(result.value);
    return key === null ? false : key;
  }

  // The index keys of a value (7.4 with multiEntry).
  function indexKeys(value, path, multiEntry) {
    const result = evaluate(value, path);
    if (result === null) return [];
    if (multiEntry && typeof path === "string") return encodeMultiEntry(result.value);
    const key = encode(result.value);
    return key === null ? [] : [key];
  }

  function canInjectKey(value, path) {
    const parts = path.split(".");
    parts.pop();
    for (const part of parts) {
      if (value === null || typeof value !== "object") return false;
      if (!hasOwn.call(value, part)) return true;
      value = value[part];
    }
    return value !== null && typeof value === "object";
  }

  function injectKey(value, path, key) {
    const parts = path.split(".");
    const last = parts.pop();
    for (const part of parts) {
      if (!hasOwn.call(value, part))
        Object.defineProperty(value, part, { value: {}, writable: true, enumerable: true, configurable: true });
      value = value[part];
    }
    Object.defineProperty(value, last, { value: decode(key), writable: true, enumerable: true, configurable: true });
  }

  // ---- IDBKeyRange ----

  const rangeData = new WeakMap();
  function rangeState(object) {
    const state = rangeData.get(object);
    if (state === undefined) throw new TypeError("Illegal invocation");
    return state;
  }
  function keyOrThrow(value, what) {
    const key = encode(value);
    if (key === null) throw dataError("Failed to execute '" + what + "' on 'IDBKeyRange': The parameter is not a " +
      "valid key.");
    return key;
  }
  function makeRange(lower, upper, lowerOpen, upperOpen) {
    const range = new IDBKeyRange(token);
    rangeData.set(range, { lower: lower, upper: upper, lowerOpen: !!lowerOpen, upperOpen: !!upperOpen });
    return range;
  }

  class IDBKeyRange {
    constructor(key) {
      if (key !== token) internal.illegal();
    }
    get lower() {
      const state = rangeState(this);
      return state.lower === null ? undefined : decode(state.lower);
    }
    get upper() {
      const state = rangeState(this);
      return state.upper === null ? undefined : decode(state.upper);
    }
    get lowerOpen() { return rangeState(this).lowerOpen; }
    get upperOpen() { return rangeState(this).upperOpen; }
    includes(key) {
      if (arguments.length < 1) throw new TypeError("Failed to execute 'includes' on 'IDBKeyRange': 1 argument " +
        "required, but only 0 present.");
      return rangeIncludes(rangeState(this), keyOrThrow(key, "includes"));
    }
    static only(value) {
      if (arguments.length < 1) throw new TypeError("Failed to execute 'only' on 'IDBKeyRange': 1 argument " +
        "required, but only 0 present.");
      const key = keyOrThrow(value, "only");
      return makeRange(key, key, false, false);
    }
    static lowerBound(lower, open) {
      if (arguments.length < 1) throw new TypeError("Failed to execute 'lowerBound' on 'IDBKeyRange': 1 argument " +
        "required, but only 0 present.");
      return makeRange(keyOrThrow(lower, "lowerBound"), null, open, true);
    }
    static upperBound(upper, open) {
      if (arguments.length < 1) throw new TypeError("Failed to execute 'upperBound' on 'IDBKeyRange': 1 argument " +
        "required, but only 0 present.");
      return makeRange(null, keyOrThrow(upper, "upperBound"), true, open);
    }
    static bound(lower, upper, lowerOpen, upperOpen) {
      if (arguments.length < 2) throw new TypeError("Failed to execute 'bound' on 'IDBKeyRange': 2 arguments " +
        "required, but only " + arguments.length + " present.");
      const low = keyOrThrow(lower, "bound");
      const high = keyOrThrow(upper, "bound");
      if (low > high) throw dataError("Failed to execute 'bound' on 'IDBKeyRange': The lower key is greater than " +
        "the upper key.");
      if (low === high && (lowerOpen || upperOpen)) throw dataError("Failed to execute 'bound' on 'IDBKeyRange': " +
        "The lower key and upper key are equal and one of the bounds is open.");
      return makeRange(low, high, lowerOpen, upperOpen);
    }
  }
  internal.finishInterface(IDBKeyRange, "IDBKeyRange");

  function rangeIncludes(state, key) {
    if (state.lower !== null && (key < state.lower || (key === state.lower && state.lowerOpen))) return false;
    if (state.upper !== null && (key > state.upper || (key === state.upper && state.upperOpen))) return false;
    return true;
  }

  // "convert a value to a key range" (null and undefined are unbounded
  // unless null is refused).
  function rangeOf(value, refuseNull, what) {
    if (value instanceof IDBKeyRange) return rangeState(value);
    if (value === undefined || (value === null && !refuseNull))
      return { lower: null, upper: null, lowerOpen: true, upperOpen: true };
    const key = encode(value);
    if (key === null) throw dataError("Failed to execute '" + what + "': The parameter is not a valid key.");
    return { lower: key, upper: key, lowerOpen: false, upperOpen: false };
  }

  internal.idbKeys = {
    encode: encode,
    decode: decode,
    compare: compare,
    isNumberKey: isNumberKey,
    normalizeKeyPath: normalizeKeyPath,
    evaluate: evaluate,
    extractKey: extractKey,
    indexKeys: indexKeys,
    canInjectKey: canInjectKey,
    injectKey: injectKey,
    rangeOf: rangeOf,
    rangeIncludes: rangeIncludes,
    isRange: function (value) { return value instanceof IDBKeyRange; },
    dataError: dataError
  };
})
