// Collections, Date (UTC), optional chaining, misc operators, garbage.
const m = new Map();
m.set("a", 1).set(NaN, "nan").set(-0, "zero").set(m, "self");
console.log(m.size, m.get(NaN), m.get(0), m.get(m), m.has("b"), [...m.keys()].length, m.delete("a"), m.size);
const order = new Map([[3, "c"], [1, "a"], [2, "b"]]);
order.delete(1); order.set(1, "again");
console.log([...order.entries()], [...order.values()].join(""));
const visited = [];
const live = new Map([[1, 1], [2, 2], [3, 3]]);
for (const [k] of live) { visited.push(k); if (k === 1) { live.delete(2); live.set(4, 4); } }
console.log(visited);
const set = new Set([1, 2, 3, 2, 1]);
set.add(4).add(1);
console.log(set.size, [...set], set.has(3), set.delete(3), [...set]);
const sa = new Set([1, 2, 3]), sb = new Set([2, 3, 4]);
console.log([...sa.union(sb)], [...sa.intersection(sb)], [...sa.difference(sb)], [...sa.symmetricDifference(sb)], sa.isSubsetOf(new Set([1, 2, 3, 4])), sa.isDisjointFrom(new Set([9])));
let forEachLog = [];
new Map([["x", 1]]).forEach((v, k, map) => forEachLog.push(k + v + map.size));
new Set(["y"]).forEach((v, k) => forEachLog.push(v + k));
console.log(forEachLog, Map.groupBy([1, 2, 3], x => x % 2).get(1));
const wm = new WeakMap(), key1 = {}, key2 = {};
wm.set(key1, "one").set(key2, "two");
console.log(wm.get(key1), wm.has(key2), wm.delete(key2), wm.has(key2), wm.get({}));
try { wm.set(1, 2); } catch (e) { console.log(e.name); }
const ws = new WeakSet([key1]);
console.log(ws.has(key1), ws.has(key2));
const ref = new WeakRef(key1);
console.log(ref.deref() === key1, typeof FinalizationRegistry);
let weakKeys = [];
for (let i = 0; i < 2000; i++) { const k = { i }; wm.set(k, new Array(10).fill(i)); if (i % 500 === 0) weakKeys.push(k); }
console.log(weakKeys.every(k => wm.get(k)[0] === k.i));
const d = new Date(Date.UTC(2024, 1, 29, 13, 45, 30, 123));
console.log(d.toISOString(), d.getUTCDay(), d.getUTCDate(), d.getTime(), JSON.stringify(d), d.toUTCString());
d.setUTCMonth(12);
console.log(d.toISOString(), new Date("2020-01-01T00:00:00Z").getTime(), new Date(0).toISOString());
console.log(new Date(8.64e15 + 1).getTime(), String(new Date(NaN)), new Date(2020, 0, 1) instanceof Date, typeof Date.now(), Date.UTC(1970, 0, 1));
console.log(new Date("2024-03-10").toISOString(), new Date(Date.UTC(-1, 0, 1)).toISOString(), new Date(Date.UTC(275760, 8, 13)).toISOString());
const obj = { a: { b: { c: 1 } }, arr: [{ v: 2 }], fn() { return "called"; } };
console.log(obj?.a?.b?.c, obj.x?.y.z, obj.arr?.[0]?.v, obj.fn?.(), obj.missing?.(), obj?.["a"].b, (null)?.length);
console.log(null ?? "default", 0 ?? "default", "" || "empty", 0 || null || "last", 1 && 2 && 3, false && boom());
let la = null, lb = 0, lc = 1;
la ??= "set"; lb ||= "zero"; lc &&= "and";
console.log(la, lb, lc);
console.log(2 ** -1, (-8) ** (1 / 3), 7 ** 0, typeof void 0, [1, 2, 3].length ?? 0, "x" in { x: undefined });
console.log(1 < 2 < 3, 3 > 2 > 1, "2" > "12", 2 > "12", [2] > 1, null + undefined, [] == ![]);
let total = 0;
for (let round = 0; round < 50; round++) {
  const garbage = [];
  for (let i = 0; i < 1000; i++) garbage.push({ i, s: "item" + i, arr: [i, i + 1] });
  total += garbage.reduce((acc, o) => acc + o.arr[1], 0);
}
console.log(total);
const closures = [];
for (let i = 0; i < 10000; i++) closures.push(() => i * 2);
console.log(closures.reduce((acc, f) => acc + f(), 0));
let str = "";
for (let i = 0; i < 20000; i++) str += String.fromCharCode(97 + (i % 26));
console.log(str.length, str.slice(-3), str.split("z").length);
/* expected
4 nan zero self false 4 true 3
[ [ 3, 'c' ], [ 2, 'b' ], [ 1, 'again' ] ] cbagain
[ 1, 3, 4 ]
4 [ 1, 2, 3, 4 ] true true [ 1, 2, 4 ]
[ 1, 2, 3, 4 ] [ 2, 3 ] [ 1 ] [ 1, 4 ] true true
[ 'x11', 'yy' ] [ 1, 3 ]
one true true false undefined
TypeError
true false
true function
true
2024-02-29T13:45:30.123Z 4 29 1709214330123 "2024-02-29T13:45:30.123Z" Thu, 29 Feb 2024 13:45:30 GMT
2025-01-29T13:45:30.123Z 1577836800000 1970-01-01T00:00:00.000Z
NaN Invalid Date true number 0
2024-03-10T00:00:00.000Z -000001-01-01T00:00:00.000Z +275760-09-13T00:00:00.000Z
1 undefined 2 called undefined { c: 1 } undefined
default 0 empty last 3 false
set zero and
0.5 NaN 1 undefined 3 true
true false true false true NaN true
25025000
99990000
20000 def 770
*/
