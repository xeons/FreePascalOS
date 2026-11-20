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
  Sets of 64-bit numbers kept as sorted, disjoint, half-open ranges
  [Start, Finish): the packet numbers received (for ACK frames), the
  stream bytes received, acknowledged or lost. Neighbouring ranges are
  merged. A set may be bounded (MaximumRanges): adding beyond it drops
  the lowest range, which for packet numbers only means old packets
  are no longer acknowledged.
}
unit Quic.RangeSets;

{$mode objfpc}
{$modeswitch advancedrecords}

interface

type
  TQuicRange = record
    Start: QWord;
    Finish: QWord;
  end;

  TQuicRangeSet = record
    Ranges: array of TQuicRange;
    Count: Integer;
    { 0: no bound. }
    MaximumRanges: Integer;
    procedure Clear;
    procedure Add(Start, Finish: QWord);
    procedure Remove(Start, Finish: QWord);
    function Contains(Value: QWord): Boolean;
    { True when any number of [Start, Finish) is in the set. }
    function Overlaps(Start, Finish: QWord): Boolean;
    { The end of the run of numbers in the set that starts at Value
      (Value itself when Value is not in the set). }
    function ContiguousEnd(Value: QWord): QWord;
    function IsEmpty: Boolean;
    function Lowest: QWord;
    { One past the highest number. }
    function HighestFinish: QWord;
    { Removes and returns the lowest range, cut to at most MaximumLength
      numbers. }
    function TakeLowest(MaximumLength: QWord; out Range: TQuicRange): Boolean;
  end;

implementation

procedure TQuicRangeSet.Clear;
begin
  Count := 0;
end;

function TQuicRangeSet.IsEmpty: Boolean;
begin
  Result := Count = 0;
end;

function TQuicRangeSet.Lowest: QWord;
begin
  if Count = 0 then
    Exit(0);
  Result := Ranges[0].Start;
end;

function TQuicRangeSet.HighestFinish: QWord;
begin
  if Count = 0 then
    Exit(0);
  Result := Ranges[Count - 1].Finish;
end;

procedure TQuicRangeSet.Add(Start, Finish: QWord);
var
  First, Last, Index, Removed: Integer;
begin
  if Finish <= Start then
    Exit;
  { The first range that ends at or after Start (it may merge). }
  First := 0;
  while (First < Count) and (Ranges[First].Finish < Start) do
    Inc(First);
  { The last range that starts at or before Finish. }
  Last := First - 1;
  while (Last + 1 < Count) and (Ranges[Last + 1].Start <= Finish) do
    Inc(Last);
  if Last < First then
  begin
    { No overlap: insert a new range at First. }
    if Count >= Length(Ranges) then
      SetLength(Ranges, Count * 2 + 4);
    for Index := Count downto First + 1 do
      Ranges[Index] := Ranges[Index - 1];
    Ranges[First].Start := Start;
    Ranges[First].Finish := Finish;
    Inc(Count);
  end
  else
  begin
    { Merge First..Last with the new range into First. }
    if Ranges[First].Start < Start then
      Start := Ranges[First].Start;
    if Ranges[Last].Finish > Finish then
      Finish := Ranges[Last].Finish;
    Ranges[First].Start := Start;
    Ranges[First].Finish := Finish;
    Removed := Last - First;
    if Removed > 0 then
    begin
      for Index := First + 1 to Count - 1 - Removed do
        Ranges[Index] := Ranges[Index + Removed];
      Count := Count - Removed;
    end;
  end;
  if (MaximumRanges > 0) and (Count > MaximumRanges) then
  begin
    for Index := 0 to Count - 2 do
      Ranges[Index] := Ranges[Index + 1];
    Dec(Count);
  end;
end;

procedure TQuicRangeSet.Remove(Start, Finish: QWord);
var
  Index, Shift: Integer;
  Current: TQuicRange;
begin
  if Finish <= Start then
    Exit;
  Index := 0;
  while Index < Count do
  begin
    Current := Ranges[Index];
    if (Current.Finish <= Start) or (Current.Start >= Finish) then
    begin
      Inc(Index);
      Continue;
    end;
    if (Current.Start < Start) and (Current.Finish > Finish) then
    begin
      { Split in two. }
      if Count >= Length(Ranges) then
        SetLength(Ranges, Count * 2 + 4);
      for Shift := Count downto Index + 2 do
        Ranges[Shift] := Ranges[Shift - 1];
      Ranges[Index].Finish := Start;
      Ranges[Index + 1].Start := Finish;
      Ranges[Index + 1].Finish := Current.Finish;
      Inc(Count);
      Exit;
    end;
    if Current.Start < Start then
    begin
      Ranges[Index].Finish := Start;
      Inc(Index);
      Continue;
    end;
    if Current.Finish > Finish then
    begin
      Ranges[Index].Start := Finish;
      Exit;
    end;
    { Wholly inside: drop it. }
    for Shift := Index to Count - 2 do
      Ranges[Shift] := Ranges[Shift + 1];
    Dec(Count);
  end;
end;

function TQuicRangeSet.Contains(Value: QWord): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to Count - 1 do
    if (Value >= Ranges[Index].Start) and (Value < Ranges[Index].Finish) then
      Exit(True);
  Result := False;
end;

function TQuicRangeSet.Overlaps(Start, Finish: QWord): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to Count - 1 do
    if (Ranges[Index].Start < Finish) and (Ranges[Index].Finish > Start) then
      Exit(True);
  Result := False;
end;

function TQuicRangeSet.ContiguousEnd(Value: QWord): QWord;
var
  Index: Integer;
begin
  for Index := 0 to Count - 1 do
    if (Value >= Ranges[Index].Start) and (Value < Ranges[Index].Finish) then
      Exit(Ranges[Index].Finish);
  Result := Value;
end;

function TQuicRangeSet.TakeLowest(MaximumLength: QWord; out Range: TQuicRange): Boolean;
begin
  Range.Start := 0;
  Range.Finish := 0;
  if (Count = 0) or (MaximumLength = 0) then
    Exit(False);
  Range := Ranges[0];
  if Range.Finish - Range.Start > MaximumLength then
    Range.Finish := Range.Start + MaximumLength;
  Remove(Range.Start, Range.Finish);
  Result := True;
end;

end.
