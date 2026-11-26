// CompressionStream and DecompressionStream (Compression Streams
// Standard): "deflate" (zlib), "deflate-raw", "gzip" and "brotli", as
// transform streams over libcompression (Web.Script.NativeCompression).
// Writes are kept; compression runs once the writable side closes (one
// chunk comes out then), decompression after every write on all the
// input so far, giving out what is new (so output flows before the end).
// Broken, short or trailing data errors the stream with a TypeError.
(function (natives, global, internal) {
  "use strict";
  if (typeof global.TransformStream !== "function" || typeof natives.compressBytes !== "function") return;
  const formats = ["deflate", "deflate-raw", "gzip", "brotli"];
  const streams = new WeakMap();

  function chunkBytes(chunk) {
    if (chunk instanceof ArrayBuffer) return new Uint8Array(chunk.slice(0));
    if (ArrayBuffer.isView(chunk) && chunk.buffer instanceof ArrayBuffer)
      return new Uint8Array(chunk.buffer.slice(chunk.byteOffset, chunk.byteOffset + chunk.byteLength));
    throw new TypeError("The chunk is not an ArrayBuffer or an ArrayBufferView");
  }
  function joined(parts, total) {
    const bytes = new Uint8Array(total);
    let offset = 0;
    for (const part of parts) {
      bytes.set(part, offset);
      offset += part.length;
    }
    return bytes;
  }
  function attach(object, format, operation, name) {
    const value = String(format);
    if (formats.indexOf(value) < 0)
      throw new TypeError("Failed to construct '" + name + "': Unsupported compression format: '" + value + "'");
    const parts = [];
    let total = 0, given = 0;
    function giveNew(controller, final) {
      const all = parts.length === 1 ? parts[0] : joined(parts, total);
      parts.length = 0;
      parts.push(all);
      const result = operation(value, all, final);
      if (result.length > given) controller.enqueue(result.slice(given));
      given = result.length;
    }
    streams.set(object, new global.TransformStream({
      transform: function (chunk, controller) {
        const bytes = chunkBytes(chunk);
        parts.push(bytes);
        total += bytes.length;
        if (operation === natives.decompressBytes && bytes.length > 0) giveNew(controller, false);
      },
      flush: function (controller) {
        giveNew(controller, true);
        parts.length = 0;
      }
    }));
  }
  function streamOf(object) {
    const stream = streams.get(object);
    if (stream === undefined) throw new TypeError("Illegal invocation");
    return stream;
  }

  class CompressionStream {
    constructor(format) {
      if (arguments.length === 0) throw new TypeError("Failed to construct 'CompressionStream': 1 argument required");
      attach(this, format, natives.compressBytes, "CompressionStream");
    }
    get readable() { return streamOf(this).readable; }
    get writable() { return streamOf(this).writable; }
  }
  internal.finishInterface(CompressionStream, "CompressionStream");

  class DecompressionStream {
    constructor(format) {
      if (arguments.length === 0) throw new TypeError("Failed to construct 'DecompressionStream': 1 argument required");
      attach(this, format, natives.decompressBytes, "DecompressionStream");
    }
    get readable() { return streamOf(this).readable; }
    get writable() { return streamOf(this).writable; }
  }
  internal.finishInterface(DecompressionStream, "DecompressionStream");
})
