{
  FreePascalOS
  Copyright (C) 2026 Brandon Scott

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <https://www.gnu.org/licenses/>.
}

{
  The HTML fragment serialization algorithm: escaping in text and in
  attributes, void elements, raw text elements, template contents,
  foreign attributes, comments and doctypes; and round trips (parsing
  what was serialized gives the same serialization).
}
unit WebTest.Serialization;

{$mode objfpc}
{$H+}

interface

procedure RunSerializationTests;

implementation

uses
  SysUtils,
  TestChecks,
  Web.Dom,
  Web.Html.Parser,
  Web.Html.Serializer;

{ The body's serialization after parsing Markup (in no-quirks mode). }
function BodyAfterParsing(const Markup: string): string;
var
  Document: TDocument;
begin
  Document := ParseHtmlText('<!DOCTYPE html><body>' + Markup);
  try
    Result := SerializeChildren(Document.Body);
  finally
    Document.Release;
  end;
end;

procedure CheckSerialization(const Markup, Expected, Name: string);
var
  Actual, Again: string;
begin
  Actual := BodyAfterParsing(Markup);
  Check(Actual = Expected, Name + ' (' + Actual + ')');
  Again := BodyAfterParsing(Actual);
  Check(Again = Actual, Name + ': round trip (' + Again + ')');
end;

procedure TestSerialization;
var
  Document: TDocument;
begin
  CheckSerialization('<p class="a&quot;b">x&amp;y&lt;z&gt;&nbsp;</p>', '<p class="a&quot;b">x&amp;y&lt;z&gt;&nbsp;</p>',
    'escaping text and attributes');
  CheckSerialization('<p title="<b>&amp;">', '<p title="&lt;b&gt;&amp;"></p>', 'attribute values escape < and >');
  CheckSerialization('<br><img src=x><input disabled><hr/>', '<br><img src="x"><input disabled=""><hr>',
    'void elements');
  CheckSerialization('<script>if (a<b && c>d) x="&amp;"</script>', '<script>if (a<b && c>d) x="&amp;"</script>',
    'script text is not escaped');
  CheckSerialization('<style>p>q{}</style><xmp><b></xmp>', '<style>p>q{}</style><xmp><b></xmp>',
    'style and xmp text is not escaped');
  CheckSerialization('<textarea><b>&amp;</textarea>', '<textarea>&lt;b&gt;&amp;</textarea>', 'textarea text is escaped');
  CheckSerialization('<template><tr><td>x</td></tr></template>', '<template><tr><td>x</td></tr></template>',
    'template contents');
  CheckSerialization('<svg viewBox="0 0 1 1" xlink:href=a xml:lang=b><path d=M0/></svg>',
    '<svg viewBox="0 0 1 1" xlink:href="a" xml:lang="b"><path d="M0/"></path></svg>', 'foreign elements');
  CheckSerialization('<math><mi>x</mi></math>', '<math><mi>x</mi></math>', 'MathML');
  CheckSerialization('<!--a--b--><p>c</p>', '<!--a--b--><p>c</p>', 'comments');
  CheckSerialization('<table><tr><td>1<td>2</table>', '<table><tbody><tr><td>1</td><td>2</td></tr></tbody></table>',
    'tables with their implied elements');
  CheckSerialization('<ul><li>a<li>b</ul>', '<ul><li>a</li><li>b</li></ul>', 'implied end tags');
  CheckSerialization('<p>caf'#$C3#$A9' &#x1F600;</p>', '<p>caf'#$C3#$A9' '#$F0#$9F#$98#$80'</p>',
    'non-ASCII text stays as it is');
  CheckSerialization('<noscript><b>x</b></noscript>', '<noscript><b>x</b></noscript>',
    'noscript with scripting off');
  Document := ParseHtmlText('<!DOCTYPE html><html lang=en><head><title>t</title></head><body>b</body></html>');
  try
    Check(SerializeChildren(Document) = '<!DOCTYPE html><html lang="en"><head><title>t</title></head><body>b</body>' +
      '</html>', 'a whole document');
    Check(SerializeNode(Document.Body) = '<body>b</body>', 'serializing an element itself');
  finally
    Document.Release;
  end;
end;

procedure TestDeepTree;
var
  Document: TDocument;
  Markup, Serialized: string;
  Index: Integer;
const
  Depth = 20000;
begin
  { A deep tree: the serializer, cloning and freeing walk it without
    recursion. }
  Markup := '';
  SetLength(Markup, Depth * 6);
  for Index := 0 to Depth - 1 do
    Move(PChar('<span>')^, Markup[Index * 6 + 1], 6);
  Document := ParseHtmlText(Markup + 'x');
  try
    Serialized := SerializeChildren(Document.Body);
    Check(Length(Serialized) = Depth * Length('<span></span>') + 1, 'a 20000 deep tree serializes');
    Check(Document.Body.CloneNode(True).IsEqualNode(Document.Body), 'and clones');
    Document.CollectGarbage;
  finally
    Document.Release;
  end;
end;

procedure RunSerializationTests;
begin
  TestSerialization;
  TestDeepTree;
end;

end.
