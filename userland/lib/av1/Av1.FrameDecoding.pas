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
  Decoding frames (specification sections 5.9.1, 5.11.1, 7.4, 7.20 and
  7.21): what follows a frame header (the CDFs loaded or reset, the
  previous segmentation map, motion field estimation), the tile groups,
  the frame wrapup (post filters, motion field storage, the reference
  frame update) and the frames shown, including show_existing_frame.

  Tiles of a tile group are decoded on worker threads when there are
  several of them and the decoder was given threads.
}
unit Av1.FrameDecoding;

{$mode objfpc}
{$H+}

interface

uses
  Classes, SysUtils, Media.Frames, Av1.Common, Av1.Constants, Av1.Tables, Av1.CdfContext, Av1.BitReader,
  Av1.SequenceHeader, Av1.FrameHeader, Av1.Picture, Av1.References, Av1.FrameContext, Av1.TileContext,
  Av1.WorkerPool;

type
  TFrameShownEvent = procedure(const Frame: TVideoFrame) of object;

  TFrameDecoder = class
  private
    FSlots: TReferenceSlots;
    FFrame: TFrameContext;
    FTiles: array of TTileContext;
    FTileMiStride, FTileMiRows: Integer;
    FThreadCount: Integer;
    FPool: TWorkerPool;
    FTileData: PByte;
    FTileFirst: Integer;
    FTileStarts, FTileSizes: array of Integer;
    FOnFrameShown: TFrameShownEvent;
    FPresentationTime: Int64;
    procedure TileJob(Index, Worker: Integer);
    procedure SetupReferences;
    procedure LoadPreviousSegmentIds;
    procedure AllocateRestorationUnits;
    procedure EnsureTileContexts(Count: Integer);
    procedure DecodeTiles(First, Last: Integer; const Starts, Sizes: array of Integer; Data: PByte);
    procedure FinishFrame;
    procedure UpdateReferences(Saved: TReferenceFrame);
    function SaveFrame: TReferenceFrame;
    procedure Output(Picture: TPicture; Width, Height: Integer; const FilmGrain: TFilmGrainParams);
  public
    constructor Create(ThreadCount: Integer);
    destructor Destroy; override;
    { The frame described by Header (show_existing_frame = 0) starts. }
    procedure StartFrame(const Sequence: TSequenceHeader; const Header: TFrameHeader);
    { tile_group_obu( sz ) over Size bytes; finishes the frame after its last tile. }
    procedure DecodeTileGroup(Data: PByte; Size: Integer);
    { A frame header with show_existing_frame = 1. }
    procedure ShowExistingFrame(const Sequence: TSequenceHeader; const Header: TFrameHeader);
    procedure Reset;
    { The reference slots, which the frame header reader updates. }
    function ReferenceSlots: PReferenceSlots;
    property OnFrameShown: TFrameShownEvent read FOnFrameShown write FOnFrameShown;
    property PresentationTime: Int64 read FPresentationTime write FPresentationTime;
  end;

implementation

uses
  Av1.TileDecoding, Av1.MotionField, Av1.PostFilters, Av1.Output, Av1.ToolStatistics;

procedure CountFrameTools(const Sequence: TSequenceHeader; const Header: TFrameHeader);
begin
  case Header.frame_type of
    KEY_FRAME: CountTool(toolKeyFrame);
    INTER_FRAME: CountTool(toolInterFrame);
    INTRA_ONLY_FRAME: CountTool(toolIntraOnlyFrame);
  else
    CountTool(toolSwitchFrame);
  end;
  if Header.error_resilient_mode then
    CountTool(toolErrorResilient);
  if Header.frame_refs_short_signaling then
    CountTool(toolShortRefSignaling);
  if Header.reference_select then
    CountTool(toolReferenceSelect);
  if Header.use_ref_frame_mvs then
    CountTool(toolTemporalMvs);
  if Header.skip_mode_present then
    CountTool(toolSkipModeFrame);
  if Header.TileCols * Header.TileRows > 1 then
    CountTool(toolMultipleTiles);
  if Sequence.use_128x128_superblock then
    CountTool(toolSuperblock128);
  if Header.use_superres then
    CountTool(toolSuperres);
  if Header.CodedLossless then
    CountTool(toolLossless);
  if Header.using_qmatrix then
    CountTool(toolQuantizerMatrix);
  if Header.segmentation_enabled then
    CountTool(toolSegmentation);
  if Header.delta_q_present then
    CountTool(toolDeltaQ);
  if Header.delta_lf_present then
    CountTool(toolDeltaLf);
  if (Header.loop_filter_level[0] <> 0) or (Header.loop_filter_level[1] <> 0) then
    CountTool(toolLoopFilter);
  if Sequence.enable_cdef and not Header.CodedLossless and not Header.allow_intrabc then
    CountTool(toolCdef);
  if Sequence.film_grain_params_present and Header.FilmGrain.apply_grain then
    CountTool(toolFilmGrain);
