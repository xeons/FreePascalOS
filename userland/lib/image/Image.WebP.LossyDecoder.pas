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
  The VP8 key frame decoder: macroblocks of 16x16 luma and two 8x8
  chroma samples (4:2:0), line after line.

  The first partition holds each macroblock's segment, whether it has
  coefficients, and its prediction modes (one 16x16 mode or sixteen 4x4
  modes, whose probabilities depend on the modes above and to the left,
  and a chroma mode); the token partitions (macroblock lines taken in
  turn) hold the coefficients. Each macroblock is predicted in a work
  block from the pixels above and to the left as they were before the
  loop filter (127 above the picture, 129 to its left, as libwebp
  has them), the inverse transforms added, and the result put in the
  planes. Once every macroblock is there, the loop filter runs over
  them in the same order, at the strength of each one's segment and
  mode. The planes cover whole macroblocks; the picture is their top
  left Width x Height.
}
unit Image.WebP.LossyDecoder;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Errors,
  Image.WebP.BoolDecoder,
  Image.WebP.LossyTables,
  Image.WebP.LossyHeader,
  Image.WebP.LossyPrediction,
  Image.WebP.LossyTransforms,
  Image.WebP.LossyResiduals,
  Image.WebP.LoopFilter;

type
  TLossyPlanes = record
    Width: LongInt;
    Height: LongInt;
    LumaStride: LongInt;
    ChromaStride: LongInt;
    Luma: TBytes;
    ChromaU: TBytes;
    ChromaV: TBytes;
  end;

{ Decodes the VP8 frame of Size bytes at Data. }
function DecodeLossyPlanes(Data: PByte; Size: PtrInt): TLossyPlanes;

implementation

type
  TMacroblockModes = record
    Segment: LongInt;
    Skip: Boolean;
    IsWhole: Boolean;  { one 16x16 luma mode rather than 4x4 ones }
    LumaModes: array[0..15] of Byte;
    ChromaMode: LongInt;
  end;

  TFilterInfo = record
    Limit: LongInt;
    InnerLevel: LongInt;
    HighVarianceThreshold: LongInt;
    Inner: Boolean;
  end;

  TLossyFrameDecoder = class
  private
    FHeader: TLossyFrameHeader;
    FModesReader: TBoolDecoder;
    FPartitions: array[0..MaximumPartitions - 1] of TBoolDecoder;
    FPlanes: TLossyPlanes;
    FModes: array of TMacroblockModes;
    FTopModes: array of Byte;
    FLeftModes: array[0..3] of Byte;
    FTopNonZero: array of LongWord;
    FTopNonZeroDc: array of LongWord;
    FLeftNonZero: LongWord;
    FLeftNonZeroDc: LongWord;
    FCoefficients: array[0..383] of SmallInt;
    FNonZeroLuma: LongWord;
    FNonZeroChroma: LongWord;
    FWork: array[0..WorkSize - 1] of Byte;
    FFilterStrengths: array[0..SegmentCount - 1, Boolean] of TFilterInfo;
    FFilterInfo: array of TFilterInfo;
    procedure ReadModes(MacroblockX: LongInt);
    function ReadResiduals(Reader: TBoolDecoder; MacroblockX: LongInt): Boolean;
    procedure DecodeMacroblock(Reader: TBoolDecoder; MacroblockX, MacroblockY: LongInt);
    procedure FillWorkEdges(MacroblockX, MacroblockY: LongInt; constref Modes: TMacroblockModes);
    procedure Reconstruct(MacroblockX, MacroblockY: LongInt; constref Modes: TMacroblockModes);
    procedure ComputeFilterStrengths;
    procedure FilterMacroblock(MacroblockX, MacroblockY: LongInt);
  public
    constructor Create(Data: PByte; Size: PtrInt);
    destructor Destroy; override;
    function Decode: TLossyPlanes;
  end;

