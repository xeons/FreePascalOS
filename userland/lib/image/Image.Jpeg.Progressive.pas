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
  Progressive scans: every block's coefficients are built up over
  several scans and kept (TJpegComponent.Coefficients) until the end.

  A scan carries either the DC coefficients (of one or several
  components) or a band of AC coefficients (SpectralStart to
  SpectralEnd, of one component), and either their first bits shifted
  up by ApproximationLow or, refining (ApproximationHigh above zero),
  one more bit of each. AC scans code runs of blocks with nothing left
  in the band as one end-of-band run. The refinement follows the
  Independent JPEG Group's decode_mcu_AC_refine: a new coefficient of
  +-1 at the place after Run zero coefficients, and a correction bit for
  every coefficient already non-zero that is passed on the way.

  FinishProgressiveFrame turns every block into samples once the scans
  are read.
}
unit Image.Jpeg.Progressive;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Jpeg.Huffman,
  Image.Jpeg.Frames,
  Image.Jpeg.Scans;

procedure DecodeProgressiveScan(State: TJpegState; constref Scan: TJpegScan; var Reader: TJpegBitReader);
procedure FinishProgressiveFrame(State: TJpegState);

implementation

uses
  Image.Jpeg.Idct;

function BlockCoefficients(State: TJpegState; ComponentIndex, BlockRow, BlockColumn: LongInt): PSmallInt;
begin
  with State.Frame.Components[ComponentIndex] do
    Result := @Coefficients[(PtrInt(BlockRow) * StoredBlocksPerLine + BlockColumn) * 64];
end;

procedure DecodeDcFirst(State: TJpegState; var Reader: TJpegBitReader; constref Scan: TJpegScan;
  ComponentIndex, BlockRow, BlockColumn: LongInt);
var
  Block: PSmallInt;
  Symbol: LongInt;
begin
  Block := BlockCoefficients(State, ComponentIndex, BlockRow, BlockColumn);
  with State.Frame.Components[ComponentIndex] do
  begin
    Symbol := DecodeHuffman(Reader, State.DcTables[DcTableIndex]);
    DcPredictor := DcPredictor + ReceiveAndExtend(Reader, Symbol);
    Block[0] := SmallInt(DcPredictor * (1 shl Scan.ApproximationLow));
  end;
end;

procedure DecodeDcRefine(State: TJpegState; var Reader: TJpegBitReader; constref Scan: TJpegScan;
  ComponentIndex, BlockRow, BlockColumn: LongInt);
var
  Block: PSmallInt;
begin
  Block := BlockCoefficients(State, ComponentIndex, BlockRow, BlockColumn);
  if ReadBit(Reader) <> 0 then
    Block[0] := Block[0] or SmallInt(1 shl Scan.ApproximationLow);
end;

procedure DecodeAcFirst(State: TJpegState; var Reader: TJpegBitReader; constref Scan: TJpegScan;
  ComponentIndex, BlockRow, BlockColumn: LongInt);
var
  Block: PSmallInt;
  Position: LongInt;
  Symbol: LongInt;
  Run: LongInt;
  Size: LongInt;
begin
  if State.EndOfBandRun > 0 then
  begin
    Dec(State.EndOfBandRun);
    Exit;
  end;
  Block := BlockCoefficients(State, ComponentIndex, BlockRow, BlockColumn);
  Position := Scan.SpectralStart;
  with State.Frame.Components[ComponentIndex] do
    while Position <= Scan.SpectralEnd do
    begin
      Symbol := DecodeHuffman(Reader, State.AcTables[AcTableIndex]);
      Run := Symbol shr 4;
      Size := Symbol and 15;
      if Size = 0 then
      begin
        if Run < 15 then
        begin
          State.EndOfBandRun := (1 shl Run) - 1;
          if Run > 0 then
            State.EndOfBandRun := State.EndOfBandRun + ReadBits(Reader, Run);
          Break;
        end;
        Inc(Position, 16);
      end
      else
      begin
        Inc(Position, Run);
        if Position > 63 then
          Break;
        Block[ZigzagToNatural[Position]] := SmallInt(ReceiveAndExtend(Reader, Size) * (1 shl Scan.ApproximationLow));
        Inc(Position);
      end;
    end;
