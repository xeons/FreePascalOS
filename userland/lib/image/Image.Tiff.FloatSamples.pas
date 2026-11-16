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
  TIFF's floating point samples (SampleFormat 3): IEEE half (16-bit)
  and single (32-bit) precision, and the floating point predictor
  (Predictor 3, Adobe's Technical Note 3).

  The predictor stores each line's samples with their bytes regrouped,
  the most significant byte of every sample first, then the next byte
  of every sample, and so on, and then as differences from the byte one
  pixel to the left. Undoing it gives the samples back in the file's
  byte order, so they are read as any other 16- or 32-bit samples.

  Floating point samples are light from 0 (black) to 1 (white), tone
  mapped to 8 bits: when the brightest colour sample of the page is
  above 1 (high dynamic range, or values meant as 0 to 255), the page is
  scaled down by it; then values are clamped to 0..1 and rounded to
  0..255. Not-a-number is 0. Alpha is only clamped.
}
unit Image.Tiff.FloatSamples;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

{ Undoes the floating point predictor on Rows lines of RowBytes bytes,
  each SamplesPerRow samples of BytesPerSample bytes, SamplesPerPixel to
  a pixel; the result is in the file's byte order. }
procedure UndoFloatingPointPredictor(Data: PByte; Rows: LongInt; RowBytes: PtrInt; SamplesPerRow, SamplesPerPixel,
  BytesPerSample: LongInt; BigEndian: Boolean);
{ A sample's bits (16 or 32 of them) as a number. }
function FloatSampleValue(Bits: LongWord; BitsPerSample: LongInt): Single;
{ The value scaled by Scale, clamped to 0..1 and made 0..255. }
function FloatToByte(Value: Single; Scale: Single): LongWord;

implementation

uses
  Math;

procedure UndoFloatingPointPredictor(Data: PByte; Rows: LongInt; RowBytes: PtrInt; SamplesPerRow, SamplesPerPixel,
  BytesPerSample: LongInt; BigEndian: Boolean);
var
  Row: LongInt;
  Line: PByte;
  Count: PtrInt;
  Index: PtrInt;
  Sample: PtrInt;
  ByteIndex: LongInt;
  Grouped: array of Byte;
begin
  Count := PtrInt(SamplesPerRow) * BytesPerSample;
  if (Count <= 0) or (Count > RowBytes) then
    Exit;
  Grouped := nil;
  SetLength(Grouped, Count);
  for Row := 0 to Rows - 1 do
  begin
    Line := Data + PtrInt(Row) * RowBytes;
    for Index := SamplesPerPixel to Count - 1 do
      Line[Index] := Byte(Line[Index] + Line[Index - SamplesPerPixel]);
    Move(Line^, Grouped[0], Count);
    for Sample := 0 to SamplesPerRow - 1 do
      for ByteIndex := 0 to BytesPerSample - 1 do
        if BigEndian then
          Line[PtrInt(BytesPerSample) * Sample + ByteIndex] := Grouped[PtrInt(ByteIndex) * SamplesPerRow + Sample]
        else
          Line[PtrInt(BytesPerSample) * Sample + ByteIndex] :=
            Grouped[PtrInt(BytesPerSample - 1 - ByteIndex) * SamplesPerRow + Sample];
  end;
end;

function HalfToSingle(Bits: Word): Single;
var
  Sign: Single;
  Exponent: LongInt;
  Mantissa: LongInt;
begin
  if (Bits and $8000) <> 0 then
    Sign := -1
  else
    Sign := 1;
  Exponent := (Bits shr 10) and $1F;
  Mantissa := Bits and $3FF;
  if Exponent = 0 then
    Result := Sign * Mantissa * Power(2, -24)
  else if Exponent = 31 then
  begin
    if Mantissa = 0 then
      Result := Sign * Infinity
    else
      Result := NaN;
  end
  else
    Result := Sign * (1 + Mantissa / 1024) * Power(2, Exponent - 15);
end;

function FloatSampleValue(Bits: LongWord; BitsPerSample: LongInt): Single;
begin
  if BitsPerSample = 16 then
    Result := HalfToSingle(Word(Bits and $FFFF))
  else
    Result := PSingle(@Bits)^;
end;

function FloatToByte(Value: Single; Scale: Single): LongWord;
begin
  if IsNan(Value) then
    Exit(0);
  Value := Value * Scale;
  if Value <= 0 then
    Result := 0
  else if Value >= 1 then
    Result := 255
  else
    Result := Round(Value * 255);
end;

end.
