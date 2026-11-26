// Building and changing a tree from script, and the serialization that
// comes out.
var body = document.body;
var list = document.createElement("ul");
list.id = "list";
list.className = "items big";
for (var i = 1; i <= 3; i++) {
  var item = document.createElement("li");
  item.textContent = "item " + i;
  item.setAttribute("data-index", String(i));
  list.appendChild(item);
}
body.appendChild(list);
check("serialization after appendChild",
  body.innerHTML === '<ul id="list" class="items big"><li data-index="1">item 1</li>' +
  '<li data-index="2">item 2</li><li data-index="3">item 3</li></ul>');
check("childNodes is live", list.childNodes.length === 3);
list.removeChild(list.firstChild);
check("removeChild", list.childNodes.length === 2 && list.firstChild.textContent === "item 2");
list.insertBefore(document.createTextNode("text"), list.lastChild);
check("insertBefore a text node", list.childNodes[1].nodeType === Node.TEXT_NODE);
check("children skips text", list.children.length === 2 && list.childElementCount === 2);
list.childNodes[1].remove();

list.innerHTML = "<li>a</li><li class=x>b</li>";
check("innerHTML parses", list.children.length === 2 && list.children[1].className === "x");
check("outerHTML", list.outerHTML === '<ul id="list" class="items big"><li>a</li><li class="x">b</li></ul>');
list.firstElementChild.insertAdjacentHTML("afterend", "<li>c</li>");
check("insertAdjacentHTML", list.children[1].textContent === "c");
list.firstElementChild.after("after", document.createElement("hr"));
check("after() with a string and a node", list.childNodes[1].data === "after" && list.childNodes[2].tagName === "HR");
list.replaceChildren(document.createElement("li"));
check("replaceChildren", list.childNodes.length === 1);

var clone = list.cloneNode(true);
check("cloneNode deep", clone.outerHTML === list.outerHTML && clone !== list && clone.parentNode === null);
check("isEqualNode", clone.isEqualNode(list));
check("contains", body.contains(list) && !list.contains(body));
check("compareDocumentPosition", (body.compareDocumentPosition(list) & Node.DOCUMENT_POSITION_CONTAINED_BY) !== 0);

check("getElementById", document.getElementById("list") === list);
var tags = document.getElementsByTagName("li");
var before = tags.length;
list.appendChild(document.createElement("li"));
check("getElementsByTagName is live", tags.length === before + 1);
check("getElementsByClassName", document.getElementsByClassName("big")[0] === list);

check("attributes", list.getAttribute("id") === "list" && list.hasAttribute("class") && list.getAttribute("nope") === null);
check("toggleAttribute", list.toggleAttribute("hidden") === true && list.hidden === true);
list.toggleAttribute("hidden");
check("attributes map", list.attributes.length === 2 && list.attributes[0].name === "id" &&
  list.attributes.getNamedItem("class").value === "items big" && list.attributes.id.value === "list");
check("getAttributeNames", list.getAttributeNames().join() === "id,class");

list.classList.add("more");
list.classList.remove("big");
check("classList", list.className === "items more" && list.classList.contains("more") && list.classList.length === 2);
check("classList.toggle", list.classList.toggle("x") === true && list.classList.toggle("x") === false);
check("classList iterates", Array.from(list.classList).join("|") === "items|more");
check("classList stringifies", String(list.classList) === "items more");
list.classList = "one two";
check("classList PutForwards to value", list.className === "one two");

var data = document.createElement("div");
data.dataset.fooBar = "1";
check("dataset sets data-*", data.getAttribute("data-foo-bar") === "1");
data.setAttribute("data-x-y", "2");
check("dataset reads data-*", data.dataset.xY === "2" && Object.keys(data.dataset).join() === "fooBar,xY");
delete data.dataset.fooBar;
check("dataset delete", !data.hasAttribute("data-foo-bar"));

data.style.color = "red";
data.style.marginTop = "4px";
// libcss serializes a named color as rgb() (CSSOM keeps the keyword).
var red = data.style.color;
check("style camel case", (red === "red" || red === "rgb(255, 0, 0)") && data.style.marginTop === "4px");
check("style serializes into the attribute", data.getAttribute("style") === "color: " + red + "; margin-top: 4px;");
data.style.setProperty("background-color", "blue", "important");
check("setProperty with priority", data.style.getPropertyPriority("background-color") === "important");
check("style length and item", data.style.length === 3 && data.style[0] === "color");
data.style.removeProperty("color");
check("removeProperty", data.style.color === "" && data.style.length === 2);
data.style.cssText = "display: none";
check("cssText", data.style.display === "none" && data.getAttribute("style") === "display: none;");
data.style = "width: 3px";
check("style PutForwards to cssText", data.style.width === "3px");
data.style.color = "not a color";
check("an invalid value is ignored", data.style.color === "");

