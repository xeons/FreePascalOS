// URL and URLSearchParams over libhttp's URL parser.
var url = new URL("https://user:pass@Example.COM:8080/a/./b/../c?x=1&y=2#frag");
check("parsing and the accessors", url.href === "https://user:pass@example.com:8080/a/c?x=1&y=2#frag" &&
  url.protocol === "https:" && url.username === "user" && url.password === "pass" && url.host === "example.com:8080" &&
  url.hostname === "example.com" && url.port === "8080" && url.pathname === "/a/c" && url.search === "?x=1&y=2" &&
  url.hash === "#frag" && url.origin === "https://example.com:8080");
check("toString and toJSON", String(url) === url.href && url.toJSON() === url.href && JSON.stringify({ u: url }) ===
  '{"u":"' + url.href + '"}');
check("relative to a base", new URL("../d?z", "https://example.com/a/b/c").href === "https://example.com/a/d?z");
var parseError = null;
try { new URL("not a url"); } catch (e) { parseError = e; }
check("an invalid URL is a TypeError", parseError instanceof TypeError);
check("URL.canParse and URL.parse", URL.canParse("https://x.test/") && !URL.canParse("nope") &&
  URL.parse("nope") === null && URL.parse("/p", "https://x.test").href === "https://x.test/p");
url.port = "443";
url.hash = "";
url.pathname = "/new path";
check("setters", url.href === "https://user:pass@example.com:443/new%20path?x=1&y=2" ||
  url.href === "https://user:pass@example.com/new%20path?x=1&y=2");
url.protocol = "http";
check("protocol setter", url.protocol === "http:");
check("webkitURL is URL", webkitURL === URL);

var params = url.searchParams;
check("searchParams", params.get("x") === "1" && params.get("missing") === null && params.has("y") &&
  params === url.searchParams && params.size === 2);
params.append("z", "a b");
check("changes to searchParams update the URL", url.search === "?x=1&y=2&z=a+b");
url.search = "?q=one&q=two";
check("changes to the URL update searchParams", params.getAll("q").join() === "one,two" && !params.has("x"));
params.delete("q", "one");
check("delete with a value", params.toString() === "q=two");
params.set("b", "2");
params.set("a", "1");
params.sort();
check("set and sort", params.toString() === "a=1&b=2&q=two");
var fromString = new URLSearchParams("?a=1&b=%20x&a=3");
check("from a string", fromString.getAll("a").join() === "1,3" && fromString.get("b") === " x");
var fromPairs = new URLSearchParams([["k", "v"], ["k", "w"]]);
check("from pairs", fromPairs.toString() === "k=v&k=w");
var fromRecord = new URLSearchParams({ one: "1", two: "2" });
check("from a record", fromRecord.toString() === "one=1&two=2");
var pairError = null;
try { new URLSearchParams([["only"]]); } catch (e) { pairError = e; }
check("a pair needs two items", pairError instanceof TypeError);
var entries = [];
for (var entry of fromRecord) entries.push(entry.join("="));
check("iteration", entries.join("&") === "one=1&two=2" && Array.from(fromRecord.keys()).join() === "one,two" &&
  Array.from(fromRecord.values()).join() === "1,2");
var seen = [];
fromRecord.forEach(function (value, key) { seen.push(key + value); });
check("forEach", seen.join() === "one1,two2");
check("encoding", new URLSearchParams({ "a&b": "c=d é" }).toString() === "a%26b=c%3Dd+%C3%A9");
var live = new URLSearchParams("a=1&b=2&c=3");
var walked = [];
for (var pair of live) {
  walked.push(pair[0]);
  if (pair[0] === "a") live.delete("a");
}
check("iteration reads the pairs live (a deleted pair moves the rest up)", walked.join() === "a,c");
var iterator = new URLSearchParams("x=1").entries();
check("a pair iterator is an iterator", typeof iterator.next === "function" &&
  iterator[Symbol.iterator]() === iterator && iterator.next().value.join() === "x,1" && iterator.next().done);
var lone = new URLSearchParams({ "\uD835x": "1", "xx": "2", "\uD83Dx": "3" });
check("record keys that are one USVString keep the later value in the first place",
  lone.toString() === "%EF%BF%BDx=3&xx=2");
var hostUrl = new URL("http://example.net:8080/path");
hostUrl.host = "example.com:invalid";
check("a host setter keeps the host when the port is bad", hostUrl.href === "http://example.com:8080/path");
hostUrl.host = "example.org:65536";
check("a host setter keeps the host when the port overflows", hostUrl.host === "example.org:8080");