end;

function TFrameDecoder.ReferenceSlots: PReferenceSlots;
begin
  Result := @FSlots;
end;

constructor TFrameDecoder.Create(ThreadCount: Integer);
begin
  inherited Create;
  FThreadCount := ThreadCount;
  if ThreadCount > 1 then
    FPool := TWorkerPool.Create(ThreadCount);
end;

destructor TFrameDecoder.Destroy;
begin
  Reset;
  FPool.Free;
  inherited Destroy;
end;

procedure TFrameDecoder.Reset;
var
  Index: Integer;
begin
  for Index := 0 to High(FTiles) do
    FTiles[Index].Free;
  FTiles := nil;
  FreeAndNil(FFrame);
  ReleaseReferenceSlots(FSlots);
end;

procedure TFrameDecoder.SetupReferences;
var
  Index: Integer;
  Reference: TReferenceFrame;
begin
  FFrame.ReleaseReferences;
  if FFrame.Header.FrameIsIntra then
    Exit;
  for Index := 0 to REFS_PER_FRAME - 1 do
  begin
    Reference := FSlots.Frames[FFrame.Header.ref_frame_idx[Index]];
    if Reference = nil then
      RaiseAv1Error('missing reference frame');
    { The specification requires references of the frame's format, and
      sizes within the scaling limits. }
    if (Reference.RefBitDepth <> FFrame.Sequence.BitDepth) or
      (Reference.RefSubsamplingX <> FFrame.Sequence.subsampling_x) or
      (Reference.RefSubsamplingY <> FFrame.Sequence.subsampling_y) or
      (Reference.Picture.NumPlanes <> FFrame.Sequence.NumPlanes) then
      RaiseAv1Error('a reference frame of another format');
    if (2 * FFrame.Header.FrameWidth < Reference.RefUpscaledWidth) or
      (2 * FFrame.Header.FrameHeight < Reference.RefFrameHeight) or
      (FFrame.Header.FrameWidth > 16 * Reference.RefUpscaledWidth) or
      (FFrame.Header.FrameHeight > 16 * Reference.RefFrameHeight) then
      RaiseAv1Error('a reference frame beyond the scaling limits');
    FFrame.ReferenceFrames[LAST_FRAME + Index] := Reference.Acquire;
  end;
end;

procedure TFrameDecoder.LoadPreviousSegmentIds;
var
  Previous: TReferenceFrame;
  Row: Integer;
begin
  FillChar(FFrame.PrevSegmentIds[0], Length(FFrame.PrevSegmentIds), 0);
  if FFrame.Header.primary_ref_frame = PRIMARY_REF_NONE then
    Exit;
  Previous := FSlots.Frames[FFrame.Header.ref_frame_idx[FFrame.Header.primary_ref_frame]];
  if FFrame.Header.segmentation_enabled and (Previous.RefMiCols = FFrame.Header.MiCols) and
    (Previous.RefMiRows = FFrame.Header.MiRows) then
    for Row := 0 to FFrame.Header.MiRows - 1 do
      Move(Previous.SavedSegmentIds[Row * Previous.RefMiCols], FFrame.PrevSegmentIds[FFrame.MiIndex(Row, 0)],
        FFrame.Header.MiCols);
end;

procedure TFrameDecoder.AllocateRestorationUnits;
var
  Plane, SubX, SubY, UnitSize: Integer;
