// Annex B (escape, HTML methods, legacy accessors, RegExp statics), normalize, Intl.
console.log(escape("a b+c/ä€\u0001"), unescape("%41%u20AC%zz%4"), unescape(escape("Grüße, 世界!")));
console.log("x".anchor('a"b'), "y".bold(), "z".link("u"), "w".fontsize(3), "v".sub());
const o = {};
o.__defineGetter__("g", function () { return 42; });
o.__defineSetter__("s", function (v) { this.stored = v; });
o.s = 5;
console.log(o.g, o.stored, typeof o.__lookupGetter__("g"), o.__lookupSetter__("g"), Object.keys(o).join());
console.log({}.__lookupGetter__("__proto__") === Object.getOwnPropertyDescriptor(Object.prototype, "__proto__").get);
/(\d+)-(\d+)/.exec("call 555-1234 now");
console.log(RegExp.$1, RegExp.$2, RegExp.$3 === "", RegExp.lastMatch, RegExp["$&"], RegExp.leftContext, RegExp.rightContext, RegExp.lastParen, RegExp.input);
"abc".replace(/b/, "X");
console.log(RegExp.lastMatch, RegExp["$`"], RegExp["$'"], RegExp.$_);
RegExp.input = "set";
console.log(RegExp.input, "abc".substr(-2, 1));
const show = s => [...s].map(c => c.codePointAt(0).toString(16).padStart(4, "0")).join(" ");
console.log(show("é".normalize("NFD")), show("é".normalize("NFC")), "é".normalize() === "é");
console.log(show("Ặ".normalize("NFD")), show("Ặ".normalize("NFC")), show("Ặ".normalize("NFC")));
console.log(show("Ặ".normalize("NFC")), show("q̣̇".normalize("NFC")), show("q̣̇".normalize("NFD")));
console.log(show("한글".normalize("NFD")), "한글".normalize("NFD").normalize("NFC") === "한글", show("간".normalize()));
console.log("ﬁ ① ½ Ⅻ ２".normalize("NFKC"), show("Ǆ".normalize("NFKD")), show("ẞ".normalize("NFD")));
console.log(show("Å".normalize("NFC")), show("̈́".normalize("NFC")), show("Ё й ἀ".normalize("NFD")));
console.log("abc".normalize("NFKD"), "Crème brûlée".normalize("NFD").length, "Crème brûlée".normalize("NFD").normalize("NFC") === "Crème brûlée");
try { "x".normalize("nfc"); } catch (e) { console.log(e.constructor.name); }
const nf = new Intl.NumberFormat("en-US");
console.log(nf.format(1234567.891), nf.format(-0), nf.format(0.1 + 0.2), nf.format(1e21), nf.format(NaN), nf.format(-Infinity), nf.format(12345678901234567890n));
console.log(new Intl.NumberFormat("en", { style: "currency", currency: "USD" }).format(-1234.5), new Intl.NumberFormat("en", { style: "currency", currency: "JPY" }).format(1234.5), new Intl.NumberFormat("en", { style: "currency", currency: "CHF" }).format(3));
console.log(new Intl.NumberFormat("en", { style: "percent" }).format(0.256), new Intl.NumberFormat("en", { maximumSignificantDigits: 3 }).format(123456), new Intl.NumberFormat("en", { minimumFractionDigits: 2 }).format(5), new Intl.NumberFormat("en", { maximumFractionDigits: 0 }).format(2.5));
console.log(new Intl.NumberFormat("en", { style: "unit", unit: "kilometer-per-hour" }).format(50), new Intl.NumberFormat("en", { style: "unit", unit: "liter", unitDisplay: "long" }).format(1), new Intl.NumberFormat("en", { signDisplay: "always" }).format(3), new Intl.NumberFormat("en", { useGrouping: false }).format(12345));
console.log(JSON.stringify(nf.formatToParts(-1234.5)), (1234.5).toLocaleString(), (1234.5).toLocaleString("en-US", { style: "currency", currency: "EUR" }), 123456789n.toLocaleString());
const d = new Date(Date.UTC(2026, 10, 20, 15, 4, 5));
const utc = { timeZone: "UTC" };
console.log(new Intl.DateTimeFormat("en-US", utc).format(d), d.toLocaleString("en-US", utc), d.toLocaleDateString("en-US", utc), d.toLocaleTimeString("en-US", utc));
console.log(new Intl.DateTimeFormat("en-US", { ...utc, dateStyle: "full", timeStyle: "short" }).format(d), new Intl.DateTimeFormat("en-US", { ...utc, dateStyle: "medium" }).format(d), new Intl.DateTimeFormat("en-US", { ...utc, dateStyle: "short" }).format(d));
console.log(new Intl.DateTimeFormat("en-US", { ...utc, weekday: "long", year: "numeric", month: "long", day: "numeric" }).format(d), new Intl.DateTimeFormat("en-US", { ...utc, hour: "2-digit", minute: "2-digit", hour12: false }).format(d), new Intl.DateTimeFormat("en-US", { ...utc, month: "short", day: "numeric" }).format(d), new Intl.DateTimeFormat("en-US", { ...utc, timeStyle: "long" }).format(d));
console.log(JSON.stringify(new Intl.DateTimeFormat("en-US", utc).formatToParts(d).map(p => p.type)), new Intl.DateTimeFormat("en-US", utc).resolvedOptions().timeZone, Intl.DateTimeFormat().resolvedOptions().locale);
const coll = new Intl.Collator("en");
console.log(["b", "a", "B", "é", "e"].sort(coll.compare).join(), new Intl.Collator("en", { sensitivity: "base" }).compare("é", "E"), new Intl.Collator("en", { numeric: true }).compare("item10", "item9"), "a".localeCompare("b"));
const pr = new Intl.PluralRules("en-US"), po = new Intl.PluralRules("en-US", { type: "ordinal" });
console.log(pr.select(1), pr.select(2), pr.select(1.5), [1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 101].map(n => po.select(n)).join());
const seg = new Intl.Segmenter("en", { granularity: "grapheme" });
console.log([...seg.segment("é👍🏽🇫🇷👨‍👩‍👧한\r\nx")].map(s => s.segment).length, [...seg.segment("abc")].map(s => s.index).join());
const words = new Intl.Segmenter("en", { granularity: "word" });
console.log([...words.segment("Hello, world! It's 3.5 km.")].filter(s => s.isWordLike).map(s => s.segment).join("|"));
console.log([...new Intl.Segmenter("en", { granularity: "sentence" }).segment("One. Two? Three!")].map(s => s.segment).join("|"), seg.segment("abc").containing(1).segment);
console.log(new Intl.ListFormat("en").format(["a", "b", "c"]), new Intl.ListFormat("en", { type: "disjunction" }).format(["a", "b"]), new Intl.ListFormat("en", { style: "short" }).format(["x", "y", "z"]), new Intl.ListFormat("en", { type: "unit" }).format(["1", "2"]));
console.log(Intl.getCanonicalLocales(["EN-us", "de-de"]).join(), Intl.NumberFormat.supportedLocalesOf(["en-GB", "fr"]).join(), Object.prototype.toString.call(Intl), Object.prototype.toString.call(nf));
try { new Intl.NumberFormat("en", { style: "bogus" }); } catch (e) { console.log(e.constructor.name); }
try { Intl.getCanonicalLocales("x_"); } catch (e) { console.log(e.constructor.name); }
/* expected
a%20b+c/%E4%u20AC%01 A€%zz%4 Grüße, 世界!
<a name="a&quot;b">x</a> <b>y</b> <a href="u">z</a> <font size="3">w</font> <sub>v</sub>
42 5 function undefined g,s,stored
true
555 1234 true 555-1234 555-1234 call   now 1234 call 555-1234 now
b a c abc
set b
0065 0301 00e9 true
0041 0323 0306 1eb6 1eb6
1eb6 0071 0323 0307 0071 0323 0307
1112 1161 11ab 1100 1173 11af true ac04
fi 1 1⁄2 XII 2 0044 005a 030c 1e9e
00c5 0308 0301 0415 0308 0020 0438 0306 0020 1f00
abc 15 true
RangeError
1,234,567.891 -0 0.3 1,000,000,000,000,000,000,000 NaN -∞ 12,345,678,901,234,567,890
-$1,234.50 ¥1,235 CHF 3.00
26% 123,000 5.00 3
50 km/h 1 liter +3 12345
[{"type":"minusSign","value":"-"},{"type":"integer","value":"1"},{"type":"group","value":","},{"type":"integer","value":"234"},{"type":"decimal","value":"."},{"type":"fraction","value":"5"}] 1,234.5 €1,234.50 123,456,789
11/20/2026 11/20/2026, 3:04:05 PM 11/20/2026 3:04:05 PM
Friday, November 20, 2026 at 3:04 PM Nov 20, 2026 11/20/26
Friday, November 20, 2026 15:04 Nov 20 3:04:05 PM UTC
["month","literal","day","literal","year"] UTC en-US
B,a,b,e,é 0 1 -1
one other other one,two,few,other,other,other,other,one,two,few,one
7 0,1,2
Hello|world|It's|3.5|km
One. |Two? |Three! b
a, b, and c a or b x, y, & z 1, 2
en-US,de-DE en-GB [object Intl] [object Intl.NumberFormat]
RangeError
RangeError
*/
