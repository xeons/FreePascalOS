// Leaving a for-of early over an iterator without a return method (Map
// and Set iterators: ECMA-262 IteratorClose has nothing to call), and
// with one; case mapping of strings and case-insensitive classes with
// lone surrogates (left as they are; the run-time library refused them).
const flags = new Map([["a", true], ["b", false], ["c", true]]);
function firstFalse() { for (const [key, value] of flags) if (!value) return key; return "none"; }
function allTrue() { for (const value of flags.values()) if (!value) return false; return true; }
console.log(firstFalse(), allTrue());
let found = "";
for (const item of new Set(["x", "y", "z"])) { if (item === "y") break; found += item; }
console.log(found);
let closed = 0;
const custom = { [Symbol.iterator]() { let n = 0; return { next() { return { value: n++, done: n > 5 }; }, return() { closed++; return {}; } }; } };
for (const n of custom) if (n === 2) break;
console.log(closed);
const bad = { [Symbol.iterator]() { return { next() { return { value: 1, done: false }; }, return() { return 5; } }; } };
try { for (const n of bad) break; } catch (e) { console.log(e.constructor.name); }
console.log("a\uD800B".toLowerCase() === "a\uD800b", "\uDC00x".toUpperCase() === "\uDC00X",
  "😀A".toLowerCase() === "😀a");
console.log(/[\uD800-\uDFFF]/i.test("\uDC01"), /[a-z\uD800-\uDBFF]+/i.test("ABC"), /\uDC00/i.test("\uDC00"));
/* expected
b false
x
1
TypeError
true true true
true true true
*/
