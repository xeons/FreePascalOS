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
  JPEG XL's dequantization matrices (ISO/IEC 18181-1 annex I.2.4).

  There are 17 tables, one per kind of transform (several strategies
  share one). Each is the default ("library") one, or given in the HF
  global section as: weights for the identity transform, for DCT2x2,
  for DCT4x4 or DCT4x8 (distance bands and multipliers), for AFV, for
  a DCT of any size as distance bands (the weight of a coefficient
  interpolated geometrically along its distance from the top left), or
  raw values in a modular stream. A table holds, per channel, the
  multiplier of every coefficient of a varblock (the reciprocal of the
  weight), laid out as the coefficients are.

  Tables are computed only for the strategies a frame uses, as libjxl
  does. The interpolation uses the exact power function where libjxl
  uses a fast approximation; the difference is far below what a
  coefficient quantized to an integer can show.
}
unit Image.Jxl.VarDct.QuantWeights;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Math,
  Image.Errors,
  Image.Jxl.BitReader,
  Image.Jxl.Modular.Tree,
  Image.Jxl.VarDct.Strategies;

const
  JxlQuantModeLibrary = 0;
  JxlQuantModeIdentity = 1;
  JxlQuantModeDct2 = 2;
  JxlQuantModeDct4 = 3;
  JxlQuantModeDct4x8 = 4;
  JxlQuantModeAfv = 5;
  JxlQuantModeDct = 6;
  JxlQuantModeRaw = 7;
  JxlMaximumDistanceBands = 17;

type
  TJxlDistanceBands = array[0..2, 0..JxlMaximumDistanceBands - 1] of Single;

  TJxlQuantEncoding = record
    Mode: LongInt;
    IdentityWeights: array[0..2, 0..2] of Single;
    Dct2Weights: array[0..2, 0..5] of Single;
    Dct4Multipliers: array[0..2, 0..1] of Single;
    Dct4x8Multipliers: array[0..2] of Single;
    AfvWeights: array[0..2, 0..8] of Single;
    BandCount: LongInt;
    Bands: TJxlDistanceBands;
    Afv4x4BandCount: LongInt;
    Afv4x4Bands: TJxlDistanceBands;
    RawDenominator: Single;
    RawTable: array of LongInt;
  end;

  TJxlDequantMatrices = class
  private
    FEncodings: array[0..JxlQuantTableCount - 1] of TJxlQuantEncoding;
    FTables: array[0..JxlQuantTableCount - 1] of array of Single;
    procedure ComputeTable(Table: LongInt);
  public
    constructor Create;
    { Reads the HF global section's tables (QuantTableStreamBase is the
      stream id of table 0's raw modular stream). }
    procedure Read(Reader: TJxlBitReader; QuantTableStreamBase: LongInt; GlobalTree: TJxlModularTreeCode);
    { Computes the tables of the strategies in the mask (bit per
      strategy). }
    procedure EnsureComputed(StrategyMask: LongWord);
    { The multipliers of Strategy's coefficients for Channel (covered
      blocks x 64 values). }
    function Matrix(Strategy, Channel: LongInt): PSingle;
  end;

implementation

uses
  Image.Jxl.Modular.Channels,
  Image.Jxl.Modular.Decoding,
  Image.Jxl.VarDct.Tables;

const
  AlmostZero = 1e-8;
  Sqrt2 = 1.41421356237;

procedure RaiseBadQuantTable(const Detail: string);
begin
  RaiseImageError(ImageErrorMalformed, 'JPEG XL quantization table: ' + Detail);
end;

procedure SetBands(var Bands: TJxlDistanceBands; out Count: LongInt; BandCount: LongInt; const Values: array of Single;
  First: LongInt);
var
  Channel: LongInt;
  Index: LongInt;
begin
  Count := BandCount;
  for Channel := 0 to 2 do
    for Index := 0 to BandCount - 1 do
      Bands[Channel, Index] := Values[First + Channel * BandCount + Index];
end;

function LibraryEncoding(Table: LongInt): TJxlQuantEncoding;
var
  Channel: LongInt;
  Index: LongInt;
