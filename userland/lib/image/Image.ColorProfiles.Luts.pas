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
  The LUT tags of ICC profiles, device to PCS (A2B0): a pipeline of
  curves, a colour lookup table (a grid over the input channels,
  interpolated multilinearly) and a matrix.

    mft1 (lut8Type)      input tables (256 bytes each), the grid (bytes),
                         output tables; the 3 x 3 matrix is used only
                         when the input is XYZ, so never here
    mft2 (lut16Type)     the same with 16-bit tables of any length
    mAB  (lutAtoBType)   A curves, the grid, M curves, a 3 x 3 matrix with
                         an offset, B curves, each part optional

  Every value is taken from 0 to 1 through the pipeline; what comes out
  is the PCS in its encoding, decoded by DecodePcs: Lab as L 0..100 and
  a, b -128..127 (mft2 in the older encoding of version 2, where 100 is
  $FF00 rather than $FFFF), or XYZ where 1.0 is $8000 of $FFFF.

  Grids are limited in size (the input channels at most 8, the grid at
  most 16 million values), so a profile cannot ask for gigabytes.
}
unit Image.ColorProfiles.Luts;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.ColorProfiles.Matrices,
  Image.ColorProfiles.Curves;

const
  MaximumLutChannels = 8;

type
  TIccLutKind = (IccLutNone, IccLut8, IccLut16, IccLutAToB);

  TLutChannels = array[0..MaximumLutChannels - 1] of Double;

  TIccLut = record
    Kind: TIccLutKind;
    InputChannels: LongInt;
    OutputChannels: LongInt;
    { Before the grid (mft1/mft2 input tables, mAB A curves). }
    InputCurves: TToneCurves;
    GridPoints: array[0..MaximumLutChannels - 1] of LongInt;
    { Output values for every grid point, the first input varying
      slowest; empty when there is no grid. }
    Grid: array of Double;
    { mAB: after the grid. }
    MiddleCurves: TToneCurves;
    HasMatrix: Boolean;
    Matrix: TColorMatrix;
    MatrixOffset: TColorVector;
    { mft1/mft2 output tables, mAB B curves. }
    OutputCurves: TToneCurves;
  end;

{ The LUT tag at Offset (Limit where it ends). False for a tag of
  another type, or one that is malformed or too large. }
