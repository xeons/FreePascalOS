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
  The headers at the start of a JPEG XL codestream (ISO/IEC 18181-1
  annex A and B), after its signature $FF $0A: the image's size, its
  metadata (orientation, preview and animation, bit depth, extra
  channels such as alpha, whether it is coded in XYB, its colour
  encoding and tone mapping) and the custom transform data (the XYB
  inverse matrix and the upsampling weights). An embedded ICC profile
  follows them (Image.Jxl.Icc) when the colour encoding asks for one.

  Every bundle can be "all default", one bit standing for its defaults.
}
unit Image.Jxl.Headers;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Jxl.BitReader;

const
  JxlColorSpaceRgb = 0;
  JxlColorSpaceGrey = 1;
  JxlColorSpaceXyb = 2;
  JxlColorSpaceUnknown = 3;

  JxlWhitePointD65 = 1;
  JxlWhitePointCustom = 2;
  JxlWhitePointE = 10;
  JxlWhitePointDci = 11;

  JxlPrimariesSrgb = 1;
  JxlPrimariesCustom = 2;
  JxlPrimaries2100 = 9;
  JxlPrimariesP3 = 11;

  JxlTransfer709 = 1;
  JxlTransferUnknown = 2;
  JxlTransferLinear = 8;
  JxlTransferSrgb = 13;
  JxlTransferPq = 16;
  JxlTransferDci = 17;
  JxlTransferHlg = 18;

  JxlExtraChannelAlpha = 0;
  JxlExtraChannelDepth = 1;
  JxlExtraChannelSpotColor = 2;
  JxlExtraChannelSelectionMask = 3;
  JxlExtraChannelBlack = 4;
  JxlExtraChannelCfa = 5;
  JxlExtraChannelThermal = 6;
  JxlExtraChannelUnknown = 15;
  JxlExtraChannelOptional = 16;

type
  TJxlBitDepth = record
    FloatSample: Boolean;
    BitsPerSample: LongWord;
    ExponentBits: LongWord;
  end;

  { A chromaticity in millionths. }
  TJxlChromaticity = record
    X: LongInt;
    Y: LongInt;
  end;

  TJxlColorEncoding = record
    WantIcc: Boolean;
    ColorSpace: LongWord;
    WhitePoint: LongWord;
    White: TJxlChromaticity;
    Primaries: LongWord;
    Red: TJxlChromaticity;
    Green: TJxlChromaticity;
    Blue: TJxlChromaticity;
    HaveGamma: Boolean;
    { The gamma in ten millionths (encoded = linear ^ Gamma). }
    Gamma: LongWord;
    TransferFunction: LongWord;
    RenderingIntent: LongWord;
  end;

  TJxlToneMapping = record
    IntensityTarget: Single;
    MinimumNits: Single;
    RelativeToMaximumDisplay: Boolean;
    LinearBelow: Single;
  end;

  TJxlExtraChannelInfo = record
    ChannelType: LongWord;
    BitDepth: TJxlBitDepth;
    DimensionShift: LongWord;
    Name: string;
    AlphaAssociated: Boolean;
    SpotColor: array[0..3] of Single;
    CfaChannel: LongWord;
  end;

  TJxlAnimationHeader = record
    TicksPerSecondNumerator: LongWord;
    TicksPerSecondDenominator: LongWord;
    LoopCount: LongWord;
    HaveTimecodes: Boolean;
  end;

  TJxlImageMetadata = record
    Orientation: LongWord;
    HaveIntrinsicSize: Boolean;
    IntrinsicWidth: LongWord;
    IntrinsicHeight: LongWord;
    HavePreview: Boolean;
    PreviewWidth: LongWord;
    PreviewHeight: LongWord;
    HaveAnimation: Boolean;
    Animation: TJxlAnimationHeader;
    BitDepth: TJxlBitDepth;
    Modular16BitBufferSufficient: Boolean;
    ExtraChannels: array of TJxlExtraChannelInfo;
    XybEncoded: Boolean;
    ColorEncoding: TJxlColorEncoding;
    ToneMapping: TJxlToneMapping;
  end;

  TJxlTransformData = record
    InverseOpsinMatrix: array[0..2, 0..2] of Single;
    OpsinBiases: array[0..2] of Single;
    QuantBiases: array[0..3] of Single;
    Upsampling2Weights: array[0..14] of Single;
    Upsampling4Weights: array[0..54] of Single;
    Upsampling8Weights: array[0..209] of Single;
  end;

  TJxlImageHeaders = record
    Width: LongWord;
    Height: LongWord;
    Metadata: TJxlImageMetadata;
    Transform: TJxlTransformData;
  end;

