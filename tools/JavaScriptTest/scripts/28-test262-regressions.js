// Fixes found by test262 (make test262).

// Unicode escapes in identifiers, also beyond the BMP, and Other_ID_Start.
function a(\u{62}, c) { return b + c; }
var \u{1d453}\u{1d45c}\u{1d465} = 7, ℘ = 1;
console.log(a(1, 2), 𝑓𝑜𝑥, ℘);
class Counter {
  #\u{6F} = 2;
  #℘ = 3;
  get sum() { return this.#o + this.#℘; }
}
console.log(new Counter().sum);

// Regular expression literals are checked when the script is parsed.
function parses(source) {
  try { new Function(source); return "ok"; } catch (e) { return e.name; }
}
console.log(parses("if (false) /(?<a>x)(?<a>y)/;"), parses("if (false) /a/gg;"), parses("if (false) /a/uv;"),
  parses("if (false) /\\p{Nope}/u;"), parses("if (false) /\\p{Emoji}/u;"), parses("if (false) /a{2,1}/;"));
console.log(/\p{Lu}\p{gc=Pd}\p{Nl}/u.test("A-Ⅻ"), /\p{LC}/u.test("1"));

// Proxies of arrays are arrays; a trap may revoke its own proxy.
var arrayProxy = new Proxy([1, 2], {});
console.log(Array.isArray(arrayProxy), Object.prototype.toString.call(arrayProxy), JSON.stringify(arrayProxy),
  [0].concat(arrayProxy).length);
var handle = Proxy.revocable([], { get: function () { handle.revoke(); } });
console.log(Object.prototype.toString.call(handle.proxy));
try { Array.isArray(handle.proxy); } catch (e) { console.log(e.name); }

// Typed array stores, collections from endless iterables, length limits.
var bigints = new BigInt64Array(1);
try { bigints[0] = null; } catch (e) { console.log(e.name); }
var endless = { [Symbol.iterator]() { return { next() { return { value: 1, done: false }; }, return() { return {}; } }; } };
try { new WeakMap(endless); } catch (e) { console.log(e.name); }
try { Array.prototype.splice.call({ length: 2 ** 53 - 1 }, 0, 0, 1); } catch (e) { console.log(e.name); }

// Early errors found when the script is parsed.
console.log(parses("var \\u0062reak = 1;"), parses("({ \\u0062reak: 1 }).break;"), parses("[...x = []] = [];"),
  parses("{ async function f() {} async function f() {} }"), parses("{ function f() {} function f() {} }"),
  parses("class C { m() { return this.#x; } }"), parses("class C { #x; m() { return this.#x; } }"),
  parses("class C { x = arguments; }"), parses("class C { x = function () { return arguments; }; }"));

/* expected
3 7 1
5
SyntaxError SyntaxError SyntaxError SyntaxError ok SyntaxError
true false
true [object Array] [1,2] 3
[object Array]
TypeError
TypeError
TypeError
TypeError
SyntaxError ok SyntaxError SyntaxError ok SyntaxError ok SyntaxError ok
*/
