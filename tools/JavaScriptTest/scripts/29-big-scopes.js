// A bundle's shape: one function in parentheses (compiled at once) whose
// scope holds many names (found by hash), with lazily compiled functions
// inside it (their syntax trees freed once parsed, their scope chains
// shared and restored by name when compiled), nested and calling each
// other, with direct eval, arguments and this from around them.
(function (global) {
  var a0 = 0, a1 = 1, a2 = 2, a3 = 3, a4 = 4, a5 = 5, a6 = 6, a7 = 7, a8 = 8, a9 = 9;
  var b0 = "b0", b1 = "b1", b2 = "b2", b3 = "b3", b4 = "b4", b5 = "b5", b6 = "b6", b7 = "b7";
  var twice = "first";
  var twice;
  let late = "not yet";
  function outer(x) {
    // Long enough to be compiled lazily; it reads names of the big scope
    // and declares one that shadows one of them.
    var a3 = "shadow";
    function middle(y) {
      // Lazily compiled inside a lazily compiled function: its chain is
      // the one outer was compiled from, plus outer's own scope.
      function inner(z) {
        // Three levels in: names from each level and the big scope.
        return [x, y, z, a3, a9, b7, twice, late].join(",") + " " + arguments.length;
      }
      return inner(y + 1, "extra");
    }
    return middle(x + 1);
  }
  late = "set";
  console.log(outer(1));
  var counter = {
    count: 0,
    bump: function (by) {
      // A method compiled lazily: this, and an arrow inside it taking
      // this and arguments from it.
      var self = this;
      var add = () => { self.count += arguments[0]; return this === self; };
      return add() && this.count + a1 + a2;
    }
  };
  console.log(counter.bump(5), counter.bump(10));
  function withEval(code) {
    // A direct eval in a lazily compiled function sees its scopes by name.
    var local = "local value";
    return eval(code);
  }
  console.log(withEval("local + ' ' + b0 + ' ' + a5 + ' ' + typeof outer"));
  function withDefaults(p = a8 * 2, q = function () { return p + a1; }) {
    // Defaults and a function in them, in a function whose tree is freed.
    return q() + b2.length + " " + p;
  }
  console.log(withDefaults(), withDefaults(1));
  function deep(level) {
    // Recursion through a lazily compiled function compiled once.
    return level === 0 ? b5 : deep(level - 1) + (level % 2 ? a1 : a0);
  }
  console.log(deep(6));
  try {
    // A syntax error inside a function that would be lazy is still found
    // when the whole source is parsed.
    eval("(function () { function lazy() { /* a long body, long enough to be lazy: " +
      "padding padding padding padding padding padding padding padding padding */ return 1 +; } })");
    console.log("no error");
  } catch (error) {
    console.log(error instanceof SyntaxError);
  }
  global.bigScopeResult = typeof inner;
})(this);
console.log(bigScopeResult);
/* expected
1,2,3,shadow,9,b7,first,set 2
8 18
local value b0 5 function
19 16 4 1
b5101010
true
undefined
*/
