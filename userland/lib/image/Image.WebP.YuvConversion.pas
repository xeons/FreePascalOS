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
  A lossy picture's Y'CbCr 4:2:0 planes turned into colours as libwebp
  turns them, so the pixels are libwebp's (and Pillow's) exactly.

  Chroma is upsampled "fancily": each output pixel's chroma is
  (9 x the nearest sample + 3 x each of the two next + the far one + 8)
  / 16 of the four samples around it, worked two lines at a time
  (libwebp's line pairs: the first and, for an even height, the last
  line on their own, with the chroma line repeated). Colours are BT.601
  limited range in libwebp's 14-bit fixed point:
  R = 1.164 (Y - 16) + 1.596 (V - 128), and so on.
}
unit Image.WebP.YuvConversion;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Model,
  Image.WebP.LossyDecoder;

{ The picture of Planes, with Alpha (Width x Height bytes) as its
  alpha, or opaque when Alpha is nil. }
function LossyPlanesToImage(constref Planes: TLossyPlanes; Alpha: PByte): TImage;

implementation

function MultiplyHigh(Value, Factor: LongInt): LongInt; inline;
begin
  Result := (Value * Factor) shr 8;
end;

function ClipToByte(Value: LongInt): LongWord; inline;
begin
  if (Value and not 16383) = 0 then
    Result := Value shr 6
  else if Value < 0 then
    Result := 0
  else
    Result := 255;
end;

function YuvToColor(Y, U, V: LongInt): LongWord; inline;
var
  Red: LongWord;
  Green: LongWord;
  Blue: LongWord;
begin
  Red := ClipToByte(MultiplyHigh(Y, 19077) + MultiplyHigh(V, 26149) - 14234);
  Green := ClipToByte(MultiplyHigh(Y, 19077) - MultiplyHigh(U, 6419) - MultiplyHigh(V, 13320) + 8708);
  Blue := ClipToByte(MultiplyHigh(Y, 19077) + MultiplyHigh(U, 33050) - 17685);
  Result := $FF000000 or (Red shl 16) or (Green shl 8) or Blue;
end;

{ The chroma of one channel for the two pixels of each pair along a
  line: Near is the line's own chroma, Far the other line's. }
procedure UpsampleLine(YLine: PByte; NearU, NearV, FarU, FarV: PByte; Target: PLongWord; Length: LongInt);
var
  X: LongInt;
  LastPair: LongInt;
  FarLeftU, NearLeftU, FarLeftV, NearLeftV: LongInt;
  FarU1, NearU1, FarV1, NearV1: LongInt;
  AverageU, AverageV: LongInt;
  DiagonalFarU, DiagonalNearU, DiagonalFarV, DiagonalNearV: LongInt;
begin
  LastPair := (Length - 1) shr 1;
  FarLeftU := FarU[0];
  NearLeftU := NearU[0];
  FarLeftV := FarV[0];
  NearLeftV := NearV[0];
  Target[0] := YuvToColor(YLine[0], (3 * NearLeftU + FarLeftU + 2) shr 2, (3 * NearLeftV + FarLeftV + 2) shr 2);
  for X := 1 to LastPair do
  begin
    FarU1 := FarU[X];
    NearU1 := NearU[X];
    FarV1 := FarV[X];
    NearV1 := NearV[X];
    AverageU := FarLeftU + FarU1 + NearLeftU + NearU1 + 8;
    AverageV := FarLeftV + FarV1 + NearLeftV + NearV1 + 8;
    { libwebp's diagonals: one through the far left and near right
      samples, one through the far right and near left ones. }
    DiagonalFarU := (AverageU + 2 * (FarU1 + NearLeftU)) shr 3;
    DiagonalNearU := (AverageU + 2 * (FarLeftU + NearU1)) shr 3;
    DiagonalFarV := (AverageV + 2 * (FarV1 + NearLeftV)) shr 3;
    DiagonalNearV := (AverageV + 2 * (FarLeftV + NearV1)) shr 3;
    Target[2 * X - 1] := YuvToColor(YLine[2 * X - 1], (DiagonalNearU + NearLeftU) shr 1,
      (DiagonalNearV + NearLeftV) shr 1);
    Target[2 * X] := YuvToColor(YLine[2 * X], (DiagonalFarU + NearU1) shr 1, (DiagonalFarV + NearV1) shr 1);
    FarLeftU := FarU1;
    NearLeftU := NearU1;
    FarLeftV := FarV1;
    NearLeftV := NearV1;
  end;
  if (Length and 1) = 0 then
    Target[Length - 1] := YuvToColor(YLine[Length - 1], (3 * NearLeftU + FarLeftU + 2) shr 2,
      (3 * NearLeftV + FarLeftV + 2) shr 2);
end;

function LossyPlanesToImage(constref Planes: TLossyPlanes; Alpha: PByte): TImage;
var
  Image: TImage;
  Width: LongInt;
  Height: LongInt;
  Luma: PByte;
  ChromaU: PByte;
  ChromaV: PByte;
  Pair: LongInt;
  Line: LongInt;
  Index: PtrInt;
  Pixels: PLongWord;

  function LumaLine(Y: LongInt): PByte;
  begin
    Result := Luma + PtrInt(Y) * Planes.LumaStride;
  end;

  function ULine(Y: LongInt): PByte;
  begin
    Result := ChromaU + PtrInt(Y) * Planes.ChromaStride;
  end;

  function VLine(Y: LongInt): PByte;
  begin
    Result := ChromaV + PtrInt(Y) * Planes.ChromaStride;
  end;

begin
  Width := Planes.Width;
  Height := Planes.Height;
  Image := TImage.Create(Width, Height);
  try
    Luma := @Planes.Luma[0];
    ChromaU := @Planes.ChromaU[0];
    ChromaV := @Planes.ChromaV[0];
    UpsampleLine(LumaLine(0), ULine(0), VLine(0), ULine(0), VLine(0), Image.Line(0), Width);
    Pair := 1;
    while 2 * Pair < Height do
    begin
      { Lines 2 Pair - 1 and 2 Pair, between chroma lines Pair - 1 and
        Pair. }
      Line := 2 * Pair - 1;
      UpsampleLine(LumaLine(Line), ULine(Pair - 1), VLine(Pair - 1), ULine(Pair), VLine(Pair), Image.Line(Line),
        Width);
      UpsampleLine(LumaLine(Line + 1), ULine(Pair), VLine(Pair), ULine(Pair - 1), VLine(Pair - 1),
        Image.Line(Line + 1), Width);
      Inc(Pair);
    end;
    if (Height and 1) = 0 then
      UpsampleLine(LumaLine(Height - 1), ULine(Pair - 1), VLine(Pair - 1), ULine(Pair - 1), VLine(Pair - 1),
        Image.Line(Height - 1), Width);
    if Alpha <> nil then
    begin
      Pixels := Image.Pixels;
      for Index := 0 to PtrInt(Width) * Height - 1 do
        Pixels[Index] := (Pixels[Index] and $00FFFFFF) or (LongWord(Alpha[Index]) shl 24);
    end;
  except
    Image.Free;
    raise;
  end;
  Result := Image;
end;

end.
