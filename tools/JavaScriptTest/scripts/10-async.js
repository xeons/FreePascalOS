// Promises, async functions, the job queue's order.
const log = [];
setTimeoutLike(() => log.push("never in this engine"));
function setTimeoutLike() {}
Promise.resolve().then(() => log.push("micro 1")).then(() => log.push("micro 3"));
Promise.resolve().then(() => log.push("micro 2"));
queueMicrotask(() => log.push("queued"));
log.push("sync");
(async function () {
  log.push("async start");
  await null;
  log.push("after await");
  const v = await new Promise(resolve => resolve("resolved"));
  log.push(v);
  try { await Promise.reject(new Error("rejected")); } catch (e) { log.push("caught " + e.message); }
  return "done";
})().then(r => { log.push(r); console.log(log.join(" | ")); });
const p = new Promise((resolve, reject) => { resolve(1); resolve(2); reject(3); });
p.then(v => console.log("first settle wins", v));
Promise.reject(new TypeError("bad")).catch(e => console.log("catch", e.name)).finally(() => console.log("finally"));
Promise.all([1, Promise.resolve(2), new Promise(r => r(3))]).then(v => console.log("all", v));
Promise.all([Promise.resolve(1), Promise.reject("nope")]).catch(e => console.log("all rejected", e));
Promise.allSettled([Promise.resolve("ok"), Promise.reject("err")]).then(v => console.log("allSettled", JSON.stringify(v)));
Promise.race([new Promise(() => {}), Promise.resolve("fast")]).then(v => console.log("race", v));
Promise.any([Promise.reject(1), Promise.resolve("any ok")]).then(v => console.log("any", v));
Promise.any([Promise.reject(1), Promise.reject(2)]).catch(e => console.log("any failed", e.constructor.name, e.errors));
const thenable = { then(resolve) { resolve("from thenable"); } };
Promise.resolve(thenable).then(v => console.log(v));
(async () => console.log("await thenable", await thenable))();
const chained = Promise.resolve(1).then(x => x + 1).then(x => { throw x * 10; }).catch(x => x + 1).then(x => console.log("chain", x));
async function* agen() { yield 1; await null; yield 2; return 3; }
(async () => { const out = []; for await (const v of agen()) out.push(v); console.log("for await", out); })();
(async () => { for await (const v of [Promise.resolve("a"), "b"]) console.log("for await sync", v); })();
const { promise, resolve } = Promise.withResolvers();
promise.then(v => console.log("withResolvers", v));
resolve("later");
const ag = agen();
ag.next().then(r => console.log("agen next", r));
ag.return("early").then(r => console.log("agen return", r));
async function thrower() { throw new RangeError("async throw"); }
thrower().catch(e => console.log("async rejection", e.name));
console.log("end of script", typeof Promise.prototype.then, p instanceof Promise);
class MyPromise extends Promise { }
const mp = MyPromise.resolve(5);
console.log(mp instanceof MyPromise, mp.then(x => x) instanceof MyPromise);
/* expected
end of script function true
true true
first settle wins 1
catch TypeError
withResolvers later
agen next { value: 1, done: false }
agen return { value: 'early', done: true }
async rejection RangeError
finally
all [ 1, 2, 3 ]
all rejected nope
allSettled [{"status":"fulfilled","value":"ok"},{"status":"rejected","reason":"err"}]
race fast
any any ok
any failed AggregateError [ 1, 2 ]
from thenable
await thenable from thenable
for await sync a
sync | async start | micro 1 | micro 2 | queued | after await | micro 3 | resolved | caught rejected | done
chain 21
for await sync b
for await [ 1, 2 ]
*/
