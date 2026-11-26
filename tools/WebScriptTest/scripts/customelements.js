// Custom elements (HTML 4.13; checks after WPT's custom-elements tests):
// define and its errors, get, getName, whenDefined, construction with
// new and createElement, upgrades of existing elements, the lifecycle
// callbacks and their order, observedAttributes, customized built-ins,
// :defined, form-associated custom elements with ElementInternals, and
// CustomStateSet.
var log = [];
class MyElement extends HTMLElement {
  static get observedAttributes() { return ["title", "data-x"]; }
  constructor() {
    super();
    log.push("constructor");
  }
  connectedCallback() { log.push("connected:" + this.isConnected); }
  disconnectedCallback() { log.push("disconnected"); }
  adoptedCallback(oldDocument, newDocument) { log.push("adopted:" + (newDocument !== oldDocument)); }
  attributeChangedCallback(name, oldValue, newValue, namespace) {
    log.push("attr:" + name + ":" + oldValue + ":" + newValue + ":" + namespace);
  }
}

check("customElements is a CustomElementRegistry", customElements instanceof CustomElementRegistry &&
  window.customElements === customElements);
var illegal = null;
try { new HTMLElement(); } catch (e) { illegal = e; }
check("new HTMLElement() throws TypeError", illegal instanceof TypeError);
var unregistered = null;
try { new MyElement(); } catch (e) { unregistered = e; }
check("an undefined class cannot be constructed", unregistered instanceof TypeError);

// An element in the document before define is upgraded by define.
document.body.innerHTML = '<my-element id="early" title="t"></my-element>';
var early = document.getElementById("early");
check("before define the element is HTMLElement and not :defined", early.constructor === HTMLElement &&
  !early.matches(":defined") && document.body.matches(":defined"));

var whenDefined = customElements.whenDefined("my-element");
var whenDefinedResult = null;
whenDefined.then(function (value) { whenDefinedResult = value; });
check("whenDefined returns the same promise until defined", customElements.whenDefined("my-element") === whenDefined);

customElements.define("my-element", MyElement);
check("define upgrades the elements in the document", early instanceof MyElement && early.matches(":defined") &&
  log.join(",") === "constructor,attr:title:null:t:null,connected:true");
check("get and getName", customElements.get("my-element") === MyElement &&
  customElements.getName(MyElement) === "my-element" && customElements.get("nope") === undefined &&
  customElements.getName(function () {}) === null);

function defineError(name, constructor, options) {
  try { customElements.define(name, constructor, options); } catch (e) { return e.name; }
  return "none";
}
check("define's errors", defineError("my-element", class extends HTMLElement {}) === "NotSupportedError" &&
  defineError("other-element", MyElement) === "NotSupportedError" &&
  defineError("nohyphen", class extends HTMLElement {}) === "SyntaxError" &&
  defineError("font-face", class extends HTMLElement {}) === "SyntaxError" &&
  defineError("x-arrow", function () {}.bind(null)) === "TypeError" &&
  defineError("x-extends", class extends HTMLElement {}, { extends: "my-element" }) === "NotSupportedError");

log = [];
var made = new MyElement();
check("new makes an element of the definition", made instanceof MyElement && made.localName === "my-element" &&
  made.matches(":defined") && log.join(",") === "constructor");
log = [];
var created = document.createElement("my-element");
check("createElement constructs at once", created instanceof MyElement && log.join(",") === "constructor");

log = [];
document.body.appendChild(created);
created.setAttribute("title", "a");
created.setAttribute("lang", "en");
created.setAttribute("data-x", "1");
created.removeAttribute("title");
document.body.removeChild(created);
check("callbacks run as each method returns, for observed attributes only", log.join(",") ===
  "connected:true,attr:title:null:a:null,attr:data-x:null:1:null,attr:title:a:null:null,disconnected");

log = [];
var other = document.implementation.createHTMLDocument("");
other.adoptNode(made);
check("adoptedCallback", log.join(",") === "adopted:true");

log = [];
var holder = document.createElement("div");
holder.innerHTML = "<my-element></my-element>";
check("innerHTML on a detached element does not upgrade (the fragment's document has no registry)",
  log.length === 0 && !(holder.firstChild instanceof MyElement));
