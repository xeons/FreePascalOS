// Shadow DOM (DOM Standard 4.2.2, 4.8; checks after WPT's shadow-dom
// tests): attachShadow and its errors, open and closed roots, slots with
// named and manual assignment, assignedNodes with flatten, slotchange,
// event retargeting and composed, composedPath with closed trees,
// getRootNode, activeElement, innerHTML/getHTML and declarative roots.
document.body.innerHTML = '<div id="host"><span id="one" slot="a">1</span><b id="two">2</b>text</div>';
var host = document.getElementById("host");
var one = document.getElementById("one");
var two = document.getElementById("two");

var root = host.attachShadow({ mode: "open" });
check("attachShadow returns an open ShadowRoot", root instanceof ShadowRoot && root instanceof DocumentFragment &&
  root.mode === "open" && host.shadowRoot === root && root.host === host);
check("a shadow root's defaults", root.delegatesFocus === false && root.slotAssignment === "named" &&
  root.clonable === false && root.serializable === false);
var twice = null;
try { host.attachShadow({ mode: "open" }); } catch (e) { twice = e; }
check("a second attachShadow throws NotSupportedError", twice !== null && twice.name === "NotSupportedError");
var invalid = null;
try { document.createElement("img").attachShadow({ mode: "open" }); } catch (e) { invalid = e; }
check("attachShadow on img throws NotSupportedError", invalid !== null && invalid.name === "NotSupportedError");
var custom = document.createElement("my-widget").attachShadow({ mode: "closed" });
check("a valid custom element name can host", custom.mode === "closed");
var missingMode = null;
try { document.createElement("div").attachShadow({}); } catch (e) { missingMode = e; }
check("mode is required", missingMode instanceof TypeError);

var closedHost = document.createElement("section");
var closedRoot = closedHost.attachShadow({ mode: "closed" });
check("a closed root is not shadowRoot", closedHost.shadowRoot === null && closedRoot.host === closedHost);

root.innerHTML = '<p id="inner">in</p><slot name="a" id="slotA"></slot><slot id="defaultSlot">fallback</slot>';
var slotA = root.getElementById("slotA");
var defaultSlot = root.getElementById("defaultSlot");
check("ShadowRoot.getElementById and innerHTML", slotA instanceof HTMLSlotElement && slotA.name === "a" &&
  root.innerHTML.indexOf('<slot name="a" id="slotA"></slot>') > 0);
check("the shadow tree is not the document's", document.getElementById("inner") === null &&
  document.querySelector("#inner") === null && root.querySelector("#inner") !== null);
check("named assignment", slotA.assignedNodes().length === 1 && slotA.assignedNodes()[0] === one &&
  one.assignedSlot === slotA);
var defaults = defaultSlot.assignedNodes();
check("the default slot takes unnamed elements and text", defaults.length === 2 && defaults[0] === two &&
  defaults[1].nodeType === Node.TEXT_NODE && defaultSlot.assignedElements().length === 1);
check("a fallback slot's assignedNodes is empty, flatten gives its children",
  slotA.assignedNodes({ flatten: true }).length === 1 &&
  root.appendChild(document.createElement("slot")).assignedNodes({ flatten: true }).length === 0);

one.slot = "b";
check("changing slot unassigns", slotA.assignedNodes().length === 0 && one.assignedSlot === null);
slotA.name = "b";
check("changing a slot's name reassigns", slotA.assignedNodes()[0] === one && one.assignedSlot === slotA);

check("getRootNode and composed", one.getRootNode() === document && root.getElementById("inner").getRootNode() === root &&
  root.getElementById("inner").getRootNode({ composed: true }) === document);
check("nodes in a connected shadow tree are connected", root.getElementById("inner").isConnected === true &&
  root.isConnected === true);
check("closed trees hide assignedSlot", (function () {
  var light = document.createElement("i");
  closedHost.appendChild(light);
  closedRoot.appendChild(document.createElement("slot"));
  return light.assignedSlot === null;
})());

// Events: retargeting and composed.
var inner = root.getElementById("inner");
var seen = [];
host.addEventListener("ping", function (e) { seen.push("host:" + (e.target === host)); });
document.addEventListener("ping", function (e) { seen.push("document:" + (e.target === host)); });
root.addEventListener("ping", function (e) { seen.push("root:" + (e.target === inner)); });
inner.dispatchEvent(new Event("ping", { bubbles: true }));
check("a non-composed event stops at the shadow root", seen.join(",") === "root:true");
seen = [];
var path = null;
inner.addEventListener("ping", function (e) { path = e.composedPath(); });
inner.dispatchEvent(new Event("ping", { bubbles: true, composed: true }));
check("a composed event is retargeted to the host outside", seen.join(",") === "root:true,host:true,document:true");
check("composedPath from inside the open tree", path.length === 7 && path[0] === inner && path[1] === root &&
  path[2] === host && path[path.length - 1] === window);

