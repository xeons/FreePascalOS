// Nested navigables: an iframe's window is another realm of the same
// engine; about:blank and srcdoc documents; closing on removal.
var frame = document.createElement("iframe");
var loads = 0;
frame.onload = function () { loads++; };
check("no window before insertion", frame.contentWindow === null && frame.contentDocument === null);
document.body.appendChild(frame);
var child = frame.contentWindow;
check("a window after insertion", child !== null && String(child) === "[object Window]" && child !== window);
check("load fired at insertion", loads === 1);
check("about:blank document", frame.contentDocument === child.document &&
  child.document.URL === "about:blank" && child.document.body !== null &&
  child.document.documentElement.outerHTML === "<html><head></head><body></body></html>");
check("its own built-ins", child.String !== String && child.Array !== Array && child.Object.prototype !== Object.prototype);
check("built-ins work across realms", child.String.prototype.replace.call("abc", "b", "x") === "axc" &&
  child.Array.isArray([1]) && Array.isArray(new child.Array(2)));
check("objects made by a frame's built-ins are of its realm",
  Object.getPrototypeOf(child.Array.prototype.map.call([1, 2], function (x) { return x * 2; })) === child.Array.prototype);
check("the parent's function keeps its own globals when the frame calls it",
  child.Array.prototype.map.call([1], function () { return typeof check; })[0] === "function");
check("parent, top and frameElement", child.parent === window && child.top === window &&
  child.frameElement === frame && window.parent === window && window.frameElement === null);
check("frames length", window.length === 1);
var el = child.document.createElement("p");
check("nodes of the frame have its prototypes", el instanceof child.HTMLElement && !(el instanceof HTMLElement));
child.eval("var inside = 41; function bump() { return ++inside; }");
check("scripts in the frame use its global", child.inside === 41 && child.bump() === 42 && typeof inside === "undefined");
child.document.body.innerHTML = "<b>bold</b>";
check("the frame's DOM", child.document.body.firstChild.localName === "b");
var srcdoc = document.createElement("iframe");
srcdoc.srcdoc = "<p id=x>hello</p><script>var fromSrcdoc = document.getElementById('x').textContent;<\/script>";
document.body.appendChild(srcdoc);
check("srcdoc parsed with its scripts", srcdoc.contentDocument.URL === "about:srcdoc" &&
  srcdoc.contentWindow.fromSrcdoc === "hello" && window.length === 2);
frame.remove();
check("removal closes the window", frame.contentWindow === null && window.length === 1);
check("what the parent kept still works", child.String.prototype.toUpperCase.call("ok") === "OK");
gc();
check("collection after closing", child.Math.max(1, 2) === 2);