begin
  Result := Default(TJxlQuantEncoding);
  Result.Mode := JxlQuantModeDct;
  case Table of
    0: SetBands(Result.Bands, Result.BandCount, LibraryDCTBandCount, LibraryDCT, 0);
    1:
      begin
        Result.Mode := JxlQuantModeIdentity;
        for Channel := 0 to 2 do
          for Index := 0 to 2 do
            Result.IdentityWeights[Channel, Index] := LibraryIDENTITY[Channel * 3 + Index];
      end;
    2:
      begin
        Result.Mode := JxlQuantModeDct2;
        for Channel := 0 to 2 do
          for Index := 0 to 5 do
            Result.Dct2Weights[Channel, Index] := LibraryDCT2X2[Channel * 6 + Index];
      end;
    3:
      begin
        Result.Mode := JxlQuantModeDct4;
        SetBands(Result.Bands, Result.BandCount, LibraryDCT4X4BandCount, LibraryDCT4X4, 0);
        for Channel := 0 to 2 do
          for Index := 0 to 1 do
            Result.Dct4Multipliers[Channel, Index] := LibraryDCT4X4[12 + Channel * 2 + Index];
      end;
    4: SetBands(Result.Bands, Result.BandCount, LibraryDCT16X16BandCount, LibraryDCT16X16, 0);
    5: SetBands(Result.Bands, Result.BandCount, LibraryDCT32X32BandCount, LibraryDCT32X32, 0);
    6: SetBands(Result.Bands, Result.BandCount, LibraryDCT8X16BandCount, LibraryDCT8X16, 0);
    7: SetBands(Result.Bands, Result.BandCount, LibraryDCT8X32BandCount, LibraryDCT8X32, 0);
    8: SetBands(Result.Bands, Result.BandCount, LibraryDCT16X32BandCount, LibraryDCT16X32, 0);
    9:
      begin
        Result.Mode := JxlQuantModeDct4x8;
        SetBands(Result.Bands, Result.BandCount, LibraryDCT4X8BandCount, LibraryDCT4X8, 0);
        for Channel := 0 to 2 do
          Result.Dct4x8Multipliers[Channel] := LibraryDCT4X8[12 + Channel];
      end;
    10:
      begin
        Result.Mode := JxlQuantModeAfv;
        SetBands(Result.Bands, Result.BandCount, LibraryDCT4X8BandCount, LibraryDCT4X8, 0);
        SetBands(Result.Afv4x4Bands, Result.Afv4x4BandCount, LibraryDCT4X4BandCount, LibraryDCT4X4, 0);
        for Channel := 0 to 2 do
          for Index := 0 to 8 do
            Result.AfvWeights[Channel, Index] := LibraryAFV0[Channel * 9 + Index];
      end;
    11: SetBands(Result.Bands, Result.BandCount, LibraryDCT64X64BandCount, LibraryDCT64X64, 0);
    12: SetBands(Result.Bands, Result.BandCount, LibraryDCT32X64BandCount, LibraryDCT32X64, 0);
    13: SetBands(Result.Bands, Result.BandCount, LibraryDCT128X128BandCount, LibraryDCT128X128, 0);
    14: SetBands(Result.Bands, Result.BandCount, LibraryDCT64X128BandCount, LibraryDCT64X128, 0);
    15: SetBands(Result.Bands, Result.BandCount, LibraryDCT256X256BandCount, LibraryDCT256X256, 0);
  else
    SetBands(Result.Bands, Result.BandCount, LibraryDCT128X256BandCount, LibraryDCT128X256, 0);
  end;
end;

procedure ReadDctParameters(Reader: TJxlBitReader; var Bands: TJxlDistanceBands; out Count: LongInt);
var
  Channel: LongInt;
  Index: LongInt;
begin
  Count := LongInt(Reader.ReadBits(4)) + 1;
  for Channel := 0 to 2 do
  begin
    for Index := 0 to Count - 1 do
      Bands[Channel, Index] := Reader.ReadF16;
    if Bands[Channel, 0] < AlmostZero then
      RaiseBadQuantTable('distance band seed too small');
    Bands[Channel, 0] := Bands[Channel, 0] * 64;
  end;
end;

procedure ReadRawTable(Reader: TJxlBitReader; Table, QuantTableStreamBase: LongInt; GlobalTree: TJxlModularTreeCode;
  var Encoding: TJxlQuantEncoding);
var
  Width: LongInt;
  Height: LongInt;
  Image: TJxlModularImage;
  State: TJxlModularStreamState;
  Channel: LongInt;
  X: LongInt;
  Y: LongInt;
  Value: LongInt;
