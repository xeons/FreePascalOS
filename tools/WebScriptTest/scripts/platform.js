// The platform scripts: performance, storage, the smaller window parts,
// crypto, Blob/File/FormData, streams, Headers/Request/Response, fetch,
// XMLHttpRequest and AbortController (the harness serves fetches).
check("platform functions read as native code", String(fetch).indexOf("[native code]") > 0 &&
  String(Headers).indexOf("[native code]") > 0 && String(performance.now).indexOf("[native code]") > 0);

// performance
var t0 = performance.now();
check("performance.now is a non-negative number", typeof t0 === "number" && t0 >= 0);
check("timeOrigin is in this century", performance.timeOrigin > 1.7e12);
check("performance.timing", performance.timing.navigationStart > 1.7e12 &&
  typeof performance.timing.responseStart === "number" && performance.navigation.type === 0);
check("navigation entry", performance.getEntriesByType("navigation").length === 1 &&
  performance.getEntriesByType("navigation")[0].type === "navigate" &&
  performance.getEntriesByType("navigation")[0] instanceof PerformanceNavigationTiming);
var mark = performance.mark("start", { detail: { a: 1 } });
check("marks", mark instanceof PerformanceMark && mark.detail.a === 1 &&
  performance.getEntriesByName("start", "mark")[0] === mark);
var measure = performance.measure("span", "start");
check("measures", measure.entryType === "measure" && measure.duration >= 0 && measure.startTime === mark.startTime);
performance.clearMarks("start");
check("clearMarks", performance.getEntriesByType("mark").length === 0);
check("toStringTag", Object.prototype.toString.call(performance) === "[object Performance]" &&
  performance instanceof EventTarget);
var observed = [];
new PerformanceObserver(function (list) { observed = observed.concat(list.getEntries()); }).observe({ type: "mark" });
performance.mark("seen");
var illegal = false;
try { new Performance(); } catch (e) { illegal = e instanceof TypeError; }
check("illegal constructor", illegal);

// storage
localStorage.clear();
localStorage.setItem("a", "1");
localStorage.b = 2;
check("storage items", localStorage.getItem("a") === "1" && localStorage.b === "2" && localStorage.length === 2 &&
  localStorage.key(0) === "a" && "b" in localStorage && Object.keys(localStorage).join() === "a,b");
delete localStorage.a;
localStorage.removeItem("b");
check("storage removal", localStorage.length === 0 && localStorage.getItem("a") === null);
localStorage.setItem("length", "x");
check("named items do not shadow members", localStorage.length === 1 && localStorage.getItem("length") === "x");
sessionStorage.setItem("s", "t");
check("session storage is separate", sessionStorage.getItem("s") === "t" && localStorage.getItem("s") === null);
check("Storage", localStorage instanceof Storage && String(localStorage) === "[object Storage]");
var quota = false;
try { localStorage.setItem("big", "x".repeat(6 * 1024 * 1024)); } catch (e) { quota = e.name === "QuotaExceededError"; }
check("quota", quota);

// window parts
var image = new Image(10, 20);
check("Image", image instanceof HTMLImageElement && image.width === 10 && image.getAttribute("height") === "20" &&
  Image.prototype === HTMLImageElement.prototype);
var option = new Option("Text", "v", true, true);
check("Option", option.text === "Text" && option.value === "v" && option.defaultSelected && option.selected);
check("screen", screen.width > 0 && screen.colorDepth === 24 && screen instanceof Screen);
check("matchMedia", matchMedia("(min-width: 1px)").matches && !matchMedia("(max-width: 1px)").matches &&
  matchMedia("screen").media === "screen" && matchMedia("(prefers-color-scheme: light)").matches);
var frameTime = null;
requestAnimationFrame(function (time) { frameTime = time; });
var idle = null;
requestIdleCallback(function (deadline) { idle = deadline; });
check("navigator plugins and permissions", navigator.plugins.length === 0 && navigator.mimeTypes.length === 0 &&
  navigator.permissions.query({ name: "notifications" }) instanceof Promise);

// crypto
var bytes = crypto.getRandomValues(new Uint8Array(32));
check("getRandomValues", bytes.some(function (b) { return b !== 0; }));
check("randomUUID", /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(crypto.randomUUID()));
var digestHex = null;
crypto.subtle.digest("SHA-256", new TextEncoder().encode("abc")).then(function (buffer) {
  digestHex = Array.from(new Uint8Array(buffer), function (b) { return (b + 256).toString(16).slice(1); }).join("");
});

