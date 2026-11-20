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
  Random documents (always the same: a fixed seed) made of tags, text,
  references and random bytes, parsed as UTF-8 bytes all at once and one
  byte at a time: the trees must be the same, nothing may raise, the
  serializer must cope, and every node must be freed afterwards.
}
unit WebTest.Fuzz;

{$mode objfpc}
{$H+}

interface

procedure RunFuzzTests;

implementation

uses
  SysUtils,
  TestChecks,
  Web.Encoding.Labels,
  Web.Encoding.Sniffing,
  Web.Dom,
  Web.Html.Parser,
  Web.Html.Serializer,
  Web.Html.TreeDump;

const
  Pieces: array[0..63] of string = (
    '<html>', '<head>', '<body>', '<p>', '</p>', '<b>', '</b>', '<i>', '</i>', '<a href=x>', '</a>', '<table>',
    '</table>', '<tr>', '</tr>', '<td>', '</td>', '<th>', '<tbody>', '<caption>', '<col>', '<colgroup>',
    '<select>', '<option>', '</select>', '<template>', '</template>', '<svg>', '</svg>', '<math>', '<mi>',
    '<foreignObject>', '<desc>', '<script>', '</script>', '<style>', '<textarea>', '<title>', '<!--', '-->',
    '<!DOCTYPE html>', 'text', ' ', #10, '&amp;', '&#x41;', '&notin', '<frameset>', '<frame>', '<noscript>',
    '<plaintext>', '<![CDATA[', ']]>', '<li>', '<ul>', '<div>', '</div>', '<nobr>', '<button>', '<form>',
    '</form>', '<input type=hidden>', #13#10, '<!--<script>');
  Iterations = 3000;

function ParseBytes(const Bytes: string; OneByteAtATime: Boolean): string;
var
  Document: TDocument;
  Parser: THtmlParser;
  Index: Integer;
begin
  Document := TDocument.CreateDocument(True);
  try
    Parser := THtmlParser.Create(Document);
    try
      Parser.SetEncoding(TextEncodingUtf8, ConfidenceCertain);
      if OneByteAtATime then
        for Index := 1 to Length(Bytes) do
          Parser.WriteBytes(PByte(@Bytes[Index]), 1)
      else
        Parser.WriteByteString(Bytes);
      Parser.Finish;
    finally
      Parser.Free;
    end;
    Result := DumpTree(Document);
    SerializeChildren(Document);
  finally
    Document.Release;
  end;
end;

procedure RunFuzzTests;
var
  Iteration, Count, Index, Mismatches, Failures: Integer;
  Bytes, FirstFailure: string;
  Baseline: Int64;
begin
  CollectGarbage;
  Baseline := LiveNodeCount;
  RandSeed := 20261119;
  Mismatches := 0;
  Failures := 0;
  FirstFailure := '';
  for Iteration := 1 to Iterations do
  begin
    Bytes := '';
    Count := Random(40);
    for Index := 1 to Count do
      if Random(10) = 0 then
        Bytes := Bytes + Chr(Random(256))
      else
        Bytes := Bytes + Pieces[Random(Length(Pieces))];
    try
      if ParseBytes(Bytes, False) <> ParseBytes(Bytes, True) then
      begin
        Inc(Mismatches);
        if FirstFailure = '' then
          FirstFailure := Bytes;
      end;
    except
      on Error: Exception do
      begin
        Inc(Failures);
        if FirstFailure = '' then
          FirstFailure := Error.Message + ': ' + Bytes;
      end;
    end;
  end;
  CollectGarbage;
  Check(Failures = 0, Format('%d random documents parse without exceptions %s', [Iterations, FirstFailure]));
  Check(Mismatches = 0, Format('and give the same tree whole and one byte at a time %s', [FirstFailure]));
  Check(LiveNodeCount = Baseline, 'and free every node');
end;

end.