begin
  Encoding.RawDenominator := Reader.ReadF16;
  if Encoding.RawDenominator < AlmostZero then
    RaiseBadQuantTable('raw denominator too small');
  Width := 8 * JxlQuantTableRequiredX[Table];
  Height := 8 * JxlQuantTableRequiredY[Table];
  Image := TJxlModularImage.Create;
  try
    Image.BitDepth := 8;
    for Channel := 0 to 2 do
      Image.AddChannel(TJxlChannel.Create(Width, Height));
    DecodeJxlModularStream(Reader, Image, QuantTableStreamBase + Table, High(Int64), GlobalTree, True, State);
    if Image.ChannelCount < 3 then
      RaiseBadQuantTable('raw table lost channels');
    SetLength(Encoding.RawTable, 3 * Width * Height);
    for Channel := 0 to 2 do
    begin
      if (Image[Channel].Width <> Width) or (Image[Channel].Height <> Height) then
        RaiseBadQuantTable('raw table of the wrong size');
      for Y := 0 to Height - 1 do
        for X := 0 to Width - 1 do
        begin
          Value := Image[Channel].Row(Y)[X];
          if Value <= 0 then
            RaiseBadQuantTable('raw value not positive');
          Encoding.RawTable[Channel * Width * Height + Y * Width + X] := Value;
        end;
    end;
  finally
    Image.Free;
  end;
end;

function ReadEncoding(Reader: TJxlBitReader; Table, QuantTableStreamBase: LongInt;
  GlobalTree: TJxlModularTreeCode): TJxlQuantEncoding;
var
  Mode: LongInt;
  SingleBlock: Boolean;
  Channel: LongInt;
  Index: LongInt;
begin
  Result := Default(TJxlQuantEncoding);
  SingleBlock := (JxlQuantTableRequiredX[Table] = 1) and (JxlQuantTableRequiredY[Table] = 1);
  Mode := LongInt(Reader.ReadBits(3));
  case Mode of
    JxlQuantModeLibrary:
      Exit(LibraryEncoding(Table));
    JxlQuantModeIdentity:
      begin
        if not SingleBlock then
          RaiseBadQuantTable('identity weights for a large table');
        for Channel := 0 to 2 do
          for Index := 0 to 2 do
          begin
            Result.IdentityWeights[Channel, Index] := Reader.ReadF16;
            if Abs(Result.IdentityWeights[Channel, Index]) < AlmostZero then
              RaiseBadQuantTable('identity weight too small');
            Result.IdentityWeights[Channel, Index] := Result.IdentityWeights[Channel, Index] * 64;
          end;
      end;
    JxlQuantModeDct2:
      begin
        if not SingleBlock then
          RaiseBadQuantTable('DCT2 weights for a large table');
        for Channel := 0 to 2 do
          for Index := 0 to 5 do
          begin
            Result.Dct2Weights[Channel, Index] := Reader.ReadF16;
            if Abs(Result.Dct2Weights[Channel, Index]) < AlmostZero then
              RaiseBadQuantTable('DCT2 weight too small');
            Result.Dct2Weights[Channel, Index] := Result.Dct2Weights[Channel, Index] * 64;
          end;
      end;
    JxlQuantModeDct4x8:
      begin
        if not SingleBlock then
          RaiseBadQuantTable('DCT4x8 weights for a large table');
        for Channel := 0 to 2 do
        begin
          Result.Dct4x8Multipliers[Channel] := Reader.ReadF16;
          if Abs(Result.Dct4x8Multipliers[Channel]) < AlmostZero then
            RaiseBadQuantTable('DCT4x8 multiplier too small');
        end;
        ReadDctParameters(Reader, Result.Bands, Result.BandCount);
      end;
    JxlQuantModeDct4:
      begin
        if not SingleBlock then
          RaiseBadQuantTable('DCT4 weights for a large table');
        for Channel := 0 to 2 do
          for Index := 0 to 1 do
          begin
            Result.Dct4Multipliers[Channel, Index] := Reader.ReadF16;
            if Abs(Result.Dct4Multipliers[Channel, Index]) < AlmostZero then
              RaiseBadQuantTable('DCT4 multiplier too small');
          end;
        ReadDctParameters(Reader, Result.Bands, Result.BandCount);
      end;
    JxlQuantModeAfv:
      begin
        if not SingleBlock then
          RaiseBadQuantTable('AFV weights for a large table');
        for Channel := 0 to 2 do
        begin
          for Index := 0 to 8 do
            Result.AfvWeights[Channel, Index] := Reader.ReadF16;
          for Index := 0 to 5 do
            Result.AfvWeights[Channel, Index] := Result.AfvWeights[Channel, Index] * 64;
        end;
        ReadDctParameters(Reader, Result.Bands, Result.BandCount);
        ReadDctParameters(Reader, Result.Afv4x4Bands, Result.Afv4x4BandCount);
      end;
    JxlQuantModeDct:
      ReadDctParameters(Reader, Result.Bands, Result.BandCount);
  else
    ReadRawTable(Reader, Table, QuantTableStreamBase, GlobalTree, Result);
  end;
  Result.Mode := Mode;
