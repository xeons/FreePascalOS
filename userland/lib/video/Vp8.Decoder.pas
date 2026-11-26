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
  The VP8 decoder (RFC 6386): one compressed frame in, at most one
  picture out, bit exact with the reference decoder.

  A frame is decoded in three passes: the modes of every macroblock
  (first partition), the macroblocks' reconstruction row by row (each
  row's tokens in its partition; rows of different partitions on
  several threads, each kept a macroblock behind the row above), and the
  loop filter. Then the reference pictures (last, golden, alternate) are
  replaced or copied as the header says.
}
unit Vp8.Decoder;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils, Media.Frames, Video.BoolDecoder, Video.WorkerPool, Vp8.Tables,
  Vp8.FrameHeader, Vp8.Modes, Vp8.Residuals, Vp8.Pictures, Vp8.Reconstruction;

type
  TVp8Decoder = class
  private
    FState: TVp8StreamState;
    FGrid: TVp8ModeInfoGrid;
    FWidth, FHeight: LongInt;
    FReferences: array[1..3] of TVp8Picture;
    FPool: array of TVp8Picture;
    FHasKeyFrame: Boolean;
    FRecon: TVp8FrameReconstruction;
    FWorkers: TVideoWorkerPool;
    FThreadCount: LongInt;
    function TakeFreePicture: TVp8Picture;
    procedure Resize(Width, Height: LongInt);
    procedure ReconstructFrame(var Partitions: TVp8Partitions; PartitionCount: LongInt);
    procedure FilterFrame(constref Header: TVp8FrameHeader; Picture: TVp8Picture);
    procedure UpdateReferences(constref Header: TVp8FrameHeader; Picture: TVp8Picture);
  public
    { ThreadCount: threads reconstructing rows (0 for one per processor). }
    constructor Create(ThreadCount: LongInt = 0);
    destructor Destroy; override;
    { Decodes the frame of Size bytes at Data. Returns True with Frame
      set when the frame is to be shown; False for a frame that is not
      (an alternate reference) or an empty packet. Raises EVp8Error for
      a frame that cannot be decoded. }
    function DecodeFrame(Data: PByte; Size: PtrInt; out Frame: TVideoFrame): Boolean;
    property Width: LongInt read FWidth;
    property Height: LongInt read FHeight;
  end;

implementation

uses
  Vp8.LoopFilter;

constructor TVp8Decoder.Create(ThreadCount: LongInt);
begin
  inherited Create;
  FRecon := TVp8FrameReconstruction.Create;
  FThreadCount := ThreadCount;
  if FThreadCount <= 0 then
    FThreadCount := DefaultVideoThreadCount;
end;

destructor TVp8Decoder.Destroy;
var
  Index: LongInt;
begin
  FWorkers.Free;
  for Index := 0 to High(FPool) do
    FPool[Index].Free;
  FRecon.Free;
  inherited Destroy;
end;

function TVp8Decoder.TakeFreePicture: TVp8Picture;
var
  Index, Reference: LongInt;
  Used: Boolean;
begin
  for Index := 0 to High(FPool) do
  begin
    Used := False;
    for Reference := 1 to 3 do
      if FReferences[Reference] = FPool[Index] then
        Used := True;
    if not Used then
      Exit(FPool[Index]);
  end;
  Result := TVp8Picture.Create(FWidth, FHeight);
  SetLength(FPool, Length(FPool) + 1);
  FPool[High(FPool)] := Result;
end;

procedure TVp8Decoder.Resize(Width, Height: LongInt);
var
  Index: LongInt;
begin
  for Index := 0 to High(FPool) do
    FPool[Index].Free;
  FPool := nil;
  FillChar(FReferences, SizeOf(FReferences), 0);
  FWidth := Width;
  FHeight := Height;
  AllocateModeGrid(FGrid, (Width + 15) div 16, (Height + 15) div 16);
end;

type
  { Reconstructing the rows of one token partition. }
  TRowJob = record
    Recon: TVp8FrameReconstruction;
    Decoders: ^TVp8Partitions;
    PartitionCount: LongInt;
    FirstRow: LongInt;
    RowStep: LongInt;
    Progress: TVideoProgress;
  end;
  PRowJob = ^TRowJob;

procedure RunRowJob(Argument: Pointer);
var
  Job: PRowJob;
  Row: LongInt;
begin
  Job := PRowJob(Argument);
  Row := Job^.FirstRow;
  try
    while Row < Job^.Recon.Grid^.Rows do
    begin
      Job^.Recon.ReconstructRow(Row, Job^.Decoders^[Row mod Job^.PartitionCount], Job^.Progress);
      Inc(Row, Job^.RowStep);
    end;
  except
    Job^.Progress.Abort;
    raise;
  end;
