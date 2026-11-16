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
  Finding an item by typing the first letters of its name, as lists
  let one do.

  Characters typed in quick succession (less than TypeAheadPause apart)
  add up to a prefix, and the first name from the current item on that
  starts with it is the one found ("rea" finds readme.txt). The same
  letter typed again and again instead steps through the names that
  start with it ("d", "d" goes to the second name starting with d).
  Letters match in either case (A to Z only; other characters exactly).

  This is plain logic: the list's names come through a routine, so the
  host can check it (make files-test).
}
unit Controls.TypeAhead;

{$mode objfpc}
{$H+}

interface

const
  { Milliseconds after which typing starts a new prefix. }
  TypeAheadPause = 1000;

type
  { The name of item Index. }
  TItemNameFunction = function(Index: LongInt): string of object;

  TTypeAhead = record
    Typed: string;
    LastKeyTime: QWord;
  end;

procedure ResetTypeAhead(out State: TTypeAhead);
{ Adds Character (a code point) typed at Now (milliseconds) and returns the
  item to go to: Current is the item with the focus (-1: none), Count
  how many there are. -1 if no name fits. }
function TypeAheadFind(var State: TTypeAhead; Character: LongWord; Now: QWord; Current, Count: LongInt;
  NameOf: TItemNameFunction): LongInt;
{ True if Name starts with Prefix, letters in either case. }
function StartsWithIgnoringCase(const Name, Prefix: string): Boolean;

implementation

uses
  SysUtils,
  Controls.TextPositions;

procedure ResetTypeAhead(out State: TTypeAhead);
begin
  State.Typed := '';
  State.LastKeyTime := 0;
end;

{ CompareText folds ASCII letters only, as the comparison here should. }
function StartsWithIgnoringCase(const Name, Prefix: string): Boolean;
begin
  if Length(Prefix) > Length(Name) then
    Exit(False);
  Result := CompareText(Copy(Name, 1, Length(Prefix)), Prefix) = 0;
end;

{ True if Text is one character (of Width bytes) said again and again. }
function IsOneCharacterRepeated(const Text: string; Width: LongInt): Boolean;
var
  Index: LongInt;
begin
  if (Width <= 0) or (Length(Text) <= Width) or ((Length(Text) mod Width) <> 0) then
    Exit(False);
  Index := Width + 1;
  while Index <= Length(Text) do
  begin
    if not StartsWithIgnoringCase(Copy(Text, Index, Width), Copy(Text, 1, Width)) then
      Exit(False);
    Index := Index + Width;
  end;
  Result := True;
end;

{ The first item from Start on (wrapping round) whose name starts with
  Prefix, or -1. }
function FindFrom(Start, Count: LongInt; const Prefix: string; NameOf: TItemNameFunction): LongInt;
var
  Step: LongInt;
  Index: LongInt;
begin
  for Step := 0 to Count - 1 do
  begin
    Index := (Start + Step) mod Count;
    if StartsWithIgnoringCase(NameOf(Index), Prefix) then
      Exit(Index);
  end;
  Result := -1;
end;

function TypeAheadFind(var State: TTypeAhead; Character: LongWord; Now: QWord; Current, Count: LongInt;
  NameOf: TItemNameFunction): LongInt;
var
  Start: LongInt;
  Typed: string;
begin
  Typed := Utf8Of(Character);
  if (State.Typed <> '') and (Now - State.LastKeyTime >= TypeAheadPause) then
    State.Typed := '';
  State.LastKeyTime := Now;
  State.Typed := State.Typed + Typed;
  if Count <= 0 then
    Exit(-1);
  if Current < 0 then
    Current := 0;
  if (Length(State.Typed) = Length(Typed)) or IsOneCharacterRepeated(State.Typed, Length(Typed)) then
  begin
    { A new start, or the same letter again: the next name with it after
      the current one (wrapping round to the current one itself only if
      nothing else has it). }
    Start := (Current + 1) mod Count;
    Exit(FindFrom(Start, Count, Typed, NameOf));
  end;
  { A longer prefix: the current item may well still fit. }
  Result := FindFrom(Current, Count, State.Typed, NameOf);
end;

end.
