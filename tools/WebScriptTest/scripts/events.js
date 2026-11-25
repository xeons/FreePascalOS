// Event dispatch to script listeners: capture and bubble order, once,
// removal, stopping, canceling, handler properties, handleEvent objects,
// event kinds and their dictionaries, the window in the path.
document.body.innerHTML = '<div id="outer"><p id="inner"><span id="leaf">x</span></p></div>';
var outer = document.getElementById("outer");
var inner = document.getElementById("inner");
var leaf = document.getElementById("leaf");
var log = [];
function note(label) {
  return function (event) {
    log.push(label + ":" + event.eventPhase + ":" + (event.currentTarget === this));
  };
}
outer.addEventListener("go", note("outer capture"), true);
outer.addEventListener("go", note("outer bubble"));
inner.addEventListener("go", note("inner capture"), { capture: true });
inner.addEventListener("go", note("inner bubble"));
leaf.addEventListener("go", note("leaf bubble"));
leaf.addEventListener("go", note("leaf capture"), true);
window.addEventListener("go", note("window capture"), true);
document.addEventListener("go", note("document bubble"));
leaf.dispatchEvent(new Event("go", { bubbles: true }));
check("capture down, target, bubble up", log.join(",") ===
  "window capture:1:true,outer capture:1:true,inner capture:1:true,leaf capture:2:true,leaf bubble:2:true," +
  "inner bubble:3:true,outer bubble:3:true,document bubble:3:true");

log = [];
leaf.dispatchEvent(new Event("go"));
check("a non-bubbling event stops at the target", log.join(",") ===
  "window capture:1:true,outer capture:1:true,inner capture:1:true,leaf capture:2:true,leaf bubble:2:true");

var count = 0;
function counter() { count++; }
leaf.addEventListener("once", counter, { once: true });
leaf.dispatchEvent(new Event("once"));
leaf.dispatchEvent(new Event("once"));
check("once", count === 1);
leaf.addEventListener("twice", counter);
leaf.addEventListener("twice", counter);
leaf.dispatchEvent(new Event("twice"));
check("a duplicate listener is added once", count === 2);
leaf.removeEventListener("twice", counter);
leaf.dispatchEvent(new Event("twice"));
check("removeEventListener", count === 2);
leaf.addEventListener("twice", counter, true);
leaf.removeEventListener("twice", counter);
leaf.dispatchEvent(new Event("twice"));
check("removal matches the capture flag", count === 3);

log = [];
inner.addEventListener("stop", function (e) { log.push("inner"); e.stopPropagation(); });
outer.addEventListener("stop", function () { log.push("outer"); });
leaf.addEventListener("stop", function () { log.push("leaf 1"); });
leaf.addEventListener("stop", function (e) { log.push("leaf 2"); });
leaf.dispatchEvent(new Event("stop", { bubbles: true }));
check("stopPropagation", log.join(",") === "leaf 1,leaf 2,inner");
log = [];
leaf.addEventListener("now", function (e) { log.push(1); e.stopImmediatePropagation(); });
leaf.addEventListener("now", function () { log.push(2); });
leaf.dispatchEvent(new Event("now"));
check("stopImmediatePropagation", log.join(",") === "1");

leaf.addEventListener("cancel", function (e) { e.preventDefault(); });
check("preventDefault on a cancelable event", leaf.dispatchEvent(new Event("cancel", { cancelable: true })) === false);
check("preventDefault on one that is not", leaf.dispatchEvent(new Event("cancel")) === true);
leaf.addEventListener("passive", function (e) { e.preventDefault(); }, { passive: true });
check("a passive listener cannot cancel", leaf.dispatchEvent(new Event("passive", { cancelable: true })) === true);

var custom = new CustomEvent("custom", { detail: { answer: 42 }, bubbles: true });
var received = null;
outer.addEventListener("custom", function (e) { received = e.detail; });
leaf.dispatchEvent(custom);
check("CustomEvent detail", received && received.answer === 42 && custom instanceof Event);
check("event fields after dispatch", custom.target === leaf && custom.currentTarget === null && custom.eventPhase === 0);

var mouse = new MouseEvent("click", { clientX: 5, clientY: 7, ctrlKey: true, button: 2, bubbles: true });
check("MouseEvent init", mouse.clientX === 5 && mouse.y === 7 && mouse.ctrlKey && !mouse.shiftKey &&
  mouse.button === 2 && mouse.getModifierState("Control") && mouse instanceof UIEvent);
