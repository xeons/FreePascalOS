// String building, splitting, joining, regular expressions.
let text = "";
for (let i = 0; i < 20000; i++) text += "word" + (i % 100) + (i % 13 === 0 ? ".\n" : " ");
const words = text.split(/\s+/);
const counts = new Map();
for (const w of words) counts.set(w, (counts.get(w) || 0) + 1);
const emails = [];
for (let i = 0; i < 5000; i++) emails.push(`user${i}@host${i % 50}.example.org`);
const valid = emails.filter(e => /^[a-z0-9]+@[a-z0-9]+\.[a-z]+\.[a-z]{2,}$/.test(e)).length;
const replaced = text.replace(/word(\d+)/g, (m, n) => n * 2).length;
const joined = words.slice(0, 10000).map(w => w.toUpperCase()).join(",");
console.log(words.length, counts.size, valid, replaced, joined.length);