begin
  for Plane := 0 to 2 do
  begin
    FFrame.LrUnitRows[Plane] := 0;
    FFrame.LrUnitCols[Plane] := 0;
    if (Plane >= FFrame.Sequence.NumPlanes) or (FFrame.Header.FrameRestorationType[Plane] = RESTORE_NONE) then
      Continue;
    if Plane = 0 then
    begin
      SubX := 0;
      SubY := 0;
    end
    else
    begin
      SubX := FFrame.Sequence.subsampling_x;
      SubY := FFrame.Sequence.subsampling_y;
    end;
    UnitSize := FFrame.Header.LoopRestorationSize[Plane];
    FFrame.LrUnitRows[Plane] := CountUnitsInFrame(UnitSize, Round2(FFrame.Header.FrameHeight, SubY));
    FFrame.LrUnitCols[Plane] := CountUnitsInFrame(UnitSize, Round2(FFrame.Header.UpscaledWidth, SubX));
    FFrame.LrUnits[Plane] := nil;
    SetLength(FFrame.LrUnits[Plane], FFrame.LrUnitRows[Plane] * FFrame.LrUnitCols[Plane]);
  end;
end;

procedure TFrameDecoder.StartFrame(const Sequence: TSequenceHeader; const Header: TFrameHeader);
var
  Previous: TReferenceFrame;
begin
  if FFrame = nil then
    FFrame := TFrameContext.Create;
  FFrame.Sequence := Sequence;
  FFrame.Header := Header;
  CountFrameTools(Sequence, Header);
  SetupReferences;
  FFrame.Allocate;
  if Header.primary_ref_frame = PRIMARY_REF_NONE then
  begin
    InitializeNonCoefficientCdfs(FFrame.Cdfs);
    InitializeCoefficientCdfs(FFrame.Cdfs, CoefficientCdfIndex(Header.base_q_idx));
  end
  else
  begin
    Previous := FSlots.Frames[Header.ref_frame_idx[Header.primary_ref_frame]];
    FFrame.Cdfs := Previous.SavedCdfs;
    ClearCdfCounters(FFrame.Cdfs);
  end;
  LoadPreviousSegmentIds;
  if Header.use_ref_frame_mvs then
    MotionFieldEstimation(FFrame);
  AllocateRestorationUnits;
end;

procedure TFrameDecoder.EnsureTileContexts(Count: Integer);
var
  Index: Integer;
begin
  { Tile contexts are sized by the frame's mode info arrays; they are kept
    while those keep their size. }
  if (Length(FTiles) > 0) and ((FTileMiStride <> FFrame.MiStride) or (FTileMiRows <> FFrame.MiRowsAllocated)) then
  begin
    for Index := 0 to High(FTiles) do
      FTiles[Index].Free;
    FTiles := nil;
  end;
  FTileMiStride := FFrame.MiStride;
  FTileMiRows := FFrame.MiRowsAllocated;
  Index := Length(FTiles);
  if Index < Count then
  begin
    SetLength(FTiles, Count);
    while Index < Count do
    begin
      FTiles[Index] := TTileContext.Create(FFrame);
      Inc(Index);
    end;
  end;
end;

procedure TFrameDecoder.TileJob(Index, Worker: Integer);
begin
  DecodeTile(FTiles[Worker], FTileFirst + Index, FTileData + FTileStarts[Index], FTileSizes[Index]);
end;

procedure TFrameDecoder.DecodeTiles(First, Last: Integer; const Starts, Sizes: array of Integer; Data: PByte);
var
  Count, Index: Integer;
begin
  Count := Last - First + 1;
  if (FPool = nil) or (Count = 1) then
  begin
    EnsureTileContexts(1);
    for Index := 0 to Count - 1 do
      DecodeTile(FTiles[0], First + Index, Data + Starts[Index], Sizes[Index]);
    Exit;
  end;
  EnsureTileContexts(FPool.WorkerCount);
  FTileData := Data;
  FTileFirst := First;
  FTileStarts := nil;
  FTileSizes := nil;
  SetLength(FTileStarts, Count);
  SetLength(FTileSizes, Count);
  for Index := 0 to Count - 1 do
  begin
    FTileStarts[Index] := Starts[Index];
    FTileSizes[Index] := Sizes[Index];
  end;
  FPool.Run(Count, @TileJob);
end;

procedure TFrameDecoder.DecodeTileGroup(Data: PByte; Size: Integer);
var
  Reader: TBitReader;
  NumTiles, TileBits, TgStart, TgEnd, HeaderBytes, Remaining, Offset, TileNum, TileSize, Index: Integer;
  StartAndEndPresent: Boolean;
  Starts, Sizes: array of Integer;
