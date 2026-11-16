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
  Writing a baseline JPEG: YCbCr with the colour at half width and half
  height (4:2:0), the standard's example quantization tables scaled for
  the quality (as libjpeg does, so the numbers mean the same) and its
  typical Huffman tables.

  The file has a JFIF segment (with the image's resolution as its
  density when there is one), an EXIF segment holding just the
  orientation when it is not the normal one, and the ICC profile in
  APP2 chunks when the image has one. JPEG has no transparency: the
  colours are written as they are and alpha is dropped.

  Edges are filled out to whole MCUs by repeating the last column and
  line, which keeps the padding from bleeding into the picture.
}
unit Image.Jpeg.Encoding;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Model;

{ Image as a JPEG file of Quality 1 to 100. }
function EncodeJpegImage(Image: TImage; Quality: LongInt): TBytes;

implementation

uses
  Image.ByteWriters,
  Image.Jpeg.Frames,
  Image.Jpeg.StandardTables,
  Image.Jpeg.ForwardDct;

type
  THuffmanCodes = record
    Codes: array[0..255] of Word;
    Sizes: array[0..255] of Byte;
  end;

  TJpegBitWriter = record
    Writer: TImageByteWriter;
    Accumulator: QWord;
    BitCount: LongInt;
  end;

  TEncodingTables = record
    Luminance: TJpegQuantizationTable;
    Chrominance: TJpegQuantizationTable;
    LuminanceDc: THuffmanCodes;
    LuminanceAc: THuffmanCodes;
    ChrominanceDc: THuffmanCodes;
    ChrominanceAc: THuffmanCodes;
  end;

const
  IccChunkCapacity = 65519;

procedure BuildHuffmanCodes(out Table: THuffmanCodes; constref Counts: array of Byte; constref Symbols: array of Byte);
var
  Code: LongInt;
  SymbolIndex: LongInt;
  CodeLength: LongInt;
  Index: LongInt;
begin
  FillChar(Table, SizeOf(Table), 0);
  Code := 0;
  SymbolIndex := 0;
  for CodeLength := 1 to 16 do
  begin
    for Index := 1 to Counts[CodeLength - 1] do
    begin
      Table.Codes[Symbols[SymbolIndex]] := Code;
      Table.Sizes[Symbols[SymbolIndex]] := CodeLength;
      Inc(Code);
      Inc(SymbolIndex);
    end;
    Code := Code shl 1;
  end;
end;

procedure PutBits(var Bits: TJpegBitWriter; Value: LongWord; Size: LongInt);
var
  OutputByte: Byte;
begin
  if Size <= 0 then
    Exit;
  Bits.Accumulator := (Bits.Accumulator shl Size) or (Value and ((LongWord(1) shl Size) - 1));
  Inc(Bits.BitCount, Size);
  while Bits.BitCount >= 8 do
  begin
    OutputByte := Byte(Bits.Accumulator shr (Bits.BitCount - 8));
    Bits.Writer.WriteByte(OutputByte);
    if OutputByte = $FF then
      Bits.Writer.WriteByte(0);
    Dec(Bits.BitCount, 8);
  end;
end;

procedure FlushBits(var Bits: TJpegBitWriter);
begin
  if Bits.BitCount > 0 then
    PutBits(Bits, $7F, 8 - Bits.BitCount);
end;

procedure PutSymbol(var Bits: TJpegBitWriter; constref Table: THuffmanCodes; Symbol: LongInt);
begin
  PutBits(Bits, Table.Codes[Symbol], Table.Sizes[Symbol]);
end;

function MagnitudeSize(Value: LongInt): LongInt;
begin
  Value := Abs(Value);
  Result := 0;
  while Value > 0 do
  begin
    Inc(Result);
    Value := Value shr 1;
  end;
end;

procedure PutValue(var Bits: TJpegBitWriter; Value, Size: LongInt);
begin
  if Value < 0 then
    Value := Value - 1;
  PutBits(Bits, LongWord(Value), Size);
end;

procedure EncodeBlock(var Bits: TJpegBitWriter; Samples: PLongInt; constref Quantization: TJpegQuantizationTable;
  constref Dc, Ac: THuffmanCodes; var Predictor: LongInt);
var
  Coefficients: array[0..63] of LongInt;
  Difference: LongInt;
  Size: LongInt;
  Position: LongInt;
  Run: LongInt;
  Value: LongInt;
