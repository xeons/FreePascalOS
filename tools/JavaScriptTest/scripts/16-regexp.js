console.log(/a(b+)c/.exec("xxabbbcyy"), /^\d{3}-\d{4}$/.test("555-1234"), /colou?r/i.test("COLOR"));
console.log("2024-01-15".replace(/(\d+)-(\d+)-(\d+)/, "$3/$2/$1"), "a1b2c3".replace(/\d/g, d => d * 2));
console.log("one two  three".split(/\s+/), "a,b;c".split(/[,;]/), "abc".split(""));
console.log("The Quick Brown".match(/[A-Z]/g), "no match".match(/xyz/), "aaa".lastIndexOf("a"));
const m = /(?<year>\d{4})-(?<month>\d{2})/.exec("on 2024-03");
console.log(m.groups.year, m.groups.month, m.index);
console.log([..."a1b22c333".matchAll(/\d+/g)].map(x => x[0]));
console.log(/(?<=\$)\d+/.exec("cost $42")[0], /(?<!\$)\b\d+/.exec("cost $42 or 17")[0], /\d+(?=%)/.exec("50% off")[0]);
console.log(/(a)\1/.test("aa"), /^(?:a|b)*$/.test("abab"), /a.c/s.test("a\nc"), /a.c/.test("a\nc"));
console.log("x".padEnd(3, "ab"), /\u{1F600}/u.test("😀"), /^.$/u.test("😀"), /^.$/.test("😀"));
console.log("aBc".replace(/b/i, "[$&]"), "abc".search(/c/), /[^a-c]+/.exec("abcdef")[0]);
const re = /o/g; console.log(re.test("foo"), re.lastIndex, re.test("foo"), re.lastIndex, re.test("foo"));
console.log(String(/a\/b/g), /\bfoo\b/.test("a foo b"), /(a*)*b/.test("aaaab"), "tel: 555".replace(/(?<n>\d+)/, "<$<n>>"));
console.log(/(\w+)\s(\w+)/[Symbol.replace]("John Smith", "$2, $1"), RegExp("a+", "g").flags, new RegExp(/x/g).global);
/* expected
[ 'abbbc', 'bbb', index: 2, input: 'xxabbbcyy', groups: undefined ] true true
15/01/2024 a2b4c6
[ 'one', 'two', 'three' ] [ 'a', 'b', 'c' ] [ 'a', 'b', 'c' ]
[ 'T', 'Q', 'B' ] null 2
2024 03 3
[ '1', '22', '333' ]
42 17 50
true true true false
xab true true false
a[B]c 2 def
true 2 true 3 false
/a\/b/g true true tel: <555>
Smith, John g true
*/
