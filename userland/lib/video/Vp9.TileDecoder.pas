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
  Decoding a VP9 tile (section 6.4 of the VP9 specification): its 64x64
  superblocks in raster order, each split recursively into partitions
  down to blocks, each block's modes read and the block reconstructed.

  Tiles of one tile row share nothing they write but the frame's above
  contexts and mode info (in disjoint columns), so they can be decoded
  at the same time.
}
unit Vp9.TileDecoder;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils, Vp9.TileState;

type
  EVp9TileError = class(Exception);

{ Decodes Tile's superblocks (its boolean decoder started, its rows and
  columns set). }
procedure DecodeTile(Tile: TVp9TileState);

implementation

uses
  Vp9.Tables, Vp9.ModeInfo, Vp9.FrameState, Vp9.Modes, Vp9.BlockReconstruction;

procedure DecodeBlock(Tile: TVp9TileState; MiRow, MiColumn, BlockSize, WidthLog2, HeightLog2: LongInt;
  SubblockWidthLog2, SubblockHeightLog2: LongInt);
var
  Frame: PVp9FrameState;
  Position: TVp9BlockPosition;
  WidthUnits, HeightUnits, X, Y, Offset, EndTotal: LongInt;
  Info: PVp9ModeInfo;
begin
  Frame := Tile.Frame;
  WidthUnits := 1 shl (WidthLog2 - 1);
  HeightUnits := 1 shl (HeightLog2 - 1);
  Position.MiRow := MiRow;
  Position.MiColumn := MiColumn;
  Position.BlockSize := BlockSize;
  Position.WidthUnits := WidthUnits;
  if Frame^.MiColumns - MiColumn < Position.WidthUnits then
    Position.WidthUnits := Frame^.MiColumns - MiColumn;
  Position.HeightUnits := HeightUnits;
  if Frame^.MiRows - MiRow < Position.HeightUnits then
    Position.HeightUnits := Frame^.MiRows - MiRow;
  Offset := MiRow * Frame^.MiColumns + MiColumn;
  Info := @Frame^.Grid.Records[Offset];
  Info^.BlockSize := BlockSize;
  for Y := 0 to Position.HeightUnits - 1 do
    for X := 0 to Position.WidthUnits - 1 do
      Frame^.Grid.Cells[Offset + Y * Frame^.MiColumns + X] := Info;
  Position.Info := Info;
  Position.ToTop := -((MiRow * 8) * 8);
  Position.ToBottom := ((Frame^.MiRows - HeightUnits - MiRow) * 8) * 8;
  Position.ToLeft := -((MiColumn * 8) * 8);
  Position.ToRight := ((Frame^.MiColumns - WidthUnits - MiColumn) * 8) * 8;
  Position.TileColumnStart := Tile.TileColumnStart;
  Position.TileColumnEnd := Tile.TileColumnEnd;
  if MiRow > 0 then
    Position.Above := Frame^.Grid.Cells[Offset - Frame^.MiColumns]
  else
    Position.Above := nil;
  if MiColumn > Tile.TileColumnStart then
    Position.Left := Frame^.Grid.Cells[Offset - 1]
  else
    Position.Left := nil;
  Position.SubblockWidthLog2 := SubblockWidthLog2;
  Position.SubblockHeightLog2 := SubblockHeightLog2;
  if (BlockSize >= Block8x8) and ((Frame^.SubsamplingX <> 0) or (Frame^.SubsamplingY <> 0)) then
    if SubsampledSizes[BlockSize, Frame^.SubsamplingX, Frame^.SubsamplingY] = BlockInvalid then
      raise EVp9TileError.Create('VP9: invalid block size');
  ReadModeInfo(Tile.Decoder, Frame^, Position, Tile.CountsPointer);
  if Info^.Skip then
    ResetSkipContexts(Tile, Position);
  if not IsInter(Info) then
    ReconstructIntraBlock(Tile, Position)
  else
  begin
    PredictInterBlock(Tile, Position);
    if not Info^.Skip then
    begin
      EndTotal := AddInterResidual(Tile, Position);
      if (BlockSize >= Block8x8) and (EndTotal = 0) then
        Info^.Skip := True;
    end;
  end;
  if Tile.Decoder.HasError then
    raise EVp9TileError.Create('VP9: failed to decode tile data');
end;

function ReadPartition(Tile: TVp9TileState; MiRow, MiColumn: LongInt; HasRows, HasColumns: Boolean;
  SizeLog2: LongInt): LongInt;
var
  Context, AboveBit, LeftBit: LongInt;
  P: PByte;