const
  { Where each 4x4 block starts in the work block. }
  BlockOffsets: array[0..15] of LongInt = (
    0 + 0 * WorkStride, 4 + 0 * WorkStride, 8 + 0 * WorkStride, 12 + 0 * WorkStride,
    0 + 4 * WorkStride, 4 + 4 * WorkStride, 8 + 4 * WorkStride, 12 + 4 * WorkStride,
    0 + 8 * WorkStride, 4 + 8 * WorkStride, 8 + 8 * WorkStride, 12 + 8 * WorkStride,
    0 + 12 * WorkStride, 4 + 12 * WorkStride, 8 + 12 * WorkStride, 12 + 12 * WorkStride);

constructor TLossyFrameDecoder.Create(Data: PByte; Size: PtrInt);
var
  Index: LongInt;
begin
  inherited Create;
  FModesReader := ReadLossyFrameHeader(Data, Size, FHeader);
  for Index := 0 to FHeader.PartitionCount - 1 do
    FPartitions[Index] := TBoolDecoder.Create(Data + FHeader.PartitionStart[Index], FHeader.PartitionSize[Index]);
end;

destructor TLossyFrameDecoder.Destroy;
var
  Index: LongInt;
begin
  for Index := 0 to MaximumPartitions - 1 do
    FPartitions[Index].Free;
  FModesReader.Free;
  inherited Destroy;
end;

procedure TLossyFrameDecoder.ReadModes(MacroblockX: LongInt);
var
  Modes: ^TMacroblockModes;
  Reader: TBoolDecoder;
  LumaMode: LongInt;
  X: LongInt;
  Y: LongInt;
  LeftMode: LongInt;
  P: LongInt;
begin
  Modes := @FModes[MacroblockX];
  Reader := FModesReader;
  if FHeader.Segments.UpdateMap then
  begin
    if Reader.ReadBit(FHeader.SegmentProbabilities[0]) = 0 then
      Modes^.Segment := Reader.ReadBit(FHeader.SegmentProbabilities[1])
    else
      Modes^.Segment := Reader.ReadBit(FHeader.SegmentProbabilities[2]) + 2;
  end
  else
    Modes^.Segment := 0;
  if FHeader.UseSkipProbability then
    Modes^.Skip := Reader.ReadBit(FHeader.SkipProbability) <> 0
  else
    Modes^.Skip := False;
  Modes^.IsWhole := Reader.ReadBit(145) <> 0;
  if Modes^.IsWhole then
  begin
    if Reader.ReadBit(156) <> 0 then
    begin
      if Reader.ReadBit(128) <> 0 then
        LumaMode := ModeTrueMotion
      else
        LumaMode := ModeHorizontal;
    end
    else if Reader.ReadBit(163) <> 0 then
      LumaMode := ModeVertical
    else
      LumaMode := ModeDc;
    Modes^.LumaModes[0] := LumaMode;
    for X := 0 to 3 do
    begin
      FTopModes[4 * MacroblockX + X] := LumaMode;
      FLeftModes[X] := LumaMode;
    end;
  end
  else
    for Y := 0 to 3 do
    begin
      LeftMode := FLeftModes[Y];
      for X := 0 to 3 do
      begin
        P := (FTopModes[4 * MacroblockX + X] * IntraModes4 + LeftMode) * (IntraModes4 - 1);
        if Reader.ReadBit(IntraMode4Probabilities[P]) = 0 then
          LeftMode := ModeDc
        else if Reader.ReadBit(IntraMode4Probabilities[P + 1]) = 0 then
          LeftMode := ModeTrueMotion
        else if Reader.ReadBit(IntraMode4Probabilities[P + 2]) = 0 then
          LeftMode := ModeVertical
        else if Reader.ReadBit(IntraMode4Probabilities[P + 3]) = 0 then
        begin
          if Reader.ReadBit(IntraMode4Probabilities[P + 4]) = 0 then
            LeftMode := ModeHorizontal
          else if Reader.ReadBit(IntraMode4Probabilities[P + 5]) = 0 then
            LeftMode := ModeDownRight
          else
            LeftMode := ModeVerticalRight;
        end
        else if Reader.ReadBit(IntraMode4Probabilities[P + 6]) = 0 then
          LeftMode := ModeDownLeft
        else if Reader.ReadBit(IntraMode4Probabilities[P + 7]) = 0 then
          LeftMode := ModeVerticalLeft
        else if Reader.ReadBit(IntraMode4Probabilities[P + 8]) = 0 then
          LeftMode := ModeHorizontalDown
        else
          LeftMode := ModeHorizontalUp;
        FTopModes[4 * MacroblockX + X] := LeftMode;
        Modes^.LumaModes[Y * 4 + X] := LeftMode;
      end;
      FLeftModes[Y] := LeftMode;
    end;
  if Reader.ReadBit(142) = 0 then
    Modes^.ChromaMode := ModeDc
  else if Reader.ReadBit(114) = 0 then
    Modes^.ChromaMode := ModeVertical
  else if Reader.ReadBit(183) <> 0 then
    Modes^.ChromaMode := ModeTrueMotion
  else
    Modes^.ChromaMode := ModeHorizontal;
