// ArrayBuffer, SharedArrayBuffer, DataView and the typed arrays.
const a = new Uint8Array([1, 2, 300, -1]);
console.log(a.length, a[0], a[2], a[3], a[4], a.byteLength, a.byteOffset);
console.log(a, new Float32Array(0), new BigUint64Array([5n]));
const f = new Float64Array(3);
f[1] = 1.5;
console.log(f.join(","), Object.prototype.toString.call(f), f[Symbol.toStringTag]);

// Conversions of each kind.
console.log(new Int8Array([127, 128, -129, 255.9]).join());
console.log(new Uint16Array([65536, -1, 1.9]).join(), new Int32Array([2 ** 31, -(2 ** 31) - 1]).join());
console.log(new Uint32Array([-1, 2 ** 32 + 5]).join(), new Float32Array([0.1])[0]);
console.log(Uint8ClampedArray.from([1.5, 2.5, -5, 300, NaN, 254.5, 0.5]).join());
console.log(new Float16Array([65504, 65520, 0.1, 1e-8, -0])[1], new Float16Array([0.1])[0], Object.is(new Float16Array([-0])[0], -0));
console.log(Math.f16round(1.337), Math.f16round(5e-8), Math.f16round(6e-8), Math.f16round(70000));
const big = new BigInt64Array([1n, -2n, 2n ** 63n]);
console.log(big[1], big[2], typeof big[0], new BigUint64Array([-1n])[0]);
try { new BigInt64Array([1]); } catch (e) { console.log(e.constructor.name); }
try { new Uint8Array([1n]); } catch (e) { console.log(e.constructor.name); }

// Integer-indexed exotic behaviour.
console.log(a["-0"], "1.5" in a, 4 in a, 3 in a, Object.keys(new Uint8Array(3)), delete a[0], delete a[9]);
a[10] = 5;
a.foo = 1;
console.log(a[10], a.foo, Object.getOwnPropertyDescriptor(a, 0), JSON.stringify(new Uint8Array([7, 8])));
console.log(Reflect.defineProperty(a, 0, { value: 9 }), a[0], Reflect.defineProperty(a, 0, { value: 1, enumerable: false }));
const proto = Object.create(new Uint8Array([42]));
console.log(proto[0], proto[5]);

// DataView.
const buf = new ArrayBuffer(16);
const dv = new DataView(buf, 2);
dv.setUint16(0, 0x1234);
console.log(dv.getUint8(0), dv.getUint8(1), dv.getUint16(0, true), dv.byteLength, dv.byteOffset);
dv.setFloat32(2, 1.5, true);
dv.setFloat64(6, -2.25);
console.log(dv.getFloat32(2, true), dv.getFloat64(6), new Uint8Array(buf, 8, 2).join());
dv.setBigInt64(0, -5n, true);
console.log(dv.getBigInt64(0, true), dv.getBigUint64(0, true), dv.getInt8(0), dv.getFloat16(0, true));
dv.setFloat16(0, 1.5);
console.log(dv.getUint16(0).toString(16));
try { dv.getUint32(12); } catch (e) { console.log(e.constructor.name, e.message); }
try { new DataView(buf, 17); } catch (e) { console.log(e.constructor.name); }
console.log(new DataView(new ArrayBuffer(2), 1));

