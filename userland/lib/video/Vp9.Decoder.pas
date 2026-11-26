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
  The VP9 decoder (profiles 0 to 3: 4:2:0, 4:2:2, 4:4:0 and 4:4:4 at 8,
  10 and 12 bits), bit exact with the reference decoder (libvpx).

  A packet holds one frame or a superframe (several frames and an index
  at its end). Each frame: its headers, its tiles (the tile columns of a
  tile row on several threads), the loop filter (superblock rows on
  several threads, each two superblocks behind the one above), the
  backward adaptation of the probabilities, then the 8 reference slots
  it refreshes. Like the reference decoder, a packet shows at most one
  picture: its last frame's, when that frame is shown.
}
unit Vp9.Decoder;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils, Media.Frames, Video.BoolDecoder, Video.WorkerPool, Vp9.ModeInfo, Vp9.Pictures,
  Vp9.Probabilities, Vp9.FrameState, Vp9.FrameHeader, Vp9.LoopFilter, Vp9.TileState;

type
  TVp9Decoder = class
  private
    FHeaderState: TVp9StreamHeaderState;
    FFrameContexts: array[0..3] of TVp9FrameContext;
    FProbabilities: TVp9FrameContext;
    FReferenceSlots: array[0..7] of TVp9Picture;
    FPool: array of TVp9Picture;
    FGrid: TVp9ModeInfoGrid;
    FSegmentMaps: array[0..1] of array of Byte;
    FCurrentSegmentMap: LongInt;
    FWidth, FHeight: LongInt;
    FAbove: TVp9AboveContexts;
    FTiles: array of TVp9TileState;
    FWorkers: TVideoWorkerPool;
    FThreadCount: LongInt;
    FHasDecoded: Boolean;
    { The previous frame, for motion vector prediction. }
    FPreviousPicture: TVp9Picture;
    FLastWidth, FLastHeight: LongInt;
    FLastShowFrame: Boolean;
    FLastKeyFrame: Boolean;
    FLastIntraOnly: Boolean;
    FIntraOnlyFlag: Boolean;
    FOutput: TVideoFrame;
    FHasOutput: Boolean;
    function TakeFreePicture: TVp9Picture;
    procedure ResizeContexts(Width, Height: LongInt);
    procedure ResetProbabilities(constref Header: TVp9FrameHeader);
    procedure SetupFrameState(constref Header: TVp9FrameHeader; Picture: TVp9Picture; out Frame: TVp9FrameState);
    function DecodeTiles(Data, DataEnd: PByte; constref Header: TVp9FrameHeader; var Frame: TVp9FrameState;
      var Counts: TVp9Counts): PByte;
    procedure FilterFrame(constref Header: TVp9FrameHeader; constref Frame: TVp9FrameState);
    procedure UpdateReferences(RefreshFlags: LongInt; Picture: TVp9Picture);
    function DecodeFrame(Data: PByte; Size: PtrInt): PtrInt;
    function Workers: TVideoWorkerPool;
  public
    { ThreadCount: threads for tiles and the loop filter (0 for one per
      processor). }
    constructor Create(ThreadCount: LongInt = 0);
    destructor Destroy; override;
    { Decodes a packet; raises EVp9Error (or another exception) for one
      that cannot be decoded. }
    procedure DecodePacket(Data: PByte; Size: PtrInt);
    { The picture the last packet shows, once. }
    function ReceiveFrame(out Frame: TVideoFrame): Boolean;
  end;

implementation

uses
  Vp9.Tables, Vp9.QuantizerTables, Vp9.InterPrediction, Vp9.TileDecoder;

constructor TVp9Decoder.Create(ThreadCount: LongInt);
begin
  inherited Create;
  FThreadCount := ThreadCount;
  if FThreadCount <= 0 then
    FThreadCount := DefaultVideoThreadCount;
  FGrid := TVp9ModeInfoGrid.Create;
end;

destructor TVp9Decoder.Destroy;
var
  Index: LongInt;
begin
  FWorkers.Free;
  for Index := 0 to High(FTiles) do
    FTiles[Index].Free;
  for Index := 0 to High(FPool) do
    FPool[Index].Free;
  FGrid.Free;
  inherited Destroy;
end;

function TVp9Decoder.Workers: TVideoWorkerPool;
begin
  if FWorkers = nil then
    FWorkers := TVideoWorkerPool.Create(FThreadCount);
  Result := FWorkers;
