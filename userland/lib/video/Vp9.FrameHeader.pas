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
  The VP9 frame headers (sections 6.2 and 6.3 of the VP9 specification;
  libvpx's read_uncompressed_header and read_compressed_header): the
  uncompressed one (frame type, size, references, loop filter,
  quantizers, segmentation, tiles) in plain bits, the compressed one
  (transform mode, probability updates) with the boolean decoder.

  What lasts from frame to frame (segmentation, loop filter deltas, the
  colour format) is in TVp9StreamHeaderState, which the header changes.
}
unit Vp9.FrameHeader;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils, Video.BoolDecoder, Vp9.BitReader, Vp9.Probabilities, Vp9.FrameState, Vp9.LoopFilter;

type
  EVp9Error = class(Exception);

  TVp9StreamHeaderState = record
    Profile: LongInt;
    BitDepth: LongInt;
    ColorSpace: LongInt;
    FullRange: Boolean;
    SubsamplingX, SubsamplingY: LongInt;
    Segmentation: TVp9Segmentation;
    LoopFilter: TVp9LoopFilterParameters;
  end;

  { The size and colour format of the reference slots, which a frame
    may take its size from. }
  TVp9ReferenceSizes = array[0..7] of record
    Valid: Boolean;
    Width, Height: LongInt;
  end;

  TVp9FrameHeader = record
    ShowExistingFrame: Boolean;
    ExistingFrameIndex: LongInt;
    KeyFrame: Boolean;
    ShowFrame: Boolean;
    ErrorResilient: Boolean;
    IntraOnly: Boolean;
    ResetFrameContext: LongInt;
    RefreshFlags: LongInt;
    ReferenceIndices: array[0..2] of LongInt;
    SignBias: array[0..3] of Boolean;
    Width, Height: LongInt;
    RenderWidth, RenderHeight: LongInt;
    AllowHighPrecisionMv: Boolean;
    Filter: LongInt;
    RefreshFrameContext: Boolean;
    FrameParallel: Boolean;
    FrameContextIndex: LongInt;
    BaseQuantizer: LongInt;
    LumaDcDelta, ChromaDcDelta, ChromaAcDelta: LongInt;
    Lossless: Boolean;
    TileColumnsLog2, TileRowsLog2: LongInt;
    CompressedHeaderSize: LongInt;
    UncompressedHeaderSize: LongInt;
    { Compressed header. }
    TransformMode: LongInt;
    ReferenceMode: LongInt;
    FixedReference: LongInt;
    VariableReferences: array[0..1] of LongInt;
  end;

{ Reads the uncompressed header of the frame of Size bytes at Data.
  For a frame that starts without the past (key, intra-only, error
  resilient) it resets the segment features, loop filter deltas and sign
  biases; the caller resets the probabilities and segment maps. }
procedure ReadUncompressedHeader(Data: PByte; Size: PtrInt; var State: TVp9StreamHeaderState;
  constref References: TVp9ReferenceSizes; out Header: TVp9FrameHeader);

{ Reads the compressed header into Header and the probabilities. }
procedure ReadCompressedHeader(Data: PByte; Size: PtrInt; var Header: TVp9FrameHeader;
  var Probabilities: TVp9FrameContext; IntraOnly: Boolean);

{ Whether a frame with these sign biases may use compound prediction. }
function CompoundAllowed(constref Header: TVp9FrameHeader): Boolean;

implementation

uses
  Vp9.Tables;

const
  SyncCode0 = $49;
  SyncCode1 = $83;
  SyncCode2 = $42;

procedure ReadSyncCode(var Reader: TVp9BitReader);
begin
  if (Reader.ReadLiteral(8) <> SyncCode0) or (Reader.ReadLiteral(8) <> SyncCode1) or
    (Reader.ReadLiteral(8) <> SyncCode2) then
    raise EVp9Error.Create('VP9: invalid frame sync code');
end;

