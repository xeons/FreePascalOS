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

/* expected
3 7 1
5
SyntaxError SyntaxError SyntaxError SyntaxError ok SyntaxError
true false
*/
