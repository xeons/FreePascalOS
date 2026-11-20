// Wrapper identity, the interface objects and prototype chains,
// collections as legacy platform objects, expandos across collections.
document.body.innerHTML = "<div id=a><p>one</p><p>two</p></div>";
var a = document.getElementById("a");
check("the same node gives the same wrapper", document.body.firstChild === a && a.firstChild === a.childNodes[0] &&
  a.firstChild.parentNode === a && document.body === document.body);
check("[SameObject] collections", a.childNodes === a.childNodes && a.children === a.children &&
  a.classList === a.classList && a.style === a.style && a.dataset === a.dataset && a.attributes === a.attributes &&
  document.implementation === document.implementation);
a.expando = { value: 1 };
gc();
check("an expando survives a collection", document.getElementById("a").expando.value === 1);
a.childNodes.expando = "list";
gc();
check("an expando on a [SameObject] list survives", document.getElementById("a").childNodes.expando === "list");

check("interface objects", typeof Node === "function" && typeof HTMLDivElement === "function" &&
  Node.ELEMENT_NODE === 1 && Node.prototype.ELEMENT_NODE === 1 && a.ELEMENT_NODE === 1);
check("prototype chain", Object.getPrototypeOf(a) === HTMLDivElement.prototype &&
  Object.getPrototypeOf(HTMLDivElement.prototype) === HTMLElement.prototype &&
  Object.getPrototypeOf(HTMLElement.prototype) === Element.prototype &&
  Object.getPrototypeOf(Element.prototype) === Node.prototype &&
  Object.getPrototypeOf(Node.prototype) === EventTarget.prototype &&
  Object.getPrototypeOf(HTMLDivElement) === HTMLElement);
check("instanceof", a instanceof HTMLDivElement && a instanceof Node && a instanceof EventTarget &&
  !(a instanceof Text) && document instanceof Document && a.firstChild.firstChild instanceof Text);
check("toStringTag", Object.prototype.toString.call(a) === "[object HTMLDivElement]" &&
  String(document) === "[object HTMLDocument]" && String(new Document()) === "[object Document]" &&
  document instanceof HTMLDocument && String(document.body.style) === "[object CSSStyleProperties]");
check("element interfaces by name", document.createElement("a") instanceof HTMLAnchorElement &&
  document.createElement("h3") instanceof HTMLHeadingElement &&
  document.createElement("blink") instanceof HTMLUnknownElement &&
  Object.getPrototypeOf(document.createElement("my-widget")) === HTMLElement.prototype &&
  Object.getPrototypeOf(document.createElement("section")) === HTMLElement.prototype);
var illegal = null;
try { new Node(); } catch (e) { illegal = e; }
check("an interface without a constructor throws", illegal instanceof TypeError);
var invocation = null;
try { Node.prototype.appendChild.call({}, a); } catch (e) { invocation = e; }
check("a member on the wrong object throws", invocation instanceof TypeError);
var getter = Object.getOwnPropertyDescriptor(Node.prototype, "firstChild");
check("attributes are accessors on the prototype", typeof getter.get === "function" && getter.set === undefined &&
  getter.enumerable && getter.configurable && getter.get.call(a) === a.firstChild);
check("operations are methods", Node.prototype.hasOwnProperty("appendChild") && Node.prototype.appendChild.length === 1 &&
  Node.prototype.appendChild.name === "appendChild");

var paragraphs = a.querySelectorAll("p");
check("NodeList indices", paragraphs[0].textContent === "one" && paragraphs[1].textContent === "two" &&
  paragraphs[2] === undefined && paragraphs.length === 2 && 0 in paragraphs && !(2 in paragraphs));
check("NodeList iterates", [...paragraphs].length === 2 && Array.from(paragraphs.keys()).join() === "0,1");
var visited = [];
paragraphs.forEach(function (node, index) { visited.push(index + node.textContent); });
check("NodeList forEach", visited.join() === "0one,1two");
check("NodeList keys", Object.keys(paragraphs).join() === "0,1");
paragraphs[0] = null;
check("indices are read only", paragraphs[0] !== null);
var children = a.children;
a.firstElementChild.id = "first";
check("HTMLCollection named properties", children.first === a.firstElementChild && children.namedItem("first") === children[0] &&
  children["first"] === children.item(0));
check("named properties are not enumerable", Object.keys(children).join() === "0,1");
check("HTMLCollection is live", (a.appendChild(document.createElement("p")), children.length === 3));
check("document.forms and others", document.forms.length === 0 && document.scripts instanceof HTMLCollection &&
  document.forms === document.forms);

check("window identities", window === globalThis && self === window && window.window === window &&
  window.document === document && document.defaultView === window && frames === window);
check("Window prototype", window instanceof Window && window instanceof EventTarget &&
  Object.getPrototypeOf(window) === Window.prototype);
var unforgeable = Object.getOwnPropertyDescriptor(window, "document");
check("window.document is unforgeable", unforgeable && unforgeable.configurable === false);
self = 5;
check("self is [Replaceable]", self === 5);
