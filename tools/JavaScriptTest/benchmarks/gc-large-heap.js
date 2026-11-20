// A large long-lived heap (a tree of objects and arrays) with steady
// short-lived garbage: what each collection has to trace.
function build(depth) {
  if (depth === 0) return { leaf: true, values: [1, 2, 3], text: "leaf" };
  return { left: build(depth - 1), right: build(depth - 1), depth, list: new Array(8).fill(depth) };
}
const tree = build(15);
const table = new Map();
for (let i = 0; i < 60000; i++) table.set("key" + i, { i, tags: ["a", "b"] });
let churn = 0;
for (let round = 0; round < 40; round++) {
  const garbage = [];
  for (let i = 0; i < 5000; i++) garbage.push({ round, i, s: "x" + i, arr: [i, i + 1] });
  churn += garbage.length;
}
function count(node) { return node.leaf ? 1 : count(node.left) + count(node.right); }
console.log(count(tree), table.size, churn);