end;

function TVp9Decoder.TakeFreePicture: TVp9Picture;
var
  Index: LongInt;
begin
  for Index := 0 to High(FPool) do
    if FPool[Index].ReferenceCount = 0 then
      Exit(FPool[Index]);
  Result := TVp9Picture.Create;
  SetLength(FPool, Length(FPool) + 1);
  FPool[High(FPool)] := Result;
end;

procedure TVp9Decoder.ResizeContexts(Width, Height: LongInt);
var
  MiRows, MiColumns, AlignedColumns, Index: LongInt;
begin
  MiRows := (Height + 7) shr 3;
  MiColumns := (Width + 7) shr 3;
  if (Width = FWidth) and (Height = FHeight) then
    Exit;
  FWidth := Width;
  FHeight := Height;
  FGrid.Resize(MiRows, MiColumns);
  if Length(FSegmentMaps[0]) < MiRows * MiColumns then
  begin
    for Index := 0 to 1 do
    begin
      FSegmentMaps[Index] := nil;
      SetLength(FSegmentMaps[Index], MiRows * MiColumns);
    end;
  end
  else
    FillChar(FSegmentMaps[1 - FCurrentSegmentMap][0], MiRows * MiColumns, 0);
  AlignedColumns := (MiColumns + 7) and not 7;
  for Index := 0 to 2 do
  begin
    FAbove.Coefficients[Index] := nil;
    SetLength(FAbove.Coefficients[Index], AlignedColumns * 2 + 16);
  end;
  FAbove.Partitions := nil;
  SetLength(FAbove.Partitions, AlignedColumns + 8);
end;

procedure TVp9Decoder.ResetProbabilities(constref Header: TVp9FrameHeader);
var
  Index: LongInt;
begin
  SetDefaultProbabilities(FProbabilities);
  if Header.KeyFrame or Header.ErrorResilient or (Header.ResetFrameContext = 3) then
    for Index := 0 to 3 do
      FFrameContexts[Index] := FProbabilities
  else if Header.ResetFrameContext = 2 then
    FFrameContexts[Header.FrameContextIndex] := FProbabilities;
end;

function QuantizerIndex(constref Segmentation: TVp9Segmentation; Segment, Base: LongInt): LongInt;
var
  Data: LongInt;
begin
  if SegmentFeatureActive(Segmentation, Segment, SegmentFeatureQuantizer) then
  begin
    Data := Segmentation.FeatureData[Segment, SegmentFeatureQuantizer];
    if Segmentation.AbsoluteValues then
      Result := Data
    else
      Result := Base + Data;
    if Result < 0 then
      Result := 0
    else if Result > 255 then
      Result := 255;
  end
  else
    Result := Base;
end;

function Step(Index, Delta, BitDepth: LongInt; Dc: Boolean): LongInt;
begin
  Index := Index + Delta;
  if Index < 0 then
    Index := 0
  else if Index > 255 then
    Index := 255;
  case BitDepth of
    10: if Dc then Result := DcQuantizer10[Index] else Result := AcQuantizer10[Index];
    12: if Dc then Result := DcQuantizer12[Index] else Result := AcQuantizer12[Index];
  else
    if Dc then Result := DcQuantizer8[Index] else Result := AcQuantizer8[Index];
  end;
end;

procedure TVp9Decoder.SetupFrameState(constref Header: TVp9FrameHeader; Picture: TVp9Picture;
  out Frame: TVp9FrameState);
var
  Segment, Index, BaseIndex: LongInt;
  Reference: TVp9Picture;
  AnyValid: Boolean;
