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
  The wallpaper: a drawn design behind the desktop's icons.

  A night-blue sky darkening upwards, a pale moon high on the right, and
  three bands of rolling water along the bottom, each a translucent
  shape over the ones behind it, all anti-aliased. It is drawn once for
  a size into a surface of its own, which the desktop window copies
  from whenever it paints (drawing the shapes again for every small
  repaint would be slow).

  WallpaperImagePath names an image to show instead. Reading images
  comes with libimage (step 8); until then the setting is kept but the
  drawn design is always shown.
}
unit Desktop.Wallpaper;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Surfaces;

var
  WallpaperImagePath: string;

{ Surface becomes the wallpaper at Width x Height pixels (the old one is
  freed); False if out of memory. }
function RenderWallpaper(var Surface: TSurface; Width, Height: LongInt): Boolean;

implementation

uses
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Canvas,
  Drawing.Rasterizer,
  Drawing.SmoothShapes;

const
  SkyTopColor = $FF0F2C42;
  SkyBottomColor = $FF3F7E95;
  MoonColor = $38F4F1E6;
  HaloColor = $0CF4F1E6;
  { Points along each wave's crest. }
  WaveSteps = 96;

type
  TWave = record
    { Where its crest runs, as fractions of the height, how far it rises
      and falls, how many crests fit across, and where they start. }
    Level: Double;
    Swell: Double;
    Crests: Double;
    Phase: Double;
    Color: TColor;
  end;

const
  Waves: array[0..2] of TWave = (
    (Level: 0.70; Swell: 0.035; Crests: 1.3; Phase: 0.6; Color: $3C9CC9D8),
    (Level: 0.79; Swell: 0.030; Crests: 2.1; Phase: 2.2; Color: $70204F66),
    (Level: 0.88; Swell: 0.022; Crests: 2.9; Phase: 4.0; Color: $A0102E40));

procedure DrawWave(const Canvas: TCanvas; const Wave: TWave; Width, Height: LongInt);
var
  Points: array[0..WaveSteps + 2] of TPrecisePoint;
  Step: LongInt;
  X: Double;
  Angle: Double;
begin
  for Step := 0 to WaveSteps do
  begin
    X := Width * Step / WaveSteps;
    Angle := Wave.Phase + 2 * Pi * Wave.Crests * Step / WaveSteps;
    Points[Step] := PrecisePoint(X, Height * (Wave.Level + Wave.Swell * Sin(Angle)));
  end;
  Points[WaveSteps + 1] := PrecisePoint(Width, Height);
  Points[WaveSteps + 2] := PrecisePoint(0, Height);
  FillSmoothPolygon(Canvas, Points, Wave.Color);
end;

procedure DrawMoon(const Canvas: TCanvas; Width, Height: LongInt);
var
  Diameter: LongInt;
  CenterX: LongInt;
  CenterY: LongInt;
begin
  Diameter := Height div 6;
  CenterX := Width - Width div 5;
  CenterY := Height div 8 + Diameter div 2;
  { A soft halo, then the moon over it. }
  FillSmoothEllipse(Canvas, MakeRectangle(CenterX - Diameter, CenterY - Diameter, 2 * Diameter, 2 * Diameter),
    HaloColor);
  FillSmoothEllipse(Canvas, MakeRectangle(CenterX - Diameter div 2, CenterY - Diameter div 2, Diameter, Diameter),
    MoonColor);
end;

function RenderWallpaper(var Surface: TSurface; Width, Height: LongInt): Boolean;
var
  Canvas: TCanvas;
  Index: LongInt;
begin
  FreeSurface(Surface);
  Result := CreateSurface(Surface, Width, Height, SkyBottomColor);
  if not Result then
    Exit;
  BeginCanvas(Canvas, Surface);
  FillVerticalGradient(Canvas, SurfaceBounds(Surface), SkyTopColor, SkyBottomColor);
  DrawMoon(Canvas, Width, Height);
  for Index := 0 to High(Waves) do
    DrawWave(Canvas, Waves[Index], Width, Height);
end;

end.
