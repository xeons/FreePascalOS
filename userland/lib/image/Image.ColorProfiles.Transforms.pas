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
  A profile's colours turned into sRGB, fast: everything is worked out
  once into tables, and a pixel then costs a few lookups.

    matrix/TRC (RGB)  three tables from the 8-bit value to linear light
                      (16 bits), one 3 x 3 matrix in 16.16 fixed point
                      from the profile's linear RGB through the PCS to
                      linear sRGB, and a table of 16384 entries from
                      linear sRGB to the 8-bit encoded value
    grey (kTRC)       one table of 256: the grey's luminance is that of
                      sRGB grey
    LUT (A2B0)        the LUT evaluated on a 33 x 33 x 33 grid of RGB
                      values (or 256 greys) once, into encoded sRGB of 16
                      bits; pixels are interpolated trilinearly in it

  As LittleCMS does, a LUT is preferred to the colorants when a profile
  has both, and the intent is relative colorimetric: the profile's
  white becomes sRGB's white, and colours sRGB cannot show are clipped.

  The colorants of a profile are meant to be adapted to D50 already
  (version 4 says how in its chad tag). Some old version 2 profiles
  give them under their own white instead (they then add up to the
  media white point, not D50); those are adapted to D50 here, by the
  chad matrix when there is one and with Bradford's method from the
  media white point otherwise.

  A profile that is sRGB itself (its matrix is the identity to within
  0.003 and its curves sRGB's to within half a level) needs nothing.
}
unit Image.ColorProfiles.Transforms;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.ColorProfiles.Matrices,
  Image.ColorProfiles.Curves,
  Image.ColorProfiles.Luts,
  Image.ColorProfiles.Reading;

const
  LinearOne = 65535;
  EncodeTableSize = 16384;
  GridSize = 33;

