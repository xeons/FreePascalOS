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
  The header of a VP8 key frame (RFC 6386 sections 9 and 19.2): the
  frame tag (key frame, version, shown, the first partition's size),
  the start code and size, then, in the first partition: colour space
  and clamping, segments (quantisers and filter levels per segment, the
  probabilities of the segment map), the loop filter (simple or normal,
  level, sharpness, deltas), the token partitions, the quantisers, and
  the coefficient probability updates and the skip probability.

  Only key frames exist in WebP; anything else is unsupported, as is a
  frame not meant to be shown.
}
unit Image.WebP.LossyHeader;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Model,
  Image.WebP.BoolDecoder,
  Image.WebP.LossyTables;

const
  LossyFrameHeaderLength = 10;
  SegmentCount = 4;
  MaximumPartitions = 8;

type
  TQuantMatrix = record
    { DC and AC steps of luma, the second order luma (Y2) and chroma. }
    Y1: TQuantSteps;
    Y2: TQuantSteps;
    UV: TQuantSteps;
  end;

  TSegmentHeader = record
    UseSegment: Boolean;
    UpdateMap: Boolean;
    AbsoluteDelta: Boolean;
    Quantizer: array[0..SegmentCount - 1] of LongInt;
    FilterStrength: array[0..SegmentCount - 1] of LongInt;
  end;

  TFilterHeader = record
    Simple: Boolean;
    Level: LongInt;
    Sharpness: LongInt;
    UseDeltas: Boolean;
    ReferenceDeltas: array[0..3] of LongInt;
    ModeDeltas: array[0..3] of LongInt;
  end;

  TLossyFrameHeader = record
    Width: LongInt;
    Height: LongInt;
    MacroblockColumns: LongInt;
    MacroblockRows: LongInt;
    Segments: TSegmentHeader;
    SegmentProbabilities: array[0..2] of LongInt;
    Filter: TFilterHeader;
    { 0 none, 1 simple, 2 normal. }
    FilterType: LongInt;
    Quant: array[0..SegmentCount - 1] of TQuantMatrix;
    Probabilities: array[0..CoefficientTableSize - 1] of Byte;
    UseSkipProbability: Boolean;
    SkipProbability: LongInt;
    PartitionCount: LongInt;
    PartitionStart: array[0..MaximumPartitions - 1] of PtrInt;
    PartitionSize: array[0..MaximumPartitions - 1] of PtrInt;
  end;

{ The picture size of the VP8 frame of Size bytes at Data; False when
  it is not a key frame VP8 knows. }
function ReadLossySize(Data: PByte; Size: PtrInt; out Width, Height: LongInt): Boolean;

{ Reads the frame header of the Size bytes at Data; the result reads
  on in the first partition (the modes), the token partitions are at
  the offsets in Header. }
function ReadLossyFrameHeader(Data: PByte; Size: PtrInt; out Header: TLossyFrameHeader): TBoolDecoder;

implementation

function ReadLossySize(Data: PByte; Size: PtrInt; out Width, Height: LongInt): Boolean;
var
  Bits: LongWord;
begin
  Width := 0;
  Height := 0;
  if Size < LossyFrameHeaderLength then
    Exit(False);
  Bits := Data[0] or (LongWord(Data[1]) shl 8) or (LongWord(Data[2]) shl 16);
  if (Data[3] <> $9D) or (Data[4] <> $01) or (Data[5] <> $2A) then
    Exit(False);
  if ((Bits and 1) <> 0) or (((Bits shr 1) and 7) > 3) or (((Bits shr 4) and 1) = 0) then
    Exit(False);
  Width := (Data[6] or (LongInt(Data[7]) shl 8)) and $3FFF;
  Height := (Data[8] or (LongInt(Data[9]) shl 8)) and $3FFF;
  Result := (Width > 0) and (Height > 0);
end;

procedure ReadSegmentHeader(Reader: TBoolDecoder; var Header: TLossyFrameHeader);
var
  Index: LongInt;
