// import() from a classic script, resolved against the script.
import("./modules/counter.mjs").then(ns => console.log("script import", ns.answer, ns.count, ns.increment(), ns.count));
import("./modules/config.json", { with: { type: "json" } }).then(ns => console.log(ns.default.title));
console.log(typeof import("./modules/counter.mjs").then);
try { eval("import.meta"); } catch (e) { console.log(e.constructor.name); }
try { new Function("import x from 'y'"); } catch (e) { console.log(e.constructor.name); }
try { eval("export const x = 1;"); } catch (e) { console.log(e.constructor.name); }
import({ toString() { throw new RangeError("from toString"); } }).catch(e => console.log("rejected", e.constructor.name));
console.log("sync end");
/* expected
function
SyntaxError
SyntaxError
SyntaxError
sync end
rejected RangeError
script import 42 0 1 1
config
*/