function ReadIccLut(const Profile: TBytes; Offset, Limit: PtrInt; out Lut: TIccLut): Boolean;
{ Runs Input (InputChannels values, 0 to 1) through the LUT. }
procedure EvaluateIccLut(constref Lut: TIccLut; constref Input: TLutChannels; out Output: TLutChannels);
{ The LUT's output as PCS XYZ (relative to D50); PcsIsLab says how the
  profile's PCS is encoded. }
function DecodePcs(constref Lut: TIccLut; constref Output: TLutChannels; PcsIsLab: Boolean): TColorVector;

implementation

uses
  Image.ColorProfiles.Numbers;

const
  MaximumGridValues = 16 * 1024 * 1024;
  MaximumTableEntries = 4096;

function TableCurve(const Values: array of Double): TToneCurve;
var
  Index: LongInt;
begin
  Result := IdentityCurve;
  Result.Kind := ToneCurveTable;
  SetLength(Result.Table, Length(Values));
  for Index := 0 to High(Values) do
    Result.Table[Index] := Values[Index];
end;

{ Count tables of Entries values of ValueBytes bytes each at Offset. }
function ReadTables(const Profile: TBytes; Offset: PtrInt; Count, Entries, ValueBytes: LongInt;
  out Curves: TToneCurves): PtrInt;
var
  Table: array of Double;
  Curve: LongInt;
  Index: LongInt;
begin
  Curves := nil;
  SetLength(Curves, Count);
  Table := nil;
  SetLength(Table, Entries);
  for Curve := 0 to Count - 1 do
  begin
    for Index := 0 to Entries - 1 do
      if ValueBytes = 1 then
        Table[Index] := Profile[Offset + Index] / 255
      else
        Table[Index] := ReadProfileWord(Profile, Offset + 2 * Index) / 65535;
    Curves[Curve] := TableCurve(Table);
    Inc(Offset, PtrInt(Entries) * ValueBytes);
  end;
  Result := Offset;
end;

function GridValueCount(constref Lut: TIccLut): Int64;
var
  Index: LongInt;
begin
  Result := Lut.OutputChannels;
  for Index := 0 to Lut.InputChannels - 1 do
  begin
    if Lut.GridPoints[Index] < 2 then
      Exit(-1);
    Result := Result * Lut.GridPoints[Index];
    if Result > MaximumGridValues then
      Exit(-1);
  end;
end;

function ReadGrid(const Profile: TBytes; Offset, Limit: PtrInt; ValueBytes: LongInt; var Lut: TIccLut): Boolean;
var
  Count: Int64;
  Index: PtrInt;
begin
  Count := GridValueCount(Lut);
  if (Count <= 0) or (Offset + Count * ValueBytes > Limit) then
    Exit(False);
  SetLength(Lut.Grid, Count);
  for Index := 0 to Count - 1 do
    if ValueBytes = 1 then
      Lut.Grid[Index] := Profile[Offset + Index] / 255
    else
      Lut.Grid[Index] := ReadProfileWord(Profile, Offset + 2 * Index) / 65535;
  Result := True;
end;

{ mft1 and mft2. }
function ReadLutOfTables(const Profile: TBytes; Offset, Limit: PtrInt; Sixteen: Boolean; var Lut: TIccLut): Boolean;
var
  Points: LongInt;
  InputEntries: LongInt;
  OutputEntries: LongInt;
  ValueBytes: LongInt;
  Position: PtrInt;
  Index: LongInt;
  GridCount: Int64;
begin
  Result := False;
  if Offset + 48 > Limit then
    Exit;
  Lut.InputChannels := Profile[Offset + 8];
  Lut.OutputChannels := Profile[Offset + 9];
  Points := Profile[Offset + 10];
  if (Lut.InputChannels < 1) or (Lut.InputChannels > MaximumLutChannels) or (Lut.OutputChannels < 1) or
    (Lut.OutputChannels > MaximumLutChannels) then
    Exit;
  for Index := 0 to Lut.InputChannels - 1 do
    Lut.GridPoints[Index] := Points;
  Position := Offset + 48;
  if Sixteen then
  begin
    if Offset + 52 > Limit then
      Exit;
    InputEntries := ReadProfileWord(Profile, Offset + 48);
    OutputEntries := ReadProfileWord(Profile, Offset + 50);
    ValueBytes := 2;
    Position := Offset + 52;
  end
  else
  begin
    InputEntries := 256;
    OutputEntries := 256;
    ValueBytes := 1;
  end;
  if (InputEntries < 2) or (OutputEntries < 2) or (InputEntries > MaximumTableEntries) or
    (OutputEntries > MaximumTableEntries) then
    Exit;
  GridCount := GridValueCount(Lut);
  if GridCount <= 0 then
    Exit;
  if Position + (Int64(InputEntries) * Lut.InputChannels + GridCount + Int64(OutputEntries) * Lut.OutputChannels) *
    ValueBytes > Limit then
    Exit;
  Position := ReadTables(Profile, Position, Lut.InputChannels, InputEntries, ValueBytes, Lut.InputCurves);
  if not ReadGrid(Profile, Position, Limit, ValueBytes, Lut) then
    Exit;
  Inc(Position, GridCount * ValueBytes);
  ReadTables(Profile, Position, Lut.OutputChannels, OutputEntries, ValueBytes, Lut.OutputCurves);
  Result := True;
end;

function ReadAToBMatrix(const Profile: TBytes; Offset, Limit: PtrInt; var Lut: TIccLut): Boolean;
var
  Row: LongInt;
  Column: LongInt;
begin
  if Offset + 48 > Limit then
    Exit(False);
  for Row := 0 to 2 do
    for Column := 0 to 2 do
      Lut.Matrix[Row, Column] := ReadProfileFixed(Profile, Offset + 4 * (3 * Row + Column));
  for Row := 0 to 2 do
    Lut.MatrixOffset[Row] := ReadProfileFixed(Profile, Offset + 36 + 4 * Row);
  Lut.HasMatrix := True;
  Result := True;
end;

function ReadAToBGrid(const Profile: TBytes; Offset, Limit: PtrInt; var Lut: TIccLut): Boolean;
var
  Index: LongInt;
  Precision: LongInt;
begin
  if Offset + 20 > Limit then
    Exit(False);
  for Index := 0 to Lut.InputChannels - 1 do
    Lut.GridPoints[Index] := Profile[Offset + Index];
  Precision := Profile[Offset + 16];
  if (Precision <> 1) and (Precision <> 2) then
    Exit(False);
  Result := ReadGrid(Profile, Offset + 20, Limit, Precision, Lut);
end;

function ReadLutAToB(const Profile: TBytes; Offset, Limit: PtrInt; var Lut: TIccLut): Boolean;
var
  BOffset: LongWord;
  MatrixOffset: LongWord;
  MOffset: LongWord;
  GridOffset: LongWord;
  AOffset: LongWord;
  Size: Int64;
begin
  Result := False;
  if Offset + 32 > Limit then
    Exit;
  Lut.InputChannels := Profile[Offset + 8];
  Lut.OutputChannels := Profile[Offset + 9];
  if (Lut.InputChannels < 1) or (Lut.InputChannels > MaximumLutChannels) or (Lut.OutputChannels < 1) or
    (Lut.OutputChannels > MaximumLutChannels) then
    Exit;
  BOffset := ReadProfileLong(Profile, Offset + 12);
  MatrixOffset := ReadProfileLong(Profile, Offset + 16);
  MOffset := ReadProfileLong(Profile, Offset + 20);
  GridOffset := ReadProfileLong(Profile, Offset + 24);
  AOffset := ReadProfileLong(Profile, Offset + 28);
  Size := Limit - Offset;
  if (BOffset >= Size) or (MatrixOffset >= Size) or (MOffset >= Size) or (GridOffset >= Size) or (AOffset >= Size) then
    Exit;
  { B curves are always there; the matrix and M curves only with three
    outputs. }
  if BOffset = 0 then
    Exit;
  if not ReadToneCurves(Profile, Offset + BOffset, Limit, Lut.OutputChannels, Lut.OutputCurves) then
    Exit;
  if MatrixOffset <> 0 then
  begin
    if Lut.OutputChannels <> 3 then
      Exit;
    if not ReadAToBMatrix(Profile, Offset + MatrixOffset, Limit, Lut) then
      Exit;
  end;
  if MOffset <> 0 then
    if not ReadToneCurves(Profile, Offset + MOffset, Limit, Lut.OutputChannels, Lut.MiddleCurves) then
      Exit;
  if GridOffset <> 0 then
  begin
    if not ReadAToBGrid(Profile, Offset + GridOffset, Limit, Lut) then
      Exit;
  end
  else if Lut.InputChannels <> Lut.OutputChannels then
    Exit;
  if AOffset <> 0 then
    if not ReadToneCurves(Profile, Offset + AOffset, Limit, Lut.InputChannels, Lut.InputCurves) then
      Exit;
  Result := True;
end;

function ReadIccLut(const Profile: TBytes; Offset, Limit: PtrInt; out Lut: TIccLut): Boolean;
var
  Signature: LongWord;
begin
  Lut := Default(TIccLut);
  Lut.Matrix := IdentityMatrix;
  Result := False;
  if (Offset < 0) or (Limit > Length(Profile)) or (Offset + 12 > Limit) then
    Exit;
  Signature := ReadProfileLong(Profile, Offset);
  if Signature = SignatureOf('mft1') then
  begin
    Lut.Kind := IccLut8;
    Result := ReadLutOfTables(Profile, Offset, Limit, False, Lut);
  end
  else if Signature = SignatureOf('mft2') then
  begin
    Lut.Kind := IccLut16;
    Result := ReadLutOfTables(Profile, Offset, Limit, True, Lut);
  end
  else if Signature = SignatureOf('mAB ') then
  begin
    Lut.Kind := IccLutAToB;
    Result := ReadLutAToB(Profile, Offset, Limit, Lut);
  end;
  if not Result then
    Lut.Kind := IccLutNone;
end;

function Clamp01(Value: Double): Double; inline;
begin
  if Value < 0 then
    Result := 0
  else if Value > 1 then
    Result := 1
  else
    Result := Value;
end;

procedure ApplyCurves(constref Curves: TToneCurves; Count: LongInt; var Values: TLutChannels);
var
  Index: LongInt;
begin
  if Length(Curves) < Count then
    Exit;
  for Index := 0 to Count - 1 do
    Values[Index] := Clamp01(EvaluateToneCurve(Curves[Index], Values[Index]));
end;

{ Multilinear interpolation in the grid: every corner of the cell the
  input falls in, weighted by its share. }
procedure InterpolateGrid(constref Lut: TIccLut; constref Input: TLutChannels; out Output: TLutChannels);
var
  Base: array[0..MaximumLutChannels - 1] of PtrInt;
  Fraction: array[0..MaximumLutChannels - 1] of Double;
  Stride: array[0..MaximumLutChannels - 1] of PtrInt;
  Channel: LongInt;
  Corner: LongInt;
  Position: Double;
  Index: PtrInt;
  Weight: Double;
  OutputChannel: LongInt;
begin
  Output := Default(TLutChannels);
  Stride[Lut.InputChannels - 1] := Lut.OutputChannels;
  for Channel := Lut.InputChannels - 2 downto 0 do
    Stride[Channel] := Stride[Channel + 1] * Lut.GridPoints[Channel + 1];
  for Channel := 0 to Lut.InputChannels - 1 do
  begin
    Position := Clamp01(Input[Channel]) * (Lut.GridPoints[Channel] - 1);
    Base[Channel] := Trunc(Position);
    if Base[Channel] >= Lut.GridPoints[Channel] - 1 then
      Base[Channel] := Lut.GridPoints[Channel] - 2;
    Fraction[Channel] := Position - Base[Channel];
  end;
  for Corner := 0 to (1 shl Lut.InputChannels) - 1 do
  begin
    Weight := 1;
    Index := 0;
    for Channel := 0 to Lut.InputChannels - 1 do
      if (Corner and (1 shl Channel)) <> 0 then
      begin
        Weight := Weight * Fraction[Channel];
        Inc(Index, (Base[Channel] + 1) * Stride[Channel]);
      end
      else
      begin
        Weight := Weight * (1 - Fraction[Channel]);
        Inc(Index, Base[Channel] * Stride[Channel]);
      end;
    if Weight = 0 then
      Continue;
    for OutputChannel := 0 to Lut.OutputChannels - 1 do
      Output[OutputChannel] := Output[OutputChannel] + Weight * Lut.Grid[Index + OutputChannel];
  end;
end;

procedure EvaluateIccLut(constref Lut: TIccLut; constref Input: TLutChannels; out Output: TLutChannels);
var
  Values: TLutChannels;
  Vector: TColorVector;
  Index: LongInt;
begin
  Values := Input;
  for Index := 0 to Lut.InputChannels - 1 do
    Values[Index] := Clamp01(Values[Index]);
  ApplyCurves(Lut.InputCurves, Lut.InputChannels, Values);
  if Length(Lut.Grid) > 0 then
    InterpolateGrid(Lut, Values, Output)
  else
    Output := Values;
  ApplyCurves(Lut.MiddleCurves, Lut.OutputChannels, Output);
  if Lut.HasMatrix then
  begin
    Vector := ApplyMatrix(Lut.Matrix, MakeVector(Output[0], Output[1], Output[2]));
    for Index := 0 to 2 do
      Output[Index] := Clamp01(Vector[Index] + Lut.MatrixOffset[Index]);
  end;
  ApplyCurves(Lut.OutputCurves, Lut.OutputChannels, Output);
end;

function DecodePcs(constref Lut: TIccLut; constref Output: TLutChannels; PcsIsLab: Boolean): TColorVector;
const
  XyzScale = 65535 / 32768;
  LegacyScale = 65535 / 65280;
var
  Lightness: Double;
  A: Double;
  B: Double;
begin
  if not PcsIsLab then
    Exit(MakeVector(Output[0] * XyzScale, Output[1] * XyzScale, Output[2] * XyzScale));
  if Lut.Kind = IccLut16 then
  begin
    Lightness := 100 * Output[0] * LegacyScale;
    A := 255 * Output[1] * LegacyScale - 128;
    B := 255 * Output[2] * LegacyScale - 128;
  end
  else
  begin
    Lightness := 100 * Output[0];
    A := 255 * Output[1] - 128;
    B := 255 * Output[2] - 128;
  end;
  Result := LabToXyz(Lightness, A, B);
end;

end.
