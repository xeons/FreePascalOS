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
  A JPEG XL VarDCT frame (ISO/IEC 18181-1 annex I), as the frame
  decoder hands it its sections:

  - LF global: the quantizer (global scale and LF quantization), the
    block context map and the LF chroma-from-luma factors;
  - each LF group: the quantized LF image of its blocks (a modular
    stream; or nothing when an LF frame supplies the LF), then, after
    the frame decoder's own modular part, the AC metadata: the
    chroma-from-luma factors of each 64 x 64 tile, the transform and
    quantization field of each varblock and the edge preserving
    filter's sharpness of each block;
  - HF global: the dequantization matrices, the number of histogram
    sets, and per pass the coefficient orders and AC histograms;
  - each pass of each group: the AC coefficients, added over the
    passes; after the last pass the group is dequantized, its lowest
    frequencies taken from the LF image, and transformed into pixels.

  Render gives the three planes (X, Y, B; or Cb, Y, Cr with chroma
  upsampled) of the frame's size and the edge preserving filter's sigma
  per block.
}
unit Image.Jxl.VarDct;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Math,
  Image.Errors,
  Image.Jxl.BitReader,
  Image.Jxl.Entropy,
  Image.Jxl.Headers,
  Image.Jxl.FrameHeader,
  Image.Jxl.Planes,
  Image.Jxl.Modular.Tree,
  Image.Jxl.EdgePreserving,
  Image.Jxl.VarDct.Strategies,
  Image.Jxl.VarDct.BlockContext,
  Image.Jxl.VarDct.QuantWeights,
  Image.Jxl.VarDct.CoefficientOrders;

type
  TJxlGroupCoefficients = array[0..2] of array of LongInt;

  TJxlVarDctFrame = class
  private
    FHeaders: TJxlImageHeaders;
    FFrame: TJxlFrameHeader;
    FLowFrequencyDequantization: TJxlLowFrequencyDequantization;
    FGlobalTree: TJxlModularTreeCode;
    FBlocksX: LongInt;
    FBlocksY: LongInt;
    FGroupBlocks: LongInt;
    FHorizontalShift: array[0..2] of LongInt;
    FVerticalShift: array[0..2] of LongInt;
    FIs444: Boolean;
    FGlobalScale: LongInt;
    FQuantLowFrequency: LongInt;
    FInverseGlobalScale: Single;
    FGlobalScaleFloat: Single;
    FLowFrequencySteps: array[0..2] of Single;
    FBlockMap: TJxlBlockContextMap;
    FColorFactor: LongWord;
    FColorScale: Single;
    FBaseCorrelationX: Single;
    FBaseCorrelationB: Single;
    FYToXLowFrequency: LongInt;
    FYToBLowFrequency: LongInt;
    FTileColumns: LongInt;
    FTileRows: LongInt;
    FYToXMap: array of ShortInt;
    FYToBMap: array of ShortInt;
    FLowFrequency: array[0..2] of TJxlPlane;
    FLowFrequencyFrame: TJxlPlaneSet;
    FLowFrequencyContexts: array of Byte;
    FStrategies: array of Byte;
    FQuantField: array of LongInt;
    FSharpness: array of Byte;
    FSigma: TJxlEpfSigma;
    FUsedStrategies: LongWord;
    FDequant: TJxlDequantMatrices;
    FHistogramSets: LongInt;
    FPassCodes: array of TJxlEntropyCode;
    FPassOrders: array of TJxlPassCoefficientOrders;
    FGroupCoefficients: array of TJxlGroupCoefficients;
    FGroupPasses: array of LongInt;
    FGroupDrawn: array of Boolean;
    FPixels: array[0..2] of TJxlPlane;
    FLowFrequencyFinalized: Boolean;
    FXMultiplier: Single;
    FBMultiplier: Single;
    FScratch: array of Single;
    FBlockBuffer: array of Single;
    procedure FinalizeLowFrequency;
    procedure GroupBlockRect(Group: LongInt; out X0, Y0, Width, Height: LongInt);
    procedure LowFrequencyGroupRect(Group: LongInt; out X0, Y0, Width, Height: LongInt);
    procedure EnsureGroupCoefficients(Group: LongInt);
    procedure DrawGroup(Group: LongInt);
    procedure ComputeSigma(X0, Y0, Width, Height: LongInt);
    function MakeOutputPlane(Channel: LongInt): TJxlPlane;
  public
    constructor Create(const Headers: TJxlImageHeaders; const Frame: TJxlFrameHeader;
      const LowFrequencyDequantization: TJxlLowFrequencyDequantization);
    destructor Destroy; override;
    procedure ReadGlobal(Reader: TJxlBitReader);
    procedure SetLowFrequencyFrame(const Planes: TJxlPlaneSet);
    procedure ReadLowFrequencyGroup(Reader: TJxlBitReader; Group: LongInt);
    procedure ReadAcMetadata(Reader: TJxlBitReader; Group: LongInt);
    procedure ReadHighFrequencyGlobal(Reader: TJxlBitReader);
    procedure ReadPassGroup(Reader: TJxlBitReader; Pass, Group: LongInt);
    procedure Render(out Planes: TJxlPlaneSet; out Sigma: TJxlEpfSigma);
    property GlobalTree: TJxlModularTreeCode read FGlobalTree write FGlobalTree;
  end;

