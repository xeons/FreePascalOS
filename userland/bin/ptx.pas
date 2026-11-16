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
  ptx - produce a permuted index of file contents

  ptx [-fr] [-i FILE] [-o FILE] [-w WIDTH] [-G] [FILE]...

  For every word of the input, prints the line it appears in, rotated so
  the word lines up in a middle column: the text before it on the left,
  the word and the rest on the right, sorted by the keyword. -i names a
  file of words to ignore, -o a file of the only words to index, -f
  ignores case when sorting, -r takes the first word of each line as a
  reference shown at the start. The output is the plain text format.
}
program ptx;

{$mode objfpc}
{$H+}

uses
  Classes,
  SysUtils,
  Sys.Format,
  Sys.Streams,
  Sys.Text,
  Util.Input,
  Util.Messages,
  Util.Options,
  Util.Sorting;

const
  Usage: PChar = 'Usage: ptx [OPTION]... [INPUT]...'#10 +
    'Output a permuted index, including context, of the words in the input files.'#10#10 +
    '  -f, --ignore-case          fold lower case to upper case for sorting'#10 +
    '  -i, --ignore-file=FILE     read ignore word list from FILE'#10 +
    '  -o, --only-file=FILE       read only word list from this FILE'#10 +
    '  -r, --references           first field of each line is a reference'#10 +
    '  -w, --width=NUMBER         output width in columns, reference excluded'#10 +
    '  -G, --traditional          accepted for compatibility'#10;

  OptionIgnoreCase = 1;
  OptionIgnoreFile = 2;
  OptionOnlyFile = 3;
  OptionReferences = 4;
  OptionWidth = 5;
  OptionTraditional = 6;

type
  TStringArray = array of string;

  { One keyword of the input, with the line it is in. }
  TIndexEntry = class
  public
    { The line, without its reference with -r. }
    Line: string;
    Reference: string;
    { Where the keyword starts in Line (from 1). }
    WordStart: Integer;
    { What entries are sorted by: the line from the keyword on. }
    SortKey: string;
    constructor Create(const ALine, AReference: string; AWordStart: Integer);
  end;

var
  IgnoreCase: Boolean;
  UseReferences: Boolean;
  Width: Int64;
  IgnoreWords: TStringArray;
  OnlyWords: TStringArray;
  HaveOnlyList: Boolean;

constructor TIndexEntry.Create(const ALine, AReference: string; AWordStart: Integer);
begin
  inherited Create;
  Line := ALine;
  Reference := AReference;
  WordStart := AWordStart;
  SortKey := Copy(Line, WordStart, MaxInt);
  if IgnoreCase then
    SortKey := UpperCase(SortKey);
end;

function WordInList(const List: TStringArray; const Word: string): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(List) do
    if List[Index] = Word then
      Exit(True);
  Result := False;
end;

function CompareEntries(First, Second: Pointer; Context: Pointer): Integer;
begin
  Result := CompareStr(TIndexEntry(First).SortKey, TIndexEntry(Second).SortKey);
end;

{ The end of Text, right aligned in Field columns: the part nearest the
  keyword is kept if it does not fit. }
function RightAligned(const Text: string; Field: Int64): string;
begin
  if Length(Text) > Field then
    Result := Copy(Text, Length(Text) - Field + 1, Field)
  else
    Result := StringOfChar(' ', Field - Length(Text)) + Text;
end;

procedure WriteEntry(Entry: TIndexEntry);
var
  HalfWidth: Int64;
  Left: Integer;
  Output: string;
begin
  HalfWidth := Width div 2;
  Output := '';
  if UseReferences then
    Output := Entry.Reference + ' ';
  { Text before the keyword, without trailing blanks. }
  Left := Entry.WordStart - 1;
  while (Left > 0) and IsSpace(Entry.Line[Left]) do
    Dec(Left);
  Output := Output + RightAligned(Copy(Entry.Line, 1, Left), HalfWidth - 3) + '   ' +
    Copy(Entry.Line, Entry.WordStart, Width - HalfWidth);
  WriteLine(StandardOutput, PChar(Output));
end;