begin
  Header.Segments.UseSegment := Reader.ReadBit($80) <> 0;
  Header.Segments.AbsoluteDelta := True;
  for Index := 0 to 2 do
    Header.SegmentProbabilities[Index] := 255;
  if not Header.Segments.UseSegment then
    Exit;
  Header.Segments.UpdateMap := Reader.ReadBit($80) <> 0;
  if Reader.ReadBit($80) <> 0 then
  begin
    Header.Segments.AbsoluteDelta := Reader.ReadBit($80) <> 0;
    for Index := 0 to SegmentCount - 1 do
      if Reader.ReadBit($80) <> 0 then
        Header.Segments.Quantizer[Index] := Reader.ReadSignedValue(7)
      else
        Header.Segments.Quantizer[Index] := 0;
    for Index := 0 to SegmentCount - 1 do
      if Reader.ReadBit($80) <> 0 then
        Header.Segments.FilterStrength[Index] := Reader.ReadSignedValue(6)
      else
        Header.Segments.FilterStrength[Index] := 0;
  end;
  if Header.Segments.UpdateMap then
    for Index := 0 to 2 do
      if Reader.ReadBit($80) <> 0 then
        Header.SegmentProbabilities[Index] := Reader.ReadValue(8)
      else
        Header.SegmentProbabilities[Index] := 255;
end;

procedure ReadFilterHeader(Reader: TBoolDecoder; var Header: TLossyFrameHeader);
var
  Index: LongInt;
begin
  Header.Filter.Simple := Reader.ReadBit($80) <> 0;
  Header.Filter.Level := Reader.ReadValue(6);
  Header.Filter.Sharpness := Reader.ReadValue(3);
  Header.Filter.UseDeltas := Reader.ReadBit($80) <> 0;
  if Header.Filter.UseDeltas and (Reader.ReadBit($80) <> 0) then
  begin
    for Index := 0 to 3 do
      if Reader.ReadBit($80) <> 0 then
        Header.Filter.ReferenceDeltas[Index] := Reader.ReadSignedValue(6);
    for Index := 0 to 3 do
      if Reader.ReadBit($80) <> 0 then
        Header.Filter.ModeDeltas[Index] := Reader.ReadSignedValue(6);
  end;
  if Header.Filter.Level = 0 then
    Header.FilterType := 0
  else if Header.Filter.Simple then
    Header.FilterType := 1
  else
    Header.FilterType := 2;
end;

procedure ReadPartitions(Reader: TBoolDecoder; Data: PByte; Start, Size: PtrInt; var Header: TLossyFrameHeader);
var
  LastPartition: LongInt;
  SizesStart: PtrInt;
  PartitionStart: PtrInt;
  SizeLeft: PtrInt;
  PartitionSize: PtrInt;
  Index: LongInt;
begin
  Header.PartitionCount := 1 shl Reader.ReadValue(2);
  LastPartition := Header.PartitionCount - 1;
  if Size - Start < 3 * LastPartition then
    RaiseImageError(ImageErrorTruncated, 'VP8 partitions');
  SizesStart := Start;
  PartitionStart := Start + 3 * LastPartition;
  SizeLeft := Size - PartitionStart;
  for Index := 0 to LastPartition - 1 do
  begin
    PartitionSize := Data[SizesStart] or (PtrInt(Data[SizesStart + 1]) shl 8) or
      (PtrInt(Data[SizesStart + 2]) shl 16);
    if PartitionSize > SizeLeft then
      PartitionSize := SizeLeft;
    Header.PartitionStart[Index] := PartitionStart;
    Header.PartitionSize[Index] := PartitionSize;
    Inc(PartitionStart, PartitionSize);
    Dec(SizeLeft, PartitionSize);
    Inc(SizesStart, 3);
  end;
  Header.PartitionStart[LastPartition] := PartitionStart;
  Header.PartitionSize[LastPartition] := SizeLeft;
  if SizeLeft <= 0 then
    RaiseImageError(ImageErrorTruncated, 'VP8 partitions');
end;

function ClipQuantizer(Value, Limit: LongInt): LongInt;
begin
  if Value < 0 then
    Result := 0
  else if Value > Limit then
    Result := Limit
  else
    Result := Value;
end;

procedure ReadQuantizers(Reader: TBoolDecoder; var Header: TLossyFrameHeader);
var
  BaseQuantizer: LongInt;
  DeltaY1Dc: LongInt;
  DeltaY2Dc: LongInt;
  DeltaY2Ac: LongInt;
  DeltaUvDc: LongInt;
  DeltaUvAc: LongInt;
  Segment: LongInt;
  Q: LongInt;

  function ReadDelta: LongInt;
  begin
    if Reader.ReadBit($80) <> 0 then
      Result := Reader.ReadSignedValue(4)
    else
      Result := 0;
  end;

