// Property access sites that see several shapes, typed array loops,
// a library-sized source compiled with few of its functions called.
class Circle { constructor(r) { this.kind = 0; this.r = r; } area() { return 3.14159 * this.r * this.r; } }
class Square { constructor(s) { this.kind = 1; this.s = s; } area() { return this.s * this.s; } }
class Rect { constructor(w, h) { this.kind = 2; this.w = w; this.h = h; } area() { return this.w * this.h; } }
class Triangle { constructor(b, h) { this.kind = 3; this.b = b; this.h = h; } area() { return this.b * this.h / 2; } }
const shapes = [];
for (let i = 0; i < 4000; i++) {
  switch (i % 4) {
    case 0: shapes.push(new Circle(i % 10)); break;
    case 1: shapes.push(new Square(i % 7)); break;
    case 2: shapes.push(new Rect(i % 5, i % 3)); break;
    default: shapes.push(new Triangle(i % 9, i % 4));
  }
}
let total = 0, kinds = 0;
for (let round = 0; round < 60; round++)
  for (const shape of shapes) {
    total += shape.area();
    kinds += shape.kind;
  }
const records = [];
for (let i = 0; i < 20000; i++) records.push(i % 3 === 0 ? { id: i, name: "a" } : i % 3 === 1 ? { name: "b", id: i } : { id: i, extra: true, name: "c" });
let ids = 0;
for (let round = 0; round < 10; round++) for (const r of records) ids += r.id;
const pixels = new Uint8ClampedArray(256 * 256 * 4);
for (let frame = 0; frame < 8; frame++)
  for (let i = 0; i < pixels.length; i += 4) {
    pixels[i] = (i + frame) & 255;
    pixels[i + 1] = pixels[i] >> 1;
    pixels[i + 2] = 255 - pixels[i];
    pixels[i + 3] = 255;
  }
const view = new DataView(pixels.buffer);
let checksum = 0;
for (let i = 0; i < pixels.length; i += 64) checksum = (checksum + view.getUint32(i, true)) | 0;
let source = "";
for (let i = 0; i < 1500; i++)
  source += `function unused${i}(a, b) { const list = [a, b, ${i}]; let sum = 0; for (const x of list) sum += typeof x === "number" ? x * 2 : String(x).length; return (y => ({ y, twice: y * 2 }))(sum).twice + Math.max(a, b); }\n`;
source += "unused1(1, 2) + unused2(3, 4)";
const compiled = (0, eval)(source);
console.log(Math.round(total), kinds, ids, checksum, compiled);