begin
  Frame := Default(TVp9FrameState);
  Frame.IntraOnly := Header.KeyFrame or Header.IntraOnly;
  Frame.Width := Header.Width;
  Frame.Height := Header.Height;
  Frame.MiRows := (Header.Height + 7) shr 3;
  Frame.MiColumns := (Header.Width + 7) shr 3;
  Frame.SubsamplingX := FHeaderState.SubsamplingX;
  Frame.SubsamplingY := FHeaderState.SubsamplingY;
  Frame.BitDepth := FHeaderState.BitDepth;
  Frame.Lossless := Header.Lossless;
  Frame.TransformMode := Header.TransformMode;
  Frame.Filter := Header.Filter;
  Frame.ReferenceMode := Header.ReferenceMode;
  Frame.FixedReference := Header.FixedReference;
  Frame.VariableReferences := Header.VariableReferences;
  Frame.SignBias := Header.SignBias;
  Frame.AllowHighPrecisionMv := Header.AllowHighPrecisionMv;
  Frame.Segmentation := FHeaderState.Segmentation;
  for Segment := 0 to 7 do
  begin
    if FHeaderState.Segmentation.Enabled then
      BaseIndex := QuantizerIndex(FHeaderState.Segmentation, Segment, Header.BaseQuantizer)
    else
      BaseIndex := Header.BaseQuantizer;
    Frame.Dequantizers[Segment].LumaDc := Step(BaseIndex, Header.LumaDcDelta, Frame.BitDepth, True);
    Frame.Dequantizers[Segment].LumaAc := Step(BaseIndex, 0, Frame.BitDepth, False);
    Frame.Dequantizers[Segment].ChromaDc := Step(BaseIndex, Header.ChromaDcDelta, Frame.BitDepth, True);
    Frame.Dequantizers[Segment].ChromaAc := Step(BaseIndex, Header.ChromaAcDelta, Frame.BitDepth, False);
  end;
  Frame.Probabilities := @FProbabilities;
  Frame.Counting := not Header.ErrorResilient and not Header.FrameParallel;
  Frame.UsePreviousMvs := (not Header.ErrorResilient) and (Header.Width = FLastWidth) and
    (Header.Height = FLastHeight) and (not FLastIntraOnly) and FLastShowFrame and (not FLastKeyFrame) and
    (FPreviousPicture <> nil);
  if Frame.UsePreviousMvs then
    Frame.PreviousMvs := @FPreviousPicture.MvReferences[0];
  Frame.CurrentSegmentMap := @FSegmentMaps[FCurrentSegmentMap][0];
  Frame.LastSegmentMap := @FSegmentMaps[1 - FCurrentSegmentMap][0];
  Frame.Grid := FGrid;
  Frame.Picture := Picture;
  if not Frame.IntraOnly then
  begin
    AnyValid := False;
    for Index := 0 to 2 do
    begin
      Reference := FReferenceSlots[Header.ReferenceIndices[Index]];
      Frame.References[1 + Index].Picture := Reference;
      SetupScaleFactors(Frame.References[1 + Index].Scale, Reference.Width, Reference.Height, Header.Width,
        Header.Height);
      if Frame.References[1 + Index].Scale.Valid then
        AnyValid := True;
      if (Reference.BitDepth <> Frame.BitDepth) or (Reference.SubsamplingX <> Frame.SubsamplingX) or
        (Reference.SubsamplingY <> Frame.SubsamplingY) then
        raise EVp9Error.Create('VP9: referenced frame has an incompatible colour format');
    end;
    if not AnyValid then
      raise EVp9Error.Create('VP9: referenced frame has an invalid size');
  end;
end;

type
  TTileJob = record
    Tile: TVp9TileState;
  end;
  PTileJob = ^TTileJob;

procedure RunTileJob(Argument: Pointer);
begin
  DecodeTile(PTileJob(Argument)^.Tile);
end;

function TileOffset(Index, MiCount, Log2: LongInt): LongInt;
var
  SuperblockCount: LongInt;
begin
  SuperblockCount := ((MiCount + 7) and not 7) shr 3;
  Result := ((Index * SuperblockCount) shr Log2) shl 3;
  if Result > MiCount then
    Result := MiCount;
end;

function TVp9Decoder.DecodeTiles(Data, DataEnd: PByte; constref Header: TVp9FrameHeader;
  var Frame: TVp9FrameState; var Counts: TVp9Counts): PByte;
var
  TileColumns, TileRows, Row, Column, Index: LongInt;
  TileSize: PtrInt;
  Tile: TVp9TileState;
  Jobs: array of TTileJob;
  Sizes: array of PtrInt;
  Starts: array of PByte;
