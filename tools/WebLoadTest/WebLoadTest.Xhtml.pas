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
  XHTML (application/xhtml+xml) through the XML parser: a style element's
  CDATA section is its sheet's text, the text is UTF-8 without a
  declaration, the document is a Document (not an XMLDocument, not an
  HTML document), scripts run in order as the tree grows (an inline
  script sees only what came before it, an external one blocks the
  parser, defer runs after parsing), and a document that is not
  well-formed becomes the parser error document.
}
unit WebLoadTest.Xhtml;

{$mode objfpc}
{$H+}

interface

procedure RunXhtmlTests;

implementation

uses
  SysUtils,
  TestChecks,
  Web.Dom,
  Web.Loading.Contexts,
  Web.Loading.ResourceSink,
  Web.Navigation.Navigables,
  Web.Script.PageScripting,
  WebLoadTest.Server;

type
  TXhtmlConditions = class
  public
    Navigable: TNavigable;
    Console: string;
    function Finished: Boolean;
    function ShowsParserError: Boolean;
    procedure ConsoleMessage(const Level, Text: string);
  end;

function TXhtmlConditions.Finished: Boolean;
var
  Output: TElement;
begin
  Result := False;
  if Navigable.ActiveDocument = nil then
    Exit;
  Output := Navigable.ActiveDocument.GetElementById('out');
  Result := (Output <> nil) and (Pos('load', Output.TextContent) > 0);
end;

function TXhtmlConditions.ShowsParserError: Boolean;
begin
  Result := (Navigable.ActiveDocument <> nil) and (Navigable.ActiveDocument.DocumentElement <> nil) and
    (Navigable.ActiveDocument.DocumentElement.LocalName = 'parsererror');
end;

procedure TXhtmlConditions.ConsoleMessage(const Level, Text: string);
begin
  Console := Console + Level + ': ' + Text + LineEnding;
end;

const
  ScriptedPage: PChar =
    '<?xml version="1.0"?>' + LineEnding +
    '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>t</title>' +
    '<style id="sheet" type="text/css"><![CDATA[ p#styled { margin-left: 7px } ]]></style>' +
    '<script>var order = ["inline1:" + document.getElementsByTagName("p").length];</script>' +
    '<script src="ext.js"></script><script defer="defer" src="def.js"></script></head>' +
    '<body><p id="styled">caf' + #$C3#$A9 + '</p><p id="out">x</p>' +
    '<script><![CDATA[ order.push("inline2:" + document.getElementsByTagName("p").length); ]]></script>' +
    '<script>document.addEventListener("DOMContentLoaded", function () { order.push("dcl"); });' +
    'window.onload = function () { order.push("load"); document.getElementById("out").textContent =' +
    ' order.join(","); };</script></body></html>';

procedure CheckXhtmlDocument;
var
  Environment: TTestEnvironment;
  Conditions: TXhtmlConditions;
  Sink: TNullResourceSink;
  Navigable: TNavigable;
  Executor: TPageScriptExecutor;
  Document: TDocument;
  Styled, Output: TElement;
  Text: string;
begin
  Environment := TTestEnvironment.Create;
  Conditions := TXhtmlConditions.Create;
  Sink := TNullResourceSink.Create;
  Navigable := TNavigable.Create(Environment.Fetcher, Sink, DefaultLoadingSettings);
  Executor := TPageScriptExecutor.Create(Navigable);
  Executor.OnConsoleMessage := @Conditions.ConsoleMessage;
  Navigable.Executor := Executor;
  Conditions.Navigable := Navigable;
  try
    Environment.Site.AddRoute('x.test/page.xhtml', 200, 'Content-Type: application/xhtml+xml', ScriptedPage);
    Environment.Site.AddRoute('x.test/ext.js', 200, 'Content-Type: text/javascript',
      'order.push("ext:" + document.getElementsByTagName("script").length);');
    Environment.Site.AddRoute('x.test/def.js', 200, 'Content-Type: text/javascript', 'order.push("defer");');
    Environment.Site.AddRoute('x.test/broken.xhtml', 200, 'Content-Type: application/xhtml+xml',
      '<html xmlns="http://www.w3.org/1999/xhtml"><body><p>unclosed</body></html>');
    Navigable.NavigateTo('https://x.test/page.xhtml');
    Check(Environment.RunUntil(@Conditions.Finished), 'xhtml: the page''s scripts ran (' +
      Trim(Conditions.Console) + ')');
    Document := Navigable.ActiveDocument;
    Output := Document.GetElementById('out');
    Text := '';
    if Output <> nil then
      Text := Output.TextContent;
    Check(Text = 'inline1:0,ext:2,inline2:2,defer,dcl,load',
      'xhtml: scripts run as the tree grows, the external one blocks, defer after parsing (' + Text + ')');
    Check(not Document.IsHtmlDocument and not Document.IsXmlDocumentObject and
      (Document.ContentType = 'application/xhtml+xml'), 'xhtml: a Document of type xml');
    Styled := Document.GetElementById('styled');
    Check((Styled <> nil) and (Styled.TextContent = 'caf' + #$C3#$A9), 'xhtml: UTF-8 text by default');
    Check(Pos('margin-left: 7px', DescendantTextContent(Document.GetElementById('sheet'))) > 0,
      'xhtml: the CDATA section is the style sheet''s text');
    Navigable.NavigateTo('https://x.test/broken.xhtml');
    Check(Environment.RunUntil(@Conditions.ShowsParserError),
      'xhtml: a document that is not well-formed shows the parser error');
  finally
    Navigable.Free;
    Executor.Free;
    Sink.Free;
    Conditions.Free;
    Environment.Free;
  end;
end;

procedure RunXhtmlTests;
begin
  CheckXhtmlDocument;
end;

end.
