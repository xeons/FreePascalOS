// Functions, closures, this, arguments.
function add(a, b) { return a + b; }
console.log(add(1, 2), add.length, add.name, add(1), typeof add);
console.log(hoisted(), typeof notYet);
function hoisted() { return "hoisted"; }
var notYet = function named() { return named.name; };
console.log(notYet(), notYet.name);
function counter() { var count = 0; return { inc: () => ++count, get: () => count }; }
var c1 = counter(), c2 = counter();
c1.inc(); c1.inc(); c2.inc();
console.log(c1.get(), c2.get());
function fact(n) { return n <= 1 ? 1 : n * fact(n - 1); }
console.log(fact(10), fact(20));
function defaults(a, b = a * 2, c = () => a + b) { return [a, b, c()]; }
console.log(defaults(1), defaults(1, 5), defaults.length);
function rest(first, ...others) { return others.length + ":" + others.join(","); }
console.log(rest(1), rest(1, 2, 3), rest.length);
console.log(Math.max(...[1, 9, 3]), add(...[4, 5]), [..."abc", ...[1, 2]]);
function args() { return arguments.length + " " + Array.prototype.slice.call(arguments).join("|"); }
console.log(args(), args(1, "two", [3]));
var obj = {
  name: "obj",
  regular() { return this.name; },
  arrow: () => typeof this,
  nested() { return [1, 2].map(function () { return this; }, "ctx").join(","); },
  later() { return (() => this.name)(); }
};
console.log(obj.regular(), obj.arrow(), obj.nested(), obj.later());
function who() { return this === undefined ? "undefined" : typeof this; }
function whoStrict() { "use strict"; return this === undefined ? "undefined" : typeof this; }
console.log(who(), whoStrict(), who.call(5), whoStrict.call(5));
var bound = add.bind(null, 10);
console.log(bound(5), bound.name, bound.length, add.call(null, 2, 3), add.apply(null, [3, 4]));
var adders = [];
for (var i = 0; i < 3; i++) adders.push(function () { return i; });
console.log(adders.map(f => f()));
var letAdders = [];
for (let j = 0; j < 3; j++) letAdders.push(() => j);
console.log(letAdders.map(f => f()));
console.log((function () { return typeof arguments; })(), (() => 1)(), (x => x * x)(7));
var iife = (function (n) { return n + 1; }(41));
console.log(iife, new Function("a", "b", "return a * b")(6, 7));
function Person(name) { this.name = name; }
Person.prototype.greet = function () { return "hi " + this.name; };
var p = new Person("ann");
console.log(p.greet(), p instanceof Person, p.constructor === Person, Object.getPrototypeOf(p) === Person.prototype);
function NewTarget() { return new.target === NewTarget; }
console.log(new NewTarget() instanceof NewTarget, NewTarget());
console.log(String(add).slice(0, 12), (function () {}).name, (() => {}).name, ({ m() {} }).m.name);
/* expected
3 2 add NaN function
hoisted undefined
named named
2 1
3628800 2432902008176640000
[ 1, 2, 3 ] [ 1, 5, 6 ] 1
0: 2:2,3 1
9 9 [ 'a', 'b', 'c', 1, 2 ]
0  3 1|two|3
obj object ctx,ctx obj
object undefined object number
15 bound add 1 5 7
[ 3, 3, 3 ]
[ 0, 1, 2 ]
object 1 49
42 42
hi ann true true true
true false
function add   m
*/
