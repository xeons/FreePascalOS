// Values, operators, conversions.
var a = 7, b = 2;
console.log(a + b, a - b, a * b, a / b, a % b, a ** b, -a % b);
console.log(1 + 2 * 3, (1 + 2) * 3, 2 ** 3 ** 2, (-2) ** 2);
console.log(5 & 3, 5 | 3, 5 ^ 3, ~5, 1 << 4, -16 >> 2, -16 >>> 28);
console.log(typeof 1, typeof "s", typeof true, typeof undefined, typeof null, typeof {}, typeof [], typeof function () {});
console.log(1 == "1", 1 === "1", null == undefined, null === undefined, NaN == NaN, [1] == 1, "" == 0);
console.log("3" * "4", "3" + 4, 3 + "4", "10" / "4", +"", +" 42 ", +"0x1f", +"1e3", +"abc", -"5");
console.log(true + 1, null + 1, undefined + 1, [] + [], [] + {}, [1, 2] + [3]);
console.log(0.1 + 0.2, 1 / 3, 100 / 3, 1e21, 1e-7, 123456789012345680000, -0, 0 / 0, 1 / 0, -1 / 0);
console.log(2147483647 + 1, -2147483648 - 1, 65536 * 65536, 0.5 * 4, 9007199254740993);
console.log("b" > "a", "B" > "a", "10" < "9", 10 < 9, "10" < 9, null >= 0, undefined >= 0);
console.log(!!"", !!"0", !!0, !!NaN, !![], !!{}, !!null);
var x = 5;
x += 2; x -= 1; x *= 3; x /= 2; x %= 5; x **= 2;
console.log(x, x++, x, ++x, x--, --x);
console.log(String(123), String(-1.5), (255).toString(2), (0.5).toString(16), Number("12px"), parseInt("12px"), parseFloat("3.14abc"));
console.log(isNaN("abc"), isFinite("12"), Number.isNaN("abc"), Number.isInteger(5.0), Number.isSafeInteger(2 ** 53));
console.log(void 0, (1, 2, 3), typeof typeof 1);
/* expected
9 5 14 3.5 1 49 -1
7 9 512 4
1 7 6 -6 16 -4 15
number string boolean undefined object object object function
true false true false false true true
12 34 34 2.5 0 42 31 1000 NaN -5
2 1 NaN  [object Object] 1,23
0.30000000000000004 0.3333333333333333 33.333333333333336 1e+21 1e-7 123456789012345680000 -0 NaN Infinity -Infinity
2147483648 -2147483649 4294967296 2 9007199254740992
true false true false false true false
false true false false true true false
16 16 17 18 18 16
123 -1.5 11111111 0.8 NaN 12 3.14
true true false true false
undefined 3 string
*/
