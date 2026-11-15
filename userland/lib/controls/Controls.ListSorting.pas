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
  Sorting list view items: comparing two items by a column, as text or
  by the numbers the texts start with, and sorting a list of items with
  any comparison.

  The sort is stable (a merge sort): items that compare equal keep the
  order they had, so sorting by one column and then by another leaves
  the first order within the second's ties.
}
unit Controls.ListSorting;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Controls.ListItems;

type
  { Negative if First goes before Second, positive if after, 0 if equal. }
  TListItemCompare = function(First, Second: TListItem): LongInt of object;

{ Column's texts, letters compared regardless of case. }
function CompareCellTexts(First, Second: TListItem; Column: LongInt): LongInt;
{ The numbers Column's texts start with ("40 KiB": 40); texts without a
  number go first; equal numbers are compared as text. }
function CompareCellNumbers(First, Second: TListItem; Column: LongInt): LongInt;
{ The number Text starts with (after spaces; a sign, digits, a fraction
  after a point); False if it does not start with one. }
function LeadingNumber(const Text: string; out Value: Double): Boolean;
{ Items (TListItem each) put in Compare's order. }
procedure SortListItems(Items: TList; Compare: TListItemCompare);

implementation

uses
  SysUtils;

function CompareCellTexts(First, Second: TListItem; Column: LongInt): LongInt;
begin
  Result := CompareText(First.Cells[Column], Second.Cells[Column]);
end;

function LeadingNumber(const Text: string; out Value: Double): Boolean;
var
  Index: LongInt;
  Negative: Boolean;
  Scale: Double;
  SawDigit: Boolean;
begin
  Value := 0;
  Index := 1;
  while (Index <= Length(Text)) and (Text[Index] = ' ') do
    Inc(Index);
  Negative := (Index <= Length(Text)) and (Text[Index] = '-');
  if Negative or ((Index <= Length(Text)) and (Text[Index] = '+')) then
    Inc(Index);
  SawDigit := False;
  while (Index <= Length(Text)) and (Text[Index] in ['0'..'9']) do
  begin
    Value := Value * 10 + (Ord(Text[Index]) - Ord('0'));
    SawDigit := True;
    Inc(Index);
  end;
  if (Index <= Length(Text)) and (Text[Index] = '.') then
  begin
    Inc(Index);
    Scale := 0.1;
    while (Index <= Length(Text)) and (Text[Index] in ['0'..'9']) do
    begin
      Value := Value + (Ord(Text[Index]) - Ord('0')) * Scale;
      Scale := Scale / 10;
      SawDigit := True;
      Inc(Index);
    end;
  end;
  if Negative then
    Value := -Value;
  Result := SawDigit;
end;

function CompareCellNumbers(First, Second: TListItem; Column: LongInt): LongInt;
var
  FirstValue: Double;
  SecondValue: Double;
  FirstIsNumber: Boolean;
  SecondIsNumber: Boolean;
begin
  FirstIsNumber := LeadingNumber(First.Cells[Column], FirstValue);
  SecondIsNumber := LeadingNumber(Second.Cells[Column], SecondValue);
  if FirstIsNumber and not SecondIsNumber then
    Exit(1);
  if SecondIsNumber and not FirstIsNumber then
    Exit(-1);
  if FirstIsNumber and (FirstValue < SecondValue) then
    Exit(-1);
  if FirstIsNumber and (FirstValue > SecondValue) then
    Exit(1);
  Result := CompareCellTexts(First, Second, Column);
end;

{ Merges the sorted runs Source[RunStart..RunMiddle - 1] and Source[RunMiddle..RunEnd - 1]
  into Target[RunStart..RunEnd - 1]; on a tie the left run's item goes first,
  which is what keeps the sort stable. }
procedure MergeRuns(const Source: array of Pointer; var Target: array of Pointer; RunStart, RunMiddle, RunEnd: LongInt;
  Compare: TListItemCompare);
var
  Left: LongInt;
  Right: LongInt;
  Index: LongInt;
begin
  Left := RunStart;
  Right := RunMiddle;
  for Index := RunStart to RunEnd - 1 do
    if (Left < RunMiddle) and ((Right >= RunEnd) or (Compare(TListItem(Source[Left]), TListItem(Source[Right])) <= 0)) then
    begin
      Target[Index] := Source[Left];
      Inc(Left);
    end
    else
    begin
      Target[Index] := Source[Right];
      Inc(Right);
    end;
end;

procedure SortListItems(Items: TList; Compare: TListItemCompare);
var
  Current: array of Pointer;
  Merged: array of Pointer;
  Swap: array of Pointer;
  Count: LongInt;
  Width: LongInt;
  RunStart: LongInt;
  RunMiddle: LongInt;
  RunEnd: LongInt;
  Index: LongInt;
begin
  Count := Items.Count;
  if Count < 2 then
    Exit;
  SetLength(Current, Count);
  SetLength(Merged, Count);
  for Index := 0 to Count - 1 do
    Current[Index] := Items[Index];
  { Bottom up: runs of 1 merged into runs of 2, then 4, and so on. }
  Width := 1;
  while Width < Count do
  begin
    RunStart := 0;
    while RunStart < Count do
    begin
      RunMiddle := RunStart + Width;
      if RunMiddle > Count then
        RunMiddle := Count;
      RunEnd := RunStart + 2 * Width;
      if RunEnd > Count then
        RunEnd := Count;
      MergeRuns(Current, Merged, RunStart, RunMiddle, RunEnd, Compare);
      RunStart := RunEnd;
    end;
    Swap := Current;
    Current := Merged;
    Merged := Swap;
    Width := Width * 2;
  end;
  for Index := 0 to Count - 1 do
    Items[Index] := Current[Index];
end;

end.