procedure ReadColorConfig(var Reader: TVp9BitReader; var State: TVp9StreamHeaderState);
begin
  if State.Profile >= 2 then
  begin
    if Reader.ReadBit <> 0 then
      State.BitDepth := 12
    else
      State.BitDepth := 10;
  end
  else
    State.BitDepth := 8;
  State.ColorSpace := Reader.ReadLiteral(3);
  if State.ColorSpace <> 7 then
  begin
    State.FullRange := Reader.ReadBit <> 0;
    if (State.Profile = 1) or (State.Profile = 3) then
    begin
      State.SubsamplingX := Reader.ReadBit;
      State.SubsamplingY := Reader.ReadBit;
      if (State.SubsamplingX = 1) and (State.SubsamplingY = 1) then
        raise EVp9Error.Create('VP9: 4:2:0 colour not supported in profile 1 or 3');
      if Reader.ReadBit <> 0 then
        raise EVp9Error.Create('VP9: reserved bit set');
    end
    else
    begin
      State.SubsamplingX := 1;
      State.SubsamplingY := 1;
    end;
  end
  else
  begin
    State.FullRange := True;
    if (State.Profile = 1) or (State.Profile = 3) then
    begin
      State.SubsamplingX := 0;
      State.SubsamplingY := 0;
      if Reader.ReadBit <> 0 then
        raise EVp9Error.Create('VP9: reserved bit set');
    end
    else
      raise EVp9Error.Create('VP9: 4:4:4 colour not supported in profile 0 or 2');
  end;
end;

procedure ReadFrameSize(var Reader: TVp9BitReader; out Width, Height: LongInt);
begin
  Width := Reader.ReadLiteral(16) + 1;
  Height := Reader.ReadLiteral(16) + 1;
end;

procedure ReadRenderSize(var Reader: TVp9BitReader; var Header: TVp9FrameHeader);
begin
  Header.RenderWidth := Header.Width;
  Header.RenderHeight := Header.Height;
  if Reader.ReadBit <> 0 then
    ReadFrameSize(Reader, Header.RenderWidth, Header.RenderHeight);
end;

procedure ResetSegmentFeatures(var Segmentation: TVp9Segmentation);
begin
  FillChar(Segmentation.FeatureEnabled, SizeOf(Segmentation.FeatureEnabled), 0);
  FillChar(Segmentation.FeatureData, SizeOf(Segmentation.FeatureData), 0);
end;

procedure ReadLoopFilter(var Reader: TVp9BitReader; var Parameters: TVp9LoopFilterParameters);
var
  Index: LongInt;
begin
  Parameters.FilterLevel := Reader.ReadLiteral(6);
  Parameters.Sharpness := Reader.ReadLiteral(3);
  Parameters.DeltasEnabled := Reader.ReadBit <> 0;
  if Parameters.DeltasEnabled then
    if Reader.ReadBit <> 0 then
    begin
      for Index := 0 to 3 do
        if Reader.ReadBit <> 0 then
          Parameters.ReferenceDeltas[Index] := Reader.ReadSignedLiteral(6);
      for Index := 0 to 1 do
        if Reader.ReadBit <> 0 then
          Parameters.ModeDeltas[Index] := Reader.ReadSignedLiteral(6);
    end;
end;

function ReadDeltaQuantizer(var Reader: TVp9BitReader): LongInt;
begin
  Result := 0;
  if Reader.ReadBit <> 0 then
    Result := Reader.ReadSignedLiteral(4);
end;

function UnsignedBits(Value: LongInt): LongInt;
begin
  Result := 0;
  while Value > 0 do
  begin
    Inc(Result);
    Value := Value shr 1;
  end;
end;

procedure ReadSegmentation(var Reader: TVp9BitReader; var Segmentation: TVp9Segmentation);
const
  FeatureMaximum: array[0..3] of LongInt = (255, 63, 3, 0);
  FeatureSigned: array[0..3] of Boolean = (True, True, False, False);
var
  Index, Segment, Feature, Value: LongInt;