check("text node data", document.createTextNode("abc").length === 3);
var text = document.createTextNode("hello world");
var second = text.splitText(5);
check("splitText", text.data === "hello" && second.data === " world");
check("comment", document.createComment("c").nodeName === "#comment");
check("fragment", document.createDocumentFragment().nodeType === 11);
var fragment = new DocumentFragment();
fragment.append("a", "b");
check("DocumentFragment constructor and append", fragment.childNodes.length === 2 && fragment.textContent === "ab");

var error = null;
try {
  body.appendChild(document);
} catch (e) {
  error = e;
}
check("HierarchyRequestError is a DOMException", error instanceof DOMException && error.name === "HierarchyRequestError" &&
  error.code === 3 && error.code === DOMException.HIERARCHY_REQUEST_ERR);
check("DOMException inherits from Error", error instanceof Error && Object.prototype.toString.call(error) === "[object DOMException]");
try {
  document.createElement("1bad");
} catch (e) {
  error = e;
}
check("InvalidCharacterError", error.name === "InvalidCharacterError");
var made = new DOMException("why", "NotFoundError");
check("DOMException constructor", made.message === "why" && made.name === "NotFoundError" && made.code === 8);

check("document properties", document.title === "test" && document.compatMode === "CSS1Compat" &&
  document.characterSet === "UTF-8" && document.contentType === "text/html" && document.doctype.name === "html");
document.title = "changed";
check("document.title setter", document.querySelector("title").textContent === "changed");
check("document.URL", document.URL === "https://example.test/dir/page.html");
check("documentElement", document.documentElement.tagName === "HTML" && document.head.tagName === "HEAD");
check("nodeValue of an element is null", body.nodeValue === null && document.textContent === null);
check("ownerDocument", list.ownerDocument === document && document.ownerDocument === null);

var doc = document.implementation.createHTMLDocument("other");
check("createHTMLDocument", doc.title === "other" && doc.body !== null && doc !== document);
var adopted = document.adoptNode(doc.body);
check("adoptNode", adopted.ownerDocument === document);
var xml = document.implementation.createDocument("http://www.w3.org/2000/svg", "svg", null);
check("createDocument", xml.documentElement.namespaceURI === "http://www.w3.org/2000/svg");
var svg = document.createElementNS("http://www.w3.org/2000/svg", "svg:circle");
check("createElementNS", svg.prefix === "svg" && svg.localName === "circle" && svg instanceof Element &&
  !(svg instanceof HTMLElement));
// HTML's cloning steps: a script that ran does not run again as a copy;
// an input and a textarea keep what was typed (the dirty value).
window.cloneRuns = 0;
var ran = document.createElement("script");
ran.textContent = "window.cloneRuns++;";
document.body.appendChild(ran);
document.body.appendChild(ran.cloneNode(true));
check("a cloned script that already ran does not run again", window.cloneRuns === 1);
var typedInput = document.createElement("input");
typedInput.value = "typed";
check("a cloned input keeps its value", typedInput.cloneNode().value === "typed");
var typedArea = document.createElement("textarea");
typedArea.textContent = "default";
typedArea.value = "changed";
check("a cloned textarea keeps its value", typedArea.cloneNode(true).value === "changed");
// DOM traversal: TreeWalker and NodeIterator with whatToShow and filters
// (lit walks its templates with one).
var walkRoot = document.createElement("div");
walkRoot.innerHTML = "<p id=w1>a<!--c--><b id=w2>b</b></p><i id=w3>i</i><u id=w4><s id=w5></s></u>";
var walker = document.createTreeWalker(walkRoot, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_COMMENT);
var walked = [];
while (walker.nextNode()) walked.push(walker.currentNode.nodeType === 8 ? "#c" : walker.currentNode.id);
check("TreeWalker nextNode in tree order", walked.join() === "w1,#c,w2,w3,w4,w5");
var back = [];
while (walker.previousNode()) back.push(walker.currentNode.nodeType === 8 ? "#c" : walker.currentNode.id);
check("TreeWalker previousNode back to the root", back.join() === "w4,w3,w2,#c,w1," && walker.currentNode === walkRoot);
var skipping = document.createTreeWalker(walkRoot, NodeFilter.SHOW_ELEMENT, function (node) {
  return node.id === "w1" ? NodeFilter.FILTER_SKIP : node.id === "w4" ? NodeFilter.FILTER_REJECT :
    NodeFilter.FILTER_ACCEPT;
});
check("TreeWalker skip and reject", skipping.firstChild().id === "w2" && skipping.nextSibling().id === "w3" &&
  skipping.nextSibling() === null && skipping.parentNode() === walkRoot);
