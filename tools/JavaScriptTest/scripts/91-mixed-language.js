function makeCounter() { let n = 0; return () => ++n; }
const c = makeCounter(); c(); c();
console.log("counter", c());
const arr = [5, 3, 8, 1];
console.log(arr.map(x => x * 2), arr.filter(x => x > 2), arr.reduce((a, b) => a + b, 0));
console.log(arr.slice().sort((a, b) => a - b), arr.indexOf(8), arr.includes(3));
const o = { a: 1, b: { c: [1, 2] }, f() { return this.a; } };
console.log(o, o.f());
const { a, b: { c: [x, y] } } = o;
console.log(a, x, y);
const [p, , q = 10, ...rest] = [1, 2, undefined, 4, 5];
console.log(p, q, rest);
class Animal { constructor(name) { this.name = name; } speak() { return `${this.name} makes a sound`; } }
class Dog extends Animal { speak() { return super.speak() + " (woof)"; } }
console.log(new Dog("Rex").speak());
try { null.x; } catch (e) { console.log(e instanceof TypeError, e.message); }
for (const v of [1, 2, 3]) console.log("of", v);
for (const k in { x: 1, y: 2 }) console.log("in", k);
let s = "";
for (let i = 0; i < 3; i++) { s += i; }
console.log(s, typeof s, `t${1 + 1}`);
function* gen() { yield 1; yield 2; return 3; }
console.log([...gen()]);
console.log(0.1 + 0.2, 1 / 3, 1e21, -0, 2 ** 10, 7 % 3, -7 % 3);
console.log([1, [2, [3, [4]]]].flat(Infinity), Array.from({ length: 3 }, (_, i) => i * i));
/* expected
counter 3
[ 10, 6, 16, 2 ] [ 5, 3, 8 ] 17
[ 1, 3, 5, 8 ] 2 true
{ a: 1, b: { c: [ 1, 2 ] }, f: [Function: f] } 1
1 1 2
1 10 [ 4, 5 ]
Rex makes a sound (woof)
true Cannot read properties of null (reading 'x')
of 1
of 2
of 3
in x
in y
012 string t2
[ 1, 2 ]
0.30000000000000004 0.3333333333333333 1e+21 -0 1024 1 -1
[ 1, 2, 3, 4 ] [ 0, 1, 4 ]
*/
