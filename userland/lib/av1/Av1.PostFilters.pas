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
  Av1.Constants, Av1.FrameContext, Av1.Picture, Av1.LoopFilter, Av1.Cdef, Av1.SuperRes, Av1.LoopRestoration;

procedure ApplyPostFilters(Frame: TFrameContext);
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

procedure ApplyPostFilters(Frame: TFrameContext);
var
  Width, Height: Integer;
begin
  Width := Frame.Header.FrameWidth;
  Height := Frame.Header.FrameHeight;
  { 1. Deblocking }
  if (Frame.Header.loop_filter_level[0] <> 0) or (Frame.Header.loop_filter_level[1] <> 0) then
    ApplyLoopFilter(Frame);
  { 2. CDEF: CdefFrame starts as a copy of CurrFrame, including the
    samples past the frame's width that upscaling reads. }
  if CdefEnabled(Frame) then
  begin
    Frame.CdefFrame := DuplicatePicture(Frame.CurrFrame, Width, Height, 256);
    CdefRows(Frame, 0, Frame.Header.MiRows);
  end
  else
    Frame.CdefFrame := Frame.CurrFrame;
  { 3, 4. Upscaling }
  if Frame.Header.use_superres and (Frame.Header.UpscaledWidth <> Frame.Header.FrameWidth) then
  begin
    Frame.UpscaledCdefFrame := UpscalePicture(Frame, Frame.CdefFrame);
    if Frame.Header.UsesLr then
      Frame.UpscaledCurrFrame := UpscalePicture(Frame, Frame.CurrFrame)
    else
      Frame.UpscaledCurrFrame := nil;    { only loop restoration reads it }
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
    ApplyLoopRestoration(Frame);
  end
  else
    Frame.LrFrame := Frame.UpscaledCdefFrame;
end;

end.
