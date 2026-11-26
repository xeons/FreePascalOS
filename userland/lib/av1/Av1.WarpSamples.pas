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
  The find warp samples process (specification section 7.10.4): the
  neighbouring blocks predicted from the same single reference frame,
  as pairs of source and destination positions (CandList) for the
  local warp estimation; NumSamples counts the valid ones.
}
unit Av1.WarpSamples;

{$mode objfpc}

interface

uses
  Av1.Common, Av1.Constants, Av1.Tables, Av1.FrameContext, Av1.TileContext, Av1.MvCandidates;

procedure FindWarpSamples(Tile: TTileContext);

implementation

{ The add sample process (7.10.4.2). }
procedure AddSample(Tile: TTileContext; DeltaRow, DeltaCol: Integer);
var
  MvRow, MvCol, CandSize, CandWidth4, CandHeight4, CandRow, CandCol, MiddleY, MiddleX: Integer;
  Threshold, DifferenceRow, DifferenceCol: Integer;
  Candidate, Source: PBlockInfo;
  Valid: Boolean;
begin
  if Tile.NumSamplesScanned >= LEAST_SQUARES_SAMPLES_MAX then
    Exit;
  MvRow := Tile.MiRow + DeltaRow;
  MvCol := Tile.MiCol + DeltaCol;
  if not CandidateDecoded(Tile, MvRow, MvCol) then
    Exit;
  Candidate := Tile.Frame.Block(MvRow, MvCol);
  if Candidate^.RefFrame[0] <> Tile.RefFrame[0] then
    Exit;
  if Candidate^.RefFrame[1] <> NONE then
    Exit;
  CandSize := Candidate^.MiSize;
  CandWidth4 := Num_4x4_Blocks_Wide[CandSize];
  CandHeight4 := Num_4x4_Blocks_High[CandSize];
  CandRow := MvRow and not (CandHeight4 - 1);
  CandCol := MvCol and not (CandWidth4 - 1);
  MiddleY := CandRow * 4 + CandHeight4 * 2 - 1;
  MiddleX := CandCol * 4 + CandWidth4 * 2 - 1;
  Threshold := Clip3(16, 112, Max(Block_Width(Tile.MiSize), Block_Height(Tile.MiSize)));
  Source := Tile.Frame.Block(CandRow, CandCol);
  DifferenceRow := Abs(Source^.Mv[0][0] - Tile.Mv[0][0]);
  DifferenceCol := Abs(Source^.Mv[0][1] - Tile.Mv[0][1]);
  Valid := (DifferenceRow + DifferenceCol) <= Threshold;
  Inc(Tile.NumSamplesScanned);
  if (not Valid) and (Tile.NumSamplesScanned > 1) then
    Exit;
  Tile.CandList[Tile.NumSamples, 0] := MiddleY * 8;
  Tile.CandList[Tile.NumSamples, 1] := MiddleX * 8;
  Tile.CandList[Tile.NumSamples, 2] := MiddleY * 8 + Source^.Mv[0][0];
  Tile.CandList[Tile.NumSamples, 3] := MiddleX * 8 + Source^.Mv[0][1];
  if Valid then
    Inc(Tile.NumSamples);
end;

procedure FindWarpSamples(Tile: TTileContext);
var
  Width4, Height4, SourceWidth, SourceHeight, Offset, Index, Step, Limit: Integer;
  DoTopLeft, DoTopRight: Boolean;
begin
  Tile.NumSamples := 0;
  Tile.NumSamplesScanned := 0;
  Width4 := Num_4x4_Blocks_Wide[Tile.MiSize];
  Height4 := Num_4x4_Blocks_High[Tile.MiSize];
  DoTopLeft := True;
  DoTopRight := True;
  if Tile.AvailU then
  begin
    SourceWidth := Num_4x4_Blocks_Wide[Tile.Frame.Block(Tile.MiRow - 1, Tile.MiCol)^.MiSize];
    if Width4 <= SourceWidth then
    begin
      Offset := -(Tile.MiCol and (SourceWidth - 1));
      if Offset < 0 then
        DoTopLeft := False;
      if Offset + SourceWidth > Width4 then
        DoTopRight := False;
      AddSample(Tile, -1, 0);
    end
    else
    begin
      Limit := Min(Width4, Tile.Header^.MiCols - Tile.MiCol);
      Index := 0;
      while Index < Limit do
      begin
        SourceWidth := Num_4x4_Blocks_Wide[Tile.Frame.Block(Tile.MiRow - 1, Tile.MiCol + Index)^.MiSize];
        Step := Min(Width4, SourceWidth);
        AddSample(Tile, -1, Index);
        Inc(Index, Step);
      end;
    end;
  end;
  if Tile.AvailL then
  begin
    SourceHeight := Num_4x4_Blocks_High[Tile.Frame.Block(Tile.MiRow, Tile.MiCol - 1)^.MiSize];
    if Height4 <= SourceHeight then
    begin
      Offset := -(Tile.MiRow and (SourceHeight - 1));
      if Offset < 0 then
        DoTopLeft := False;
      AddSample(Tile, 0, -1);
    end
    else
    begin
      Limit := Min(Height4, Tile.Header^.MiRows - Tile.MiRow);
      Index := 0;
      while Index < Limit do
      begin
        SourceHeight := Num_4x4_Blocks_High[Tile.Frame.Block(Tile.MiRow + Index, Tile.MiCol - 1)^.MiSize];
        Step := Min(Height4, SourceHeight);
        AddSample(Tile, Index, -1);
        Inc(Index, Step);
      end;
    end;
  end;
  if DoTopLeft then
    AddSample(Tile, -1, -1);
  if DoTopRight and (Max(Width4, Height4) <= 16) then
    AddSample(Tile, -1, Width4);
  if (Tile.NumSamples = 0) and (Tile.NumSamplesScanned > 0) then
    Tile.NumSamples := 1;
end;

end.
