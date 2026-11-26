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
  The edges of intra prediction (specification sections 7.11.2.7 to
  7.11.2.12): the filter corner, intra filter type, edge filter strength
  and upsample selection, and the edge upsample and edge filter
  processes over a tile's AboveRow and LeftCol (Edge points at index 0
  of either; indexes -2 and -1 exist).
}
unit Av1.IntraEdges;

{$mode objfpc}

interface

uses
  Av1.Constants, Av1.Tables, Av1.TileContext;

const
  { Index of AboveRow[ 0 ] / LeftCol[ 0 ] in TTileContext.IntraAboveRow / IntraLeftCol. }
  IntraEdgeOrigin = 16;

type
  TEdgePointer = PInteger;

{ The filter corner process: the value for AboveRow[ -1 ] and LeftCol[ -1 ]. }
function FilterCorner(Above, Left: TEdgePointer): Integer;
{ The intra filter type process (get_filter_type): 1 when the block above
  or to the left uses a smooth mode. }
function GetFilterType(Tile: TTileContext; Plane: Integer): Integer;
{ The intra edge filter strength selection process. }
function EdgeFilterStrength(W, H, FilterType, Delta: Integer): Integer;
{ The intra edge upsample selection process. }
function UseEdgeUpsample(W, H, FilterType, Delta: Integer): Boolean;
{ The intra edge filter process over Edge[ -1 .. Size - 2 ]. }
procedure FilterEdge(Edge: TEdgePointer; Size, Strength: Integer);
{ The intra edge upsample process: Edge[ -1 .. NumPx - 1 ] becomes
  Edge[ -2 .. 2 * NumPx - 2 ]. }
procedure UpsampleEdge(Edge: TEdgePointer; NumPx, BitDepth: Integer);

implementation

uses
  Av1.Common, Av1.FrameContext;

function FilterCorner(Above, Left: TEdgePointer): Integer;
var
  Sum: Integer;
begin
  Sum := Left[0] * 5 + Above[-1] * 6 + Above[0] * 5;
  Result := (Sum + 8) shr 4;
end;

function IsSmooth(Tile: TTileContext; Row, Col, Plane: Integer): Boolean;
var
  Info: PBlockInfo;
  Mode: Integer;
begin
  Info := Tile.Frame.Block(Row, Col);
  if Plane = 0 then
    Mode := Info^.YMode
  else
  begin
    if Info^.RefFrame[0] > INTRA_FRAME then
      Exit(False);
    Mode := Info^.UVMode;
  end;
  Result := (Mode = SMOOTH_PRED) or (Mode = SMOOTH_V_PRED) or (Mode = SMOOTH_H_PRED);
end;

function GetFilterType(Tile: TTileContext; Plane: Integer): Integer;
var
  AboveSmooth, LeftSmooth, Available: Boolean;
  Row, Col, SubX, SubY: Integer;
begin
  AboveSmooth := False;
  LeftSmooth := False;
  SubX := Tile.Sequence^.subsampling_x;
  SubY := Tile.Sequence^.subsampling_y;
  if Plane = 0 then
    Available := Tile.AvailU
  else
    Available := Tile.AvailUChroma;
  if Available then
  begin
    Row := Tile.MiRow - 1;
    Col := Tile.MiCol;
    if Plane > 0 then
    begin
      if (SubX <> 0) and ((Tile.MiCol and 1) = 0) then
        Inc(Col);
      if (SubY <> 0) and ((Tile.MiRow and 1) <> 0) then
        Dec(Row);
    end;
    AboveSmooth := IsSmooth(Tile, Row, Col, Plane);
  end;
  if Plane = 0 then
    Available := Tile.AvailL
  else
    Available := Tile.AvailLChroma;
  if Available then
  begin
    Row := Tile.MiRow;
    Col := Tile.MiCol - 1;
    if Plane > 0 then
    begin
      if (SubX <> 0) and ((Tile.MiCol and 1) <> 0) then
        Dec(Col);
      if (SubY <> 0) and ((Tile.MiRow and 1) = 0) then
        Inc(Row);
    end;
    LeftSmooth := IsSmooth(Tile, Row, Col, Plane);
  end;
  Result := Ord(AboveSmooth or LeftSmooth);
end;

function EdgeFilterStrength(W, H, FilterType, Delta: Integer): Integer;
var
  D, BlockWh: Integer;
begin
  D := Abs(Delta);
  BlockWh := W + H;
  Result := 0;
  if FilterType = 0 then
  begin
    if BlockWh <= 8 then
    begin
      if D >= 56 then Result := 1;
    end
    else if BlockWh <= 12 then
    begin
      if D >= 40 then Result := 1;
    end
    else if BlockWh <= 16 then
    begin
      if D >= 40 then Result := 1;
    end
    else if BlockWh <= 24 then
    begin
      if D >= 8 then Result := 1;
      if D >= 16 then Result := 2;
      if D >= 32 then Result := 3;
    end
    else if BlockWh <= 32 then
    begin
      Result := 1;
      if D >= 4 then Result := 2;
      if D >= 32 then Result := 3;
    end
    else
      Result := 3;
  end
  else
  begin
    if BlockWh <= 8 then
    begin
      if D >= 40 then Result := 1;
      if D >= 64 then Result := 2;
    end
    else if BlockWh <= 16 then
    begin
      if D >= 20 then Result := 1;
      if D >= 48 then Result := 2;
    end
    else if BlockWh <= 24 then
    begin
      if D >= 4 then Result := 3;
    end
    else
      Result := 3;
  end;
end;

function UseEdgeUpsample(W, H, FilterType, Delta: Integer): Boolean;
var
  D: Integer;
begin
  D := Abs(Delta);
  if (D <= 0) or (D >= 40) then
    Result := False
  else if FilterType = 0 then
    Result := W + H <= 16
  else
    Result := W + H <= 8;
end;

procedure FilterEdge(Edge: TEdgePointer; Size, Strength: Integer);
var
  Original: array[0..135] of Integer;
  Index, Tap, Position, Sum: Integer;
begin
  if Strength = 0 then
    Exit;
  for Index := 0 to Size - 1 do
    Original[Index] := Edge[Index - 1];
  for Index := 1 to Size - 1 do
  begin
    Sum := 0;
    for Tap := 0 to INTRA_EDGE_TAPS - 1 do
    begin
      Position := Clip3(0, Size - 1, Index - 2 + Tap);
      Inc(Sum, Intra_Edge_Kernel[Strength - 1, Tap] * Original[Position]);
    end;
    Edge[Index - 1] := (Sum + 8) shr 4;
  end;
end;

procedure UpsampleEdge(Edge: TEdgePointer; NumPx, BitDepth: Integer);
var
  Duplicate: array[0..70] of Integer;
  Index, Sum, MaxValue: Integer;
begin
  MaxValue := (1 shl BitDepth) - 1;
  Duplicate[0] := Edge[-1];
  for Index := -1 to NumPx - 1 do
    Duplicate[Index + 2] := Edge[Index];
  Duplicate[NumPx + 2] := Edge[NumPx - 1];
  Edge[-2] := Duplicate[0];
  for Index := 0 to NumPx - 1 do
  begin
    Sum := -Duplicate[Index] + 9 * Duplicate[Index + 1] + 9 * Duplicate[Index + 2] - Duplicate[Index + 3];
    Sum := Clip3(0, MaxValue, Round2(Sum, 4));
    Edge[2 * Index - 1] := Sum;
    Edge[2 * Index] := Duplicate[Index + 2];
  end;
end;

end.