begin
  Segmentation.UpdateMap := False;
  Segmentation.UpdateData := False;
  Segmentation.Enabled := Reader.ReadBit <> 0;
  if not Segmentation.Enabled then
    Exit;
  Segmentation.UpdateMap := Reader.ReadBit <> 0;
  if Segmentation.UpdateMap then
  begin
    for Index := 0 to 6 do
      if Reader.ReadBit <> 0 then
        Segmentation.TreeProbabilities[Index] := Reader.ReadLiteral(8)
      else
        Segmentation.TreeProbabilities[Index] := 255;
    Segmentation.TemporalUpdate := Reader.ReadBit <> 0;
    for Index := 0 to 2 do
      if Segmentation.TemporalUpdate and (Reader.ReadBit <> 0) then
        Segmentation.PredictionProbabilities[Index] := Reader.ReadLiteral(8)
      else
        Segmentation.PredictionProbabilities[Index] := 255;
  end;
  Segmentation.UpdateData := Reader.ReadBit <> 0;
  if Segmentation.UpdateData then
  begin
    Segmentation.AbsoluteValues := Reader.ReadBit <> 0;
    ResetSegmentFeatures(Segmentation);
    for Segment := 0 to 7 do
      for Feature := 0 to 3 do
      begin
        Value := 0;
        if Reader.ReadBit <> 0 then
        begin
          Segmentation.FeatureEnabled[Segment, Feature] := True;
          Value := Reader.ReadLiteral(UnsignedBits(FeatureMaximum[Feature]));
          if Value > FeatureMaximum[Feature] then
            Value := FeatureMaximum[Feature];
          if FeatureSigned[Feature] then
            if Reader.ReadBit <> 0 then
              Value := -Value;
        end;
        Segmentation.FeatureData[Segment, Feature] := Value;
      end;
  end;
end;

procedure ReadTileInfo(var Reader: TVp9BitReader; var Header: TVp9FrameHeader);
var
  MiColumns, SuperblockColumns, MinLog2, MaxLog2, MaxOnes: LongInt;
begin
  MiColumns := (Header.Width + 7) shr 3;
  SuperblockColumns := (MiColumns + 7) shr 3;
  MinLog2 := 0;
  while (64 shl MinLog2) < SuperblockColumns do
    Inc(MinLog2);
  MaxLog2 := 1;
  while (SuperblockColumns shr MaxLog2) >= 4 do
    Inc(MaxLog2);
  Dec(MaxLog2);
  MaxOnes := MaxLog2 - MinLog2;
  Header.TileColumnsLog2 := MinLog2;
  while (MaxOnes > 0) and (Reader.ReadBit <> 0) do
  begin
    Inc(Header.TileColumnsLog2);
    Dec(MaxOnes);
  end;
  if Header.TileColumnsLog2 > 6 then
    raise EVp9Error.Create('VP9: invalid number of tile columns');
  Header.TileRowsLog2 := Reader.ReadBit;
  if Header.TileRowsLog2 <> 0 then
    Inc(Header.TileRowsLog2, Reader.ReadBit);
end;

procedure SetDefaultLoopFilterDeltas(var Parameters: TVp9LoopFilterParameters);
begin
  Parameters.DeltasEnabled := True;
  Parameters.ReferenceDeltas[0] := 1;
  Parameters.ReferenceDeltas[1] := 0;
  Parameters.ReferenceDeltas[2] := -1;
  Parameters.ReferenceDeltas[3] := -1;
  Parameters.ModeDeltas[0] := 0;
  Parameters.ModeDeltas[1] := 0;
end;

procedure ReadUncompressedHeader(Data: PByte; Size: PtrInt; var State: TVp9StreamHeaderState;
  constref References: TVp9ReferenceSizes; out Header: TVp9FrameHeader);
var
  Reader: TVp9BitReader;
  Index, Reference: LongInt;
  Found: Boolean;
const
  FilterByLiteral: array[0..3] of LongInt = (FilterSmooth, FilterRegular, FilterSharp, FilterBilinear);
