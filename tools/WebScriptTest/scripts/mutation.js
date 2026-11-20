// MutationObserver: records for child lists, attributes and text, the
// subtree option, old values, filters, takeRecords, disconnect, and
// delivery in a microtask.
document.body.innerHTML = "<div id=root><p id=child>text</p></div>";
var root = document.getElementById("root");
var child = document.getElementById("child");
var batches = [];
var observer = new MutationObserver(function (records, which) {
  batches.push(records.map(function (record) {
    return record.type + ":" + record.target.nodeName + ":" +
      (record.attributeName || "") + ":" + record.oldValue + ":" + record.addedNodes.length + ":" +
      record.removedNodes.length;
  }).join("|"));
  check("the callback gets the observer as this and its second argument", this === observer && which === observer);
});
observer.observe(root, { childList: true, attributes: true, attributeOldValue: true, subtree: true,
  characterData: true, characterDataOldValue: true });
root.setAttribute("class", "a");
root.setAttribute("class", "b");
child.firstChild.data = "new";
var added = document.createElement("span");
root.appendChild(added);
root.removeChild(child);
check("records are not delivered synchronously", batches.length === 0);

var filtered = [];
var filterObserver = new MutationObserver(function (records) {
  records.forEach(function (record) { filtered.push(record.attributeName + "=" + record.oldValue); });
});
filterObserver.observe(added, { attributeFilter: ["title"], attributeOldValue: true });
added.setAttribute("lang", "en");
added.setAttribute("title", "one");
added.setAttribute("title", "two");

var taken = new MutationObserver(function () { check("takeRecords leaves nothing to deliver", false); });
taken.observe(root, { attributes: true });
root.id = "root2";
var takenRecords = taken.takeRecords();
check("takeRecords", takenRecords.length === 1 && takenRecords[0].attributeName === "id" &&
  takenRecords[0] instanceof MutationRecord);

var disconnected = new MutationObserver(function () { check("a disconnected observer gets nothing", false); });
disconnected.observe(root, { childList: true });
disconnected.disconnect();
root.appendChild(document.createElement("i"));

var observeError = null;
try { observer.observe(root, {}); } catch (e) { observeError = e; }
check("observe with nothing to observe throws", observeError instanceof TypeError);

var microtaskOrder = [];
Promise.resolve().then(function () { microtaskOrder.push("promise"); });
var orderObserver = new MutationObserver(function () { microtaskOrder.push("observer"); });
orderObserver.observe(document.body, { attributes: true });
document.body.setAttribute("x", "1");
queueMicrotask(function () { microtaskOrder.push("microtask"); });

function after() {
  check("one batch with the records in order", batches.length === 1 && batches[0] ===
    "attributes:DIV:class:null:0:0|attributes:DIV:class:a:0:0|characterData:#text::text:0:0|" +
    "childList:DIV::null:1:0|childList:DIV::null:0:1|attributes:SPAN:lang:null:0:0|attributes:SPAN:title:null:0:0|" +
    "attributes:SPAN:title:one:0:0|attributes:DIV:id:root:0:0|childList:DIV::null:1:0");
  check("attributeFilter and attributeOldValue", filtered.join(",") === "title=null,title=one");
  check("the mutation observer microtask was queued by the first mutation",
    microtaskOrder.join(",") === "observer,promise,microtask");
  child.setAttribute("late", "1");
}
