console.log(JSON.stringify({ a: [1, "x", null, true], b: { c: 1.5 } }), JSON.parse('{"x":[1,2,{"y":"z"}]}').x[2].y);
console.log(JSON.stringify({ a: 1, b: [1, 2] }, null, 2));
const m = new Map([[1, "one"], ["two", 2]]);
m.set(NaN, "nan");
console.log(m.get(1), m.get("two"), m.get(NaN), m.size, [...m.keys()], m);
const s = new Set([1, 2, 2, 3]);
console.log(s.has(2), s.size, [...s], s);
const wm = new WeakMap(); const k = {}; wm.set(k, 42); console.log(wm.get(k), wm.has({}));
console.log((1234.5678).toFixed(2), (0.000001234).toPrecision(2), (1.005).toFixed(2), (123.456).toExponential(2), (255).toString(16));
console.log(Math.max(1, 5, 3), Math.round(2.5), Math.round(-2.5), Math.floor(-1.5), Math.sqrt(16), Math.PI);
console.log("Hello".toUpperCase(), "  trim ".trim(), "a,b,c".split(","), "abc".padStart(5, "*"), "x".repeat(3));
console.log("abcdef".slice(1, -1), "abcdef".substring(4, 1), "hello world".replace("world", "there"), "aaa".replaceAll("a", "b"));
console.log(`${[1, 2, 3]}`, String(Symbol("s")), [1, 2, 3].join("-"), "abc".at(-1), "€".charCodeAt(0));
console.log(10n ** 20n, BigInt(123) * 2n, typeof 1n, 7n / 2n, -7n % 3n, (2n ** 64n).toString(16));
const p = new Proxy({}, { get: (t, key) => "prop:" + String(key) });
console.log(p.foo, Reflect.ownKeys({ a: 1, [Symbol.iterator]: 0 }), Reflect.has({ x: 1 }, "x"));
const d = new Date(Date.UTC(2024, 0, 15, 10, 30, 0));
console.log(d.toISOString(), d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDay(), Date.parse("2024-01-15T10:30:00Z") === d.getTime());
Promise.resolve(1).then(v => console.log("then", v));
(async () => { const v = await Promise.resolve(5); console.log("async", v); })();
console.log("sync done");
async function* ag() { yield 1; await null; yield 2; }
(async () => { for await (const v of ag()) console.log("ag", v); })();
console.log(Object.entries({ a: 1, b: 2 }), Object.assign({}, { x: 1 }), Object.freeze([1]).length, Array.isArray([]));
console.log([3, 1, 2].toSorted(), [1, 2, 3].findLast(x => x < 3), [1, 2, 3, 4].findLastIndex(x => x % 2 == 1));
class A { #x = 1; static s = 5; get x() { return this.#x; } inc() { this.#x++; return this; } static #p() { return 9; } static q() { return A.#p(); } static has(o) { return #x in o; } }
console.log(new A().inc().x, A.s, A.q(), A.has(new A()));
label: for (let i = 0; i < 3; i++) { for (let j = 0; j < 3; j++) { if (j == 1) continue label; if (i == 2) break label; console.log("ij", i, j); } }
let fns = []; for (let i = 0; i < 3; i++) fns.push(() => i); console.log(fns.map(f => f()));
console.log(typeof undeclared, void 0 ?? "default", null?.x, ({ a: { b: 2 } }).a?.b);
try { throw new RangeError("bad", { cause: 7 }); } catch (e) { console.log(e.name, e.message, e.cause, e instanceof Error); } finally { console.log("finally"); }
function f(a, b = a + 1, ...rest) { return [a, b, rest, arguments.length]; }
console.log(f(1), f(1, 2, 3, 4));
console.log([..."héllo"], Array.from(new Set("aab")), Object.getOwnPropertyNames("ab"));
/* expected
{"a":[1,"x",null,true],"b":{"c":1.5}} z
{
  "a": 1,
  "b": [
    1,
    2
  ]
}
one 2 nan 3 [ 1, 'two', NaN ] Map(3) { 1 => 'one', 'two' => 2, NaN => 'nan' }
true 3 [ 1, 2, 3 ] Set(3) { 1, 2, 3 }
42 false
1234.57 0.0000012 1.00 1.23e+2 ff
5 3 -2 -2 4 3.141592653589793
HELLO trim [ 'a', 'b', 'c' ] **abc xxx
bcde bcd hello there bbb
1,2,3 Symbol(s) 1-2-3 c 8364
100000000000000000000n 246n bigint 3n -1n 10000000000000000
prop:foo [ 'a', Symbol(Symbol.iterator) ] true
2024-01-15T10:30:00.000Z 2024 0 1 true
sync done
[ [ 'a', 1 ], [ 'b', 2 ] ] { x: 1 } 1 true
[ 1, 2, 3 ] 2 2
2 5 9 true
ij 0 0
ij 1 0
[ 0, 1, 2 ]
undefined default undefined 2
RangeError bad 7 true
finally
[ 1, 2, [], 1 ] [ 1, 2, [ 3, 4 ], 4 ]
[ 'h', 'é', 'l', 'l', 'o' ] [ 'a', 'b' ] [ '0', '1', 'length' ]
then 1
async 5
ag 1
ag 2
*/
