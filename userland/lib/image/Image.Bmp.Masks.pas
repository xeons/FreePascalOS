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
  Colour masks (BMP's bit fields): which bits of a 16 or 32-bit pixel
  hold a channel. A field is the mask's lowest set bit and how many bits
  it spans (contiguous, as the format requires; bits above a gap are
  ignored). A value of N bits becomes 0 to 255 by value * 255 / (2^N - 1),
  rounded, so full scale is 255 at any width; an empty mask reads as 0.
}
unit Image.Bmp.Masks;

{$mode objfpc}
{$H+}

interface

type
  TColorField = record
    Shift: LongInt;
    Bits: LongInt;
    Maximum: LongWord;
  end;

function MakeColorField(Mask: LongWord): TColorField;
{ The channel's value in Pixel, 0 to 255. }
function ExtractField(const Field: TColorField; Pixel: LongWord): Byte; inline;

implementation

function MakeColorField(Mask: LongWord): TColorField;
begin
  Result.Shift := 0;
  Result.Bits := 0;
  Result.Maximum := 0;
  if Mask = 0 then
    Exit;
  while (Mask and 1) = 0 do
  begin
    Mask := Mask shr 1;
    Inc(Result.Shift);
  end;
  while ((Mask and 1) <> 0) and (Result.Bits < 32) do
  begin
    Mask := Mask shr 1;
    Inc(Result.Bits);
  end;
  Result.Maximum := LongWord((QWord(1) shl Result.Bits) - 1);
end;

function ExtractField(const Field: TColorField; Pixel: LongWord): Byte;
var
  Value: QWord;
begin
  if Field.Bits = 0 then
    Exit(0);
  Value := (Pixel shr Field.Shift) and Field.Maximum;
  if Field.Bits = 8 then
    Exit(Byte(Value));
  Result := Byte((Value * 255 + Field.Maximum div 2) div Field.Maximum);
end;

end.
