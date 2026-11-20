// Scope: let/const/TDZ, hoisting, closures, strict mode, globals.
try { console.log(tdz); let tdz = 1; } catch (e) { console.log(e.name, e.message); }
try { const c = 1; c = 2; } catch (e) { console.log(e.name, e.message); }
{ let shadow = "inner"; { let shadow = "innermost"; console.log(shadow); } console.log(shadow); }
var hoisted = typeof laterFunction;
function laterFunction() {}
console.log(hoisted, typeof laterVar, (function () { return typeof inside; var inside = 1; })());
function closureTdz() { const read = () => value; try { read(); } catch (e) { console.log("closure tdz", e.name); } let value = 5; return read(); }
console.log(closureTdz());
globalThis.fromGlobal = 1;
var declared = 2;
console.log(fromGlobal, globalThis.declared, "declared" in globalThis, delete globalThis.fromGlobal, typeof fromGlobal);
let lexicalGlobal = 3;
console.log(lexicalGlobal, globalThis.lexicalGlobal);
implicitGlobal = 4;
console.log(globalThis.implicitGlobal);
(function () { "use strict"; try { undeclaredStrict = 1; } catch (e) { console.log("strict", e.name); } })();
(function () { "use strict"; try { Object.defineProperty({}, "x", { value: 1 }).x = 2; } catch (e) { console.log("strict write", e.name); } })();
(function () { "use strict"; try { delete Object.prototype; } catch (e) { console.log("strict delete", e.name); } })();
(function () { try { Object.freeze([1]).push(2); } catch (e) { console.log("frozen push", e.name); } })();
console.log((function () { return this; })() === globalThis, (function () { "use strict"; return this; })());
var fnInBlock = 1;
{ function blockFunction() { return "block"; } }
console.log(typeof blockFunction, blockFunction());
const counters = [];
for (let i = 0; i < 3; i++) { let j = i * 10; counters.push(() => i + j); }
console.log(counters.map(f => f()));
let loopClosures = [];
for (const x of ["a", "b"]) loopClosures.push(() => x);
for (const k in { p: 1, q: 2 }) loopClosures.push(() => k);
console.log(loopClosures.map(f => f()).join(""));
function makeAdders() { const result = []; for (var i = 0; i < 2; i++) result.push(((n) => () => n)(i)); return result; }
console.log(makeAdders().map(f => f()));
const self = function fact(n) { return n ? n * fact(n - 1) : 1; };
console.log(self(5), typeof fact);
let x = "outer";
function dynamic() { return x; }
{ let x = "block"; console.log(dynamic(), x); }
switch (1) { case 1: let inSwitch = "switch scoped"; console.log(inSwitch); }
try { eval("var evaluated = 42"); console.log(evaluated, eval("1 + 2"), typeof eval); } catch (e) { console.log(e.name); }
console.log(new Function("return typeof this")(), Function("a", "b", "return a + b")(1, 2));
console.log(typeof globalThis, typeof window, this === globalThis);
var arguments_ = (function () { return arguments; })(1, 2);
console.log(arguments_.length, arguments_[1], Object.prototype.toString.call(arguments_), [...arguments_]);
/* expected
ReferenceError Cannot access 'tdz' before initialization
TypeError Assignment to constant variable.
innermost
inner
function undefined undefined
closure tdz ReferenceError
5
1 2 true true undefined
3 undefined
4
strict ReferenceError
strict write TypeError
strict delete TypeError
frozen push TypeError
true undefined
function block
[ 0, 11, 22 ]
abpq
[ 0, 1 ]
120 undefined
outer block
switch scoped
42 3 function
object 3
object undefined true
2 2 [object Arguments] [ 1, 2 ]
*/
