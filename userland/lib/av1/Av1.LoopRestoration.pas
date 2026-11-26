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
  The loop restoration process (specification section 7.17): LrFrame
  starts as a copy of UpscaledCdefFrame, and each restoration unit with
  a Wiener or self guided filter is filtered into it.

  The specification walks 4x4 luma blocks; every block of one stripe
  (64 luma rows, offset 8 rows up) and one restoration unit gets the
  same filter and the same sources, so this filters rectangles of up to
  64 by 64 samples, each inside one stripe and one unit, which gives the
  same samples. RestoreStripes does a range of stripes of one plane,
  for threads (each with its own TRestorationScratch).
}
unit Av1.LoopRestoration;

{$mode objfpc}

interface

uses
  Av1.Common, Av1.Constants, Av1.FrameContext, Av1.Picture, Av1.RestorationWindow, Av1.Wiener,
  Av1.SelfGuided;

{ Filters the stripes [ StripeFirst, StripeLast ] of the plane into Frame.LrFrame. }
procedure RestoreStripes(Frame: TFrameContext; Scratch: TRestorationScratch; Plane, StripeFirst,
  StripeLast: Integer);
{ The number of stripes of the frame (luma rows offset by 8, 64 a stripe). }
function StripeCount(Frame: TFrameContext): Integer;
{ The loop restoration of every plane with a restoration type. }
procedure ApplyLoopRestoration(Frame: TFrameContext);

implementation

function StripeCount(Frame: TFrameContext): Integer;
begin
  Result := (Frame.Header.FrameHeight + 8 + 63) div 64;
end;

procedure RestoreRectangle(Frame: TFrameContext; Scratch: TRestorationScratch; var Block: TRestorationBlock;
  const RestorationUnit: TRestorationUnit; Right, Bottom: Integer);
var
  Top, Left, FirstLeft: Integer;
begin
  Top := Block.Y;
  FirstLeft := Block.X;
  while Top <= Bottom do
  begin
    Block.Y := Top;
    Block.H := Min(RestorationBlockMax, Bottom - Top + 1);
    Left := FirstLeft;
    while Left <= Right do
    begin
      Block.X := Left;
      Block.W := Min(RestorationBlockMax, Right - Left + 1);
      FillRestorationWindow(Scratch, Block, Frame.UpscaledCurrFrame, Frame.UpscaledCdefFrame);
      if RestorationUnit.RestorationType = RESTORE_WIENER then
        WienerFilter(Scratch, Block, RestorationUnit, Frame.Sequence.BitDepth, Frame.LrFrame)
      else
        SelfGuidedFilter(Scratch, Block, RestorationUnit, Frame.Sequence.BitDepth, Frame.UpscaledCdefFrame,
          Frame.LrFrame);
      Inc(Left, Block.W);
    end;
    Inc(Top, Block.H);
  end;
end;

procedure RestoreStripes(Frame: TFrameContext; Scratch: TRestorationScratch; Plane, StripeFirst,
  StripeLast: Integer);
var
  SubX, SubY, UnitSize, UnitRows, UnitCols, Stripe, UnitRow, UnitCol: Integer;
  StripeStartY, StripeEndY, Top, Bottom, Left, Right: Integer;
  Block: TRestorationBlock;
  RestorationUnit: PRestorationUnit;
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
  UnitSize := Frame.Header.LoopRestorationSize[Plane];
  UnitRows := Frame.LrUnitRows[Plane];
  UnitCols := Frame.LrUnitCols[Plane];
  Block.Plane := Plane;
  Block.PlaneEndX := Round2(Frame.Header.UpscaledWidth, SubX) - 1;
  Block.PlaneEndY := Round2(Frame.Header.FrameHeight, SubY) - 1;
  for Stripe := StripeFirst to StripeLast do
  begin
    StripeStartY := SarLongint(-8 + Stripe * 64, SubY);
    StripeEndY := StripeStartY + (64 shr SubY) - 1;
    Top := Max(0, StripeStartY);
    Bottom := Min(Block.PlaneEndY, StripeEndY);
    if Top > Bottom then
      Continue;
    Block.StripeStartY := StripeStartY;
    Block.StripeEndY := StripeEndY;
    { unitRow from the stripe's first luma row (lumaY + 8 = 64 * Stripe, or 0 for the first) }
    UnitRow := Min(UnitRows - 1, ((Stripe * 64) shr SubY) div UnitSize);
    for UnitCol := 0 to UnitCols - 1 do
    begin
      Left := UnitCol * UnitSize;
      if Left > Block.PlaneEndX then
        Break;
      if UnitCol = UnitCols - 1 then
        Right := Block.PlaneEndX
      else
        Right := Min(Block.PlaneEndX, Left + UnitSize - 1);
      RestorationUnit := @Frame.LrUnits[Plane][UnitRow * UnitCols + UnitCol];
      if (RestorationUnit^.RestorationType <> RESTORE_WIENER) and
        (RestorationUnit^.RestorationType <> RESTORE_SGRPROJ) then
        Continue;
      Block.X := Left;
      Block.Y := Top;
      RestoreRectangle(Frame, Scratch, Block, RestorationUnit^, Right, Bottom);
    end;
  end;
end;

procedure ApplyLoopRestoration(Frame: TFrameContext);
var
  Scratch: TRestorationScratch;
  Plane: Integer;
begin
  Scratch := TRestorationScratch.Create;
  try
    for Plane := 0 to Frame.Sequence.NumPlanes - 1 do
      if Frame.Header.FrameRestorationType[Plane] <> RESTORE_NONE then
        RestoreStripes(Frame, Scratch, Plane, 0, StripeCount(Frame) - 1);
  finally
    Scratch.Free;
  end;
end;

end.
