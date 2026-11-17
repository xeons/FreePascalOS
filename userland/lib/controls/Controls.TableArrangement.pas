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
  Table arrangement: the arithmetic of TTableLayoutPanel, in pixels,
  apart from the controls (checked on the host).

  Columns and rows are tracks, each sized one of three ways: Absolute (a
  fixed extent), AutoSize (as wide or tall as the largest item in it)
  or Percent (a share of what the other tracks leave, the shares
  relative to each other: two tracks of 50 and 25 take two thirds and
  one third). An item spanning several tracks widens the automatic ones
  among them if it does not fit (the shortfall shared equally, the rest
  to the last), unless a percent track among them can take it.

  Items without a cell of their own take the first free one, row by
  row; when there is none, the table grows a row or a column (Grow) or
  leaves the item out.
}
unit Controls.TableArrangement;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles;

type
  TTrackSizing = (TrackAbsolute, TrackAutoSize, TrackPercent);

  TTrackStyle = record
    Sizing: TTrackSizing;
    { Absolute: the extent (pixels); Percent: the share. }
    Value: LongInt;
  end;
  TTrackStyles = array of TTrackStyle;
  TTrackSizes = array of LongInt;

  { An item along one axis: the tracks it covers and the extent it needs
    (margins in). }
  TTrackSpan = record
    First: LongInt;
    Count: LongInt;
    Extent: LongInt;
  end;
  TTrackSpans = array of TTrackSpan;

  TTableGrowStyle = (GrowAddRows, GrowAddColumns, GrowFixedSize);

  { Where an item is: Column -1 if it has no cell (left out). Fixed:
    given by the program rather than found. }
  TCellPlacement = record
    Column: LongInt;
    Row: LongInt;
    ColumnSpan: LongInt;
    RowSpan: LongInt;
    Fixed: Boolean;
  end;
  TCellPlacements = array of TCellPlacement;

