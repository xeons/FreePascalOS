// Destructuring, defaults, rest, spread.
const [a, , b = 5, ...rest] = [1, 2, undefined, 4, 5];
console.log(a, b, rest);
const { x, y: why = 9, z: { deep } = { deep: "d" }, ...others } = { x: 1, w: 3, v: 4 };
console.log(x, why, deep, others);
let p, q;
[p, q] = [q, p] = [1, 2];
console.log(p, q);
let m = 1, n = 2;
[m, n] = [n, m];
console.log(m, n);
const target = {};
({ a: target.first, b: target["second"] } = { a: "A", b: "B" });
[target.third] = ["C"];
console.log(target);
function f({ name, tags: [first = "none"] = [] } = {}, ...more) { return `${name}/${first}/${more.length}`; }
console.log(f({ name: "n", tags: ["t"] }), f({ name: "m" }, 1, 2), f());
for (const [k, v] of Object.entries({ one: 1, two: 2 })) console.log(k, v);
for (const { id, ...row } of [{ id: 1, val: "a" }]) console.log(id, row);
const [s1, s2, ...sRest] = "héllo";
console.log(s1, s2, sRest);
const [g1, g2] = (function* () { yield "first"; yield "second"; yield "never"; })();
console.log(g1, g2);
const { length } = "abc", { [`dyn${1}`]: dynamic } = { dyn1: "computed" };
console.log(length, dynamic);
try { const { boom } = null; } catch (e) { console.log(e.constructor.name); }
try { const [nope] = {}; } catch (e) { console.log(e.constructor.name); }
const nested = { arr: [{ val: [10, 20] }] };
const { arr: [{ val: [, second] }] } = nested;
console.log(second);
const defaultsOrder = [];
const { o1 = defaultsOrder.push("o1"), o2 = defaultsOrder.push("o2") } = { o1: "given" };
console.log(o1, o2, defaultsOrder);
const named = ({ fn = function () {}, arrow = () => {} } = {}) => [fn.name, arrow.name];
console.log(named());
console.log([...new Set([3, 3, 4])], { ...[1, 2] }, [...[], ...[1]], Math.min(...[]));
let closed = false;
const iterable = { [Symbol.iterator]() { let i = 0; return { next: () => ({ value: i++, done: false }), return() { closed = true; return {}; } }; } };
const [i0, i1] = iterable;
console.log(i0, i1, closed);
/* expected
1 5 [ 4, 5 ]
1 9 d { w: 3, v: 4 }
1 2
2 1
{ first: 'A', second: 'B', third: 'C' }
n/t/0 m/none/2 undefined/none/0
one 1
two 2
1 { val: 'a' }
h é [ 'l', 'l', 'o' ]
first second
3 computed
TypeError
TypeError
20
given 1 [ 'o2' ]
[ 'fn', 'arrow' ]
[ 3, 4 ] { '0': 1, '1': 2 } [ 1 ] Infinity
0 1 true
*/