end;

{ The two bits telling which inverse transform a block needs: 3 any,
  2 only coefficients 0, 1 and 4, 1 only DC, 0 none. }
function TransformCode(Codes: LongWord; Count: LongInt; HasDc: Boolean): LongWord;
begin
  Result := (Codes shl 2) and $FFFFFFFF;
  if Count > 3 then
    Result := Result or 3
  else if Count > 1 then
    Result := Result or 2
  else if HasDc then
    Result := Result or 1;
end;

function TLossyFrameDecoder.ReadResiduals(Reader: TBoolDecoder; MacroblockX: LongInt): Boolean;
var
  Modes: ^TMacroblockModes;
  Quant: ^TQuantMatrix;
  Probabilities: PByte;
  Dc: array[0..15] of SmallInt;
  Count: LongInt;
  DcValue: LongInt;
  First: LongInt;
  AcType: LongInt;
  TopBits: LongWord;
  LeftBits: LongWord;
  OutTop: LongWord;
  OutLeft: LongWord;
  Codes: LongWord;
  LeftFlag: LongWord;
  X: LongInt;
  Y: LongInt;
  Index: LongInt;
  Channel: LongInt;
  Block: LongInt;
begin
  Modes := @FModes[MacroblockX];
  Quant := @FHeader.Quant[Modes^.Segment];
  Probabilities := @FHeader.Probabilities[0];
  FillChar(FCoefficients, SizeOf(FCoefficients), 0);
  if Modes^.IsWhole then
  begin
    FillChar(Dc, SizeOf(Dc), 0);
    Count := ReadCoefficients(Reader, Probabilities, BlockTypeLumaDc,
      LongInt(FTopNonZeroDc[MacroblockX] + FLeftNonZeroDc), Quant^.Y2, 0, @Dc[0]);
    if Count > 0 then
      FTopNonZeroDc[MacroblockX] := 1
    else
      FTopNonZeroDc[MacroblockX] := 0;
    FLeftNonZeroDc := FTopNonZeroDc[MacroblockX];
    if Count > 1 then
      InverseWalshHadamard(@Dc[0], @FCoefficients[0])
    else
    begin
      DcValue := SarLongint(Dc[0] + 3, 3);
      for Index := 0 to 15 do
        FCoefficients[Index * 16] := SmallInt(DcValue);
    end;
    First := 1;
    AcType := BlockTypeLumaAc;
  end
  else
  begin
    First := 0;
    AcType := BlockTypeLumaWhole;
  end;

  TopBits := FTopNonZero[MacroblockX] and $0F;
  LeftBits := FLeftNonZero and $0F;
  FNonZeroLuma := 0;
  for Y := 0 to 3 do
  begin
    LeftFlag := LeftBits and 1;
    Codes := 0;
    for X := 0 to 3 do
    begin
      Block := Y * 4 + X;
      Count := ReadCoefficients(Reader, Probabilities, AcType, LongInt(LeftFlag + (TopBits and 1)),
        Quant^.Y1, First, @FCoefficients[Block * 16]);
      if Count > First then
        LeftFlag := 1
      else
        LeftFlag := 0;
      TopBits := (TopBits shr 1) or (LeftFlag shl 7);
      Codes := TransformCode(Codes, Count, FCoefficients[Block * 16] <> 0);
    end;
    TopBits := TopBits shr 4;
    LeftBits := (LeftBits shr 1) or (LeftFlag shl 7);
    FNonZeroLuma := ((FNonZeroLuma shl 8) and $FFFFFFFF) or Codes;
  end;
  OutTop := TopBits;
  OutLeft := LeftBits shr 4;

  FNonZeroChroma := 0;
  Channel := 0;
  while Channel < 4 do
  begin
    Codes := 0;
    TopBits := FTopNonZero[MacroblockX] shr (4 + Channel);
    LeftBits := FLeftNonZero shr (4 + Channel);
    for Y := 0 to 1 do
    begin
      LeftFlag := LeftBits and 1;
      for X := 0 to 1 do
      begin
        Block := 16 + Channel * 2 + Y * 2 + X;
        Count := ReadCoefficients(Reader, Probabilities, BlockTypeChroma, LongInt(LeftFlag + (TopBits and 1)),
          Quant^.UV, 0, @FCoefficients[Block * 16]);
        if Count > 0 then
          LeftFlag := 1
        else
          LeftFlag := 0;
        TopBits := (TopBits shr 1) or (LeftFlag shl 3);
        Codes := TransformCode(Codes, Count, FCoefficients[Block * 16] <> 0);
      end;
      TopBits := TopBits shr 2;
      LeftBits := (LeftBits shr 1) or (LeftFlag shl 5);
    end;
    FNonZeroChroma := FNonZeroChroma or (Codes shl (4 * Channel));
    OutTop := OutTop or ((TopBits shl 4) shl Channel);
    OutLeft := OutLeft or ((LeftBits and $F0) shl Channel);
    Inc(Channel, 2);
  end;
  FTopNonZero[MacroblockX] := OutTop and $FF;
  FLeftNonZero := OutLeft and $FF;
  Result := (FNonZeroLuma or FNonZeroChroma) = 0;
