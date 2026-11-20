// TextEncoder, TextDecoder, atob, btoa and structuredClone.
function bytes(value) {
  return Array.prototype.join.call(value, ",");
}
var encoder = new TextEncoder();
check("TextEncoder.encoding", encoder.encoding === "utf-8");
check("encode", bytes(encoder.encode("a€😀")) === "97,226,130,172,240,159,152,128");
check("encode of a lone surrogate gives U+FFFD", bytes(encoder.encode("\uD800")) === "239,191,189");
check("encode()", encoder.encode().length === 0);
var target = [0, 0, 0, 0];
var summary = encoder.encodeInto("a€b", target);
check("encodeInto stops at whole characters", summary.read === 2 && summary.written === 4 && bytes(target) === "97,226,130,172");

var decoder = new TextDecoder();
check("TextDecoder defaults", decoder.encoding === "utf-8" && decoder.fatal === false && decoder.ignoreBOM === false);
check("decode", decoder.decode([0xEF, 0xBB, 0xBF, 104, 105, 0xE2, 0x82, 0xAC]) === "hi€");
check("decode replaces bad bytes", decoder.decode([0x61, 0xFF, 0x62]) === "a�b");
check("decode()", decoder.decode() === "");
var keep = new TextDecoder("utf-8", { ignoreBOM: true });
check("ignoreBOM keeps the BOM", keep.decode([0xEF, 0xBB, 0xBF, 0x41]) === "﻿A");
var fatal = new TextDecoder("utf-8", { fatal: true });
var fatalError = null;
try { fatal.decode([0xC3]); } catch (e) { fatalError = e; }
check("fatal decoding throws a TypeError", fatalError instanceof TypeError);
var stream = new TextDecoder();
var first = stream.decode([0xE2, 0x82], { stream: true });
var second = stream.decode([0xAC]);
check("streaming keeps a split sequence", first === "" && second === "€");
var latin = new TextDecoder("latin1");
check("labels", latin.encoding === "windows-1252" && latin.decode([0x80, 0x41]) === "€A");
check("UTF-16LE", new TextDecoder("utf-16le").decode([0x41, 0x00, 0xAC, 0x20]) === "A€");
var labelError = null;
try { new TextDecoder("no-such-encoding"); } catch (e) { labelError = e; }
check("an unknown label is a RangeError", labelError instanceof RangeError);
if (typeof Uint8Array === "function") {
  check("encode gives a Uint8Array", encoder.encode("x") instanceof Uint8Array);
  check("decode takes an ArrayBuffer", decoder.decode(new Uint8Array([79, 75]).buffer) === "OK");
}

check("btoa", btoa("hello") === "aGVsbG8=" && btoa("") === "" && btoa("\xFF") === "/w==");
check("atob", atob("aGVsbG8=") === "hello" && atob(" aGVs bG8 ") === "hello" && atob("/w") === "\xFF");
var base64Error = null;
try { btoa("€"); } catch (e) { base64Error = e; }
check("btoa outside Latin-1 is an InvalidCharacterError", base64Error && base64Error.name === "InvalidCharacterError");
base64Error = null;
try { atob("a"); } catch (e) { base64Error = e; }
check("atob of bad input is an InvalidCharacterError", base64Error && base64Error.name === "InvalidCharacterError");

var original = { number: 1, text: "t", list: [1, { deep: true }], when: new Date(1000), map: new Map([["k", 1]]),
  set: new Set([1, 2]), pattern: /a+/gi };
original.self = original;
var copy = structuredClone(original);
check("structuredClone copies", copy !== original && copy.list[1].deep === true && copy.list !== original.list &&
  copy.when.getTime() === 1000 && copy.map.get("k") === 1 && copy.set.has(2) && copy.pattern.flags === "gi");
check("structuredClone keeps cycles", copy.self === copy);
var cloneError = null;
try { structuredClone({ f: function () {} }); } catch (e) { cloneError = e; }
check("a function cannot be cloned", cloneError instanceof DOMException && cloneError.name === "DataCloneError");
cloneError = null;
try { structuredClone(document.body); } catch (e) { cloneError = e; }
check("a node cannot be cloned", cloneError && cloneError.name === "DataCloneError");
