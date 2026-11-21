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
  Heap checking (sysheapcheck.inc): how much checking a program runs
  with.

  The environment variable HEAP_CHECKS decides: "off" (or 0, none),
  "fill" (fill patterns, header and guard checks), "all" (also the
  quarantine; any other value, or 1, means the same) or "pages" (the
  page heap, syspageheap.inc: every block on pages of its own before a
  page nobody may touch; only from the environment, never from the
  kernel option, since it is slow and costs a page per block). Without it the
  kernel option "heapchecks" (same values, the bare option meaning all)
  is the default, so one option checks the kernel heap and every
  program; HEAP_CHECKS=off in a program's environment still turns it
  off for that program.

  This runs before anything is allocated, so it must not allocate: the
  environment is read in place and the kernel options into a buffer on
  the stack. Because the level is fixed before the first block exists,
  every block of the program carries the header of the checking heap,
  and no block from before the checks can be mistaken for a bad one.
}

type
  THeapCheckLevel = (
    HeapChecksOff,
    HeapChecksFill,
    HeapChecksQuarantine,
    HeapChecksPages);

const
  HeapCheckVariableName = 'HEAP_CHECKS';
  HeapCheckKernelOption = 'heapchecks';
  KernelOptionsCapacity = 256;

var
  HeapCheckLevel: THeapCheckLevel = HeapChecksOff;

{ True if the Length characters at Text are Word. }
function HeapCheckTextIs(Text: PChar; Length: SizeInt; const Word: ShortString): Boolean;
var
  Index: SizeInt;
begin
  HeapCheckTextIs := False;
  if Length <> System.Length(Word) then
    Exit;
  for Index := 1 to Length do
    if Text[Index - 1] <> Word[Index] then
      Exit;
  HeapCheckTextIs := True;
end;

function HeapCheckLevelFromText(Text: PChar; Length: SizeInt): THeapCheckLevel;
begin
  if HeapCheckTextIs(Text, Length, 'off') or HeapCheckTextIs(Text, Length, '0') or
     HeapCheckTextIs(Text, Length, 'none') then
    HeapCheckLevelFromText := HeapChecksOff
  else if HeapCheckTextIs(Text, Length, 'fill') then
    HeapCheckLevelFromText := HeapChecksFill
  else if HeapCheckTextIs(Text, Length, 'pages') then
    HeapCheckLevelFromText := HeapChecksPages
  else
    HeapCheckLevelFromText := HeapChecksQuarantine;
end;

{ The value of HEAP_CHECKS in the environment, or nil. }
function FindHeapCheckVariable: PChar;
var
  Entry: PPChar;
  NameLength: SizeInt;
begin
  FindHeapCheckVariable := nil;
  if envp = nil then
    Exit;
  NameLength := Length(HeapCheckVariableName);
  Entry := envp;
  while Entry^ <> nil do
  begin
    if HeapCheckTextIs(Entry^, NameLength, HeapCheckVariableName) and (Entry^[NameLength] = '=') then
      Exit(Entry^ + NameLength + 1);
    Inc(Entry);
  end;
end;

{ Looks for the heapchecks option in the kernel's command line; True
  and its level if it is there. }
function FindHeapCheckKernelOption(out Level: THeapCheckLevel): Boolean;
var
  Options: array[0..KernelOptionsCapacity - 1] of Char;
  WordStart: SizeInt;
  WordEnd: SizeInt;
  NameLength: SizeInt;
begin
  FindHeapCheckKernelOption := False;
  Level := HeapChecksOff;
  if SystemCall(CallGetKernelOptions, QWord(@Options[0]), KernelOptionsCapacity, 0, 0, 0, 0) < 0 then
    Exit;
  NameLength := Length(HeapCheckKernelOption);
  WordStart := 0;
  while Options[WordStart] <> #0 do
  begin
    while Options[WordStart] = ' ' do
      Inc(WordStart);
    WordEnd := WordStart;
    while (Options[WordEnd] <> ' ') and (Options[WordEnd] <> #0) do
      Inc(WordEnd);

    if HeapCheckTextIs(@Options[WordStart], WordEnd - WordStart, HeapCheckKernelOption) then
    begin
      Level := HeapChecksQuarantine;
      Exit(True);
    end;
    if (WordEnd - WordStart > NameLength) and
       HeapCheckTextIs(@Options[WordStart], NameLength, HeapCheckKernelOption) and
       (Options[WordStart + NameLength] = '=') then
    begin
      Level := HeapCheckLevelFromText(@Options[WordStart + NameLength + 1], WordEnd - WordStart - NameLength - 1);
      if Level = HeapChecksPages then
        Level := HeapChecksQuarantine;
      Exit(True);
    end;
    WordStart := WordEnd;
  end;
end;

procedure ChooseHeapCheckLevel;
var
  Value: PChar;
  Level: THeapCheckLevel;
begin
  Value := FindHeapCheckVariable;
  if Value <> nil then
    HeapCheckLevel := HeapCheckLevelFromText(Value, StrLen(Value))
  else if FindHeapCheckKernelOption(Level) then
    HeapCheckLevel := Level
  else
    HeapCheckLevel := HeapChecksOff;
end;