end;

function BandMultiplier(Value: Single): Single;
begin
  if Value > 0 then
    Result := 1 + Value
  else
    Result := 1 / (1 - Value);
end;

{ Weights of a Rows x Columns DCT from distance bands, channel after
  channel into Output. }
procedure ComputeDctWeights(Rows, Columns: LongInt; const Bands: TJxlDistanceBands; BandCount: LongInt;
  var Output: array of Single);
var
  Channel: LongInt;
  Band: array[0..JxlMaximumDistanceBands] of Single;
  Index: LongInt;
  Scale: Single;
  ColumnStep: Single;
  RowStep: Single;
  X: LongInt;
  Y: LongInt;
  DistanceY: Single;
  DistanceX: Single;
  Distance: Single;
  Position: LongInt;
  Fraction: Single;
  Weight: Single;
begin
  if (BandCount < 1) or (BandCount > JxlMaximumDistanceBands) then
    RaiseBadQuantTable('bad band count');
  for Channel := 0 to 2 do
  begin
    Band[0] := Bands[Channel, 0];
    if Band[0] < AlmostZero then
      RaiseBadQuantTable('bad distance bands');
    for Index := 1 to BandCount - 1 do
    begin
      Band[Index] := Band[Index - 1] * BandMultiplier(Bands[Channel, Index]);
      if Band[Index] < AlmostZero then
        RaiseBadQuantTable('bad distance bands');
    end;
    Band[BandCount] := Band[BandCount - 1];
    Scale := (BandCount - 1) / (Sqrt2 + 1e-6);
    ColumnStep := Scale / (Columns - 1);
    RowStep := Scale / (Rows - 1);
    for Y := 0 to Rows - 1 do
    begin
      DistanceY := Y * RowStep;
      for X := 0 to Columns - 1 do
      begin
        if BandCount = 1 then
          Weight := Band[0]
        else
        begin
          DistanceX := X * ColumnStep;
          Distance := Sqrt(DistanceX * DistanceX + DistanceY * DistanceY);
          Position := Trunc(Distance);
          if Position > BandCount - 1 then
            Position := BandCount - 1;
          Fraction := Distance - Position;
          Weight := Band[Position] * Power(Band[Position + 1] / Band[Position], Fraction);
        end;
        Output[Channel * Rows * Columns + Y * Columns + X] := Weight;
      end;
    end;
  end;
end;

function Interpolate(Position, Maximum: Single; const Values: array of Single): Single;
var
  Scaled: Single;
  Index: LongInt;
begin
  Scaled := Position * (Length(Values) - 1) / Maximum;
  Index := Trunc(Scaled);
  if Index + 1 >= Length(Values) then
    RaiseBadQuantTable('bad AFV interpolation');
  Result := Values[Index] * Power(Values[Index + 1] / Values[Index], Scaled - Index);
end;

procedure ComputeAfvWeights(const Encoding: TJxlQuantEncoding; var Weights: array of Single);
const
  Frequencies: array[0..15] of Single = (
    0, 0, 0.8517778890324296, 5.37778436506804, 0, 0, 4.734747904497923, 5.449245381693219,
    1.6598270267479331, 4, 7.275749096817861, 10.423227632456525, 2.662932286148962, 7.630657783650829,
    8.962388608184032, 12.97166202570235);
  Low = 0.8517778890324296;
  High = 12.97166202570235 - Low + 1e-6;
var
  Weights4x8: array[0..3 * 32 - 1] of Single;
  Weights4x4: array[0..3 * 16 - 1] of Single;
  Bands: array[0..3] of Single;
  Channel: LongInt;
  Index: LongInt;
  Start: LongInt;
  X: LongInt;
  Y: LongInt;
