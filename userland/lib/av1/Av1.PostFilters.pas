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
  The in-loop filters of the decode frame wrapup process (specification
  section 7.4, steps 1 to 5): deblocking CurrFrame, CDEF into CdefFrame,
  super-resolution upscaling of both, and loop restoration into LrFrame.
  A step that changes nothing leaves its output the same picture as its
  input (CdefFrame = CurrFrame without CDEF, the upscaled pictures = the
  ones they come from without super-resolution, LrFrame =
  UpscaledCdefFrame without loop restoration).
}
unit Av1.PostFilters;

{$mode objfpc}

interface

uses
  Av1.Constants, Av1.FrameContext, Av1.Picture, Av1.LoopFilter, Av1.Cdef, Av1.SuperRes, Av1.LoopRestoration,
  Av1.RestorationWindow, Av1.WorkerPool;

{ Steps 1 to 5 of the decode frame wrapup process; with a Pool the rows of
  each filter are shared between its workers. }
procedure ApplyPostFilters(Frame: TFrameContext; Pool: TWorkerPool = nil);
{ A new picture Width by Height like Source, with Source's samples (as
  far as both pictures reach, padding included). }
function DuplicatePicture(Source: TPicture; Width, Height, Padding: Integer): TPicture;

implementation

function DuplicatePicture(Source: TPicture; Width, Height, Padding: Integer): TPicture;
var
  Plane, Y, Columns, Rows: Integer;
begin
  Result := TPicture.Create(Width, Height, Source.SubsamplingX, Source.SubsamplingY, Source.NumPlanes,
    Source.BitDepth, Padding);
  for Plane := 0 to Source.NumPlanes - 1 do
  begin
    Columns := Source.Planes[Plane].AllocatedWidth;
    if Result.Planes[Plane].AllocatedWidth < Columns then
      Columns := Result.Planes[Plane].AllocatedWidth;
    Rows := Source.Planes[Plane].AllocatedHeight;
    if Result.Planes[Plane].AllocatedHeight < Rows then
      Rows := Result.Planes[Plane].AllocatedHeight;
    for Y := 0 to Rows - 1 do
      Move(Source.Row(Plane, Y)^, Result.Row(Plane, Y)^, Columns * SizeOf(Word));
  end;
end;

const
  { Mode info rows of a loop filter or CDEF job: a 64x64 superblock row. }
  RowsPerJob = 16;

type
  { The jobs of one frame's filters on the pool's workers. }
  TPostFilterJobs = class
  public
    Frame: TFrameContext;
    Plane, Pass: Integer;
    Source, Target: TPicture;
    Scratch: array of TRestorationScratch;
    destructor Destroy; override;
    procedure LoopFilterJob(Index, Worker: Integer);
    procedure CdefJob(Index, Worker: Integer);
    procedure UpscaleJob(Index, Worker: Integer);
    procedure RestorationJob(Index, Worker: Integer);
  end;

destructor TPostFilterJobs.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to High(Scratch) do
    Scratch[Index].Free;
  inherited Destroy;
end;

procedure TPostFilterJobs.LoopFilterJob(Index, Worker: Integer);
begin
  LoopFilterRows(Frame, Plane, Pass, Index * RowsPerJob, (Index + 1) * RowsPerJob);
end;

procedure TPostFilterJobs.CdefJob(Index, Worker: Integer);
begin
  CdefRows(Frame, Index * RowsPerJob, (Index + 1) * RowsPerJob);
end;

procedure TPostFilterJobs.UpscaleJob(Index, Worker: Integer);
var
  PlaneIndex, Rows: Integer;
begin
  for PlaneIndex := 0 to Frame.Sequence.NumPlanes - 1 do
  begin
    Rows := 64 shr Ord((PlaneIndex > 0) and (Frame.Sequence.subsampling_y <> 0));
    UpscaleRows(Frame, Source, Target, PlaneIndex, Index * Rows, (Index + 1) * Rows);
  end;
end;

procedure TPostFilterJobs.RestorationJob(Index, Worker: Integer);
var
  PlaneIndex: Integer;
begin
  if Scratch[Worker] = nil then
    Scratch[Worker] := TRestorationScratch.Create;
  for PlaneIndex := 0 to Frame.Sequence.NumPlanes - 1 do
    if Frame.Header.FrameRestorationType[PlaneIndex] <> RESTORE_NONE then
      RestoreStripes(Frame, Scratch[Worker], PlaneIndex, Index, Index);
end;

