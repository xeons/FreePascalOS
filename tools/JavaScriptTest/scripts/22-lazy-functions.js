// Functions long enough to be compiled on their first call: what they
// capture, their kinds, their source text and line numbers.
const outerValue = "outer";
function makeCounter(start) {
  // A long comment so that this function is compiled lazily, and the
  // closures below it too: they capture start, step and outerValue.
  let step = 1;
  const counter = {
    next() {
      // Methods: lazily compiled, reading the captured bindings.
      start += step;
      return start + " " + outerValue + " " + this.label;
    },
    get current() {
      // A getter compiled on first use: its this is the counter.
      return start * 10 + (this.label === "c" ? 1 : 0) + step * 0;
    },
    label: "c",
  };
  counter.faster = () => {
    // An arrow: this and arguments from makeCounter around it.
    step = arguments.length + 1;
    return typeof this;
  };
  return counter;
}
const counter = makeCounter(5);
console.log(counter.next(), counter.current, counter.faster(), counter.next(), counter.current);
const factorial = function fact(n) {
  // A named function expression calling itself by its own name, which
  // the lazy compilation has to give back to it.
  return n <= 1 ? 1 : n * fact(n - 1) + 0 * outerValue.length;
};
console.log(factorial(10));
function* numbers(limit) {
  // A generator, lazily compiled: its flags are known before the body.
  for (let i = 0; i < limit; i++) yield i * 2;
  return "done after " + limit + " values of " + outerValue;
}
console.log([...numbers(4)].join(), numbers(1).next().value);
async function later(value) {
  // An async function compiled when first called; it awaits once.
  const awaited = await Promise.resolve(value);
  return awaited + " " + outerValue + " " + (typeof later);
}
later("async").then(v => console.log(v));
class Base { greet() { return "base"; } }
class Derived extends Base {
  greet() {
    // A class method with super, compiled lazily (no private names).
    const inner = function (x, y = 2) { return x + y + arguments.length; };
    return super.greet() + " derived " + inner(1) + " " + inner(1, 5);
  }
}
console.log(new Derived().greet());
function withDefaults(a, { b = 2, c } = {}, ...rest) {
  // Default values, a destructured parameter and a rest parameter.
  return [a, b, c, rest.length, withDefaults.length].join("/");
}
console.log(withDefaults(1), withDefaults(1, { c: 3 }, 4, 5));
function usesEval(x) {
  // A lazily compiled function with a direct eval inside it, and a
  // with statement: both resolved against the rebuilt scopes.
  const y = x * 2;
  with ({ z: 3 }) { return eval("x + y + z") + outerValue.length; }
}
console.log(usesEval(1));
function shortOne() { return 1; }
console.log(shortOne.toString(), String(makeCounter).slice(0, 29), makeCounter.length, makeCounter.name);
function throwsAtLine() {
  // The stack trace of a lazily compiled function names its own lines,
  // here the line of the throw below this comment.
  throw new Error("line check");
}
try { throwsAtLine(); } catch (e) { console.log(e.stack.split("\n")[1].trim()); }
const nested = (function outer(a) {
  // Three levels of lazily compiled functions, each capturing from the
  // one around it, made and called in order.
  return function middle(b) {
    // The middle one captures a and gives back the innermost.
    return function inner(c) {
      // The innermost reads a and b from two levels up.
      return a + b + c;
    };
  };
})(1)(2)(3);
console.log(nested);
const lateArrow = async value => {
  // An async arrow with one bare parameter, compiled lazily: parsed again
  // from "async", so its body may await (www.bbc.com's data hooks).
  const settled = await value;
  return settled + " arrow";
};
console.log(lateArrow.toString().slice(0, 11));
lateArrow("async").then(v => console.log(v));
/* expected
6 outer c 61 object 8 outer c 81
3628800
0,2,4,6 0
base derived 4 8
1/2//0/1 1/2/3/2/1
11
function shortOne() { return 1; } function makeCounter(start) { 1 makeCounter
at throwsAtLine (22-lazy-functions.js:73:9)
6
async value
async outer function
async arrow
*/
