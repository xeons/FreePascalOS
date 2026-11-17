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
  The image viewer's zoom and pan arithmetic, one axis at a time where
  it can be.

  Zoom is a multiple of the picture's size (1 is 100 %). Zooming in and
  out goes through fixed steps (5 % to 3200 %); fitting picks the
  largest zoom at which the whole picture shows (not above 100 % unless
  allowed). The view is a scrolling panel: the picture is centred while
  it is smaller than the view, else scrolled (a scroll position is the
  content's coordinate at the view's left or top edge, logical units).
  Zooming about a point keeps the picture's spot under that point where
  it was; dragging moves the picture with the pointer.

  Plain logic: the host checks it (make apps-test).
}
unit ImageViewer.ViewGeometry;

{$mode objfpc}
{$H+}

interface

const
  SmallestZoom = 0.05;
  LargestZoom = 32;

{ The next step up or down from Zoom. }
function ZoomedIn(Zoom: Double): Double;
function ZoomedOut(Zoom: Double): Double;
function ClampZoom(Zoom: Double): Double;
{ The zoom at which a picture fits the view (1 at most unless
  Enlarge); 1 for an empty picture or view. }
function FitZoom(PictureWidth, PictureHeight, ViewWidth, ViewHeight: LongInt; Enlarge: Boolean): Double;
{ The picture's extent at Zoom (at least 1). }
function ZoomedExtent(Extent: LongInt; Zoom: Double): LongInt;
{ Where the picture starts in the view: centred when smaller, else 0. }
function CentringOffset(Content, View: LongInt): LongInt;
{ Scroll kept within 0 and what the content leaves beyond the view. }
function ClampScroll(Scroll, Content, View: LongInt): LongInt;
{ The scroll position after the content changes from OldContent to
  NewContent (a zoom) that keeps the content's spot at Point (view
  coordinates) at Point. }
function ScrollKeepingPoint(OldScroll, Point, OldContent, NewContent, View: LongInt): LongInt;
{ The scroll position for a drag that started at StartPointer with the
  view scrolled to StartScroll and is now at Pointer. }
function DraggedScroll(StartScroll, StartPointer, Pointer, Content, View: LongInt): LongInt;
{ "100%", "12.5%", "3200%". }
function ZoomPercentText(Zoom: Double): string;

implementation

uses
  SysUtils,
  Math;

const
  ZoomSteps: array[0..21] of Double = (0.05, 0.0625, 0.0833333333333333, 0.1, 0.125, 0.166666666666667, 0.25,
    0.333333333333333, 0.5, 0.666666666666667, 1, 1.5, 2, 3, 4, 5, 6, 8, 12, 16, 24, 32);
  { Steps nearer than this share count as the same zoom. }
  StepTolerance = 1.001;

function ClampZoom(Zoom: Double): Double;
begin
  Result := Min(LargestZoom, Max(SmallestZoom, Zoom));
end;

function ZoomedIn(Zoom: Double): Double;
var
  Index: LongInt;
begin
  for Index := Low(ZoomSteps) to High(ZoomSteps) do
    if ZoomSteps[Index] > Zoom * StepTolerance then
      Exit(ZoomSteps[Index]);
  Result := LargestZoom;
end;

function ZoomedOut(Zoom: Double): Double;
var
  Index: LongInt;
begin
  Index := High(ZoomSteps);
  while Index >= Low(ZoomSteps) do
  begin
    if ZoomSteps[Index] * StepTolerance < Zoom then
      Exit(ZoomSteps[Index]);
    Dec(Index);
  end;
  Result := SmallestZoom;
end;

function FitZoom(PictureWidth, PictureHeight, ViewWidth, ViewHeight: LongInt; Enlarge: Boolean): Double;
begin
  if (PictureWidth <= 0) or (PictureHeight <= 0) or (ViewWidth <= 0) or (ViewHeight <= 0) then
    Exit(1);
  Result := Min(ViewWidth / PictureWidth, ViewHeight / PictureHeight);
  if not Enlarge then
    Result := Min(1, Result);
  Result := ClampZoom(Result);
end;

function ZoomedExtent(Extent: LongInt; Zoom: Double): LongInt;
begin
  Result := Max(1, Round(Extent * Zoom));
end;

function CentringOffset(Content, View: LongInt): LongInt;
begin
  Result := Max(0, (View - Content) div 2);
end;

function ClampScroll(Scroll, Content, View: LongInt): LongInt;
begin
  Result := Max(0, Min(Scroll, Content - View));
end;

function ScrollKeepingPoint(OldScroll, Point, OldContent, NewContent, View: LongInt): LongInt;
var
  Spot: Double;
  NewSpot: Double;
begin
  if OldContent <= 0 then
    Exit(0);
  { The content's coordinate under Point, as a share of the content. }
  Spot := (OldScroll + Point - CentringOffset(OldContent, View)) / OldContent;
  Spot := Max(0, Min(1, Spot));
  NewSpot := Spot * NewContent;
  Result := ClampScroll(Round(NewSpot + CentringOffset(NewContent, View) - Point), NewContent, View);
end;

function DraggedScroll(StartScroll, StartPointer, Pointer, Content, View: LongInt): LongInt;
begin
  Result := ClampScroll(StartScroll - (Pointer - StartPointer), Content, View);
end;

function ZoomPercentText(Zoom: Double): string;
var
  Percent: Double;
begin
  Percent := Zoom * 100;
  if Abs(Percent - Round(Percent)) < 0.05 then
    Result := IntToStr(Round(Percent)) + '%'
  else
    Result := FormatFloat('0.#', Percent) + '%';
end;

end.
