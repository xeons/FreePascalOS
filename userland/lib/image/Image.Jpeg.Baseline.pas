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
  Sequential scans (baseline and extended Huffman frames): each block
  comes whole, a DC difference then run-length coded AC coefficients up
  to an end of block, so it is turned into samples at once (inverse DCT
  straight into the component's plane) and no coefficients are kept.
}
unit Image.Jpeg.Baseline;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Jpeg.Huffman,
  Image.Jpeg.Frames,
  Image.Jpeg.Scans;

procedure DecodeSequentialScan(State: TJpegState; constref Scan: TJpegScan; var Reader: TJpegBitReader);

implementation

uses
  Image.Jpeg.Idct;

procedure DecodeSequentialBlock(State: TJpegState; var Reader: TJpegBitReader; constref Scan: TJpegScan;
  ComponentIndex, BlockRow, BlockColumn: LongInt);
var
  Block: array[0..63] of SmallInt;
  Position: LongInt;
  Symbol: LongInt;
  Run: LongInt;
  Size: LongInt;
begin
  FillChar(Block, SizeOf(Block), 0);
  with State.Frame.Components[ComponentIndex] do
  begin
    Symbol := DecodeHuffman(Reader, State.DcTables[DcTableIndex]);
    DcPredictor := DcPredictor + ReceiveAndExtend(Reader, Symbol);
    Block[0] := SmallInt(DcPredictor);
    Position := 1;
    while Position < 64 do
    begin
      Symbol := DecodeHuffman(Reader, State.AcTables[AcTableIndex]);
      Run := Symbol shr 4;
      Size := Symbol and 15;
      if Size = 0 then
      begin
        if Run <> 15 then
          Break;
        Inc(Position, 16);
      end
      else
      begin
        Inc(Position, Run);
        if Position > 63 then
          Break;
        Block[ZigzagToNatural[Position]] := SmallInt(ReceiveAndExtend(Reader, Size));
        Inc(Position);
      end;
    end;
    InverseDctBlock(@Block[0], @Quantization[0], @Plane[PtrInt(BlockRow) * 8 * PlaneStride + BlockColumn * 8],
      PlaneStride);
  end;
end;

procedure DecodeSequentialScan(State: TJpegState; constref Scan: TJpegScan; var Reader: TJpegBitReader);
begin
  WalkScan(State, Scan, Reader, @DecodeSequentialBlock);
end;

end.