// Methods.
const i16 = new Int16Array([5, -3, 10, 0, -0]);
i16.sort();
console.log(i16.join(), new Float64Array([3, NaN, -0, 0, -1]).sort().join(), Object.is(new Float64Array([0, -0]).sort()[0], -0));
console.log(new Int32Array([1, 10, 2]).sort((x, y) => y - x).join(), new BigInt64Array([3n, -1n, 2n]).sort().join());
console.log(Array.from(new Uint16Array([7, 8, 9]).map(x => x * 2)), [...new Int8Array([3, 4])]);
console.log(new Uint8Array([1, 2, 3]).filter(x => x & 1), new Int32Array([1, 2, 3]).reduce((x, y) => x + y));
console.log(new Uint8Array([1, 2, 3]).reduceRight((x, y) => x + "" + y), new Uint8Array([4, 5, 6]).at(-1));
console.log(new Uint8Array([1, 2, 3, 2]).indexOf(2), new Uint8Array([1, 2, 3, 2]).lastIndexOf(2), new Float32Array([NaN]).includes(NaN), new Float32Array([NaN]).indexOf(NaN));
console.log(new Uint8Array([5, 6, 7]).find(x => x > 5), new Uint8Array([5, 6, 7]).findLastIndex(x => x < 7), new Uint8Array([1]).some(x => x > 1), new Uint8Array([2, 4]).every(x => x % 2 === 0));
const ta = new Uint8Array(10);
ta.set([1, 2, 3], 2);
ta.copyWithin(0, 2, 5);
console.log(ta.join(""), ta.fill(7, -2).join(""), ta.subarray(1, 3), ta.subarray(-2).byteOffset);
console.log(new Uint8Array([3, 1, 2]).toSorted().join(), new Uint8Array([1, 2]).with(-1, 9).join(), new Uint8Array([1, 2]).toReversed().join(), new Uint8Array([1, 2, 3]).reverse().join());
console.log(new Uint8Array([1, 2, 3]).slice(1).join(), new Uint8Array([1, 2, 3]).slice(-1, 5).length, [...new Uint8Array([9, 8]).entries()].join(";"), [...new Uint8Array(2).keys()]);
const overlap = new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8]);
new Uint16Array(overlap.buffer, 2, 2).set(new Uint8Array(overlap.buffer, 0, 2));
console.log(overlap.join());
try { new Uint8Array(2).set([1, 2, 3]); } catch (e) { console.log(e.constructor.name); }
try { new Uint8Array(2).with(5, 1); } catch (e) { console.log(e.constructor.name); }
console.log(new Float64Array([1.5, 2]).toLocaleString(), new Uint8Array([1, 2]).toString(), Uint8Array.prototype.toString === Array.prototype.toString);
console.log(Uint8Array.of(1, 2, 300).join(), Int16Array.from({ length: 2, 0: 5, 1: "6" }).join(), Float32Array.from([1, 2], x => x / 2).join());
console.log(Uint8Array.from(new Set([4, 5])).join(), new Uint8Array(new Int16Array([256, 257])).join(), new Int16Array(new Uint8Array([200])).join());

// Species.
class Bytes extends Uint8Array {}
const species = new Bytes([1, 2, 3]);
console.log(species.map(x => x + 1) instanceof Bytes, species.subarray(1) instanceof Bytes, species.slice(1).constructor.name, species.toSorted().constructor.name);
console.log(Object.getPrototypeOf(Int8Array).name, Object.getPrototypeOf(Int8Array.prototype) === Object.getPrototypeOf(Uint8Array.prototype));
try { Object.getPrototypeOf(Int8Array)(); } catch (e) { console.log(e.constructor.name); }
try { Uint8Array(2); } catch (e) { console.log(e.constructor.name); }
console.log(Uint8Array.BYTES_PER_ELEMENT, Float64Array.prototype.BYTES_PER_ELEMENT, BigInt64Array.BYTES_PER_ELEMENT, Uint8Array.length, Uint8Array.name);

// ArrayBuffer: slice, resizable, transfer, detach.
const source = new Uint8Array([1, 2, 3, 4]).buffer;
console.log(source.slice(1, 3).byteLength, new Uint8Array(source.slice(-2)).join(), ArrayBuffer.isView(dv), ArrayBuffer.isView(buf));
const growable = new ArrayBuffer(4, { maxByteLength: 16 });
const tracking = new Uint8Array(growable);
const fixed = new Uint8Array(growable, 0, 4);
console.log(growable.resizable, growable.maxByteLength, tracking.length, source.resizable, source.maxByteLength);
growable.resize(10);
tracking[9] = 9;
console.log(tracking.length, fixed.length, tracking[9]);
growable.resize(2);
console.log(tracking.length, fixed.length, fixed.byteOffset, fixed[0]);
try { fixed.fill(0); } catch (e) { console.log(e.constructor.name); }
try { growable.resize(17); } catch (e) { console.log(e.constructor.name); }
const moved = source.transfer();
console.log(source.detached, source.byteLength, moved.byteLength, new Uint8Array(moved).join());
try { new Uint8Array(source); } catch (e) { console.log(e.constructor.name); }
try { source.slice(0); } catch (e) { console.log(e.constructor.name); }
const longer = moved.transfer(6);
console.log(new Uint8Array(longer).join(), moved.detached, longer.transferToFixedLength(2).byteLength, longer.detached);
const keepResizable = new ArrayBuffer(2, { maxByteLength: 8 }).transfer();
console.log(keepResizable.resizable, keepResizable.maxByteLength, new ArrayBuffer(2, { maxByteLength: 8 }).transferToFixedLength().resizable);
const view = new Uint8Array(new ArrayBuffer(4));
const viewBuffer = view.buffer;
viewBuffer.transfer();
console.log(view.length, view[0], view.byteLength);
try { view.join(); } catch (e) { console.log(e.constructor.name); }
try { for (const v of view) console.log(v); } catch (e) { console.log(e.constructor.name); }
console.log(new ArrayBuffer(3), viewBuffer);

