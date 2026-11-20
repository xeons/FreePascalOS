// Generators and iterators.
function* range(start, end, step = 1) { for (let i = start; i < end; i += step) yield i; }
console.log([...range(0, 5)], [...range(0, 10, 3)], Array.from(range(1, 4), x => x * x));
function* talk() { const a = yield "first"; const b = yield a + 1; return a + b; }
const g = talk();
console.log(g.next("ignored"), g.next(10), g.next(5), g.next());
function* withFinally() { try { yield 1; yield 2; } finally { console.log("cleanup"); } }
const wf = withFinally();
console.log(wf.next().value, wf.return(42), wf.next());
for (const v of withFinally()) { if (v === 1) break; }
function* catcher() { while (true) { try { yield "waiting"; } catch (e) { console.log("caught", e); } } }
const c = catcher();
c.next();
console.log(c.throw("boom").value);
function* delegate() { yield "a"; const r = yield* talk(); yield "result " + r; yield* [8, 9]; }
const dg = delegate();
console.log(dg.next().value, dg.next().value, dg.next(3).value, dg.next(4).value, dg.next().value, dg.next().value, dg.next().done);
const fib = function* () { let [a, b] = [0, 1]; for (;;) { yield a; [a, b] = [b, a + b]; } };
const first10 = [];
for (const n of fib()) { if (first10.length === 10) break; first10.push(n); }
console.log(first10.join(","));
class Tree {
  constructor(value, ...children) { this.value = value; this.children = children; }
  *[Symbol.iterator]() { yield this.value; for (const child of this.children) yield* child; }
}
console.log([...new Tree(1, new Tree(2, new Tree(3)), new Tree(4))]);
const iter = { from: 1, to: 3, [Symbol.iterator]() { let cur = this.from, last = this.to; return { next: () => cur <= last ? { value: cur++, done: false } : { value: undefined, done: true } }; } };
console.log([...iter], Math.max(...iter));
const genObj = range(0, 2);
console.log(typeof genObj.next, genObj[Symbol.iterator]() === genObj, Object.prototype.toString.call(genObj), String(range));
const it = [1, 2, 3][Symbol.iterator]();
console.log(it.next(), [...it], it.next());
const entries = new Map([["k", "v"]]).entries();
console.log(entries.next().value, entries.next().done);
console.log([..."ab"].map((ch, i) => ch + i), [...new Set("hello")].join(""));
function* infinite() { let i = 0; while (true) yield i++; }
console.log(infinite().map(x => x * 2).filter(x => x % 3 === 0).take(4).toArray());
console.log(Iterator.from({ next() { return { done: true }; } }).toArray(), [1, 2, 3].values().drop(1).reduce((a, b) => a + b));
console.log(range(0, 4).some(x => x > 2), range(0, 4).every(x => x < 2), range(0, 4).find(x => x === 3), [10].values().flatMap(x => [x, x]).toArray());
const genFn = function* () {};
console.log(Object.getPrototypeOf(genFn).constructor.name, genFn.prototype !== undefined);
try { const running = (function* () { running.next(); yield; })(); running.next(); } catch (e) { console.log(e.message); }
/* expected
[ 0, 1, 2, 3, 4 ] [ 0, 3, 6, 9 ] [ 1, 4, 9 ]
{ value: 'first', done: false } { value: 11, done: false } { value: 15, done: true } { value: undefined, done: true }
cleanup
1 { value: 42, done: true } { value: undefined, done: true }
cleanup
caught boom
waiting
a first 4 result 7 8 9 true
0,1,1,2,3,5,8,13,21,34
[ 1, 2, 3, 4 ]
[ 1, 2, 3 ] 3
function true [object Generator] function* range(start, end, step = 1) { for (let i = start; i < end; i += step) yield i; }
{ value: 1, done: false } [ 2, 3 ] { value: undefined, done: true }
[ 'k', 'v' ] true
[ 'a0', 'b1' ] helo
[ 0, 6, 12, 18 ]
[] 5
true false 3 [ 10, 10 ]
GeneratorFunction true
Generator is already running
*/
