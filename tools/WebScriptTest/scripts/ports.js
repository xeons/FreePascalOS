// MessagePorts sent between realms (a frame and its parent are realms of
// one heap: the receiver gets a port of its own realm), ports in
// MessageChannel messages, and frames found by name (window[name]).
var frame = document.createElement("iframe");
frame.name = "kid";
document.body.appendChild(frame);
var child = frame.contentWindow;
check("a frame by its name", window.kid === child && window.frames.kid === child);
check("a name the window has already is not hidden", (function () {
  var other = document.createElement("iframe");
  other.name = "document";
  document.body.appendChild(other);
  var kept = window.document instanceof Document;
  other.remove();
  return kept;
})());

var received = null;
var trustedReplies = true;
var replies = [];
window.addEventListener("message", function (event) {
  if (event.data !== "port") return;
  received = event;
  var port = event.ports[0];
  port.onmessage = function (reply) {
    trustedReplies = trustedReplies && reply.isTrusted === true;
    replies.push(reply.data);
    if (reply.ports.length === 1) reply.ports[0].postMessage("x");
  };
  port.postMessage({ text: "ping" });
});
child.eval("var channel = new MessageChannel();" +
  "channel.port1.onmessage = function (event) {" +
  "  var inner = new MessageChannel();" +
  "  inner.port1.onmessage = function (e) { channel.port1.postMessage('inner ' + e.data); };" +
  "  channel.port1.postMessage('echo ' + event.data.text + ' ' + (Object.getPrototypeOf(event.data) === Object.prototype)," +
  "    [inner.port2]);" +
  "};" +
  "parent.postMessage('port', '*', [channel.port2]);");

var local = new MessageChannel();
var carried = null;
var throughMoved = null;
local.port2.onmessage = function (event) {
  carried = event;
  event.ports[0].onmessage = function (inner) { throughMoved = inner.data; };
  third.port2.postMessage("to the moved port");
};
var third = new MessageChannel();
local.port1.postMessage("with a port", [third.port1]);
var twice = false;
try {
  local.port1.postMessage("again", [third.port1]);
} catch (error) {
  twice = error.name === "DataCloneError";
}

var rounds = 0;
function after() {
  // The exchange takes several tasks: run them until it settles.
  while (replies.length < 2 && rounds < 20) {
    rounds++;
    runTimers();
  }
  check("a port from another realm arrives as one of this realm", received !== null && received.ports.length === 1 &&
    received.ports[0] instanceof MessagePort && received.source === child);
  check("postMessage's and a port's message events are trusted (the user agent fires them)",
    received !== null && received.isTrusted === true && trustedReplies);
  check("script's own dispatch of a message event is not trusted", (function () {
    var seen = null;
    var listener = function (event) { seen = event.isTrusted; };
    window.addEventListener("message", listener);
    window.dispatchEvent(new MessageEvent("message", { data: "forged" }));
    window.removeEventListener("message", listener);
    return seen === false;
  })());
  check("messages both ways, cloned into the receiver's realm", replies[0] === "echo ping true");
  check("a port sent back through a received port", replies[1] === "inner x");
  check("a port in a channel message", carried !== null && carried.ports.length === 1 &&
    carried.ports[0] !== third.port1 && carried.data === "with a port" && throughMoved === "to the moved port");
  check("a transferred port cannot be sent again", twice);
}
