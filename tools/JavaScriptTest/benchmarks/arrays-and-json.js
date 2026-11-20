// Array methods, sorting, closures, JSON round trips, garbage.
const data = Array.from({ length: 100000 }, (_, i) => (i * 2654435761) % 1000003);
const sorted = data.slice().sort((a, b) => a - b);
const evens = data.filter(x => x % 2 === 0).map(x => x / 2).reduce((a, b) => a + b, 0);
const records = [];
for (let i = 0; i < 20000; i++) records.push({ id: i, name: "item" + i, tags: ["a", "b", String(i % 5)], nested: { value: i * 1.5 } });
const json = JSON.stringify(records);
const back = JSON.parse(json);
const total = back.reduce((acc, r) => acc + r.nested.value, 0);
const grouped = Object.groupBy(back, r => r.tags[2]);
console.log(sorted[0], sorted[sorted.length - 1], evens, json.length, total, Object.keys(grouped).length);
