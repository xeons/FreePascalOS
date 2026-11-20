// Function calls, recursion, property access through shapes and inline caches.
function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
class Vector {
  constructor(x, y) { this.x = x; this.y = y; }
  add(other) { return new Vector(this.x + other.x, this.y + other.y); }
  scale(f) { return new Vector(this.x * f, this.y * f); }
  get length() { return Math.sqrt(this.x * this.x + this.y * this.y); }
}
let sum = new Vector(0, 0);
for (let i = 0; i < 200000; i++) sum = sum.add(new Vector(i % 7, i % 3).scale(0.5));
const points = [];
for (let i = 0; i < 50000; i++) points.push({ id: i, x: i % 100, y: (i * 7) % 100, tag: "p" + (i % 10) });
let hits = 0;
for (const p of points) if (p.x > 50 && p.y < 30) hits++;
console.log(fib(24), Math.round(sum.length), hits);