begin
  ForwardDctBlock(Samples, Quantization, @Coefficients[0]);
  for Position := 0 to 63 do
    if Coefficients[Position] > 1023 then
      Coefficients[Position] := 1023
    else if Coefficients[Position] < -1023 then
      Coefficients[Position] := -1023;
  Difference := Coefficients[0] - Predictor;
  Predictor := Coefficients[0];
  Size := MagnitudeSize(Difference);
  PutSymbol(Bits, Dc, Size);
  PutValue(Bits, Difference, Size);
  Run := 0;
  for Position := 1 to 63 do
  begin
    Value := Coefficients[ZigzagToNatural[Position]];
    if Value = 0 then
    begin
      Inc(Run);
      Continue;
    end;
    while Run > 15 do
    begin
      PutSymbol(Bits, Ac, $F0);
      Dec(Run, 16);
    end;
    Size := MagnitudeSize(Value);
    PutSymbol(Bits, Ac, (Run shl 4) or Size);
    PutValue(Bits, Value, Size);
    Run := 0;
  end;
  if Run > 0 then
    PutSymbol(Bits, Ac, $00);
end;

procedure WriteSegmentStart(Writer: TImageByteWriter; Marker: Byte; PayloadLength: LongInt);
begin
  Writer.WriteByte($FF);
  Writer.WriteByte(Marker);
  Writer.WriteWordBig(PayloadLength + 2);
end;

procedure WriteJfif(Writer: TImageByteWriter; Image: TImage);
var
  Units: Byte;
  HorizontalDensity: LongInt;
  VerticalDensity: LongInt;
begin
  Units := 0;
  HorizontalDensity := 1;
  VerticalDensity := 1;
  if (Image.Resolution.HorizontalDpi >= 1) and (Image.Resolution.VerticalDpi >= 1) and
    (Image.Resolution.HorizontalDpi <= 65535) and (Image.Resolution.VerticalDpi <= 65535) then
  begin
    Units := 1;
    HorizontalDensity := Round(Image.Resolution.HorizontalDpi);
    VerticalDensity := Round(Image.Resolution.VerticalDpi);
  end;
  WriteSegmentStart(Writer, $E0, 14);
  Writer.WriteText('JFIF');
  Writer.WriteByte(0);
  Writer.WriteByte(1);
  Writer.WriteByte(1);
  Writer.WriteByte(Units);
  Writer.WriteWordBig(HorizontalDensity);
  Writer.WriteWordBig(VerticalDensity);
  Writer.WriteByte(0);
  Writer.WriteByte(0);
end;

procedure WriteExifOrientation(Writer: TImageByteWriter; Image: TImage);
begin
  if Image.Orientation = OrientationNormal then
    Exit;
  WriteSegmentStart(Writer, $E1, 32);
  Writer.WriteText('Exif');
  Writer.WriteByte(0);
  Writer.WriteByte(0);
  { A big-endian TIFF header, its directory at 8. }
  Writer.WriteText('MM');
  Writer.WriteWordBig(42);
  Writer.WriteLongBig(8);
  { One entry: Orientation, SHORT, one value, left-justified. }
  Writer.WriteWordBig(1);
  Writer.WriteWordBig($0112);
  Writer.WriteWordBig(3);
  Writer.WriteLongBig(1);
  Writer.WriteWordBig(OrientationToExif(Image.Orientation));
  Writer.WriteWordBig(0);
  { No next directory. }
  Writer.WriteLongBig(0);
end;

procedure WriteIccProfile(Writer: TImageByteWriter; Image: TImage);
var
  Profile: TBytes;
  ChunkCount: LongInt;
  Chunk: LongInt;
  Offset: PtrInt;
  ChunkSize: PtrInt;
begin
  Profile := Image.IccProfile;
  if Length(Profile) = 0 then
    Exit;
  ChunkCount := (Length(Profile) + IccChunkCapacity - 1) div IccChunkCapacity;
  if ChunkCount > 255 then
    Exit;
  Offset := 0;
  for Chunk := 1 to ChunkCount do
  begin
    ChunkSize := Length(Profile) - Offset;
    if ChunkSize > IccChunkCapacity then
      ChunkSize := IccChunkCapacity;
    WriteSegmentStart(Writer, $E2, 14 + ChunkSize);
    Writer.WriteText('ICC_PROFILE');
    Writer.WriteByte(0);
    Writer.WriteByte(Chunk);
    Writer.WriteByte(ChunkCount);
    Writer.WriteBuffer(Profile[Offset], ChunkSize);
    Inc(Offset, ChunkSize);
  end;