end;

procedure TLossyFrameDecoder.DecodeMacroblock(Reader: TBoolDecoder; MacroblockX, MacroblockY: LongInt);
var
  Modes: ^TMacroblockModes;
  Skip: Boolean;
  Info: TFilterInfo;
begin
  Modes := @FModes[MacroblockX];
  Skip := FHeader.UseSkipProbability and Modes^.Skip;
  if not Skip then
    Skip := ReadResiduals(Reader, MacroblockX)
  else
  begin
    FLeftNonZero := 0;
    FTopNonZero[MacroblockX] := 0;
    if Modes^.IsWhole then
    begin
      FLeftNonZeroDc := 0;
      FTopNonZeroDc[MacroblockX] := 0;
    end;
    FNonZeroLuma := 0;
    FNonZeroChroma := 0;
  end;
  if FHeader.FilterType > 0 then
  begin
    Info := FFilterStrengths[Modes^.Segment, not Modes^.IsWhole];
    Info.Inner := Info.Inner or not Skip;
    FFilterInfo[MacroblockY * FHeader.MacroblockColumns + MacroblockX] := Info;
  end;
  Reconstruct(MacroblockX, MacroblockY, Modes^);
end;

procedure TLossyFrameDecoder.FillWorkEdges(MacroblockX, MacroblockY: LongInt; constref Modes: TMacroblockModes);
var
  Y: LongInt;
  LumaX: LongInt;
  LumaY: LongInt;
  ChromaX: LongInt;
  ChromaY: LongInt;
  Luma: PByte;
  ChromaU: PByte;
  ChromaV: PByte;
  TopRight: PByte;
  Above: PByte;
