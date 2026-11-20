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
  position: sticky (CSS Positioned Layout 3, 3.4): the offset that keeps
  a sticky box's border box at its insets from the edges of its scroll
  container's scrollport while its containing block is in view, never
  pushing its margin box out of the containing block.

  The builder (Web.Paint.Builder) gathers each sticky box's constraints
  (Web.Paint.DisplayList's TStickyRun). Inside an inner scroll container
  the scroll offset is known when the list is built and the offset is
  applied then; under the viewport it depends on the scroll offset at
  painting time, so painting, hit testing and the web view compute it
  from the run with StickyOffset.
}
unit Web.Paint.Sticky;

{$mode objfpc}
{$H+}

interface

uses
  Web.Paint.DisplayList;

{ The offset of a sticky box whose border box is at (X, Y, Width,
  Height) in the coordinates of the run, with the scrollport at
  (PortX, PortY, PortWidth, PortHeight) in the same coordinates. }
procedure StickyOffset(constref Run: TStickyRun; X, Y, Width, Height: Single; PortX, PortY, PortWidth,
  PortHeight: Single; out OffsetX, OffsetY: Single);

implementation

{ The offset along one axis. }
function AxisOffset(Start, Size, LimitStart, LimitEnd: Single; HasStart, HasEnd: Boolean; InsetStart,
  InsetEnd, PortStart, PortSize: Single): Single;
var
  Wanted: Single;
begin
  Result := 0;
  if HasEnd then
  begin
    { Keep the end edge at least InsetEnd inside the scrollport's end,
      but not above the limit's start. }
    Wanted := (PortStart + PortSize - InsetEnd) - (Start + Size);
    if Wanted < 0 then
    begin
      if Start + Wanted < LimitStart then
        Wanted := LimitStart - Start;
      if Wanted < 0 then
        Result := Wanted;
    end;
  end;
  if HasStart then
  begin
    { The start inset wins over the end one. }
    Wanted := (PortStart + InsetStart) - Start;
    if Wanted > 0 then
    begin
      if Start + Size + Wanted > LimitEnd then
        Wanted := LimitEnd - (Start + Size);
      if Wanted > 0 then
        Result := Wanted;
    end;
  end;
end;

procedure StickyOffset(constref Run: TStickyRun; X, Y, Width, Height: Single; PortX, PortY, PortWidth,
  PortHeight: Single; out OffsetX, OffsetY: Single);
begin
  OffsetX := AxisOffset(X, Width, Run.LimitLeft, Run.LimitRight, Run.HasLeft, Run.HasRight, Run.InsetLeft,
    Run.InsetRight, PortX, PortWidth);
  OffsetY := AxisOffset(Y, Height, Run.LimitTop, Run.LimitBottom, Run.HasTop, Run.HasBottom, Run.InsetTop,
    Run.InsetBottom, PortY, PortHeight);
end;

end.
