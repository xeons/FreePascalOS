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
  Stable sorting of pointer arrays (merge sort).

  The comparison receives two items and returns a negative number,
  zero or a positive number. Equal items keep their original order,
  which tools such as sort and ls rely on for predictable output.
}
unit Util.Sorting;

{$mode objfpc}{$H+}
{$pointermath on}

interface

uses
  Classes,
  SysUtils;

type
  TCompareItems = function(First, Second: Pointer; Context: Pointer): Integer;

procedure SortPointers(Items: PPointer; Count: Integer; Compare: TCompareItems; Context: Pointer);

type
  TCompareStrings = function(const First, Second: string): Integer of object;
  TComparePointers = function(First, Second: Pointer): Integer of object;

{ Stable sorts (a merge sort: equal items keep their order), unlike
  TStringList.Sort and TList.Sort. }
procedure SortStrings(var Items: TStringArray; Compare: TCompareStrings);
procedure SortList(List: TFPList; Compare: TComparePointers);

implementation

uses
  Runtime.Memory,
  Sys.Memory;

procedure MergeRuns(Source, Target: PPointer; Start, Middle, Finish: Integer;
  Compare: TCompareItems; Context: Pointer);
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
    if Compare(Source[Right], Source[Left], Context) < 0 then
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

procedure SortPointers(Items: PPointer; Count: Integer; Compare: TCompareItems; Context: Pointer);
var
  Scratch: PPointer;
  Source: PPointer;
  Target: PPointer;
  Swap: PPointer;
  Width: Integer;
  Start: Integer;
  Middle: Integer;
  Finish: Integer;
begin
  if Count < 2 then
    Exit;
  Scratch := PPointer(AllocateMemory(QWord(Count) * SizeOf(Pointer)));
  if Scratch = nil then
    Exit;

  { Bottom-up: merge runs of width 1, 2, 4, ... alternating buffers. }
  Source := Items;
  Target := Scratch;
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
      MergeRuns(Source, Target, Start, Middle, Finish, Compare, Context);
      Start := Finish;
    end;
    Swap := Source;
    Source := Target;
    Target := Swap;
    Width := Width * 2;
  end;

  if Source <> Items then
    CopyMemory(Items, Source, QWord(Count) * SizeOf(Pointer));
  FreeMemory(Scratch);
end;

type
  { Carries a method through SortPointers. }
  TPointerComparison = class
  private
    FCompare: TComparePointers;
  public
    constructor Create(Compare: TComparePointers);
  end;

constructor TPointerComparison.Create(Compare: TComparePointers);
begin
  inherited Create;
  FCompare := Compare;
end;

function ComparePointersBy(First, Second: Pointer; Context: Pointer): Integer;
begin
  Result := TPointerComparison(Context).FCompare(First, Second);
end;

procedure SortList(List: TFPList; Compare: TComparePointers);
var
  Comparison: TPointerComparison;
begin
  if List.Count < 2 then
    Exit;
  Comparison := TPointerComparison.Create(Compare);
  try
    SortPointers(PPointer(List.List), List.Count, @ComparePointersBy, Comparison);
  finally
    Comparison.Free;
  end;
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