begin
  Header := Default(TVp9FrameHeader);
  Reader.Init(Data, Size);
  if Reader.ReadLiteral(2) <> 2 then
    raise EVp9Error.Create('VP9: invalid frame marker');
  State.Profile := Reader.ReadBit;
  State.Profile := State.Profile or (Reader.ReadBit shl 1);
  if State.Profile > 2 then
    Inc(State.Profile, Reader.ReadBit);
  if State.Profile > 3 then
    raise EVp9Error.Create('VP9: unsupported bitstream profile');
  Header.ShowExistingFrame := Reader.ReadBit <> 0;
  if Header.ShowExistingFrame then
  begin
    Header.ExistingFrameIndex := Reader.ReadLiteral(3);
    Header.ShowFrame := True;
    Header.UncompressedHeaderSize := Reader.BytesRead;
    Exit;
  end;
  Header.KeyFrame := Reader.ReadBit = 0;
  Header.ShowFrame := Reader.ReadBit <> 0;
  Header.ErrorResilient := Reader.ReadBit <> 0;
  if Header.KeyFrame then
  begin
    ReadSyncCode(Reader);
    ReadColorConfig(Reader, State);
    Header.RefreshFlags := $FF;
    ReadFrameSize(Reader, Header.Width, Header.Height);
    ReadRenderSize(Reader, Header);
  end
  else
  begin
    if not Header.ShowFrame then
      Header.IntraOnly := Reader.ReadBit <> 0;
    if not Header.ErrorResilient then
      Header.ResetFrameContext := Reader.ReadLiteral(2);
    if Header.IntraOnly then
    begin
      ReadSyncCode(Reader);
      if State.Profile > 0 then
        ReadColorConfig(Reader, State)
      else
      begin
        State.ColorSpace := 1;
        State.FullRange := False;
        State.SubsamplingX := 1;
        State.SubsamplingY := 1;
        State.BitDepth := 8;
      end;
      Header.RefreshFlags := Reader.ReadLiteral(8);
      ReadFrameSize(Reader, Header.Width, Header.Height);
      ReadRenderSize(Reader, Header);
    end
    else
    begin
      Header.RefreshFlags := Reader.ReadLiteral(8);
      for Index := 0 to 2 do
      begin
        Reference := Reader.ReadLiteral(3);
        if not References[Reference].Valid then
          raise EVp9Error.Create('VP9: invalid reference frame index');
        Header.ReferenceIndices[Index] := Reference;
        Header.SignBias[1 + Index] := Reader.ReadBit <> 0;
      end;
      Found := False;
      for Index := 0 to 2 do
        if Reader.ReadBit <> 0 then
        begin
          Header.Width := References[Header.ReferenceIndices[Index]].Width;
          Header.Height := References[Header.ReferenceIndices[Index]].Height;
          Found := True;
          Break;
        end;
      if not Found then
        ReadFrameSize(Reader, Header.Width, Header.Height);
      if (Header.Width <= 0) or (Header.Height <= 0) then
        raise EVp9Error.Create('VP9: invalid frame size');
      ReadRenderSize(Reader, Header);
      Header.AllowHighPrecisionMv := Reader.ReadBit <> 0;
      if Reader.ReadBit <> 0 then
        Header.Filter := FilterSwitchable
      else
        Header.Filter := FilterByLiteral[Reader.ReadLiteral(2)];
    end;
  end;
  if not Header.ErrorResilient then
  begin
    Header.RefreshFrameContext := Reader.ReadBit <> 0;
    Header.FrameParallel := Reader.ReadBit <> 0;
  end
  else
  begin
    Header.RefreshFrameContext := False;
    Header.FrameParallel := True;
  end;
  Header.FrameContextIndex := Reader.ReadLiteral(2);
  if Header.KeyFrame or Header.IntraOnly or Header.ErrorResilient then
  begin
    { setup_past_independence: segmentation features and loop filter
      deltas back to their defaults; the decoder resets the rest. }
    ResetSegmentFeatures(State.Segmentation);
    State.Segmentation.AbsoluteValues := False;
    SetDefaultLoopFilterDeltas(State.LoopFilter);
    FillChar(Header.SignBias, SizeOf(Header.SignBias), 0);
  end;
  ReadLoopFilter(Reader, State.LoopFilter);
  Header.BaseQuantizer := Reader.ReadLiteral(8);
  Header.LumaDcDelta := ReadDeltaQuantizer(Reader);
  Header.ChromaDcDelta := ReadDeltaQuantizer(Reader);
  Header.ChromaAcDelta := ReadDeltaQuantizer(Reader);
  Header.Lossless := (Header.BaseQuantizer = 0) and (Header.LumaDcDelta = 0) and (Header.ChromaDcDelta = 0) and
    (Header.ChromaAcDelta = 0);
  ReadSegmentation(Reader, State.Segmentation);
  ReadTileInfo(Reader, Header);
  Header.CompressedHeaderSize := Reader.ReadLiteral(16);
  if Header.CompressedHeaderSize = 0 then
    raise EVp9Error.Create('VP9: invalid header size');
  Header.UncompressedHeaderSize := Reader.BytesRead;
