// StructuredSerialize and StructuredDeserialize (HTML Standard 2.7.3,
// 2.7.4) to text, for values that go to another heap: a shared or
// service worker, a page through a BroadcastChannel, the Cache API's
// store. The record is JSON of a tagged tree in which each object has an
// index (later references to it, cycles included, are by index):
// primitives (with -0, NaN, the infinities and BigInt), arrays and plain
// objects (own enumerable string keys), Boolean, Number, String and
// BigInt objects, Date, RegExp, Map, Set, the native errors, ArrayBuffer,
// the typed arrays and DataView (sharing their buffer), Blob and File,
// and transferred MessagePorts (by their index in the transfer list).
// Anything else - functions, symbols, platform objects - is a
// DataCloneError. Values of other realms (a worker scope's) are read by
// their internal tags, not by instanceof.
(function (natives, global, internal) {
  "use strict";
  const toString = Object.prototype.toString;
  // Taken now: page script may replace the globals.
  const BlobClass = global.Blob;
  const FileClass = global.File;
  const errorNames = ["Error", "EvalError", "RangeError", "ReferenceError", "SyntaxError", "TypeError", "URIError"];
  const viewKinds = ["Int8Array", "Uint8Array", "Uint8ClampedArray", "Int16Array", "Uint16Array", "Int32Array",
    "Uint32Array", "Float32Array", "Float64Array", "BigInt64Array", "BigUint64Array", "DataView"];

  function refuse(what) {
    throw new DOMException("Failed to execute 'postMessage': " + what + " could not be cloned.", "DataCloneError");
  }

  // Bytes as base64 (in pieces: fromCharCode takes a bounded argument list).
  function bytesToBase64(bytes) {
    let text = "";
    for (let offset = 0; offset < bytes.length; offset += 8192)
      text += String.fromCharCode.apply(null, bytes.subarray(offset, offset + 8192));
    return btoa(text);
  }
  function base64ToBytes(text) {
    const binary = atob(text);
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index++) bytes[index] = binary.charCodeAt(index);
    return bytes;
  }
  internal.bytesToBase64 = bytesToBase64;
  internal.base64ToBytes = base64ToBytes;

  function serializePrimitive(value) {
    switch (typeof value) {
      case "undefined": return ["u"];
      case "number":
        if (Number.isNaN(value)) return ["n", "NaN"];
        if (value === Infinity) return ["n", "Infinity"];
        if (value === -Infinity) return ["n", "-Infinity"];
        if (value === 0 && 1 / value < 0) return ["n", "-0"];
        return value;
      case "bigint": return ["i", value.toString()];
      case "symbol": refuse("A symbol");
      case "function": refuse("A function");
      default: return value;
    }
  }

  function serializeWith(value, ports, memory) {
    if (value === null) return null;
    if (typeof value !== "object") {
      if (typeof value === "string") return ["s", value];
      return serializePrimitive(value);
    }
    if (memory.has(value)) return ["r", memory.get(value)];
    const index = memory.size;
    memory.set(value, index);
    if (internal.isMessagePort(value)) {
      const at = ports.indexOf(value);
      if (at < 0) refuse("A MessagePort that is not transferred");
      return ["P", index, at];
    }
    if (value instanceof BlobClass) {
      const bytes = bytesToBase64(internal.blobBytes(value));
      if (value instanceof FileClass)
        return ["F", index, bytes, value.type, value.name, value.lastModified];
      return ["L", index, bytes, value.type];
    }
    if (Array.isArray(value)) {
      const entries = [];
      for (const key of Object.keys(value)) entries.push([key, serializeWith(value[key], ports, memory)]);
      return ["a", index, value.length, entries];
    }
    const tag = toString.call(value).slice(8, -1);
    switch (tag) {
      case "Boolean": return ["B", index, Boolean.prototype.valueOf.call(value)];
      case "Number": return ["N", index, serializePrimitive(Number.prototype.valueOf.call(value))];
      case "String": return ["S", index, String.prototype.valueOf.call(value)];
      case "BigInt": return ["I", index, BigInt.prototype.valueOf.call(value).toString()];
      case "Date": return ["D", index, serializePrimitive(Date.prototype.getTime.call(value))];
      case "RegExp": return ["R", index, value.source, value.flags];
      case "ArrayBuffer": return ["A", index, bytesToBase64(new Uint8Array(value))];
      case "Map": {
        const entries = [];
        for (const [key, item] of value)
          entries.push([serializeWith(key, ports, memory), serializeWith(item, ports, memory)]);
        return ["M", index, entries];
      }
      case "Set": {
        const entries = [];
        for (const item of value) entries.push(serializeWith(item, ports, memory));
        return ["T", index, entries];
      }
      case "Error": {
        let name = "Error";
        try {
          const prototypeName = value.name;
          if (errorNames.indexOf(prototypeName) >= 0) name = prototypeName;
        } catch (error) {}
        const message = Object.prototype.hasOwnProperty.call(value, "message") ? String(value.message) : undefined;
        return ["E", index, name, message === undefined ? null : message,
          typeof value.stack === "string" ? value.stack : null];
      }
      case "Object":
        break;
      default:
        if (viewKinds.indexOf(tag) >= 0 && ArrayBuffer.isView(value)) {
          const buffer = serializeWith(value.buffer, ports, memory);
          const length = tag === "DataView" ? value.byteLength : value.length;
          return ["V", index, tag, buffer, value.byteOffset, length];
        }
        refuse(tag === "Object" ? "An object" : "A " + tag);
    }
    // An ordinary object (a class's instance too) keeps its own data.
    const entries = [];
    for (const key of Object.keys(value)) entries.push([key, serializeWith(value[key], ports, memory)]);
    return ["o", index, entries];
  }

  // The text of Value; Ports: the MessagePorts transferred with it.
  internal.serializeMessage = function (value, ports) {
    return JSON.stringify(serializeWith(value, ports || [], new Map()));
  };

  function special(text) {
    switch (text) {
      case "NaN": return NaN;
      case "Infinity": return Infinity;
      case "-Infinity": return -Infinity;
      default: return -0;
    }
  }

  function primitiveOf(node) {
    if (!Array.isArray(node)) return node;
    if (node[0] === "u") return undefined;
    if (node[0] === "n") return special(node[1]);
    if (node[0] === "i") return BigInt(node[1]);
    if (node[0] === "s") return node[1];
    throw new TypeError("malformed serialization");
  }

  function deserializeWith(node, ports, memory) {
    if (!Array.isArray(node)) return node;
    const kind = node[0];
    if (kind === "u" || kind === "n" || kind === "i" || kind === "s") return primitiveOf(node);
    if (kind === "r") return memory[node[1]];
    const index = node[1];
    let result;
    switch (kind) {
      case "P":
        result = ports[node[2]];
        break;
      case "L":
        result = internal.makeBlob(base64ToBytes(node[2]), node[3]);
        break;
      case "F":
        result = new FileClass([base64ToBytes(node[2])], node[4], { type: node[3], lastModified: node[5] });
        break;
      case "a":
        result = new Array(node[2]);
        memory[index] = result;
        for (const [key, item] of node[3]) result[key] = deserializeWith(item, ports, memory);
        return result;
      case "o":
        result = {};
        memory[index] = result;
        for (const [key, item] of node[2]) result[key] = deserializeWith(item, ports, memory);
        return result;
      case "B": result = new Boolean(node[2]); break;
      case "N": result = new Number(primitiveOf(node[2])); break;
      case "S": result = new String(node[2]); break;
      case "I": result = Object(BigInt(node[2])); break;
      case "D": result = new Date(primitiveOf(node[2])); break;
      case "R": result = new RegExp(node[2], node[3]); break;
      case "A": result = base64ToBytes(node[2]).buffer; break;
      case "M":
        result = new Map();
        memory[index] = result;
        for (const [key, item] of node[2])
          result.set(deserializeWith(key, ports, memory), deserializeWith(item, ports, memory));
        return result;
      case "T":
        result = new Set();
        memory[index] = result;
        for (const item of node[2]) result.add(deserializeWith(item, ports, memory));
        return result;
      case "E": {
        const Constructor = errorNames.indexOf(node[2]) >= 0 ? global[node[2]] : Error;
        result = node[3] === null ? new Constructor() : new Constructor(node[3]);
        if (node[4] !== null)
          Object.defineProperty(result, "stack", { value: node[4], writable: true, configurable: true });
        break;
      }
      case "V": {
        const buffer = deserializeWith(node[3], ports, memory);
        const Constructor = global[node[2]];
        if (viewKinds.indexOf(node[2]) < 0 || typeof Constructor !== "function")
          throw new TypeError("malformed serialization");
        result = new Constructor(buffer, node[4], node[5]);
        break;
      }
      default:
        throw new TypeError("malformed serialization");
    }
    memory[index] = result;
    return result;
  }

  // The value of a serialization; Ports: the MessagePorts made here for
  // the ones transferred.
  internal.deserializeMessage = function (text, ports) {
    return deserializeWith(JSON.parse(text), ports || [], []);
  };
})
