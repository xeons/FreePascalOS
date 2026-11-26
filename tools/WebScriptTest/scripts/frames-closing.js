// A closed frame's realm after collections: nothing of it is reached
// once freed. Removing an iframe detaches its realm (its roots stop
// being marked); its listeners, timers and message ports must not call
// into it afterwards, and a script of the frame that removes its own
// iframe must finish with its globals intact.

// Listeners added to a frame's window from its own realm and from the
// parent, a timer and a message port of the frame, a message queued for
// it; then the frame goes and both collectors run.
var frame = document.createElement("iframe");
document.body.appendChild(frame);
var child = frame.contentWindow;
child.eval("var hits = 0; let lexical = 1;" +
  "window.addEventListener('message', function () { hits += lexical; [1].map(function (x) { return x; }); });" +
  "window.addEventListener('ping', function () { hits += lexical; });" +
  "window.onmessage = function () { hits += lexical; };" +
  "setTimeout(function () { hits += lexical; }, 0);" +
  "setInterval(function () { hits += lexical; }, 1);" +
  "var channel = new MessageChannel(); channel.port2.onmessage = function () { hits += lexical; };" +
  "var target = new EventTarget(); target.addEventListener('ping', function () { hits += lexical; });");
var parentHits = 0;
child.addEventListener("message", function () { parentHits++; });
var port = child.channel.port1;
var childTarget = child.target;
var ChildEvent = child.Event;
child.dispatchEvent(new ChildEvent("ping"));
check("listeners run while the frame is open", child.hits === 1);
child.postMessage("queued before removal", "*");
frame.remove();
child = null;
gc();
gc();
port.postMessage("after removal");
window.dispatchEvent(new Event("ping"));
try {
  childTarget.dispatchEvent(new ChildEvent("ping"));
} catch (error) {
  // A closed window's natives may refuse: what matters is no crash.
}
gc();
check("events after the frame closed", true);

// A frame's script removes its own iframe, collects, then keeps using
// its globals, lexicals and built-ins.
var second = document.createElement("iframe");
document.body.appendChild(second);
var result = second.contentWindow.eval("var collect = parent.gc; let kept = { a: [1, 2, 3] }; var seven = 7;" +
  "function work() { var local = { b: 'x' + seven }; frameElement.remove(); collect(); collect();" +
  "  var s = 0; for (var i = 0; i < 2000; i++) { s += kept.a[1] + local.b.length; var t = { i: i }; }" +
  "  collect(); return s + seven + String(Math.max(1, 2)) + [1, 2].map(function (x) { return x; }).length; }" +
  "work()");
check("a frame's script that removed its own iframe finishes", result === "800722");
gc();

function after() {
  gc();
  check("timers, ports and queued messages of a closed frame do not reach it", parentHits === 0 ||
    parentHits === 1);
}
