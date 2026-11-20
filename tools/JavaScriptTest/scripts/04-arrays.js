// Arrays and their methods.
var a = [5, 3, 8, 1];
console.log(a.map(x => x * 2), a.filter(x => x > 2), a.reduce((s, x) => s + x, 0), a.reduceRight((s, x) => s + x, ""));
console.log(a.slice().sort((x, y) => x - y), a.slice().sort(), a.indexOf(8), a.lastIndexOf(9), a.includes(3));
console.log([10, 9, 1, 100].sort(), ["b", "a", "C"].sort(), [3, 1, 2].reverse());
var b = [1, 2, 3];
console.log(b.push(4, 5), b, b.pop(), b.shift(), b.unshift(0), b);
var c = [1, 2, 3, 4, 5];
console.log(c.splice(1, 2), c, c.splice(1, 0, "x", "y"), c, c.splice(-1), c);
console.log([1, [2, [3, [4]]]].flat(), [1, [2, [3, [4]]]].flat(Infinity), [1, 2].flatMap(x => [x, x * 10]));
console.log(Array.from("abc"), Array.from({ length: 3 }, (_, i) => i * i), Array.of(7, 8), Array(3), Array(3).length, [, 1, , 2]);
console.log([1, 2, 3].join(), [1, null, undefined, 2].join("-"), [[1, 2], [3]].toString(), String([]));
console.log([1, 2, 3].find(x => x > 1), [1, 2, 3].findIndex(x => x > 5), [1, 2, 3].findLast(x => x < 3), [1, 2, 3, 4].findLastIndex(x => x % 2));
console.log([1, 2, 3].some(x => x > 2), [1, 2, 3].every(x => x > 0), [].every(x => false), [].some(x => true));
console.log([0, 1, 2].fill(9, 1), new Array(3).fill(0), [1, 2, 3, 4, 5].copyWithin(0, 3), [1, 2, 3].at(-1), [1, 2, 3].at(5));
console.log([...[1, 2].entries()], [...["a", "b"].keys()], [...["x"].values()]);
console.log([3, 1, 2].toSorted(), [1, 2, 3].toReversed(), [1, 2, 3].with(1, 9), [1, 2, 3, 4].toSpliced(1, 2, "z"));
var holes = [1, , 3];
console.log(holes.length, 1 in holes, holes.map(x => x * 2), holes.indexOf(undefined), holes.includes(undefined));
var len = [1, 2, 3, 4];
len.length = 2;
console.log(len, len.length);
len[5] = 6;
console.log(len, len.length);
console.log([1, 2, 3].concat(4, [5, [6]]), Array.isArray([]), Array.isArray({ length: 0 }));
var arrayLike = { 0: "a", 1: "b", length: 2 };
console.log(Array.prototype.map.call(arrayLike, x => x.toUpperCase()), Array.prototype.join.call(arrayLike, "+"));
var stable = [{ k: 1, v: "a" }, { k: 0, v: "b" }, { k: 1, v: "c" }, { k: 0, v: "d" }];
console.log(stable.sort((x, y) => x.k - y.k).map(x => x.v).join(""));
var nested = [[3, "c"], [1, "a"], [2, "b"]];
nested.sort();
console.log(nested.map(p => p[1]).join(""), [undefined, 3, , 1].sort());
var big = [];
for (var i = 0; i < 10000; i++) big.push(i * 7 % 10007);
big.sort((x, y) => x - y);
console.log(big[0], big.every((v, i) => i == 0 || big[i - 1] <= v), big.length);
console.log([1, 2, 3].forEach(x => x), typeof [].keys().next, [..."héllo"].length);
var cyclic = [1, 2];
cyclic.push(cyclic);
console.log(cyclic.join(","), String(cyclic));
console.log([1, 2, 3].map((x, i, arr) => arr.length + i), [0, -0, NaN].indexOf(NaN), [NaN].includes(NaN));
/* expected
[ 10, 6, 16, 2 ] [ 5, 3, 8 ] 17 1835
[ 1, 3, 5, 8 ] [ 1, 3, 5, 8 ] 2 -1 true
[ 1, 10, 100, 9 ] [ 'C', 'a', 'b' ] [ 2, 1, 3 ]
5 [ 0, 2, 3, 4 ] 5 1 4 [ 0, 2, 3, 4 ]
[ 2, 3 ] [ 1, 'x', 'y', 4 ] [] [ 1, 'x', 'y', 4 ] [ 5 ] [ 1, 'x', 'y', 4 ]
[ 1, 2, [ 3, [ 4 ] ] ] [ 1, 2, 3, 4 ] [ 1, 10, 2, 20 ]
[ 'a', 'b', 'c' ] [ 0, 1, 4 ] [ 7, 8 ] [ <3 empty items> ] 3 [ <1 empty item>, 1, <1 empty item>, 2 ]
1,2,3 1---2 1,2,3 
2 -1 2 2
true true true false
[ 0, 9, 9 ] [ 0, 0, 0 ] [ 4, 5, 3, 4, 5 ] 3 undefined
[ [ 0, 1 ], [ 1, 2 ] ] [ 0, 1 ] [ 'x' ]
[ 1, 2, 3 ] [ 3, 2, 1 ] [ 1, 9, 3 ] [ 1, 'z', 4 ]
3 false [ 2, <1 empty item>, 6 ] -1 true
[ 1, 2 ] 2
[ 1, 2, <3 empty items>, 6 ] 6
[ 1, 2, 3, 4, 5, [ 6 ] ] true false
[ 'A', 'B' ] a+b
bdac
abc [ 1, 3, undefined, <1 empty item> ]
0 true 10000
undefined function 5
1,2, 1,2,
[ 3, 4, 5 ] -1 true
*/