end;

procedure RefineCoefficient(var Reader: TJpegBitReader; Coefficient: PSmallInt; PositiveBit, NegativeBit: LongInt);
  inline;
begin
  if ReadBit(Reader) <> 0 then
    if (Coefficient^ and PositiveBit) = 0 then
    begin
      if Coefficient^ >= 0 then
        Coefficient^ := SmallInt(Coefficient^ + PositiveBit)
      else
        Coefficient^ := SmallInt(Coefficient^ + NegativeBit);
    end;
end;

procedure DecodeAcRefine(State: TJpegState; var Reader: TJpegBitReader; constref Scan: TJpegScan;
  ComponentIndex, BlockRow, BlockColumn: LongInt);
var
  Block: PSmallInt;
  Position: LongInt;
  Symbol: LongInt;
  Run: LongInt;
  NewValue: LongInt;
  PositiveBit: LongInt;
  NegativeBit: LongInt;
  Coefficient: PSmallInt;
begin
  Block := BlockCoefficients(State, ComponentIndex, BlockRow, BlockColumn);
  PositiveBit := 1 shl Scan.ApproximationLow;
  NegativeBit := -1 * PositiveBit;
  Position := Scan.SpectralStart;
  if State.EndOfBandRun = 0 then
    with State.Frame.Components[ComponentIndex] do
      while Position <= Scan.SpectralEnd do
      begin
        Symbol := DecodeHuffman(Reader, State.AcTables[AcTableIndex]);
        Run := Symbol shr 4;
        NewValue := 0;
        if (Symbol and 15) <> 0 then
        begin
          if ReadBit(Reader) <> 0 then
            NewValue := PositiveBit
          else
            NewValue := NegativeBit;
        end
        else if Run <> 15 then
        begin
          State.EndOfBandRun := 1 shl Run;
          if Run > 0 then
            State.EndOfBandRun := State.EndOfBandRun + ReadBits(Reader, Run);
          Break;
        end;
        while Position <= Scan.SpectralEnd do
        begin
          Coefficient := Block + ZigzagToNatural[Position];
          if Coefficient^ <> 0 then
            RefineCoefficient(Reader, Coefficient, PositiveBit, NegativeBit)
          else
          begin
            Dec(Run);
            if Run < 0 then
              Break;
          end;
          Inc(Position);
        end;
        if (NewValue <> 0) and (Position <= 63) then
          Block[ZigzagToNatural[Position]] := SmallInt(NewValue);
        Inc(Position);
      end;
  if State.EndOfBandRun > 0 then
  begin
    while Position <= Scan.SpectralEnd do
    begin
      Coefficient := Block + ZigzagToNatural[Position];
      if Coefficient^ <> 0 then
        RefineCoefficient(Reader, Coefficient, PositiveBit, NegativeBit);
      Inc(Position);
    end;
    Dec(State.EndOfBandRun);
  end;
end;

procedure DecodeProgressiveScan(State: TJpegState; constref Scan: TJpegScan; var Reader: TJpegBitReader);
begin
  if Scan.SpectralStart = 0 then
  begin
    if Scan.ApproximationHigh = 0 then
      WalkScan(State, Scan, Reader, @DecodeDcFirst)
    else
      WalkScan(State, Scan, Reader, @DecodeDcRefine);
  end
  else if Scan.ApproximationHigh = 0 then
    WalkScan(State, Scan, Reader, @DecodeAcFirst)
  else
    WalkScan(State, Scan, Reader, @DecodeAcRefine);
end;

procedure FinishProgressiveFrame(State: TJpegState);
var
  ComponentIndex: LongInt;
  BlockRow: LongInt;
  BlockColumn: LongInt;
begin
  for ComponentIndex := 0 to State.Frame.ComponentCount - 1 do
    with State.Frame.Components[ComponentIndex] do
      for BlockRow := 0 to StoredBlocksPerColumn - 1 do
        for BlockColumn := 0 to StoredBlocksPerLine - 1 do
          InverseDctBlock(BlockCoefficients(State, ComponentIndex, BlockRow, BlockColumn), @Quantization[0],
            @Plane[PtrInt(BlockRow) * 8 * PlaneStride + BlockColumn * 8], PlaneStride);
end;

end.