function MakeTrackStyle(Sizing: TTrackSizing; Value: LongInt): TTrackStyle;
function MakeTrackSpan(First, Count, Extent: LongInt): TTrackSpan;
{ Each track's extent when the tracks share Available. }
function MeasureTracks(const Styles: TTrackStyles; const Spans: TTrackSpans; Available: LongInt): TTrackSizes;
{ The extent the tracks need for every item to fit, their shares kept. }
function TracksContentExtent(const Styles: TTrackStyles; const Spans: TTrackSpans): LongInt;
{ Where each track starts from Start, and one more entry: where the
  last ends. }
function TrackOffsets(Start: LongInt; const Sizes: TTrackSizes): TTrackSizes;
{ The cell of Column, Row spanning ColumnSpan x RowSpan (clipped to the
  table). }
function CellRectangle(const ColumnOffsets, RowOffsets: TTrackSizes; Column, Row, ColumnSpan,
  RowSpan: LongInt): TRectangle;
{ Gives every placement that is not Fixed the first free cell (row by
  row) its span fits; ColumnCount and RowCount grow as Grow says. }
procedure AssignFreeCells(var Placements: TCellPlacements; var ColumnCount, RowCount: LongInt;
  Grow: TTableGrowStyle);

implementation

function MakeTrackStyle(Sizing: TTrackSizing; Value: LongInt): TTrackStyle;
begin
  Result.Sizing := Sizing;
  Result.Value := Value;
end;

function MakeTrackSpan(First, Count, Extent: LongInt): TTrackSpan;
begin
  Result.First := First;
  Result.Count := Count;
  Result.Extent := Extent;
end;

{ The span clipped to the tracks there are; False if nothing is left. }
function ClipSpan(const Span: TTrackSpan; TrackCount: LongInt; out First, Last: LongInt): Boolean;
begin
  First := Span.First;
  Last := Span.First + Span.Count - 1;
  if Span.Count < 1 then
    Last := First;
  if First < 0 then
    First := 0;
  if Last > TrackCount - 1 then
    Last := TrackCount - 1;
  Result := First <= Last;
end;

{ The tracks' extents with percent tracks treated as AutoSize ones when
  PercentByContent, else left at 0: absolute ones, then single items,
  then spanning items. }
function ContentSizes(const Styles: TTrackStyles; const Spans: TTrackSpans; PercentByContent: Boolean): TTrackSizes;
var
  Index: LongInt;
  Track: LongInt;
  First: LongInt;
  Last: LongInt;
  Covered: LongInt;
  Growable: LongInt;
  Shortfall: LongInt;
  Share: LongInt;
  Given: LongInt;
  SharesRest: Boolean;

  function GrowsByContent(TrackIndex: LongInt): Boolean;
  begin
    Result := (Styles[TrackIndex].Sizing = TrackAutoSize) or
      (PercentByContent and (Styles[TrackIndex].Sizing = TrackPercent));
  end;

begin
  Result := nil;
  SetLength(Result, Length(Styles));
  for Track := 0 to High(Styles) do
    if Styles[Track].Sizing = TrackAbsolute then
      Result[Track] := Styles[Track].Value
    else
      Result[Track] := 0;
  for Index := 0 to High(Spans) do
    if ClipSpan(Spans[Index], Length(Styles), First, Last) and (First = Last) and GrowsByContent(First) and
       (Spans[Index].Extent > Result[First]) then
      Result[First] := Spans[Index].Extent;
  for Index := 0 to High(Spans) do
  begin
    if not ClipSpan(Spans[Index], Length(Styles), First, Last) or (First = Last) then
      Continue;
    Covered := 0;
    Growable := 0;
    SharesRest := False;
    for Track := First to Last do
    begin
      Covered := Covered + Result[Track];
      if GrowsByContent(Track) then
        Inc(Growable);
      if Styles[Track].Sizing = TrackPercent then
        SharesRest := True;
    end;
    { A percent track it covers takes the room it needs from what is
      left, rather than the automatic ones growing. }
    if SharesRest and not PercentByContent then
      Continue;
    Shortfall := Spans[Index].Extent - Covered;
    if (Shortfall <= 0) or (Growable = 0) then
      Continue;
    Share := Shortfall div Growable;
    Given := 0;
    for Track := First to Last do
      if GrowsByContent(Track) then
      begin
        Dec(Growable);
        if Growable = 0 then
          Result[Track] := Result[Track] + Shortfall - Given
        else
        begin
          Result[Track] := Result[Track] + Share;
          Given := Given + Share;
        end;
      end;
  end;
end;

function MeasureTracks(const Styles: TTrackStyles; const Spans: TTrackSpans; Available: LongInt): TTrackSizes;
var
  Track: LongInt;
  Used: LongInt;
  Remaining: LongInt;
  TotalShare: LongInt;
  SharesLeft: LongInt;
  Given: LongInt;
begin
  Result := ContentSizes(Styles, Spans, False);
  Used := 0;
  TotalShare := 0;
  for Track := 0 to High(Styles) do
    if Styles[Track].Sizing = TrackPercent then
      TotalShare := TotalShare + Styles[Track].Value
    else
      Used := Used + Result[Track];
  Remaining := Available - Used;
  if Remaining < 0 then
    Remaining := 0;
  if TotalShare <= 0 then
    Exit;
  { Each its share; the last percent track takes what rounding left. }
  SharesLeft := TotalShare;
  Given := 0;
  for Track := 0 to High(Styles) do
    if Styles[Track].Sizing = TrackPercent then
    begin
      SharesLeft := SharesLeft - Styles[Track].Value;
      if SharesLeft <= 0 then
        Result[Track] := Remaining - Given
      else
      begin
        Result[Track] := LongInt((Int64(Remaining) * Styles[Track].Value) div TotalShare);
        Given := Given + Result[Track];
      end;
    end;
end;

function TracksContentExtent(const Styles: TTrackStyles; const Spans: TTrackSpans): LongInt;
var
  Sizes: TTrackSizes;
  Track: LongInt;
  TotalShare: LongInt;
  PercentNeed: Int64;
  Need: Int64;
begin
  Sizes := ContentSizes(Styles, Spans, True);
  Result := 0;
  TotalShare := 0;
  for Track := 0 to High(Styles) do
    if Styles[Track].Sizing = TrackPercent then
      TotalShare := TotalShare + Styles[Track].Value
    else
      Result := Result + Sizes[Track];
  { The percent tracks together must be large enough that each one's
    share holds what is in it. }
  PercentNeed := 0;
  for Track := 0 to High(Styles) do
    if (Styles[Track].Sizing = TrackPercent) and (Styles[Track].Value > 0) then
    begin
      Need := (Int64(Sizes[Track]) * TotalShare + Styles[Track].Value - 1) div Styles[Track].Value;
      if Need > PercentNeed then
        PercentNeed := Need;
    end;
  Result := Result + LongInt(PercentNeed);
end;

function TrackOffsets(Start: LongInt; const Sizes: TTrackSizes): TTrackSizes;
var
  Track: LongInt;
begin
  Result := nil;
  SetLength(Result, Length(Sizes) + 1);
  Result[0] := Start;
  for Track := 0 to High(Sizes) do
    Result[Track + 1] := Result[Track] + Sizes[Track];
end;

function CellRectangle(const ColumnOffsets, RowOffsets: TTrackSizes; Column, Row, ColumnSpan,
  RowSpan: LongInt): TRectangle;
var
  LastColumn: LongInt;
  LastRow: LongInt;
begin
  if (Column < 0) or (Row < 0) or (Column >= High(ColumnOffsets)) or (Row >= High(RowOffsets)) then
    Exit(MakeRectangle(0, 0, 0, 0));
  if ColumnSpan < 1 then
    ColumnSpan := 1;
  if RowSpan < 1 then
    RowSpan := 1;
  LastColumn := Column + ColumnSpan;
  if LastColumn > High(ColumnOffsets) then
    LastColumn := High(ColumnOffsets);
  LastRow := Row + RowSpan;
  if LastRow > High(RowOffsets) then
    LastRow := High(RowOffsets);
  Result.Left := ColumnOffsets[Column];
  Result.Top := RowOffsets[Row];
  Result.Right := ColumnOffsets[LastColumn];
  Result.Bottom := RowOffsets[LastRow];
end;

type
  TOccupancy = array of array of Boolean;

procedure SizeOccupancy(var Taken: TOccupancy; ColumnCount, RowCount: LongInt);
var
  Row: LongInt;
begin
  SetLength(Taken, RowCount);
  for Row := 0 to RowCount - 1 do
    SetLength(Taken[Row], ColumnCount);
end;

function SpanIsFree(const Taken: TOccupancy; Column, Row, ColumnSpan, RowSpan: LongInt): Boolean;
var
  X: LongInt;
  Y: LongInt;
begin
  if (Row + RowSpan > Length(Taken)) or (Length(Taken) = 0) or (Column + ColumnSpan > Length(Taken[0])) then
    Exit(False);
  for Y := Row to Row + RowSpan - 1 do
    for X := Column to Column + ColumnSpan - 1 do
      if Taken[Y][X] then
        Exit(False);
  Result := True;
end;

procedure TakeSpan(var Taken: TOccupancy; Column, Row, ColumnSpan, RowSpan: LongInt);
var
  X: LongInt;
  Y: LongInt;
begin
  for Y := Row to Row + RowSpan - 1 do
    for X := Column to Column + ColumnSpan - 1 do
      if (Y >= 0) and (Y < Length(Taken)) and (X >= 0) and (X < Length(Taken[Y])) then
        Taken[Y][X] := True;
end;

function FindFreeCell(const Taken: TOccupancy; ColumnCount, RowCount, ColumnSpan, RowSpan: LongInt;
  out Column, Row: LongInt): Boolean;
var
  X: LongInt;
  Y: LongInt;
begin
  for Y := 0 to RowCount - 1 do
    for X := 0 to ColumnCount - 1 do
      if SpanIsFree(Taken, X, Y, ColumnSpan, RowSpan) then
      begin
        Column := X;
        Row := Y;
        Exit(True);
      end;
  Column := -1;
  Row := -1;
  Result := False;
end;

procedure AssignFreeCells(var Placements: TCellPlacements; var ColumnCount, RowCount: LongInt;
  Grow: TTableGrowStyle);
var
  Taken: TOccupancy;
  Index: LongInt;
  Column: LongInt;
  Row: LongInt;
  ColumnSpan: LongInt;
  RowSpan: LongInt;
begin
  if ColumnCount < 1 then
    ColumnCount := 1;
  if RowCount < 0 then
    RowCount := 0;
  Taken := nil;
  SizeOccupancy(Taken, ColumnCount, RowCount);
  for Index := 0 to High(Placements) do
    if Placements[Index].Fixed then
      TakeSpan(Taken, Placements[Index].Column, Placements[Index].Row, Placements[Index].ColumnSpan,
        Placements[Index].RowSpan);
  for Index := 0 to High(Placements) do
  begin
    if Placements[Index].Fixed then
      Continue;
    ColumnSpan := Placements[Index].ColumnSpan;
    RowSpan := Placements[Index].RowSpan;
    if ColumnSpan < 1 then
      ColumnSpan := 1;
    if RowSpan < 1 then
      RowSpan := 1;
    if (Grow <> GrowAddColumns) and (ColumnSpan > ColumnCount) then
      ColumnSpan := ColumnCount;
    while not FindFreeCell(Taken, ColumnCount, RowCount, ColumnSpan, RowSpan, Column, Row) do
    begin
      case Grow of
        GrowAddRows: Inc(RowCount);
        GrowAddColumns:
          begin
            Inc(ColumnCount);
            if RowCount < RowSpan then
              RowCount := RowSpan;
          end;
      else
        Break;
      end;
      SizeOccupancy(Taken, ColumnCount, RowCount);
    end;
    Placements[Index].Column := Column;
    Placements[Index].Row := Row;
    Placements[Index].ColumnSpan := ColumnSpan;
    Placements[Index].RowSpan := RowSpan;
    if Column >= 0 then
      TakeSpan(Taken, Column, Row, ColumnSpan, RowSpan);
  end;
end;

end.