{ Reads the size, the metadata and the transform data (the reader just
  after the signature). }
function ReadJxlImageHeaders(Reader: TJxlBitReader): TJxlImageHeaders;
{ The index of the first alpha extra channel, or -1. }
function JxlAlphaChannelIndex(const Metadata: TJxlImageMetadata): LongInt;
{ True when the image has one colour channel. }
function JxlIsGrey(const Metadata: TJxlImageMetadata): Boolean;

implementation

uses
  Image.Jxl.UpsamplingWeights;

procedure RaiseBadHeader(const Detail: string);
begin
  RaiseImageError(ImageErrorMalformed, 'JPEG XL: ' + Detail);
end;

function AspectRatioWidth(Ratio, Height: LongWord): LongWord;
begin
  case Ratio of
    1: Result := Height;
    2: Result := LongWord(QWord(Height) * 12 div 10);
    3: Result := LongWord(QWord(Height) * 4 div 3);
    4: Result := LongWord(QWord(Height) * 3 div 2);
    5: Result := LongWord(QWord(Height) * 16 div 9);
    6: Result := LongWord(QWord(Height) * 5 div 4);
  else
    Result := LongWord(QWord(Height) * 2);
  end;
end;

procedure ReadSizeHeader(Reader: TJxlBitReader; out Width, Height: LongWord);
var
  Small: Boolean;
  Ratio: LongWord;
begin
  Small := Reader.ReadBool;
  if Small then
    Height := (Reader.ReadBits(5) + 1) * 8
  else
    Height := Reader.ReadU32(JxlBitsOffset(9, 1), JxlBitsOffset(13, 1), JxlBitsOffset(18, 1), JxlBitsOffset(30, 1));
  Ratio := Reader.ReadBits(3);
  if Ratio <> 0 then
    Width := AspectRatioWidth(Ratio, Height)
  else if Small then
    Width := (Reader.ReadBits(5) + 1) * 8
  else
    Width := Reader.ReadU32(JxlBitsOffset(9, 1), JxlBitsOffset(13, 1), JxlBitsOffset(18, 1), JxlBitsOffset(30, 1));
end;

procedure ReadPreviewHeader(Reader: TJxlBitReader; out Width, Height: LongWord);
var
  DividedBy8: Boolean;
  Ratio: LongWord;
begin
  DividedBy8 := Reader.ReadBool;
  if DividedBy8 then
    Height := Reader.ReadU32(JxlVal(16), JxlVal(32), JxlBitsOffset(5, 1), JxlBitsOffset(9, 33)) * 8
  else
    Height := Reader.ReadU32(JxlBitsOffset(6, 1), JxlBitsOffset(8, 65), JxlBitsOffset(10, 321),
      JxlBitsOffset(12, 1345));
  Ratio := Reader.ReadBits(3);
  if Ratio <> 0 then
    Width := AspectRatioWidth(Ratio, Height)
  else if DividedBy8 then
    Width := Reader.ReadU32(JxlVal(16), JxlVal(32), JxlBitsOffset(5, 1), JxlBitsOffset(9, 33)) * 8
  else
    Width := Reader.ReadU32(JxlBitsOffset(6, 1), JxlBitsOffset(8, 65), JxlBitsOffset(10, 321),
      JxlBitsOffset(12, 1345));
end;

function ReadBitDepth(Reader: TJxlBitReader): TJxlBitDepth;
var
  MantissaBits: LongInt;
begin
  Result.FloatSample := Reader.ReadBool;
  if not Result.FloatSample then
  begin
    Result.BitsPerSample := Reader.ReadU32(JxlVal(8), JxlVal(10), JxlVal(12), JxlBitsOffset(6, 1));
    Result.ExponentBits := 0;
    if Result.BitsPerSample > 31 then
      RaiseBadHeader('bad bit depth');
  end
  else
  begin
    Result.BitsPerSample := Reader.ReadU32(JxlVal(32), JxlVal(16), JxlVal(24), JxlBitsOffset(6, 1));
    Result.ExponentBits := Reader.ReadBits(4) + 1;
    MantissaBits := LongInt(Result.BitsPerSample) - LongInt(Result.ExponentBits) - 1;
    if (Result.ExponentBits < 2) or (Result.ExponentBits > 8) or (MantissaBits < 2) or (MantissaBits > 23) then
      RaiseBadHeader('bad floating point bit depth');
  end;