begin
  LumaX := MacroblockX * 16;
  LumaY := MacroblockY * 16;
  ChromaX := MacroblockX * 8;
  ChromaY := MacroblockY * 8;
  Luma := @FWork[WorkLumaOffset];
  ChromaU := @FWork[WorkUOffset];
  ChromaV := @FWork[WorkVOffset];
  for Y := 0 to 15 do
    if MacroblockX = 0 then
      Luma[Y * WorkStride - 1] := 129
    else
      Luma[Y * WorkStride - 1] := FPlanes.Luma[(LumaY + Y) * FPlanes.LumaStride + LumaX - 1];
  for Y := 0 to 7 do
    if MacroblockX = 0 then
    begin
      ChromaU[Y * WorkStride - 1] := 129;
      ChromaV[Y * WorkStride - 1] := 129;
    end
    else
    begin
      ChromaU[Y * WorkStride - 1] := FPlanes.ChromaU[(ChromaY + Y) * FPlanes.ChromaStride + ChromaX - 1];
      ChromaV[Y * WorkStride - 1] := FPlanes.ChromaV[(ChromaY + Y) * FPlanes.ChromaStride + ChromaX - 1];
    end;
  if MacroblockY = 0 then
  begin
    FillChar(Luma[-WorkStride - 1], 16 + 4 + 1, 127);
    FillChar(ChromaU[-WorkStride - 1], 8 + 1, 127);
    FillChar(ChromaV[-WorkStride - 1], 8 + 1, 127);
  end
  else
  begin
    if MacroblockX = 0 then
    begin
      Luma[-WorkStride - 1] := 129;
      ChromaU[-WorkStride - 1] := 129;
      ChromaV[-WorkStride - 1] := 129;
      Move(FPlanes.Luma[(LumaY - 1) * FPlanes.LumaStride + LumaX], Luma[-WorkStride], 16);
      Move(FPlanes.ChromaU[(ChromaY - 1) * FPlanes.ChromaStride + ChromaX], ChromaU[-WorkStride], 8);
      Move(FPlanes.ChromaV[(ChromaY - 1) * FPlanes.ChromaStride + ChromaX], ChromaV[-WorkStride], 8);
    end
    else
    begin
      Move(FPlanes.Luma[(LumaY - 1) * FPlanes.LumaStride + LumaX - 1], Luma[-WorkStride - 1], 17);
      Move(FPlanes.ChromaU[(ChromaY - 1) * FPlanes.ChromaStride + ChromaX - 1], ChromaU[-WorkStride - 1], 9);
      Move(FPlanes.ChromaV[(ChromaY - 1) * FPlanes.ChromaStride + ChromaX - 1], ChromaV[-WorkStride - 1], 9);
    end;
  end;
  if Modes.IsWhole then
    Exit;
  { Above and to the right of the macroblock, for the 4x4 blocks of
    its right column (the lower ones see the same pixels). }
  TopRight := @Luma[-WorkStride + 16];
  if MacroblockY > 0 then
  begin
    Above := @FPlanes.Luma[(LumaY - 1) * FPlanes.LumaStride];
    if MacroblockX >= FHeader.MacroblockColumns - 1 then
      FillChar(TopRight^, 4, Above[LumaX + 15])
    else
      Move(Above[LumaX + 16], TopRight^, 4);
  end;
  for Y := 1 to 3 do
    Move(TopRight^, TopRight[Y * 4 * WorkStride], 4);
end;

procedure ApplyTransform(Code: LongWord; Input: PCoefficient; Target: PByte);
begin
  case Code of
    3: AddInverseTransform(Input, Target);
    2: AddInverseTransformAc3(Input, Target);
    1: AddInverseTransformDc(Input, Target);
  end;
end;