end;

procedure WriteQuantizationTables(Writer: TImageByteWriter; constref Tables: TEncodingTables);
var
  Index: LongInt;
begin
  WriteSegmentStart(Writer, $DB, 2 * 65);
  Writer.WriteByte(0);
  for Index := 0 to 63 do
    Writer.WriteByte(Tables.Luminance[ZigzagToNatural[Index]]);
  Writer.WriteByte(1);
  for Index := 0 to 63 do
    Writer.WriteByte(Tables.Chrominance[ZigzagToNatural[Index]]);
end;

procedure WriteFrameHeader(Writer: TImageByteWriter; Image: TImage);
begin
  WriteSegmentStart(Writer, $C0, 15);
  Writer.WriteByte(8);
  Writer.WriteWordBig(Image.Height);
  Writer.WriteWordBig(Image.Width);
  Writer.WriteByte(3);
  Writer.WriteByte(1);
  Writer.WriteByte($22);
  Writer.WriteByte(0);
  Writer.WriteByte(2);
  Writer.WriteByte($11);
  Writer.WriteByte(1);
  Writer.WriteByte(3);
  Writer.WriteByte($11);
  Writer.WriteByte(1);
end;

procedure WriteHuffmanTable(Writer: TImageByteWriter; Header: Byte; constref Counts: array of Byte;
  constref Symbols: array of Byte);
begin
  Writer.WriteByte(Header);
  Writer.WriteBuffer(Counts[0], 16);
  Writer.WriteBuffer(Symbols[0], Length(Symbols));
end;

procedure WriteHuffmanTables(Writer: TImageByteWriter);
begin
  WriteSegmentStart(Writer, $C4, 4 * 17 + Length(LuminanceDcSymbols) + Length(LuminanceAcSymbols) +
    Length(ChrominanceDcSymbols) + Length(ChrominanceAcSymbols));
  WriteHuffmanTable(Writer, $00, LuminanceDcCounts, LuminanceDcSymbols);
  WriteHuffmanTable(Writer, $10, LuminanceAcCounts, LuminanceAcSymbols);
  WriteHuffmanTable(Writer, $01, ChrominanceDcCounts, ChrominanceDcSymbols);
  WriteHuffmanTable(Writer, $11, ChrominanceAcCounts, ChrominanceAcSymbols);
end;

procedure WriteScanHeader(Writer: TImageByteWriter);
begin
  WriteSegmentStart(Writer, $DA, 10);
  Writer.WriteByte(3);
  Writer.WriteByte(1);
  Writer.WriteByte($00);
  Writer.WriteByte(2);
  Writer.WriteByte($11);
  Writer.WriteByte(3);
  Writer.WriteByte($11);
  Writer.WriteByte(0);
  Writer.WriteByte(63);
  Writer.WriteByte(0);
end;

{ The MCU at (Left, Top): 16 x 16 luma samples and 8 x 8 of each
  chroma, averaged over 2 x 2 pixels, all less 128. }
procedure PrepareMcu(Image: TImage; Left, Top: LongInt; Luma: PLongInt; BlueDifference, RedDifference: PLongInt);
var
  X: LongInt;
  Y: LongInt;
  SourceX: LongInt;
  SourceY: LongInt;
  Pixel: LongWord;
  Red: LongInt;
  Green: LongInt;
  Blue: LongInt;
  FullBlue: array[0..255] of LongInt;
  FullRed: array[0..255] of LongInt;
  Index: LongInt;
begin
  for Y := 0 to 15 do
  begin
    SourceY := Top + Y;
    if SourceY >= Image.Height then
      SourceY := Image.Height - 1;
    for X := 0 to 15 do
    begin
      SourceX := Left + X;
      if SourceX >= Image.Width then
        SourceX := Image.Width - 1;
      Pixel := Image.Line(SourceY)[SourceX];
      Red := (Pixel shr 16) and $FF;
      Green := (Pixel shr 8) and $FF;
      Blue := Pixel and $FF;
      Index := Y * 16 + X;
      Luma[Index] := SarLongint(19595 * Red + 38470 * Green + 7471 * Blue + 32768, 16) - 128;
      FullBlue[Index] := -11059 * Red - 21709 * Green + 32768 * Blue;
      FullRed[Index] := 32768 * Red - 27439 * Green - 5329 * Blue;
    end;
  end;
  for Y := 0 to 7 do
    for X := 0 to 7 do
    begin
      Index := Y * 32 + X * 2;
      BlueDifference[Y * 8 + X] := SarLongint(FullBlue[Index] + FullBlue[Index + 1] + FullBlue[Index + 16] +
        FullBlue[Index + 17] + 131072, 18);
      RedDifference[Y * 8 + X] := SarLongint(FullRed[Index] + FullRed[Index + 1] + FullRed[Index + 16] +
        FullRed[Index + 17] + 131072, 18);
    end;
