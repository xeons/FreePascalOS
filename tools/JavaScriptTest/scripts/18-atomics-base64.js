// Atomics (one agent) and Uint8Array base64/hex.
const i8 = new Int8Array(4);
console.log(Atomics.add(i8, 0, 5), Atomics.add(i8, 0, 130), i8[0], Atomics.sub(i8, 1, 1), i8[1]);
console.log(Atomics.compareExchange(i8, 0, -121, 3), i8[0], Atomics.compareExchange(i8, 0, 9, 4), i8[0]);
console.log(Atomics.exchange(i8, 2, 7), Atomics.load(i8, 2), Atomics.store(i8, 3, -0), Atomics.store(i8, 3, 3.7), i8[3]);
console.log(Atomics.and(i8, 2, 3), Atomics.or(i8, 2, 8), Atomics.xor(i8, 2, 1), i8[2], Atomics.isLockFree(4), Atomics.notify(new Int32Array(new SharedArrayBuffer(8)), 0));
const b64 = new BigInt64Array(1); console.log(Atomics.add(b64, 0, 5n), Atomics.sub(b64, 0, 10n), b64[0]);
try { Atomics.add(new Float64Array(1), 0, 1); } catch (e) { console.log(e.constructor.name); }
try { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0); } catch (e) { console.log(e.constructor.name); }
try { Atomics.load(i8, 4); } catch (e) { console.log(e.constructor.name); }
console.log(Object.prototype.toString.call(Atomics));
const bytes = new Uint8Array([72, 101, 108, 108, 111, 255, 254]);
console.log(bytes.toBase64(), bytes.toBase64({ alphabet: "base64url", omitPadding: true }), bytes.toHex());
console.log(Uint8Array.fromBase64("SGVsbG8=").join(), Uint8Array.fromBase64(" SGVs bG8 ").join(), Uint8Array.fromBase64("_-8", { alphabet: "base64url" }).join());
try { Uint8Array.fromBase64("SGVsbG9=", { lastChunkHandling: "strict" }); } catch (e) { console.log(e.constructor.name); }
console.log(Uint8Array.fromBase64("SGVsbG8", { lastChunkHandling: "stop-before-partial" }).join(), Uint8Array.fromHex("cafeBABE").join());
const into = new Uint8Array(4);
console.log(JSON.stringify(into.setFromBase64("SGVsbG8=")), into.join(), JSON.stringify(into.setFromHex("0102")), into.join());
try { Uint8Array.fromHex("abc"); } catch (e) { console.log(e.constructor.name); }
console.log(new Uint8Array(0).toBase64(), new Uint8Array([1]).toBase64(), new Uint8Array([1, 2]).toBase64());
const u = new Uint8Array(3); console.log(u.length, (() => { let s = 0; for (const v of u) s++; return s; })());
/* expected
0 5 -121 0 -1
-121 3 3 3
0 7 0 3 3
7 3 11 10 true 0
0n 5n -5n
TypeError
TypeError
RangeError
[object Atomics]
SGVsbG///g== SGVsbG___g 48656c6c6ffffe
72,101,108,108,111 72,101,108,108,111 255,239
SyntaxError
72,101,108 202,254,186,190
{"read":4,"written":3} 72,101,108,0 {"read":4,"written":2} 1,2,108,0
SyntaxError
 AQ== AQI=
3 3
*/
