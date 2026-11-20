// Array.fromAsync, Error.captureStackTrace and stackTraceLimit, groupBy, Promise.try, RegExp scripts.
async function* gen() { yield 1; yield Promise.resolve(2); yield 3; }
Array.fromAsync(gen()).then(a => console.log("async gen", a));
Array.fromAsync([Promise.resolve(4), 5], x => x * 10).then(a => console.log("sync iterable mapped", a));
Array.fromAsync({ length: 2, 0: "a", 1: Promise.resolve("b") }).then(a => console.log("array-like", a));
Array.fromAsync(null).catch(e => console.log("null", e.constructor.name));
Array.fromAsync([1], 5).catch(e => console.log("bad mapper", e.constructor.name));
class MyArray extends Array {}
Array.fromAsync.call(MyArray, [1, 2]).then(a => console.log("species-free", a instanceof MyArray, a.length));
console.log(Array.fromAsync.length, Array.fromAsync.name, typeof Array.fromAsync([]).then);
function outer() { return inner(); }
function inner() { const holder = {}; Error.captureStackTrace(holder, inner); return holder.stack; }
console.log(outer().split("\n").length, outer().split("\n")[1].trim().startsWith("at outer"));
function deep(n) { return n === 0 ? new Error("deep").stack : deep(n - 1); }
console.log(deep(20).split("\n").length, Error.stackTraceLimit);
Error.stackTraceLimit = 2;
console.log(deep(20).split("\n").length);
Error.stackTraceLimit = 0;
console.log(JSON.stringify(new Error("none").stack));
Error.stackTraceLimit = 10;
console.log(Object.groupBy([1, 2, 3, 4], x => x % 2 ? "odd" : "even"), Map.groupBy([1, 2, 3], x => x > 1).get(true), typeof Promise.try);
Promise.try(() => 7).then(v => console.log("try", v));
console.log(/\p{Script=Greek}+/u.exec("abc αβγ def")[0], /\p{sc=Cyrillic}/u.test("ж"), /\p{Script=Devanagari}+/u.exec("x नमस्ते y")[0].length, /\p{scx=Hangul}/u.test("한"));
console.log(/\p{Script=Thai}/u.test("ก"), /\p{Script=Armenian}/u.test("Ա"), /\p{Script=Georgian}/u.test("ა"), /\p{Script=Ethiopic}/u.test("ሀ"), /^\p{Script=Latin}+$/u.test("Ærøskøbing"));
/* expected
1 fromAsync function
3 true
11 10
3
"Error: none"
[Object: null prototype] { odd: [ 1, 3 ], even: [ 2, 4 ] } [ 2, 3 ] function
αβγ true 6 true
true true true true true
null TypeError
bad mapper TypeError
try 7
array-like [ 'a', 'b' ]
species-free true 2
async gen [ 1, 2, 3 ]
sync iterable mapped [ 40, 50 ]
*/
