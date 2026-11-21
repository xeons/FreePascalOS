// Objects: literals, accessors, keys order, prototypes, descriptors.
var key = "dyn";
var o = { a: 1, "b-c": 2, [key + 1]: 3, 2: "two", 1: "one", get g() { return this.a * 10; }, set g(v) { this.a = v; } };
console.log(Object.keys(o), o.g);
o.g = 5;
console.log(o.a, o.g, "a" in o, "zz" in o, o.hasOwnProperty("g"));
delete o.a;
console.log(o.a, Object.keys(o).length);
var proto = { hello() { return "hello " + this.name; } };
var child = Object.create(proto, { name: { value: "kid", enumerable: true } });
console.log(child.hello(), Object.getPrototypeOf(child) === proto, proto.isPrototypeOf(child), child.hasOwnProperty("hello"));
var d = {};
Object.defineProperty(d, "fixed", { value: 42, writable: false, enumerable: false, configurable: false });
d.fixed = 7;
console.log(d.fixed, Object.keys(d), JSON.stringify(Object.getOwnPropertyDescriptor(d, "fixed")));
var frozen = Object.freeze({ x: 1, inner: { y: 2 } });
frozen.x = 9; frozen.inner.y = 3; frozen.added = 1;
console.log(frozen.x, frozen.inner.y, frozen.added, Object.isFrozen(frozen), Object.isSealed(frozen));
var spread = { ...{ a: 1, b: 2 }, b: 3, c: 4 };
console.log(spread, Object.assign({ z: 0 }, { a: 1 }, null, { b: 2 }));
var { a, ...others } = spread;
console.log(a, others);
var shorthand = 10;
console.log({ shorthand, method() { return 1; } }.shorthand);
var order = {};
order.z = 1; order[10] = 1; order.a = 1; order[2] = 1; order[Symbol.for("s")] = 1;
console.log(Object.keys(order), Reflect.ownKeys(order).length);
for (var k in { x: 1, y: 2, __proto__: { inherited: 3 } }) console.log("key", k);
console.log(Object.entries({ p: 1, q: [2] }), Object.fromEntries([["m", 1], ["n", 2]]));
console.log(Object.getOwnPropertyNames([1, 2]), Object.values("hi"), typeof Object.prototype.toString.call([]));
console.log(Object.prototype.toString.call(null), Object.prototype.toString.call(1), String({}), `${{ toString() { return "custom"; } }}`);
var withValueOf = { valueOf() { return 41; } };
console.log(withValueOf + 1, withValueOf > 40, [withValueOf] + "");
var big = {};
for (var i = 0; i < 200; i++) big["k" + i] = i;
delete big.k5;
console.log(Object.keys(big).length, big.k199, big.k5, big.k6);
console.log(Object.is(NaN, NaN), Object.is(0, -0), Object.hasOwn({ q: 1 }, "q"));
var nullProto = Object.create(null);
nullProto.x = 1;
console.log(Object.keys(nullProto), "toString" in nullProto);
var getterOnly = { get v() { return 1; } };
getterOnly.v = 2;
console.log(getterOnly.v);
console.log(Object.groupBy([1, 2, 3, 4], n => (n % 2 ? "odd" : "even")));
function selfObject(b) { b = { plb: b, Fp: 2 }; return typeof b.plb; }
function selfArray(b) { b = [b, 1]; return typeof b[0]; }
function selfVar(b) { var b = { p: b }; return typeof b.p; }
console.log(selfObject("s"), selfArray("s"), selfVar("s"));
/* expected
[ '1', '2', 'a', 'b-c', 'dyn1', 'g' ] 10
5 50 true false true
undefined 5
hello kid true true false
42 [] {"value":42,"writable":false,"enumerable":false,"configurable":false}
1 3 undefined true true
{ a: 1, b: 3, c: 4 } { z: 0, a: 1, b: 2 }
1 { b: 3, c: 4 }
10
[ '2', '10', 'z', 'a' ] 5
key x
key y
key inherited
[ [ 'p', 1 ], [ 'q', [ 2 ] ] ] { m: 1, n: 2 }
[ '0', '1', 'length' ] [ 'h', 'i' ] string
[object Null] [object Number] [object Object] custom
42 true [object Object]
199 199 undefined 6
true false true
[ 'x' ] false
1
[Object: null prototype] { odd: [ 1, 3 ], even: [ 2, 4 ] }
string string string
*/