begin
  ComputeDctWeights(4, 8, Encoding.Bands, Encoding.BandCount, Weights4x8);
  ComputeDctWeights(4, 4, Encoding.Afv4x4Bands, Encoding.Afv4x4BandCount, Weights4x4);
  for Channel := 0 to 2 do
  begin
    Bands[0] := Encoding.AfvWeights[Channel, 5];
    if Bands[0] < AlmostZero then
      RaiseBadQuantTable('bad AFV bands');
    for Index := 1 to 3 do
    begin
      Bands[Index] := Bands[Index - 1] * BandMultiplier(Encoding.AfvWeights[Channel, Index + 5]);
      if Bands[Index] < AlmostZero then
        RaiseBadQuantTable('bad AFV bands');
    end;
    Start := Channel * 64;
    Weights[Start] := 1;
    Weights[Start + 1 * 8 + 0] := Encoding.AfvWeights[Channel, 0];
    Weights[Start + 0 * 8 + 1] := Encoding.AfvWeights[Channel, 1];
    Weights[Start + 2 * 8 + 0] := Encoding.AfvWeights[Channel, 2];
    Weights[Start + 0 * 8 + 2] := Encoding.AfvWeights[Channel, 3];
    Weights[Start + 2 * 8 + 2] := Encoding.AfvWeights[Channel, 4];
    for Y := 0 to 3 do
      for X := 0 to 3 do
      begin
        if (X < 2) and (Y < 2) then
          Continue;
        Weights[Start + 2 * Y * 8 + 2 * X] := Interpolate(Frequencies[Y * 4 + X] - Low, High, Bands);
      end;
    for Y := 0 to 3 do
      for X := 0 to 7 do
      begin
        if (X = 0) and (Y = 0) then
          Continue;
        Weights[Start + (2 * Y + 1) * 8 + X] := Weights4x8[Channel * 32 + Y * 8 + X];
      end;
    for Y := 0 to 3 do
      for X := 0 to 3 do
      begin
        if (X = 0) and (Y = 0) then
          Continue;
        Weights[Start + 2 * Y * 8 + 2 * X + 1] := Weights4x4[Channel * 16 + Y * 4 + X];
      end;
  end;
end;

procedure ComputeDct2Weights(const Encoding: TJxlQuantEncoding; var Weights: array of Single);
var
  Channel: LongInt;
  Start: LongInt;
  X: LongInt;
  Y: LongInt;
begin
  for Channel := 0 to 2 do
  begin
    Start := Channel * 64;
    Weights[Start] := $BAD;
    Weights[Start + 1] := Encoding.Dct2Weights[Channel, 0];
    Weights[Start + 8] := Encoding.Dct2Weights[Channel, 0];
    Weights[Start + 9] := Encoding.Dct2Weights[Channel, 1];
    for Y := 0 to 1 do
      for X := 0 to 1 do
      begin
        Weights[Start + Y * 8 + X + 2] := Encoding.Dct2Weights[Channel, 2];
        Weights[Start + (Y + 2) * 8 + X] := Encoding.Dct2Weights[Channel, 2];
        Weights[Start + (Y + 2) * 8 + X + 2] := Encoding.Dct2Weights[Channel, 3];
      end;
    for Y := 0 to 3 do
      for X := 0 to 3 do
      begin
        Weights[Start + Y * 8 + X + 4] := Encoding.Dct2Weights[Channel, 4];
        Weights[Start + (Y + 4) * 8 + X] := Encoding.Dct2Weights[Channel, 4];
        Weights[Start + (Y + 4) * 8 + X + 4] := Encoding.Dct2Weights[Channel, 5];
      end;
  end;
end;

constructor TJxlDequantMatrices.Create;
var
  Table: LongInt;
begin
  inherited Create;
  for Table := 0 to JxlQuantTableCount - 1 do
    FEncodings[Table] := LibraryEncoding(Table);
end;

procedure TJxlDequantMatrices.Read(Reader: TJxlBitReader; QuantTableStreamBase: LongInt;
  GlobalTree: TJxlModularTreeCode);
var
  Table: LongInt;
begin
  if not Reader.ReadBool then
    for Table := 0 to JxlQuantTableCount - 1 do
      FEncodings[Table] := ReadEncoding(Reader, Table, QuantTableStreamBase, GlobalTree);
  for Table := 0 to JxlQuantTableCount - 1 do
    FTables[Table] := nil;
end;