end;

function CompoundAllowed(constref Header: TVp9FrameHeader): Boolean;
begin
  Result := (Header.SignBias[2] <> Header.SignBias[1]) or (Header.SignBias[3] <> Header.SignBias[1]);
end;

procedure SetupCompoundReferences(var Header: TVp9FrameHeader);
begin
  if Header.SignBias[1] = Header.SignBias[2] then
  begin
    Header.FixedReference := ReferenceAltRef;
    Header.VariableReferences[0] := ReferenceLast;
    Header.VariableReferences[1] := ReferenceGolden;
  end
  else if Header.SignBias[1] = Header.SignBias[3] then
  begin
    Header.FixedReference := ReferenceGolden;
    Header.VariableReferences[0] := ReferenceLast;
    Header.VariableReferences[1] := ReferenceAltRef;
  end
  else
  begin
    Header.FixedReference := ReferenceLast;
    Header.VariableReferences[0] := ReferenceGolden;
    Header.VariableReferences[1] := ReferenceAltRef;
  end;
end;

procedure UpdateMvProbabilities(var Decoder: TBoolDecoder; P: PByte; Count: LongInt);
var
  Index: LongInt;
begin
  for Index := 0 to Count - 1 do
    if Decoder.ReadBool(252) <> 0 then
      P[Index] := (Decoder.ReadLiteral(7) shl 1) or 1;
end;

procedure ReadCompressedHeader(Data: PByte; Size: PtrInt; var Header: TVp9FrameHeader;
  var Probabilities: TVp9FrameContext; IntraOnly: Boolean);
var
  Decoder: TBoolDecoder;
  I, J, K, L, M, Largest, Size2: LongInt;
