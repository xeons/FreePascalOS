// After parsing.html: inline scripts ran in order while parsing,
// document.write inserted at the insertion point, event handler content
// attributes, errors reported with their file and line.
check("scripts ran in document order", order.join(",") === "head,body,nested,after nested,after error,nomodule");
var written = document.getElementById("written");
check("document.write output comes right after its script",
  written.previousElementSibling.tagName === "SCRIPT" && written.nextElementSibling.tagName === "P" &&
  written.nextElementSibling.id === "after");
check("a script written by document.write runs and writes too", document.getElementById("deep") !== null);
check("readyState and the load events", states.join(",") ===
  "loading,change:interactive,DOMContentLoaded:interactive,change:complete,load:complete");
check("document.currentScript outside scripts", document.currentScript === null);
var text = consoleText();
check("an error is reported to the console", text.indexOf("undefinedFunction") >= 0 &&
  text.indexOf("ReferenceError") >= 0);
check("with the file and line", text.indexOf("inline script") >= 0 && text.indexOf(":2") >= 0);
clearConsole();
var clicker = document.getElementById("clicker");
check("a handler attribute is compiled when read", typeof clicker.onclick === "function");
var event = new MouseEvent("click", { cancelable: true });
clicker.dispatchEvent(event);
check("a handler attribute runs and its return value cancels", window.clicked === 1 && event.defaultPrevented);
clicker.click();
check("click() runs it", window.clicked === 2);
clicker.setAttribute("onclick", "window.clicked = 100");
clicker.click();
check("changing the attribute recompiles the handler", window.clicked === 100);
clicker.removeAttribute("onclick");
clicker.click();
check("removing it removes the handler", window.clicked === 100);
var made = document.createElement("button");
made.setAttribute("onclick", "window.madeClicked = true");
made.click();
check("a handler attribute set from script works", window.madeClicked === true);
var inserted = document.createElement("script");
inserted.textContent = "window.insertedRan = true;";
document.body.appendChild(inserted);
check("an inline script inserted by script runs when connected", window.insertedRan === true);
var late = document.createElement("script");
document.body.appendChild(late);
late.textContent = "window.lateRan = true;";
check("a connected empty script runs when it gets its text", window.lateRan === true);
var viaInnerHtml = document.createElement("div");
viaInnerHtml.innerHTML = "<script>window.innerRan = true<\/script>";
document.body.appendChild(viaInnerHtml);
check("innerHTML scripts never run", window.innerRan === undefined);
var writeError = null;
try { document.write("late"); } catch (e) { writeError = e; }
check("document.write after loading is refused", writeError instanceof DOMException && writeError.name === "NotSupportedError");
