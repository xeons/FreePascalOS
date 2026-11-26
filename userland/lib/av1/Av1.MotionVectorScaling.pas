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
  The motion vector scaling process (specification section 7.11.3.3):
  where a block's prediction starts in the reference frame and how far
  apart its samples are there, in 1/1024 samples, allowing for a
  reference frame of another size than the current one. Also is_scaled
  (section 5.11.27).
}
unit Av1.MotionVectorScaling;

{$mode objfpc}

interface

uses
  Av1.Common, Av1.Constants, Av1.References, Av1.TileContext;

{ RefUpscaledWidth and RefFrameHeight are those of the reference used
  (the current frame's for intra block copy). }
procedure ScaleMotionVector(Tile: TTileContext; Plane, RefUpscaledWidth, RefFrameHeight, X, Y: Integer;
  const Mv: TMotionVector; out StartX, StartY, StepX, StepY: Integer);
{ is_scaled( refFrame ): whether the reference differs in size from the current frame. }
function IsScaled(Tile: TTileContext; RefFrame: Integer): Boolean;

implementation

procedure ScaleMotionVector(Tile: TTileContext; Plane, RefUpscaledWidth, RefFrameHeight, X, Y: Integer;
  const Mv: TMotionVector; out StartX, StartY, StepX, StepY: Integer);
const
  HalfSample = 1 shl (SUBPEL_BITS - 1);
  RoundingOffset = (1 shl (SCALE_SUBPEL_BITS - SUBPEL_BITS)) div 2;
var
  FrameWidth, FrameHeight, XScale, YScale, SubX, SubY: Integer;
  OriginX, OriginY: Int64;
  BaseX, BaseY: Int64;
begin
  FrameWidth := Tile.Header^.FrameWidth;
  FrameHeight := Tile.Header^.FrameHeight;
  XScale := ((RefUpscaledWidth shl REF_SCALE_SHIFT) + (FrameWidth div 2)) div FrameWidth;
  YScale := ((RefFrameHeight shl REF_SCALE_SHIFT) + (FrameHeight div 2)) div FrameHeight;
  SubX := Tile.SubsamplingX(Plane);
  SubY := Tile.SubsamplingY(Plane);
  OriginX := (Int64(X) shl SUBPEL_BITS) + ShiftRight(2 * Mv[1], SubX) + HalfSample;
  OriginY := (Int64(Y) shl SUBPEL_BITS) + ShiftRight(2 * Mv[0], SubY) + HalfSample;
  BaseX := OriginX * XScale - (Int64(HalfSample) shl REF_SCALE_SHIFT);
  BaseY := OriginY * YScale - (Int64(HalfSample) shl REF_SCALE_SHIFT);
  StartX := Round2SignedInt64(BaseX, REF_SCALE_SHIFT + SUBPEL_BITS - SCALE_SUBPEL_BITS) + RoundingOffset;
  StartY := Round2SignedInt64(BaseY, REF_SCALE_SHIFT + SUBPEL_BITS - SCALE_SUBPEL_BITS) + RoundingOffset;
  StepX := Round2Signed(XScale, REF_SCALE_SHIFT - SCALE_SUBPEL_BITS);
  StepY := Round2Signed(YScale, REF_SCALE_SHIFT - SCALE_SUBPEL_BITS);
end;

function IsScaled(Tile: TTileContext; RefFrame: Integer): Boolean;
var
  Reference: TReferenceFrame;
  FrameWidth, FrameHeight, XScale, YScale: Integer;
begin
  Reference := Tile.Frame.ReferenceFrames[RefFrame];
  FrameWidth := Tile.Header^.FrameWidth;
  FrameHeight := Tile.Header^.FrameHeight;
  XScale := ((Reference.RefUpscaledWidth shl REF_SCALE_SHIFT) + (FrameWidth div 2)) div FrameWidth;
  YScale := ((Reference.RefFrameHeight shl REF_SCALE_SHIFT) + (FrameHeight div 2)) div FrameHeight;
  Result := (XScale <> 1 shl REF_SCALE_SHIFT) or (YScale <> 1 shl REF_SCALE_SHIFT);
end;

end.
