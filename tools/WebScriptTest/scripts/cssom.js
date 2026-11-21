// The CSSOM: document.styleSheets, a <style>'s sheet, cssRules,
// insertRule and deleteRule (as CSS-in-JS libraries use them), rule
// objects (style, media, keyframes, import), CSSStyleRule.style,
// MediaList, constructable sheets with replaceSync and replace, and
// adoptedStyleSheets.
document.head.innerHTML = "<style id=one>p { color: red } @media (min-width: 1px) { .a { margin: 1px } }" +
  " @keyframes spin { from { opacity: 0 } to { opacity: 1 } }</style>";
var style = document.getElementById("one");
var sheet = style.sheet;
check("a style element's sheet", sheet instanceof CSSStyleSheet && sheet === style.sheet && sheet.ownerNode === style &&
  sheet.type === "text/css" && sheet.href === null);
check("document.styleSheets", document.styleSheets.length === 1 && document.styleSheets[0] === sheet &&
  document.styleSheets.item(0) === sheet && document.styleSheets === document.styleSheets);
var rules = sheet.cssRules;
check("cssRules", rules.length === 3 && rules === sheet.cssRules && rules[0] === rules.item(0) &&
  rules[0] instanceof CSSStyleRule && rules[1] instanceof CSSMediaRule && rules[2] instanceof CSSKeyframesRule);
var first = rules[0];
check("CSSStyleRule", first.selectorText === "p" && first.style.color === "rgb(255, 0, 0)" && first.type === 1 &&
  first.parentStyleSheet === sheet && first.parentRule === null && first.cssText === "p { color: rgb(255, 0, 0); }");
check("CSSMediaRule", rules[1].conditionText === "(min-width: 1px)" && rules[1].media.mediaText === "(min-width: 1px)" &&
  rules[1].cssRules.length === 1 && rules[1].cssRules[0].parentRule === rules[1] && rules[1].type === 4);
check("CSSKeyframesRule", rules[2].name === "spin" && rules[2].length === 2 && rules[2][0].keyText === "0%" &&
  rules[2].findRule("to") === rules[2][1] && rules[2][1].style.opacity === "1");

check("insertRule at the end", sheet.insertRule(".x { color: blue }", rules.length) === 3 && rules.length === 4 &&
  rules[3].selectorText === ".x");
check("insertRule at the start", sheet.insertRule("div { width: 1px }") === 0 && rules[0].selectorText === "div" &&
  rules[1] === first);
var threw = "";
try { sheet.insertRule("{{{", 0); } catch (error) { threw = error.name; }
check("an unparsable rule is a SyntaxError", threw === "SyntaxError");
threw = "";
try { sheet.insertRule("a {}", 99); } catch (error) { threw = error.name; }
check("an index past the end is an IndexSizeError", threw === "IndexSizeError");
var removed = rules[0];
sheet.deleteRule(0);
check("deleteRule", rules.length === 4 && rules[0] === first);
check("a removed rule keeps answering", typeof removed.cssText === "string");
first.style.setProperty("background-color", "green");
check("rule.style changes the rule", first.cssText === "p { color: rgb(255, 0, 0); background-color: rgb(0, 128, 0); }");
first.style.color = "";
check("removing through rule.style", first.style.color === "" && first.style.backgroundColor === "rgb(0, 128, 0)");
first.selectorText = "p.b, em";
check("selectorText", first.selectorText === "p.b, em");
first.selectorText = "!!";
check("an invalid selectorText is ignored", first.selectorText === "p.b, em");
rules[1].insertRule(".inner { top: 0 }", 1);
check("CSSGroupingRule.insertRule", rules[1].cssRules.length === 2 && rules[1].cssRules[1].selectorText === ".inner");
rules[1].deleteRule(0);
check("CSSGroupingRule.deleteRule", rules[1].cssRules.length === 1);
rules[2].appendRule("50% { opacity: 0.5 }");
check("appendRule", rules[2].length === 3 && rules[2][2].keyText === "50%");
rules[2].deleteRule("50%");
check("CSSKeyframesRule.deleteRule", rules[2].length === 2);
sheet.media.mediaText = "screen";
check("MediaList", sheet.media.mediaText === "screen" && sheet.media.length === 1 && sheet.media[0] === "screen");
sheet.media.appendMedium("print");
check("appendMedium", sheet.media.length === 2 && sheet.media.item(1) === "print");
sheet.media.deleteMedium("screen");
check("deleteMedium", sheet.media.mediaText === "print");
sheet.disabled = true;
check("disabled", sheet.disabled === true);
sheet.disabled = false;

style.textContent = "b { color: black }";
check("new text, a new sheet", style.sheet !== sheet && style.sheet.cssRules.length === 1);
style.remove();
check("a removed style has no sheet", style.sheet === null && document.styleSheets.length === 0);

var made = new CSSStyleSheet();
check("new CSSStyleSheet", made.cssRules.length === 0 && made.ownerNode === null && made instanceof StyleSheet);
made.replaceSync("a { color: red } b { color: blue }");
check("replaceSync", made.cssRules.length === 2 && made.cssRules[1].selectorText === "b");
threw = "";
try { made.insertRule("@import url(x.css);", 0); } catch (error) { threw = error.name; }
check("no @import in a constructed sheet", threw === "SyntaxError");
document.adoptedStyleSheets = [made];
check("adoptedStyleSheets", document.adoptedStyleSheets.length === 1 && document.adoptedStyleSheets[0] === made);
threw = "";
try { document.adoptedStyleSheets = [document.createElement("style")]; } catch (error) { threw = error.name; }
check("only sheets can be adopted", threw !== "");
var replaced = null;
made.replace("i { color: green }").then(function (result) { replaced = result; });
var media = new CSSStyleSheet({ media: "print", disabled: true });
check("the constructor's options", media.media.mediaText === "print" && media.disabled);

// What CSS-in-JS libraries do: a style element of their own, rules
// appended one at a time.
var emotion = document.createElement("style");
emotion.setAttribute("data-emotion", "css");
document.head.appendChild(emotion);
for (var index = 0; index < 50; index++)
  emotion.sheet.insertRule(".css-" + index + " { margin: " + index + "px }", emotion.sheet.cssRules.length);
check("fifty appended rules", emotion.sheet.cssRules.length === 50 && emotion.sheet.cssRules[49].style.margin === "49px");

function after() {
  check("replace() settles with the sheet", replaced === made && made.cssRules.length === 1);
}
