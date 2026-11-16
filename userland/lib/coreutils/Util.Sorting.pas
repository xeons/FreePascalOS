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
  Stable sorting (merge sort) of strings and of lists.

  The comparison receives two items and returns a negative number,
  zero or a positive number. Equal items keep their original order,
  which tools such as sort and ptx rely on for predictable output.
}
unit Util.Sorting;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils;

type
  TCompareStrings = function(const First, Second: string): Integer of object;
  TComparePointers = function(First, Second: Pointer): Integer of object;

{ Stable sorts (a merge sort: equal items keep their order), unlike
  TStringList.Sort and TList.Sort. }
procedure SortStrings(var Items: TStringArray; Compare: TCompareStrings);
procedure SortList(List: TFPList; Compare: TComparePointers);

implementation

type
  TPointerArray = array of Pointer;

procedure MergePointerRuns(const Source: TPointerArray; var Target: TPointerArray;
  Start, Middle, Finish: Integer; Compare: TComparePointers);
var
  Left: Integer;
  Right: Integer;
  Output: Integer;
begin
  Left := Start;
  Right := Middle;
  Output := Start;
  while (Left < Middle) and (Right < Finish) do
  begin
    { Take from the left run on ties to keep the sort stable. }
    if Compare(Source[Right], Source[Left]) < 0 then
    begin
      Target[Output] := Source[Right];
      Inc(Right);
    end
    else
    begin
      Target[Output] := Source[Left];
      Inc(Left);
    end;
    Inc(Output);
  end;
  while Left < Middle do
  begin
    Target[Output] := Source[Left];
    Inc(Left);
    Inc(Output);
  end;
  while Right < Finish do
  begin
    Target[Output] := Source[Right];
    Inc(Right);
    Inc(Output);
  end;
end;

procedure SortList(List: TFPList; Compare: TComparePointers);
var
  Items: TPointerArray;
  Scratch: TPointerArray;
  Swap: TPointerArray;
  Count: Integer;
  Index: Integer;
  Width: Integer;
  Start: Integer;
  Middle: Integer;
  Finish: Integer;
begin
  Count := List.Count;
  if Count < 2 then
    Exit;
  Items := nil;
  SetLength(Items, Count);
  for Index := 0 to Count - 1 do
    Items[Index] := List[Index];
  Scratch := nil;
  SetLength(Scratch, Count);
  { Bottom-up: merge runs of width 1, 2, 4, ... alternating arrays. }
  Width := 1;
  while Width < Count do
  begin
    Start := 0;
    while Start < Count do
    begin
      Middle := Start + Width;
      if Middle > Count then
        Middle := Count;
      Finish := Start + 2 * Width;
      if Finish > Count then
        Finish := Count;
      MergePointerRuns(Items, Scratch, Start, Middle, Finish, Compare);
      Start := Finish;
    end;
    Swap := Items;
    Items := Scratch;
    Scratch := Swap;
    Width := Width * 2;
  end;
  for Index := 0 to Count - 1 do
    List[Index] := Items[Index];
end;

procedure MergeStringRuns(const Source: TStringArray; var Target: TStringArray;
  Start, Middle, Finish: Integer; Compare: TCompareStrings);
var
  Left: Integer;
  Right: Integer;
  Output: Integer;
begin
  Left := Start;
  Right := Middle;
  Output := Start;
  while (Left < Middle) and (Right < Finish) do
  begin
    { Take from the left run on ties to keep the sort stable. }
    if Compare(Source[Right], Source[Left]) < 0 then
    begin
      Target[Output] := Source[Right];
      Inc(Right);
    end
    else
    begin
      Target[Output] := Source[Left];
      Inc(Left);
    end;
    Inc(Output);
  end;
  while Left < Middle do
  begin
    Target[Output] := Source[Left];
    Inc(Left);
    Inc(Output);
  end;
  while Right < Finish do
  begin
    Target[Output] := Source[Right];
    Inc(Right);
    Inc(Output);
  end;
end;

procedure SortStrings(var Items: TStringArray; Compare: TCompareStrings);
var
  Scratch: TStringArray;
  Swap: TStringArray;
  Count: Integer;
  Width: Integer;
  Start: Integer;
  Middle: Integer;
  Finish: Integer;
begin
  Count := Length(Items);
  if Count < 2 then
    Exit;
  Scratch := nil;
  SetLength(Scratch, Count);
  { Bottom-up: merge runs of width 1, 2, 4, ... alternating arrays. }
  Width := 1;
  while Width < Count do
  begin
    Start := 0;
    while Start < Count do
    begin
      Middle := Start + Width;
      if Middle > Count then
        Middle := Count;
      Finish := Start + 2 * Width;
      if Finish > Count then
        Finish := Count;
      MergeStringRuns(Items, Scratch, Start, Middle, Finish, Compare);
      Start := Finish;
    end;
    Swap := Items;
    Items := Scratch;
    Scratch := Swap;
    Width := Width * 2;
  end;
end;

end.
