// StructuredSerializeForStorage and StructuredDeserialize (HTML Standard
// 2.7.3, 2.7.6) to and from bytes: what IndexedDB and the Cache API keep.
// Serializable: primitives (strings keep lone surrogates), Boolean,
// Number, BigInt and String objects, Date, RegExp, ArrayBuffer (also
// resizable ones), typed arrays and DataView (sharing a buffer stays
// shared), Map, Set, arrays (holes and extra properties too), plain
// objects, the native errors, DOMException, Blob and File (their bytes
// with them), with cycles and shared references. Anything else - a
// function, a symbol, a SharedArrayBuffer, a node, a WeakMap - is a
// DataCloneError, as is a detached buffer.
//
// The bytes: a version byte, then one value: a tag byte and its data;
// integers are 32-bit and doubles 64-bit little-endian, strings a
// length and either a byte per code unit (when every unit is below 256)
// or two. Objects are numbered in the order they are first met; a later
// meeting is a reference to that number.
(function (natives, global, internal) {
  "use strict";
  const Version = 1;
  const T = {
    Undefined: 0, Null: 1, False: 2, True: 3, Number: 4, BigInt: 5, String8: 6, String16: 7,
    BooleanObject: 16, NumberObject: 17, BigIntObject: 18, StringObject: 19, Date: 20, RegExp: 21,
    ArrayBuffer: 22, View: 23, Map: 24, Set: 25, Array: 26, Object: 27, Error: 28, Blob: 29, File: 30,
    DOMException: 31, ResizableArrayBuffer: 32, Reference: 48
  };
  const viewKinds = ["Int8Array", "Uint8Array", "Uint8ClampedArray", "Int16Array", "Uint16Array", "Int32Array",
    "Uint32Array", "Float32Array", "Float64Array", "BigInt64Array", "BigUint64Array", "DataView", "Float16Array"];
  const errorNames = ["Error", "EvalError", "RangeError", "ReferenceError", "SyntaxError", "TypeError", "URIError"];
  const toStringOf = Object.prototype.toString;
  const getTime = Date.prototype.getTime;
  const isView = ArrayBuffer.isView;
  const typedArrayPrototype = Object.getPrototypeOf(Int8Array.prototype);
  const typedArrayTag = Object.getOwnPropertyDescriptor(typedArrayPrototype, Symbol.toStringTag).get;
  const bufferByteLength = Object.getOwnPropertyDescriptor(ArrayBuffer.prototype, "byteLength").get;
  const resizableOf = Object.getOwnPropertyDescriptor(ArrayBuffer.prototype, "resizable");
  const maxByteLengthOf = Object.getOwnPropertyDescriptor(ArrayBuffer.prototype, "maxByteLength");
  const detachedOf = Object.getOwnPropertyDescriptor(ArrayBuffer.prototype, "detached");
  const SharedBuffer = global.SharedArrayBuffer;

  function refuse(what) {
    throw new DOMException(what + " could not be cloned.", "DataCloneError");
  }

  // ---- writing ----

  class Writer {
    constructor() {
      this.bytes = new Uint8Array(256);
      this.view = new DataView(this.bytes.buffer);
      this.length = 0;
    }
    reserve(count) {
      if (this.length + count <= this.bytes.length) return;
      let capacity = this.bytes.length * 2;
      while (capacity < this.length + count) capacity *= 2;
      const bigger = new Uint8Array(capacity);
      bigger.set(this.bytes.subarray(0, this.length));
      this.bytes = bigger;
      this.view = new DataView(bigger.buffer);
    }
    byte(value) {
      this.reserve(1);
      this.bytes[this.length++] = value;
    }
    u32(value) {
      this.reserve(4);
      this.view.setUint32(this.length, value, true);
      this.length += 4;
    }
    f64(value) {
      this.reserve(8);
      this.view.setFloat64(this.length, value, true);
      this.length += 8;
    }
    raw(bytes) {
      this.u32(bytes.length);
      this.reserve(bytes.length);
      this.bytes.set(bytes, this.length);
      this.length += bytes.length;
    }
    string(text) {
      const count = text.length;
      let wide = false;
      for (let index = 0; index < count; index++) {
        if (text.charCodeAt(index) > 255) {
          wide = true;
          break;
        }
      }
      this.byte(wide ? T.String16 : T.String8);
      this.u32(count);
      if (wide) {
        this.reserve(count * 2);
        for (let index = 0; index < count; index++) {
          const unit = text.charCodeAt(index);
          this.bytes[this.length++] = unit & 255;
          this.bytes[this.length++] = unit >> 8;
        }
      } else {
        this.reserve(count);
        for (let index = 0; index < count; index++) this.bytes[this.length++] = text.charCodeAt(index);
      }
    }
    result() {
      return this.bytes.slice(0, this.length);
    }
  }

  function isDetached(buffer) {
    if (detachedOf !== undefined) return detachedOf.get.call(buffer);
    return false;
  }

  function blobKind(value) {
    if (typeof global.File === "function" && value instanceof global.File) return "File";
    if (typeof global.Blob === "function" && value instanceof global.Blob) return "Blob";
    return null;
  }

  function serialize(value, writer, memory) {
    switch (typeof value) {
      case "undefined": writer.byte(T.Undefined); return;
      case "boolean": writer.byte(value ? T.True : T.False); return;
      case "number": writer.byte(T.Number); writer.f64(value); return;
      case "bigint": writer.byte(T.BigInt); writer.string(value.toString(16)); return;
      case "string": writer.string(value); return;
      case "symbol": refuse("A symbol");
      case "function": refuse("A function");
    }
    if (value === null) {
      writer.byte(T.Null);
      return;
    }
    const seen = memory.get(value);
    if (seen !== undefined) {
      writer.byte(T.Reference);
      writer.u32(seen);
      return;
    }
    memory.set(value, memory.size);
    if (Array.isArray(value)) {
      writer.byte(T.Array);
      writer.u32(value.length);
      properties(value, writer, memory);
      return;
    }
    if (value instanceof ArrayBuffer) {
      if (isDetached(value)) refuse("A detached ArrayBuffer");
      const resizable = resizableOf !== undefined && resizableOf.get.call(value);
      writer.byte(resizable ? T.ResizableArrayBuffer : T.ArrayBuffer);
      writer.raw(new Uint8Array(value, 0, bufferByteLength.call(value)));
      if (resizable) writer.f64(maxByteLengthOf.get.call(value));
      return;
    }
    if (SharedBuffer !== undefined && value instanceof SharedBuffer) refuse("A SharedArrayBuffer");
    if (isView(value)) {
      const kind = value instanceof DataView ? "DataView" : typedArrayTag.call(value);
      const index = viewKinds.indexOf(kind);
      if (index < 0) refuse(String(kind));
      if (value.buffer instanceof ArrayBuffer && isDetached(value.buffer)) refuse("A detached ArrayBuffer");
      writer.byte(T.View);
      writer.byte(index);
      serialize(value.buffer, writer, memory);
      writer.f64(value.byteOffset);
      writer.f64(kind === "DataView" ? value.byteLength : value.length);
      return;
    }
    const blob = blobKind(value);
    if (blob !== null) {
      const bytes = internal.blobBytes(value);
      writer.byte(blob === "File" ? T.File : T.Blob);
      writer.string(value.type);
      if (blob === "File") {
        writer.string(value.name);
        writer.f64(value.lastModified);
      }
      writer.raw(bytes);
      return;
    }
    if (typeof global.DOMException === "function" && value instanceof global.DOMException) {
      writer.byte(T.DOMException);
      writer.string(String(value.name));
      writer.string(String(value.message));
      return;
    }
    const tag = toStringOf.call(value);
    switch (tag) {
      case "[object Boolean]": writer.byte(T.BooleanObject); writer.byte(value.valueOf() ? 1 : 0); return;
      case "[object Number]": writer.byte(T.NumberObject); writer.f64(Number.prototype.valueOf.call(value)); return;
      case "[object BigInt]": writer.byte(T.BigIntObject); writer.string(BigInt.prototype.valueOf.call(value).toString(16)); return;
      case "[object String]": writer.byte(T.StringObject); writer.string(String.prototype.valueOf.call(value)); return;
      case "[object Date]": writer.byte(T.Date); writer.f64(getTime.call(value)); return;
      case "[object RegExp]":
        writer.byte(T.RegExp);
        writer.string(value.source);
        writer.string(value.flags);
        return;
      case "[object Map]": {
        const entries = [];
        Map.prototype.forEach.call(value, function (item, key) { entries.push(key, item); });
        writer.byte(T.Map);
        writer.u32(entries.length / 2);
        for (const item of entries) serialize(item, writer, memory);
        return;
      }
      case "[object Set]": {
        const items = [];
        Set.prototype.forEach.call(value, function (item) { items.push(item); });
        writer.byte(T.Set);
        writer.u32(items.length);
        for (const item of items) serialize(item, writer, memory);
        return;
      }
      case "[object Error]": {
        let name = value.name;
        if (errorNames.indexOf(name) < 0) name = "Error";
        const message = Object.getOwnPropertyDescriptor(value, "message");
        writer.byte(T.Error);
        writer.string(name);
        writer.byte(message !== undefined && "value" in message ? 1 : 0);
        if (message !== undefined && "value" in message) writer.string(String(message.value));
        return;
      }
      case "[object Object]":
        if (isPlainEnough(value)) {
          writer.byte(T.Object);
          properties(value, writer, memory);
          return;
        }
    }
    refuse(tag.slice(8, -1) === "Object" ? "The object" : tag.slice(8, -1));
  }

  // Platform objects (anything made by a binding or a platform class)
  // are not plain: only ordinary objects are serialized property by
  // property.
  function isPlainEnough(value) {
    if (typeof global.Node === "function" && value instanceof global.Node) return false;
    if (typeof global.EventTarget === "function" && value instanceof global.EventTarget) return false;
    if (value instanceof Promise || value instanceof WeakMap || value instanceof WeakSet) return false;
    if (typeof global.WeakRef === "function" && value instanceof global.WeakRef) return false;
    return true;
  }

  function properties(value, writer, memory) {
    const keys = Object.keys(value);
    writer.u32(keys.length);
    for (const key of keys) {
      writer.string(key);
      serialize(value[key], writer, memory);
    }
  }

  internal.ByteWriter = Writer;

  internal.structuredSerialize = function (value) {
    const writer = new Writer();
    writer.byte(Version);
    serialize(value, writer, new Map());
    return writer.result();
  };

  // ---- reading ----

  class Reader {
    constructor(bytes) {
      this.bytes = bytes;
      this.view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
      this.position = 0;
    }
    need(count) {
      if (this.position + count > this.bytes.length) throw new DOMException("The stored value is damaged.",
        "DataCloneError");
    }
    byte() {
      this.need(1);
      return this.bytes[this.position++];
    }
    u32() {
      this.need(4);
      const value = this.view.getUint32(this.position, true);
      this.position += 4;
      return value;
    }
    f64() {
      this.need(8);
      const value = this.view.getFloat64(this.position, true);
      this.position += 8;
      return value;
    }
    raw() {
      const count = this.u32();
      this.need(count);
      const bytes = this.bytes.slice(this.position, this.position + count);
      this.position += count;
      return bytes;
    }
    string() {
      const tag = this.byte();
      return this.stringBody(tag);
    }
    stringBody(tag) {
      const count = this.u32();
      const width = tag === T.String16 ? 2 : 1;
      this.need(count * width);
      let text = "";
      let chunk = [];
      for (let index = 0; index < count; index++) {
        let unit;
        if (width === 1) unit = this.bytes[this.position++];
        else {
          unit = this.bytes[this.position] | (this.bytes[this.position + 1] << 8);
          this.position += 2;
        }
        chunk.push(unit);
        if (chunk.length === 4096) {
          text += String.fromCharCode.apply(null, chunk);
          chunk = [];
        }
      }
      if (chunk.length > 0) text += String.fromCharCode.apply(null, chunk);
      return text;
    }
  }

  function viewOf(kind, buffer, offset, length) {
    const name = viewKinds[kind];
    const Constructor = global[name];
    if (typeof Constructor !== "function") throw new DOMException("The stored value is damaged.", "DataCloneError");
    return new Constructor(buffer, offset, length);
  }

  function deserialize(reader, memory) {
    const tag = reader.byte();
    switch (tag) {
      case T.Undefined: return undefined;
      case T.Null: return null;
      case T.False: return false;
      case T.True: return true;
      case T.Number: return reader.f64();
      case T.BigInt: return bigIntOf(reader.string());
      case T.String8:
      case T.String16: return reader.stringBody(tag);
      case T.Reference: {
        const index = reader.u32();
        if (index >= memory.length) throw new DOMException("The stored value is damaged.", "DataCloneError");
        return memory[index];
      }
    }
    const slot = memory.length;
    memory.push(undefined);
    let value;
    switch (tag) {
      case T.BooleanObject: value = new Boolean(reader.byte() !== 0); break;
      case T.NumberObject: value = new Number(reader.f64()); break;
      case T.BigIntObject: value = Object(bigIntOf(reader.string())); break;
      case T.StringObject: value = new String(reader.string()); break;
      case T.Date: value = new Date(reader.f64()); break;
      case T.RegExp: {
        const source = reader.string();
        value = new RegExp(source, reader.string());
        break;
      }
      case T.ArrayBuffer: value = reader.raw().buffer; break;
      case T.ResizableArrayBuffer: {
        const bytes = reader.raw();
        const maximum = reader.f64();
        value = new ArrayBuffer(bytes.length, { maxByteLength: maximum });
        new Uint8Array(value).set(bytes);
        break;
      }
      case T.View: {
        const kind = reader.byte();
        const buffer = deserialize(reader, memory);
        const offset = reader.f64();
        value = viewOf(kind, buffer, offset, reader.f64());
        break;
      }
      case T.Map: {
        value = new Map();
        memory[slot] = value;
        const count = reader.u32();
        for (let index = 0; index < count; index++) {
          const key = deserialize(reader, memory);
          value.set(key, deserialize(reader, memory));
        }
        return value;
      }
      case T.Set: {
        value = new Set();
        memory[slot] = value;
        const count = reader.u32();
        for (let index = 0; index < count; index++) value.add(deserialize(reader, memory));
        return value;
      }
      case T.Array: {
        value = new Array(reader.u32());
        memory[slot] = value;
        readProperties(reader, value, memory);
        return value;
      }
      case T.Object: {
        value = {};
        memory[slot] = value;
        readProperties(reader, value, memory);
        return value;
      }
      case T.Error: {
        const name = reader.string();
        const hasMessage = reader.byte() !== 0;
        const message = hasMessage ? reader.string() : undefined;
        const Constructor = errorNames.indexOf(name) >= 0 ? global[name] : Error;
        value = hasMessage ? new Constructor(message) : new Constructor();
        break;
      }
      case T.DOMException: {
        const name = reader.string();
        value = new DOMException(reader.string(), name);
        break;
      }
      case T.Blob: {
        const type = reader.string();
        value = internal.makeBlob(reader.raw(), type);
        break;
      }
      case T.File: {
        const type = reader.string();
        const name = reader.string();
        const lastModified = reader.f64();
        value = internal.makeFile(reader.raw(), type, name, lastModified);
        break;
      }
      default:
        throw new DOMException("The stored value is damaged.", "DataCloneError");
    }
    memory[slot] = value;
    return value;
  }

  function bigIntOf(hex) {
    return hex.charAt(0) === "-" ? -BigInt("0x" + hex.slice(1)) : BigInt("0x" + hex);
  }

  function readProperties(reader, target, memory) {
    const count = reader.u32();
    for (let index = 0; index < count; index++) {
      const key = reader.string();
      Object.defineProperty(target, key, { value: deserialize(reader, memory), writable: true, enumerable: true,
        configurable: true });
    }
  }

  internal.structuredDeserialize = function (bytes) {
    const reader = new Reader(bytes);
    if (reader.byte() !== Version) throw new DOMException("The stored value is damaged.", "DataCloneError");
    return deserialize(reader, []);
  };
})