end;

function DefaultBitDepth: TJxlBitDepth;
begin
  Result.FloatSample := False;
  Result.BitsPerSample := 8;
  Result.ExponentBits := 0;
end;

function ReadName(Reader: TJxlBitReader): string;
var
  Count: LongWord;
  Index: LongWord;
begin
  Count := Reader.ReadU32(JxlVal(0), JxlBits(4), JxlBitsOffset(5, 16), JxlBitsOffset(10, 48));
  SetLength(Result, Count);
  for Index := 1 to Count do
    Result[Index] := Chr(Reader.ReadBits(8));
end;

function ReadExtraChannelInfo(Reader: TJxlBitReader): TJxlExtraChannelInfo;
var
  Index: LongInt;
begin
  Result := Default(TJxlExtraChannelInfo);
  Result.ChannelType := JxlExtraChannelAlpha;
  Result.BitDepth := DefaultBitDepth;
  Result.CfaChannel := 1;
  if Reader.ReadBool then
    Exit;
  Result.ChannelType := Reader.ReadEnum;
  Result.BitDepth := ReadBitDepth(Reader);
  Result.DimensionShift := Reader.ReadU32(JxlVal(0), JxlVal(3), JxlVal(4), JxlBitsOffset(3, 1));
  if Result.DimensionShift > 3 then
    RaiseBadHeader('extra channel dimension shift too large');
  Result.Name := ReadName(Reader);
  if Result.ChannelType = JxlExtraChannelAlpha then
    Result.AlphaAssociated := Reader.ReadBool;
  if Result.ChannelType = JxlExtraChannelSpotColor then
    for Index := 0 to 3 do
      Result.SpotColor[Index] := Reader.ReadF16;
  if Result.ChannelType = JxlExtraChannelCfa then
    Result.CfaChannel := Reader.ReadU32(JxlVal(1), JxlBits(2), JxlBitsOffset(4, 3), JxlBitsOffset(8, 19));
  if (Result.ChannelType >= 7) and (Result.ChannelType <= JxlExtraChannelUnknown) then
    RaiseImageError(ImageErrorUnsupported, 'JPEG XL: unknown extra channel type');
  if Result.ChannelType > JxlExtraChannelOptional then
    RaiseBadHeader('bad extra channel type');
end;

function ReadChromaticity(Reader: TJxlBitReader): TJxlChromaticity;
begin
  Result.X := JxlUnpackSigned(Reader.ReadU32(JxlBits(19), JxlBitsOffset(19, 524288), JxlBitsOffset(20, 1048576),
    JxlBitsOffset(21, 2097152)));
  Result.Y := JxlUnpackSigned(Reader.ReadU32(JxlBits(19), JxlBitsOffset(19, 524288), JxlBitsOffset(20, 1048576),
    JxlBitsOffset(21, 2097152)));
end;

function DefaultColorEncoding: TJxlColorEncoding;
begin
  Result := Default(TJxlColorEncoding);
  Result.ColorSpace := JxlColorSpaceRgb;
  Result.WhitePoint := JxlWhitePointD65;
  Result.Primaries := JxlPrimariesSrgb;
  Result.TransferFunction := JxlTransferSrgb;
  Result.RenderingIntent := 1;
end;

