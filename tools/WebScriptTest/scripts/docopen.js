// document.open, write and close outside the parser (HTML 8.4): an
// iframe's about:blank document written by its parent (what DuckDuckGo
// does to follow a result), then the page written anew.
var frame = document.createElement("iframe");
document.body.appendChild(frame);
var doc = frame.contentDocument;
doc.open();
check("document.open: the document is emptied and loading", doc.documentElement === null && doc.readyState === "loading");
doc.writeln("<html><head><title>written</title></head><body><p id=p>one</p><script>" +
  "parent.window.fromFrame = document.getElementById('p').textContent; document.write('<b id=b>two</b>');<\/script>");
doc.write("<i id=i>three</i></body></html>");
check("document.write: a written script runs in the frame's window", window.fromFrame === "one");
check("document.write from a written script inserts at its place",
  doc.getElementById("b") !== null && doc.getElementById("b").nextElementSibling === doc.getElementById("i"));
var loaded = false;
frame.contentWindow.addEventListener("load", function () { loaded = true; });
doc.close();
check("document.close: the document is complete", doc.readyState === "complete" && doc.title === "written" &&
  doc.getElementById("i").textContent === "three");
check("document.close: load fires at the frame's window", loaded);
doc.close();
check("document.close again does nothing", doc.getElementById("i") !== null);
document.write("<p id=fresh>fresh</p>");
check("document.write after loading writes a new document",
  document.getElementById("fresh") !== null && document.querySelector("iframe") === null);
