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
  The parser on a large generated document: nodes per second, the heap
  bytes per node (all of it: node objects, attribute arrays, text), the
  size of each node class, and that freeing the document gives every
  node back. The figures are printed as "perf" lines.
}
unit WebTest.Performance;

{$mode objfpc}
{$H+}

interface

procedure RunPerformanceTests;

implementation

uses
  SysUtils,
  DateUtils,
  TestChecks,
  Web.TextBuffers,
  Web.Dom,
  Web.Html.Parser,
  Web.Html.Serializer;

const
  BlockCount = 20000;

function GeneratedDocument: string;
var
  Output: TTextBuffer;
  Index: Integer;
begin
  Output := TTextBuffer.Create;
  try
    Output.AppendString('<!DOCTYPE html><html><head><title>Generated</title></head><body>');
    for Index := 1 to BlockCount do
    begin
      Output.AppendString('<div class="item" id="item');
      Output.AppendString(IntToStr(Index));
      Output.AppendString('"><h2>Item ');
      Output.AppendString(IntToStr(Index));
      Output.AppendString('</h2><p>Some <b>bold</b> text, a <a href="/page/');
      Output.AppendString(IntToStr(Index));
      Output.AppendString('">link</a> &amp; more text here.</p><ul><li>one<li>two<li>three</ul></div>'#10);
    end;
    Output.AppendString('</body></html>');
    Result := Output.TakeText;
  finally
    Output.Free;
  end;
end;

function HeapInUse: Int64;
begin
  Result := GetFPCHeapStatus.CurrHeapUsed;
end;

procedure RunPerformanceTests;
var
  Markup: string;
  Document: TDocument;
  Started: TDateTime;
  Milliseconds: Int64;
  NodesBefore, Nodes, HeapBefore, HeapAfter: Int64;
  Serialized: string;
begin
  Markup := GeneratedDocument;
  CollectGarbage;
  NodesBefore := LiveNodeCount;
  HeapBefore := HeapInUse;
  Started := Now;
  Document := ParseHtmlText(Markup);
  Milliseconds := MilliSecondsBetween(Now, Started);
  if Milliseconds = 0 then
    Milliseconds := 1;
  HeapAfter := HeapInUse;
  Nodes := LiveNodeCount - NodesBefore;
  WriteLn(Format('perf parse: %d bytes of HTML, %d nodes in %d ms: %d nodes/s, %.1f MB/s', [Length(Markup), Nodes,
    Milliseconds, Nodes * 1000 div Milliseconds, Length(Markup) / 1048576 / (Milliseconds / 1000)]));
  WriteLn(Format('perf memory: %d bytes of heap for the document, %.1f bytes per node (text and attributes included)',
    [HeapAfter - HeapBefore, (HeapAfter - HeapBefore) / Nodes]));
  WriteLn(Format('perf node sizes: Element %d, Text %d, Comment %d, Document %d bytes (instance, without the heap''s' +
    ' header); an attribute record is %d bytes', [TElement.InstanceSize, TText.InstanceSize, TComment.InstanceSize,
    TDocument.InstanceSize, SizeOf(TAttributeRecord)]));
  Check(Nodes > BlockCount * 15, 'the generated document has the nodes expected');
  Check(Document.GetElementById('item' + IntToStr(BlockCount)) <> nil, 'ids of the generated document');
  Started := Now;
  Serialized := SerializeChildren(Document);
  Milliseconds := MilliSecondsBetween(Now, Started);
  WriteLn(Format('perf serialize: %d bytes in %d ms', [Length(Serialized), Milliseconds]));
  Serialized := '';
  Document.Release;
  CollectGarbage;
  Check(LiveNodeCount = NodesBefore, 'freeing the document frees every node');
  Check(HeapInUse - HeapBefore < 64 * 1024, Format('and the heap it used (%d bytes left)', [HeapInUse - HeapBefore]));
end;

end.