document.body.appendChild(holder);
check("connecting upgrades it", log.join(",") === "constructor,connected:true" &&
  holder.firstChild instanceof MyElement);

// Customized built-in elements.
class FancyButton extends HTMLButtonElement {
  constructor() { super(); this.fancy = true; }
}
customElements.define("fancy-button", FancyButton, { extends: "button" });
var fancy = document.createElement("button", { is: "fancy-button" });
check("a customized built-in from createElement", fancy instanceof FancyButton && fancy instanceof HTMLButtonElement &&
  fancy.fancy === true && fancy.localName === "button");
var fancyNew = new FancyButton();
check("new on a customized built-in", fancyNew.localName === "button" && fancyNew.outerHTML === '<button is="fancy-button"></button>');
holder.innerHTML = '<button is="fancy-button">b</button>';
check("is= upgrades from markup", holder.firstChild instanceof FancyButton);

// whenDefined settles in a microtask.
var rejected = null;
customElements.whenDefined("invalid").catch(function (e) { rejected = e; });

// upgrade() upgrades a tree that is not in the document.
var detached = document.createElement("div");
detached.innerHTML = "<late-element></late-element>";
class LateElement extends HTMLElement {}
customElements.define("late-element", LateElement);
check("define does not upgrade elements outside the document", !(detached.firstChild instanceof LateElement));
customElements.upgrade(detached);
check("upgrade() does", detached.firstChild instanceof LateElement);

// Shadow roots and disabledFeatures.
class NoShadow extends HTMLElement {
  static get disabledFeatures() { return ["shadow"]; }
}
customElements.define("no-shadow", NoShadow);
var noShadowError = null;
try { new NoShadow().attachShadow({ mode: "open" }); } catch (e) { noShadowError = e; }
check("disabledFeatures shadow", noShadowError !== null && noShadowError.name === "NotSupportedError");

// Form-associated custom elements.
class MyInput extends HTMLElement {
  static get formAssociated() { return true; }
  constructor() {
    super();
    this.internals = this.attachInternals();
  }
  formResetCallback() { log.push("reset"); }
  formAssociatedCallback(form) { log.push("form:" + (form ? form.id : null)); }
}
customElements.define("my-input", MyInput);
document.body.insertAdjacentHTML("beforeend", '<form id="f"><my-input name="mine"></my-input><input name="plain" value="p"></form>');
var form = document.getElementById("f");
var mine = form.querySelector("my-input");
check("a form-associated custom element is listed in its form", form.elements.length === 2 &&
  form.elements[0] === mine && mine.internals.form === form);
var twiceInternals = null;
try { mine.attachInternals(); } catch (e) { twiceInternals = e; }
check("attachInternals only once", twiceInternals !== null && twiceInternals.name === "NotSupportedError");
mine.internals.setFormValue("v1");
check("setFormValue and willValidate", mine.internals.willValidate === true && mine.internals.validity.valid);
mine.internals.setValidity({ valueMissing: true }, "fill me");
check("setValidity", !mine.internals.validity.valid && mine.internals.validity.valueMissing &&
  mine.internals.validationMessage === "fill me" && mine.internals.checkValidity() === false &&
  form.checkValidity() === false);
var setValidityError = null;
try { mine.internals.setValidity({ customError: true }); } catch (e) { setValidityError = e; }
check("setValidity needs a message with flags", setValidityError instanceof TypeError);
mine.internals.setValidity({});
check("clearing validity", mine.internals.validity.valid && form.checkValidity());
log = [];
form.reset();
check("form reset runs formResetCallback", log.join(",") === "reset");
var plainInternals = null;
try { new LateElement().attachInternals().form; } catch (e) { plainInternals = e; }
check("a non-form-associated element's form members throw", plainInternals !== null &&
  plainInternals.name === "NotSupportedError");

// CustomStateSet and :state().
var states = mine.internals.states;
states.add("checked");
check("CustomStateSet and :state()", states.has("checked") && states.size === 1 && mine.matches(":state(checked)") &&
  Array.from(states).join(",") === "checked");
states.delete("checked");
check("deleting a state", !mine.matches(":state(checked)") && states.size === 0);

function after() {
  check("whenDefined resolved with the constructor", whenDefinedResult === MyElement);
  check("whenDefined rejects invalid names with SyntaxError", rejected !== null && rejected.name === "SyntaxError");
}