begin
  AboveBit := (Tile.Above^.Partitions[MiColumn] shr SizeLog2) and 1;
  LeftBit := (Tile.LeftPartitions[MiRow and 7] shr SizeLog2) and 1;
  Context := LeftBit * 2 + AboveBit + SizeLog2 * 4;
  if Tile.Frame^.IntraOnly then
    P := @KeyFramePartitionProbabilities[Context, 0]
  else
    P := @Tile.Frame^.Probabilities^.Partitions[Context, 0];
  if HasRows and HasColumns then
    Result := Tile.Decoder.ReadTree(@PartitionTree[0], P)
  else if (not HasRows) and HasColumns then
  begin
    if Tile.Decoder.ReadBool(P[1]) <> 0 then
      Result := PartitionSplit
    else
      Result := PartitionHorizontal;
  end
  else if HasRows and not HasColumns then
  begin
    if Tile.Decoder.ReadBool(P[2]) <> 0 then
      Result := PartitionSplit
    else
      Result := PartitionVertical;
  end
  else
    Result := PartitionSplit;
  if Tile.CountsPointer <> nil then
    Inc(Tile.Counts.Partitions[Context, Result]);
end;

procedure DecodePartition(Tile: TVp9TileState; MiRow, MiColumn, BlockSize, Size4x4Log2: LongInt);
var
  Size8x8Log2, HalfBlock, Partition, Subsize, Width8x8: LongInt;
  HasRows, HasColumns: Boolean;
begin
  if (MiRow >= Tile.Frame^.MiRows) or (MiColumn >= Tile.Frame^.MiColumns) then
    Exit;
  Size8x8Log2 := Size4x4Log2 - 1;
  Width8x8 := 1 shl Size8x8Log2;
  HalfBlock := Width8x8 shr 1;
  HasRows := (MiRow + HalfBlock) < Tile.Frame^.MiRows;
  HasColumns := (MiColumn + HalfBlock) < Tile.Frame^.MiColumns;
  Partition := ReadPartition(Tile, MiRow, MiColumn, HasRows, HasColumns, Size8x8Log2);
  Subsize := Subsizes[Partition, BlockSize];
  if HalfBlock = 0 then
    DecodeBlock(Tile, MiRow, MiColumn, Subsize, 1, 1, 1 shr Ord((Partition and PartitionVertical) <> 0),
      1 shr Ord((Partition and PartitionHorizontal) <> 0))
  else
    case Partition of
      PartitionNone:
        DecodeBlock(Tile, MiRow, MiColumn, Subsize, Size4x4Log2, Size4x4Log2, 0, 0);
      PartitionHorizontal:
        begin
          DecodeBlock(Tile, MiRow, MiColumn, Subsize, Size4x4Log2, Size8x8Log2, 0, 0);
          if HasRows then
            DecodeBlock(Tile, MiRow + HalfBlock, MiColumn, Subsize, Size4x4Log2, Size8x8Log2, 0, 0);
        end;
      PartitionVertical:
        begin
          DecodeBlock(Tile, MiRow, MiColumn, Subsize, Size8x8Log2, Size4x4Log2, 0, 0);
          if HasColumns then
            DecodeBlock(Tile, MiRow, MiColumn + HalfBlock, Subsize, Size8x8Log2, Size4x4Log2, 0, 0);
        end;
    else
      begin
        DecodePartition(Tile, MiRow, MiColumn, Subsize, Size8x8Log2);
        DecodePartition(Tile, MiRow, MiColumn + HalfBlock, Subsize, Size8x8Log2);
        DecodePartition(Tile, MiRow + HalfBlock, MiColumn, Subsize, Size8x8Log2);
        DecodePartition(Tile, MiRow + HalfBlock, MiColumn + HalfBlock, Subsize, Size8x8Log2);
      end;
    end;
  if (BlockSize >= Block8x8) and ((BlockSize = Block8x8) or (Partition <> PartitionSplit)) then
  begin
    FillChar(Tile.Above^.Partitions[MiColumn], Width8x8, PartitionContextAbove[Subsize]);
    FillChar(Tile.LeftPartitions[MiRow and 7], Width8x8, PartitionContextLeft[Subsize]);
  end;
end;

procedure DecodeTile(Tile: TVp9TileState);
var
  MiRow, MiColumn: LongInt;
begin
  MiRow := Tile.TileRowStart;
  while MiRow < Tile.TileRowEnd do
  begin
    FillChar(Tile.LeftCoefficients, SizeOf(Tile.LeftCoefficients), 0);
    FillChar(Tile.LeftPartitions, SizeOf(Tile.LeftPartitions), 0);
    MiColumn := Tile.TileColumnStart;
    while MiColumn < Tile.TileColumnEnd do
    begin
      DecodePartition(Tile, MiRow, MiColumn, Block64x64, 4);
      Inc(MiColumn, 8);
    end;
    Inc(MiRow, 8);
  end;
end;

end.
