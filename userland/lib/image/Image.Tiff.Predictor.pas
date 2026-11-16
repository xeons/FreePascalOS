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
  TIFF's horizontal predictor (Predictor 2): each sample of a line is
  stored as its difference from the same sample of the pixel to its
  left, modulo 2 to the bits; the first pixel of each line is as it is.
  Lines are those of a strip or tile, so the predictor runs within one
  chunk. 8-bit and 16-bit samples (16-bit in the file's byte order).
}
unit Image.Tiff.Predictor;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

{ Undoes the predictor on Rows lines of RowBytes bytes at Data, each
  of PixelsPerRow pixels of SamplesPerPixel samples of Bits bits. }
procedure UndoHorizontalPredictor(Data: PByte; Rows, RowBytes, PixelsPerRow, SamplesPerPixel, Bits: LongInt;
  BigEndian: Boolean);
{ Applies it (for writing 8-bit samples). }
procedure ApplyHorizontalPredictor(Data: PByte; Rows, RowBytes, PixelsPerRow, SamplesPerPixel: LongInt);

implementation

function ReadSample16(Data: PByte; BigEndian: Boolean): Word; inline;
begin
  if BigEndian then
    Result := (Word(Data[0]) shl 8) or Data[1]
  else
    Result := (Word(Data[1]) shl 8) or Data[0];
end;

procedure WriteSample16(Data: PByte; Value: Word; BigEndian: Boolean); inline;
begin
  if BigEndian then
  begin
    Data[0] := Value shr 8;
    Data[1] := Value and $FF;
  end
  else
  begin
    Data[0] := Value and $FF;
    Data[1] := Value shr 8;
  end;
end;

procedure UndoHorizontalPredictor(Data: PByte; Rows, RowBytes, PixelsPerRow, SamplesPerPixel, Bits: LongInt;
  BigEndian: Boolean);
var
  Row: LongInt;
  Line: PByte;
  Index: LongInt;
  SampleCount: LongInt;
  Sum: Word;
begin
  SampleCount := PixelsPerRow * SamplesPerPixel;
  for Row := 0 to Rows - 1 do
  begin
    Line := Data + PtrInt(Row) * RowBytes;
    if Bits = 8 then
      for Index := SamplesPerPixel to SampleCount - 1 do
        Line[Index] := Byte(Line[Index] + Line[Index - SamplesPerPixel])
    else
      for Index := SamplesPerPixel to SampleCount - 1 do
      begin
        Sum := Word(ReadSample16(Line + 2 * Index, BigEndian) +
          ReadSample16(Line + 2 * (Index - SamplesPerPixel), BigEndian));
        WriteSample16(Line + 2 * Index, Sum, BigEndian);
      end;
  end;
end;

procedure ApplyHorizontalPredictor(Data: PByte; Rows, RowBytes, PixelsPerRow, SamplesPerPixel: LongInt);
var
  Row: LongInt;
  Line: PByte;
  Index: LongInt;
begin
  for Row := 0 to Rows - 1 do
  begin
    Line := Data + PtrInt(Row) * RowBytes;
    Index := PixelsPerRow * SamplesPerPixel - 1;
    while Index >= SamplesPerPixel do
    begin
      Line[Index] := Byte(Line[Index] - Line[Index - SamplesPerPixel]);
      Dec(Index);
    end;
  end;
end;

end.
