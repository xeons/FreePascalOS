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
  The stock icons for files and places besides the document and the
  folder (Controls.Icons): a plain file (a blank page), a program (a
  small window with a gear), a fixed disk (a drive's slab with its
  light), a removable disk (a USB stick), the home folder (a house), the
  computer (a screen on a stand), and the arrow put over a symbolic
  link's icon.

  Each is drawn with shapes on the design grid (Controls.PictureGrid),
  anti-aliased, at any size; small boxes (16 logical units at 100%) get
  a little thicker outlines so they do not fade.
}
unit Controls.FileIcons;

{$mode objfpc}

interface

uses
  Drawing.Rectangles,
  Drawing.Canvas;

procedure DrawBlankPage(const Canvas: TCanvas; const Box: TRectangle);
procedure DrawProgramIcon(const Canvas: TCanvas; const Box: TRectangle);
procedure DrawFixedDisk(const Canvas: TCanvas; const Box: TRectangle);
procedure DrawRemovableDisk(const Canvas: TCanvas; const Box: TRectangle);
procedure DrawHome(const Canvas: TCanvas; const Box: TRectangle);
procedure DrawComputer(const Canvas: TCanvas; const Box: TRectangle);
{ A small curved arrow in a white box at the bottom left of Box: the
  mark of a symbolic link, drawn over the icon of what it points to. }
procedure DrawLinkOverlay(const Canvas: TCanvas; const Box: TRectangle);

implementation

uses
  Drawing.Colors,
  Drawing.Rasterizer,
  Controls.PictureGrid;

const
  OutlineColor = $FF4A4F57;
  PageColor = $FFFFFFFF;
  FoldColor = $FFD5D9DF;
  WindowFaceColor = $FFE4E1DA;
  WindowTitleColor = $FF1F4E79;
  GearColor = $FF6B737D;
  DiskBodyColor = $FFB9BEC6;
  DiskFaceColor = $FF8E959F;
  DiskLightColor = $FF39C25A;
  StickBodyColor = $FF3B73C4;
  StickPlugColor = $FFD5D9DF;
  WallColor = $FFF4EEDF;
  RoofColor = $FFC8553D;
  DoorColor = $FF8A6418;
  ScreenFrameColor = $FF3A4049;
  ScreenColor = $FF5B9BD5;
  StandColor = $FF8E959F;
  ArrowColor = $FF1F4E79;

{ Outlines thick enough to stay visible in a small box. }
function OutlineWidth(const Box: TRectangle): Double;
begin
  if RectangleHeight(Box) < 24 then
    Result := 1.6
  else
    Result := 1;
end;

{ (Outline widths below are in design steps: one step is a pixel in a
  32 pixel box.) }

procedure DrawBlankPage(const Canvas: TCanvas; const Box: TRectangle);
var
  Grid: TPictureGrid;
  Width: Double;
begin
  Grid := GridFor(Box);
  Width := OutlineWidth(Box);
  DrawGridPolygon(Canvas, Grid, [PrecisePoint(6.5, 1.5), PrecisePoint(19.5, 1.5), PrecisePoint(26.5, 8.5),
    PrecisePoint(26.5, 30.5), PrecisePoint(6.5, 30.5)], PageColor, OutlineColor, Width);
  DrawGridPolygon(Canvas, Grid, [PrecisePoint(19.5, 1.5), PrecisePoint(19.5, 8.5), PrecisePoint(26.5, 8.5)],
    FoldColor, OutlineColor, Width);
end;

procedure DrawProgramIcon(const Canvas: TCanvas; const Box: TRectangle);
var
  Grid: TPictureGrid;
  Width: Double;
  Tooth: LongInt;
  Angle: Double;
begin
  Grid := GridFor(Box);
  Width := OutlineWidth(Box);
  { A window: its face and title bar. }
  DrawRoundedBox(Canvas, Grid, 2.5, 4.5, 29.5, 27.5, 1.5, WindowFaceColor, OutlineColor, Width);
  DrawRoundedBox(Canvas, Grid, 3.5, 5.5, 28.5, 10.5, 0.8, WindowTitleColor, ColorTransparent, 0);
  { A gear in it: eight teeth round a disc, a hole in the middle. }
  for Tooth := 0 to 7 do
  begin
    Angle := Tooth * Pi / 4;
    DrawGridLine(Canvas, Grid, 16 + 4 * Cos(Angle), 19 + 4 * Sin(Angle), 16 + 7 * Cos(Angle),
      19 + 7 * Sin(Angle), 2.6, GearColor);
  end;
  DrawGridDisc(Canvas, Grid, 16, 19, 5, GearColor);
  DrawGridDisc(Canvas, Grid, 16, 19, 2, WindowFaceColor);
end;

