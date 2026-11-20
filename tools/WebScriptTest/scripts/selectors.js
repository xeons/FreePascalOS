// querySelector, querySelectorAll, matches and closest.
document.body.innerHTML =
  '<div id="main" class="box">' +
  '  <p class="first intro">a</p>' +
  '  <p lang="en-US">b <em>c</em></p>' +
  '  <ul><li>1</li><li class="odd">2</li><li>3</li><li data-x="yes">4</li></ul>' +
  '  <input type="checkbox" checked><input type="text" disabled>' +
  '  <a href="/x">link</a><a>anchor</a>' +
  '</div>' +
  '<div class="box other"><p>z</p></div>';
var main = document.getElementById("main");
function ids(list) {
  return Array.prototype.map.call(list, function (node) { return node.textContent.trim(); }).join(",");
}
check("by id", document.querySelector("#main") === main);
check("by class", document.querySelectorAll(".box").length === 2);
check("compound", document.querySelector("p.first.intro").textContent === "a");
check("descendant and child", ids(document.querySelectorAll("#main > p")) === "a,b c" &&
  ids(document.querySelectorAll("div p")) === "a,b c,z");
check("sibling combinators", ids(document.querySelectorAll("li + li")) === "2,3,4" &&
  ids(document.querySelectorAll(".odd ~ li")) === "3,4");
check("attribute selectors", document.querySelector("[data-x=yes]").textContent === "4" &&
  document.querySelectorAll("[lang|=en]").length === 1 && document.querySelector("[href^='/']").textContent === "link");
check(":nth-child", ids(document.querySelectorAll("li:nth-child(2n+1)")) === "1,3" &&
  ids(document.querySelectorAll("li:nth-last-child(1)")) === "4");
check(":not and :is", ids(document.querySelectorAll("li:not(.odd)")) === "1,3,4" &&
  document.querySelectorAll(":is(ul, em)").length === 2);
check(":has", document.querySelector("p:has(em)").textContent === "b c");
check(":first-child and :empty", ids(document.querySelectorAll("li:first-child")) === "1" &&
  document.querySelectorAll("p:empty").length === 0);
check("state pseudo-classes", document.querySelectorAll(":checked").length === 1 &&
  document.querySelectorAll("input:disabled").length === 1 && document.querySelectorAll("input:enabled").length === 1 &&
  document.querySelectorAll(":link").length === 1);
check(":lang", document.querySelector(":lang(en)").tagName === "P");
check("tree order", ids(document.querySelectorAll("li, p")) === "a,b c,1,2,3,4,z");
check(":scope", ids(main.querySelectorAll(":scope > ul > li.odd")) === "2" &&
  main.querySelector(":scope > p").textContent === "a");
check("a query only searches inside", main.querySelectorAll("div").length === 0 &&
  main.querySelector("#main") === null);
check(":root", document.querySelector(":root") === document.documentElement);
check("case of HTML names", document.querySelectorAll("LI").length === 4);
check("querySelectorAll is static", (function () {
  var list = document.querySelectorAll("li");
  main.querySelector("ul").appendChild(document.createElement("li"));
  return list.length === 4 && document.querySelectorAll("li").length === 5;
})());
var em = document.querySelector("em");
check("matches", em.matches("p > em") && em.matches("#main em") && !em.matches("li em") &&
  em.webkitMatchesSelector("em"));
check("closest", em.closest("div") === main && em.closest("p").tagName === "P" && em.closest("table") === null &&
  em.closest("em") === em);
var error = null;
try { document.querySelector("p::"); } catch (e) { error = e; }
check("an invalid selector is a SyntaxError DOMException", error instanceof DOMException && error.name === "SyntaxError");
check("fragment queries", (function () {
  var fragment = document.createDocumentFragment();
  fragment.appendChild(document.createElement("b")).id = "inside";
  return fragment.querySelector("#inside") !== null && fragment.getElementById("inside") !== null;
})());
check("pseudo-elements never match", document.querySelectorAll("p::before").length === 0);