end;

procedure TVp8Decoder.ReconstructFrame(var Partitions: TVp8Partitions; PartitionCount: LongInt);
var
  Row, Index, JobCount: LongInt;
  Jobs: array[0..MaxTokenPartitions - 1] of TRowJob;
  Progress: TVideoProgress;
begin
  { Every job runs at the same time as the others (a row waits for the
    one above), so there are no more jobs than threads; and a
    partition's rows stay in one job, in order: the jobs are a power of
    two, which divides the partitions. }
  JobCount := 1;
  while (JobCount * 2 <= PartitionCount) and (JobCount * 2 <= FThreadCount) and
    (JobCount * 2 <= FGrid.Rows) do
    JobCount := JobCount * 2;
  if JobCount <= 1 then
  begin
    for Row := 0 to FGrid.Rows - 1 do
      FRecon.ReconstructRow(Row, Partitions[Row mod PartitionCount], nil);
    Exit;
  end;
  if FWorkers = nil then
    FWorkers := TVideoWorkerPool.Create(FThreadCount);
  Progress := TVideoProgress.Create(FGrid.Rows);
  try
    for Index := 0 to JobCount - 1 do
    begin
      Jobs[Index].Recon := FRecon;
      Jobs[Index].Decoders := @Partitions;
      Jobs[Index].PartitionCount := PartitionCount;
      Jobs[Index].FirstRow := Index;
      Jobs[Index].RowStep := JobCount;
      Jobs[Index].Progress := Progress;
      FWorkers.Add(@RunRowJob, @Jobs[Index]);
    end;
    FWorkers.WaitAll;
  finally
    Progress.Free;
  end;
end;

procedure TVp8Decoder.FilterFrame(constref Header: TVp8FrameHeader; Picture: TVp8Picture);
var
  Levels: array[0..3, 0..3, 0..3] of LongInt;
  Limits: array[0..63] of TVp8FilterLimits;
  Segment, Reference, Mode, SegmentLevel, ReferenceLevel, Level: LongInt;
  Row, Column, ModeIndex: LongInt;
  Info: PVp8MacroblockInfo;
  Inner: Boolean;
  Y, U, V: PByte;
  YStride, UvStride: LongInt;

  function Clamp63(Value: LongInt): LongInt;
  begin
    if Value < 0 then
      Result := 0
    else if Value > 63 then
      Result := 63
    else
      Result := Value;
  end;

begin
  if Header.FilterLevel = 0 then
    Exit;
  for Segment := 0 to 3 do
  begin
    SegmentLevel := Header.FilterLevel;
    if FState.Segmentation.Enabled then
    begin
      if FState.Segmentation.AbsoluteValues then
        SegmentLevel := FState.Segmentation.FilterLevel[Segment]
      else
        SegmentLevel := SegmentLevel + FState.Segmentation.FilterLevel[Segment];
      SegmentLevel := Clamp63(SegmentLevel);
    end;
    if not Header.ModeReferenceDeltas then
    begin
      for Reference := 0 to 3 do
        for Mode := 0 to 3 do
          Levels[Segment, Reference, Mode] := SegmentLevel;
      Continue;
    end;
    ReferenceLevel := SegmentLevel + FState.ReferenceDeltas[ReferenceIntra];
    Levels[Segment, ReferenceIntra, 0] := Clamp63(ReferenceLevel + FState.ModeDeltas[0]);
    Levels[Segment, ReferenceIntra, 1] := Clamp63(ReferenceLevel);
    for Reference := 1 to 3 do
    begin
      ReferenceLevel := SegmentLevel + FState.ReferenceDeltas[Reference];
      for Mode := 1 to 3 do
        Levels[Segment, Reference, Mode] := Clamp63(ReferenceLevel + FState.ModeDeltas[Mode]);
    end;
  end;
  for Level := 1 to 63 do
    Limits[Level] := ComputeFilterLimits(Level, Header.Sharpness, Header.KeyFrame);
  YStride := Picture.Planes[0].Stride;
  UvStride := Picture.Planes[1].Stride;
  for Row := 0 to FGrid.Rows - 1 do
    for Column := 0 to FGrid.Columns - 1 do
    begin
      Info := MacroblockAt(FGrid, Row, Column);
      case Info^.YMode of
        ModeBlocks: ModeIndex := 0;
        ModeNearest, ModeNear, ModeNew: ModeIndex := 2;
        ModeSplit: ModeIndex := 3;
      else
        ModeIndex := 1;
      end;
      Level := Levels[Info^.Segment, Info^.Reference, ModeIndex];
      if Level = 0 then
        Continue;
      Inner := (Info^.YMode = ModeBlocks) or (Info^.YMode = ModeSplit) or not Info^.Skip;
      Y := Picture.Planes[0].Origin + Row * 16 * YStride + Column * 16;
      if Header.SimpleFilter then
        FilterMacroblockSimple(Y, YStride, Limits[Level], Column > 0, Row > 0, Inner)
      else
      begin
        U := Picture.Planes[1].Origin + Row * 8 * UvStride + Column * 8;
        V := Picture.Planes[2].Origin + Row * 8 * UvStride + Column * 8;
        FilterMacroblockNormal(Y, U, V, YStride, UvStride, Limits[Level], Column > 0, Row > 0, Inner);
      end;
    end;