function ReadColorEncoding(Reader: TJxlBitReader): TJxlColorEncoding;
begin
  Result := DefaultColorEncoding;
  if Reader.ReadBool then
    Exit;
  Result.WantIcc := Reader.ReadBool;
  Result.ColorSpace := Reader.ReadEnum;
  if Result.ColorSpace > JxlColorSpaceUnknown then
    RaiseBadHeader('bad colour space');
  if Result.WantIcc then
    Exit;
  if Result.ColorSpace <> JxlColorSpaceXyb then
  begin
    Result.WhitePoint := Reader.ReadEnum;
    if not (Result.WhitePoint in [JxlWhitePointD65, JxlWhitePointCustom, JxlWhitePointE, JxlWhitePointDci]) then
      RaiseBadHeader('bad white point');
    if Result.WhitePoint = JxlWhitePointCustom then
      Result.White := ReadChromaticity(Reader);
  end;
  if (Result.ColorSpace <> JxlColorSpaceXyb) and (Result.ColorSpace <> JxlColorSpaceGrey) then
  begin
    Result.Primaries := Reader.ReadEnum;
    if not (Result.Primaries in [JxlPrimariesSrgb, JxlPrimariesCustom, JxlPrimaries2100, JxlPrimariesP3]) then
      RaiseBadHeader('bad primaries');
    if Result.Primaries = JxlPrimariesCustom then
    begin
      Result.Red := ReadChromaticity(Reader);
      Result.Green := ReadChromaticity(Reader);
      Result.Blue := ReadChromaticity(Reader);
    end;
  end;
  if Result.ColorSpace = JxlColorSpaceXyb then
  begin
    Result.HaveGamma := True;
    Result.Gamma := 3333333;
  end
  else
  begin
    Result.HaveGamma := Reader.ReadBool;
    if Result.HaveGamma then
    begin
      Result.Gamma := Reader.ReadBits(24);
      if (Result.Gamma = 0) or (Result.Gamma > 10000000) then
        RaiseBadHeader('bad gamma');
    end
    else
    begin
      Result.TransferFunction := Reader.ReadEnum;
      if not (Result.TransferFunction in [JxlTransfer709, JxlTransferUnknown, JxlTransferLinear, JxlTransferSrgb,
        JxlTransferPq, JxlTransferDci, JxlTransferHlg]) then
        RaiseBadHeader('bad transfer function');
    end;
  end;
  Result.RenderingIntent := Reader.ReadEnum;
  if Result.RenderingIntent > 3 then
    RaiseBadHeader('bad rendering intent');
  if (Result.ColorSpace = JxlColorSpaceUnknown) or
    ((not Result.HaveGamma) and (Result.TransferFunction = JxlTransferUnknown)) then
    RaiseImageError(ImageErrorUnsupported, 'JPEG XL: unknown colour space without a profile');
end;

function DefaultToneMapping: TJxlToneMapping;
begin
  Result.IntensityTarget := 255;
  Result.MinimumNits := 0;
  Result.RelativeToMaximumDisplay := False;
  Result.LinearBelow := 0;
end;

function ReadToneMapping(Reader: TJxlBitReader): TJxlToneMapping;
begin
  Result := DefaultToneMapping;
  if Reader.ReadBool then
    Exit;
  Result.IntensityTarget := Reader.ReadF16;
  if Result.IntensityTarget <= 0 then
    RaiseBadHeader('bad intensity target');
  Result.MinimumNits := Reader.ReadF16;
  Result.RelativeToMaximumDisplay := Reader.ReadBool;
  Result.LinearBelow := Reader.ReadF16;
end;

function ReadAnimationHeader(Reader: TJxlBitReader): TJxlAnimationHeader;
begin
  Result.TicksPerSecondNumerator := Reader.ReadU32(JxlVal(100), JxlVal(1000), JxlBitsOffset(10, 1),
    JxlBitsOffset(30, 1));
  Result.TicksPerSecondDenominator := Reader.ReadU32(JxlVal(1), JxlVal(1001), JxlBitsOffset(8, 1),
    JxlBitsOffset(10, 1));
  Result.LoopCount := Reader.ReadU32(JxlVal(0), JxlBits(3), JxlBits(16), JxlBits(32));
  Result.HaveTimecodes := Reader.ReadBool;
end;

function DefaultImageMetadata: TJxlImageMetadata;
begin
  Result := Default(TJxlImageMetadata);
  Result.Orientation := 1;
  Result.BitDepth := DefaultBitDepth;
  Result.Modular16BitBufferSufficient := True;
  Result.XybEncoded := True;
  Result.ColorEncoding := DefaultColorEncoding;
  Result.ToneMapping := DefaultToneMapping;
end;

function ReadImageMetadata(Reader: TJxlBitReader): TJxlImageMetadata;
var
  ExtraFields: Boolean;
  ExtraCount: LongWord;
  Index: LongWord;
begin
  Result := DefaultImageMetadata;
  if Reader.ReadBool then
    Exit;
  ExtraFields := Reader.ReadBool;
  if ExtraFields then
  begin
    Result.Orientation := Reader.ReadBits(3) + 1;
    Result.HaveIntrinsicSize := Reader.ReadBool;
    if Result.HaveIntrinsicSize then
      ReadSizeHeader(Reader, Result.IntrinsicWidth, Result.IntrinsicHeight);
    Result.HavePreview := Reader.ReadBool;
    if Result.HavePreview then
      ReadPreviewHeader(Reader, Result.PreviewWidth, Result.PreviewHeight);
    Result.HaveAnimation := Reader.ReadBool;
    if Result.HaveAnimation then
      Result.Animation := ReadAnimationHeader(Reader);
  end;
  Result.BitDepth := ReadBitDepth(Reader);
  Result.Modular16BitBufferSufficient := Reader.ReadBool;
  ExtraCount := Reader.ReadU32(JxlVal(0), JxlVal(1), JxlBitsOffset(4, 2), JxlBitsOffset(12, 1));
  if ExtraCount > 256 then
    RaiseImageError(ImageErrorUnsupported, 'JPEG XL: too many extra channels');
  SetLength(Result.ExtraChannels, ExtraCount);
  for Index := 1 to ExtraCount do
    Result.ExtraChannels[Index - 1] := ReadExtraChannelInfo(Reader);
  Result.XybEncoded := Reader.ReadBool;
  Result.ColorEncoding := ReadColorEncoding(Reader);
  if ExtraFields then
    Result.ToneMapping := ReadToneMapping(Reader);
  Reader.SkipExtensions;
