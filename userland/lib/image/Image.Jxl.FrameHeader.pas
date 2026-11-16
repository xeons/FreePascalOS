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
  A JPEG XL frame's header and table of contents (ISO/IEC 18181-1
  annex C.2 to C.4).

  The header says what kind of frame it is (a regular frame, an LF
  frame holding another frame's low frequencies, a frame kept only to
  be referenced, or one that skips progressive rendering), how it is
  coded (VarDCT or modular), its features (noise, patches, splines,
  using an LF frame), colour transform, upsampling, group size, passes,
  crop and offset, blending, duration, whether it is the last, which
  reference slot it is saved in, its name and its restoration filters
  (gaborish and the edge preserving filter).

  The frame's dimensions follow: groups of 128, 256, 512 or 1024 pixels
  a side, LF groups eight times as large. The table of contents gives
  the size of each section: the LF global section, each LF group, the
  HF global section and each pass of each group, possibly permuted; a
  frame of one group and one pass has a single section with all of it.
}
unit Image.Jxl.FrameHeader;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Jxl.BitReader,
  Image.Jxl.Headers;

const
  JxlFrameRegular = 0;
  JxlFrameLowFrequency = 1;
  JxlFrameReferenceOnly = 2;
  JxlFrameSkipProgressive = 3;

  JxlEncodingVarDct = 0;
  JxlEncodingModular = 1;

  JxlFlagNoise = 1;
  JxlFlagPatches = 2;
  JxlFlagSplines = 16;
  JxlFlagUseLowFrequencyFrame = 32;
  JxlFlagSkipAdaptiveLowFrequencySmoothing = 128;

  JxlColorTransformXyb = 0;
  JxlColorTransformNone = 1;
  JxlColorTransformYCbCr = 2;

  JxlBlendReplace = 0;
  JxlBlendAdd = 1;
  JxlBlendBlend = 2;
  JxlBlendAlphaWeightedAdd = 3;
  JxlBlendMultiply = 4;

  JxlMaximumPasses = 11;

