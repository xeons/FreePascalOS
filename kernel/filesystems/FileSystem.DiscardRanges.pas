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
  A batch of byte ranges waiting to be discarded (FileSystem.Discards).

  Ranges are kept sorted by start and never overlap or touch: a range
  added next to or over others is merged with them, so freeing a file's
  clusters one by one ends as one range per run of clusters. Cancelling
  a range (its blocks were allocated again before the discard went out)
  cuts it out of whatever it overlaps, splitting a range in two if need
  be. The list has a fixed capacity; Add reports when a range found no
  room (the caller then sends the batch and tries again, or lets that
  range go: a later fstrim finds it).

  Pure data, for the host test (tools/CachePolicyTest).
}
unit FileSystem.DiscardRanges;

{$mode objfpc}

interface

const
  DiscardRangeCapacity = 128;

type
  TDiscardRange = record
    Start: QWord;
    Count: QWord;
  end;

  TDiscardRangeList = record
    Ranges: array[0..DiscardRangeCapacity - 1] of TDiscardRange;
    Count: Integer;
  end;

procedure ClearDiscardRanges(out List: TDiscardRangeList);
{ Adds Count bytes at Start, merged with what it touches; False if there
  was no room (nothing changed then). }
function AddDiscardRange(var List: TDiscardRangeList; Start, Count: QWord): Boolean;
{ Takes Count bytes at Start out of the list; False if a split found no
  room (the range it would split is then dropped whole, which is always
  safe: discarding less). }
function CancelDiscardRange(var List: TDiscardRangeList; Start, Count: QWord): Boolean;
{ Adds every range of Source to List; False if some found no room. }
function MergeDiscardRanges(var List: TDiscardRangeList; const Source: TDiscardRangeList): Boolean;
function DiscardRangeBytes(const List: TDiscardRangeList): QWord;

implementation

procedure ClearDiscardRanges(out List: TDiscardRangeList);
begin
  List.Count := 0;
end;

procedure RemoveAt(var List: TDiscardRangeList; Index: Integer);
var
  Place: Integer;
begin
  for Place := Index to List.Count - 2 do
    List.Ranges[Place] := List.Ranges[Place + 1];
  Dec(List.Count);
end;

procedure InsertAt(var List: TDiscardRangeList; Index: Integer; Start, Count: QWord);
var
  Place: Integer;
begin
  Place := List.Count;
  while Place > Index do
  begin
    List.Ranges[Place] := List.Ranges[Place - 1];
    Dec(Place);
  end;
  List.Ranges[Index].Start := Start;
  List.Ranges[Index].Count := Count;
  Inc(List.Count);
end;

function AddDiscardRange(var List: TDiscardRangeList; Start, Count: QWord): Boolean;
var
  Index: Integer;
  Finish: QWord;
  RangeFinish: QWord;
begin
  Result := True;
  if Count = 0 then
    Exit;
  Finish := Start + Count;
  { The first range that ends at or after Start. }
  Index := 0;
  while (Index < List.Count) and (List.Ranges[Index].Start + List.Ranges[Index].Count < Start) do
    Inc(Index);
  if (Index = List.Count) or (List.Ranges[Index].Start > Finish) then
  begin
    if List.Count >= DiscardRangeCapacity then
      Exit(False);
    InsertAt(List, Index, Start, Count);
    Exit;
  end;
  { Touches or overlaps range Index: grow it, then swallow the ranges
    after it that the grown one reaches. }
  if Start < List.Ranges[Index].Start then
  begin
    List.Ranges[Index].Count := List.Ranges[Index].Count + (List.Ranges[Index].Start - Start);
    List.Ranges[Index].Start := Start;
  end;
  RangeFinish := List.Ranges[Index].Start + List.Ranges[Index].Count;
  if Finish > RangeFinish then
    RangeFinish := Finish;
  while (Index + 1 < List.Count) and (List.Ranges[Index + 1].Start <= RangeFinish) do
  begin
    if List.Ranges[Index + 1].Start + List.Ranges[Index + 1].Count > RangeFinish then
      RangeFinish := List.Ranges[Index + 1].Start + List.Ranges[Index + 1].Count;
    RemoveAt(List, Index + 1);
  end;
  List.Ranges[Index].Count := RangeFinish - List.Ranges[Index].Start;
end;

function CancelDiscardRange(var List: TDiscardRangeList; Start, Count: QWord): Boolean;
var
  Index: Integer;
  Finish: QWord;
  RangeStart: QWord;
  RangeFinish: QWord;
begin
  Result := True;
  if Count = 0 then
    Exit;
  Finish := Start + Count;
  Index := 0;
  while Index < List.Count do
  begin
    RangeStart := List.Ranges[Index].Start;
    RangeFinish := RangeStart + List.Ranges[Index].Count;
    if RangeStart >= Finish then
      Break;
    if RangeFinish <= Start then
    begin
      Inc(Index);
      Continue;
    end;
    if (RangeStart < Start) and (RangeFinish > Finish) then
    begin
      { Split: the part before stays here, the part after follows. }
      if List.Count >= DiscardRangeCapacity then
      begin
        RemoveAt(List, Index);
        Exit(False);
      end;
      List.Ranges[Index].Count := Start - RangeStart;
      InsertAt(List, Index + 1, Finish, RangeFinish - Finish);
      Exit;
    end;
    if RangeStart < Start then
    begin
      List.Ranges[Index].Count := Start - RangeStart;
      Inc(Index);
    end
    else if RangeFinish > Finish then
    begin
      List.Ranges[Index].Start := Finish;
      List.Ranges[Index].Count := RangeFinish - Finish;
      Inc(Index);
    end
    else
      RemoveAt(List, Index);
  end;
end;

function MergeDiscardRanges(var List: TDiscardRangeList; const Source: TDiscardRangeList): Boolean;
var
  Index: Integer;
begin
  Result := True;
  for Index := 0 to Source.Count - 1 do
    if not AddDiscardRange(List, Source.Ranges[Index].Start, Source.Ranges[Index].Count) then
      Result := False;
end;

function DiscardRangeBytes(const List: TDiscardRangeList): QWord;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to List.Count - 1 do
    Result := Result + List.Ranges[Index].Count;
end;

end.
