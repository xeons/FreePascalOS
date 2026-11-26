// Reflected attributes and the form control basics.
var a = document.createElement("a");
a.href = "../other/page.html?q=1#top";
check("a URL attribute resolves against the document", a.href === "https://example.test/other/page.html?q=1#top" &&
  a.getAttribute("href") === "../other/page.html?q=1#top");
check("hyperlink parts", a.protocol === "https:" && a.host === "example.test" && a.pathname === "/other/page.html" &&
  a.search === "?q=1" && a.hash === "#top" && a.origin === "https://example.test" && String(a) === a.href);
a.hash = "bottom";
check("a hyperlink part setter writes href", a.getAttribute("href") === "https://example.test/other/page.html?q=1#bottom");
a.relList.add("noopener");
check("relList", a.rel === "noopener" && a.relList === a.relList);
check("no href", document.createElement("a").href === "" && document.createElement("a").protocol === ":");
var base = document.createElement("base");
base.href = "https://cdn.example.test/assets/";
document.head.appendChild(base);
var img = document.createElement("img");
img.src = "logo.png";
check("the base element is the base URL", img.src === "https://cdn.example.test/assets/logo.png");
base.remove();
check("string reflection", (img.alt = "x", img.getAttribute("alt") === "x") && img.title === "" &&
  (img.title = "t", img.getAttribute("title") === "t"));
check("unsigned long default", img.width === 0 && (img.width = 30, img.getAttribute("width") === "30") &&
  img.width === 30);
img.setAttribute("width", "-5");
check("a bad unsigned long gives the default", img.width === 0);
img.setAttribute("width", "  12px");
check("the rules for parsing integers", img.width === 12);
var input = document.createElement("input");
check("long with a default", input.maxLength === -1 && (input.maxLength = 4, input.maxLength === 4));
check("limited to positive", input.size === 20 && (function () {
  try { input.size = 0; return false; } catch (e) { return e.name === "IndexSizeError"; }
})());
var button = document.createElement("button");
check("enumerated attribute default", button.type === "submit");
button.setAttribute("type", "RESET");
check("enumerated keywords match without case", button.type === "reset");
button.setAttribute("type", "nonsense");
check("an invalid value default", button.type === "submit");
var form = document.createElement("form");
check("form.method", form.method === "get" && (form.method = "POST", form.method === "post") &&
  form.getAttribute("method") === "POST");
check("form.enctype", form.enctype === "application/x-www-form-urlencoded");
var div = document.createElement("div");
check("boolean reflection", div.hidden === false && (div.hidden = true, div.getAttribute("hidden") === "") &&
  (div.hidden = false, !div.hasAttribute("hidden")));
check("id and className", (div.id = "x", div.getAttribute("id") === "x") &&
  (div.className = "y", div.getAttribute("class") === "y"));
check("htmlFor", (function () { var label = document.createElement("label"); label.htmlFor = "f";
  return label.getAttribute("for") === "f"; })());
check("tabIndex defaults", div.tabIndex === -1 && document.createElement("button").tabIndex === 0 &&
  (div.tabIndex = 3, div.getAttribute("tabindex") === "3"));
var td = document.createElement("td");
check("colSpan", td.colSpan === 1 && (td.setAttribute("colspan", "0"), td.colSpan === 1));
var meter = document.createElement("meter");
check("double reflection", meter.max === 1 && (meter.max = 2.5, meter.getAttribute("max") === "2.5"));
check("lang and dir", (div.dir = "RTL", div.dir === "rtl") && (div.dir = "sideways", div.dir === ""));

input.value = "typed";
check("input.value is state, not the attribute", input.value === "typed" && !input.hasAttribute("value"));
input.defaultValue = "default";
check("defaultValue reflects value", input.getAttribute("value") === "default" && input.value === "typed");
var fresh = document.createElement("input");
fresh.setAttribute("value", "from attribute");
check("an input's value comes from the attribute until changed", fresh.value === "from attribute");
fresh.value = "line\nbreak";
check("text values lose line breaks", fresh.value === "linebreak");
var box = document.createElement("input");
box.type = "checkbox";
check("checkbox type and value", box.type === "checkbox" && box.value === "on");
box.defaultChecked = true;
check("defaultChecked gives checked", box.checked === true);
box.checked = false;
check("checked is state", box.checked === false && box.hasAttribute("checked"));
var changes = 0;
box.addEventListener("change", function () { changes++; });
box.click();
check("click() toggles a checkbox and fires change", box.checked === true && changes === 1);
box.addEventListener("click", function (e) { e.preventDefault(); });
box.click();
check("a canceled click restores checkedness", box.checked === true && changes === 1);
check("an unknown input type is text", (function () { var i = document.createElement("input");
  i.setAttribute("type", "fancy"); return i.type === "text"; })());