begin
  TileColumns := 1 shl Header.TileColumnsLog2;
  TileRows := 1 shl Header.TileRowsLog2;
  for Index := 0 to 2 do
    FillChar(FAbove.Coefficients[Index][0], Length(FAbove.Coefficients[Index]), 0);
  FillChar(FAbove.Partitions[0], Length(FAbove.Partitions), 0);
  SetLength(Sizes, TileColumns * TileRows);
  SetLength(Starts, TileColumns * TileRows);
  for Row := 0 to TileRows - 1 do
    for Column := 0 to TileColumns - 1 do
    begin
      Index := Row * TileColumns + Column;
      if (Row = TileRows - 1) and (Column = TileColumns - 1) then
        TileSize := DataEnd - Data
      else
      begin
        if DataEnd - Data < 4 then
          raise EVp9Error.Create('VP9: truncated packet or corrupt tile length');
        TileSize := (PtrInt(Data[0]) shl 24) or (PtrInt(Data[1]) shl 16) or (PtrInt(Data[2]) shl 8) or Data[3];
        Inc(Data, 4);
        if TileSize > DataEnd - Data then
          raise EVp9Error.Create('VP9: truncated packet or corrupt tile size');
      end;
      if TileSize <= 0 then
        raise EVp9Error.Create('VP9: truncated packet or corrupt tile length');
      Starts[Index] := Data;
      Sizes[Index] := TileSize;
      Inc(Data, TileSize);
    end;
  while Length(FTiles) < TileColumns do
  begin
    SetLength(FTiles, Length(FTiles) + 1);
    FTiles[High(FTiles)] := TVp9TileState.Create;
  end;
  SetLength(Jobs, TileColumns);
  for Row := 0 to TileRows - 1 do
  begin
    for Column := 0 to TileColumns - 1 do
    begin
      Index := Row * TileColumns + Column;
      Tile := FTiles[Column];
      Tile.Frame := @Frame;
      Tile.Above := @FAbove;
      if Row = 0 then
        FillChar(Tile.Counts, SizeOf(Tile.Counts), 0);
      if Frame.Counting then
        Tile.CountsPointer := @Tile.Counts
      else
        Tile.CountsPointer := nil;
      Tile.TileRowStart := TileOffset(Row, Frame.MiRows, Header.TileRowsLog2);
      Tile.TileRowEnd := TileOffset(Row + 1, Frame.MiRows, Header.TileRowsLog2);
      Tile.TileColumnStart := TileOffset(Column, Frame.MiColumns, Header.TileColumnsLog2);
      Tile.TileColumnEnd := TileOffset(Column + 1, Frame.MiColumns, Header.TileColumnsLog2);
      Tile.Decoder.Init(Starts[Index], Sizes[Index]);
      if Tile.Decoder.ReadBit <> 0 then
        raise EVp9Error.Create('VP9: invalid tile marker bit');
      Jobs[Column].Tile := Tile;
    end;
    if (FThreadCount > 1) and (TileColumns > 1) then
    begin
      for Column := 0 to TileColumns - 1 do
        Workers.Add(@RunTileJob, @Jobs[Column]);
      Workers.WaitAll;
    end
    else
      for Column := 0 to TileColumns - 1 do
        DecodeTile(Jobs[Column].Tile);
  end;
  FillChar(Counts, SizeOf(Counts), 0);
  if Frame.Counting then
    for Column := 0 to TileColumns - 1 do
      AddCounts(Counts, FTiles[Column].Counts);
  Result := FTiles[TileColumns - 1].Decoder.FindEnd;
end;

type
  TFilterJob = record
    Frame: PVp9LoopFilterFrame;
    FirstRow, RowStep, Rows: LongInt;
    Progress: TVideoProgress;
  end;
  PFilterJob = ^TFilterJob;

procedure RunFilterJob(Argument: Pointer);
var
  Job: PFilterJob;
  Row: LongInt;
begin
  Job := PFilterJob(Argument);
  Row := Job^.FirstRow;
  try
    while Row < Job^.Rows do
    begin
      FilterSuperblockRow(Job^.Frame^, Row, Job^.Progress);
      Inc(Row, Job^.RowStep);
    end;
  except
    Job^.Progress.Abort;
    raise;
  end;
end;

procedure TVp9Decoder.FilterFrame(constref Header: TVp9FrameHeader; constref Frame: TVp9FrameState);
var
  Filter: TVp9LoopFilterFrame;
  Segments: TVp9SegmentFilterLevels;
  Segment, Rows, JobCount, Index: LongInt;
  Jobs: array of TFilterJob;
  Progress: TVideoProgress;
