// ES modules: every import and export form, live bindings, cycles,
// top-level await ordering, JSON modules, namespaces, import() errors.
import anonymous, { count, increment, answer, first, second, renamedNested, Shape, visible, "quoted name" as quoted } from "./modules/counter.mjs";
import * as counter from "./modules/counter.mjs";
import DefaultClass from "./modules/defaults.mjs";
import double from "./modules/default-expression.mjs";
import named from "./modules/default-named.mjs";
import { a, getA } from "./modules/cycle-a.mjs";
import { user } from "./modules/tla-user.mjs";
import config from "./modules/config.json" with { type: "json" };
import * as stars from "./modules/stars.mjs";
import { onlyA, starA } from "./modules/stars.mjs";

console.log(anonymous(), anonymous.name, count, increment(), increment(), count, counter.count);
console.log(answer, first, second, renamedNested, new Shape().area(), visible, quoted);
console.log(DefaultClass.name, DefaultClass.kind, double(21), double.name, named(), named.name);
console.log(a, getA(), user, config.title, config.items[1]);
console.log(Object.keys(stars).join(), stars.shared, onlyA, starA.onlyA, starA === stars.starA);
console.log(Reflect.ownKeys(counter).map(String).join(), Object.getPrototypeOf(counter), String(counter[Symbol.toStringTag]));
console.log(JSON.stringify(Object.getOwnPropertyDescriptor(counter, "count")), Reflect.deleteProperty(counter, "count"), Reflect.deleteProperty(counter, "missing"), "count" in counter, "missing" in counter);
console.log(Reflect.defineProperty(counter, "count", { value: 2 }), Reflect.defineProperty(counter, "count", { value: 3 }), Reflect.set(counter, "count", 1), Reflect.setPrototypeOf(counter, null), Reflect.setPrototypeOf(counter, {}));
try { counter.count = 1; } catch (e) { console.log(e.constructor.name); }
try { count = 1; } catch (e) { console.log(e.constructor.name); }
try { increment = 1; } catch (e) { console.log(e.constructor.name); }
console.log(typeof this, typeof import.meta, Object.getPrototypeOf(import.meta), import.meta.url.endsWith("19-modules.mjs"), (() => import.meta)() === import.meta);
console.log(import.meta.resolve("./modules/x.mjs").endsWith("scripts/modules/x.mjs"));
const later = await import("./modules/counter.mjs");
console.log(later === counter, later.count);
const json2 = await import("./modules/config.json", { with: { type: "json" } });
console.log(json2.default === config, Object.keys(json2).join());
for (const [name, specifier] of [["missing", "./modules/missing.mjs"], ["link", "./modules/bad-import.mjs"], ["ambiguous", "./modules/bad-ambiguous.mjs"], ["throws", "./modules/throws.mjs"], ["throws again", "./modules/throws.mjs"]]) {
  try { await import(specifier); } catch (e) { console.log(name, e.constructor.name, e.message); }
}
try { await import("./modules/bad-syntax.mjs"); } catch (e) { console.log("syntax", e.constructor.name); }
try { await import("./modules/config.json"); } catch (e) { console.log("json without type", e.constructor.name); }
try { await import("./modules/counter.mjs", { with: { type: "css" } }); } catch (e) { console.log("bad type", e.constructor.name); }
try { await import("./modules/counter.mjs", 5); } catch (e) { console.log("bad options", e.constructor.name); }
console.log("end");
/* expected
cycle-b body, getA is function a: ReferenceError
cycle-a body: B A
slow start
fast runs
slow end
user sees slow done fast
anonymous default default 0 1 2 2 2
42 1 2 deep 0 hidden hidden
default class 42 default named named
A A slow done/fast config 20
onlyA,onlyB,starA undefined 1 1 true
Shape,answer,count,default,first,increment,quoted name,renamedNested,second,visible,Symbol(Symbol.toStringTag) null Module
{"value":2,"writable":true,"enumerable":true,"configurable":false} false true true false
true false false true false
TypeError
TypeError
TypeError
undefined object null true true
true
true 2
true default
missing TypeError Cannot find module 'missing.mjs'
link SyntaxError The requested module './counter.mjs' does not provide an export named 'nope'
ambiguous SyntaxError The requested module './stars.mjs' contains conflicting star exports for name 'shared'
throws Error boom
throws again Error boom
syntax SyntaxError
json without type SyntaxError
bad type TypeError
bad options TypeError
end
*/