// Blob, File, FormData
var blob = new Blob(["ab", new Uint8Array([99]), new Blob(["d"])], { type: "Text/Plain" });
check("Blob", blob.size === 4 && blob.type === "text/plain" && blob.slice(1, 3).size === 2);
var blobText = null;
blob.text().then(function (text) { blobText = text; });
var file = new File(["x"], "a/b.txt", { lastModified: 5 });
check("File", file.name === "a:b.txt" && file.lastModified === 5 && file instanceof Blob);
var form = new FormData();
form.append("k", "v");
form.append("k", "w");
form.set("j", "1");
check("FormData", form.getAll("k").join() === "v,w" && form.get("j") === "1" && Array.from(form.keys()).join() === "k,k,j");
var blobUrl = URL.createObjectURL(blob);
check("blob URL", blobUrl.indexOf("blob:https://example.test/") === 0);

// streams
var streamed = [];
var stream = new ReadableStream({ start: function (c) { c.enqueue("a"); c.enqueue("b"); c.close(); } });
var reader = stream.getReader();
reader.read().then(function (r) { streamed.push(r.value); return reader.read(); })
  .then(function (r) { streamed.push(r.value); return reader.read(); })
  .then(function (r) { streamed.push(r.done); });

// Headers, Request, Response
var headers = new Headers({ "Content-Type": "text/html", "X-A": "1" });
headers.append("x-a", "2");
check("Headers", headers.get("x-a") === "1, 2" && headers.has("content-type") &&
  Array.from(headers.keys()).join() === "content-type,x-a");
var request = new Request("/api?q=1", { method: "post", body: "data", headers: { "X-B": "y" } });
check("Request", request.method === "POST" && request.url === "https://example.test/api?q=1" &&
  request.headers.get("content-type") === "text/plain;charset=UTF-8" && request.mode === "cors");
var response = new Response("{\"x\":1}", { status: 201, headers: { "Content-Type": "application/json" } });
var json = null;
response.json().then(function (value) { json = value; });
check("Response", response.status === 201 && response.ok && response.headers.get("content-type") === "application/json");
check("Response.json", Response.json({ a: 1 }).headers.get("content-type") === "application/json");

// fetch through the harness
var fetched = null, fetchedType = null, fetchedStatus = 0;
fetch("/data.json").then(function (r) { fetchedStatus = r.status; fetchedType = r.headers.get("content-type"); return r.json(); })
  .then(function (value) { fetched = value; });
var failed = null;
fetch("/missing").then(function (r) { failed = r.status; });
var networkError = null;
fetch("https://unreachable.test/").catch(function (e) { networkError = e; });
var controller = new AbortController();
var aborted = null;
fetch("/data.json", { signal: controller.signal }).catch(function (e) { aborted = e.name; });
controller.abort();
var blobFetched = null;
fetch(blobUrl).then(function (r) { return r.text(); }).then(function (text) { blobFetched = text; });

// XMLHttpRequest
var xhr = new XMLHttpRequest();
var states = [];
var xhrLoaded = false;
xhr.onreadystatechange = function () { states.push(xhr.readyState); };
xhr.onload = function () { xhrLoaded = true; };
xhr.open("GET", "/data.json");
xhr.send();
var xhrJson = new XMLHttpRequest();
xhrJson.responseType = "json";
xhrJson.open("GET", "/data.json");
xhrJson.send();

function after() {
  check("animation frame ran", typeof frameTime === "number");
  check("idle callback ran", idle !== null && idle.didTimeout === false && typeof idle.timeRemaining() === "number");
  check("performance observer", observed.length === 1 && observed[0].name === "seen");
  check("digest", digestHex === "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  check("blob text", blobText === "abcd");
  check("stream reading", streamed.join() === "a,b,true");
  check("response body", json !== null && json.x === 1);
  check("fetch", fetchedStatus === 200 && fetchedType === "application/json" && fetched !== null && fetched.ok === true);
  check("fetch of a 404", failed === 404);
  check("network error", networkError instanceof TypeError);
  check("abort", aborted === "AbortError");
  check("blob URL fetch", blobFetched === "abcd");
  check("XMLHttpRequest", xhrLoaded && xhr.status === 200 && JSON.parse(xhr.responseText).ok === true &&
    states.join() === "1,2,3,4" && xhr.getResponseHeader("Content-Type") === "application/json");
  check("XMLHttpRequest json", xhrJson.response !== null && xhrJson.response.ok === true);
}
