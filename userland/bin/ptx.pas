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
{$pointermath on}

uses
  Runtime.Text,
  Sys.Format,
  Sys.Memory,
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
  PEntry = ^TEntry;
  TEntry = record
    Line: PChar;
    Reference: PChar;
    WordStart: PtrUInt;
    WordLength: PtrUInt;
  end;

var
  IgnoreCase: Boolean;
  UseReferences: Boolean;
  Width: Int64;
  IgnoreWords: TLineList;
  OnlyWords: TLineList;
  HaveOnlyList: Boolean;

function WordInList(const List: TLineList; Word: PChar; Length: PtrUInt): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to List.Count - 1 do
    if (TextLength(List.Items[Index]) = Length) and TextStartsWith(Word, List.Items[Index]) then
      Exit(True);
  Result := False;
end;

function CompareEntries(First, Second: Pointer; Context: Pointer): Integer;
var
  Left: PEntry;
  Right: PEntry;
  Index: PtrUInt;
  A, B: Char;
begin
  Left := PEntry(First);
  Right := PEntry(Second);
  Index := 0;
  while True do
  begin
    A := Left^.Line[Left^.WordStart + Index];
    B := Right^.Line[Right^.WordStart + Index];
    if IgnoreCase then
    begin
      A := ToUpperCase(A);
      B := ToUpperCase(B);
    end;
    if (A <> B) or (A = #0) then
      Exit(Integer(Byte(A)) - Integer(Byte(B)));
    Inc(Index);
  end;
end;

procedure WriteRightAligned(Text: PChar; Length: PtrUInt; Field: Int64);
var
  Start: PtrUInt;
begin
  { Keep the part nearest the keyword if it does not fit. }
  Start := 0;
  if Int64(Length) > Field then
    Start := Length - PtrUInt(Field);
  while Field > Int64(Length - Start) do
  begin
    WriteCharacter(StandardOutput, ' ');
    Dec(Field);
  end;
  WriteBytes(StandardOutput, Text + Start, Length - Start);
end;

procedure WriteEntry(Entry: PEntry);
var
  HalfWidth: Int64;
  Left: PtrUInt;
  Right: PChar;
  RightLength: PtrUInt;
begin
  HalfWidth := Width div 2;
  if UseReferences and (Entry^.Reference <> nil) then
  begin
    WriteText(StandardOutput, Entry^.Reference);
    WriteCharacter(StandardOutput, ' ');
  end;
  { Text before the keyword, without trailing blanks. }
  Left := Entry^.WordStart;
  while (Left > 0) and IsSpace(Entry^.Line[Left - 1]) do
    Dec(Left);
  WriteRightAligned(Entry^.Line, Left, HalfWidth - 3);
  WriteText(StandardOutput, '   ');
  Right := Entry^.Line + Entry^.WordStart;
  RightLength := TextLength(Right);
  if Int64(RightLength) > Width - HalfWidth then
    RightLength := PtrUInt(Width - HalfWidth);
  WriteBytes(StandardOutput, Right, RightLength);
  WriteCharacter(StandardOutput, #10);
end;

procedure LoadWordList(Path: PChar; var List: TLineList);
var
  Stream: PInputStream;
begin
  Stream := OpenInput(Path);
  if Stream = nil then
    Halt(1);
  ReadAllLines(Stream, List);
  CloseInput(Stream);
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Index: Integer;
  Stream: PInputStream;
  Lines: TLineList;
  Entries: PPointer;
  EntryCount: Integer;
  EntryCapacity: Integer;
  Entry: PEntry;
  Line: PChar;
  Position: PtrUInt;
  Start: PtrUInt;
  Reference: PChar;
  LineIndex: Integer;
  ExitStatus: LongInt;
begin
  Width := 72;
  BeginLineList(IgnoreWords);
  BeginLineList(OnlyWords);
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
  BeginLineList(Lines);
  for Index := 0 to Parser.OperandCount - 1 do
  begin
    Stream := OpenInput(Parser.Operands[Index]);
    if Stream = nil then
    begin
      ExitStatus := 1;
      Continue;
    end;
    ReadAllLines(Stream, Lines);
    CloseInput(Stream);
  end;

  Entries := nil;
  EntryCount := 0;
  EntryCapacity := 0;
  for LineIndex := 0 to Lines.Count - 1 do
  begin
    Line := Lines.Items[LineIndex];
    Position := 0;
    Reference := nil;
    if UseReferences then
    begin
      while (Line[Position] <> #0) and not IsSpace(Line[Position]) do
        Inc(Position);
      Reference := PChar(AllocateMemory(Position + 1));
      CopyText(Reference, Line, Position + 1);
      while IsSpace(Line[Position]) do
        Inc(Position);
      Line := Line + Position;
      Position := 0;
    end;
    while Line[Position] <> #0 do
    begin
      while (Line[Position] <> #0) and not IsAlphanumeric(Line[Position]) do
        Inc(Position);
      if Line[Position] = #0 then
        Break;
      Start := Position;
      while IsAlphanumeric(Line[Position]) do
        Inc(Position);
      if WordInList(IgnoreWords, Line + Start, Position - Start) then
        Continue;
      if HaveOnlyList and not WordInList(OnlyWords, Line + Start, Position - Start) then
        Continue;
      if EntryCount = EntryCapacity then
      begin
        EntryCapacity := EntryCapacity * 2 + 64;
        Entries := PPointer(ReallocateMemory(Entries, QWord(EntryCapacity) * SizeOf(Pointer)));
      end;
      Entry := PEntry(AllocateMemory(SizeOf(TEntry)));
      Entry^.Line := Line;
      Entry^.Reference := Reference;
      Entry^.WordStart := Start;
      Entry^.WordLength := Position - Start;
      Entries[EntryCount] := Entry;
      Inc(EntryCount);
    end;
  end;
  SortPointers(Entries, EntryCount, @CompareEntries, nil);
  for Index := 0 to EntryCount - 1 do
    WriteEntry(PEntry(Entries[Index]));
  Halt(ExitStatus);
end.