end;

procedure SetDefaultTransformData(var Transform: TJxlTransformData);
const
  DefaultInverseMatrix: array[0..2, 0..2] of Single = (
    (11.031566901960783, -9.866943921568629, -0.16462299647058826),
    (-3.254147380392157, 4.418770392156863, -0.16462299647058826),
    (-3.6588512862745097, 2.7129230470588235, 1.9459282392156863));
  OpsinAbsorbanceBias = 0.0037930732552754493;
  DefaultQuantBiases: array[0..3] of Single = (
    1.0 - 0.05465007330715401, 1.0 - 0.07005449891748593, 1.0 - 0.049935103337343655, 0.145);
var
  Row: LongInt;
  Column: LongInt;
begin
  for Row := 0 to 2 do
    for Column := 0 to 2 do
      Transform.InverseOpsinMatrix[Row, Column] := DefaultInverseMatrix[Row, Column];
  for Row := 0 to 2 do
    Transform.OpsinBiases[Row] := -OpsinAbsorbanceBias;
  for Row := 0 to 3 do
    Transform.QuantBiases[Row] := DefaultQuantBiases[Row];
  for Row := 0 to 14 do
    Transform.Upsampling2Weights[Row] := JxlDefaultUpsampling2Weights[Row];
  for Row := 0 to 54 do
    Transform.Upsampling4Weights[Row] := JxlDefaultUpsampling4Weights[Row];
  for Row := 0 to 209 do
    Transform.Upsampling8Weights[Row] := JxlDefaultUpsampling8Weights[Row];
end;

procedure ReadTransformData(Reader: TJxlBitReader; XybEncoded: Boolean; var Transform: TJxlTransformData);
var
  Row: LongInt;
  Column: LongInt;
  WeightsMask: LongWord;
begin
  SetDefaultTransformData(Transform);
  if Reader.ReadBool then
    Exit;
  if XybEncoded and not Reader.ReadBool then
  begin
    for Row := 0 to 2 do
      for Column := 0 to 2 do
        Transform.InverseOpsinMatrix[Row, Column] := Reader.ReadF16;
    for Row := 0 to 2 do
      Transform.OpsinBiases[Row] := Reader.ReadF16;
    for Row := 0 to 3 do
      Transform.QuantBiases[Row] := Reader.ReadF16;
  end;
  WeightsMask := Reader.ReadBits(3);
  if (WeightsMask and 1) <> 0 then
    for Row := 0 to 14 do
      Transform.Upsampling2Weights[Row] := Reader.ReadF16;
  if (WeightsMask and 2) <> 0 then
    for Row := 0 to 54 do
      Transform.Upsampling4Weights[Row] := Reader.ReadF16;
  if (WeightsMask and 4) <> 0 then
    for Row := 0 to 209 do
      Transform.Upsampling8Weights[Row] := Reader.ReadF16;
end;

function ReadJxlImageHeaders(Reader: TJxlBitReader): TJxlImageHeaders;
begin
  ReadSizeHeader(Reader, Result.Width, Result.Height);
  Result.Metadata := ReadImageMetadata(Reader);
  ReadTransformData(Reader, Result.Metadata.XybEncoded, Result.Transform);
end;

function JxlAlphaChannelIndex(const Metadata: TJxlImageMetadata): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to High(Metadata.ExtraChannels) do
    if Metadata.ExtraChannels[Index].ChannelType = JxlExtraChannelAlpha then
      Exit(Index);
  Result := -1;
end;

function JxlIsGrey(const Metadata: TJxlImageMetadata): Boolean;
begin
  Result := Metadata.ColorEncoding.ColorSpace = JxlColorSpaceGrey;
end;

end.