begin
  if FHeaderState.LoopFilter.FilterLevel = 0 then
    Exit;
  Filter.Picture := Frame.Picture;
  Filter.Grid := Frame.Grid;
  Filter.MiRows := Frame.MiRows;
  Filter.MiColumns := Frame.MiColumns;
  for Segment := 0 to 7 do
  begin
    Segments.Enabled[Segment] := SegmentFeatureActive(Frame.Segmentation, Segment, SegmentFeatureFilterLevel);
    Segments.Values[Segment] := Frame.Segmentation.FeatureData[Segment, SegmentFeatureFilterLevel];
  end;
  Segments.AbsoluteValues := Frame.Segmentation.AbsoluteValues;
  PrepareLoopFilter(Filter, FHeaderState.LoopFilter, Segments);
  Rows := (Frame.MiRows + 7) shr 3;
  JobCount := FThreadCount;
  if JobCount > Rows then
    JobCount := Rows;
  if JobCount <= 1 then
  begin
    for Index := 0 to Rows - 1 do
      FilterSuperblockRow(Filter, Index, nil);
    Exit;
  end;
  Progress := TVideoProgress.Create(Rows);
  try
    SetLength(Jobs, JobCount);
    for Index := 0 to JobCount - 1 do
    begin
      Jobs[Index].Frame := @Filter;
      Jobs[Index].FirstRow := Index;
      Jobs[Index].RowStep := JobCount;
      Jobs[Index].Rows := Rows;
      Jobs[Index].Progress := Progress;
      Workers.Add(@RunFilterJob, @Jobs[Index]);
    end;
    Workers.WaitAll;
  finally
    Progress.Free;
  end;
end;

procedure TVp9Decoder.UpdateReferences(RefreshFlags: LongInt; Picture: TVp9Picture);
var
  Index: LongInt;
begin
  for Index := 0 to 7 do
    if (RefreshFlags and (1 shl Index)) <> 0 then
    begin
      if FReferenceSlots[Index] <> nil then
        Dec(FReferenceSlots[Index].ReferenceCount);
      FReferenceSlots[Index] := Picture;
      Inc(Picture.ReferenceCount);
    end;
end;

function TVp9Decoder.DecodeFrame(Data: PByte; Size: PtrInt): PtrInt;
var
  Header: TVp9FrameHeader;
  Sizes: TVp9ReferenceSizes;
  Index: LongInt;
  Picture: TVp9Picture;
  Frame: TVp9FrameState;
  Counts: TVp9Counts;
  Previous: TVp9FrameContext;
  Payload, DataEnd, FrameEnd: PByte;