begin
  BaseQuantizer := Reader.ReadValue(7);
  DeltaY1Dc := ReadDelta;
  DeltaY2Dc := ReadDelta;
  DeltaY2Ac := ReadDelta;
  DeltaUvDc := ReadDelta;
  DeltaUvAc := ReadDelta;
  for Segment := 0 to SegmentCount - 1 do
  begin
    if Header.Segments.UseSegment then
    begin
      Q := Header.Segments.Quantizer[Segment];
      if not Header.Segments.AbsoluteDelta then
        Inc(Q, BaseQuantizer);
    end
    else if Segment > 0 then
    begin
      Header.Quant[Segment] := Header.Quant[0];
      Continue;
    end
    else
      Q := BaseQuantizer;
    with Header.Quant[Segment] do
    begin
      Y1[0] := DcQuantiserSteps[ClipQuantizer(Q + DeltaY1Dc, 127)];
      Y1[1] := AcQuantiserSteps[ClipQuantizer(Q, 127)];
      Y2[0] := DcQuantiserSteps[ClipQuantizer(Q + DeltaY2Dc, 127)] * 2;
      Y2[1] := (LongInt(AcQuantiserSteps[ClipQuantizer(Q + DeltaY2Ac, 127)]) * 101581) shr 16;
      if Y2[1] < 8 then
        Y2[1] := 8;
      UV[0] := DcQuantiserSteps[ClipQuantizer(Q + DeltaUvDc, 117)];
      UV[1] := AcQuantiserSteps[ClipQuantizer(Q + DeltaUvAc, 127)];
    end;
  end;
end;

procedure ReadProbabilities(Reader: TBoolDecoder; var Header: TLossyFrameHeader);
var
  Index: LongInt;
begin
  for Index := 0 to CoefficientTableSize - 1 do
    if Reader.ReadBit(CoefficientUpdateProbabilities[Index]) <> 0 then
      Header.Probabilities[Index] := Reader.ReadValue(8)
    else
      Header.Probabilities[Index] := DefaultCoefficientProbabilities[Index];
  Header.UseSkipProbability := Reader.ReadBit($80) <> 0;
  if Header.UseSkipProbability then
    Header.SkipProbability := Reader.ReadValue(8);
end;

function ReadLossyFrameHeader(Data: PByte; Size: PtrInt; out Header: TLossyFrameHeader): TBoolDecoder;
var
  FirstPartitionSize: PtrInt;
  Reader: TBoolDecoder;
begin
  Header := Default(TLossyFrameHeader);
  if not ReadLossySize(Data, Size, Header.Width, Header.Height) then
  begin
    if (Size >= LossyFrameHeaderLength) and ((Data[0] and 1) <> 0) then
      RaiseImageError(ImageErrorUnsupported, 'VP8 frame that is not a key frame');
    RaiseImageError(ImageErrorMalformed, 'VP8 frame header');
  end;
  CheckImageSize(Header.Width, Header.Height);
  FirstPartitionSize := (Data[0] or (LongWord(Data[1]) shl 8) or (LongWord(Data[2]) shl 16)) shr 5;
  if FirstPartitionSize > Size - LossyFrameHeaderLength then
    RaiseImageError(ImageErrorTruncated, 'VP8 first partition');
  Header.MacroblockColumns := (Header.Width + 15) shr 4;
  Header.MacroblockRows := (Header.Height + 15) shr 4;
  Reader := TBoolDecoder.Create(Data + LossyFrameHeaderLength, FirstPartitionSize);
  try
    Reader.ReadBit($80);  { colour space }
    Reader.ReadBit($80);  { clamping type }
    ReadSegmentHeader(Reader, Header);
    ReadFilterHeader(Reader, Header);
    if Reader.EndOfData then
      RaiseImageError(ImageErrorTruncated, 'VP8 frame header');
    ReadPartitions(Reader, Data, LossyFrameHeaderLength + FirstPartitionSize, Size, Header);
    ReadQuantizers(Reader, Header);
    Reader.ReadBit($80);  { refresh entropy probabilities: a key frame's own }
    ReadProbabilities(Reader, Header);
  except
    Reader.Free;
    raise;
  end;
  Result := Reader;
end;

end.