// SharedArrayBuffer.
const shared = new SharedArrayBuffer(4, { maxByteLength: 8 });
console.log(shared.byteLength, shared.growable, Object.prototype.toString.call(shared), new Int8Array(shared).length);
shared.grow(8);
console.log(shared.byteLength, shared.slice(2).byteLength);
try { shared.grow(4); } catch (e) { console.log(e.constructor.name); }
try { ArrayBuffer.prototype.slice.call(shared); } catch (e) { console.log(e.constructor.name); }

// Conversions that run code may detach the buffer.
const victim = new Uint8Array(4);
victim[0] = { valueOf() { victim.buffer.transfer(); return 1; } };
console.log(victim.length, victim[0]);

// Iteration and loops.
let total = 0;
const numbers = new Float64Array(1000);
for (let i = 0; i < numbers.length; i++) numbers[i] = i * 0.5;
for (const n of numbers) total += n;
console.log(total, numbers.length);
/* expected
4 1 44 255 undefined 4 0
Uint8Array(4) [ 1, 2, 44, 255 ] Float32Array(0) [] BigUint64Array(1) [ 5n ]
0,1.5,0 [object Float64Array] Float64Array
127,-128,127,-1
0,65535,1 -2147483648,2147483647
4294967295,5 0.10000000149011612
2,2,0,255,0,254,0
Infinity 0.0999755859375 true
1.3369140625 5.960464477539063e-8 5.960464477539063e-8 Infinity
-2n -9223372036854775808n bigint 18446744073709551615n
TypeError
TypeError
undefined false false true [ '0', '1', '2' ] false true
undefined 1 { value: 1, writable: true, enumerable: true, configurable: true } {"0":7,"1":8}
true 9 false
42 undefined
18 52 13330 14 2
1.5 -2.25 192,2
-5n 18446744073709551611n -5 NaN
3e00
RangeError Offset is outside the bounds of the DataView
RangeError
DataView { byteLength: 1, byteOffset: 1, buffer: ArrayBuffer { [Uint8Contents]: <00 00>, byteLength: 2 } }
-3,0,0,5,10 -1,0,0,3,NaN true
10,2,1 -1,2,3
[ 14, 16, 18 ] [ 3, 4 ]
Uint8Array(2) [ 1, 3 ] 6
321 6
1 3 true -1
6 1 false true
1232300000 1232300077 Uint8Array(2) [ 2, 3 ] 8
1,2,3 1,9 2,1 3,2,1
2,3 1 0,9;1,8 [ 0, 1 ]
1,2,1,0,2,0,7,8
RangeError
RangeError
1.5,2 1,2 true
1,2,44 5,6 0.5,1
4,5 0,1 200
true true Bytes Uint8Array
TypedArray true
TypeError
TypeError
1 8 8 3 Uint8Array
2 3,4 true false
true 16 4 false 4
10 4 9
2 0 0 undefined
TypeError
RangeError
true 0 4 1,2,3,4
TypeError
TypeError
1,2,3,4,0,0 true 2 true
true 8 false
0 undefined 0
TypeError
TypeError
ArrayBuffer { [Uint8Contents]: <00 00 00>, byteLength: 3 } ArrayBuffer { (detached), byteLength: 0 }
4 true [object SharedArrayBuffer] 4
8 6
RangeError
TypeError
0 undefined
249750 1000
*/