procedure TJxlDequantMatrices.ComputeTable(Table: LongInt);
var
  Rows: LongInt;
  Columns: LongInt;
  Count: LongInt;
  Weights: array of Single;
  Encoding: TJxlQuantEncoding;
  Weights4: array[0..3 * 32 - 1] of Single;
  Channel: LongInt;
  Index: LongInt;
  X: LongInt;
  Y: LongInt;
begin
  Rows := 8 * JxlQuantTableRequiredX[Table];
  Columns := 8 * JxlQuantTableRequiredY[Table];
  Count := Rows * Columns;
  SetLength(Weights, 3 * Count);
  Encoding := FEncodings[Table];
  case Encoding.Mode of
    JxlQuantModeIdentity:
      for Channel := 0 to 2 do
      begin
        for Index := 0 to 63 do
          Weights[64 * Channel + Index] := Encoding.IdentityWeights[Channel, 0];
        Weights[64 * Channel + 1] := Encoding.IdentityWeights[Channel, 1];
        Weights[64 * Channel + 8] := Encoding.IdentityWeights[Channel, 1];
        Weights[64 * Channel + 9] := Encoding.IdentityWeights[Channel, 2];
      end;
    JxlQuantModeDct2:
      ComputeDct2Weights(Encoding, Weights);
    JxlQuantModeDct4:
      begin
        ComputeDctWeights(4, 4, Encoding.Bands, Encoding.BandCount, Weights4);
        for Channel := 0 to 2 do
        begin
          for Y := 0 to 7 do
            for X := 0 to 7 do
              Weights[Channel * Count + Y * 8 + X] := Weights4[Channel * 16 + (Y div 2) * 4 + (X div 2)];
          Weights[Channel * Count + 1] := Weights[Channel * Count + 1] / Encoding.Dct4Multipliers[Channel, 0];
          Weights[Channel * Count + 8] := Weights[Channel * Count + 8] / Encoding.Dct4Multipliers[Channel, 0];
          Weights[Channel * Count + 9] := Weights[Channel * Count + 9] / Encoding.Dct4Multipliers[Channel, 1];
        end;
      end;
    JxlQuantModeDct4x8:
      begin
        ComputeDctWeights(4, 8, Encoding.Bands, Encoding.BandCount, Weights4);
        for Channel := 0 to 2 do
        begin
          for Y := 0 to 7 do
            for X := 0 to 7 do
              Weights[Channel * Count + Y * 8 + X] := Weights4[Channel * 32 + (Y div 2) * 8 + X];
          Weights[Channel * Count + 8] := Weights[Channel * Count + 8] / Encoding.Dct4x8Multipliers[Channel];
        end;
      end;
    JxlQuantModeDct:
      ComputeDctWeights(Rows, Columns, Encoding.Bands, Encoding.BandCount, Weights);
    JxlQuantModeAfv:
      ComputeAfvWeights(Encoding, Weights);
    JxlQuantModeRaw:
      begin
        if Length(Encoding.RawTable) <> 3 * Count then
          RaiseBadQuantTable('bad raw table');
        for Index := 0 to 3 * Count - 1 do
          Weights[Index] := 1 / (Encoding.RawDenominator * Encoding.RawTable[Index]);
      end;
  else
    RaiseBadQuantTable('bad mode');
  end;
  SetLength(FTables[Table], 3 * Count);
  for Index := 0 to 3 * Count - 1 do
  begin
    if (Weights[Index] >= 1 / AlmostZero) or (Weights[Index] < AlmostZero) then
      RaiseBadQuantTable('weight out of range');
    FTables[Table][Index] := 1 / Weights[Index];
  end;
end;

procedure TJxlDequantMatrices.EnsureComputed(StrategyMask: LongWord);
var
  Strategy: LongInt;
  Table: LongInt;
begin
  for Strategy := 0 to JxlStrategyCount - 1 do
    if (StrategyMask and (LongWord(1) shl Strategy)) <> 0 then
    begin
      Table := JxlStrategyQuantTable[Strategy];
      if Length(FTables[Table]) = 0 then
        ComputeTable(Table);
    end;
end;

function TJxlDequantMatrices.Matrix(Strategy, Channel: LongInt): PSingle;
var
  Table: LongInt;
  Count: LongInt;
begin
  Table := JxlStrategyQuantTable[Strategy];
  if Length(FTables[Table]) = 0 then
    ComputeTable(Table);
  Count := 64 * JxlQuantTableRequiredX[Table] * JxlQuantTableRequiredY[Table];
  Result := PSingle(@FTables[Table][0]) + Channel * Count;
end;

end.
