// Strings, Unicode, templates.
const s = "Hello, World";
console.log(s.length, s[0], s.charAt(7), s.charCodeAt(1), s.indexOf("o"), s.lastIndexOf("o"), s.includes("World"), s.startsWith("Hell"), s.endsWith("ld"));
console.log(s.slice(-5), s.substring(7), s.substr(1, 3), s.toUpperCase(), s.toLowerCase(), s.split(", "), s.at(-1));
console.log("  pad ".trim() + "|", "  pad ".trimStart() + "|", "|" + "  pad ".trimEnd(), "5".padStart(3, "0"), "ab".padEnd(5, "-"), "na".repeat(3));
console.log("a-b-c".replace("-", "+"), "a-b-c".replaceAll("-", "+"), "a-b-c".split("-", 2), "".split(","), "abc".split(""));
console.log("😀".length, [..."😀"].length, "😀".codePointAt(0), "😀".charCodeAt(0), String.fromCodePoint(128512) === "😀", String.fromCharCode(72, 105));
console.log("ÄÖÜ ß straße".toLowerCase(), "ß".toUpperCase(), "é".normalize("NFC").length, "İ".length);
console.log("abc" < "abd", "a".localeCompare("b"), "b".localeCompare("a"), "a".localeCompare("a"), "Z" < "a");
const name = "world", n = 3;
console.log(`Hello ${name}! ${n} + ${n} = ${n + n}`, `multi
line`, `nested ${`inner ${n}`}`, `${[1, 2]}`, `${{}}`);
function tag(strings, ...values) { return strings.raw.join("|") + " :: " + values.join(",") + " :: " + strings.length; }
console.log(tag`a${1}b${2}c`, tag`\n${"x"}`, String.raw`C:\path\${n}`);
const sameSite = () => tag => tag;
const t1 = (s => s)`x`, t2 = (s => s)`x`;
console.log(Object.isFrozen(t1), Array.isArray(t1.raw), t1 === t2);
console.log("\u0041\x42\u{43}", "tab\tend", "quote\"s", 'single\'s', "back\\slash", "\0".length);
console.log(encodeURIComponent("a b&c=d/é"), decodeURIComponent("%E2%82%AC%20"), encodeURI("http://x.y/a b?q=1&r=é#f"));
let built = "";
for (let i = 0; i < 1000; i++) built += i % 10;
console.log(built.length, built.slice(0, 12), built[999]);
const big = "x".repeat(100000);
console.log(big.length, (big + big).length, big.indexOf("y"));
console.log("abc".concat("def", 1), "a,b".split(/,/), " x ".trim().length, "aaa".lastIndexOf("a", 1), "abc".search("c"));
console.log(String(null), String(undefined), String(123n), String(Symbol("d")), [1, [2, 3]].toString(), String(-0));
console.log("lone \uD800 surrogate".isWellFormed(), "fine".isWellFormed(), "x\uDC00".toWellFormed().charCodeAt(1).toString(16));
console.log("Mississippi".split("ss"), "abc".match(/b/).index, "aBc".toUpperCase() === "ABC", "ﬃ".length);
const str = new String("boxed");
console.log(typeof str, str.length, str[1], str + "!", Object.keys(str), str instanceof String, JSON.stringify(str));
/* expected
12 H W 101 4 8 true true true
World World ell HELLO, WORLD hello, world [ 'Hello', 'World' ] d
pad| pad | |  pad 005 ab--- nanana
a+b-c a+b+c [ 'a', 'b' ] [ '' ] [ 'a', 'b', 'c' ]
2 1 128512 55357 true Hi
äöü ß straße SS 1 1
true -1 1 0 true
Hello world! 3 + 3 = 6 multi
line nested inner 3 1,2 [object Object]
a|b|c :: 1,2 :: 3 \n| :: x :: 2 C:\path\${n}
true true false
ABC tab	end quote"s single's back\slash 1
a%20b%26c%3Dd%2F%C3%A9 €  http://x.y/a%20b?q=1&r=%C3%A9#f
1000 012345678901 9
100000 200000 -1
abcdef1 [ 'a', 'b' ] 1 1 2
null undefined 123 Symbol(d) 1,2,3 0
false true fffd
[ 'Mi', 'i', 'ippi' ] 1 true 1
object 5 o boxed! [ '0', '1', '2', '3', '4' ] true "boxed"
*/