var texts = document.createNodeIterator(walkRoot, NodeFilter.SHOW_TEXT, { acceptNode: function () { return 1; } });
var found = [];
for (var textNode = texts.nextNode(); textNode; textNode = texts.nextNode()) found.push(textNode.data);
check("NodeIterator with an acceptNode object", found.join() === "a,b,i" && texts.previousNode().data === "i" &&
  texts.pointerBeforeReferenceNode === true && texts instanceof NodeIterator);

// Collections with an indexed getter and a length iterate as arrays do
// (WebIDL): 4chan's ads code runs for...of over getElementsByClassName,
// and the rest of its start-up never ran when that threw.
var iterRoot = document.createElement("div");
iterRoot.innerHTML = "<p class=k>1</p><span class=k>2</span><p>3</p>";
var iterated = [];
for (const element of iterRoot.getElementsByClassName("k")) iterated.push(element.textContent);
check("for...of over an HTMLCollection", iterated.join() === "1,2");
check("spreading children", [...iterRoot.children].length === 3);
check("HTMLCollection's iterator is Array.prototype.values",
  HTMLCollection.prototype[Symbol.iterator] === Array.prototype.values &&
  !HTMLCollection.prototype.propertyIsEnumerable(Symbol.iterator));
iterRoot.firstChild.setAttribute("title", "t");
check("Array.from over a NamedNodeMap", Array.from(iterRoot.firstChild.attributes).length === 2);
check("a derived collection inherits its iterator",
  typeof HTMLFormControlsCollection === "undefined" ||
  !Object.prototype.hasOwnProperty.call(HTMLFormControlsCollection.prototype, Symbol.iterator));
var xmlDocument = new DOMParser().parseFromString(
  '<?xml version="1.0"?><!DOCTYPE r [<!ENTITY e "ent">]><r xmlns="urn:a" xmlns:b="urn:b" b:at="1">' +
  '<b:c>&e;&#x41;</b:c><![CDATA[<x>]]><?pi data?><!--note--></r>', "application/xml");
var xmlRoot = xmlDocument.documentElement;
check("DOMParser parses XML (namespaces, entities, CDATA, PIs, comments)", xmlDocument instanceof XMLDocument &&
  xmlRoot.namespaceURI === "urn:a" && xmlRoot.firstChild.namespaceURI === "urn:b" &&
  xmlRoot.firstChild.prefix === "b" && xmlRoot.firstChild.textContent === "entA" &&
  xmlRoot.getAttributeNS("urn:b", "at") === "1" && xmlRoot.childNodes[1].nodeType === Node.CDATA_SECTION_NODE &&
  xmlRoot.childNodes[2].target === "pi" && xmlRoot.childNodes[3].data === "note" && xmlDocument.doctype.name === "r");
var brokenXml = new DOMParser().parseFromString("<a><b></a>", "text/xml");
check("XML that is not well-formed gives the parser error document",
  brokenXml.documentElement.localName === "parsererror");
check("createDocument makes an XMLDocument", document.implementation.createDocument(null, "x") instanceof XMLDocument);
var serialized = new XMLSerializer().serializeToString(new DOMParser().parseFromString(
  '<r xmlns="urn:a" xmlns:b="urn:b"><b:c at="1"/>t&amp;</r>', "application/xml"));
check("XMLSerializer keeps namespaces and escapes", serialized === '<r xmlns="urn:a" xmlns:b="urn:b"><b:c at="1"/>t&amp;</r>');
var htmlSerialized = new XMLSerializer().serializeToString(document.createElement("br"));
check("XMLSerializer closes an HTML void element", htmlSerialized === '<br xmlns="http://www.w3.org/1999/xhtml" />');
check("Document.parseHTMLUnsafe", Document.parseHTMLUnsafe("<p>x").body.firstChild.localName === "p");

// document.all: every element, by index and name, callable, and yet
// typeof "undefined" and false ([[IsHTMLDDA]]).
document.body.innerHTML = '<p id="allfirst">x</p><form name="allform"></form><img name="allpic">';
var all = document.all;
check("document.all is [[IsHTMLDDA]]", typeof all === "undefined" && !all && all == null && all == undefined &&
  all !== undefined && all !== null && (all ? 1 : 2) === 2 && (all ?? "nullish") === all);
check("document.all is the same object", document.all === all &&
  Object.prototype.toString.call(all) === "[object HTMLAllCollection]" && all instanceof HTMLAllCollection);
check("document.all's elements in tree order", all.length === document.getElementsByTagName("*").length &&
  all[0] === document.documentElement && all.item(0) === document.documentElement);
check("document.all by name and id, and called", all.allfirst === document.getElementById("allfirst") &&
  all.namedItem("allform").localName === "form" && all("allpic").localName === "img" && all("nothing") === null &&
  all() === null && all["missing"] === undefined);
