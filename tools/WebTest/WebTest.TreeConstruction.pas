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
  Runs tree construction cases in the html5lib format: #data, #errors
  (not compared: the counts are only reported), optional
  #document-fragment (the context: "td", "svg path", "math mi"),
  optional #script-on / #script-off, and #document. Two extensions:
  #mode (quirks, limited-quirks or no-quirks: the document mode to
  check) and #roundtrip (serializing the tree and parsing that again
  must give the same tree).

  Each case is parsed whole and again fed one byte at a time, which must
  give the same tree (the streaming tokenizer).
}
unit WebTest.TreeConstruction;

{$mode objfpc}
{$H+}

interface

procedure RunTreeConstructionTests(const Directory: string);

implementation

uses
  SysUtils,
  Classes,
  TestChecks,
  Web.Atoms,
  Web.Namespaces,
  Web.Dom,
  Web.Html.Parser,
  Web.Html.Serializer,
  Web.Html.TreeDump;

type
  TTreeCase = record
    Data: string;
    Expected: string;
    Context: string;
    ScriptingEnabled: Boolean;
    Mode: string;
    RoundTrip: Boolean;
    Origin: string;
  end;

function ParseDocumentWhole(const Text: string; Scripting: Boolean; out Mode: TDocumentMode): string;
var
  Document: TDocument;
begin
  Document := ParseHtmlText(Text, Scripting);
  try
    Mode := Document.Mode;
    Result := DumpTree(Document);
  finally
    Document.Release;
  end;
end;

function ParseDocumentByteByByte(const Text: string; Scripting: Boolean): string;
var
  Document: TDocument;
  Parser: THtmlParser;
  Index: Integer;
begin
  Document := TDocument.CreateDocument(True);
  Document.ScriptingEnabled := Scripting;
  try
    Parser := THtmlParser.Create(Document);
    try
      for Index := 1 to Length(Text) do
        Parser.WriteText(Text[Index]);
      Parser.Finish;
    finally
      Parser.Free;
    end;
    Result := DumpTree(Document);
  finally
    Document.Release;
  end;
end;

function MakeContext(Document: TDocument; const Context: string): TElement;
var
  Space: Integer;
begin
  Space := Pos(' ', Context);
  if Space = 0 then
    Result := Document.CreateElement(Context)
  else if Copy(Context, 1, Space - 1) = 'svg' then
    Result := Document.CreateElementNS(NameOfAtom(AtomSvgNamespace), Copy(Context, Space + 1, MaxInt))
  else
    Result := Document.CreateElementNS(NameOfAtom(AtomMathMlNamespace), Copy(Context, Space + 1, MaxInt));
end;

function ParseFragmentCase(const Text, Context: string; Scripting: Boolean): string;
var
  Document: TDocument;
  Fragment: TDocumentFragment;
begin
  Document := TDocument.CreateDocument(True);
  Document.ScriptingEnabled := Scripting;
  try
    Fragment := ParseHtmlFragment(MakeContext(Document, Context), Text);
    Result := DumpTree(Fragment);
  finally
    Document.Release;
  end;
end;

function ModeName(Mode: TDocumentMode): string;
begin
  case Mode of
    DocumentModeQuirks: Result := 'quirks';
    DocumentModeLimitedQuirks: Result := 'limited-quirks';
  else
    Result := 'no-quirks';
  end;
end;

function SerializeRoundTrip(const Text: string; Scripting: Boolean): string;
var
  Document: TDocument;
  Serialized: string;
  Mode: TDocumentMode;
begin
  Document := ParseHtmlText(Text, Scripting);
  try
    Serialized := SerializeChildren(Document);
  finally
    Document.Release;
  end;
  Result := ParseDocumentWhole(Serialized, Scripting, Mode);
end;

procedure ReportMismatch(const TestCase: TTreeCase; const What, Actual: string);
begin
  WriteLn('FAIL ', TestCase.Origin, ' (', What, ')');
  WriteLn('#data');
  WriteLn(TestCase.Data);
  WriteLn('#expected');
  Write(TestCase.Expected);
  WriteLn('#actual');
  Write(Actual);
  Inc(FailedChecks);
end;

procedure RunCase(const TestCase: TTreeCase);
var
  Actual, Streamed: string;
  Mode: TDocumentMode;
  Good: Boolean;