type
  TSrgbTransformKind = (
    { Nothing to do: the profile is sRGB. }
    SrgbTransformNone,
    SrgbTransformMatrixShaper,
    SrgbTransformGrey,
    SrgbTransformGrid
  );

  TSrgbTransform = class
  private
    FKind: TSrgbTransformKind;
    FLinear: array[0..2, 0..255] of LongInt;
    FMatrix: array[0..2, 0..2] of Int64;
    FEncode: array[0..EncodeTableSize - 1] of Byte;
    FGreyTable: array[0..255] of Byte;
    FGrid: array of Word;
    FGridIndex: array[0..255] of LongInt;
    FGridFraction: array[0..255] of LongInt;
    procedure BuildEncodeTable;
    procedure BuildGridAxis;
    procedure ConvertMatrixShaper(Pixels: PLongWord; Count: PtrInt);
    procedure ConvertGrey(Pixels: PLongWord; Count: PtrInt);
    procedure ConvertGrid(Pixels: PLongWord; Count: PtrInt);
  public
    { The profile's colorants (adapted to D50) and curves. }
    constructor CreateMatrixShaper(const Colorants: TColorMatrix; const Curves: array of TToneCurve);
    constructor CreateGrey(constref Curve: TToneCurve);
    { Lut maps RGB (InputChannels 3) or grey (1) to the PCS. }
    constructor CreateFromLut(constref Lut: TIccLut; PcsIsLab: Boolean);
    { Converts the colour of Count $AARRGGBB pixels in place; alpha
      stays as it is. }
    procedure ConvertPixels(Pixels: PLongWord; Count: PtrInt);
    property Kind: TSrgbTransformKind read FKind;
  end;

{ The colorants of an RGB profile as a matrix to the PCS, adapted to
  D50 if they were not (see above). }
function AdaptedColorants(constref Profile: TIccProfile): TColorMatrix;

implementation

uses
  Math;

const
  MatrixShift = 16;
  { A grid value's interpolation weights are 8-bit. }
  FractionBits = 8;
  FractionOne = 1 shl FractionBits;
  SameMatrixTolerance = 0.003;
  { Far beyond any real matrix, and small enough for 64-bit sums. }
  LargestCoefficient = 1000000.0;
  SameCurveTolerance = 0.5 / 255;

function ClampValue(Value, Low, High: Int64): Int64; inline;
begin
  if Value < Low then
    Result := Low
  else if Value > High then
    Result := High
  else
    Result := Value;
end;

function AdaptedColorants(constref Profile: TIccProfile): TColorMatrix;
var
  White: TColorVector;
begin
  Result := MatrixFromColumns(Profile.RedColorant, Profile.GreenColorant, Profile.BlueColorant);
  White := ApplyMatrix(Result, MakeVector(1, 1, 1));
  if VectorDistance(White, WhiteD50) < 0.02 then
    Exit;
  if Profile.HasAdaptation and (MatrixDistance(Profile.Adaptation, IdentityMatrix) > 1e-6) then
    Result := MultiplyMatrices(Profile.Adaptation, Result)
  else if Profile.HasMediaWhite and (VectorDistance(White, Profile.MediaWhite) < 0.02) then
    Result := MultiplyMatrices(BradfordAdaptation(Profile.MediaWhite, WhiteD50), Result);
end;

function CurvesAreSrgb(const Curves: array of TToneCurve): Boolean;
var
  Channel: LongInt;
  Value: LongInt;
begin
  for Channel := 0 to 2 do
    for Value := 0 to 255 do
      if Abs(EvaluateToneCurve(Curves[Channel], Value / 255) - SrgbToLinear(Value / 255)) > SameCurveTolerance then
        Exit(False);
  Result := True;
end;

procedure TSrgbTransform.BuildEncodeTable;
var
  Index: LongInt;
  Linear: Double;
begin
  for Index := 0 to EncodeTableSize - 1 do
  begin
    Linear := (Index + 0.5) / EncodeTableSize;
    FEncode[Index] := Round(255 * LinearToSrgb(Linear));
  end;
  FEncode[0] := 0;
  FEncode[EncodeTableSize - 1] := 255;
end;

constructor TSrgbTransform.CreateMatrixShaper(const Colorants: TColorMatrix; const Curves: array of TToneCurve);
var
  Total: TColorMatrix;
  Channel: LongInt;
  Column: LongInt;
  Value: LongInt;
begin
  inherited Create;
  Total := MultiplyMatrices(PcsToSrgbMatrix, Colorants);
  if (MatrixDistance(Total, IdentityMatrix) < SameMatrixTolerance) and CurvesAreSrgb(Curves) then
  begin
    FKind := SrgbTransformNone;
    Exit;
  end;
  FKind := SrgbTransformMatrixShaper;
  for Channel := 0 to 2 do
    for Value := 0 to 255 do
      FLinear[Channel, Value] := Round(EnsureRange(EvaluateToneCurve(Curves[Channel], Value / 255), 0, 1) *
        LinearOne);
  for Channel := 0 to 2 do
    for Column := 0 to 2 do
      FMatrix[Channel, Column] := Round(EnsureRange(Total[Channel, Column], -LargestCoefficient, LargestCoefficient) *
        (1 shl MatrixShift));
  BuildEncodeTable;
end;

constructor TSrgbTransform.CreateGrey(constref Curve: TToneCurve);
var
  Value: LongInt;
  Luminance: Double;
begin
  inherited Create;
  FKind := SrgbTransformGrey;
  for Value := 0 to 255 do
  begin
    Luminance := EvaluateToneCurve(Curve, Value / 255);
    FGreyTable[Value] := Round(255 * LinearToSrgb(Luminance));
  end;
end;

{ The PCS colour as encoded sRGB, 0 to 65535 a channel. }
procedure PcsToEncodedSrgb(const ToSrgb: TColorMatrix; const Pcs: TColorVector; out Red, Green, Blue: Word);
var
  Linear: TColorVector;
begin
  Linear := ApplyMatrix(ToSrgb, Pcs);
  Red := Round(65535 * LinearToSrgb(Linear[0]));
  Green := Round(65535 * LinearToSrgb(Linear[1]));
  Blue := Round(65535 * LinearToSrgb(Linear[2]));
end;

procedure TSrgbTransform.BuildGridAxis;
var
  Value: LongInt;
  Position: LongInt;
begin
  for Value := 0 to 255 do
  begin
    { Position in the grid in 1/256 steps. }
    Position := (Value * (GridSize - 1) * FractionOne + 127) div 255;
    FGridIndex[Value] := Position shr FractionBits;
    FGridFraction[Value] := Position and (FractionOne - 1);
    if FGridIndex[Value] >= GridSize - 1 then
    begin
      FGridIndex[Value] := GridSize - 2;
      FGridFraction[Value] := FractionOne;
    end;
  end;
end;

constructor TSrgbTransform.CreateFromLut(constref Lut: TIccLut; PcsIsLab: Boolean);
var
  Input: TLutChannels;
  Output: TLutChannels;
  Red: LongInt;
  Green: LongInt;
  Blue: LongInt;
  Value: LongInt;
  Index: PtrInt;
  EncodedRed: Word;
  EncodedGreen: Word;
  EncodedBlue: Word;
  ToSrgb: TColorMatrix;
begin
  inherited Create;
  ToSrgb := PcsToSrgbMatrix;
  Input := Default(TLutChannels);
  if Lut.InputChannels = 1 then
  begin
    FKind := SrgbTransformGrey;
    for Value := 0 to 255 do
    begin
      Input[0] := Value / 255;
      EvaluateIccLut(Lut, Input, Output);
      PcsToEncodedSrgb(ToSrgb, DecodePcs(Lut, Output, PcsIsLab), EncodedRed, EncodedGreen, EncodedBlue);
      FGreyTable[Value] := (LongWord(EncodedGreen) * 255 + 32767) div 65535;
    end;
    Exit;
  end;
  FKind := SrgbTransformGrid;
  SetLength(FGrid, GridSize * GridSize * GridSize * 3);
  Index := 0;
  for Red := 0 to GridSize - 1 do
    for Green := 0 to GridSize - 1 do
      for Blue := 0 to GridSize - 1 do
      begin
        Input[0] := Red / (GridSize - 1);
        Input[1] := Green / (GridSize - 1);
        Input[2] := Blue / (GridSize - 1);
        EvaluateIccLut(Lut, Input, Output);
        PcsToEncodedSrgb(ToSrgb, DecodePcs(Lut, Output, PcsIsLab), EncodedRed, EncodedGreen, EncodedBlue);
        FGrid[Index] := EncodedRed;
        FGrid[Index + 1] := EncodedGreen;
        FGrid[Index + 2] := EncodedBlue;
        Inc(Index, 3);
      end;
  BuildGridAxis;
end;

procedure TSrgbTransform.ConvertMatrixShaper(Pixels: PLongWord; Count: PtrInt);
var
  Index: PtrInt;
  Pixel: LongWord;
  Red: Int64;
  Green: Int64;
  Blue: Int64;
  OutRed: Int64;
  OutGreen: Int64;
  OutBlue: Int64;
const
  Half = Int64(1) shl (MatrixShift - 1);
begin
  for Index := 0 to Count - 1 do
  begin
    Pixel := Pixels[Index];
    Red := FLinear[0, (Pixel shr 16) and $FF];
    Green := FLinear[1, (Pixel shr 8) and $FF];
    Blue := FLinear[2, Pixel and $FF];
    OutRed := ClampValue((FMatrix[0, 0] * Red + FMatrix[0, 1] * Green + FMatrix[0, 2] * Blue + Half) div
      (Int64(1) shl MatrixShift), 0, LinearOne);
    OutGreen := ClampValue((FMatrix[1, 0] * Red + FMatrix[1, 1] * Green + FMatrix[1, 2] * Blue + Half) div
      (Int64(1) shl MatrixShift), 0, LinearOne);
    OutBlue := ClampValue((FMatrix[2, 0] * Red + FMatrix[2, 1] * Green + FMatrix[2, 2] * Blue + Half) div
      (Int64(1) shl MatrixShift), 0, LinearOne);
    Pixels[Index] := (Pixel and $FF000000) or (LongWord(FEncode[OutRed shr 2]) shl 16) or
      (LongWord(FEncode[OutGreen shr 2]) shl 8) or FEncode[OutBlue shr 2];
  end;
end;

procedure TSrgbTransform.ConvertGrey(Pixels: PLongWord; Count: PtrInt);
var
  Index: PtrInt;
  Pixel: LongWord;
begin
  for Index := 0 to Count - 1 do
  begin
    Pixel := Pixels[Index];
    Pixels[Index] := (Pixel and $FF000000) or (LongWord(FGreyTable[(Pixel shr 16) and $FF]) shl 16) or
      (LongWord(FGreyTable[(Pixel shr 8) and $FF]) shl 8) or FGreyTable[Pixel and $FF];
  end;
end;

procedure TSrgbTransform.ConvertGrid(Pixels: PLongWord; Count: PtrInt);
const
  BlueStride = 3;
  GreenStride = 3 * GridSize;
  RedStride = 3 * GridSize * GridSize;
var
  Index: PtrInt;
  Pixel: LongWord;
  RedIndex, GreenIndex, BlueIndex: LongInt;
  RedFraction, GreenFraction, BlueFraction: LongInt;
  Base: PtrInt;
  Channel: LongInt;
  Corner: array[0..7] of LongInt;
  Value: Int64;
  Output: array[0..2] of LongWord;
begin
  for Index := 0 to Count - 1 do
  begin
    Pixel := Pixels[Index];
    RedIndex := FGridIndex[(Pixel shr 16) and $FF];
    GreenIndex := FGridIndex[(Pixel shr 8) and $FF];
    BlueIndex := FGridIndex[Pixel and $FF];
    RedFraction := FGridFraction[(Pixel shr 16) and $FF];
    GreenFraction := FGridFraction[(Pixel shr 8) and $FF];
    BlueFraction := FGridFraction[Pixel and $FF];
    Base := RedIndex * RedStride + GreenIndex * GreenStride + BlueIndex * BlueStride;
    for Channel := 0 to 2 do
    begin
      Corner[0] := FGrid[Base + Channel];
      Corner[1] := FGrid[Base + BlueStride + Channel];
      Corner[2] := FGrid[Base + GreenStride + Channel];
      Corner[3] := FGrid[Base + GreenStride + BlueStride + Channel];
      Corner[4] := FGrid[Base + RedStride + Channel];
      Corner[5] := FGrid[Base + RedStride + BlueStride + Channel];
      Corner[6] := FGrid[Base + RedStride + GreenStride + Channel];
      Corner[7] := FGrid[Base + RedStride + GreenStride + BlueStride + Channel];
      { Along blue, then green, then red. }
      Corner[0] := Corner[0] * FractionOne + (Corner[1] - Corner[0]) * BlueFraction;
      Corner[2] := Corner[2] * FractionOne + (Corner[3] - Corner[2]) * BlueFraction;
      Corner[4] := Corner[4] * FractionOne + (Corner[5] - Corner[4]) * BlueFraction;
      Corner[6] := Corner[6] * FractionOne + (Corner[7] - Corner[6]) * BlueFraction;
      Corner[0] := (Int64(Corner[0]) * FractionOne + Int64(Corner[2] - Corner[0]) * GreenFraction) div FractionOne;
      Corner[4] := (Int64(Corner[4]) * FractionOne + Int64(Corner[6] - Corner[4]) * GreenFraction) div FractionOne;
      Value := Int64(Corner[0]) * FractionOne + Int64(Corner[4] - Corner[0]) * RedFraction;
      { Value is the 16-bit encoded value times FractionOne squared. }
      Output[Channel] := ClampValue((Value * 255 div (Int64(FractionOne) * FractionOne) + 32767) div 65535, 0, 255);
    end;
    Pixels[Index] := (Pixel and $FF000000) or (Output[0] shl 16) or (Output[1] shl 8) or Output[2];
  end;
end;

procedure TSrgbTransform.ConvertPixels(Pixels: PLongWord; Count: PtrInt);
begin
  case FKind of
    SrgbTransformMatrixShaper: ConvertMatrixShaper(Pixels, Count);
    SrgbTransformGrey: ConvertGrey(Pixels, Count);
    SrgbTransformGrid: ConvertGrid(Pixels, Count);
  end;
end;

end.