{ Appends every line of Stream to Lines. }
procedure ReadLinesInto(Stream: PInputStream; var Lines: TStringArray);
var
  List: TLineList;
  Index: Integer;
  First: Integer;
begin
  BeginLineList(List);
  ReadAllLines(Stream, List);
  First := Length(Lines);
  SetLength(Lines, First + List.Count);
  for Index := 0 to List.Count - 1 do
    Lines[First + Index] := List.Items[Index];
  FreeLineList(List);
end;

procedure LoadWordList(Path: PChar; var List: TStringArray);
var
  Stream: PInputStream;
begin
  Stream := OpenInput(Path);
  if Stream = nil then
    Halt(1);
  ReadLinesInto(Stream, List);
  CloseInput(Stream);
end;

{ Adds an entry for every keyword of Line that is to be indexed. }
procedure AddEntries(const FullLine: string; Entries: TFPList);
var
  Line: string;
  Reference: string;
  Position: Integer;
  Start: Integer;
  Keyword: string;
begin
  Line := FullLine;
  Reference := '';
  Position := 1;
  if UseReferences then
  begin
    while (Position <= Length(Line)) and not IsSpace(Line[Position]) do
      Inc(Position);
    Reference := Copy(Line, 1, Position - 1);
    while (Position <= Length(Line)) and IsSpace(Line[Position]) do
      Inc(Position);
    Line := Copy(Line, Position, MaxInt);
    Position := 1;
  end;
  while Position <= Length(Line) do
  begin
    while (Position <= Length(Line)) and not IsAlphanumeric(Line[Position]) do
      Inc(Position);
    if Position > Length(Line) then
      Break;
    Start := Position;
    while (Position <= Length(Line)) and IsAlphanumeric(Line[Position]) do
      Inc(Position);
    Keyword := Copy(Line, Start, Position - Start);
    if WordInList(IgnoreWords, Keyword) then
      Continue;
    if HaveOnlyList and not WordInList(OnlyWords, Keyword) then
      Continue;
    Entries.Add(TIndexEntry.Create(Line, Reference, Start));
  end;
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Index: Integer;
  Stream: PInputStream;
  Lines: TStringArray;
  Entries: TFPList;
  LineIndex: Integer;
  ExitStatus: LongInt;
begin
  Width := 72;
  BeginOptions(Parser, [
    OptionDefinition('f', 'ignore-case', False, OptionIgnoreCase),
    OptionDefinition('i', 'ignore-file', True, OptionIgnoreFile),
    OptionDefinition('o', 'only-file', True, OptionOnlyFile),
    OptionDefinition('r', 'references', False, OptionReferences),
    OptionDefinition('w', 'width', True, OptionWidth),
    OptionDefinition('G', 'traditional', False, OptionTraditional)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionIgnoreCase: IgnoreCase := True;
      OptionIgnoreFile: LoadWordList(Value, IgnoreWords);
      OptionOnlyFile:
        begin
          LoadWordList(Value, OnlyWords);
          HaveOnlyList := True;
        end;
      OptionReferences: UseReferences := True;
      OptionWidth:
        if not ParseInteger(Value, Width) or (Width < 10) then
          Fail(1, 'invalid width: ''%s''', [ArgumentText(Value)]);
    end;
  if Parser.OperandCount = 0 then
  begin
    Parser.Operands[0] := '-';
    Parser.OperandCount := 1;
  end;

  ExitStatus := 0;
  Lines := nil;
  for Index := 0 to Parser.OperandCount - 1 do
  begin
    Stream := OpenInput(Parser.Operands[Index]);
    if Stream = nil then
    begin
      ExitStatus := 1;
      Continue;
    end;
    ReadLinesInto(Stream, Lines);
    CloseInput(Stream);
  end;

  Entries := TFPList.Create;
  for LineIndex := 0 to High(Lines) do
    AddEntries(Lines[LineIndex], Entries);
  if Entries.Count > 0 then
    SortPointers(PPointer(Entries.List), Entries.Count, @CompareEntries, nil);
  for Index := 0 to Entries.Count - 1 do
    WriteEntry(TIndexEntry(Entries[Index]));
  Halt(ExitStatus);
end.