begin
  try
    if TestCase.Context <> '' then
      Actual := ParseFragmentCase(TestCase.Data, TestCase.Context, TestCase.ScriptingEnabled)
    else
      Actual := ParseDocumentWhole(TestCase.Data, TestCase.ScriptingEnabled, Mode);
  except
    on Error: Exception do
    begin
      ReportMismatch(TestCase, 'exception ' + Error.ClassName + ': ' + Error.Message, '');
      Exit;
    end;
  end;
  if Actual <> TestCase.Expected then
  begin
    ReportMismatch(TestCase, 'tree', Actual);
    Exit;
  end;
  Good := True;
  if TestCase.Context = '' then
  begin
    Streamed := ParseDocumentByteByByte(TestCase.Data, TestCase.ScriptingEnabled);
    if Streamed <> TestCase.Expected then
    begin
      ReportMismatch(TestCase, 'byte by byte', Streamed);
      Good := False;
    end;
    if (TestCase.Mode <> '') and (ModeName(Mode) <> TestCase.Mode) then
    begin
      ReportMismatch(TestCase, 'mode ' + ModeName(Mode) + ' instead of ' + TestCase.Mode, Actual);
      Good := False;
    end;
    if TestCase.RoundTrip then
    begin
      Streamed := SerializeRoundTrip(TestCase.Data, TestCase.ScriptingEnabled);
      if Streamed <> TestCase.Expected then
      begin
        ReportMismatch(TestCase, 'serialize and parse again', Streamed);
        Good := False;
      end;
    end;
  end;
  if Good then
    Inc(PassedChecks);
end;

{ Splits a .dat file into its cases. }
procedure RunFile(const FileName: string; var CaseCount: Integer);
var
  Lines: TStringList;
  Index, Start: Integer;
  Section, Line: string;
  TestCase: TTreeCase;
  InCase: Boolean;

  procedure FinishCase;
  begin
    if not InCase then
      Exit;
    { The document section ends with an empty line before the next case. }
    if (Length(TestCase.Expected) >= 2) and (Copy(TestCase.Expected, Length(TestCase.Expected) - 1, 2) = #10#10) then
      SetLength(TestCase.Expected, Length(TestCase.Expected) - 1);
    if (TestCase.Data <> '') and (TestCase.Data[Length(TestCase.Data)] = #10) then
      SetLength(TestCase.Data, Length(TestCase.Data) - 1);
    Inc(CaseCount);
    RunCase(TestCase);
    InCase := False;
  end;

begin
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(FileName);
    InCase := False;
    Section := '';
    Start := 0;
    for Index := 0 to Lines.Count - 1 do
    begin
      Line := Lines[Index];
      if Line = '#data' then
      begin
        FinishCase;
        TestCase := Default(TTreeCase);
        TestCase.Origin := ExtractFileName(FileName) + ':' + IntToStr(Index + 1);
        InCase := True;
        Section := 'data';
        Start := Index;
        Continue;
      end;
      if not InCase then
        Continue;
      if (Line <> '') and (Line[1] = '#') and (Section <> 'document-text') then
      begin
        if (Line = '#errors') or (Line = '#new-errors') then
          Section := 'errors'
        else if Line = '#document-fragment' then
          Section := 'fragment'
        else if Line = '#script-on' then
          TestCase.ScriptingEnabled := True
        else if Line = '#script-off' then
          TestCase.ScriptingEnabled := False
        else if Line = '#roundtrip' then
          TestCase.RoundTrip := True
        else if Copy(Line, 1, 6) = '#mode ' then
          TestCase.Mode := Copy(Line, 7, MaxInt)
        else if Line = '#document' then
          Section := 'document'
        else
          Section := 'unknown';
        Continue;
      end;
      if Section = 'data' then
        TestCase.Data := TestCase.Data + Line + #10
      else if Section = 'fragment' then
        TestCase.Context := Line
      else if Section = 'document' then
        TestCase.Expected := TestCase.Expected + Line + #10;
    end;
    FinishCase;
  finally
    Lines.Free;
  end;
  if Start < 0 then
    Exit;
end;

procedure RunTreeConstructionTests(const Directory: string);
var
  Search: TSearchRec;
  Files: TStringList;
  Index, CaseCount, FailedBefore: Integer;
begin
  Files := TStringList.Create;
  try
    if FindFirst(IncludeTrailingPathDelimiter(Directory) + '*.dat', faAnyFile, Search) = 0 then
    begin
      repeat
        Files.Add(IncludeTrailingPathDelimiter(Directory) + Search.Name);
      until FindNext(Search) <> 0;
      FindClose(Search);
    end;
    Files.Sort;
    CaseCount := 0;
    FailedBefore := FailedChecks;
    for Index := 0 to Files.Count - 1 do
      RunFile(Files[Index], CaseCount);
    WriteLn('ok   tree construction: ', CaseCount, ' cases in ', Files.Count, ' files, ',
      FailedChecks - FailedBefore, ' failed');
    Check(Files.Count > 0, 'tree construction files found');
  finally
    Files.Free;
  end;
end;

end.
