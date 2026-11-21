// await inside an async arrow that is inside a class field's initializer
// belongs to that arrow (www.github.com's router: #R = async e => ... ).
class Router {
  #load = async e => {
    return Promise.all([[e, { name: "n" }]].map(([value, { name }]) => {
      const pending = (async () => { try { return await value; } catch (error) { return 0; } })();
      return pending.then(v => name + v);
    }));
  };
  plain = async () => await 2;
  go(v) { return this.#load(v); }
}
const router = new Router();
router.go(7).then(v => console.log(v[0]));
router.plain().then(v => console.log(v));
// In the initializer itself await is still no operator.
let rejected = "";
try { new Function("return async function () { class A { x = await 1; } }"); } catch (e) { rejected = e.name; }
console.log(rejected);
/* expected
SyntaxError
2
n7
*/
