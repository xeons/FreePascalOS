// HTML-like comments (Annex B.1.1): <!-- anywhere a token may start, --> at the start of a line.
	<!-- after a tab, as an old inline script wraps its code
var seen = [];
seen.push("first"); <!-- the rest of this line is a comment
  --> a closing marker after spaces is a comment too
/* a block comment */ --> and after a block comment on the same line
seen.push("second");
var a = 3, b = 1;
console.log(seen.join(), a < !--b, b);
var c = 5;
console.log(c-->4, c);
	//-->
console.log("end");
/* expected
first,second false 0
true 4
end
*/
