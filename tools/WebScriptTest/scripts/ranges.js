// Range, StaticRange and Selection (DOM Standard 5, Selection API): the
// boundary points and their checks, live adjustment by the mutation
// algorithms, the content operations, comparisons, the selection's
// range, anchor and focus, and selectionchange.
document.body.innerHTML = "<p id=a>Hello <b>bold</b> world</p><p id=b>second</p>";
var a = document.getElementById("a");
var b = document.getElementById("b");
var hello = a.firstChild;
var bold = a.childNodes[1];
var world = a.lastChild;

var range = document.createRange();
check("a new range is collapsed at the document's start", range.startContainer === document &&
  range.startOffset === 0 && range.collapsed && range instanceof Range && range instanceof AbstractRange);
check("new Range()", new Range().startContainer === document);
range.setStart(hello, 2);
range.setEnd(world, 3);
check("setStart and setEnd", range.startContainer === hello && range.startOffset === 2 &&
  range.endContainer === world && range.endOffset === 3 && !range.collapsed);
check("toString", String(range) === "llo bold wo" && range.toString() === "llo bold wo");
check("commonAncestorContainer", range.commonAncestorContainer === a);
var threw = "";
try { range.setStart(hello, 99); } catch (error) { threw = error.name; }
check("an offset past the end is an IndexSizeError", threw === "IndexSizeError");
threw = "";
try { range.setStart(document.doctype || document.implementation.createDocumentType("html", "", ""), 0); }
catch (error) { threw = error.name; }
check("a doctype is an InvalidNodeTypeError", threw === "InvalidNodeTypeError");

var later = document.createRange();
later.setStart(b.firstChild, 1);
check("a start after the end collapses the end onto it", later.collapsed && later.endContainer === b.firstChild);

check("comparePoint and isPointInRange", range.comparePoint(hello, 0) === -1 && range.comparePoint(bold, 0) === 0 &&
  range.comparePoint(b, 0) === 1 && range.isPointInRange(bold.firstChild, 1) && !range.isPointInRange(b, 0));
check("intersectsNode", range.intersectsNode(bold) && !range.intersectsNode(b));
var other = document.createRange();
other.selectNode(bold);
check("selectNode", other.startContainer === a && other.startOffset === 1 && other.endOffset === 2);
check("compareBoundaryPoints", range.compareBoundaryPoints(Range.START_TO_START, other) === -1 &&
  range.compareBoundaryPoints(Range.END_TO_END, other) === 1);
other.selectNodeContents(bold);
check("selectNodeContents", other.startContainer === bold && other.endOffset === 1);

var fragment = range.cloneContents();
check("cloneContents", fragment.childNodes.length === 3 && fragment.firstChild.data === "llo " &&
  fragment.childNodes[1].localName === "b" && fragment.lastChild.data === " wo" && a.textContent === "Hello bold world");

// Live adjustment.
var live = document.createRange();
live.setStart(a, 1);
live.setEnd(a, 3);
a.insertBefore(document.createElement("i"), a.firstChild);
check("insertion before the points moves them", live.startOffset === 2 && live.endOffset === 4);
a.removeChild(a.firstChild);
check("removal before the points moves them back", live.startOffset === 1 && live.endOffset === 3);
var inner = document.createRange();
inner.setStart(bold.firstChild, 2);
a.removeChild(bold);
check("a point inside a removed node goes to where it was", inner.startContainer === a && inner.startOffset === 1);
a.insertBefore(bold, world);
var textRange = document.createRange();
textRange.setStart(world, 4);
textRange.setEnd(world, 6);
world.insertData(0, "big ");
check("insertData before the points moves them", textRange.startOffset === 8 && textRange.endOffset === 10);
world.deleteData(0, 4);
check("deleteData moves them back", textRange.startOffset === 4 && textRange.endOffset === 6);
var rest = world.splitText(3);
check("splitText moves points past the split into the new node", textRange.startContainer === rest &&
  textRange.startOffset === 1 && textRange.endOffset === 3);
a.normalize();
check("normalize brings them back", textRange.startContainer === world && textRange.startOffset === 4 &&
  a.childNodes.length === 3);
world.data = "planet";
check("replacing the data collapses points in it to 0", textRange.startOffset === 0 && textRange.endOffset === 0);

