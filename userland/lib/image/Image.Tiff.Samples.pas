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
  One line of a TIFF page's samples taken out of its planes
  (Image.Tiff.Strips) as plain numbers: SamplesPerPixel values a pixel,
  pixel after pixel, each as stored (0 to 2 to the bits, less one).

  Samples of fewer than 8 bits are packed from the highest bit of each
  byte; 16- and 32-bit ones are in the file's byte order (32-bit ones
  are floating point, given as their bits). Subsampled YCbCr
  gives each pixel the luma of its own and the Cb and Cr of its block.
}
unit Image.Tiff.Samples;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Image.Tiff.Pages,
  Image.Tiff.Strips;

type
  TTiffSampleLine = array of LongWord;

{ Line Y's samples into Samples (Width x SamplesPerPixel values). }
procedure ExtractSampleLine(constref Page: TTiffPage; constref Planes: TTiffPlanes; Y: LongInt;
  var Samples: TTiffSampleLine);

implementation

{ The Bits-bit value starting at bit BitOffset of Line. }
function ReadBits(Line: PByte; BitOffset: PtrInt; Bits: LongInt; BigEndian: Boolean): LongWord;
var
  Position: PtrInt;
  Shift: LongInt;
  Value: LongWord;
  Taken: LongInt;
begin
  case Bits of
    8:
      Exit(Line[BitOffset shr 3]);
    16:
      begin
        Position := BitOffset shr 3;
        if BigEndian then
          Exit((LongWord(Line[Position]) shl 8) or Line[Position + 1])
        else
          Exit((LongWord(Line[Position + 1]) shl 8) or Line[Position]);
      end;
    32:
      begin
        Position := BitOffset shr 3;
        if BigEndian then
          Exit((LongWord(Line[Position]) shl 24) or (LongWord(Line[Position + 1]) shl 16) or
            (LongWord(Line[Position + 2]) shl 8) or Line[Position + 3])
        else
          Exit((LongWord(Line[Position + 3]) shl 24) or (LongWord(Line[Position + 2]) shl 16) or
            (LongWord(Line[Position + 1]) shl 8) or Line[Position]);
      end;
  end;
  Value := 0;
  Taken := 0;
  while Taken < Bits do
  begin
    Position := (BitOffset + Taken) shr 3;
    Shift := 7 - ((BitOffset + Taken) and 7);
    Value := (Value shl 1) or ((LongWord(Line[Position]) shr Shift) and 1);
    Inc(Taken);
  end;
  Result := Value;
end;

procedure ExtractSubsampled(constref Page: TTiffPage; constref Planes: TTiffPlanes; Y: LongInt;
  var Samples: TTiffSampleLine);
var
  Line: PByte;
  BlockBytes: LongInt;
  LumaIndex: LongInt;
  Block: PByte;
  X: LongInt;
begin
  Line := @Planes.Planes[0][PtrInt(Y div Planes.UnitHeight) * Planes.LineBytes];
  BlockBytes := Planes.UnitWidth * Planes.UnitHeight + 2;
  for X := 0 to Page.Width - 1 do
  begin
    Block := Line + PtrInt(X div Planes.UnitWidth) * BlockBytes;
    LumaIndex := (Y mod Planes.UnitHeight) * Planes.UnitWidth + (X mod Planes.UnitWidth);
    Samples[3 * X] := Block[LumaIndex];
    Samples[3 * X + 1] := Block[BlockBytes - 2];
    Samples[3 * X + 2] := Block[BlockBytes - 1];
  end;
end;

procedure ExtractSampleLine(constref Page: TTiffPage; constref Planes: TTiffPlanes; Y: LongInt;
  var Samples: TTiffSampleLine);
var
  Line: PByte;
  X: LongInt;
  Sample: LongInt;
  Count: LongInt;
  Bits: LongInt;
  Index: PtrInt;
begin
  Count := Page.SamplesPerPixel;
  if Length(Samples) < PtrInt(Page.Width) * Count then
    SetLength(Samples, PtrInt(Page.Width) * Count);
  if Planes.Subsampled then
  begin
    ExtractSubsampled(Page, Planes, Y, Samples);
    Exit;
  end;
  Bits := Page.BitsPerSample;
  if Planes.PlaneCount = 1 then
  begin
    Line := @Planes.Planes[0][PtrInt(Y) * Planes.LineBytes];
    if Bits = 8 then
      for Index := 0 to PtrInt(Page.Width) * Count - 1 do
        Samples[Index] := Line[Index]
    else
      for Index := 0 to PtrInt(Page.Width) * Count - 1 do
        Samples[Index] := ReadBits(Line, Index * Bits, Bits, Planes.BigEndian);
  end
  else
    for Sample := 0 to Count - 1 do
    begin
      Line := @Planes.Planes[Sample][PtrInt(Y) * Planes.LineBytes];
      for X := 0 to Page.Width - 1 do
        Samples[PtrInt(X) * Count + Sample] := ReadBits(Line, PtrInt(X) * Bits, Bits, Planes.BigEndian);
    end;
end;

end.
