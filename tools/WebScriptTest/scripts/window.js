// The window: location, navigator, history and timers through the
// environment, console, queueMicrotask.
check("location", location.href === "https://example.test/dir/page.html" && location.protocol === "https:" &&
  location.host === "example.test" && location.pathname === "/dir/page.html" && String(location) === location.href &&
  document.location === location && window.location === location);
location.assign("other.html");
check("location.assign goes to the environment", lastNavigation() === "https://example.test/dir/other.html");
check("navigator", typeof navigator.userAgent === "string" && navigator.userAgent.indexOf("Mozilla/5.0") === 0 &&
  navigator.language === "en-US" && navigator.languages[0] === "en-US" && navigator.onLine === true &&
  navigator === window.navigator);
check("viewport", innerWidth === 800 && innerHeight === 600 && devicePixelRatio === 1);
check("origin", origin === "https://example.test" && isSecureContext === true);
history.pushState({ page: 2 }, "", "page2.html");
check("pushState changes the URL", document.URL === "https://example.test/dir/page2.html" &&
  history.state.page === 2 && lastNavigation() === "history https://example.test/dir/page2.html");
var historyError = null;
try { history.back(); } catch (e) { historyError = e; }
check("what the environment cannot do is a NotSupportedError", historyError instanceof DOMException &&
  historyError.name === "NotSupportedError");
var style = getComputedStyle(document.body);
check("getComputedStyle answers (read only)", style instanceof CSSStyleDeclaration);

var log = [];
var first = setTimeout(function (a, b) { log.push("first " + a + b); }, 10, "x", "y");
setTimeout(function () { log.push("zero"); });
var cleared = setTimeout(function () { log.push("cleared"); }, 5);
clearTimeout(cleared);
var count = 0;
var interval = setInterval(function () { count++; if (count === 3) clearInterval(interval); }, 1);
setTimeout("log.push('string handler')", 20);
check("timer ids", typeof first === "number" && first > 0);
check("timers wait for the event loop", log.length === 0);
runTimers();
check("timers run in order of their timeouts", log.join(",") === "zero,first xy,string handler");
check("setInterval repeats until cleared", count === 3);
check("no timers are left", runTimers() === 0);

var micro = [];
queueMicrotask(function () { micro.push("queued"); });
Promise.resolve().then(function () { micro.push("promise"); });
check("microtasks wait for the script to end", micro.length === 0);
function after() {
  check("microtasks ran after the script", micro.join(",") === "queued,promise");
  check("each timer task ends with a microtask checkpoint", nested.join(",") === "outer,outer microtask,inner");
}
console.log("from", "console", 1);
check("console goes to the host", consoleText().indexOf("from console 1") >= 0);
clearConsole();
var nested = [];
setTimeout(function () {
  nested.push("outer");
  Promise.resolve().then(function () { nested.push("outer microtask"); });
  setTimeout(function () { nested.push("inner"); });
}, 0);
// Location's setters navigate (HTML 7.2.4).
location.href = "page2.html";
check("location.href = navigates", lastNavigation().indexOf("page2.html") > 0);
window.location = "page3.html";
check("window.location = navigates (PutForwards href)", lastNavigation().indexOf("page3.html") > 0);
location.search = "?q=1";
check("location.search = navigates with the new query", lastNavigation().indexOf("?q=1") > 0);
var namedTarget = document.createElement("div");
namedTarget.id = "namedAccessTarget";
document.body.appendChild(namedTarget);
check("the window's named properties find an element by id", window.namedAccessTarget === namedTarget &&
  namedAccessTarget === namedTarget && "namedAccessTarget" in window &&
  !Object.prototype.hasOwnProperty.call(window, "namedAccessTarget"));
namedTarget.remove();
check("a removed element leaves the window's named properties", window.namedAccessTarget === undefined);
check("the window's own members win over named elements", (function () {
  var shadow = document.createElement("div");
  shadow.id = "location";
  document.body.appendChild(shadow);
  var kept = window.location !== shadow;
  shadow.remove();
  return kept;
})());