begin
  Decoder.Init(Data, Size);
  if Decoder.ReadBit <> 0 then
    raise EVp9Error.Create('VP9: invalid compressed header marker');
  if Header.Lossless then
    Header.TransformMode := TransformModeOnly4x4
  else
  begin
    Header.TransformMode := Decoder.ReadLiteral(2);
    if Header.TransformMode = 3 then
      Inc(Header.TransformMode, Decoder.ReadBit);
  end;
  if Header.TransformMode = TransformModeSelect then
  begin
    for I := 0 to 1 do
      ReadProbabilityUpdate(Decoder, Probabilities.Transform8x8[I, 0]);
    for I := 0 to 1 do
      for J := 0 to 1 do
        ReadProbabilityUpdate(Decoder, Probabilities.Transform16x16[I, J]);
    for I := 0 to 1 do
      for J := 0 to 2 do
        ReadProbabilityUpdate(Decoder, Probabilities.Transform32x32[I, J]);
  end;
  Largest := TransformModeLargest[Header.TransformMode];
  for Size2 := 0 to Largest do
    if Decoder.ReadBit <> 0 then
      for I := 0 to 1 do
        for J := 0 to 1 do
          for K := 0 to 5 do
            for L := 0 to 5 do
            begin
              if (K = 0) and (L >= 3) then
                Continue;
              for M := 0 to 2 do
                ReadProbabilityUpdate(Decoder, Probabilities.Coefficients[Size2][I, J, K, L, M]);
            end;
  for I := 0 to 2 do
    ReadProbabilityUpdate(Decoder, Probabilities.Skip[I]);
  if not IntraOnly then
  begin
    for I := 0 to 6 do
      for J := 0 to 2 do
        ReadProbabilityUpdate(Decoder, Probabilities.InterModes[I, J]);
    if Header.Filter = FilterSwitchable then
      for I := 0 to 3 do
        for J := 0 to 1 do
          ReadProbabilityUpdate(Decoder, Probabilities.SwitchableFilters[I, J]);
    for I := 0 to 3 do
      ReadProbabilityUpdate(Decoder, Probabilities.IntraInter[I]);
    Header.ReferenceMode := ReferenceModeSingle;
    if CompoundAllowed(Header) then
    begin
      if Decoder.ReadBit <> 0 then
      begin
        if Decoder.ReadBit <> 0 then
          Header.ReferenceMode := ReferenceModeSelect
        else
          Header.ReferenceMode := ReferenceModeCompound;
      end;
    end;
    if Header.ReferenceMode <> ReferenceModeSingle then
      SetupCompoundReferences(Header);
    if Header.ReferenceMode = ReferenceModeSelect then
      for I := 0 to 4 do
        ReadProbabilityUpdate(Decoder, Probabilities.CompoundInter[I]);
    if Header.ReferenceMode <> ReferenceModeCompound then
      for I := 0 to 4 do
      begin
        ReadProbabilityUpdate(Decoder, Probabilities.SingleReference[I, 0]);
        ReadProbabilityUpdate(Decoder, Probabilities.SingleReference[I, 1]);
      end;
    if Header.ReferenceMode <> ReferenceModeSingle then
      for I := 0 to 4 do
        ReadProbabilityUpdate(Decoder, Probabilities.CompoundReference[I]);
    for J := 0 to 3 do
      for I := 0 to 8 do
        ReadProbabilityUpdate(Decoder, Probabilities.YModes[J, I]);
    for J := 0 to 15 do
      for I := 0 to 2 do
        ReadProbabilityUpdate(Decoder, Probabilities.Partitions[J, I]);
    UpdateMvProbabilities(Decoder, @Probabilities.MvJoints[0], 3);
    for I := 0 to 1 do
    begin
      UpdateMvProbabilities(Decoder, @Probabilities.MvComponents[I].Sign, 1);
      UpdateMvProbabilities(Decoder, @Probabilities.MvComponents[I].Classes[0], 10);
      UpdateMvProbabilities(Decoder, @Probabilities.MvComponents[I].Class0[0], 1);
      UpdateMvProbabilities(Decoder, @Probabilities.MvComponents[I].Bits[0], 10);
    end;
    for I := 0 to 1 do
    begin
      for J := 0 to 1 do
        UpdateMvProbabilities(Decoder, @Probabilities.MvComponents[I].Class0Fraction[J, 0], 3);
      UpdateMvProbabilities(Decoder, @Probabilities.MvComponents[I].Fraction[0], 3);
    end;
    if Header.AllowHighPrecisionMv then
      for I := 0 to 1 do
      begin
        UpdateMvProbabilities(Decoder, @Probabilities.MvComponents[I].Class0HighPrecision, 1);
        UpdateMvProbabilities(Decoder, @Probabilities.MvComponents[I].HighPrecision, 1);
      end;
  end;
  if Decoder.HasError then
    raise EVp9Error.Create('VP9: the frame data header is corrupted');
end;

end.