implementation

uses
  Image.Jxl.Modular.Channels,
  Image.Jxl.Modular.Decoding,
  Image.Jxl.VarDct.LowFrequency,
  Image.Jxl.VarDct.Dequantization,
  Image.Jxl.VarDct.AcDecoding,
  Image.Jxl.VarDct.Transforms;

const
  InvalidStrategy = $FF;
  ColorTileBlocks = 8;
  DefaultColorFactor = 84;
  QuantMaximum = 256;
  EpfSharpEntries = 8;

procedure RaiseBadVarDct(const Detail: string);
begin
  RaiseImageError(ImageErrorMalformed, 'JPEG XL VarDCT: ' + Detail);
end;

function CeilLog2(Value: Int64): LongInt;
begin
  Result := 0;
  while (Int64(1) shl Result) < Value do
    Inc(Result);
end;

function DivideRoundingUp(Value, Divisor: LongInt): LongInt;
begin
  Result := (Value + Divisor - 1) div Divisor;
end;

constructor TJxlVarDctFrame.Create(const Headers: TJxlImageHeaders; const Frame: TJxlFrameHeader;
  const LowFrequencyDequantization: TJxlLowFrequencyDequantization);
var
  Channel: LongInt;
  BlockCount: PtrInt;
  Index: PtrInt;