end;

{ Block (BlockX, BlockY) of the MCU's 16 x 16 luma. }
procedure TakeLumaBlock(Luma: PLongInt; BlockX, BlockY: LongInt; Block: PLongInt);
var
  Row: LongInt;
  Column: LongInt;
begin
  for Row := 0 to 7 do
    for Column := 0 to 7 do
      Block[Row * 8 + Column] := Luma[(BlockY * 8 + Row) * 16 + BlockX * 8 + Column];
end;

procedure WriteScanData(Writer: TImageByteWriter; Image: TImage; constref Tables: TEncodingTables);
var
  Bits: TJpegBitWriter;
  Luma: array[0..255] of LongInt;
  BlueDifference: array[0..63] of LongInt;
  RedDifference: array[0..63] of LongInt;
  Block: array[0..63] of LongInt;
  McuX: LongInt;
  McuY: LongInt;
  LumaPredictor: LongInt;
  BluePredictor: LongInt;
  RedPredictor: LongInt;
  BlockIndex: LongInt;
begin
  Bits.Writer := Writer;
  Bits.Accumulator := 0;
  Bits.BitCount := 0;
  LumaPredictor := 0;
  BluePredictor := 0;
  RedPredictor := 0;
  McuY := 0;
  while McuY < Image.Height do
  begin
    McuX := 0;
    while McuX < Image.Width do
    begin
      PrepareMcu(Image, McuX, McuY, @Luma[0], @BlueDifference[0], @RedDifference[0]);
      for BlockIndex := 0 to 3 do
      begin
        TakeLumaBlock(@Luma[0], BlockIndex mod 2, BlockIndex div 2, @Block[0]);
        EncodeBlock(Bits, @Block[0], Tables.Luminance, Tables.LuminanceDc, Tables.LuminanceAc, LumaPredictor);
      end;
      EncodeBlock(Bits, @BlueDifference[0], Tables.Chrominance, Tables.ChrominanceDc, Tables.ChrominanceAc,
        BluePredictor);
      EncodeBlock(Bits, @RedDifference[0], Tables.Chrominance, Tables.ChrominanceDc, Tables.ChrominanceAc,
        RedPredictor);
      Inc(McuX, 16);
    end;
    Inc(McuY, 16);
  end;
  FlushBits(Bits);
end;

function EncodeJpegImage(Image: TImage; Quality: LongInt): TBytes;
var
  Writer: TImageByteWriter;
  Tables: TEncodingTables;
begin
  Tables.Luminance := ScaledQuantizationTable(LuminanceQuantization, Quality);
  Tables.Chrominance := ScaledQuantizationTable(ChrominanceQuantization, Quality);
  BuildHuffmanCodes(Tables.LuminanceDc, LuminanceDcCounts, LuminanceDcSymbols);
  BuildHuffmanCodes(Tables.LuminanceAc, LuminanceAcCounts, LuminanceAcSymbols);
  BuildHuffmanCodes(Tables.ChrominanceDc, ChrominanceDcCounts, ChrominanceDcSymbols);
  BuildHuffmanCodes(Tables.ChrominanceAc, ChrominanceAcCounts, ChrominanceAcSymbols);
  Writer := TImageByteWriter.Create(PtrInt(Image.Width) * Image.Height div 4 + 4096);
  try
    Writer.WriteByte($FF);
    Writer.WriteByte($D8);
    WriteJfif(Writer, Image);
    WriteExifOrientation(Writer, Image);
    WriteIccProfile(Writer, Image);
    WriteQuantizationTables(Writer, Tables);
    WriteFrameHeader(Writer, Image);
    WriteHuffmanTables(Writer);
    WriteScanHeader(Writer);
    WriteScanData(Writer, Image, Tables);
    Writer.WriteByte($FF);
    Writer.WriteByte($D9);
    Result := Writer.ToBytes;
  finally
    Writer.Free;
  end;
end;

end.
