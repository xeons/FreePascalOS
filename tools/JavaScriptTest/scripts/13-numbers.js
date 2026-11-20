// Numbers, Math, BigInt.
console.log((1234.5678).toFixed(2), (0.5).toFixed(0), (1.5).toFixed(0), (2.5).toFixed(0), (1.005).toFixed(2), (-1.5).toFixed(0), (1e21).toFixed(2));
console.log((123.456).toPrecision(4), (0.00012345).toPrecision(2), (123456).toPrecision(2), (1.5).toPrecision(1), (99.99).toPrecision(3));
console.log((123.456).toExponential(2), (0).toExponential(), (1e-10).toExponential(3), (12345).toExponential());
console.log((255).toString(16), (255).toString(2), (-255).toString(36), (0.1).toString(3).slice(0, 10), (3.75).toString(2));
console.log(Number.MAX_SAFE_INTEGER, Number.MIN_VALUE, Number.MAX_VALUE, Number.EPSILON > 0, Number.parseFloat === parseFloat);
console.log(parseInt("  42abc"), parseInt("0x1F"), parseInt("101", 2), parseInt("z", 36), parseInt(""), parseInt("-0"), parseInt(0.0000005), parseInt("12", 50));
console.log(parseFloat(".5e1"), parseFloat("-Infinityx"), parseFloat("1.2.3"), Number(""), Number(" 0b101 "), Number("1_000"), Number(null), Number([5]), Number([1, 2]));
console.log(1e300 * 1e10, -1e300 * 1e10, 5 / 0, -5 / 0, 0 / 0, 2 ** 1024, 2 ** -1080, 0.1 * 3);
console.log(Math.round(0.49999999999999994), Math.round(-0.5), Math.round(2.5), Math.trunc(-4.7), Math.sign(-3), Math.cbrt(27), Math.hypot(3, 4));
console.log(Math.max(), Math.min(), Math.max(1, NaN), Math.min(0, -0), Math.abs(-7.5), Math.floor(-0.5), Math.ceil(-0.5));
console.log(Math.sqrt(2), Math.log(Math.E), Math.log2(8), Math.log10(1000), Math.exp(0), Math.pow(2, 0.5) === Math.SQRT2, Math.clz32(1), Math.imul(0xffffffff, 5), Math.fround(5.5));
console.log(Math.sin(0), Math.cos(Math.PI).toFixed(5), Math.atan2(1, 1).toFixed(6), Math.asinh(1).toFixed(6), Math.expm1(0), Math.log1p(0));
const r = Math.random();
console.log(r >= 0 && r < 1, typeof r);
console.log(0.1 + 0.2 === 0.3, Math.abs(0.3 - (0.1 + 0.2)) < Number.EPSILON, 1 / 3 * 3, 9007199254740992 + 1, 4.35 * 100);
console.log(5..toString(), 1e3, 1.5e-7, 123e-20, 0.000001, 0.0000001, 1e21, 999999999999999900000, -1e-7);
console.log((25).toString(36), Number("0o17"), 0b1010, 0o777, 0xff, 1_000_000, .5, 5.);
console.log(10n ** 30n, 2n ** 64n - 1n, -(2n ** 63n), 7n / 2n, -7n / 2n, 7n % -2n, -7n % 2n, 5n * -3n);
console.log(1n << 70n, (1n << 70n) >> 69n, -9n >> 1n, 5n & 3n, 5n | 3n, 5n ^ 3n, ~5n, -(-5n));
console.log(BigInt(123), BigInt("0xff"), BigInt("-42"), BigInt(true), BigInt.asIntN(8, 255n), BigInt.asUintN(8, -1n), BigInt(Number.MAX_SAFE_INTEGER) + 2n);
console.log(typeof 1n, 1n == 1, 1n === 1, 2n > 1, 1 < 2n, 10n > 9, "10" == 10n, 0n ? "t" : "f", 1n + "", (255n).toString(16));
try { 1n + 1; } catch (e) { console.log(e.name, e.message); }
try { BigInt(1.5); } catch (e) { console.log(e.name); }
try { 1n / 0n; } catch (e) { console.log(e.name, e.message); }
console.log([3n, 1n, 2n].sort((a, b) => (a < b ? -1 : 1)), new Map([[1n, "big"]]).get(1n), JSON.stringify({ n: 1 }), 2n ** 100n % 1000n);
console.log(Number(123n), parseInt("123n"), BigInt(Number.MAX_VALUE).toString().length, (2n ** 200n).toString().length);
const num = new Number(5);
console.log(typeof num, num + 1, num.valueOf() === 5, Object.prototype.toString.call(num), (12.5).toLocaleString());
/* expected
1234.57 1 2 3 1.00 -2 1e+21
123.5 0.00012 1.2e+5 2 100
1.23e+2 0e+0 1.000e-10 1.2345e+4
ff 11111111 -73 0.00220022 11.11
9007199254740991 4.9e-324 1.7976931348623157e+308 true true
42 31 5 35 NaN -0 5 NaN
5 -Infinity 1.2 0 5 NaN 0 5 NaN
Infinity -Infinity Infinity -Infinity NaN Infinity 0 0.30000000000000004
0 -0 3 -4 -1 3 5
-Infinity Infinity NaN -0 7.5 -1 -0
1.4142135623730951 1 3 3 1 true 31 -5 5.5
0 -1.00000 0.785398 0.881374 0 0
true number
false true 1 9007199254740992 434.99999999999994
5 1000 1.5e-7 1.23e-18 0.000001 1e-7 1e+21 999999999999999900000 -1e-7
p 15 10 511 255 1000000 0.5 5
1000000000000000000000000000000n 18446744073709551615n -9223372036854775808n 3n -3n 1n -1n -15n
1180591620717411303424n 2n -5n 1n 7n 6n -6n 5n
123n 255n -42n 1n -1n 255n 9007199254740993n
bigint true false true true true true f 1 ff
TypeError Cannot mix BigInt and other types, use explicit conversions
RangeError
RangeError Division by zero
[ 1n, 2n, 3n ] big {"n":1} 376n
123 123 309 61
object 6 true [object Number] 12.5
*/
