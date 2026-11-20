// Direct eval with the caller's scope, with statements, mapped arguments.
var g = "global";
function f(a, b) {
  var local = 1;
  let block = 2;
  const c = 3;
  console.log(eval("a + b + local + block + c"), eval("typeof g"), eval("this === globalThis"));
  eval("var created = 'created by eval'; local = 10;");
  console.log(created, local, typeof created);
  eval("function made() { return 'made ' + a; }");
  console.log(made());
  try { eval("c = 5"); } catch (e) { console.log(e.constructor.name); }
  try { eval("let block = 1; var block;"); } catch (e) { console.log(e.constructor.name); }
  console.log(eval("let inner = 5; inner * 2"), typeof inner);
  console.log((0, eval)("typeof local"), eval("arguments.length"), eval("(() => arguments[0])()"));
  return () => eval("local + created");
}
const later = f(1, 2);
console.log(later());
function strictEval() { "use strict"; eval("var s = 1"); return typeof s; }
console.log(strictEval());
eval("var topLevel = 'top'");
console.log(topLevel, globalThis.topLevel);
const o = { x: 1, y: 2, f() { return this === o; } };
with (o) {
  console.log(x + y, f());
  x = 10;
  var z = 3;
}
console.log(o.x, typeof z, z, o.z);
with ({ a: 1, [Symbol.unscopables]: { a: true } }) { try { console.log(a); } catch (e) { console.log("unscopable", e.constructor.name); } }
function counter() { with ({ n: 0 }) { return () => ++n; } }
const inc = counter();
console.log(inc(), inc());
with ({ hidden: "seen" }) { console.log(typeof hidden, delete hidden, typeof hidden); }
function mapped(a, b) { arguments[0] = "changed"; b = "b changed"; return [a, arguments[1], arguments.length]; }
console.log(mapped(1, 2), mapped(1));
function unmapped(a) { "use strict"; arguments[0] = 9; return a; }
console.log(unmapped(1));
function deleted(a) { delete arguments[0]; arguments[0] = 5; return a; }
console.log(deleted(1));
function defaults(a = 0) { arguments[0] = 7; return a; }
console.log(defaults(1));
class K { m() { return eval("super.toString === Object.prototype.toString"); } }
console.log(new K().m());
function nt() { return eval("new.target === nt"); }
console.log(new nt() instanceof nt, nt());
const closures = [];
for (let i = 0; i < 3; i++) closures.push(eval("() => i"));
console.log(closures.map(c => c()).join(), eval("1; if (true) { 2 }"), eval(""), eval(5), eval("eval('closures.length * 10')"));
var v = "outer";
function w(obj) { with (obj) return v; }
console.log(w({}), w({ v: "inner" }), (function () { with ({}) return typeof notDefinedAnywhere; })());
function args(a, b) {
  const tag = Object.prototype.toString.call(arguments);
  Object.defineProperty(arguments, 0, { value: 3 });
  const first = a;
  Object.defineProperty(arguments, 0, { writable: false });
  arguments[0] = 4;
  a = 5;
  return [tag, arguments.callee === args, first, arguments[0], a, Object.keys(arguments).join()];
}
console.log(args(1, 2));
const obj = { name: "obj", run() { return (() => eval("this.name"))(); } };
console.log(obj.run());
function shadow() { var x = "function x"; { let y = "block y"; return eval("x + ' / ' + y"); } }
console.log(shadow());
function evalThenRead() { eval("var fresh = 1"); fresh++; return fresh; }
console.log(evalThenRead(), typeof fresh);
function nestedReads() { eval("var deep = 'deep'"); return (function () { return deep; })(); }
console.log(nestedReads());
try { eval("}"); } catch (e) { console.log(e.constructor.name); }
/* expected
9 string true
created by eval 10 string
made 1
TypeError
SyntaxError
10 undefined
undefined 2 1
10created by eval
undefined
top top
3 true
10 number 3 undefined
unscopable ReferenceError
1 2
string true undefined
[ 'changed', 'b changed', 2 ] [ 'changed', undefined, 1 ]
1
1
1
true
true false
0,1,2 2 undefined 5 30
outer inner undefined
[ '[object Arguments]', true, 3, 3, 5, '0,1' ]
obj
function x / block y
2 undefined
deep
SyntaxError
*/
