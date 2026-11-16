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
  Sys.Streams,
  Sys.Text,
  Util.CommandLine,
  Util.Input,
  Util.Messages,
  Util.Numbers,
  Util.Sorting;

const
  Usage = 'Usage: ptx [OPTION]... [INPUT]...'#10 +
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

  { Orders entries by SortKey. }
  TEntryOrder = class
  public
    function Compare(First, Second: Pointer): Integer;
  end;

var
  IgnoreCase: Boolean;
  UseReferences: Boolean;
  Width: Int64;
  IgnoreWords: TStringList;
  { nil without -o. }
  OnlyWords: TStringList;

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

function TEntryOrder.Compare(First, Second: Pointer): Integer;
begin
  Result := CompareStr(TIndexEntry(First).SortKey, TIndexEntry(Second).SortKey);
end;

{ An exact (case sensitive) match. }
function WordInList(List: TStrings; const Word: string): Boolean;
var
  Item: string;
begin
  for Item in List do
    if Item = Word then
      Exit(True);
  Result := False;
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
  PrintStringLine(Output);
end;

procedure LoadWordList(const Path: string; List: TStrings);
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
    if (OnlyWords <> nil) and not WordInList(OnlyWords, Keyword) then
      Continue;
    Entries.Add(TIndexEntry.Create(Line, Reference, Start));
  end;
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Operand: string;
  Stream: PInputStream;
  Lines: TStringList;
  Line: string;
  Entries: TFPList;
  Order: TEntryOrder;
  Index: Integer;
  ExitStatus: LongInt;
begin
  Width := 72;
  IgnoreWords := TStringList.Create;
  OnlyWords := nil;
  CommandLine := TCommandLine.Create([
    CommandOption('f', 'ignore-case', False, OptionIgnoreCase),
    CommandOption('i', 'ignore-file', True, OptionIgnoreFile),
    CommandOption('o', 'only-file', True, OptionOnlyFile),
    CommandOption('r', 'references', False, OptionReferences),
    CommandOption('w', 'width', True, OptionWidth),
    CommandOption('G', 'traditional', False, OptionTraditional)], Usage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionIgnoreCase: IgnoreCase := True;
      OptionIgnoreFile: LoadWordList(Value, IgnoreWords);
      OptionOnlyFile:
        begin
          if OnlyWords = nil then
            OnlyWords := TStringList.Create;
          LoadWordList(Value, OnlyWords);
        end;
      OptionReferences: UseReferences := True;
      OptionWidth:
        if not ParseDecimal(Value, Width) or (Width < 10) then
          Fail(1, Format('invalid width: ''%s''', [Value]));
    end;
  if CommandLine.OperandCount = 0 then
    CommandLine.Operands := ['-'];

  ExitStatus := 0;
  Lines := TStringList.Create;
  for Operand in CommandLine.Operands do
  begin
    Stream := OpenInput(Operand);
    if Stream = nil then
    begin
      ExitStatus := 1;
      Continue;
    end;
    ReadLinesInto(Stream, Lines);
    CloseInput(Stream);
  end;

  Entries := TFPList.Create;
  for Line in Lines do
    AddEntries(Line, Entries);
  Order := TEntryOrder.Create;
  SortList(Entries, @Order.Compare);
  Order.Free;
  for Index := 0 to Entries.Count - 1 do
    WriteEntry(TIndexEntry(Entries[Index]));
  Halt(ExitStatus);
end.