end;

procedure TVp8Decoder.UpdateReferences(constref Header: TVp8FrameHeader; Picture: TVp8Picture);
begin
  case Header.CopyToAltRef of
    1: FReferences[ReferenceAltRef] := FReferences[ReferenceLast];
    2: FReferences[ReferenceAltRef] := FReferences[ReferenceGolden];
  end;
  case Header.CopyToGolden of
    1: FReferences[ReferenceGolden] := FReferences[ReferenceLast];
    2: FReferences[ReferenceGolden] := FReferences[ReferenceAltRef];
  end;
  if Header.RefreshGolden then
    FReferences[ReferenceGolden] := Picture;
  if Header.RefreshAltRef then
    FReferences[ReferenceAltRef] := Picture;
  if Header.RefreshLast then
    FReferences[ReferenceLast] := Picture;
end;

function TVp8Decoder.DecodeFrame(Data: PByte; Size: PtrInt; out Frame: TVideoFrame): Boolean;
var
  Header: TVp8FrameHeader;
  Saved: TVp8EntropyState;
  FirstPartition: TBoolDecoder;
  Partitions: TVp8Partitions;
  Picture: TVp8Picture;
  Segment, Index, Reference: LongInt;
begin
  Result := False;
  Frame := Default(TVideoFrame);
  if Size = 0 then
    Exit;
  ReadFrameTag(Data, Size, Header);
  if Header.KeyFrame then
  begin
    if (Header.Width = 0) or (Header.Height = 0) then
      raise EVp8Error.Create('VP8: invalid frame size');
    if (Header.Width <> FWidth) or (Header.Height <> FHeight) then
      Resize(Header.Width, Header.Height);
  end
  else if not FHasKeyFrame then
    raise EVp8Error.Create('VP8: a stream must start with a key frame');
  ReadFrameHeader(Data, Size, Header, FState, Saved, FirstPartition, Partitions);
  ReadFrameModes(FirstPartition, Header, FState, FGrid);
  for Reference := 1 to 3 do
    if (not Header.KeyFrame) and (FReferences[Reference] = nil) then
      raise EVp8Error.Create('VP8: missing reference picture');
  Picture := TakeFreePicture;
  Picture.PrepareTopBorder;
  FRecon.Header := Header;
  FRecon.Target := Picture;
  for Reference := 1 to 3 do
    FRecon.References[Reference] := FReferences[Reference];
  FRecon.Grid := @FGrid;
  FRecon.Probabilities := @FState.Entropy.Coefficients;
  FRecon.SegmentationEnabled := FState.Segmentation.Enabled;
  for Segment := 0 to 3 do
  begin
    Index := Header.BaseQuantizer;
    if FState.Segmentation.Enabled then
    begin
      if FState.Segmentation.AbsoluteValues then
        Index := FState.Segmentation.Quantizer[Segment]
      else
        Index := Index + FState.Segmentation.Quantizer[Segment];
    end;
    if Index < 0 then
      Index := 0
    else if Index > 127 then
      Index := 127;
    FRecon.Dequantizers[Segment] := ComputeDequantizer(Header, Index);
  end;
  SetLength(FRecon.AboveContexts, FGrid.Columns);
  if FGrid.Columns > 0 then
    FillChar(FRecon.AboveContexts[0], FGrid.Columns * SizeOf(TEntropyContexts), 0);
  ReconstructFrame(Partitions, Header.PartitionCount);
  FilterFrame(Header, Picture);
  Picture.ExtendBorders;
  if not Header.RefreshEntropy then
    FState.Entropy := Saved;
  if Header.KeyFrame then
    FHasKeyFrame := True;
  UpdateReferences(Header, Picture);
  if Header.ShowFrame then
  begin
    Picture.CopyTo(Frame);
    Result := True;
  end;
end;

end.
