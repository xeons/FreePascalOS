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
  The page zoom levels Ctrl+plus and Ctrl+minus step through (the
  usual browsers' steps, 30 % to 300 %), and the scale a page is drawn
  at: the display's scale (device pixels per logical unit, a CSS pixel
  at 100 %) times the zoom.
}
unit WebView.Zoom;

{$mode objfpc}
{$H+}

interface

const
  MinimumZoom = 0.3;
  MaximumZoom = 3.0;

function ZoomedIn(Zoom: Double): Double;
function ZoomedOut(Zoom: Double): Double;
function ClampZoom(Zoom: Double): Double;
{ Device pixels per CSS pixel: DisplayPixelsPerUnit (the window's scale)
  times Zoom. }
function DeviceScaleFor(DisplayPixelsPerUnit, Zoom: Double): Double;
{ "125%". }
function ZoomText(Zoom: Double): string;

implementation

uses
  SysUtils;

const
  ZoomSteps: array[0..13] of Double = (0.3, 0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0);

function ClampZoom(Zoom: Double): Double;
begin
  Result := Zoom;
  if Result < MinimumZoom then
    Result := MinimumZoom;
  if Result > MaximumZoom then
    Result := MaximumZoom;
end;

function ZoomedIn(Zoom: Double): Double;
var
  Index: Integer;
begin
  for Index := Low(ZoomSteps) to High(ZoomSteps) do
    if ZoomSteps[Index] > Zoom + 0.001 then
      Exit(ZoomSteps[Index]);
  Result := MaximumZoom;
end;

function ZoomedOut(Zoom: Double): Double;
var
  Index: Integer;
begin
  for Index := High(ZoomSteps) downto Low(ZoomSteps) do
    if ZoomSteps[Index] < Zoom - 0.001 then
      Exit(ZoomSteps[Index]);
  Result := MinimumZoom;
end;

function DeviceScaleFor(DisplayPixelsPerUnit, Zoom: Double): Double;
begin
  Result := DisplayPixelsPerUnit * ClampZoom(Zoom);
  if Result <= 0 then
    Result := 1;
end;

function ZoomText(Zoom: Double): string;
begin
  Result := IntToStr(Round(Zoom * 100)) + '%';
end;

end.
