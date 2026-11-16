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
  The modular part of a JPEG XL frame (ISO/IEC 18181-1 annex G.1 to
  G.4): the colour channels of a modular frame and every frame's extra
  channels, as one modular image.

  The LF global section holds the frame's global MA tree (if any) and
  the global stream, which decodes the meta channels and every channel
  up to the group size; the transforms it lists stay until the end. The
  larger channels are then decoded a rectangle at a time: those shifted
  at least three times (the low frequencies of a squeeze pyramid) in
  the LF groups, the others in the pass groups, each pass taking the
  shifts its downsampling allows. Last the global transforms are undone
  and the channels become floating point planes.
}
unit Image.Jxl.ModularFrame;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Jxl.BitReader,
  Image.Jxl.Headers,
  Image.Jxl.FrameHeader,
  Image.Jxl.Planes,
  Image.Jxl.Modular.Channels,
  Image.Jxl.Modular.Tree,
  Image.Jxl.Modular.Decoding;

type
  TJxlModularFrame = class
  private
    FHeaders: TJxlImageHeaders;
    FFrame: TJxlFrameHeader;
    FImage: TJxlModularImage;
    FGlobalTree: TJxlModularTreeCode;
    FGlobalState: TJxlModularStreamState;
    FColorChannelCount: LongInt;
    FDecodesColor: Boolean;
    procedure DecodeRectangle(Reader: TJxlBitReader; X0, Y0, Size: Int64; MinimumShift, MaximumShift: LongInt;
      StreamId: LongInt);
    function ChannelToPlane(Channel: TJxlChannel; Factor: Double; FloatSamples: Boolean;
      const BitDepth: TJxlBitDepth): TJxlPlane;
  public
    constructor Create(const Headers: TJxlImageHeaders; const Frame: TJxlFrameHeader);
    destructor Destroy; override;
    { The global tree flag, tree and the global stream (LF global). }
    procedure ReadGlobal(Reader: TJxlBitReader);
    { The modular data of an LF group, after its VarDCT part. }
    procedure ReadLowFrequencyGroup(Reader: TJxlBitReader; Group: LongInt);
    { The modular data of a pass group, after its VarDCT part. }
    procedure ReadPassGroup(Reader: TJxlBitReader; Pass, Group: LongInt);
    { Undoes the global transforms (after every section). }
    procedure Finish;
    { The colour planes (three; a grey image's one channel repeated) of
      a modular frame; XYB channels are scaled by the LF dequantization
      as libjxl does. }
    function ColorPlanes(const Dequantization: TJxlLowFrequencyDequantization): TJxlPlaneSet;
    { Extra channel Index as a plane at its coded size. }
    function ExtraChannelPlane(Index: LongInt): TJxlPlane;
    property GlobalTree: TJxlModularTreeCode read FGlobalTree;
  end;

implementation

const
  QuantTableCount = 17;

procedure RaiseBadModularFrame(const Detail: string);
begin
  RaiseImageError(ImageErrorMalformed, 'JPEG XL modular frame: ' + Detail);
end;

function CeilLog2(Value: LongWord): LongInt;
begin
  Result := 0;
  while (LongWord(1) shl Result) < Value do
    Inc(Result);
end;

function DivideRoundingUp(Value, Divisor: Int64): Int64;
begin
  Result := (Value + Divisor - 1) div Divisor;
end;

constructor TJxlModularFrame.Create(const Headers: TJxlImageHeaders; const Frame: TJxlFrameHeader);
var
  Channel: LongInt;
  ExtraIndex: LongInt;
  Upsampling: LongWord;
  Item: TJxlChannel;
  Dimensions: TJxlFrameDimensions;
  Shift: LongInt;
begin
  inherited Create;
  FHeaders := Headers;
  FFrame := Frame;
  FImage := TJxlModularImage.Create;
  FImage.BitDepth := Headers.Metadata.BitDepth.BitsPerSample;
  Dimensions := Frame.Dimensions;
  FDecodesColor := Frame.Encoding = JxlEncodingModular;
  FColorChannelCount := 0;
  if FDecodesColor then
  begin
    if JxlIsGrey(Headers.Metadata) and (Frame.ColorTransform = JxlColorTransformNone) then
      FColorChannelCount := 1
    else
      FColorChannelCount := 3;
  end;
  if FDecodesColor and (Headers.Metadata.BitDepth.BitsPerSample >= 32) and
    (Frame.ColorTransform <> JxlColorTransformXyb) and not Headers.Metadata.BitDepth.FloatSample then
    RaiseImageError(ImageErrorUnsupported, 'JPEG XL: 32-bit integer samples');
  for Channel := 0 to FColorChannelCount - 1 do
  begin
    Item := TJxlChannel.Create(Dimensions.Width, Dimensions.Height);
    if Frame.ColorTransform = JxlColorTransformYCbCr then
    begin
      Item.HorizontalShift := JxlChromaHorizontalShift(Frame, Channel);
      Item.VerticalShift := JxlChromaVerticalShift(Frame, Channel);
      Item.Resize(DivideRoundingUp(Dimensions.Width, Int64(1) shl Item.HorizontalShift),
        DivideRoundingUp(Dimensions.Height, Int64(1) shl Item.VerticalShift));
    end;
    FImage.AddChannel(Item);
  end;
  for ExtraIndex := 0 to High(Headers.Metadata.ExtraChannels) do
  begin
    Upsampling := Frame.ExtraChannelUpsampling[ExtraIndex];
    Shift := CeilLog2(Upsampling) - CeilLog2(Frame.Upsampling);
    Item := TJxlChannel.Create(DivideRoundingUp(Dimensions.UpsampledWidth, Upsampling),
      DivideRoundingUp(Dimensions.UpsampledHeight, Upsampling), Shift, Shift);
    FImage.AddChannel(Item);
  end;
  FGlobalState.Transforms := nil;
end;

destructor TJxlModularFrame.Destroy;
begin
  FGlobalTree.Free;
  FImage.Free;
  inherited Destroy;
end;

procedure TJxlModularFrame.ReadGlobal(Reader: TJxlBitReader);
var
  TreeSizeLimit: Int64;
begin
  if Reader.ReadBool then
  begin
    TreeSizeLimit := 1024 + Int64(FFrame.Dimensions.Width) * FFrame.Dimensions.Height *
      (FColorChannelCount + Length(FHeaders.Metadata.ExtraChannels)) div 16;
    if TreeSizeLimit > 1 shl 22 then
      TreeSizeLimit := 1 shl 22;
    FGlobalTree := ReadJxlModularTreeCode(Reader, TreeSizeLimit);
  end;
  DecodeJxlModularStream(Reader, FImage, 0, FFrame.Dimensions.GroupDimension, FGlobalTree, False, FGlobalState);
end;

procedure TJxlModularFrame.DecodeRectangle(Reader: TJxlBitReader; X0, Y0, Size: Int64;
  MinimumShift, MaximumShift: LongInt; StreamId: LongInt);
var
  First: LongInt;
  Index: LongInt;
  Channel: TJxlChannel;
  Shift: LongInt;
  Part: TJxlModularImage;
  PartChannel: TJxlChannel;
  Left: Int64;
  Top: Int64;
  Width: Int64;
  Height: Int64;
  Sources: array of LongInt;
  Lefts: array of Int64;
  Tops: array of Int64;
  State: TJxlModularStreamState;
  Y: LongInt;
begin
  First := FImage.MetaChannelCount;
  while (First < FImage.ChannelCount) and
    (FImage[First].Width <= FFrame.Dimensions.GroupDimension) and
    (FImage[First].Height <= FFrame.Dimensions.GroupDimension) do
    Inc(First);
  Part := TJxlModularImage.Create;
  try
    Part.BitDepth := FImage.BitDepth;
    Sources := nil;
    for Index := First to FImage.ChannelCount - 1 do
    begin
      Channel := FImage[Index];
      Shift := Channel.HorizontalShift;
      if Channel.VerticalShift < Shift then
        Shift := Channel.VerticalShift;
      if (Shift > MaximumShift) or (Shift < MinimumShift) then
        Continue;
      if (Channel.HorizontalShift < 0) or (Channel.VerticalShift < 0) then
        Continue;
      Left := X0 shr Channel.HorizontalShift;
      Top := Y0 shr Channel.VerticalShift;
      Width := Size shr Channel.HorizontalShift;
      Height := Size shr Channel.VerticalShift;
      if Left + Width > Channel.Width then
        Width := Channel.Width - Left;
      if Top + Height > Channel.Height then
        Height := Channel.Height - Top;
      if (Width <= 0) or (Height <= 0) then
        Continue;
      Part.AddChannel(TJxlChannel.Create(Width, Height, Channel.HorizontalShift, Channel.VerticalShift));
      SetLength(Sources, Length(Sources) + 1);
      SetLength(Lefts, Length(Sources));
      SetLength(Tops, Length(Sources));
      Sources[High(Sources)] := Index;
      Lefts[High(Sources)] := Left;
      Tops[High(Sources)] := Top;
    end;
    if Part.ChannelCount = 0 then
      Exit;
    DecodeJxlModularStream(Reader, Part, StreamId, High(LongInt), FGlobalTree, True, State);
    if Part.ChannelCount <> Length(Sources) then
      RaiseBadModularFrame('group transforms changed the channels');
    for Index := 0 to High(Sources) do
    begin
      PartChannel := Part[Index];
      Channel := FImage[Sources[Index]];
      for Y := 0 to PartChannel.Height - 1 do
        Move(PartChannel.Row(Y)^, (Channel.Row(Tops[Index] + Y) + Lefts[Index])^,
          SizeOf(LongInt) * PartChannel.Width);
    end;
  finally
    Part.Free;
  end;
end;

procedure TJxlModularFrame.ReadLowFrequencyGroup(Reader: TJxlBitReader; Group: LongInt);
var
  Dimensions: TJxlFrameDimensions;
  Column: LongInt;
  Row: LongInt;
begin
  Dimensions := FFrame.Dimensions;
  Column := Group mod Dimensions.LowFrequencyGroupColumns;
  Row := Group div Dimensions.LowFrequencyGroupColumns;
  DecodeRectangle(Reader, Int64(Column) * Dimensions.LowFrequencyGroupDimension,
    Int64(Row) * Dimensions.LowFrequencyGroupDimension, Dimensions.LowFrequencyGroupDimension, 3, 1000,
    1 + Dimensions.LowFrequencyGroupCount + Group);
end;

procedure TJxlModularFrame.ReadPassGroup(Reader: TJxlBitReader; Pass, Group: LongInt);
var
  Dimensions: TJxlFrameDimensions;
  Column: LongInt;
  Row: LongInt;
  MinimumShift: LongInt;
  MaximumShift: LongInt;
begin
  Dimensions := FFrame.Dimensions;
  Column := Group mod Dimensions.GroupColumns;
  Row := Group div Dimensions.GroupColumns;
  JxlPassShiftRange(FFrame.Passes, Pass, MinimumShift, MaximumShift);
  DecodeRectangle(Reader, Int64(Column) * Dimensions.GroupDimension, Int64(Row) * Dimensions.GroupDimension,
    Dimensions.GroupDimension, MinimumShift, MaximumShift,
    1 + 3 * Dimensions.LowFrequencyGroupCount + QuantTableCount + Dimensions.GroupCount * Pass + Group);
end;

procedure TJxlModularFrame.Finish;
begin
  JxlUndoModularTransforms(FImage, FGlobalState);
  FGlobalState.Transforms := nil;
  if FImage.ChannelCount <> FColorChannelCount + Length(FHeaders.Metadata.ExtraChannels) then
    RaiseBadModularFrame('transforms left the wrong number of channels');
end;

function FloatFromBits(Bits: LongWord; BitCount, ExponentBits: LongInt): Single;
var
  ExponentBias: LongInt;
  SignShift: LongInt;
  MantissaBits: LongInt;
  MantissaShift: LongInt;
  Sign: LongWord;
  Exponent: LongInt;
  Mantissa: LongWord;
  Value: LongWord;
begin
  if BitCount = 32 then
  begin
    Move(Bits, Result, SizeOf(Result));
    Exit;
  end;
  ExponentBias := (1 shl (ExponentBits - 1)) - 1;
  SignShift := BitCount - 1;
  MantissaBits := BitCount - ExponentBits - 1;
  MantissaShift := 23 - MantissaBits;
  Sign := (Bits shr SignShift) and 1;
  Bits := Bits and ((LongWord(1) shl SignShift) - 1);
  if Bits = 0 then
  begin
    if Sign <> 0 then
      Result := -0.0
    else
      Result := 0.0;
    Exit;
  end;
  Exponent := LongInt(Bits shr MantissaBits);
  Mantissa := (Bits and ((LongWord(1) shl MantissaBits) - 1)) shl MantissaShift;
  if (Exponent = 0) and (ExponentBits < 8) then
  begin
    while (Mantissa and $800000) = 0 do
    begin
      Mantissa := Mantissa shl 1;
      Dec(Exponent);
    end;
    Inc(Exponent);
    Mantissa := Mantissa and $7FFFFF;
  end;
  Exponent := Exponent - ExponentBias + 127;
  Value := (Sign shl 31) or (LongWord(Exponent and $FF) shl 23) or Mantissa;
  Move(Value, Result, SizeOf(Result));
end;

function TJxlModularFrame.ChannelToPlane(Channel: TJxlChannel; Factor: Double; FloatSamples: Boolean;
  const BitDepth: TJxlBitDepth): TJxlPlane;
var
  Index: PtrInt;
  Count: PtrInt;
begin
  Result := TJxlPlane.Create(Channel.Width, Channel.Height);
  Count := PtrInt(Channel.Width) * Channel.Height;
  if FloatSamples then
    for Index := 0 to Count - 1 do
      Result.Samples[Index] := FloatFromBits(LongWord(Channel.Pixels[Index]), BitDepth.BitsPerSample,
        BitDepth.ExponentBits)
  else
    for Index := 0 to Count - 1 do
      Result.Samples[Index] := Channel.Pixels[Index] * Factor;
end;

function TJxlModularFrame.ColorPlanes(const Dequantization: TJxlLowFrequencyDequantization): TJxlPlaneSet;
var
  Factor: Double;
  FloatSamples: Boolean;
  BitDepth: TJxlBitDepth;
  Channel: LongInt;
  Index: PtrInt;
  Luma: TJxlChannel;
  Blue: TJxlChannel;
begin
  Result := nil;
  if not FDecodesColor then
    RaiseBadModularFrame('no colour channels');
  BitDepth := FHeaders.Metadata.BitDepth;
  SetLength(Result, 3);
  try
    for Channel := 0 to 2 do
    begin
      if FImage[0].Width * FImage[0].Height = 0 then
        RaiseBadModularFrame('empty image');
      if FColorChannelCount = 1 then
      begin
        if BitDepth.FloatSample then
          Result[Channel] := ChannelToPlane(FImage[0], 0, True, BitDepth)
        else
          Result[Channel] := ChannelToPlane(FImage[0], 1.0 / ((QWord(1) shl BitDepth.BitsPerSample) - 1), False,
            BitDepth);
      end
      else if FFrame.ColorTransform = JxlColorTransformXyb then
      begin
        Factor := Dequantization[Channel];
        case Channel of
          0: Result[Channel] := ChannelToPlane(FImage[1], Factor, False, BitDepth);
          1: Result[Channel] := ChannelToPlane(FImage[0], Factor, False, BitDepth);
        else
          begin
            Luma := FImage[0];
            Blue := FImage[2];
            if (Luma.Width <> Blue.Width) or (Luma.Height <> Blue.Height) then
              RaiseBadModularFrame('XYB channels of different sizes');
            Result[Channel] := TJxlPlane.Create(Blue.Width, Blue.Height);
            for Index := 0 to PtrInt(Blue.Width) * Blue.Height - 1 do
              Result[Channel].Samples[Index] := (Int64(Blue.Pixels[Index]) + Luma.Pixels[Index]) * Factor;
          end;
        end;
      end
      else
      begin
        FloatSamples := BitDepth.FloatSample;
        if FloatSamples then
          Factor := 0
        else
          Factor := 1.0 / ((QWord(1) shl BitDepth.BitsPerSample) - 1);
        Result[Channel] := ChannelToPlane(FImage[Channel], Factor, FloatSamples, BitDepth);
      end;
    end;
  except
    FreeJxlPlanes(Result);
    raise;
  end;
end;

function TJxlModularFrame.ExtraChannelPlane(Index: LongInt): TJxlPlane;
var
  BitDepth: TJxlBitDepth;
  Factor: Double;
begin
  BitDepth := FHeaders.Metadata.ExtraChannels[Index].BitDepth;
  if BitDepth.FloatSample then
    Factor := 0
  else
  begin
    if BitDepth.BitsPerSample >= 32 then
      RaiseImageError(ImageErrorUnsupported, 'JPEG XL: 32-bit integer extra channel');
    Factor := 1.0 / ((QWord(1) shl BitDepth.BitsPerSample) - 1);
  end;
  Result := ChannelToPlane(FImage[FColorChannelCount + Index], Factor, BitDepth.FloatSample, BitDepth);
end;

end.