type
  TJxlBlendingInfo = record
    Mode: LongWord;
    AlphaChannel: LongWord;
    Clamp: Boolean;
    Source: LongWord;
  end;

  TJxlPasses = record
    Count: LongWord;
    DownsampleCount: LongWord;
    Shift: array[0..JxlMaximumPasses - 1] of LongWord;
    Downsample: array[0..3] of LongWord;
    LastPass: array[0..3] of LongWord;
  end;

  TJxlLoopFilter = record
    Gaborish: Boolean;
    GaborishWeights: array[0..2, 0..1] of Single;
    EpfIterations: LongWord;
    EpfSharpLut: array[0..7] of Single;
    EpfChannelScale: array[0..2] of Single;
    EpfPass1ZeroFlush: Single;
    EpfPass2ZeroFlush: Single;
    EpfQuantMultiplier: Single;
    EpfPass0SigmaScale: Single;
    EpfPass2SigmaScale: Single;
    EpfBorderSadMultiplier: Single;
    EpfSigmaForModular: Single;
  end;

  TJxlFrameDimensions = record
    { The frame's size after upsampling (as the header gives it). }
    UpsampledWidth: LongInt;
    UpsampledHeight: LongInt;
    { The size it is coded at. }
    Width: LongInt;
    Height: LongInt;
    WidthInBlocks: LongInt;
    HeightInBlocks: LongInt;
    PaddedWidth: LongInt;
    PaddedHeight: LongInt;
    GroupDimension: LongInt;
    LowFrequencyGroupDimension: LongInt;
    GroupColumns: LongInt;
    GroupRows: LongInt;
    LowFrequencyGroupColumns: LongInt;
    LowFrequencyGroupRows: LongInt;
    GroupCount: LongInt;
    LowFrequencyGroupCount: LongInt;
  end;

  TJxlFrameHeader = record
    FrameType: LongWord;
    Encoding: LongWord;
    Flags: QWord;
    ColorTransform: LongWord;
    { YCbCr subsampling mode of each channel (Cb, Y, Cr order as stored). }
    ChromaChannelMode: array[0..2] of LongWord;
    Upsampling: LongWord;
    ExtraChannelUpsampling: array of LongWord;
    GroupSizeShift: LongWord;
    XQmScale: LongWord;
    BQmScale: LongWord;
    Passes: TJxlPasses;
    LowFrequencyLevel: LongWord;
    CustomSizeOrOrigin: Boolean;
    X0: LongInt;
    Y0: LongInt;
    { The frame's size (the image's unless cropped). }
    FrameWidth: LongWord;
    FrameHeight: LongWord;
    Blending: TJxlBlendingInfo;
    ExtraChannelBlending: array of TJxlBlendingInfo;
    Duration: LongWord;
    Timecode: LongWord;
    IsLast: Boolean;
    SaveAsReference: LongWord;
    SaveBeforeColorTransform: Boolean;
    Name: string;
    LoopFilter: TJxlLoopFilter;
    Dimensions: TJxlFrameDimensions;
  end;

  { The LF (DC) dequantization multipliers of X, Y and B (LF global
    section, read for every frame). }
  TJxlLowFrequencyDequantization = array[0..2] of Single;

  TJxlTableOfContents = record
    { Byte offset of each section from the end of the table, and its
      size, in the sections' logical order. }
    Offsets: array of QWord;
    Sizes: array of LongWord;
    { The total of the sizes. }
    TotalSize: QWord;
  end;

{ Reads a frame header (the reader at its first, byte aligned, bit).
  A preview frame's size defaults to the preview's. }
function ReadJxlFrameHeader(Reader: TJxlBitReader; const Headers: TJxlImageHeaders;
  IsPreview: Boolean = False): TJxlFrameHeader;
{ The number of sections in the frame's table of contents. }
function JxlSectionCount(const Header: TJxlFrameHeader): LongInt;
{ Reads the table of contents and skips to the byte after it. }
function ReadJxlTableOfContents(Reader: TJxlBitReader; SectionCount: LongInt): TJxlTableOfContents;
{ Section indices in a table of contents. }
function JxlLowFrequencyGroupSection(Group: LongInt): LongInt;
function JxlHighFrequencyGlobalSection(const Dimensions: TJxlFrameDimensions): LongInt;
function JxlPassGroupSection(const Dimensions: TJxlFrameDimensions; Pass, Group: LongInt): LongInt;
{ The range of shifts (minimum shift of a channel's two) a pass's
  modular data covers. }
procedure JxlPassShiftRange(const Passes: TJxlPasses; Pass: LongInt; out MinimumShift, MaximumShift: LongInt);
{ Horizontal and vertical subsampling shift of colour channel Channel
  (0, 1, 2 as stored) for YCbCr frames. }
function JxlChromaHorizontalShift(const Header: TJxlFrameHeader; Channel: LongInt): LongInt;
function JxlChromaVerticalShift(const Header: TJxlFrameHeader; Channel: LongInt): LongInt;
{ True when the frame may be saved for later frames to reference. }
function JxlFrameCanBeReferenced(const Header: TJxlFrameHeader): Boolean;
{ Reads LfChannelDequantization (1/4096, 1/512, 1/256 by default). }
function ReadJxlLowFrequencyDequantization(Reader: TJxlBitReader): TJxlLowFrequencyDequantization;

implementation

uses
  Image.Jxl.Permutation;

const
  ChromaHorizontalShifts: array[0..3] of LongInt = (0, 1, 1, 0);
  ChromaVerticalShifts: array[0..3] of LongInt = (0, 1, 0, 1);

procedure RaiseBadFrame(const Detail: string);
begin
  RaiseImageError(ImageErrorMalformed, 'JPEG XL frame: ' + Detail);
end;

function DivideRoundingUp(Value, Divisor: Int64): Int64;
begin
  Result := (Value + Divisor - 1) div Divisor;
end;

function MaximumHorizontalShift(const Header: TJxlFrameHeader): LongInt;
var
  Channel: LongInt;
begin
  Result := 0;
  for Channel := 0 to 2 do
    if ChromaHorizontalShifts[Header.ChromaChannelMode[Channel]] > Result then
      Result := ChromaHorizontalShifts[Header.ChromaChannelMode[Channel]];
end;

function MaximumVerticalShift(const Header: TJxlFrameHeader): LongInt;
var
  Channel: LongInt;
begin
  Result := 0;
  for Channel := 0 to 2 do
    if ChromaVerticalShifts[Header.ChromaChannelMode[Channel]] > Result then
      Result := ChromaVerticalShifts[Header.ChromaChannelMode[Channel]];
end;

function JxlChromaHorizontalShift(const Header: TJxlFrameHeader; Channel: LongInt): LongInt;
begin
  Result := MaximumHorizontalShift(Header) - ChromaHorizontalShifts[Header.ChromaChannelMode[Channel]];
end;

function JxlChromaVerticalShift(const Header: TJxlFrameHeader; Channel: LongInt): LongInt;
begin
  Result := MaximumVerticalShift(Header) - ChromaVerticalShifts[Header.ChromaChannelMode[Channel]];
end;

function JxlFrameCanBeReferenced(const Header: TJxlFrameHeader): Boolean;
begin
  Result := (not Header.IsLast) and (Header.FrameType <> JxlFrameLowFrequency) and
    ((Header.Duration = 0) or (Header.SaveAsReference <> 0));
end;

function ReadJxlLowFrequencyDequantization(Reader: TJxlBitReader): TJxlLowFrequencyDequantization;
var
  Channel: LongInt;
begin
  Result[0] := 1.0 / 4096;
  Result[1] := 1.0 / 512;
  Result[2] := 1.0 / 256;
  if Reader.ReadBool then
    Exit;
  for Channel := 0 to 2 do
  begin
    Result[Channel] := Reader.ReadF16 * (1.0 / 128);
    if Result[Channel] < 1e-8 then
      RaiseBadFrame('bad LF dequantization');
  end;
end;

function ReadBlendingInfo(Reader: TJxlBitReader; ExtraChannelCount: LongInt;
  IsPartialFrame: Boolean): TJxlBlendingInfo;
begin
  Result := Default(TJxlBlendingInfo);
  Result.Mode := Reader.ReadU32(JxlVal(JxlBlendReplace), JxlVal(JxlBlendAdd), JxlVal(JxlBlendBlend),
    JxlBitsOffset(2, 3));
  if Result.Mode > JxlBlendMultiply then
    RaiseBadFrame('bad blend mode');
  if (ExtraChannelCount > 0) and ((Result.Mode = JxlBlendBlend) or (Result.Mode = JxlBlendAlphaWeightedAdd)) then
  begin
    Result.AlphaChannel := Reader.ReadU32(JxlVal(0), JxlVal(1), JxlVal(2), JxlBitsOffset(3, 3));
    if Result.AlphaChannel >= LongWord(ExtraChannelCount) then
      RaiseBadFrame('bad blending alpha channel');
  end;
  if ((ExtraChannelCount > 0) and ((Result.Mode = JxlBlendBlend) or (Result.Mode = JxlBlendAlphaWeightedAdd)))
    or (Result.Mode = JxlBlendMultiply) then
    Result.Clamp := Reader.ReadBool;
  if (Result.Mode <> JxlBlendReplace) or IsPartialFrame then
    Result.Source := Reader.ReadU32(JxlVal(0), JxlVal(1), JxlVal(2), JxlVal(3));
end;

procedure ReadPasses(Reader: TJxlBitReader; var Passes: TJxlPasses);
var
  Index: LongWord;
begin
  Passes := Default(TJxlPasses);
  Passes.Count := Reader.ReadU32(JxlVal(1), JxlVal(2), JxlVal(3), JxlBitsOffset(3, 4));
  if Passes.Count > JxlMaximumPasses then
    RaiseBadFrame('too many passes');
  if Passes.Count = 1 then
    Exit;
  Passes.DownsampleCount := Reader.ReadU32(JxlVal(0), JxlVal(1), JxlVal(2), JxlBitsOffset(1, 3));
  if (Passes.DownsampleCount > 4) or (Passes.DownsampleCount > Passes.Count) then
    RaiseBadFrame('bad pass downsampling');
  for Index := 0 to Passes.Count - 2 do
    Passes.Shift[Index] := Reader.ReadBits(2);
  Passes.Shift[Passes.Count - 1] := 0;
  for Index := 1 to Passes.DownsampleCount do
  begin
    Passes.Downsample[Index - 1] := Reader.ReadU32(JxlVal(1), JxlVal(2), JxlVal(4), JxlVal(8));
    if (Index > 1) and (Passes.Downsample[Index - 1] >= Passes.Downsample[Index - 2]) then
      RaiseBadFrame('bad pass downsampling');
  end;
  for Index := 1 to Passes.DownsampleCount do
  begin
    Passes.LastPass[Index - 1] := Reader.ReadU32(JxlVal(0), JxlVal(1), JxlVal(2), JxlBits(3));
    if ((Index > 1) and (Passes.LastPass[Index - 1] <= Passes.LastPass[Index - 2])) or
      (Passes.LastPass[Index - 1] >= Passes.Count) then
      RaiseBadFrame('bad last pass');
  end;
end;

procedure SetDefaultLoopFilter(var Filter: TJxlLoopFilter);
var
  Index: LongInt;
begin
  Filter.Gaborish := True;
  for Index := 0 to 2 do
  begin
    Filter.GaborishWeights[Index, 0] := 1.1 * 0.104699568;
    Filter.GaborishWeights[Index, 1] := 1.1 * 0.055680538;
  end;
  Filter.EpfIterations := 2;
  for Index := 0 to 7 do
    Filter.EpfSharpLut[Index] := Index / 7;
  Filter.EpfChannelScale[0] := 40.0;
  Filter.EpfChannelScale[1] := 5.0;
  Filter.EpfChannelScale[2] := 3.5;
  Filter.EpfPass1ZeroFlush := 0.45;
  Filter.EpfPass2ZeroFlush := 0.6;
  Filter.EpfQuantMultiplier := 0.46;
  Filter.EpfPass0SigmaScale := 0.9;
  Filter.EpfPass2SigmaScale := 6.5;
  Filter.EpfBorderSadMultiplier := 2.0 / 3.0;
  Filter.EpfSigmaForModular := 1.0;
end;

procedure ReadLoopFilter(Reader: TJxlBitReader; IsModular: Boolean; var Filter: TJxlLoopFilter);
var
  Index: LongInt;
begin
  SetDefaultLoopFilter(Filter);
  if Reader.ReadBool then
    Exit;
  Filter.Gaborish := Reader.ReadBool;
  if Filter.Gaborish and Reader.ReadBool then
    for Index := 0 to 2 do
    begin
      Filter.GaborishWeights[Index, 0] := Reader.ReadF16;
      Filter.GaborishWeights[Index, 1] := Reader.ReadF16;
      if Abs(1.0 + (Filter.GaborishWeights[Index, 0] + Filter.GaborishWeights[Index, 1]) * 4) < 1e-8 then
        RaiseBadFrame('bad gaborish weights');
    end;
  Filter.EpfIterations := Reader.ReadBits(2);
  if Filter.EpfIterations > 0 then
  begin
    if (not IsModular) and Reader.ReadBool then
      for Index := 0 to 7 do
        Filter.EpfSharpLut[Index] := Reader.ReadF16;
    if Reader.ReadBool then
    begin
      for Index := 0 to 2 do
        Filter.EpfChannelScale[Index] := Reader.ReadF16;
      Filter.EpfPass1ZeroFlush := Reader.ReadF16;
      Filter.EpfPass2ZeroFlush := Reader.ReadF16;
    end;
    if Reader.ReadBool then
    begin
      if not IsModular then
        Filter.EpfQuantMultiplier := Reader.ReadF16;
      Filter.EpfPass0SigmaScale := Reader.ReadF16;
      Filter.EpfPass2SigmaScale := Reader.ReadF16;
      Filter.EpfBorderSadMultiplier := Reader.ReadF16;
    end;
    if IsModular then
    begin
      Filter.EpfSigmaForModular := Reader.ReadF16;
      if Filter.EpfSigmaForModular < 1e-8 then
        RaiseBadFrame('bad edge preserving filter sigma');
    end;
  end;
  Reader.SkipExtensions;
end;

procedure ComputeDimensions(var Header: TJxlFrameHeader);
var
  Dimensions: TJxlFrameDimensions;
  HorizontalShift: LongInt;
  VerticalShift: LongInt;
  Width: Int64;
  Height: Int64;
begin
  Width := Header.FrameWidth;
  Height := Header.FrameHeight;
  if Header.LowFrequencyLevel <> 0 then
  begin
    Width := DivideRoundingUp(Width, Int64(1) shl (3 * Header.LowFrequencyLevel));
    Height := DivideRoundingUp(Height, Int64(1) shl (3 * Header.LowFrequencyLevel));
  end;
  if (Width <= 0) or (Height <= 0) or (Width > 1 shl 30) or (Height > 1 shl 30) then
    RaiseBadFrame('bad frame size');
  HorizontalShift := MaximumHorizontalShift(Header);
  VerticalShift := MaximumVerticalShift(Header);
  Dimensions.UpsampledWidth := Width;
  Dimensions.UpsampledHeight := Height;
  Dimensions.GroupDimension := 128 shl Header.GroupSizeShift;
  Dimensions.LowFrequencyGroupDimension := Dimensions.GroupDimension * 8;
  Dimensions.Width := DivideRoundingUp(Width, Header.Upsampling);
  Dimensions.Height := DivideRoundingUp(Height, Header.Upsampling);
  Dimensions.WidthInBlocks := DivideRoundingUp(Dimensions.Width, Int64(8) shl HorizontalShift) shl HorizontalShift;
  Dimensions.HeightInBlocks := DivideRoundingUp(Dimensions.Height, Int64(8) shl VerticalShift) shl VerticalShift;
  if Header.Encoding = JxlEncodingModular then
  begin
    Dimensions.PaddedWidth := Dimensions.Width;
    Dimensions.PaddedHeight := Dimensions.Height;
  end
  else
  begin
    Dimensions.PaddedWidth := Dimensions.WidthInBlocks * 8;
    Dimensions.PaddedHeight := Dimensions.HeightInBlocks * 8;
  end;
  Dimensions.GroupColumns := DivideRoundingUp(Dimensions.Width, Dimensions.GroupDimension);
  Dimensions.GroupRows := DivideRoundingUp(Dimensions.Height, Dimensions.GroupDimension);
  Dimensions.LowFrequencyGroupColumns := DivideRoundingUp(Dimensions.WidthInBlocks, Dimensions.GroupDimension);
  Dimensions.LowFrequencyGroupRows := DivideRoundingUp(Dimensions.HeightInBlocks, Dimensions.GroupDimension);
  Dimensions.GroupCount := Dimensions.GroupColumns * Dimensions.GroupRows;
  Dimensions.LowFrequencyGroupCount := Dimensions.LowFrequencyGroupColumns * Dimensions.LowFrequencyGroupRows;
  Header.Dimensions := Dimensions;
end;

function ReadJxlFrameHeader(Reader: TJxlBitReader; const Headers: TJxlImageHeaders;
  IsPreview: Boolean): TJxlFrameHeader;
var
  DefaultWidth: LongWord;
  DefaultHeight: LongWord;
  ExtraCount: LongInt;
  Index: LongInt;
  Distributions: array[0..3] of TJxlU32Distribution;
  IsPartialFrame: Boolean;
  DimensionShift: LongWord;
  Upsampling: LongWord;
begin
  Result := Default(TJxlFrameHeader);
  ExtraCount := Length(Headers.Metadata.ExtraChannels);
  Result.FrameType := JxlFrameRegular;
  Result.Encoding := JxlEncodingVarDct;
  if Headers.Metadata.XybEncoded then
    Result.ColorTransform := JxlColorTransformXyb
  else
    Result.ColorTransform := JxlColorTransformNone;
  Result.Upsampling := 1;
  SetLength(Result.ExtraChannelUpsampling, ExtraCount);
  for Index := 0 to ExtraCount - 1 do
    Result.ExtraChannelUpsampling[Index] := 1 shl Headers.Metadata.ExtraChannels[Index].DimensionShift;
  Result.GroupSizeShift := 1;
  if Result.ColorTransform = JxlColorTransformXyb then
  begin
    Result.XQmScale := 3;
    Result.BQmScale := 2;
  end
  else
  begin
    Result.XQmScale := 2;
    Result.BQmScale := 2;
  end;
  Result.Passes.Count := 1;
  if IsPreview then
  begin
    DefaultWidth := Headers.Metadata.PreviewWidth;
    DefaultHeight := Headers.Metadata.PreviewHeight;
  end
  else
  begin
    DefaultWidth := Headers.Width;
    DefaultHeight := Headers.Height;
  end;
  Result.FrameWidth := DefaultWidth;
  Result.FrameHeight := DefaultHeight;
  SetLength(Result.ExtraChannelBlending, ExtraCount);
  Result.IsLast := True;
  SetDefaultLoopFilter(Result.LoopFilter);
  if Reader.ReadBool then
  begin
    ComputeDimensions(Result);
    Exit;
  end;
  Result.FrameType := Reader.ReadU32(JxlVal(0), JxlVal(1), JxlVal(2), JxlVal(3));
  if Reader.ReadBool then
    Result.Encoding := JxlEncodingModular;
  Result.Flags := Reader.ReadU64;
  if not Headers.Metadata.XybEncoded then
  begin
    if Reader.ReadBool then
      Result.ColorTransform := JxlColorTransformYCbCr;
  end;
  if (Result.ColorTransform = JxlColorTransformYCbCr) and ((Result.Flags and JxlFlagUseLowFrequencyFrame) = 0) then
    for Index := 0 to 2 do
      Result.ChromaChannelMode[Index] := Reader.ReadBits(2);
  if (Result.Flags and JxlFlagUseLowFrequencyFrame) = 0 then
  begin
    Result.Upsampling := Reader.ReadU32(JxlVal(1), JxlVal(2), JxlVal(4), JxlVal(8));
    for Index := 0 to ExtraCount - 1 do
    begin
      DimensionShift := Headers.Metadata.ExtraChannels[Index].DimensionShift;
      Upsampling := Reader.ReadU32(JxlVal(1), JxlVal(2), JxlVal(4), JxlVal(8));
      Upsampling := Upsampling shl DimensionShift;
      if (Upsampling < Result.Upsampling) or (Upsampling > 8) then
        RaiseBadFrame('bad extra channel upsampling');
      Result.ExtraChannelUpsampling[Index] := Upsampling;
    end;
  end;
  if Result.Encoding = JxlEncodingModular then
    Result.GroupSizeShift := Reader.ReadBits(2);
  if (Result.Encoding = JxlEncodingVarDct) and (Result.ColorTransform = JxlColorTransformXyb) then
  begin
    Result.XQmScale := Reader.ReadBits(3);
    Result.BQmScale := Reader.ReadBits(3);
  end
  else
  begin
    Result.XQmScale := 2;
    Result.BQmScale := 2;
  end;
  if Result.FrameType <> JxlFrameReferenceOnly then
    ReadPasses(Reader, Result.Passes);
  if Result.FrameType = JxlFrameLowFrequency then
    Result.LowFrequencyLevel := Reader.ReadU32(JxlVal(1), JxlVal(2), JxlVal(3), JxlVal(4));
  IsPartialFrame := False;
  if Result.FrameType <> JxlFrameLowFrequency then
  begin
    Result.CustomSizeOrOrigin := Reader.ReadBool;
    if Result.CustomSizeOrOrigin then
    begin
      Distributions[0] := JxlBits(8);
      Distributions[1] := JxlBitsOffset(11, 256);
      Distributions[2] := JxlBitsOffset(14, 2304);
      Distributions[3] := JxlBitsOffset(30, 18688);
      if (Result.FrameType = JxlFrameRegular) or (Result.FrameType = JxlFrameSkipProgressive) then
      begin
        Result.X0 := JxlUnpackSigned(Reader.ReadU32(Distributions[0], Distributions[1], Distributions[2],
          Distributions[3]));
        Result.Y0 := JxlUnpackSigned(Reader.ReadU32(Distributions[0], Distributions[1], Distributions[2],
          Distributions[3]));
      end;
      Result.FrameWidth := Reader.ReadU32(Distributions[0], Distributions[1], Distributions[2], Distributions[3]);
      Result.FrameHeight := Reader.ReadU32(Distributions[0], Distributions[1], Distributions[2], Distributions[3]);
      if (Result.FrameWidth = 0) or (Result.FrameHeight = 0) then
        RaiseBadFrame('empty frame');
      if (Result.FrameType = JxlFrameRegular) or (Result.FrameType = JxlFrameSkipProgressive) then
        IsPartialFrame := (Result.X0 > 0) or (Result.Y0 > 0) or
          (Int64(Result.FrameWidth) + Result.X0 < Int64(DefaultWidth)) or
          (Int64(Result.FrameHeight) + Result.Y0 < Int64(DefaultHeight));
    end;
  end;
  if (Result.FrameType = JxlFrameRegular) or (Result.FrameType = JxlFrameSkipProgressive) then
  begin
    Result.Blending := ReadBlendingInfo(Reader, ExtraCount, IsPartialFrame);
    for Index := 0 to ExtraCount - 1 do
      Result.ExtraChannelBlending[Index] := ReadBlendingInfo(Reader, ExtraCount, IsPartialFrame);
    if Headers.Metadata.HaveAnimation then
    begin
      Result.Duration := Reader.ReadU32(JxlVal(0), JxlVal(1), JxlBits(8), JxlBits(32));
      if Headers.Metadata.Animation.HaveTimecodes then
        Result.Timecode := Reader.ReadBits(32);
    end;
    Result.IsLast := Reader.ReadBool;
  end
  else
    Result.IsLast := False;
  if (Result.FrameType <> JxlFrameLowFrequency) and not Result.IsLast then
    Result.SaveAsReference := Reader.ReadU32(JxlVal(0), JxlVal(1), JxlVal(2), JxlVal(3));
  if Result.FrameType <> JxlFrameLowFrequency then
  begin
    if JxlFrameCanBeReferenced(Result) and (Result.Blending.Mode = JxlBlendReplace) and (not IsPartialFrame) and
      ((Result.FrameType = JxlFrameRegular) or (Result.FrameType = JxlFrameSkipProgressive)) then
      Result.SaveBeforeColorTransform := Reader.ReadBool
    else if Result.FrameType = JxlFrameReferenceOnly then
      Result.SaveBeforeColorTransform := Reader.ReadBool;
  end
  else
    Result.SaveBeforeColorTransform := True;
  Result.Name := '';
  Index := LongInt(Reader.ReadU32(JxlVal(0), JxlBits(4), JxlBitsOffset(5, 16), JxlBitsOffset(10, 48)));
  while Index > 0 do
  begin
    Result.Name := Result.Name + Chr(Reader.ReadBits(8));
    Dec(Index);
  end;
  ReadLoopFilter(Reader, Result.Encoding = JxlEncodingModular, Result.LoopFilter);
  Reader.SkipExtensions;
  ComputeDimensions(Result);
end;

function JxlSectionCount(const Header: TJxlFrameHeader): LongInt;
begin
  if (Header.Dimensions.GroupCount = 1) and (Header.Passes.Count = 1) then
    Exit(1);
  Result := 2 + Header.Dimensions.LowFrequencyGroupCount
    + Header.Dimensions.GroupCount * LongInt(Header.Passes.Count);
end;

function JxlLowFrequencyGroupSection(Group: LongInt): LongInt;
begin
  Result := 1 + Group;
end;

function JxlHighFrequencyGlobalSection(const Dimensions: TJxlFrameDimensions): LongInt;
begin
  Result := 1 + Dimensions.LowFrequencyGroupCount;
end;

function JxlPassGroupSection(const Dimensions: TJxlFrameDimensions; Pass, Group: LongInt): LongInt;
begin
  Result := 2 + Dimensions.LowFrequencyGroupCount + Pass * Dimensions.GroupCount + Group;
end;

procedure JxlPassShiftRange(const Passes: TJxlPasses; Pass: LongInt; out MinimumShift, MaximumShift: LongInt);
var
  Index: LongInt;
  Downsample: LongInt;
begin
  MaximumShift := 2;
  MinimumShift := 3;
  Index := 0;
  while True do
  begin
    for Downsample := 0 to LongInt(Passes.DownsampleCount) - 1 do
      if Index = LongInt(Passes.LastPass[Downsample]) then
        case Passes.Downsample[Downsample] of
          8: MinimumShift := 3;
          4: MinimumShift := 2;
          2: MinimumShift := 1;
          1: MinimumShift := 0;
        end;
    if Index = LongInt(Passes.Count) - 1 then
      MinimumShift := 0;
    if Index = Pass then
      Exit;
    MaximumShift := MinimumShift - 1;
    Inc(Index);
  end;
end;

function ReadJxlTableOfContents(Reader: TJxlBitReader; SectionCount: LongInt): TJxlTableOfContents;
var
  Permuted: Boolean;
  Permutation: TJxlPermutation;
  Index: LongInt;
  Offset: QWord;
  Offsets: array of QWord;
  Sizes: array of LongWord;
begin
  if (SectionCount <= 0) or (SectionCount > 65536) then
    RaiseBadFrame('too many sections');
  if Int64(SectionCount) * 12 > Reader.TotalBits - Reader.BitPosition then
    RaiseImageError(ImageErrorTruncated, 'JPEG XL table of contents');
  Permuted := Reader.ReadBool;
  Permutation := nil;
  if Permuted then
    Permutation := DecodeJxlPermutation(Reader, SectionCount, 0);
  Reader.ZeroPadToByte;
  SetLength(Sizes, SectionCount);
  SetLength(Offsets, SectionCount);
  for Index := 0 to SectionCount - 1 do
    Sizes[Index] := Reader.ReadU32(JxlBits(10), JxlBitsOffset(14, 1024), JxlBitsOffset(22, 17408),
      JxlBitsOffset(30, 4211712));
  Reader.ZeroPadToByte;
  Offset := 0;
  for Index := 0 to SectionCount - 1 do
  begin
    Offsets[Index] := Offset;
    Inc(Offset, Sizes[Index]);
  end;
  Result.TotalSize := Offset;
  SetLength(Result.Offsets, SectionCount);
  SetLength(Result.Sizes, SectionCount);
  for Index := 0 to SectionCount - 1 do
    if Permuted then
    begin
      Result.Offsets[Index] := Offsets[Permutation[Index]];
      Result.Sizes[Index] := Sizes[Permutation[Index]];
    end
    else
    begin
      Result.Offsets[Index] := Offsets[Index];
      Result.Sizes[Index] := Sizes[Index];
    end;
end;

end.
