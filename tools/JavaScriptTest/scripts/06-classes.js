// Classes: inheritance, super, static, fields, private names, accessors.
class Shape {
  static count = 0;
  #id;
  name = "shape";
  constructor(id) { this.#id = id; Shape.count++; }
  get id() { return this.#id; }
  area() { return 0; }
  describe() { return `${this.name}#${this.#id} area=${this.area()}`; }
  static create(id) { return new this(id); }
  #secret() { return "s" + this.#id; }
  reveal() { return this.#secret(); }
  static isShape(o) { return #id in o; }
}
class Circle extends Shape {
  name = "circle";
  constructor(id, r) { super(id); this.r = r; }
  area() { return Math.round(Math.PI * this.r ** 2); }
  describe() { return super.describe() + " (round)"; }
  static create(id) { return super.create(id); }
}
const c = new Circle(1, 2);
console.log(c.describe(), c.id, c.reveal(), Shape.count, c instanceof Shape, Shape.isShape(c), Shape.isShape({}));
console.log(Object.getPrototypeOf(Circle) === Shape, typeof Circle, Circle.name, Circle.create(5) instanceof Circle);
try { Circle(); } catch (e) { console.log(e.constructor.name, e.message); }
class Counter {
  static #instances = 0;
  #value = 0;
  constructor() { Counter.#instances++; }
  increment() { this.#value++; return this; }
  get value() { return this.#value; }
  set value(v) { if (v < 0) throw new RangeError("negative"); this.#value = v; }
  static get instances() { return Counter.#instances; }
}
const k = new Counter().increment().increment();
k.value = 10;
console.log(k.value, Counter.instances);
try { k.value = -1; } catch (e) { console.log(e.name, e.message); }
try { Counter.prototype.increment.call({}); } catch (e) { console.log(e.name); }
const Anonymous = class { };
const Named = class Inner { who() { return Inner.name; } };
console.log(Anonymous.name, Named.name, new Named().who(), typeof Inner);
class WithComputed { ["say" + "Hi"]() { return "hi"; } static [Symbol.iterator] = 1; [Symbol.toStringTag] = "Custom"; }
console.log(new WithComputed().sayHi(), String(new WithComputed()), WithComputed[Symbol.iterator]);
class Base { constructor() { this.kind = new.target.name; } }
class Derived extends Base { }
console.log(new Derived().kind, new Base().kind);
class MyArray extends Array { sum() { return this.reduce((a, b) => a + b, 0); } }
const ma = MyArray.from([1, 2, 3]);
console.log(ma.sum(), ma.length, ma instanceof Array, Array.isArray(ma), ma.map(x => x * 2) instanceof MyArray);
class MyError extends Error { constructor(m) { super(m); this.name = "MyError"; } }
try { throw new MyError("custom"); } catch (e) { console.log(e instanceof Error, e instanceof MyError, e.name, e.message, String(e)); }
class Statics { static a = 1; static b = Statics.a + 1; static { Statics.c = Statics.b * 10; } }
console.log(Statics.a, Statics.b, Statics.c);
class Accessors { static #x = 3; static get x() { return this.#x; } }
console.log(Accessors.x, Object.getOwnPropertyNames(Accessors.prototype));
class NoNew { constructor() { return { replaced: true }; } }
console.log(new NoNew().replaced);
class ThisBeforeSuper extends Base { constructor() { try { this.x = 1; } catch (e) { console.log(e.name); } super(); } }
new ThisBeforeSuper();
const methods = { toString() { return "obj"; }, valueOf() { return 7; } };
class Mixed extends Object { }
console.log(`${methods}`, methods * 2, new Mixed() instanceof Object);
class Fields { a = 1; b = this.a + 1; ["c"] = 3; static d = this.name; arrow = () => this.a; }
const f = new Fields();
console.log(f.a, f.b, f.c, Fields.d, f.arrow.call(null), Object.keys(f));
/* expected
circle#1 area=13 (round) 1 s1 1 true true false
true function Circle true
TypeError Class constructor Circle cannot be invoked without 'new'
10 1
RangeError negative
TypeError
Anonymous Inner Inner undefined
hi [object Custom] 1
Derived Base
6 3 true true true
true true MyError custom MyError: custom
1 2 20
3 [ 'constructor' ]
true
ReferenceError
obj 14 true
1 2 3 Fields 1 [ 'a', 'b', 'c', 'arrow' ]
*/