begin
  if FFrame = nil then
    RaiseAv1Error('tile group without a frame header');
  InitializeBitReader(Reader, Data, Size);
  NumTiles := FFrame.Header.TileCols * FFrame.Header.TileRows;
  StartAndEndPresent := False;
  if NumTiles > 1 then
    StartAndEndPresent := ReadFlag(Reader);
  if (NumTiles = 1) or not StartAndEndPresent then
  begin
    TgStart := 0;
    TgEnd := NumTiles - 1;
  end
  else
  begin
    TileBits := FFrame.Header.TileColsLog2 + FFrame.Header.TileRowsLog2;
    TgStart := ReadBits(Reader, TileBits);
    TgEnd := ReadBits(Reader, TileBits);
  end;
  if (TgStart > TgEnd) or (TgEnd >= NumTiles) then
    RaiseAv1Error('a tile group with tiles the frame does not have');
  AlignToByte(Reader);
  HeaderBytes := BytePosition(Reader);
  Offset := HeaderBytes;
  Remaining := Size - HeaderBytes;
  Starts := nil;
  Sizes := nil;
  SetLength(Starts, TgEnd - TgStart + 1);
  SetLength(Sizes, TgEnd - TgStart + 1);
  for TileNum := TgStart to TgEnd do
  begin
    Index := TileNum - TgStart;
    if TileNum = TgEnd then
      TileSize := Remaining
    else
    begin
      InitializeBitReader(Reader, Data + Offset, Remaining);
      TileSize := Integer(ReadLittleEndian(Reader, FFrame.Header.TileSizeBytes)) + 1;
      Inc(Offset, FFrame.Header.TileSizeBytes);
      Dec(Remaining, TileSize + FFrame.Header.TileSizeBytes);
    end;
    if (TileSize <= 0) or (Offset + TileSize > Size) then
      RaiseAv1Error('tile data cut short');
    Starts[Index] := Offset;
    Sizes[Index] := TileSize;
    Inc(Offset, TileSize);
  end;
  DecodeTiles(TgStart, TgEnd, Starts, Sizes, Data);
  if TgEnd = NumTiles - 1 then
  begin
    if not FFrame.Header.disable_frame_end_update_cdf then
      FFrame.Cdfs := FFrame.SavedCdfs;
    FinishFrame;
  end;
end;

function TFrameDecoder.SaveFrame: TReferenceFrame;
var
  Frame: TFrameContext;
  Index, Row, Count: Integer;
begin
  Frame := FFrame;
  Result := TReferenceFrame.Create;
  Result.Picture := Frame.LrFrame;
  if Frame.LrFrame = Frame.CurrFrame then
    Frame.CurrFrame := nil;
  if Frame.LrFrame = Frame.UpscaledCurrFrame then
    Frame.UpscaledCurrFrame := nil;
  if Frame.LrFrame = Frame.UpscaledCdefFrame then
    Frame.UpscaledCdefFrame := nil;
  if Frame.LrFrame = Frame.CdefFrame then
    Frame.CdefFrame := nil;
  Frame.LrFrame := nil;
  Frame.FreePostFilterPictures;
  Result.RefFrameId := Frame.Header.current_frame_id;
  Result.RefUpscaledWidth := Frame.Header.UpscaledWidth;
  Result.RefFrameWidth := Frame.Header.FrameWidth;
  Result.RefFrameHeight := Frame.Header.FrameHeight;
  Result.RefRenderWidth := Frame.Header.RenderWidth;
  Result.RefRenderHeight := Frame.Header.RenderHeight;
  Result.RefMiCols := Frame.Header.MiCols;
  Result.RefMiRows := Frame.Header.MiRows;
  Result.RefFrameType := Frame.Header.frame_type;
  Result.RefSubsamplingX := Frame.Sequence.subsampling_x;
  Result.RefSubsamplingY := Frame.Sequence.subsampling_y;
  Result.RefBitDepth := Frame.Sequence.BitDepth;
  Result.RefOrderHint := Frame.Header.OrderHint;
  Result.RefShowableFrame := Frame.Header.showable_frame;
  for Index := 0 to TOTAL_REFS_PER_FRAME - 1 do
    Result.SavedOrderHints[Index] := Frame.Header.OrderHints[Index];
  Count := Frame.Header.MiRows * Frame.Header.MiCols;
  SetLength(Result.SavedRefFrames, Count);
  SetLength(Result.SavedMvs, Count);
  SetLength(Result.SavedSegmentIds, Count);
  for Row := 0 to Frame.Header.MiRows - 1 do
  begin
    Move(Frame.MfRefFrames[Frame.MiIndex(Row, 0)], Result.SavedRefFrames[Row * Frame.Header.MiCols],
      Frame.Header.MiCols * SizeOf(ShortInt));
    Move(Frame.MfMvs[Frame.MiIndex(Row, 0)], Result.SavedMvs[Row * Frame.Header.MiCols],
      Frame.Header.MiCols * SizeOf(TMotionVector));
    Move(Frame.SegmentIds[Frame.MiIndex(Row, 0)], Result.SavedSegmentIds[Row * Frame.Header.MiCols],
      Frame.Header.MiCols);
  end;
  Result.SavedGmParams := Frame.Header.gm_params;
  Result.SavedCdfs := Frame.Cdfs;
  Result.SavedFilmGrain := Frame.Header.FilmGrain;
  Result.SavedLoopFilterDeltas := Frame.Header.LoopFilterDeltas;
  Result.SavedSegmentation := Frame.Header.Segmentation;