var number = document.createElement("input");
number.type = "number";
number.value = "2.5";
check("valueAsNumber", number.valueAsNumber === 2.5 && (number.valueAsNumber = 7, number.value === "7"));

document.body.innerHTML = '<form id=f action="/submit"><select name=s><option>a</option>' +
  '<option value=bee selected>b</option><optgroup><option>c</option></optgroup></select>' +
  '<input name=t value=1><input type=radio name=r value=x checked><input type=radio name=r value=y>' +
  '<textarea name=ta>text</textarea><input type=submit></form>';
var select = document.querySelector("select");
check("select basics", select.length === 3 && select.selectedIndex === 1 && select.value === "bee" &&
  select.type === "select-one" && select.options.length === 3 && select.options[2].text === "c");
select.value = "c";
check("select.value setter", select.selectedIndex === 2 && select.options[2].selected && !select.options[1].selected);
select.selectedIndex = 0;
check("selectedIndex setter", select.value === "a" && select.selectedOptions.length === 1 &&
  select.selectedOptions[0] === select.options[0]);
check("option index and form", select.options[2].index === 2 && select.options[0].form === document.getElementById("f"));
var radios = document.querySelectorAll("input[type=radio]");
radios[1].checked = true;
check("a radio group has one checked", radios[1].checked && !radios[0].checked);
var textarea = document.querySelector("textarea");
check("textarea value", textarea.value === "text" && textarea.defaultValue === "text" && textarea.type === "textarea");
textarea.value = "changed";
check("textarea value is state", textarea.value === "changed" && textarea.textContent === "text");
var formElement = document.getElementById("f");
check("form.elements", formElement.elements.length === 6 && formElement.length === 6 &&
  formElement.elements.t === document.querySelector("input[name=t]"));
check("form of a control", document.querySelector("input[name=t]").form === formElement);
var required = document.createElement("input");
required.required = true;
var invalid = 0;
required.addEventListener("invalid", function () { invalid++; });
check("checkValidity", required.checkValidity() === false && invalid === 1 && (required.value = "x", required.checkValidity()));
required.setCustomValidity("nope");
check("setCustomValidity", required.checkValidity() === false);
formElement.submit();
check("a GET form submits through the environment", lastNavigation() ===
  "https://example.test/submit?s=a&t=1&r=y&ta=changed");
var submits = 0;
formElement.addEventListener("submit", function (e) { submits++; e.preventDefault(); });
formElement.requestSubmit();
check("requestSubmit fires submit", submits === 1);
formElement.reset();
check("reset restores the defaults", textarea.value === "text" && radios[0].checked && select.value === "bee");

var template = document.createElement("template");
template.innerHTML = "<b>bold</b>";
check("template content", template.content instanceof DocumentFragment && template.content.firstChild.tagName === "B" &&
  template.childNodes.length === 0);
var script = document.createElement("script");
script.text = "1 + 1";
check("script text and async", script.text === "1 + 1" && script.async === false && (script.async = true,
  script.hasAttribute("async")));
check("HTMLScriptElement.supports", HTMLScriptElement.supports("classic") && !HTMLScriptElement.supports("module"));
var editable = document.createElement("div");
check("contentEditable", editable.contentEditable === "inherit" && (editable.contentEditable = "true",
  editable.isContentEditable));
editable.innerText = "a\nb";
check("innerText setter makes line breaks", editable.innerHTML === "a<br>b");

var fieldset = document.createElement("fieldset");
fieldset.innerHTML = "<legend>l</legend><input name=a><div><select name=b></select><output></output></div>" +
  "<label>x</label><fieldset><button>b</button></fieldset><input type=image>";
var fieldsetElements = fieldset.elements;
check("fieldset.elements lists the listed elements under it",
  fieldsetElements instanceof HTMLCollection && fieldsetElements.length === 6 &&
  fieldsetElements[0].name === "a" && fieldsetElements.b.tagName === "SELECT" &&
  fieldsetElements[4].tagName === "BUTTON" && fieldset.elements === fieldsetElements);
fieldset.appendChild(document.createElement("textarea"));
check("fieldset.elements is live", fieldsetElements.length === 7);
