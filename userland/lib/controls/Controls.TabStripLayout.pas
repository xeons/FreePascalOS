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
  Where a tab strip's tabs go (Controls.TabStrip), as plain arithmetic
  in pixels.

  The tabs are all as wide as each other and stand side by side from
  FirstLeft: they share the room there is, each between a minimum and a
  maximum width; when even the minimum does not fit, they shrink
  further, down to the smallest a tab can be. A tab dragged sideways
  follows the pointer within the row and takes the place its middle is
  over; dragged far enough above or below the strip it is out.

  Plain logic, no system calls: it builds for the host too and is
  checked there (tools/NavigationControlsTest).
}
unit Controls.TabStripLayout;

{$mode objfpc}
{$H+}

interface

{ The width of each of TabCount tabs sharing Available pixels: at most
  MaximumWidth, at least MinimumWidth while they fit, never below
  SmallestWidth. }
function StripTabWidth(TabCount, Available, MinimumWidth, MaximumWidth, SmallestWidth: LongInt): LongInt;
{ The tab at X (-1: none). }
function StripTabAt(X, FirstLeft, TabWidth, TabCount: LongInt): LongInt;
{ Where a tab dragged by the pointer at PointerX, held GrabOffset from
  its left edge, is drawn: kept within the row. }
function DraggedTabLeft(PointerX, GrabOffset, FirstLeft, TabWidth, TabCount: LongInt): LongInt;
{ The place a dragged tab drawn at DraggedLeft takes: the one its middle
  is over. }
function StripDropIndex(DraggedLeft, FirstLeft, TabWidth, TabCount: LongInt): LongInt;
{ Whether a tab dragged to Y (the strip's pixels) left the strip: more
  than Threshold above its top or below its bottom. }
function IsDraggedOut(Y, StripHeight, Threshold: LongInt): Boolean;

implementation

function StripTabWidth(TabCount, Available, MinimumWidth, MaximumWidth, SmallestWidth: LongInt): LongInt;
begin
  if TabCount <= 0 then
    Exit(MaximumWidth);
  Result := Available div TabCount;
  if Result > MaximumWidth then
    Result := MaximumWidth;
  { Below the minimum only when they would not fit at it. }
  if (Result < MinimumWidth) and (MinimumWidth * TabCount <= Available) then
    Result := MinimumWidth;
  if Result < SmallestWidth then
    Result := SmallestWidth;
end;

function StripTabAt(X, FirstLeft, TabWidth, TabCount: LongInt): LongInt;
begin
  if (TabWidth <= 0) or (X < FirstLeft) then
    Exit(-1);
  Result := (X - FirstLeft) div TabWidth;
  if Result >= TabCount then
    Result := -1;
end;

function DraggedTabLeft(PointerX, GrabOffset, FirstLeft, TabWidth, TabCount: LongInt): LongInt;
var
  LastLeft: LongInt;
begin
  Result := PointerX - GrabOffset;
  LastLeft := FirstLeft + (TabCount - 1) * TabWidth;
  if Result > LastLeft then
    Result := LastLeft;
  if Result < FirstLeft then
    Result := FirstLeft;
end;

function StripDropIndex(DraggedLeft, FirstLeft, TabWidth, TabCount: LongInt): LongInt;
begin
  if (TabCount <= 0) or (TabWidth <= 0) then
    Exit(0);
  Result := (DraggedLeft + TabWidth div 2 - FirstLeft) div TabWidth;
  if Result < 0 then
    Result := 0;
  if Result >= TabCount then
    Result := TabCount - 1;
end;

function IsDraggedOut(Y, StripHeight, Threshold: LongInt): Boolean;
begin
  Result := (Y < -Threshold) or (Y >= StripHeight + Threshold);
end;

end.