var key = new KeyboardEvent("keydown", { key: "a", code: "KeyA", keyCode: 65 });
check("KeyboardEvent init", key.key === "a" && key.code === "KeyA" && key.keyCode === 65 && key.which === 65);
var focus = new FocusEvent("focus", { relatedTarget: leaf });
check("FocusEvent init", focus.relatedTarget === leaf);
var input = new InputEvent("input", { data: "x", inputType: "insertText" });
check("InputEvent init", input.data === "x" && input.inputType === "insertText" && new InputEvent("input").data === null);
var ui = new UIEvent("u", { view: window, detail: 3 });
check("UIEvent init", ui.view === window && ui.detail === 3);
check("isTrusted is false for script events", mouse.isTrusted === false);
check("timeStamp", typeof mouse.timeStamp === "number");

var handled = 0;
leaf.onclick = function (e) { handled++; return false; };
check("onclick getter", typeof leaf.onclick === "function");
var clickEvent = new MouseEvent("click", { cancelable: true, bubbles: true });
leaf.dispatchEvent(clickEvent);
check("an onclick handler runs and returning false cancels", handled === 1 && clickEvent.defaultPrevented);
leaf.onclick = null;
leaf.dispatchEvent(new MouseEvent("click"));
check("a cleared handler does not run", handled === 1 && leaf.onclick === null);
leaf.onclick = "not a function";
check("a non-function handler is null", leaf.onclick === null);

var listenerObject = { calls: 0, handleEvent: function (e) { this.calls++; } };
leaf.addEventListener("object", listenerObject);
leaf.dispatchEvent(new Event("object"));
check("handleEvent objects", listenerObject.calls === 1);

clearConsole();
var after = false;
leaf.addEventListener("throw", function () { throw new Error("listener failed"); });
leaf.addEventListener("throw", function () { after = true; });
leaf.dispatchEvent(new Event("throw"));
check("an exception in a listener is reported and the next one runs",
  after && consoleText().indexOf("listener failed") >= 0);
clearConsole();

var target = new EventTarget();
var seen = null;
target.addEventListener("ping", function (e) { seen = e.target; });
target.dispatchEvent(new Event("ping"));
check("new EventTarget", seen === target);

var windowSeen = 0;
window.onmessage = function () { windowSeen++; };
window.dispatchEvent(new Event("message"));
addEventListener("message", function () { windowSeen++; });
dispatchEvent(new Event("message"));
check("window handlers and listeners (this as the window)", windowSeen === 3);

var pending = new Event("x");
var dispatchError = null;
leaf.addEventListener("x", function () {
  try { leaf.dispatchEvent(pending); } catch (e) { dispatchError = e; }
});
leaf.dispatchEvent(pending);
check("dispatching an event being dispatched is an InvalidStateError", dispatchError && dispatchError.name === "InvalidStateError");

var legacy = document.createEvent("Event");
legacy.initEvent("legacy", true, true);
var legacySeen = false;
document.addEventListener("legacy", function () { legacySeen = true; });
leaf.dispatchEvent(legacy);
check("createEvent and initEvent", legacySeen);

var composed = null;
leaf.addEventListener("path", function (e) { composed = e.composedPath(); });
leaf.dispatchEvent(new Event("path"));
check("composedPath", composed.length === 7 && composed[0] === leaf && composed[5] === document && composed[6] === window);

// The legacy initializers (DuckDuckGo builds its clicks with
// document.createEvent("MouseEvents") and initMouseEvent).
var legacy = document.createEvent("MouseEvents");
legacy.initMouseEvent("click", true, true, window, 2, 10, 20, 30, 40, true, false, true, false, 1, document.body);
check("initMouseEvent sets the fields", legacy.type === "click" && legacy.bubbles && legacy.cancelable &&
  legacy.view === window && legacy.detail === 2 && legacy.screenX === 10 && legacy.clientY === 40 &&
  legacy.ctrlKey && !legacy.altKey && legacy.shiftKey && legacy.button === 1 && legacy.relatedTarget === document.body);
var legacyTarget = document.createElement("a");
var legacyClicks = 0;
legacyTarget.addEventListener("click", function (event) {
  legacyClicks++;
  event.initMouseEvent("other", false, false, null, 0, 0, 0, 0, 0, false, false, false, false, 0, null);
});
legacyTarget.dispatchEvent(legacy);
check("a legacy event is dispatched, and initMouseEvent does nothing while it is",
  legacyClicks === 1 && legacy.type === "click" && legacy.button === 1);
var legacyUi = document.createEvent("UIEvents");
legacyUi.initUIEvent("resize", false, true, null, 5);
check("initUIEvent", legacyUi.type === "resize" && !legacyUi.bubbles && legacyUi.cancelable && legacyUi.view === null &&
  legacyUi.detail === 5);
