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
  The super-resolution upscaling process (specification section 7.16):
  a frame coded FrameWidth samples wide is stretched horizontally to
  UpscaledWidth with 8-tap filters at 1/64 sample positions.
  UpscaleRows does a range of rows of one plane, for threads.
}
unit Av1.SuperRes;

{$mode objfpc}

interface

uses
  Av1.Common, Av1.Constants, Av1.Tables, Av1.FrameContext, Av1.Picture;

{ A new picture UpscaledWidth wide holding Source upscaled. }
function UpscalePicture(Frame: TFrameContext; Source: TPicture): TPicture;
{ Rows [ RowStart, RowEnd ) of one plane of Source upscaled into Target. }
procedure UpscaleRows(Frame: TFrameContext; Source, Target: TPicture; Plane, RowStart, RowEnd: Integer);

implementation

procedure UpscaleRows(Frame: TFrameContext; Source, Target: TPicture; Plane, RowStart, RowEnd: Integer);
var
  SubX, SubY, DownscaledPlaneW, UpscaledPlaneW, PlaneH, StepX, Error, InitialSubpelX: Integer;
  MaxX, Y, X, K, SourceX, SourceXPx, SourceXSubpel, SampleX, Sum, PixelMax, Value: Integer;
  SourceRow, TargetRow: PWord;
begin
  if Plane > 0 then
  begin
    SubX := Frame.Sequence.subsampling_x;
    SubY := Frame.Sequence.subsampling_y;
  end
  else
  begin
    SubX := 0;
    SubY := 0;
  end;
  DownscaledPlaneW := Round2(Frame.Header.FrameWidth, SubX);
  UpscaledPlaneW := Round2(Frame.Header.UpscaledWidth, SubX);
  PlaneH := Round2(Frame.Header.FrameHeight, SubY);
  StepX := ((DownscaledPlaneW shl SUPERRES_SCALE_BITS) + (UpscaledPlaneW div 2)) div UpscaledPlaneW;
  Error := (UpscaledPlaneW * StepX) - (DownscaledPlaneW shl SUPERRES_SCALE_BITS);
  InitialSubpelX :=
    (-((UpscaledPlaneW - DownscaledPlaneW) shl (SUPERRES_SCALE_BITS - 1)) + UpscaledPlaneW div 2) div UpscaledPlaneW +
    (1 shl (SUPERRES_EXTRA_BITS - 1)) - Error div 2;
  InitialSubpelX := InitialSubpelX and SUPERRES_SCALE_MASK;
  MaxX := (Frame.Header.MiCols shr SubX) * MI_SIZE - 1;
  PixelMax := (1 shl Frame.Sequence.BitDepth) - 1;
  if RowEnd > PlaneH then
    RowEnd := PlaneH;
  for Y := RowStart to RowEnd - 1 do
  begin
    SourceRow := Source.Row(Plane, Y);
    TargetRow := Target.Row(Plane, Y);
    for X := 0 to UpscaledPlaneW - 1 do
    begin
      SourceX := -(1 shl SUPERRES_SCALE_BITS) + InitialSubpelX + X * StepX;
      SourceXPx := SarLongint(SourceX, SUPERRES_SCALE_BITS);
      SourceXSubpel := (SourceX and SUPERRES_SCALE_MASK) shr SUPERRES_EXTRA_BITS;
      Sum := 0;
      for K := 0 to SUPERRES_FILTER_TAPS - 1 do
      begin
        SampleX := SourceXPx + (K - SUPERRES_FILTER_OFFSET);
        if SampleX < 0 then
          SampleX := 0
        else if SampleX > MaxX then
          SampleX := MaxX;
        Inc(Sum, SourceRow[SampleX] * Upscale_Filter[SourceXSubpel][K]);
      end;
      Value := SarLongint(Sum + (1 shl (FILTER_BITS - 1)), FILTER_BITS);
      if Value < 0 then
        Value := 0
      else if Value > PixelMax then
        Value := PixelMax;
      TargetRow[X] := Value;
    end;
  end;
end;

function UpscalePicture(Frame: TFrameContext; Source: TPicture): TPicture;
var
  Plane: Integer;
begin
  Result := TPicture.Create(Frame.Header.UpscaledWidth, Frame.Header.FrameHeight, Frame.Sequence.subsampling_x,
    Frame.Sequence.subsampling_y, Frame.Sequence.NumPlanes, Frame.Sequence.BitDepth, 64);
  for Plane := 0 to Frame.Sequence.NumPlanes - 1 do
    UpscaleRows(Frame, Source, Result, Plane, 0, Result.Planes[Plane].Height);
end;

end.