var event = new Event("ping", { bubbles: true, composed: true });
inner.dispatchEvent(event);
check("after dispatch the target is the host and the path is empty", event.target === host &&
  event.composedPath().length === 0);

var closedInner = document.createElement("em");
closedRoot.appendChild(closedInner);
document.body.appendChild(closedHost);
var outsidePath = null;
closedHost.addEventListener("pong", function (e) { outsidePath = e.composedPath(); });
closedInner.dispatchEvent(new Event("pong", { bubbles: true, composed: true }));
check("composedPath outside a closed tree leaves it out", outsidePath !== null && outsidePath[0] === closedHost);

var slotted = [];
slotA.addEventListener("click", function (e) { slotted.push("slot"); });
host.addEventListener("click", function (e) { slotted.push("host:" + (e.target === one)); });
one.dispatchEvent(new MouseEvent("click", { bubbles: true, composed: true }));
check("a slotted node's event passes its slot", slotted.join(",") === "slot,host:true");

// Focus is retargeted.
var button = document.createElement("button");
root.appendChild(button);
button.focus();
check("activeElement is retargeted to the host", document.activeElement === host && root.activeElement === button);
button.blur();

// Serialization and declarative shadow roots.
var serializableHost = document.createElement("div");
serializableHost.attachShadow({ mode: "open", serializable: true }).innerHTML = "<b>s</b>";
check("getHTML with serializableShadowRoots", serializableHost.getHTML({ serializableShadowRoots: true }) ===
  '<template shadowrootmode="open" shadowrootserializable=""><b>s</b></template>' &&
  serializableHost.getHTML() === "");
var declared = document.createElement("div");
declared.setHTMLUnsafe('<div id="d"><template shadowrootmode="open"><slot></slot><i>x</i></template>light</div>');
var dhost = declared.querySelector("#d");
check("setHTMLUnsafe attaches declarative shadow roots", dhost.shadowRoot !== null &&
  dhost.shadowRoot.querySelector("i") !== null && dhost.childNodes.length === 1 &&
  dhost.querySelector("template") === null);
var plain = document.createElement("div");
plain.innerHTML = '<div><template shadowrootmode="open"><i>x</i></template></div>';
check("innerHTML leaves declarative templates alone", plain.firstChild.shadowRoot === null &&
  plain.querySelector("template") !== null);

// Cloning.
var clonableHost = document.createElement("div");
clonableHost.attachShadow({ mode: "open", clonable: true }).innerHTML = "<u>c</u>";
var copy = clonableHost.cloneNode(false);
check("a clonable shadow root is cloned", copy.shadowRoot !== null && copy.shadowRoot.clonable === true &&
  copy.shadowRoot.innerHTML === "<u>c</u>");
check("a non-clonable one is not", host.cloneNode(true).shadowRoot === null);

// Manual assignment.
var manualHost = document.createElement("div");
manualHost.innerHTML = "<span>m1</span><span>m2</span>";
var manualRoot = manualHost.attachShadow({ mode: "open", slotAssignment: "manual" });
var manualSlot = document.createElement("slot");
manualRoot.appendChild(manualSlot);
check("manual slots start empty", manualSlot.assignedNodes().length === 0);
manualSlot.assign(manualHost.lastChild);
check("assign()", manualSlot.assignedNodes().length === 1 && manualSlot.assignedNodes()[0] === manualHost.lastChild);

// slotchange fires at the next microtask.
var changes = [];
slotA.addEventListener("slotchange", function (e) { changes.push(e.target.id + ":" + e.bubbles); });
var late = document.createElement("span");
late.slot = "b";
host.appendChild(late);
check("slotchange is not synchronous", changes.length === 0);

// Styles are scoped.
var styledHost = document.createElement("div");
document.body.appendChild(styledHost);
var styledRoot = styledHost.attachShadow({ mode: "open" });
styledRoot.innerHTML = "<style>p { color: rgb(0, 128, 0); } :host { color: rgb(0, 0, 255); }</style><p>in</p>";
var outsideP = document.createElement("p");
document.body.appendChild(outsideP);
check("ShadowRoot.adoptedStyleSheets starts empty", Array.isArray(styledRoot.adoptedStyleSheets) &&
  styledRoot.adoptedStyleSheets.length === 0);

function after() {
  check("slotchange fired once at the slot, bubbling", changes.join(",") === "slotA:true");
}