begin
  for Index := 0 to 7 do
  begin
    Sizes[Index].Valid := FReferenceSlots[Index] <> nil;
    if Sizes[Index].Valid then
    begin
      Sizes[Index].Width := FReferenceSlots[Index].Width;
      Sizes[Index].Height := FReferenceSlots[Index].Height;
    end;
  end;
  ReadUncompressedHeader(Data, Size, FHeaderState, Sizes, Header);
  if Header.ShowExistingFrame then
  begin
    Picture := FReferenceSlots[Header.ExistingFrameIndex];
    if Picture = nil then
      raise EVp9Error.Create('VP9: the frame shown does not exist');
    Picture.CopyTo(FOutput);
    FHasOutput := True;
    if FHeaderState.Profile <= 2 then
      Result := 1
    else
      Result := 2;
    Exit;
  end;
  if not (Header.KeyFrame or Header.IntraOnly) and not FHasDecoded then
    raise EVp9Error.Create('VP9: a stream must start with a key frame or an intra-only frame');
  ResizeContexts(Header.Width, Header.Height);
  if Header.KeyFrame or Header.IntraOnly or Header.ErrorResilient then
  begin
    ResetProbabilities(Header);
    FillChar(FSegmentMaps[0][0], Length(FSegmentMaps[0]), 0);
    FillChar(FSegmentMaps[1][0], Length(FSegmentMaps[1]), 0);
    Header.FrameContextIndex := 0;
  end;
  if not Header.KeyFrame then
    FIntraOnlyFlag := Header.IntraOnly;
  FProbabilities := FFrameContexts[Header.FrameContextIndex];
  if not FProbabilities.Initialized then
    raise EVp9Error.Create('VP9: uninitialized entropy context');
  Payload := Data + Header.UncompressedHeaderSize;
  DataEnd := Data + Size;
  if (Header.CompressedHeaderSize > DataEnd - Payload) then
    raise EVp9Error.Create('VP9: truncated packet or corrupt header length');
  ReadCompressedHeader(Payload, Header.CompressedHeaderSize, Header, FProbabilities,
    Header.KeyFrame or Header.IntraOnly);
  Picture := TakeFreePicture;
  Picture.Allocate(Header.Width, Header.Height, FHeaderState.SubsamplingX, FHeaderState.SubsamplingY,
    FHeaderState.BitDepth);
  Picture.ColorSpace := FHeaderState.ColorSpace;
  Picture.FullRange := FHeaderState.FullRange;
  Inc(Picture.ReferenceCount);
  try
    SetupFrameState(Header, Picture, Frame);
    FrameEnd := DecodeTiles(Payload + Header.CompressedHeaderSize, DataEnd, Header, Frame, Counts);
    FilterFrame(Header, Frame);
    if (not Header.ErrorResilient) and (not Header.FrameParallel) then
    begin
      Previous := FFrameContexts[Header.FrameContextIndex];
      AdaptCoefficientProbabilities(FProbabilities, Previous, Counts, Frame.IntraOnly, FLastKeyFrame);
      if not Frame.IntraOnly then
      begin
        AdaptModeProbabilities(FProbabilities, Previous, Counts, Header.Filter = FilterSwitchable,
          Header.TransformMode = TransformModeSelect);
        AdaptMvProbabilities(FProbabilities, Previous, Counts, Header.AllowHighPrecisionMv);
      end;
    end;
    if Header.RefreshFrameContext then
      FFrameContexts[Header.FrameContextIndex] := FProbabilities;
    UpdateReferences(Header.RefreshFlags, Picture);
  finally
    Dec(Picture.ReferenceCount);
  end;
  FHasDecoded := True;
  FLastShowFrame := Header.ShowFrame;
  FPreviousPicture := Picture;
  if FHeaderState.Segmentation.Enabled then
    FCurrentSegmentMap := 1 - FCurrentSegmentMap;
  FLastWidth := Header.Width;
  FLastHeight := Header.Height;
  FLastKeyFrame := Header.KeyFrame;
  FLastIntraOnly := FIntraOnlyFlag;
  if Header.ShowFrame then
  begin
    Picture.CopyTo(FOutput);
    FHasOutput := True;
  end
  else
    FHasOutput := False;
  Result := FrameEnd - Data;
end;

procedure TVp9Decoder.DecodePacket(Data: PByte; Size: PtrInt);
var
  Marker, Frames, Magnitude, IndexSize, Index, Byte: LongInt;
  FrameSizes: array[0..7] of PtrInt;
  Start, DataEnd: PByte;
  Used: PtrInt;
begin
  FHasOutput := False;
  if Size <= 0 then
    Exit;
  Marker := Data[Size - 1];
  Frames := 0;
  if (Marker and $E0) = $C0 then
  begin
    Frames := (Marker and 7) + 1;
    Magnitude := ((Marker shr 3) and 3) + 1;
    IndexSize := 2 + Magnitude * Frames;
    if (Size < IndexSize) or (Data[Size - IndexSize] <> Marker) then
      raise EVp9Error.Create('VP9: invalid superframe index');
    for Index := 0 to Frames - 1 do
    begin
      FrameSizes[Index] := 0;
      for Byte := 0 to Magnitude - 1 do
        FrameSizes[Index] := FrameSizes[Index] or
          (PtrInt(Data[Size - IndexSize + 1 + Index * Magnitude + Byte]) shl (Byte * 8));
    end;
  end;
  DataEnd := Data + Size;
  Start := Data;
  if Frames > 0 then
  begin
    for Index := 0 to Frames - 1 do
    begin
      if FrameSizes[Index] > DataEnd - Start then
        raise EVp9Error.Create('VP9: invalid frame size in index');
      DecodeFrame(Start, FrameSizes[Index]);
      Inc(Start, FrameSizes[Index]);
    end;
  end
  else
    while Start < DataEnd do
    begin
      Used := DecodeFrame(Start, DataEnd - Start);
      Inc(Start, Used);
      while (Start < DataEnd) and (Start^ = 0) do
        Inc(Start);
    end;
end;

function TVp9Decoder.ReceiveFrame(out Frame: TVideoFrame): Boolean;
begin
  Frame := Default(TVideoFrame);
  Result := FHasOutput;
  if Result then
  begin
    Frame := FOutput;
    FOutput := Default(TVideoFrame);
    FHasOutput := False;
  end;
end;

end.