end;

procedure TFrameDecoder.UpdateReferences(Saved: TReferenceFrame);
var
  Index: Integer;
begin
  for Index := 0 to NUM_REF_FRAMES - 1 do
    if ((FFrame.Header.refresh_frame_flags shr Index) and 1) <> 0 then
    begin
      FSlots.RefValid[Index] := True;
      FSlots.RefFrameId[Index] := Saved.RefFrameId;
      FSlots.RefOrderHint[Index] := Saved.RefOrderHint;
      AssignReferenceSlot(FSlots, Index, Saved);
    end;
end;

procedure TFrameDecoder.Output(Picture: TPicture; Width, Height: Integer; const FilmGrain: TFilmGrainParams);
var
  Frame: TVideoFrame;
begin
  if not Assigned(FOnFrameShown) then
    Exit;
  ProduceOutputFrame(Picture, Width, Height, FFrame.Sequence, FilmGrain, FPresentationTime, Frame);
  FOnFrameShown(Frame);
end;

procedure TFrameDecoder.FinishFrame;
var
  Saved: TReferenceFrame;
  Row: Integer;
begin
  ApplyPostFilters(FFrame, FPool);
  StoreMotionField(FFrame);
  if FFrame.Header.segmentation_enabled and not FFrame.Header.segmentation_update_map then
    for Row := 0 to FFrame.Header.MiRows - 1 do
      Move(FFrame.PrevSegmentIds[FFrame.MiIndex(Row, 0)], FFrame.SegmentIds[FFrame.MiIndex(Row, 0)],
        FFrame.Header.MiCols);
  Saved := SaveFrame;
  try
    UpdateReferences(Saved);
    if FFrame.Header.show_frame then
      Output(Saved.Picture, FFrame.Header.UpscaledWidth, FFrame.Header.FrameHeight, FFrame.Header.FilmGrain);
  finally
    Saved.Release;
    FFrame.ReleaseReferences;
  end;
end;

procedure TFrameDecoder.ShowExistingFrame(const Sequence: TSequenceHeader; const Header: TFrameHeader);
var
  Shown: TReferenceFrame;
  Index: Integer;
begin
  Shown := FSlots.Frames[Header.frame_to_show_map_idx];
  if Shown = nil then
    RaiseAv1Error('show_existing_frame of an empty slot');
  if FFrame = nil then
    FFrame := TFrameContext.Create;
  FFrame.Sequence := Sequence;
  FFrame.Header := Header;
  CountTool(toolShowExistingFrame);
  Output(Shown.Picture, Shown.RefUpscaledWidth, Shown.RefFrameHeight, Header.FilmGrain);
  if Header.frame_type = KEY_FRAME then
  begin
    { The reference frame loading process, then the update of every slot. }
    Shown.Acquire;
    try
      for Index := 0 to NUM_REF_FRAMES - 1 do
      begin
        FSlots.RefValid[Index] := True;
        FSlots.RefFrameId[Index] := Shown.RefFrameId;
        FSlots.RefOrderHint[Index] := Shown.RefOrderHint;
        AssignReferenceSlot(FSlots, Index, Shown);
      end;
    finally
      Shown.Release;
    end;
  end;
end;

end.