procedure LoopFilterInParallel(Jobs: TPostFilterJobs; Pool: TWorkerPool);
var
  Plane, Pass: Integer;
  Frame: TFrameContext;
begin
  Frame := Jobs.Frame;
  for Plane := 0 to Frame.Sequence.NumPlanes - 1 do
    if (Plane = 0) or (Frame.Header.loop_filter_level[1 + Plane] <> 0) then
      for Pass := 0 to 1 do
      begin
        { Every edge of a pass reads and writes samples no other edge of
          the pass touches, so the rows can go in any order; the passes
          follow each other. }
        Jobs.Plane := Plane;
        Jobs.Pass := Pass;
        Pool.Run((Frame.Header.MiRows + RowsPerJob - 1) div RowsPerJob, @Jobs.LoopFilterJob);
      end;
end;

function UpscaleInParallel(Jobs: TPostFilterJobs; Pool: TWorkerPool; Source: TPicture): TPicture;
var
  Frame: TFrameContext;
begin
  Frame := Jobs.Frame;
  Result := TPicture.Create(Frame.Header.UpscaledWidth, Frame.Header.FrameHeight, Frame.Sequence.subsampling_x,
    Frame.Sequence.subsampling_y, Frame.Sequence.NumPlanes, Frame.Sequence.BitDepth, 64);
  Jobs.Source := Source;
  Jobs.Target := Result;
  Pool.Run((Frame.Header.FrameHeight + 63) div 64, @Jobs.UpscaleJob);
end;

procedure ApplyPostFilters(Frame: TFrameContext; Pool: TWorkerPool);
var
  Width, Height: Integer;
  Jobs: TPostFilterJobs;
begin
  Width := Frame.Header.FrameWidth;
  Height := Frame.Header.FrameHeight;
  Jobs := nil;
  if (Pool <> nil) and (Pool.WorkerCount > 1) then
  begin
    Jobs := TPostFilterJobs.Create;
    Jobs.Frame := Frame;
    SetLength(Jobs.Scratch, Pool.WorkerCount);
  end;
  try
    { 1. Deblocking }
    if (Frame.Header.loop_filter_level[0] <> 0) or (Frame.Header.loop_filter_level[1] <> 0) then
    begin
      if Jobs <> nil then
        LoopFilterInParallel(Jobs, Pool)
      else
        ApplyLoopFilter(Frame);
    end;
    { 2. CDEF: CdefFrame starts as a copy of CurrFrame, including the
      samples past the frame's width that upscaling reads. }
    if CdefEnabled(Frame) then
    begin
      Frame.CdefFrame := DuplicatePicture(Frame.CurrFrame, Width, Height, 256);
      if Jobs <> nil then
        Pool.Run((Frame.Header.MiRows + RowsPerJob - 1) div RowsPerJob, @Jobs.CdefJob)
      else
        CdefRows(Frame, 0, Frame.Header.MiRows);
    end
    else
      Frame.CdefFrame := Frame.CurrFrame;
    { 3, 4. Upscaling }
    if Frame.Header.use_superres and (Frame.Header.UpscaledWidth <> Frame.Header.FrameWidth) then
    begin
      if Jobs <> nil then
        Frame.UpscaledCdefFrame := UpscaleInParallel(Jobs, Pool, Frame.CdefFrame)
      else
        Frame.UpscaledCdefFrame := UpscalePicture(Frame, Frame.CdefFrame);
      if not Frame.Header.UsesLr then
        Frame.UpscaledCurrFrame := nil    { only loop restoration reads it }
      else if Jobs <> nil then
        Frame.UpscaledCurrFrame := UpscaleInParallel(Jobs, Pool, Frame.CurrFrame)
      else
        Frame.UpscaledCurrFrame := UpscalePicture(Frame, Frame.CurrFrame);
    end
    else
    begin
      Frame.UpscaledCdefFrame := Frame.CdefFrame;
      Frame.UpscaledCurrFrame := Frame.CurrFrame;
    end;
    { 5. Loop restoration }
    if Frame.Header.UsesLr then
    begin
      Frame.LrFrame := DuplicatePicture(Frame.UpscaledCdefFrame, Frame.Header.UpscaledWidth, Height, 64);
      if Jobs <> nil then
        Pool.Run(StripeCount(Frame), @Jobs.RestorationJob)
      else
        ApplyLoopRestoration(Frame);
    end
    else
      Frame.LrFrame := Frame.UpscaledCdefFrame;
  finally
    Jobs.Free;
  end;
end;

end.
