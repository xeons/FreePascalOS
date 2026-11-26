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
  The VP8 frame header (RFC 6386 sections 9 and 19.2): the uncompressed
  tag (and a key frame's start code and size), then, in the first
  partition, segmentation, the loop filter, the token partitions, the
  quantizers, which reference pictures the frame replaces, and the
  probability updates.

  What lasts from frame to frame (probabilities, segmentation, the loop
  filter's deltas) is in TVp8StreamState, which the header changes.
}
unit Vp8.FrameHeader;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils, Video.BoolDecoder, Vp8.Residuals;

const
  MaxTokenPartitions = 8;

type
  TVp8EntropyState = record
    Coefficients: TCoefficientProbabilities;
    YModes: array[0..3] of Byte;
    UvModes: array[0..2] of Byte;
    MotionVectors: array[0..1, 0..18] of Byte;
  end;

  TVp8Segmentation = record
    Enabled: Boolean;
    UpdateMap: Boolean;
    UpdateData: Boolean;
    AbsoluteValues: Boolean;
    Quantizer: array[0..3] of LongInt;
    FilterLevel: array[0..3] of LongInt;
    TreeProbabilities: array[0..2] of Byte;
  end;

  TVp8StreamState = record
    Entropy: TVp8EntropyState;
    Segmentation: TVp8Segmentation;
    ReferenceDeltas: array[0..3] of LongInt;
    ModeDeltas: array[0..3] of LongInt;
    SignBias: array[0..3] of Boolean;
  end;

  TVp8FrameHeader = record
    KeyFrame: Boolean;
    Version: LongInt;
    ShowFrame: Boolean;
    Width, Height: LongInt;
    SimpleFilter: Boolean;
    FilterLevel: LongInt;
    Sharpness: LongInt;
    ModeReferenceDeltas: Boolean;
    PartitionCount: LongInt;
    BaseQuantizer: LongInt;
    Y1DcDelta, Y2DcDelta, Y2AcDelta, UvDcDelta, UvAcDelta: LongInt;
    RefreshGolden, RefreshAltRef, RefreshLast: Boolean;
    CopyToGolden, CopyToAltRef: LongInt;
    RefreshEntropy: Boolean;
    SkipEnabled: Boolean;
    SkipFalseProbability: LongInt;
    IntraProbability, LastProbability, GoldenProbability: LongInt;
    { Bilinear motion compensation, whole pixel chroma vectors. }
    Bilinear: Boolean;
    FullPixel: Boolean;
  end;

  TVp8Partitions = array[0..MaxTokenPartitions - 1] of TBoolDecoder;

  EVp8Error = class(Exception);

{ Puts State as a key frame leaves it before its header is read. }
procedure ResetStreamState(var State: TVp8StreamState);

{ Reads the tag of a frame of Size bytes at Data: whether it is a key
  frame and, for one, its size. Raises EVp8Error when it is not VP8. }
procedure ReadFrameTag(Data: PByte; Size: PtrInt; out Header: TVp8FrameHeader);

{ Reads the rest of the header (after ReadFrameTag), updating State, and
  starts the first partition's decoder (left where the modes begin) and
  the token partitions' decoders. Saved receives the entropy state to
  go back to after the frame when the header says not to keep it. }
procedure ReadFrameHeader(Data: PByte; Size: PtrInt; var Header: TVp8FrameHeader;
  var State: TVp8StreamState; out Saved: TVp8EntropyState;
  out FirstPartition: TBoolDecoder; out Partitions: TVp8Partitions);

implementation

uses
  Vp8.Tables;

procedure ResetStreamState(var State: TVp8StreamState);
begin
  Move(DefaultCoefficientProbabilities, State.Entropy.Coefficients, SizeOf(State.Entropy.Coefficients));
  Move(DefaultYModeProbabilities, State.Entropy.YModes, SizeOf(State.Entropy.YModes));
  Move(DefaultUvModeProbabilities, State.Entropy.UvModes, SizeOf(State.Entropy.UvModes));
  Move(DefaultMvProbabilities, State.Entropy.MotionVectors, SizeOf(State.Entropy.MotionVectors));
  FillChar(State.Segmentation.Quantizer, SizeOf(State.Segmentation.Quantizer), 0);
  FillChar(State.Segmentation.FilterLevel, SizeOf(State.Segmentation.FilterLevel), 0);
  State.Segmentation.AbsoluteValues := False;
  FillChar(State.ReferenceDeltas, SizeOf(State.ReferenceDeltas), 0);
  FillChar(State.ModeDeltas, SizeOf(State.ModeDeltas), 0);
  State.SignBias[ReferenceGolden] := False;
  State.SignBias[ReferenceAltRef] := False;
end;

procedure ReadFrameTag(Data: PByte; Size: PtrInt; out Header: TVp8FrameHeader);
begin
  Header := Default(TVp8FrameHeader);
  if Size < 3 then
    raise EVp8Error.Create('VP8: truncated frame');
  Header.KeyFrame := (Data[0] and 1) = 0;
  Header.Version := (Data[0] shr 1) and 7;
  Header.ShowFrame := ((Data[0] shr 4) and 1) <> 0;
  case Header.Version of
    1, 2:
      Header.Bilinear := True;
    3:
      begin
        Header.Bilinear := True;
        Header.FullPixel := True;
      end;
  end;
  if Header.KeyFrame then
  begin
    if Size < 10 then
      raise EVp8Error.Create('VP8: truncated key frame header');
    if (Data[3] <> $9D) or (Data[4] <> $01) or (Data[5] <> $2A) then
      raise EVp8Error.Create('VP8: invalid frame start code');
    Header.Width := (Data[6] or (Data[7] shl 8)) and $3FFF;
    Header.Height := (Data[8] or (Data[9] shl 8)) and $3FFF;
  end;
end;

function ReadSignedValue(var Decoder: TBoolDecoder; Bits: LongInt): LongInt;
begin
  Result := Decoder.ReadLiteral(Bits);
  if Decoder.ReadBit <> 0 then
    Result := -Result;
end;

function ReadQuantizerDelta(var Decoder: TBoolDecoder): LongInt;
begin
  Result := 0;
  if Decoder.ReadBit <> 0 then
    Result := ReadSignedValue(Decoder, 4);
end;

procedure ReadSegmentation(var Decoder: TBoolDecoder; var Segmentation: TVp8Segmentation);
const
  FeatureBits: array[0..1] of LongInt = (7, 6);
var
  Feature, Segment, Value, Index: LongInt;
begin
  Segmentation.Enabled := Decoder.ReadBit <> 0;
  if not Segmentation.Enabled then
  begin
    Segmentation.UpdateMap := False;
    Segmentation.UpdateData := False;
    Exit;
  end;
  Segmentation.UpdateMap := Decoder.ReadBit <> 0;
  Segmentation.UpdateData := Decoder.ReadBit <> 0;
  if Segmentation.UpdateData then
  begin
    Segmentation.AbsoluteValues := Decoder.ReadBit <> 0;
    for Feature := 0 to 1 do
      for Segment := 0 to 3 do
      begin
        Value := 0;
        if Decoder.ReadBit <> 0 then
          Value := ReadSignedValue(Decoder, FeatureBits[Feature]);
        if Feature = 0 then
          Segmentation.Quantizer[Segment] := Value
        else
          Segmentation.FilterLevel[Segment] := Value;
      end;
  end;
  if Segmentation.UpdateMap then
    for Index := 0 to 2 do
    begin
      Segmentation.TreeProbabilities[Index] := 255;
      if Decoder.ReadBit <> 0 then
        Segmentation.TreeProbabilities[Index] := Decoder.ReadLiteral(8);
    end;
end;

procedure ReadFilterDeltas(var Decoder: TBoolDecoder; var Header: TVp8FrameHeader;
  var State: TVp8StreamState);
var
  Index: LongInt;
begin
  Header.ModeReferenceDeltas := Decoder.ReadBit <> 0;
  if not Header.ModeReferenceDeltas then
    Exit;
  if Decoder.ReadBit = 0 then
    Exit;
  for Index := 0 to 3 do
    if Decoder.ReadBit <> 0 then
      State.ReferenceDeltas[Index] := ReadSignedValue(Decoder, 6);
  for Index := 0 to 3 do
    if Decoder.ReadBit <> 0 then
      State.ModeDeltas[Index] := ReadSignedValue(Decoder, 6);
end;

procedure StartPartitions(Data, DataEnd: PByte; Count: LongInt; out Partitions: TVp8Partitions);
var
  Index: LongInt;
  Sizes, Start: PByte;
  PartitionSize: PtrInt;
begin
  Sizes := Data;
  Start := Data + 3 * (Count - 1);
  if Start > DataEnd then
    raise EVp8Error.Create('VP8: truncated partition sizes');
  for Index := 0 to Count - 1 do
  begin
    if Index < Count - 1 then
      PartitionSize := Sizes[Index * 3] or (Sizes[Index * 3 + 1] shl 8) or (Sizes[Index * 3 + 2] shl 16)
    else
      PartitionSize := DataEnd - Start;
    if (PartitionSize <= 0) or (PartitionSize > DataEnd - Start) then
      raise EVp8Error.Create('VP8: truncated or corrupt partition');
    Partitions[Index].Init(Start, PartitionSize);
    Inc(Start, PartitionSize);
  end;
end;

procedure ReadModeProbabilities(var Decoder: TBoolDecoder; var Header: TVp8FrameHeader;
  var State: TVp8StreamState);
var
  Index, Component, Value: LongInt;
begin
  Header.SkipEnabled := Decoder.ReadBit <> 0;
  Header.SkipFalseProbability := 0;
  if Header.SkipEnabled then
    Header.SkipFalseProbability := Decoder.ReadLiteral(8);
  if Header.KeyFrame then
    Exit;
  Header.IntraProbability := Decoder.ReadLiteral(8);
  Header.LastProbability := Decoder.ReadLiteral(8);
  Header.GoldenProbability := Decoder.ReadLiteral(8);
  if Decoder.ReadBit <> 0 then
    for Index := 0 to 3 do
      State.Entropy.YModes[Index] := Decoder.ReadLiteral(8);
  if Decoder.ReadBit <> 0 then
    for Index := 0 to 2 do
      State.Entropy.UvModes[Index] := Decoder.ReadLiteral(8);
  for Component := 0 to 1 do
    for Index := 0 to MvProbabilityCount - 1 do
      if Decoder.ReadBool(MvUpdateProbabilities[Component, Index]) <> 0 then
      begin
        Value := Decoder.ReadLiteral(7);
        if Value <> 0 then
          State.Entropy.MotionVectors[Component, Index] := Value shl 1
        else
          State.Entropy.MotionVectors[Component, Index] := 1;
      end;
end;

procedure ReadFrameHeader(Data: PByte; Size: PtrInt; var Header: TVp8FrameHeader;
  var State: TVp8StreamState; out Saved: TVp8EntropyState;
  out FirstPartition: TBoolDecoder; out Partitions: TVp8Partitions);
var
  FirstPartitionSize: PtrInt;
  Start, DataEnd: PByte;
  I, J, K, L: LongInt;
begin
  FirstPartitionSize := (Data[0] or (Data[1] shl 8) or (Data[2] shl 16)) shr 5;
  DataEnd := Data + Size;
  Start := Data + 3;
  if Header.KeyFrame then
    Inc(Start, 7);
  if (FirstPartitionSize = 0) or (DataEnd - Start < FirstPartitionSize) then
    raise EVp8Error.Create('VP8: truncated packet or corrupt first partition');
  if Header.KeyFrame then
    ResetStreamState(State);
  FirstPartition.Init(Start, DataEnd - Start);
  if Header.KeyFrame then
  begin
    FirstPartition.ReadBit;  { colour space }
    FirstPartition.ReadBit;  { clamping type: the reference decoder clamps anyway }
  end;
  ReadSegmentation(FirstPartition, State.Segmentation);
  Header.SimpleFilter := FirstPartition.ReadBit <> 0;
  Header.FilterLevel := FirstPartition.ReadLiteral(6);
  Header.Sharpness := FirstPartition.ReadLiteral(3);
  ReadFilterDeltas(FirstPartition, Header, State);
  Header.PartitionCount := 1 shl FirstPartition.ReadLiteral(2);
  StartPartitions(Start + FirstPartitionSize, DataEnd, Header.PartitionCount, Partitions);
  Header.BaseQuantizer := FirstPartition.ReadLiteral(7);
  Header.Y1DcDelta := ReadQuantizerDelta(FirstPartition);
  Header.Y2DcDelta := ReadQuantizerDelta(FirstPartition);
  Header.Y2AcDelta := ReadQuantizerDelta(FirstPartition);
  Header.UvDcDelta := ReadQuantizerDelta(FirstPartition);
  Header.UvAcDelta := ReadQuantizerDelta(FirstPartition);
  if Header.KeyFrame then
  begin
    Header.RefreshGolden := True;
    Header.RefreshAltRef := True;
    Header.CopyToGolden := 0;
    Header.CopyToAltRef := 0;
  end
  else
  begin
    Header.RefreshGolden := FirstPartition.ReadBit <> 0;
    Header.RefreshAltRef := FirstPartition.ReadBit <> 0;
    Header.CopyToGolden := 0;
    if not Header.RefreshGolden then
      Header.CopyToGolden := FirstPartition.ReadLiteral(2);
    Header.CopyToAltRef := 0;
    if not Header.RefreshAltRef then
      Header.CopyToAltRef := FirstPartition.ReadLiteral(2);
    State.SignBias[ReferenceGolden] := FirstPartition.ReadBit <> 0;
    State.SignBias[ReferenceAltRef] := FirstPartition.ReadBit <> 0;
  end;
  Header.RefreshEntropy := FirstPartition.ReadBit <> 0;
  Saved := State.Entropy;
  Header.RefreshLast := Header.KeyFrame or (FirstPartition.ReadBit <> 0);
  for I := 0 to 3 do
    for J := 0 to 7 do
      for K := 0 to 2 do
        for L := 0 to 10 do
          if FirstPartition.ReadBool(CoefficientUpdateProbabilities[I, J, K, L]) <> 0 then
            State.Entropy.Coefficients[I, J, K, L] := FirstPartition.ReadLiteral(8);
  ReadModeProbabilities(FirstPartition, Header, State);
end;

end.