procedure DrawFixedDisk(const Canvas: TCanvas; const Box: TRectangle);
var
  Grid: TPictureGrid;
  Width: Double;
begin
  Grid := GridFor(Box);
  Width := OutlineWidth(Box);
  { A drive seen from the front and a little above: its top, then its
    face with a light and a slot. }
  DrawGridPolygon(Canvas, Grid, [PrecisePoint(6, 9.5), PrecisePoint(26, 9.5), PrecisePoint(30, 16.5),
    PrecisePoint(2, 16.5)], DiskBodyColor, OutlineColor, Width);
  DrawRoundedBox(Canvas, Grid, 2, 16.5, 30, 24.5, 1.2, DiskFaceColor, OutlineColor, Width);
  DrawGridDisc(Canvas, Grid, 25.5, 20.5, 1.6, DiskLightColor);
  DrawGridLine(Canvas, Grid, 6, 20.5, 17, 20.5, 1.2, OutlineColor);
end;

procedure DrawRemovableDisk(const Canvas: TCanvas; const Box: TRectangle);
var
  Grid: TPictureGrid;
  Width: Double;
begin
  Grid := GridFor(Box);
  Width := OutlineWidth(Box);
  { A USB stick standing up: the metal plug at the top with its two
    windows, the body below with a light. }
  DrawRoundedBox(Canvas, Grid, 11.5, 2.5, 20.5, 10.5, 0.5, StickPlugColor, OutlineColor, Width);
  DrawRoundedBox(Canvas, Grid, 13.2, 4.8, 15.2, 6.8, 0, OutlineColor, ColorTransparent, 0);
  DrawRoundedBox(Canvas, Grid, 16.8, 4.8, 18.8, 6.8, 0, OutlineColor, ColorTransparent, 0);
  DrawRoundedBox(Canvas, Grid, 9, 10.5, 23, 29.5, 2.5, StickBodyColor, OutlineColor, Width);
  DrawGridDisc(Canvas, Grid, 16, 24.5, 1.6, DiskLightColor);
end;

procedure DrawHome(const Canvas: TCanvas; const Box: TRectangle);
var
  Grid: TPictureGrid;
  Width: Double;
begin
  Grid := GridFor(Box);
  Width := OutlineWidth(Box);
  { Walls, a door, and a roof over them. }
  DrawGridPolygon(Canvas, Grid, [PrecisePoint(7, 14), PrecisePoint(25, 14), PrecisePoint(25, 28.5),
    PrecisePoint(7, 28.5)], WallColor, OutlineColor, Width);
  DrawGridPolygon(Canvas, Grid, [PrecisePoint(13.5, 19), PrecisePoint(18.5, 19), PrecisePoint(18.5, 28.5),
    PrecisePoint(13.5, 28.5)], DoorColor, OutlineColor, Width);
  DrawGridPolygon(Canvas, Grid, [PrecisePoint(16, 3), PrecisePoint(30, 15.5), PrecisePoint(2, 15.5)],
    RoofColor, OutlineColor, Width);
end;

procedure DrawComputer(const Canvas: TCanvas; const Box: TRectangle);
var
  Grid: TPictureGrid;
  Width: Double;
begin
  Grid := GridFor(Box);
  Width := OutlineWidth(Box);
  DrawGridPolygon(Canvas, Grid, [PrecisePoint(13, 23), PrecisePoint(19, 23), PrecisePoint(21, 28.5),
    PrecisePoint(11, 28.5)], StandColor, OutlineColor, Width);
  DrawRoundedBox(Canvas, Grid, 2.5, 4.5, 29.5, 23.5, 1.5, ScreenFrameColor, OutlineColor, Width);
  DrawRoundedBox(Canvas, Grid, 5, 7, 27, 21, 0.5, ScreenColor, ColorTransparent, 0);
end;

procedure DrawLinkOverlay(const Canvas: TCanvas; const Box: TRectangle);
var
  Grid: TPictureGrid;
begin
  Grid := GridFor(Box);
  { A white box at the bottom left, an arrow curving up and right in it. }
  DrawRoundedBox(Canvas, Grid, 1, 18, 14, 31, 1.5, PageColor, OutlineColor, 1);
  DrawGridLine(Canvas, Grid, 4.5, 28, 4.5, 24.5, 1.8, ArrowColor);
  DrawGridLine(Canvas, Grid, 4.5, 24.5, 6.5, 22.2, 1.8, ArrowColor);
  DrawGridLine(Canvas, Grid, 6.5, 22.2, 10, 22.2, 1.8, ArrowColor);
  DrawGridPolygon(Canvas, Grid, [PrecisePoint(9.5, 19), PrecisePoint(12.8, 22.2), PrecisePoint(9.5, 25.4)],
    ArrowColor, ColorTransparent, 0);
end;

end.