begin
  inherited Create;
  FHeaders := Headers;
  FFrame := Frame;
  FLowFrequencyDequantization := LowFrequencyDequantization;
  FBlocksX := Frame.Dimensions.WidthInBlocks;
  FBlocksY := Frame.Dimensions.HeightInBlocks;
  FGroupBlocks := Frame.Dimensions.GroupDimension div 8;
  FIs444 := True;
  for Channel := 0 to 2 do
  begin
    FHorizontalShift[Channel] := JxlChromaHorizontalShift(Frame, Channel);
    FVerticalShift[Channel] := JxlChromaVerticalShift(Frame, Channel);
    if (FHorizontalShift[Channel] <> 0) or (FVerticalShift[Channel] <> 0) then
      FIs444 := False;
  end;
  CheckJxlPlaneSize(Int64(FBlocksX) * 8, Int64(FBlocksY) * 8);
  BlockCount := PtrInt(FBlocksX) * FBlocksY;
  SetLength(FStrategies, BlockCount);
  for Index := 0 to BlockCount - 1 do
    FStrategies[Index] := InvalidStrategy;
  SetLength(FQuantField, BlockCount);
  SetLength(FSharpness, BlockCount);
  SetLength(FLowFrequencyContexts, BlockCount);
  FSigma := JxlConstantEpfSigma(FBlocksX * 8, FBlocksY * 8, JxlInverseSigmaNumerator);
  for Channel := 0 to 2 do
  begin
    FPixels[Channel] := TJxlPlane.Create((FBlocksX * 8) shr FHorizontalShift[Channel],
      (FBlocksY * 8) shr FVerticalShift[Channel]);
    if (Frame.Flags and JxlFlagUseLowFrequencyFrame) = 0 then
      FLowFrequency[Channel] := TJxlPlane.Create(FBlocksX shr FHorizontalShift[Channel],
        FBlocksY shr FVerticalShift[Channel]);
  end;
  { The quantizer's defaults, before the LF global section. }
  FQuantLowFrequency := 64;
  FGlobalScale := 65536 div 64;
  FInverseGlobalScale := 65536.0 / FGlobalScale;
  FGlobalScaleFloat := FGlobalScale * (1.0 / 65536);
  FBlockMap := DefaultJxlBlockContextMap;
  FColorFactor := DefaultColorFactor;
  FColorScale := 1.0 / FColorFactor;
  FBaseCorrelationX := 0;
  FBaseCorrelationB := 1.0;
  FTileColumns := DivideRoundingUp(Frame.Dimensions.Width, 64);
  FTileRows := DivideRoundingUp(Frame.Dimensions.Height, 64);
  SetLength(FYToXMap, PtrInt(FTileColumns) * FTileRows);
  SetLength(FYToBMap, PtrInt(FTileColumns) * FTileRows);
  FXMultiplier := Power(1 / 1.25, LongInt(Frame.XQmScale) - 2.0);
  FBMultiplier := Power(1 / 1.25, LongInt(Frame.BQmScale) - 2.0);
  FDequant := TJxlDequantMatrices.Create;
  SetLength(FGroupCoefficients, Frame.Dimensions.GroupCount);
  SetLength(FGroupPasses, Frame.Dimensions.GroupCount);
  SetLength(FGroupDrawn, Frame.Dimensions.GroupCount);
  SetLength(FScratch, JxlTransformScratchSize);
  SetLength(FBlockBuffer, 3 * 256 * 256);
end;

destructor TJxlVarDctFrame.Destroy;
var
  Channel: LongInt;
  Index: LongInt;
begin
  for Channel := 0 to 2 do
  begin
    FPixels[Channel].Free;
    FLowFrequency[Channel].Free;
  end;
  for Index := 0 to High(FPassCodes) do
    FPassCodes[Index].Free;
  FDequant.Free;
  inherited Destroy;
end;

procedure TJxlVarDctFrame.ReadGlobal(Reader: TJxlBitReader);
var
  Channel: LongInt;
  InverseQuantLowFrequency: Single;
begin
  FGlobalScale := LongInt(Reader.ReadU32(JxlBitsOffset(11, 1), JxlBitsOffset(11, 2049), JxlBitsOffset(12, 4097),
    JxlBitsOffset(16, 8193)));
  FQuantLowFrequency := LongInt(Reader.ReadU32(JxlVal(16), JxlBitsOffset(5, 1), JxlBitsOffset(8, 1),
    JxlBitsOffset(16, 1)));
  FGlobalScaleFloat := FGlobalScale * (1.0 / 65536);
  FInverseGlobalScale := 65536.0 / FGlobalScale;
  InverseQuantLowFrequency := FInverseGlobalScale / FQuantLowFrequency;
  for Channel := 0 to 2 do
    FLowFrequencySteps[Channel] := InverseQuantLowFrequency * FLowFrequencyDequantization[Channel];
  FBlockMap := ReadJxlBlockContextMap(Reader);
  if not Reader.ReadBool then
  begin
    FColorFactor := Reader.ReadU32(JxlVal(DefaultColorFactor), JxlVal(256), JxlBitsOffset(8, 2),
      JxlBitsOffset(16, 258));
    if FColorFactor = 0 then
      RaiseBadVarDct('bad colour factor');
    FColorScale := 1.0 / FColorFactor;
    FBaseCorrelationX := Reader.ReadF16;
    if Abs(FBaseCorrelationX) > 4 then
      RaiseBadVarDct('base X correlation out of range');
    FBaseCorrelationB := Reader.ReadF16;
    if Abs(FBaseCorrelationB) > 4 then
      RaiseBadVarDct('base B correlation out of range');
    FYToXLowFrequency := LongInt(Reader.ReadBits(8)) - 128;
    FYToBLowFrequency := LongInt(Reader.ReadBits(8)) - 128;
  end;
end;

procedure TJxlVarDctFrame.SetLowFrequencyFrame(const Planes: TJxlPlaneSet);
begin
  FLowFrequencyFrame := Planes;
end;

procedure TJxlVarDctFrame.LowFrequencyGroupRect(Group: LongInt; out X0, Y0, Width, Height: LongInt);
var
  Dimension: LongInt;
begin
  Dimension := FFrame.Dimensions.GroupDimension;
  X0 := (Group mod FFrame.Dimensions.LowFrequencyGroupColumns) * Dimension;
  Y0 := (Group div FFrame.Dimensions.LowFrequencyGroupColumns) * Dimension;
  Width := Min(Dimension, FBlocksX - X0);
  Height := Min(Dimension, FBlocksY - Y0);
  if (Width <= 0) or (Height <= 0) then
    RaiseBadVarDct('bad LF group');
end;

procedure TJxlVarDctFrame.GroupBlockRect(Group: LongInt; out X0, Y0, Width, Height: LongInt);
begin
  X0 := (Group mod FFrame.Dimensions.GroupColumns) * FGroupBlocks;
  Y0 := (Group div FFrame.Dimensions.GroupColumns) * FGroupBlocks;
  Width := Min(FGroupBlocks, FBlocksX - X0);
  Height := Min(FGroupBlocks, FBlocksY - Y0);
  if (Width <= 0) or (Height <= 0) then
    RaiseBadVarDct('bad group');
end;

procedure TJxlVarDctFrame.ReadLowFrequencyGroup(Reader: TJxlBitReader; Group: LongInt);
var
  X0: LongInt;
  Y0: LongInt;
  Width: LongInt;
  Height: LongInt;
  ExtraPrecision: LongInt;
  Multiplier: Single;
  Image: TJxlModularImage;
  State: TJxlModularStreamState;
  Channel: LongInt;
  ImageChannel: LongInt;
  X: LongInt;
  Y: LongInt;
  Factors: array[0..2] of Single;
  FromYToX: Single;
  FromYToB: Single;
  LineX: PLongInt;
  LineY: PLongInt;
  LineB: PLongInt;
  Output: PSingle;
  OutputX: PSingle;
  OutputY: PSingle;
  OutputB: PSingle;
  Source: PLongInt;
  ChannelWidth: LongInt;
  ChannelHeight: LongInt;
  Bucket: array[0..2] of LongInt;
  Threshold: LongInt;
  Value: LongInt;
begin
  if (FFrame.Flags and JxlFlagUseLowFrequencyFrame) <> 0 then
    Exit;
  LowFrequencyGroupRect(Group, X0, Y0, Width, Height);
  ExtraPrecision := LongInt(Reader.ReadBits(2));
  Multiplier := 1.0 / (1 shl ExtraPrecision);
  Image := TJxlModularImage.Create;
  try
    Image.BitDepth := FHeaders.Metadata.BitDepth.BitsPerSample;
    for ImageChannel := 0 to 2 do
    begin
      if ImageChannel < 2 then
        Channel := ImageChannel xor 1
      else
        Channel := ImageChannel;
      Image.AddChannel(TJxlChannel.Create(Width shr FHorizontalShift[Channel], Height shr FVerticalShift[Channel]));
    end;
    DecodeJxlModularStream(Reader, Image, 1 + Group, High(Int64), FGlobalTree, True, State);
    if Image.ChannelCount <> 3 then
      RaiseBadVarDct('LF image lost channels');
    for Channel := 0 to 2 do
      Factors[Channel] := FLowFrequencySteps[Channel] * Multiplier;
    if FIs444 then
    begin
      FromYToX := FBaseCorrelationX + FYToXLowFrequency * FColorScale;
      FromYToB := FBaseCorrelationB + FYToBLowFrequency * FColorScale;
      for Y := 0 to Height - 1 do
      begin
        LineY := Image[0].Row(Y);
        LineX := Image[1].Row(Y);
        LineB := Image[2].Row(Y);
        OutputX := FLowFrequency[0].Row(Y0 + Y) + X0;
        OutputY := FLowFrequency[1].Row(Y0 + Y) + X0;
        OutputB := FLowFrequency[2].Row(Y0 + Y) + X0;
        for X := 0 to Width - 1 do
        begin
          OutputY[X] := LineY[X] * Factors[1];
          OutputX[X] := OutputY[X] * FromYToX + LineX[X] * Factors[0];
          OutputB[X] := OutputY[X] * FromYToB + LineB[X] * Factors[2];
        end;
      end;
    end
    else
      for Channel := 0 to 2 do
      begin
        if Channel < 2 then
          ImageChannel := Channel xor 1
        else
          ImageChannel := Channel;
        ChannelWidth := Width shr FHorizontalShift[Channel];
        ChannelHeight := Height shr FVerticalShift[Channel];
        for Y := 0 to ChannelHeight - 1 do
        begin
          Source := Image[ImageChannel].Row(Y);
          Output := FLowFrequency[Channel].Row((Y0 shr FVerticalShift[Channel]) + Y) +
            (X0 shr FHorizontalShift[Channel]);
          for X := 0 to ChannelWidth - 1 do
            Output[X] := Source[X] * Factors[Channel];
        end;
      end;
    { The LF context of each block, from the quantized LF values. }
    if FBlockMap.LowFrequencyContextCount > 1 then
      for Y := 0 to Height - 1 do
        for X := 0 to Width - 1 do
        begin
          for Channel := 0 to 2 do
          begin
            if Channel < 2 then
              ImageChannel := Channel xor 1
            else
              ImageChannel := Channel;
            Value := Image[ImageChannel].Row(Y shr FVerticalShift[Channel])[X shr FHorizontalShift[Channel]];
            Bucket[Channel] := 0;
            for Threshold := 0 to High(FBlockMap.LowFrequencyThresholds[Channel]) do
              if Value > FBlockMap.LowFrequencyThresholds[Channel][Threshold] then
                Inc(Bucket[Channel]);
          end;
          Value := Bucket[0];
          Value := Value * (Length(FBlockMap.LowFrequencyThresholds[2]) + 1) + Bucket[2];
          Value := Value * (Length(FBlockMap.LowFrequencyThresholds[1]) + 1) + Bucket[1];
          FLowFrequencyContexts[PtrInt(Y0 + Y) * FBlocksX + X0 + X] := Value;
        end;
  finally
    Image.Free;
  end;
end;

procedure TJxlVarDctFrame.ComputeSigma(X0, Y0, Width, Height: LongInt);
var
  X: LongInt;
  Y: LongInt;
  Strategy: LongInt;
  Value: Byte;
  SigmaQuant: Single;
  Sigma: Single;
  InnerX: LongInt;
  InnerY: LongInt;
  Position: PtrInt;
begin
  for Y := Y0 to Y0 + Height - 1 do
    for X := X0 to X0 + Width - 1 do
    begin
      Value := FStrategies[PtrInt(Y) * FBlocksX + X];
      if (Value = InvalidStrategy) or ((Value and 1) = 0) then
        Continue;
      Strategy := Value shr 1;
      SigmaQuant := FFrame.LoopFilter.EpfQuantMultiplier /
        (FGlobalScaleFloat * FQuantField[PtrInt(Y) * FBlocksX + X] * JxlInverseSigmaNumerator);
      for InnerY := 0 to JxlStrategyBlocksY[Strategy] - 1 do
        for InnerX := 0 to JxlStrategyBlocksX[Strategy] - 1 do
        begin
          Position := PtrInt(Y + InnerY) * FBlocksX + X + InnerX;
          Sigma := SigmaQuant * FFrame.LoopFilter.EpfSharpLut[FSharpness[Position]];
          if Sigma > -1e-4 then
            Sigma := -1e-4;
          FSigma.InverseSigma[Position] := 1.0 / Sigma;
        end;
    end;
end;

procedure TJxlVarDctFrame.ReadAcMetadata(Reader: TJxlBitReader; Group: LongInt);
var
  X0: LongInt;
  Y0: LongInt;
  Width: LongInt;
  Height: LongInt;
  Count: LongInt;
  Image: TJxlModularImage;
  State: TJxlModularStreamState;
  TileX0: LongInt;
  TileY0: LongInt;
  TileWidth: LongInt;
  TileHeight: LongInt;
  X: LongInt;
  Y: LongInt;
  Value: LongInt;
  Used: LongInt;
  Strategy: LongInt;
  Sharpness: LongInt;
  XLimit: LongInt;
  YLimit: LongInt;
  InnerX: LongInt;
  InnerY: LongInt;
  StrategyLine: PLongInt;
  QuantLine: PLongInt;

  function ClampToShortInt(Number: LongInt): ShortInt;
  begin
    if Number < -128 then
      Number := -128;
    if Number > 127 then
      Number := 127;
    Result := Number;
  end;

begin
  LowFrequencyGroupRect(Group, X0, Y0, Width, Height);
  Count := LongInt(Reader.ReadBits(CeilLog2(Int64(Width) * Height))) + 1;
  TileX0 := X0 shr 3;
  TileY0 := Y0 shr 3;
  TileWidth := (Width + 7) shr 3;
  TileHeight := (Height + 7) shr 3;
  Image := TJxlModularImage.Create;
  try
    Image.BitDepth := FHeaders.Metadata.BitDepth.BitsPerSample;
    Image.AddChannel(TJxlChannel.Create(TileWidth, TileHeight, 3, 3));
    Image.AddChannel(TJxlChannel.Create(TileWidth, TileHeight, 3, 3));
    Image.AddChannel(TJxlChannel.Create(Count, 2, 0, 0));
    Image.AddChannel(TJxlChannel.Create(Width, Height, 0, 0));
    DecodeJxlModularStream(Reader, Image, 1 + 2 * FFrame.Dimensions.LowFrequencyGroupCount + Group, High(Int64),
      FGlobalTree, True, State);
    if Image.ChannelCount <> 4 then
      RaiseBadVarDct('AC metadata lost channels');
    for Y := 0 to TileHeight - 1 do
      for X := 0 to TileWidth - 1 do
        if (TileY0 + Y < FTileRows) and (TileX0 + X < FTileColumns) then
        begin
          FYToXMap[PtrInt(TileY0 + Y) * FTileColumns + TileX0 + X] := ClampToShortInt(Image[0].Row(Y)[X]);
          FYToBMap[PtrInt(TileY0 + Y) * FTileColumns + TileX0 + X] := ClampToShortInt(Image[1].Row(Y)[X]);
        end;
    StrategyLine := Image[2].Row(0);
    QuantLine := Image[2].Row(1);
    Used := 0;
    XLimit := Min(FBlocksX, X0 + Width);
    YLimit := Min(FBlocksY, Y0 + Height);
    for Y := Y0 to Y0 + Height - 1 do
      for X := X0 to X0 + Width - 1 do
      begin
        Sharpness := Image[3].Row(Y - Y0)[X - X0];
        if (Sharpness < 0) or (Sharpness >= EpfSharpEntries) then
          RaiseBadVarDct('bad sharpness');
        FSharpness[PtrInt(Y) * FBlocksX + X] := Sharpness;
        if FStrategies[PtrInt(Y) * FBlocksX + X] <> InvalidStrategy then
          Continue;
        if Used >= Count then
          RaiseBadVarDct('too few transforms');
        Strategy := StrategyLine[Used];
        if (Strategy < 0) or (Strategy >= JxlStrategyCount) then
          RaiseBadVarDct('bad transform');
        FUsedStrategies := FUsedStrategies or (LongWord(1) shl Strategy);
        if JxlStrategyIsMultiblock(Strategy) and not FIs444 then
          RaiseBadVarDct('large transform with chroma subsampling');
        if (X + JxlStrategyBlocksX[Strategy] > (X div FGroupBlocks + 1) * FGroupBlocks) or
          (X + JxlStrategyBlocksX[Strategy] > XLimit) or
          (Y + JxlStrategyBlocksY[Strategy] > (Y div FGroupBlocks + 1) * FGroupBlocks) or
          (Y + JxlStrategyBlocksY[Strategy] > YLimit) then
          RaiseBadVarDct('transform crosses a group');
        for InnerY := 0 to JxlStrategyBlocksY[Strategy] - 1 do
          for InnerX := 0 to JxlStrategyBlocksX[Strategy] - 1 do
          begin
            if FStrategies[PtrInt(Y + InnerY) * FBlocksX + X + InnerX] <> InvalidStrategy then
              RaiseBadVarDct('transforms overlap');
            if (InnerX = 0) and (InnerY = 0) then
              FStrategies[PtrInt(Y + InnerY) * FBlocksX + X + InnerX] := (Strategy shl 1) or 1
            else
              FStrategies[PtrInt(Y + InnerY) * FBlocksX + X + InnerX] := Strategy shl 1;
          end;
        Value := QuantLine[Used];
        if Value < 0 then
          Value := 0;
        if Value > QuantMaximum - 1 then
          Value := QuantMaximum - 1;
        FQuantField[PtrInt(Y) * FBlocksX + X] := 1 + Value;
        Inc(Used);
      end;
  finally
    Image.Free;
  end;
  if FFrame.LoopFilter.EpfIterations > 0 then
    ComputeSigma(X0, Y0, Width, Height);
end;

procedure TJxlVarDctFrame.FinalizeLowFrequency;
var
  Channel: LongInt;
  X: LongInt;
  Y: LongInt;
  Source: TJxlPlane;
begin
  if FLowFrequencyFinalized then
    Exit;
  FLowFrequencyFinalized := True;
  if (FFrame.Flags and JxlFlagUseLowFrequencyFrame) <> 0 then
  begin
    if Length(FLowFrequencyFrame) < 3 then
      RaiseBadVarDct('LF frame missing');
    for Channel := 0 to 2 do
    begin
      FLowFrequency[Channel] := TJxlPlane.Create(FBlocksX shr FHorizontalShift[Channel],
        FBlocksY shr FVerticalShift[Channel]);
      Source := FLowFrequencyFrame[Channel];
      if (Source = nil) or (Source.Width <= 0) or (Source.Height <= 0) then
        RaiseBadVarDct('LF frame missing');
      for Y := 0 to FLowFrequency[Channel].Height - 1 do
        for X := 0 to FLowFrequency[Channel].Width - 1 do
          FLowFrequency[Channel].Row(Y)[X] := Source.Row(Min(Y, Source.Height - 1))[Min(X, Source.Width - 1)];
    end;
    Exit;
  end;
  if (FFrame.Flags and JxlFlagSkipAdaptiveLowFrequencySmoothing) = 0 then
  begin
    if not FIs444 then
      RaiseBadVarDct('chroma subsampling with LF smoothing');
    SmoothJxlLowFrequency([FLowFrequency[0], FLowFrequency[1], FLowFrequency[2]], FLowFrequencySteps);
  end;
end;

procedure TJxlVarDctFrame.ReadHighFrequencyGlobal(Reader: TJxlBitReader);
var
  Pass: LongInt;
  ContextCount: Int64;
begin
  FinalizeLowFrequency;
  FDequant.Read(Reader, 1 + 3 * FFrame.Dimensions.LowFrequencyGroupCount, FGlobalTree);
  FDequant.EnsureComputed(FUsedStrategies);
  FHistogramSets := 1 + LongInt(Reader.ReadBits(CeilLog2(FFrame.Dimensions.GroupCount)));
  SetLength(FPassCodes, FFrame.Passes.Count);
  SetLength(FPassOrders, FFrame.Passes.Count);
  for Pass := 0 to LongInt(FFrame.Passes.Count) - 1 do
  begin
    FPassOrders[Pass] := ReadJxlCoefficientOrders(Reader, FUsedStrategies);
    ContextCount := Int64(FHistogramSets) * JxlAcContextCount(FBlockMap);
    if ContextCount > 1 shl 24 then
      RaiseBadVarDct('too many AC contexts');
    FPassCodes[Pass] := ReadJxlEntropyCode(Reader, LongInt(ContextCount));
  end;
end;

procedure TJxlVarDctFrame.EnsureGroupCoefficients(Group: LongInt);
var
  Channel: LongInt;
begin
  if Length(FGroupCoefficients[Group][0]) <> 0 then
    Exit;
  for Channel := 0 to 2 do
    SetLength(FGroupCoefficients[Group][Channel], PtrInt(FGroupBlocks) * FGroupBlocks * 64);
end;

procedure TJxlVarDctFrame.ReadPassGroup(Reader: TJxlBitReader; Pass, Group: LongInt);
const
  ChannelOrder: array[0..2] of LongInt = (1, 0, 2);
var
  X0: LongInt;
  Y0: LongInt;
  Width: LongInt;
  Height: LongInt;
  Decoder: TJxlAcPassDecoder;
  Selector: LongInt;
  NonZeros: array[0..2] of array of LongInt;
  Channel: LongInt;
  OrderIndex: LongInt;
  X: LongInt;
  Y: LongInt;
  SubX: LongInt;
  SubY: LongInt;
  Value: Byte;
  Strategy: LongInt;
  Offset: PtrInt;
  BlockIndex: PtrInt;
begin
  if (Pass < 0) or (Pass >= Length(FPassCodes)) or (Group < 0) or (Group >= Length(FGroupPasses)) then
    RaiseBadVarDct('section out of order');
  FinalizeLowFrequency;
  GroupBlockRect(Group, X0, Y0, Width, Height);
  EnsureGroupCoefficients(Group);
  Selector := 0;
  if FHistogramSets > 1 then
    Selector := LongInt(Reader.ReadBits(CeilLog2(FHistogramSets)));
  if Selector >= FHistogramSets then
    RaiseBadVarDct('bad histogram selector');
  Decoder.ContextCount := FPassCodes[Pass].ContextCount;
  Decoder.ContextOffset := Selector * JxlAcContextCount(FBlockMap);
  Decoder.Orders := @FPassOrders[Pass][0];
  Decoder.Shift := FFrame.Passes.Shift[Pass];
  for Channel := 0 to 2 do
    SetLength(NonZeros[Channel], PtrInt(FGroupBlocks) * FGroupBlocks);
  Decoder.SymbolReader := TJxlSymbolReader.Create(FPassCodes[Pass], Reader);
  try
    Offset := 0;
    for Y := 0 to Height - 1 do
      for X := 0 to Width - 1 do
      begin
        BlockIndex := PtrInt(Y0 + Y) * FBlocksX + X0 + X;
        Value := FStrategies[BlockIndex];
        if Value = InvalidStrategy then
          RaiseBadVarDct('block without a transform');
        if (Value and 1) = 0 then
          Continue;
        Strategy := Value shr 1;
        for OrderIndex := 0 to 2 do
        begin
          Channel := ChannelOrder[OrderIndex];
          SubX := X shr FHorizontalShift[Channel];
          SubY := Y shr FVerticalShift[Channel];
          if ((SubX shl FHorizontalShift[Channel]) <> X) or ((SubY shl FVerticalShift[Channel]) <> Y) then
            Continue;
          DecodeJxlVarBlock(Decoder, FBlockMap, Strategy, Channel, FLowFrequencyContexts[BlockIndex],
            LongWord(FQuantField[PtrInt(Y0 + Y) * FBlocksX + X0 + SubX]),
            @NonZeros[Channel][PtrInt(SubY) * FGroupBlocks + SubX], FGroupBlocks, SubX, SubY,
            @FGroupCoefficients[Group][Channel][Offset]);
        end;
        Inc(Offset, PtrInt(64) shl JxlStrategyLog2Blocks[Strategy]);
      end;
    Decoder.SymbolReader.CheckFinalState;
  finally
    Decoder.SymbolReader.Free;
  end;
  Inc(FGroupPasses[Group]);
  if FGroupPasses[Group] >= LongInt(FFrame.Passes.Count) then
    DrawGroup(Group);
end;

procedure TJxlVarDctFrame.DrawGroup(Group: LongInt);
const
  ChannelOrder: array[0..2] of LongInt = (1, 0, 2);
var
  X0: LongInt;
  Y0: LongInt;
  Width: LongInt;
  Height: LongInt;
  X: LongInt;
  Y: LongInt;
  Value: Byte;
  Strategy: LongInt;
  Size: LongInt;
  Offset: PtrInt;
  BlockIndex: PtrInt;
  Parameters: TJxlBlockDequantization;
  Biases: TJxlQuantBiases;
  TileIndex: PtrInt;
  Channel: LongInt;
  OrderIndex: LongInt;
  SubX: LongInt;
  SubY: LongInt;
  LowFrequencyX: LongInt;
  LowFrequencyY: LongInt;
  Zeros: array of LongInt;
  Coefficients: array[0..2] of PLongInt;
  Plane: TJxlPlane;
begin
  if FGroupDrawn[Group] then
    Exit;
  FGroupDrawn[Group] := True;
  GroupBlockRect(Group, X0, Y0, Width, Height);
  for Channel := 0 to 3 do
    Biases[Channel] := FHeaders.Transform.QuantBiases[Channel];
  Zeros := nil;
  if Length(FGroupCoefficients[Group][0]) = 0 then
    SetLength(Zeros, 256 * 256);
  Offset := 0;
  for Y := 0 to Height - 1 do
    for X := 0 to Width - 1 do
    begin
      BlockIndex := PtrInt(Y0 + Y) * FBlocksX + X0 + X;
      Value := FStrategies[BlockIndex];
      if Value = InvalidStrategy then
        RaiseBadVarDct('block without a transform');
      if (Value and 1) = 0 then
        Continue;
      Strategy := Value shr 1;
      Size := 64 shl JxlStrategyLog2Blocks[Strategy];
      for Channel := 0 to 2 do
        if Zeros <> nil then
          Coefficients[Channel] := @Zeros[0]
        else
          Coefficients[Channel] := @FGroupCoefficients[Group][Channel][Offset];
      TileIndex := PtrInt(Min((Y0 + Y) div ColorTileBlocks, FTileRows - 1)) * FTileColumns +
        Min((X0 + X) div ColorTileBlocks, FTileColumns - 1);
      Parameters.Step := FInverseGlobalScale / FQuantField[BlockIndex];
      Parameters.XMultiplier := FXMultiplier;
      Parameters.BMultiplier := FBMultiplier;
      if TileIndex >= 0 then
      begin
        Parameters.XFromY := FBaseCorrelationX + FYToXMap[TileIndex] * FColorScale;
        Parameters.BFromY := FBaseCorrelationB + FYToBMap[TileIndex] * FColorScale;
      end
      else
      begin
        Parameters.XFromY := FBaseCorrelationX;
        Parameters.BFromY := FBaseCorrelationB;
      end;
      DequantizeJxlBlock(Parameters, Biases, Coefficients[0], Coefficients[1], Coefficients[2],
        FDequant.Matrix(Strategy, 0), FDequant.Matrix(Strategy, 1), FDequant.Matrix(Strategy, 2), Size,
        @FBlockBuffer[0]);
      for Channel := 0 to 2 do
      begin
        LowFrequencyX := (X0 shr FHorizontalShift[Channel]) + (X shr FHorizontalShift[Channel]);
        LowFrequencyY := (Y0 shr FVerticalShift[Channel]) + (Y shr FVerticalShift[Channel]);
        Plane := FLowFrequency[Channel];
        if (LowFrequencyX < Plane.Width) and (LowFrequencyY < Plane.Height) then
          JxlLowestFrequenciesFromDc(Strategy, Plane.Row(LowFrequencyY) + LowFrequencyX, Plane.Width,
            @FBlockBuffer[Channel * Size], @FScratch[0]);
      end;
      for OrderIndex := 0 to 2 do
      begin
        Channel := ChannelOrder[OrderIndex];
        SubX := X shr FHorizontalShift[Channel];
        SubY := Y shr FVerticalShift[Channel];
        if ((SubX shl FHorizontalShift[Channel]) <> X) or ((SubY shl FVerticalShift[Channel]) <> Y) then
          Continue;
        Plane := FPixels[Channel];
        JxlTransformToPixels(Strategy, @FBlockBuffer[Channel * Size],
          Plane.Row(((Y0 shr FVerticalShift[Channel]) + SubY) * 8) + ((X0 shr FHorizontalShift[Channel]) + SubX) * 8,
          Plane.Width, @FScratch[0]);
      end;
      Inc(Offset, Size);
    end;
  for Channel := 0 to 2 do
    FGroupCoefficients[Group][Channel] := nil;
end;

{ Doubles a plane's width (Horizontal) or height with libjxl's chroma
  upsampling: 3/4 of the sample and 1/4 of its neighbour, mirrored at
  the edges. }
function UpsampleChroma(Source: TJxlPlane; Horizontal: Boolean): TJxlPlane;
var
  X: LongInt;
  Y: LongInt;
  Line: PSingle;
  Output: PSingle;
  Above: PSingle;
  Below: PSingle;
  Scaled: Single;
begin
  if Horizontal then
  begin
    Result := TJxlPlane.Create(Source.Width * 2, Source.Height);
    for Y := 0 to Source.Height - 1 do
    begin
      Line := Source.Row(Y);
      Output := Result.Row(Y);
      for X := 0 to Source.Width - 1 do
      begin
        Scaled := Line[X] * 0.75;
        Output[2 * X] := 0.25 * Line[JxlMirror(X - 1, Source.Width)] + Scaled;
        Output[2 * X + 1] := 0.25 * Line[JxlMirror(X + 1, Source.Width)] + Scaled;
      end;
    end;
  end
  else
  begin
    Result := TJxlPlane.Create(Source.Width, Source.Height * 2);
    for Y := 0 to Source.Height - 1 do
    begin
      Line := Source.Row(Y);
      Above := Source.Row(JxlMirror(Y - 1, Source.Height));
      Below := Source.Row(JxlMirror(Y + 1, Source.Height));
      for X := 0 to Source.Width - 1 do
      begin
        Scaled := Line[X] * 0.75;
        Result.Row(2 * Y)[X] := Above[X] * 0.25 + Scaled;
        Result.Row(2 * Y + 1)[X] := Below[X] * 0.25 + Scaled;
      end;
    end;
  end;
end;

function CropPlane(Source: TJxlPlane; Width, Height: LongInt): TJxlPlane;
var
  Y: LongInt;
begin
  Result := TJxlPlane.Create(Width, Height);
  for Y := 0 to Height - 1 do
    Move(Source.Row(Y)^, Result.Row(Y)^, SizeOf(Single) * Width);
end;

function TJxlVarDctFrame.MakeOutputPlane(Channel: LongInt): TJxlPlane;
var
  Width: LongInt;
  Height: LongInt;
  Current: TJxlPlane;
  Next: TJxlPlane;
begin
  Width := FFrame.Dimensions.Width;
  Height := FFrame.Dimensions.Height;
  Current := CropPlane(FPixels[Channel], DivideRoundingUp(Width, 1 shl FHorizontalShift[Channel]),
    DivideRoundingUp(Height, 1 shl FVerticalShift[Channel]));
  try
    if FHorizontalShift[Channel] <> 0 then
    begin
      Next := UpsampleChroma(Current, True);
      Current.Free;
      Current := Next;
    end;
    if FVerticalShift[Channel] <> 0 then
    begin
      Next := UpsampleChroma(Current, False);
      Current.Free;
      Current := Next;
    end;
    if (Current.Width = Width) and (Current.Height = Height) then
    begin
      Result := Current;
      Current := nil;
    end
    else
      Result := CropPlane(Current, Width, Height);
  finally
    Current.Free;
  end;
end;

procedure TJxlVarDctFrame.Render(out Planes: TJxlPlaneSet; out Sigma: TJxlEpfSigma);
var
  Group: LongInt;
  Channel: LongInt;
begin
  FinalizeLowFrequency;
  for Group := 0 to High(FGroupDrawn) do
    if not FGroupDrawn[Group] then
      DrawGroup(Group);
  Planes := nil;
  SetLength(Planes, 3);
  try
    for Channel := 0 to 2 do
      Planes[Channel] := MakeOutputPlane(Channel);
  except
    FreeJxlPlanes(Planes);
    raise;
  end;
  Sigma := FSigma;
end;

end.