// Content operations.
document.body.innerHTML = "<div id=c>one <em>two</em> three</div>";
var c = document.getElementById("c");
var r = document.createRange();
r.setStart(c.firstChild, 2);
r.setEnd(c.lastChild, 3);
var extracted = r.extractContents();
check("extractContents", c.innerHTML === "onree" && extracted.childNodes.length === 3 &&
  extracted.childNodes[1].outerHTML === "<em>two</em>" && r.collapsed && r.startContainer === c &&
  r.startOffset === 1);
r.insertNode(document.createTextNode("[x]"));
check("insertNode splits the text at the start", c.textContent === "on[x]ree" && c.childNodes.length === 3);
r.selectNodeContents(c);
r.deleteContents();
check("deleteContents", c.childNodes.length === 0 && r.collapsed);
c.innerHTML = "abc def";
r.setStart(c.firstChild, 4);
r.setEnd(c.firstChild, 7);
r.surroundContents(document.createElement("strong"));
check("surroundContents", c.innerHTML === "abc <strong>def</strong>" && r.startContainer === c &&
  r.startOffset === 1 && r.endOffset === 2);
var copy = r.cloneRange();
check("cloneRange", copy !== r && copy.startContainer === c && copy.endOffset === 2);
var made = r.createContextualFragment("<span>made</span>");
check("createContextualFragment", made.firstChild.localName === "span" && made instanceof DocumentFragment);

var s = new StaticRange({ startContainer: c, startOffset: 0, endContainer: c, endOffset: 1 });
check("StaticRange", s.startContainer === c && s.endOffset === 1 && !s.collapsed && s instanceof AbstractRange &&
  !(s instanceof Range));
c.textContent = "";
check("a StaticRange does not follow the tree", s.endOffset === 1);

// Selection.
document.body.innerHTML = "<p id=s>select me please</p>";
var p = document.getElementById("s");
var selection = window.getSelection();
check("getSelection: one object", selection === document.getSelection() && selection instanceof Selection &&
  selection.rangeCount === 0 && selection.type === "None" && selection.anchorNode === null);
var changes = 0;
document.addEventListener("selectionchange", function () { changes++; });
selection.collapse(p.firstChild, 2);
check("collapse", selection.rangeCount === 1 && selection.isCollapsed && selection.type === "Caret" &&
  selection.anchorNode === p.firstChild && selection.focusOffset === 2);
selection.extend(p.firstChild, 9);
check("extend", selection.type === "Range" && selection.anchorOffset === 2 && selection.focusOffset === 9 &&
  String(selection) === "lect me" && selection.direction === "forward");
selection.setBaseAndExtent(p.firstChild, 9, p.firstChild, 7);
check("setBaseAndExtent backwards", selection.anchorOffset === 9 && selection.focusOffset === 7 &&
  selection.getRangeAt(0).startOffset === 7 && selection.direction === "backward");
check("getRangeAt gives the same Range", selection.getRangeAt(0) === selection.getRangeAt(0));
var mine = document.createRange();
mine.selectNodeContents(p);
selection.removeAllRanges();
check("removeAllRanges", selection.rangeCount === 0);
selection.addRange(mine);
check("addRange keeps the object", selection.getRangeAt(0) === mine && String(selection) === "select me please");
mine.setEnd(p.firstChild, 6);
check("the selection follows its range", String(selection) === "select");
selection.selectAllChildren(p);
check("selectAllChildren", selection.anchorNode === p && selection.focusOffset === 1);
check("containsNode", selection.containsNode(p.firstChild) && !selection.containsNode(p) &&
  selection.containsNode(p, true));
selection.collapseToEnd();
check("collapseToEnd", selection.isCollapsed && selection.anchorOffset === 1);
var outside = document.createElement("div");
selection.collapse(outside, 0);
check("a node outside the document is ignored", selection.anchorNode === p);
selection.deleteFromDocument();
selection.setBaseAndExtent(p.firstChild, 0, p.firstChild, 7);
selection.deleteFromDocument();
check("deleteFromDocument", p.textContent === "me please");
selection.setBaseAndExtent(p.firstChild, 0, p.firstChild, 2);
var taken = selection.getRangeAt(0);
var loose = document.createTextNode("loose");
taken.setStart(loose, 1);
check("the selection's range moved out of the document is the selection no more",
  selection.rangeCount === 0 && taken.startContainer === loose && taken.endContainer === loose &&
  taken.startOffset === 1);
selection.setBaseAndExtent(p.firstChild, 0, p.firstChild, 2);

function after() {
  check("selectionchange fired once for the changes of a task", changes === 1);
}
