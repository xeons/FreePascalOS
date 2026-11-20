// JSON, Symbols, Proxy, Reflect, errors.
console.log(JSON.stringify({ s: "q\"uote\n", n: 1.5, b: false, nul: null, u: undefined, f() {}, sym: Symbol("x"), d: new Date(0), nested: [1, { a: [] }] }));
console.log(JSON.stringify([undefined, function () {}, NaN, Infinity]), JSON.stringify(" \ud800"), JSON.stringify(undefined), JSON.stringify(null));
console.log(JSON.stringify({ a: 1, b: { c: 2 } }, null, "--"), JSON.stringify([1, [2]], null, 1));
console.log(JSON.stringify({ a: 1, b: 2, c: 3 }, ["a", "c"]), JSON.stringify({ a: 1, b: "x" }, (k, v) => (typeof v === "number" ? v * 10 : v)));
console.log(JSON.stringify({ toJSON() { return { replaced: true }; } }), JSON.stringify(new Map([[1, 2]])), JSON.stringify(Object.create({ inherited: 1 })));
const parsed = JSON.parse('{"a":[1,2,{"b":null}],"c":"\\u0041\\n","d":-1.5e2,"e":true}');
console.log(parsed, parsed.c.length);
console.log(JSON.parse("[1,2,3]", (k, v) => (Array.isArray(v) ? v : v * 2)), JSON.parse(" 42 "), JSON.parse('"str"'));
for (const bad of ["{a:1}", "[1,]", "'x'", "", "01", "{\"a\":1}x"]) { try { JSON.parse(bad); console.log("parsed", bad); } catch (e) { console.log(e.name); } }
const circular = {}; circular.self = circular;
try { JSON.stringify(circular); } catch (e) { console.log(e.name, e.message); }
try { JSON.stringify({ big: 1n }); } catch (e) { console.log(e.name); }
const s1 = Symbol("desc"), s2 = Symbol("desc");
console.log(s1 === s2, s1.toString(), s1.description, typeof s1, Symbol.for("k") === Symbol.for("k"), Symbol.keyFor(Symbol.for("k")), Symbol.keyFor(s1));
const withSym = { [s1]: 1, regular: 2 };
console.log(Object.keys(withSym), Object.getOwnPropertySymbols(withSym).length, withSym[s1], JSON.stringify(withSym));
const custom = { [Symbol.toPrimitive](hint) { return hint === "number" ? 42 : "str:" + hint; } };
console.log(+custom, `${custom}`, custom + "", custom * 2);
class Even { static [Symbol.hasInstance](n) { return n % 2 === 0; } }
console.log(2 instanceof Even, 3 instanceof Even, Symbol.iterator.toString(), Object(Symbol("w")) instanceof Symbol);
try { Symbol() + ""; } catch (e) { console.log(e.name); }
const handlerLog = [];
const proxy = new Proxy({ x: 1 }, {
  get(t, k, r) { handlerLog.push("get " + String(k)); return k in t ? t[k] : "default"; },
  set(t, k, v) { handlerLog.push("set " + k); t[k] = v * 2; return true; },
  has(t, k) { return k.startsWith("x"); },
  deleteProperty(t, k) { handlerLog.push("delete " + k); return delete t[k]; },
  ownKeys(t) { return [...Reflect.ownKeys(t), "virtual"]; },
  getOwnPropertyDescriptor(t, k) { return k === "virtual" ? { value: "v", enumerable: true, configurable: true } : Reflect.getOwnPropertyDescriptor(t, k); }
});
proxy.y = 5;
console.log(proxy.x, proxy.y, proxy.missing, "xyz" in proxy, "abc" in proxy, delete proxy.x, Object.keys(proxy));
console.log(handlerLog.join(", "));
const fnProxy = new Proxy(function (a, b) { return a + b; }, { apply(t, self, args) { return t(...args) * 100; }, construct(t, args) { return { made: args }; } });
console.log(fnProxy(1, 2), new fnProxy(7).made, typeof fnProxy);
const { proxy: revocable, revoke } = Proxy.revocable({}, {});
revoke();
try { revocable.x; } catch (e) { console.log(e.name); }
console.log(Reflect.has({ a: 1 }, "a"), Reflect.ownKeys([1]), Reflect.get({ get g() { return this.v; } }, "g", { v: "receiver" }), Reflect.apply(Math.max, null, [1, 5]));
console.log(Reflect.construct(Date, [0]).getTime(), Reflect.defineProperty({}, "x", { value: 1 }), Reflect.getPrototypeOf([]) === Array.prototype, Reflect.isExtensible(Object.preventExtensions({})));
const errors = [new Error("e"), new TypeError("t"), new RangeError("r"), new SyntaxError("s"), new ReferenceError("f"), new URIError("u"), new EvalError("v")];
console.log(errors.map(e => `${e.name}:${e.message}:${e instanceof Error}`).join(" "));
const withCause = new Error("outer", { cause: new Error("inner") });
console.log(withCause.cause.message, "cause" in new Error("x"), Object.keys(new Error("x")), new Error().message === "");
const agg = new AggregateError([new Error("a"), "b"], "many");
console.log(agg.name, agg.message, agg.errors.length, agg instanceof Error);
function thrower() { throw new Error("traced"); }
try { thrower(); } catch (e) { console.log(e.stack.split("\n")[0], e.stack.split("\n")[1].trim().startsWith("at thrower")); }
try { undefined.prop; } catch (e) { console.log(e.message); }
try { null(); } catch (e) { console.log(e.constructor === TypeError); }
try { new (function () {}.bind())().x.y; } catch (e) { console.log(e.name); }
try { throw { custom: "object" }; } catch (e) { console.log(e.custom); }
console.log(String(new TypeError("msg")), Error.prototype.toString.call({ name: "N", message: "M" }), new Error("x") instanceof Object);
/* expected
{"s":"q\"uote\n","n":1.5,"b":false,"nul":null,"d":"1970-01-01T00:00:00.000Z","nested":[1,{"a":[]}]}
[null,null,null,null] " \ud800" undefined null
{
--"a": 1,
--"b": {
----"c": 2
--}
} [
 1,
 [
  2
 ]
]
{"a":1,"c":3} {"a":10,"b":"x"}
{"replaced":true} {} {}
{ a: [ 1, 2, { b: null } ], c: 'A\n', d: -150, e: true } 2
[ 2, 4, 6 ] 42 str
SyntaxError
SyntaxError
SyntaxError
SyntaxError
SyntaxError
SyntaxError
TypeError Converting circular structure to JSON
TypeError
false Symbol(desc) desc symbol true k undefined
[ 'regular' ] 1 1 {"regular":2}
42 str:string str:default 84
true false Symbol(Symbol.iterator) true
TypeError
1 10 default true false true [ 'y', 'virtual' ]
set y, get x, get y, get missing, delete x
300 [ 7 ] function
TypeError
true [ '0', 'length' ] receiver 5
0 true true false
Error:e:true TypeError:t:true RangeError:r:true SyntaxError:s:true ReferenceError:f:true URIError:u:true EvalError:v:true
inner false [] true
AggregateError many 2 true
Error: traced true
Cannot read properties of undefined (reading 'prop')
true
TypeError
object
TypeError: msg N: M true
*/
