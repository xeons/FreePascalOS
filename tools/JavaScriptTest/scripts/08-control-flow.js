// Control flow: loops, labels, switch, try/catch/finally.
let out = [];
for (let i = 0; i < 5; i++) { if (i === 1) continue; if (i === 4) break; out.push(i); }
let w = 0; while (w < 3) w++;
let d = 10; do { d++; } while (d < 5);
console.log(out, w, d);
outer: for (let i = 0; i < 3; i++) {
  inner: for (let j = 0; j < 3; j++) {
    if (j === 2) continue outer;
    if (i === 2) break outer;
    out.push(`${i}${j}`);
  }
}
console.log(out.join(" "));
block: { out = ["in"]; if (out.length) break block; out.push("never"); }
console.log(out);
function sw(v) {
  let r = "";
  switch (v) {
    case 1: r += "one ";
    case 2: r += "two "; break;
    default: r += "default ";
    case 3: r += "three "; break;
    case "1": r += "string"; break;
  }
  return r.trim();
}
console.log(sw(1), "|", sw(2), "|", sw(3), "|", sw(4), "|", sw("1"));
function tf() {
  const log = [];
  try { log.push("try"); throw new Error("x"); }
  catch (e) { log.push("catch " + e.message); }
  finally { log.push("finally"); }
  return log.join(",");
}
console.log(tf());
function finallyOverride() { try { return "try"; } finally { return "finally"; } }
function finallyRuns() { const log = []; for (const v of [1, 2, 3]) { try { if (v === 2) continue; if (v === 3) break; log.push(v); } finally { log.push("f" + v); } } return log.join(","); }
console.log(finallyOverride(), finallyRuns());
function nestedTry() {
  const log = [];
  try {
    try { throw 1; } finally { log.push("inner finally"); }
  } catch (e) { log.push("outer caught " + e); }
  try { try { throw 2; } catch (e) { throw e + 1; } } catch (e) { log.push("rethrown " + e); }
  return log;
}
console.log(nestedTry());
function returnInTry() { let x = 1; try { return x; } finally { x = 2; } }
console.log(returnInTry());
try { undefinedFunction(); } catch { console.log("optional catch binding"); }
const errorInFinally = () => { try { return 1; } finally { throw new Error("from finally"); } };
try { errorInFinally(); } catch (e) { console.log(e.message); }
let count = 0;
for (const ch of "abc") for (const n of [1, 2]) count += n;
console.log(count);
for (var vi = 0, vj = 10; vi < vj; vi += 3, vj -= 3);
console.log(vi, vj);
const obj = { a: 1, b: 2 };
for (const key in obj) { delete obj.b; console.log("key", key); }
let s = "";
for (let i = 3; i--;) s += i;
console.log(s, (() => { switch (true) { case false: return "no"; default: return "yes"; } })());
let caught;
try { null.prop; } catch (e) { caught = e; }
console.log(caught instanceof TypeError, typeof caught.stack);
function deep(n) { return n === 0 ? 0 : 1 + deep(n - 1); }
console.log(deep(3000));
try { (function recurse() { recurse(); })(); } catch (e) { console.log(e.constructor.name, e.message); }
// A return through a finally block that has loops and a try of its own.
const finallyLog = [];
function returnThroughFinally() {
  try {
    return "returned";
  } finally {
    for (const item of [1, 2]) finallyLog.push(item);
    try { finallyLog.push("inner"); } finally { finallyLog.push("inner finally"); }
  }
}
console.log(returnThroughFinally(), finallyLog.join());
/* expected
[ 0, 2, 3 ] 3 11
0 2 3 00 01 10 11
[ 'in' ]
one two | two | three | default three | string
try,catch x,finally
finally 1,f1,f2,f3
[ 'inner finally', 'outer caught 1', 'rethrown 3' ]
1
optional catch binding
from finally
9
6 4
key a
210 yes
true string
3000
RangeError Maximum call stack size exceeded
returned 1,2,inner,inner finally
*/