procedure ApplyChromaTransform(Codes: LongWord; Input: PCoefficient; Target: PByte);
begin
  if (Codes and $FF) = 0 then
    Exit;
  if (Codes and $AA) <> 0 then
  begin
    AddInverseTransform(Input, Target);
    AddInverseTransform(Input + 16, Target + 4);
    AddInverseTransform(Input + 32, Target + 4 * WorkStride);
    AddInverseTransform(Input + 48, Target + 4 * WorkStride + 4);
  end
  else
  begin
    if Input[0] <> 0 then
      AddInverseTransformDc(Input, Target);
    if Input[16] <> 0 then
      AddInverseTransformDc(Input + 16, Target + 4);
    if Input[32] <> 0 then
      AddInverseTransformDc(Input + 32, Target + 4 * WorkStride);
    if Input[48] <> 0 then
      AddInverseTransformDc(Input + 48, Target + 4 * WorkStride + 4);
  end;
end;

{ The DC mode at the picture's edges. }
function EdgeMode(Mode, MacroblockX, MacroblockY: LongInt): LongInt;
begin
  Result := Mode;
  if Mode <> ModeDc then
    Exit;
  if MacroblockX = 0 then
  begin
    if MacroblockY = 0 then
      Result := ModeDcNoTopLeft
    else
      Result := ModeDcNoLeft;
  end
  else if MacroblockY = 0 then
    Result := ModeDcNoTop;
end;

procedure TLossyFrameDecoder.Reconstruct(MacroblockX, MacroblockY: LongInt; constref Modes: TMacroblockModes);
var
  Luma: PByte;
  Codes: LongWord;
  Block: LongInt;
  Y: LongInt;
begin
  FillWorkEdges(MacroblockX, MacroblockY, Modes);
  Luma := @FWork[WorkLumaOffset];
  Codes := FNonZeroLuma;
  if not Modes.IsWhole then
    for Block := 0 to 15 do
    begin
      PredictLuma4(Modes.LumaModes[Block], Luma + BlockOffsets[Block]);
      ApplyTransform(Codes shr 30, @FCoefficients[Block * 16], Luma + BlockOffsets[Block]);
      Codes := (Codes shl 2) and $FFFFFFFF;
    end
  else
  begin
    PredictLuma16(EdgeMode(Modes.LumaModes[0], MacroblockX, MacroblockY), Luma);
    if Codes <> 0 then
      for Block := 0 to 15 do
      begin
        ApplyTransform(Codes shr 30, @FCoefficients[Block * 16], Luma + BlockOffsets[Block]);
        Codes := (Codes shl 2) and $FFFFFFFF;
      end;
  end;
  PredictChroma8(EdgeMode(Modes.ChromaMode, MacroblockX, MacroblockY), @FWork[WorkUOffset]);
  PredictChroma8(EdgeMode(Modes.ChromaMode, MacroblockX, MacroblockY), @FWork[WorkVOffset]);
  ApplyChromaTransform(FNonZeroChroma, @FCoefficients[16 * 16], @FWork[WorkUOffset]);
  ApplyChromaTransform(FNonZeroChroma shr 8, @FCoefficients[20 * 16], @FWork[WorkVOffset]);
  for Y := 0 to 15 do
    Move(FWork[WorkLumaOffset + Y * WorkStride],
      FPlanes.Luma[(MacroblockY * 16 + Y) * FPlanes.LumaStride + MacroblockX * 16], 16);
  for Y := 0 to 7 do
  begin
    Move(FWork[WorkUOffset + Y * WorkStride],
      FPlanes.ChromaU[(MacroblockY * 8 + Y) * FPlanes.ChromaStride + MacroblockX * 8], 8);
    Move(FWork[WorkVOffset + Y * WorkStride],
      FPlanes.ChromaV[(MacroblockY * 8 + Y) * FPlanes.ChromaStride + MacroblockX * 8], 8);
  end;
end;

procedure TLossyFrameDecoder.ComputeFilterStrengths;
var
  Segment: LongInt;
  BaseLevel: LongInt;
  Level: LongInt;
  InnerLevel: LongInt;
  FourByFour: Boolean;
  Info: TFilterInfo;
begin
  for Segment := 0 to SegmentCount - 1 do
  begin
    if FHeader.Segments.UseSegment then
    begin
      BaseLevel := FHeader.Segments.FilterStrength[Segment];
      if not FHeader.Segments.AbsoluteDelta then
        Inc(BaseLevel, FHeader.Filter.Level);
    end
    else
      BaseLevel := FHeader.Filter.Level;
    for FourByFour := False to True do
    begin
      Info := Default(TFilterInfo);
      Level := BaseLevel;
      if FHeader.Filter.UseDeltas then
      begin
        Inc(Level, FHeader.Filter.ReferenceDeltas[0]);
        if FourByFour then
          Inc(Level, FHeader.Filter.ModeDeltas[0]);
      end;
      if Level < 0 then
        Level := 0
      else if Level > 63 then
        Level := 63;
      if Level > 0 then
      begin
        InnerLevel := Level;
        if FHeader.Filter.Sharpness > 0 then
        begin
          if FHeader.Filter.Sharpness > 4 then
            InnerLevel := InnerLevel shr 2
          else
            InnerLevel := InnerLevel shr 1;
          if InnerLevel > 9 - FHeader.Filter.Sharpness then
            InnerLevel := 9 - FHeader.Filter.Sharpness;
        end;
        if InnerLevel < 1 then
          InnerLevel := 1;
        Info.InnerLevel := InnerLevel;
        Info.Limit := 2 * Level + InnerLevel;
        if Level >= 40 then
          Info.HighVarianceThreshold := 2
        else if Level >= 15 then
          Info.HighVarianceThreshold := 1
        else
          Info.HighVarianceThreshold := 0;
      end
      else
        Info.Limit := 0;
      Info.Inner := FourByFour;
      FFilterStrengths[Segment, FourByFour] := Info;
    end;
  end;
end;

procedure TLossyFrameDecoder.FilterMacroblock(MacroblockX, MacroblockY: LongInt);
var
  Info: TFilterInfo;
  Luma: PByte;
  ChromaU: PByte;
  ChromaV: PByte;
  LumaStride: LongInt;
  ChromaStride: LongInt;
begin
  Info := FFilterInfo[MacroblockY * FHeader.MacroblockColumns + MacroblockX];
  if Info.Limit = 0 then
    Exit;
  LumaStride := FPlanes.LumaStride;
  ChromaStride := FPlanes.ChromaStride;
  Luma := @FPlanes.Luma[MacroblockY * 16 * LumaStride + MacroblockX * 16];
  if FHeader.FilterType = 1 then
  begin
    if MacroblockX > 0 then
      SimpleLeftEdge16(Luma, LumaStride, Info.Limit + 4);
    if Info.Inner then
      SimpleInnerVerticalEdges16(Luma, LumaStride, Info.Limit);
    if MacroblockY > 0 then
      SimpleTopEdge16(Luma, LumaStride, Info.Limit + 4);
    if Info.Inner then
      SimpleInnerHorizontalEdges16(Luma, LumaStride, Info.Limit);
    Exit;
  end;
  ChromaU := @FPlanes.ChromaU[MacroblockY * 8 * ChromaStride + MacroblockX * 8];
  ChromaV := @FPlanes.ChromaV[MacroblockY * 8 * ChromaStride + MacroblockX * 8];
  if MacroblockX > 0 then
  begin
    LeftEdge16(Luma, LumaStride, Info.Limit + 4, Info.InnerLevel, Info.HighVarianceThreshold);
    LeftEdge8(ChromaU, ChromaV, ChromaStride, Info.Limit + 4, Info.InnerLevel, Info.HighVarianceThreshold);
  end;
  if Info.Inner then
  begin
    InnerVerticalEdges16(Luma, LumaStride, Info.Limit, Info.InnerLevel, Info.HighVarianceThreshold);
    InnerVerticalEdge8(ChromaU, ChromaV, ChromaStride, Info.Limit, Info.InnerLevel, Info.HighVarianceThreshold);
  end;
  if MacroblockY > 0 then
  begin
    TopEdge16(Luma, LumaStride, Info.Limit + 4, Info.InnerLevel, Info.HighVarianceThreshold);
    TopEdge8(ChromaU, ChromaV, ChromaStride, Info.Limit + 4, Info.InnerLevel, Info.HighVarianceThreshold);
  end;
  if Info.Inner then
  begin
    InnerHorizontalEdges16(Luma, LumaStride, Info.Limit, Info.InnerLevel, Info.HighVarianceThreshold);
    InnerHorizontalEdge8(ChromaU, ChromaV, ChromaStride, Info.Limit, Info.InnerLevel, Info.HighVarianceThreshold);
  end;
end;

function TLossyFrameDecoder.Decode: TLossyPlanes;
var
  Columns: LongInt;
  Rows: LongInt;
  MacroblockX: LongInt;
  MacroblockY: LongInt;
  Reader: TBoolDecoder;
  Index: LongInt;
begin
  Columns := FHeader.MacroblockColumns;
  Rows := FHeader.MacroblockRows;
  FPlanes.Width := FHeader.Width;
  FPlanes.Height := FHeader.Height;
  FPlanes.LumaStride := Columns * 16;
  FPlanes.ChromaStride := Columns * 8;
  SetLength(FPlanes.Luma, PtrInt(FPlanes.LumaStride) * Rows * 16);
  SetLength(FPlanes.ChromaU, PtrInt(FPlanes.ChromaStride) * Rows * 8);
  SetLength(FPlanes.ChromaV, PtrInt(FPlanes.ChromaStride) * Rows * 8);
  SetLength(FModes, Columns);
  SetLength(FTopModes, Columns * 4);
  SetLength(FTopNonZero, Columns);
  SetLength(FTopNonZeroDc, Columns);
  for Index := 0 to Columns * 4 - 1 do
    FTopModes[Index] := ModeDc;
  for Index := 0 to Columns - 1 do
  begin
    FTopNonZero[Index] := 0;
    FTopNonZeroDc[Index] := 0;
  end;
  if FHeader.FilterType > 0 then
  begin
    ComputeFilterStrengths;
    SetLength(FFilterInfo, PtrInt(Columns) * Rows);
  end;
  for MacroblockY := 0 to Rows - 1 do
  begin
    for Index := 0 to 3 do
      FLeftModes[Index] := ModeDc;
    FLeftNonZero := 0;
    FLeftNonZeroDc := 0;
    for MacroblockX := 0 to Columns - 1 do
      ReadModes(MacroblockX);
    if FModesReader.EndOfData then
      RaiseImageError(ImageErrorTruncated, 'VP8 first partition');
    Reader := FPartitions[MacroblockY and (FHeader.PartitionCount - 1)];
    for MacroblockX := 0 to Columns - 1 do
    begin
      DecodeMacroblock(Reader, MacroblockX, MacroblockY);
      if Reader.EndOfData then
        RaiseImageError(ImageErrorTruncated, 'VP8 coefficients');
    end;
  end;
  if FHeader.FilterType > 0 then
    for MacroblockY := 0 to Rows - 1 do
      for MacroblockX := 0 to Columns - 1 do
        FilterMacroblock(MacroblockX, MacroblockY);
  Result := FPlanes;
end;

function DecodeLossyPlanes(Data: PByte; Size: PtrInt): TLossyPlanes;
var
  Decoder: TLossyFrameDecoder;
begin
  Decoder := TLossyFrameDecoder.Create(Data, Size);
  try
    Result := Decoder.Decode;
  finally
    Decoder.Free;
  end;
end;

end.
