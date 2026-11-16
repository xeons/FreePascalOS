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
  The ALPH chunk: the alpha of a lossy picture. A header byte says how
  it is compressed (0 not at all, 1 as a headerless VP8L stream whose
  green channel is the alpha), how it was filtered (none, horizontal,
  vertical or gradient: each value a difference from its prediction,
  modulo 256) and whether its levels were reduced before (a hint only:
  the values are used as they are, as libwebp does by default).
}
unit Image.WebP.Alpha;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Errors,
  Image.WebP.LosslessDecoder;

const
  AlphaFilterNone = 0;
  AlphaFilterHorizontal = 1;
  AlphaFilterVertical = 2;
  AlphaFilterGradient = 3;

{ The Width x Height alpha values of the ALPH payload of Size bytes at
  Data. }
function DecodeAlphaPlane(Data: PByte; Size: PtrInt; Width, Height: LongInt): TBytes;

{ Undoes Filter on one line (Previous is the line above, nil for the
  first), Input to Output (which may be the same). }
procedure UnfilterAlphaLine(Filter: LongInt; Previous, Input, Output: PByte; Width: LongInt);

implementation

const
  MethodRaw = 0;
  MethodLossless = 1;

function GradientPrediction(Left, Top, TopLeft: LongInt): LongInt; inline;
begin
  Result := Left + Top - TopLeft;
  if Result < 0 then
    Result := 0
  else if Result > 255 then
    Result := 255;
end;

procedure UnfilterAlphaLine(Filter: LongInt; Previous, Input, Output: PByte; Width: LongInt);
var
  X: LongInt;
  Prediction: Byte;
  Top: LongInt;
  TopLeft: LongInt;
  Left: LongInt;
begin
  if (Filter = AlphaFilterNone) then
  begin
    if Output <> Input then
      Move(Input^, Output^, Width);
    Exit;
  end;
  if (Filter = AlphaFilterHorizontal) or (Previous = nil) then
  begin
    if Previous = nil then
      Prediction := 0
    else
      Prediction := Previous[0];
    for X := 0 to Width - 1 do
    begin
      Output[X] := Byte((Prediction + Input[X]) and $FF);
      Prediction := Output[X];
    end;
  end
  else if Filter = AlphaFilterVertical then
  begin
    for X := 0 to Width - 1 do
      Output[X] := Byte((Previous[X] + Input[X]) and $FF);
  end
  else
  begin
    Top := Previous[0];
    TopLeft := Top;
    Left := Top;
    for X := 0 to Width - 1 do
    begin
      Top := Previous[X];
      Left := (Input[X] + GradientPrediction(Left, Top, TopLeft)) and $FF;
      TopLeft := Top;
      Output[X] := Left;
    end;
  end;
end;

function DecodeAlphaPlane(Data: PByte; Size: PtrInt; Width, Height: LongInt): TBytes;
var
  Method: LongInt;
  Filter: LongInt;
  PreProcessing: LongInt;
  Count: PtrInt;
  Pixels: PLongWord;
  Index: PtrInt;
  Y: LongInt;
  Previous: PByte;
  Line: PByte;
begin
  if Size <= 1 then
    RaiseImageError(ImageErrorTruncated, 'ALPH chunk');
  Method := Data[0] and 3;
  Filter := (Data[0] shr 2) and 3;
  PreProcessing := (Data[0] shr 4) and 3;
  if (Method > MethodLossless) or (PreProcessing > 1) or ((Data[0] shr 6) <> 0) then
    RaiseImageError(ImageErrorMalformed, 'ALPH header');
  Count := PtrInt(Width) * Height;
  Result := nil;
  SetLength(Result, Count);
  if Method = MethodRaw then
  begin
    if Size - 1 < Count then
      RaiseImageError(ImageErrorTruncated, 'ALPH data');
    Move(Data[1], Result[0], Count);
  end
  else
  begin
    Pixels := DecodeLosslessPixels(Data + 1, Size - 1, Width, Height);
    try
      for Index := 0 to Count - 1 do
        Result[Index] := (Pixels[Index] shr 8) and $FF;
    finally
      FreeMem(Pixels);
    end;
  end;
  Previous := nil;
  for Y := 0 to Height - 1 do
  begin
    Line := @Result[PtrInt(Y) * Width];
    UnfilterAlphaLine(Filter, Previous, Line, Line, Width);
    Previous := Line;
  end;
end;

end.
