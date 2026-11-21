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
  Drawing a display list with libdrawing.

  The surface shows the viewport: a CSS pixel point (X, Y) of the
  document is drawn at ((X - ScrollX) * Scale, (Y - ScrollY) * Scale)
  device pixels (fixed items ignore the scroll). Only the damaged
  rectangle is drawn: the canvas is cleared to the canvas color there
  and every item outside it is skipped, so a web view can repaint what
  changed or what scrolled into view.

  Rectangles, rounded rectangles and borders are drawn with coverage
  (anti-aliased) shapes; text glyph by glyph from libfont's glyph cache
  at the device pixel size, placed at the positions layout measured;
  images scaled (and tiled for backgrounds); gradients pixel by pixel;
  box shadows as a blurred coverage mask. Clips narrow the canvas's
  clip region (rounded clips are clipped to their rectangle); an
  opacity group is drawn on a transparent surface and composited.
}
unit Web.Paint.Raster;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Surfaces, Drawing.Rectangles, Web.Paint.DisplayList;

type
  TRasterView = record
    { CSS px of the viewport's top left in the document. }
    ScrollX, ScrollY: Single;
    { Device pixels per CSS pixel. }
    Scale: Single;
    { The part of the surface to draw (device pixels). }
    Damage: TRectangle;
  end;

procedure RasterizeDisplayList(List: TDisplayList; const Surface: TSurface; const View: TRasterView);

var
  { Draw glyphs hinted (sharper at small sizes). }
  WebTextHinting: Boolean = True;

implementation

uses
  Math, SysUtils, Drawing.Colors, Drawing.Canvas, Drawing.Regions, Drawing.Rasterizer, Drawing.SmoothRoundedRectangles,
  Drawing.CoverageBlending, Drawing.Scaling, Drawing.SmoothShapes, Css.Keywords, Font.Outlines,
  Font.GlyphCache, Image.Model, Image.Surfaces, Image.Scalable, Web.Layout.Boxes, Web.Layout.TreeBuilder, Web.Text.Fonts,
  Web.Text.FontInstances, Web.Paint.Gradients;

type
  TGroup = record
    Canvas: TCanvas;
    Surface: TSurface;
    Opacity: Byte;
  end;

  { A rounded clip: what is drawn inside goes to a group composited
    through the clip's coverage. }
  TRoundedClip = record
    Active: Boolean;
    Shape: TCoverageShape;
  end;

  TRaster = record
    List: TDisplayList;
    RoundedClips: array of TRoundedClip;
    View: TRasterView;
    Canvas: TCanvas;
    ClipStack: array of TRegion;
    ClipDepth: Integer;
    Groups: array of TGroup;
    GroupDepth: Integer;
    FixedDepth: Integer;
    Glyphs: TPlacedGlyphArray;
  end;

function EdgesRectangle(Left, Top, Right, Bottom: LongInt): TRectangle;
begin
  Result.Left := Left;
  Result.Top := Top;
  Result.Right := Right;
  Result.Bottom := Bottom;
end;

function DeviceX(const Raster: TRaster; X: Single): Double; inline;
begin
  if Raster.FixedDepth > 0 then
    Result := X * Raster.View.Scale
  else
    Result := (X - Raster.View.ScrollX) * Raster.View.Scale;
end;

function DeviceY(const Raster: TRaster; Y: Single): Double; inline;
begin
  if Raster.FixedDepth > 0 then
    Result := Y * Raster.View.Scale
  else
    Result := (Y - Raster.View.ScrollY) * Raster.View.Scale;
end;

function DeviceRectangle(const Raster: TRaster; X, Y, Width, Height: Single): TRectangle;
begin
  Result.Left := Floor(DeviceX(Raster, X) + 0.5);
  Result.Top := Floor(DeviceY(Raster, Y) + 0.5);
  Result.Right := Floor(DeviceX(Raster, X + Width) + 0.5);
  Result.Bottom := Floor(DeviceY(Raster, Y + Height) + 0.5);
end;

function ItemVisible(const Raster: TRaster; const Item: TDisplayItem): Boolean;
var
  Bounds, Common: TRectangle;
begin
  Bounds := DeviceRectangle(Raster, Item.X, Item.Y, Item.Width, Item.Height);
  Bounds := InflateRectangle(Bounds, 2);
  Result := IntersectRectangles(Bounds, RegionBounds(Raster.Canvas.Clip), Common);
end;

function ScaledRadii(const Raster: TRaster; const Radii: TCornerRadii): TCornerRadii;
var
  Corner: Integer;
begin
  for Corner := 0 to 3 do
  begin
    Result[Corner].X := Radii[Corner].X * Raster.View.Scale;
    Result[Corner].Y := Radii[Corner].Y * Raster.View.Scale;
  end;
end;

procedure FillBox(var Raster: TRaster; X, Y, Width, Height: Single; Color: TColor; RadiiIndex: Integer);
var
  Shape: TCoverageShape;
begin
  if (Width <= 0) or (Height <= 0) or (AlphaOf(Color) = 0) then
    Exit;
  if RadiiIndex < 0 then
  begin
    FillRectangle(Raster.Canvas, DeviceRectangle(Raster, X, Y, Width, Height), Color);
    Exit;
  end;
  BeginShape(Shape);
  AddShapeRoundedRectangleCorners(Shape, DeviceX(Raster, X), DeviceY(Raster, Y), DeviceX(Raster, X + Width),
    DeviceY(Raster, Y + Height), ScaledRadii(Raster, Raster.List.Radii[RadiiIndex]), True);
  FillShape(Raster.Canvas, Shape, Color);
end;

{ ---- borders ---- }

function Shade(Color: TColor; Factor: Single): TColor;
begin
  Result := ArgbColor(AlphaOf(Color), Round(EnsureRange(RedOf(Color) * Factor, 0, 255)),
    Round(EnsureRange(GreenOf(Color) * Factor, 0, 255)), Round(EnsureRange(BlueOf(Color) * Factor, 0, 255)));
end;

{ The color of a side for the 3D styles (side 0 top ... 3 left). }
function SideColor(Style: TCssKeyword; Color: TColor; Side: Integer; Outer: Boolean): TColor;
var
  TopLeft: Boolean;
begin
  Result := Color;
  TopLeft := (Side = 0) or (Side = 3);
  case Style of
    kwInset:
      if TopLeft then
        Result := Shade(Color, 0.6);
    kwOutset:
      if not TopLeft then
        Result := Shade(Color, 0.6);
    kwGroove:
      if TopLeft = Outer then
        Result := Shade(Color, 0.6);
    kwRidge:
      if TopLeft <> Outer then
        Result := Shade(Color, 0.6);
  end;
end;

{ One side as a trapezoid between the outer and inner edges, from
  fraction From to To of the side's thickness. }
procedure FillSide(var Raster: TRaster; Side: Integer; Left, Top, Right, Bottom: Double;
  const Widths: array of Double; FromPart, ToPart: Double; Color: TColor);
var
  Points: array[0..3] of TPrecisePoint;
  OuterLeft, OuterTop, OuterRight, OuterBottom, InnerLeft, InnerTop, InnerRight, InnerBottom: Double;
begin
  if AlphaOf(Color) = 0 then
    Exit;
  OuterLeft := Left + Widths[3] * FromPart;
  OuterTop := Top + Widths[0] * FromPart;
  OuterRight := Right - Widths[1] * FromPart;
  OuterBottom := Bottom - Widths[2] * FromPart;
  InnerLeft := Left + Widths[3] * ToPart;
  InnerTop := Top + Widths[0] * ToPart;
  InnerRight := Right - Widths[1] * ToPart;
  InnerBottom := Bottom - Widths[2] * ToPart;
  case Side of
    0:
      begin
        Points[0] := PrecisePoint(OuterLeft, OuterTop);
        Points[1] := PrecisePoint(OuterRight, OuterTop);
        Points[2] := PrecisePoint(InnerRight, InnerTop);
        Points[3] := PrecisePoint(InnerLeft, InnerTop);
      end;
    1:
      begin
        Points[0] := PrecisePoint(OuterRight, OuterTop);
        Points[1] := PrecisePoint(OuterRight, OuterBottom);
        Points[2] := PrecisePoint(InnerRight, InnerBottom);
        Points[3] := PrecisePoint(InnerRight, InnerTop);
      end;
    2:
      begin
        Points[0] := PrecisePoint(OuterRight, OuterBottom);
        Points[1] := PrecisePoint(OuterLeft, OuterBottom);
        Points[2] := PrecisePoint(InnerLeft, InnerBottom);
        Points[3] := PrecisePoint(InnerRight, InnerBottom);
      end;
  else
    begin
      Points[0] := PrecisePoint(OuterLeft, OuterBottom);
      Points[1] := PrecisePoint(OuterLeft, OuterTop);
      Points[2] := PrecisePoint(InnerLeft, InnerTop);
      Points[3] := PrecisePoint(InnerLeft, InnerBottom);
    end;
  end;
  FillSmoothPolygon(Raster.Canvas, Points, Color);
end;

{ dashes or dots along a side. }
procedure DashSide(var Raster: TRaster; Side: Integer; Left, Top, Right, Bottom: Double; const Widths: array of Double;
  Dotted: Boolean; Color: TColor);
var
  Thickness, Length, Dash, Gap, Position, Start: Double;
  Count, Index: Integer;
  Area: TRectangle;
  Bounds: TRectangle;
  Horizontal: Boolean;
begin
  Thickness := Widths[Side];
  if Thickness <= 0 then
    Exit;
  Horizontal := (Side = 0) or (Side = 2);
  if Horizontal then
    Length := Right - Left
  else
    Length := Bottom - Top;
  if Dotted then
    Dash := Thickness
  else
    Dash := Thickness * 3;
  Gap := Dash;
  Count := Max(1, Round((Length + Gap) / (Dash + Gap)));
  { Spread so that both ends get a full dash. }
  if Count > 1 then
    Gap := (Length - Count * Dash) / (Count - 1);
  for Index := 0 to Count - 1 do
  begin
    Position := Index * (Dash + Gap);
    if Horizontal then
    begin
      Start := Left + Position;
      if Side = 0 then
        Bounds := EdgesRectangle(Floor(Start), Floor(Top), Ceil(Start + Dash), Floor(Top + Thickness + 0.5))
      else
        Bounds := EdgesRectangle(Floor(Start), Floor(Bottom - Thickness + 0.5), Ceil(Start + Dash), Floor(Bottom + 0.5));
    end
    else
    begin
      Start := Top + Position;
      if Side = 3 then
        Bounds := EdgesRectangle(Floor(Left), Floor(Start), Floor(Left + Thickness + 0.5), Ceil(Start + Dash))
      else
        Bounds := EdgesRectangle(Floor(Right - Thickness + 0.5), Floor(Start), Floor(Right + 0.5), Ceil(Start + Dash));
    end;
    if Dotted and (Thickness >= 3) then
      FillSmoothEllipse(Raster.Canvas, Bounds, Color)
    else
      FillRectangle(Raster.Canvas, Bounds, Color);
  end;
  Area := Bounds;
end;

procedure DrawBorder(var Raster: TRaster; const Item: TDisplayItem);
var
  Sides: TBorderSides;
  Widths: array[0..3] of Double;
  Left, Top, Right, Bottom: Double;
  Side: Integer;
  Same: Boolean;
  Shape: TCoverageShape;
  Outer, Inner: TCornerRadii;
  Style: TCssKeyword;
  Color: TColor;
begin
  Sides := Raster.List.Borders[Item.Index];
  Left := DeviceX(Raster, Item.X);
  Top := DeviceY(Raster, Item.Y);
  Right := DeviceX(Raster, Item.X + Item.Width);
  Bottom := DeviceY(Raster, Item.Y + Item.Height);
  for Side := 0 to 3 do
  begin
    Widths[Side] := Sides.Widths[Side] * Raster.View.Scale;
    if KeywordIn(Sides.Styles[Side], [kwNone, kwHidden]) then
      Widths[Side] := 0;
  end;
  if Sides.Radii >= 0 then
  begin
    { A ring between the rounded outer and inner edges, in the top color
      (each side its own color when they differ, split at the corners). }
    Outer := ScaledRadii(Raster, Raster.List.Radii[Sides.Radii]);
    Inner := Outer;
    Inner[0].X := Max(0, Outer[0].X - Widths[3]);
    Inner[0].Y := Max(0, Outer[0].Y - Widths[0]);
    Inner[1].X := Max(0, Outer[1].X - Widths[1]);
    Inner[1].Y := Max(0, Outer[1].Y - Widths[0]);
    Inner[2].X := Max(0, Outer[2].X - Widths[1]);
    Inner[2].Y := Max(0, Outer[2].Y - Widths[2]);
    Inner[3].X := Max(0, Outer[3].X - Widths[3]);
    Inner[3].Y := Max(0, Outer[3].Y - Widths[2]);
    Color := Sides.Colors[0];
    if Widths[0] = 0 then
      Color := Sides.Colors[3];
    BeginShape(Shape);
    AddShapeRoundedRectangleCorners(Shape, Left, Top, Right, Bottom, Outer, True);
    AddShapeRoundedRectangleCorners(Shape, Left + Widths[3], Top + Widths[0], Right - Widths[1], Bottom - Widths[2],
      Inner, False);
    FillShape(Raster.Canvas, Shape, Color);
    Exit;
  end;
  Same := True;
  for Side := 1 to 3 do
    if (Sides.Colors[Side] <> Sides.Colors[0]) or (Sides.Styles[Side] <> Sides.Styles[0]) or (Widths[Side] = 0) then
      Same := False;
  if Same and (Sides.Styles[0] = kwSolid) and (Widths[0] > 0) then
  begin
    BeginShape(Shape);
    AddShapeRoundedRectangleCorners(Shape, Left, Top, Right, Bottom, Default(TCornerRadii), True);
    AddShapeRoundedRectangleCorners(Shape, Left + Widths[3], Top + Widths[0], Right - Widths[1], Bottom - Widths[2],
      Default(TCornerRadii), False);
    FillShape(Raster.Canvas, Shape, Sides.Colors[0]);
    Exit;
  end;
  for Side := 0 to 3 do
  begin
    if Widths[Side] <= 0 then
      Continue;
    Style := Sides.Styles[Side];
    Color := Sides.Colors[Side];
    case Style of
      kwDashed, kwDotted:
        DashSide(Raster, Side, Left, Top, Right, Bottom, Widths, Style = kwDotted, Color);
      kwDouble:
        begin
          FillSide(Raster, Side, Left, Top, Right, Bottom, Widths, 0, 1 / 3, Color);
          FillSide(Raster, Side, Left, Top, Right, Bottom, Widths, 2 / 3, 1, Color);
        end;
      kwGroove, kwRidge:
        begin
          FillSide(Raster, Side, Left, Top, Right, Bottom, Widths, 0, 0.5, SideColor(Style, Color, Side, True));
          FillSide(Raster, Side, Left, Top, Right, Bottom, Widths, 0.5, 1, SideColor(Style, Color, Side, False));
        end;
    else
      FillSide(Raster, Side, Left, Top, Right, Bottom, Widths, 0, 1, SideColor(Style, Color, Side, True));
    end;
  end;
end;

{ ---- text ---- }

{ Bold draws the glyph twice a pixel apart (a synthetic bold); Slant
  shears it, rows above the baseline moved right (a synthetic oblique). }
procedure DrawGlyph(var Raster: TRaster; Font: TOutlineFont; PixelSize: Integer; Glyph: LongWord; PenX, BaselineY: Double;
  Color: TColor; Bold: Boolean; Slant: Double = 0);
var
  Quarters, Whole, Row, BaselinePixel, Shift: LongInt;
  Bitmap: PGlyphBitmap;
begin
  Quarters := Floor(PenX * SubpixelSteps + 0.5);
  Whole := Floor(Quarters / SubpixelSteps);
  Bitmap := CachedGlyph(Font, PixelSize, Glyph, Quarters - SubpixelSteps * Whole, WebTextHinting);
  if (Bitmap = nil) or (Bitmap^.Width = 0) then
    Exit;
  BaselinePixel := Floor(BaselineY + 0.5);
  for Row := 0 to Bitmap^.Height - 1 do
  begin
    Shift := Round(-(Bitmap^.Top + Row) * Slant);
    BlendCoverageSpan(Raster.Canvas, BaselinePixel + Bitmap^.Top + Row, Whole + Bitmap^.Left + Shift,
      @Bitmap^.Coverage[Row * Bitmap^.Width], Bitmap^.Width, Color);
    if Bold then
      BlendCoverageSpan(Raster.Canvas, BaselinePixel + Bitmap^.Top + Row, Whole + Bitmap^.Left + 1 + Shift,
        @Bitmap^.Coverage[Row * Bitmap^.Width], Bitmap^.Width, Color);
  end;
end;

procedure DrawText(var Raster: TRaster; const Item: TDisplayItem);
var
  Run: TTextRun;
  Count, Index, PixelSize, Spaces, Characters: Integer;
  Baseline, StartX, PenX, Slant: Double;
  Font: TOutlineFont;
begin
  Run := Raster.List.Texts[Item.Index];
  Slant := 0;
  if Run.Font.SyntheticItalic then
    Slant := 0.2;
  Run.Font.PlaceGlyphs(Run.Box.Text, Run.TextStart, Run.TextLength, Raster.Glyphs, Count);
  PixelSize := Max(1, Round(Run.Font.Size * Raster.View.Scale));
  Baseline := DeviceY(Raster, Run.Baseline);
  StartX := Item.X;
  Spaces := 0;
  Characters := 0;
  for Index := 0 to Count - 1 do
  begin
    PenX := DeviceX(Raster, StartX + Raster.Glyphs[Index].X + Spaces * Run.SpaceExtra + Characters * Run.LetterExtra);
    Font := Raster.Glyphs[Index].Face.Font;
    if Font <> nil then
      DrawGlyph(Raster, Font, PixelSize, Raster.Glyphs[Index].Glyph, PenX, Baseline, Item.Color,
        Run.Font.SyntheticBold, Slant);
    if Raster.Glyphs[Index].CodePoint = 32 then
      Inc(Spaces);
    Inc(Characters);
  end;
end;

{ ---- images ---- }

procedure DrawImage(var Raster: TRaster; const Item: TDisplayItem);
const
  { 4096 x 4096: larger images are scaled from their own pixels. }
  MaximumVectorRenderingPixels = 16 * 1024 * 1024;
var
  Rendered: TImage;
  Run: TImageRun;
  Source: TSurface;
  SourceRectangle, Destination, Area, Common: TRectangle;
  Saved: TRegion;
  TileX, TileY, StartX, StartY, EndX, EndY: Single;
  Guard: Integer;
begin
  Run := Raster.List.Images[Item.Index];
  if (Run.Image = nil) or (Run.TileWidth <= 0) or (Run.TileHeight <= 0) then
    Exit;
  Source := ImageSurface(Run.Image);
  SourceRectangle := MakeRectangle(0, 0, Run.Image.Width, Run.Image.Height);
  Area := DeviceRectangle(Raster, Item.X, Item.Y, Item.Width, Item.Height);
  CopyRegion(Raster.Canvas.Clip, Saved);
  IntersectRegionWithRectangle(Raster.Canvas.Clip, Area);
  try
    if RegionIsEmpty(Raster.Canvas.Clip) then
      Exit;
    StartX := Run.TileX;
    StartY := Run.TileY;
    EndX := Run.TileX + Run.TileWidth;
    EndY := Run.TileY + Run.TileHeight;
    if Run.RepeatX then
    begin
      StartX := Run.TileX - Ceil((Run.TileX - Item.X) / Run.TileWidth) * Run.TileWidth;
      EndX := Item.X + Item.Width;
    end;
    if Run.RepeatY then
    begin
      StartY := Run.TileY - Ceil((Run.TileY - Item.Y) / Run.TileHeight) * Run.TileHeight;
      EndY := Item.Y + Item.Height;
    end;
    Guard := 0;
    TileY := StartY;
    while (TileY < EndY - 0.01) and (Guard < 100000) do
    begin
      TileX := StartX;
      while (TileX < EndX - 0.01) and (Guard < 100000) do
      begin
        Destination := DeviceRectangle(Raster, TileX, TileY, Run.TileWidth, Run.TileHeight);
        if IntersectRectangles(Destination, RegionBounds(Raster.Canvas.Clip), Common) then
        begin
          { A vector image (SVG) is drawn again at the size shown. }
          Rendered := nil;
          if (Run.Image is TScalableImage) and not Run.Pixelated and
             (Int64(RectangleWidth(Destination)) * RectangleHeight(Destination) <= MaximumVectorRenderingPixels) then
            Rendered := TScalableImage(Run.Image).RenderedAt(RectangleWidth(Destination), RectangleHeight(Destination));
          if Rendered <> nil then
            DrawSurface(Raster.Canvas, ImageSurface(Rendered), MakeRectangle(0, 0, Rendered.Width, Rendered.Height),
              Destination.Left, Destination.Top, True, 255)
          else if (RectangleWidth(Destination) = Run.Image.Width) and (RectangleHeight(Destination) = Run.Image.Height) then
            DrawSurface(Raster.Canvas, Source, SourceRectangle, Destination.Left, Destination.Top, True, 255)
          else if Run.Pixelated then
            DrawSurfaceStretched(Raster.Canvas, Source, SourceRectangle, Destination, True)
          else
            DrawSurfaceScaled(Raster.Canvas, Source, SourceRectangle, Destination, True);
        end;
        TileX := TileX + Run.TileWidth;
        Inc(Guard);
      end;
      TileY := TileY + Run.TileHeight;
    end;
  finally
    Raster.Canvas.Clip := Saved;
  end;
end;

{ ---- gradients ---- }

procedure BlendRow(const Canvas: TCanvas; Y, Left: LongInt; const Colors: array of TColor; Count: LongInt);
var
  Index, Start, Finish, X: LongInt;
  Piece: TRectangle;
  Line: PLongWord;
begin
  Line := SurfaceLine(Canvas.Surface, Y);
  for Index := 0 to Canvas.Clip.Count - 1 do
  begin
    Piece := Canvas.Clip.Rectangles[Index];
    if (Y < Piece.Top) or (Y >= Piece.Bottom) then
      Continue;
    Start := Max(Left, Piece.Left);
    Finish := Min(Left + Count, Piece.Right);
    for X := Start to Finish - 1 do
      Line[X] := BlendColors(Line[X], Colors[X - Left]);
  end;
end;

procedure DrawGradient(var Raster: TRaster; const Item: TDisplayItem);
var
  Run: TGradientRun;
  Prepared: TPreparedGradient;
  Area, Bounds: TRectangle;
  Row, Column: LongInt;
  Colors: array of TColor;
  BoxLeft, BoxTop, TileWidth, TileHeight, PointX, PointY: Double;
  Repeating: Boolean;
begin
  Run := Raster.List.Gradients[Item.Index];
  BoxLeft := DeviceX(Raster, Run.BoxX);
  BoxTop := DeviceY(Raster, Run.BoxY);
  TileWidth := Run.BoxWidth * Raster.View.Scale;
  TileHeight := Run.BoxHeight * Raster.View.Scale;
  if (TileWidth <= 0) or (TileHeight <= 0) then
    Exit;
  if not PrepareGradient(Run.Gradient, 0, 0, TileWidth, TileHeight, Run.CurrentColor, Prepared) then
    Exit;
  Repeating := Item.Value > 0;
  Area := DeviceRectangle(Raster, Item.X, Item.Y, Item.Width, Item.Height);
  if not IntersectRectangles(Area, RegionBounds(Raster.Canvas.Clip), Bounds) then
    Exit;
  Colors := nil;
  SetLength(Colors, RectangleWidth(Bounds));
  for Row := Bounds.Top to Bounds.Bottom - 1 do
  begin
    PointY := Row + 0.5 - BoxTop;
    if Repeating then
      PointY := PointY - TileHeight * Floor(PointY / TileHeight);
    for Column := Bounds.Left to Bounds.Right - 1 do
    begin
      PointX := Column + 0.5 - BoxLeft;
      if Repeating then
        PointX := PointX - TileWidth * Floor(PointX / TileWidth);
      Colors[Column - Bounds.Left] := GradientColorAt(Prepared, PointX, PointY);
    end;
    BlendRow(Raster.Canvas, Row, Bounds.Left, Colors, RectangleWidth(Bounds));
  end;
end;

{ ---- shadows ---- }

procedure BoxBlur(var Mask: array of Byte; Width, Height, Radius: LongInt);
var
  Temporary: array of Byte;
  X, Y, Sum, Count, Pass: LongInt;
begin
  if Radius <= 0 then
    Exit;
  Temporary := nil;
  SetLength(Temporary, Width * Height);
  for Pass := 1 to 3 do
  begin
    for Y := 0 to Height - 1 do
    begin
      Sum := 0;
      Count := 0;
      for X := -Radius to Radius do
        if (X >= 0) and (X < Width) then
        begin
          Inc(Sum, Mask[Y * Width + X]);
          Inc(Count);
        end;
      for X := 0 to Width - 1 do
      begin
        Temporary[Y * Width + X] := Sum div (2 * Radius + 1);
        if X - Radius >= 0 then
          Dec(Sum, Mask[Y * Width + X - Radius]);
        if X + Radius + 1 < Width then
          Inc(Sum, Mask[Y * Width + X + Radius + 1]);
      end;
    end;
    for X := 0 to Width - 1 do
    begin
      Sum := 0;
      for Y := -Radius to Radius do
        if (Y >= 0) and (Y < Height) then
          Inc(Sum, Temporary[Y * Width + X]);
      for Y := 0 to Height - 1 do
      begin
        Mask[Y * Width + X] := Sum div (2 * Radius + 1);
        if Y - Radius >= 0 then
          Dec(Sum, Temporary[(Y - Radius) * Width + X]);
        if Y + Radius + 1 < Height then
          Inc(Sum, Temporary[(Y + Radius + 1) * Width + X]);
      end;
    end;
  end;
  if Count = 0 then;
end;

procedure DrawShadow(var Raster: TRaster; const Item: TDisplayItem);
var
  Run: TShadowRun;
  Shape, BoxShape: TCoverageShape;
  Area, Bounds: TRectangle;
  Mask, BoxMask: array of Byte;
  Radii, ShadowRadii: TCornerRadii;
  Left, Top, Right, Bottom, Spread, Blur: Double;
  Width, Height, Row, Index, Corner: LongInt;
  Coverage: Byte;
  Margin: LongInt;
begin
  Run := Raster.List.Shadows[Item.Index];
  Spread := Run.Spread * Raster.View.Scale;
  Blur := Run.Blur * Raster.View.Scale;
  FillChar(Radii, SizeOf(Radii), 0);
  if Run.Radii >= 0 then
    Radii := ScaledRadii(Raster, Raster.List.Radii[Run.Radii]);
  Margin := Ceil(Blur) + 2;
  Area := DeviceRectangle(Raster, Item.X, Item.Y, Item.Width, Item.Height);
  Area := InflateRectangle(Area, Margin);
  if not IntersectRectangles(Area, RegionBounds(Raster.Canvas.Clip), Bounds) then
    Exit;
  Width := RectangleWidth(Area);
  Height := RectangleHeight(Area);
  if (Width <= 0) or (Height <= 0) or (Int64(Width) * Height > 16 * 1024 * 1024) then
    Exit;
  Left := DeviceX(Raster, Run.BoxX);
  Top := DeviceY(Raster, Run.BoxY);
  Right := DeviceX(Raster, Run.BoxX + Run.BoxWidth);
  Bottom := DeviceY(Raster, Run.BoxY + Run.BoxHeight);
  ShadowRadii := Radii;
  for Corner := 0 to 3 do
  begin
    ShadowRadii[Corner].X := Max(0, Radii[Corner].X + Spread);
    ShadowRadii[Corner].Y := Max(0, Radii[Corner].Y + Spread);
  end;
  BeginShape(Shape);
  BeginShape(BoxShape);
  AddShapeRoundedRectangleCorners(BoxShape, Left, Top, Right, Bottom, Radii, True);
  Mask := nil;
  SetLength(Mask, Width * Height);
  BoxMask := nil;
  SetLength(BoxMask, Width * Height);
  ShapeCoverage(BoxShape, Area, BoxMask);
  if Run.Inset then
  begin
    { The box minus the shadow's shape inside it. }
    AddShapeRoundedRectangleCorners(Shape, Area.Left - Margin, Area.Top - Margin, Area.Right + Margin,
      Area.Bottom + Margin, Default(TCornerRadii), True);
    AddShapeRoundedRectangleCorners(Shape, Left + Run.OffsetX * Raster.View.Scale + Spread,
      Top + Run.OffsetY * Raster.View.Scale + Spread, Right + Run.OffsetX * Raster.View.Scale - Spread,
      Bottom + Run.OffsetY * Raster.View.Scale - Spread, Radii, False);
  end
  else
    AddShapeRoundedRectangleCorners(Shape, Left + Run.OffsetX * Raster.View.Scale - Spread,
      Top + Run.OffsetY * Raster.View.Scale - Spread, Right + Run.OffsetX * Raster.View.Scale + Spread,
      Bottom + Run.OffsetY * Raster.View.Scale + Spread, ShadowRadii, True);
  ShapeCoverage(Shape, Area, Mask);
  BoxBlur(Mask, Width, Height, Round(Blur / 2));
  for Index := 0 to Width * Height - 1 do
    if Run.Inset then
      Mask[Index] := (LongWord(Mask[Index]) * BoxMask[Index]) div 255
    else
      Mask[Index] := (LongWord(Mask[Index]) * (255 - BoxMask[Index])) div 255;
  for Row := 0 to Height - 1 do
    BlendCoverageSpan(Raster.Canvas, Area.Top + Row, Area.Left, @Mask[Row * Width], Width, Item.Color);
  if Coverage = 0 then;
end;

{ ---- controls ---- }

procedure DrawControl(var Raster: TRaster; const Item: TDisplayItem);
var
  Bounds, Inner: TRectangle;
  Checked: Boolean;
  Points: array[0..2] of TPrecisePoint;
  Size: Double;
begin
  Bounds := DeviceRectangle(Raster, Item.X, Item.Y, Item.Width, Item.Height);
  Checked := Item.Value > 0;
  Size := RectangleWidth(Bounds);
  case Item.Index of
    ControlCheckbox:
      begin
        FillRectangle(Raster.Canvas, Bounds, ColorWhite);
        DrawSmoothRoundedRectangleOutline(Raster.Canvas, Bounds, 2 * Raster.View.Scale, Raster.View.Scale,
          RgbColor($76, $76, $76));
        if Checked then
        begin
          Points[0] := PrecisePoint(Bounds.Left + Size * 0.2, Bounds.Top + Size * 0.5);
          Points[1] := PrecisePoint(Bounds.Left + Size * 0.42, Bounds.Top + Size * 0.72);
          Points[2] := PrecisePoint(Bounds.Left + Size * 0.8, Bounds.Top + Size * 0.28);
          DrawSmoothPolygonOutline(Raster.Canvas, Points, 2 * Raster.View.Scale, Item.Color);
        end;
      end;
    ControlRadio:
      begin
        FillSmoothEllipse(Raster.Canvas, Bounds, ColorWhite);
        DrawSmoothEllipseOutline(Raster.Canvas, Bounds, Raster.View.Scale, RgbColor($76, $76, $76));
        if Checked then
        begin
          Inner := InflateRectangle(Bounds, -Round(Size * 0.28));
          FillSmoothEllipse(Raster.Canvas, Inner, Item.Color);
        end;
      end;
    ControlMeter:
      begin
        FillSmoothRoundedRectangle(Raster.Canvas, Bounds, RectangleHeight(Bounds) / 2, RgbColor($E0, $E0, $E0));
        Inner := Bounds;
        Inner.Right := Bounds.Left + RectangleWidth(Bounds) div 2;
        FillSmoothRoundedRectangle(Raster.Canvas, Inner, RectangleHeight(Bounds) / 2, RgbColor($10, $7C, $10));
      end;
  end;
end;

{ A text field's value, a textarea's lines, clipped to the content box. }
procedure DrawControlText(var Raster: TRaster; const Item: TDisplayItem);
var
  Font: TTextFont;
  Text, Line: string;
  Saved: TRegion;
  Count, Index, PixelSize, LineNumber, Start, Stop: Integer;
  Baseline, LineHeight: Double;
begin
  Font := TextFontOf(Item.Box.Style);
  Text := Raster.List.Strings[Item.Index];
  CopyRegion(Raster.Canvas.Clip, Saved);
  IntersectRegionWithRectangle(Raster.Canvas.Clip, DeviceRectangle(Raster, Item.X, Item.Y, Item.Width, Item.Height));
  try
    PixelSize := Max(1, Round(Font.Size * Raster.View.Scale));
    LineHeight := Font.Ascent + Font.Descent;
    if TReplacedBox(Item.Box).ControlKind = ControlTextField then
      Text := StringReplace(Text, #10, ' ', [rfReplaceAll]);
    LineNumber := 0;
    Start := 1;
    while Start <= Length(Text) + 1 do
    begin
      Stop := Start;
      while (Stop <= Length(Text)) and (Text[Stop] <> #10) do
        Inc(Stop);
      Line := Copy(Text, Start, Stop - Start);
      if TReplacedBox(Item.Box).ControlKind = ControlTextField then
        Baseline := Item.Y + (Item.Height - LineHeight) / 2 + Font.Ascent
      else
        Baseline := Item.Y + LineNumber * LineHeight + Font.Ascent;
      Font.PlaceGlyphs(Line, 1, Length(Line), Raster.Glyphs, Count);
      for Index := 0 to Count - 1 do
        if Raster.Glyphs[Index].Face.Font <> nil then
          DrawGlyph(Raster, Raster.Glyphs[Index].Face.Font, PixelSize, Raster.Glyphs[Index].Glyph,
            DeviceX(Raster, Item.X + Raster.Glyphs[Index].X), DeviceY(Raster, Baseline), Item.Color, False);
      Inc(LineNumber);
      Start := Stop + 1;
    end;
  finally
    Raster.Canvas.Clip := Saved;
  end;
end;

{ ---- clips and groups ---- }

procedure PushGroup(var Raster: TRaster; const Item: TDisplayItem); forward;
procedure PopGroupMasked(var Raster: TRaster; const Shape: TCoverageShape); forward;

procedure PushClip(var Raster: TRaster; const Item: TDisplayItem);
var
  Opaque: TDisplayItem;
begin
  if Raster.ClipDepth >= Length(Raster.ClipStack) then
  begin
    SetLength(Raster.ClipStack, Raster.ClipDepth * 2 + 8);
    SetLength(Raster.RoundedClips, Length(Raster.ClipStack));
  end;
  CopyRegion(Raster.Canvas.Clip, Raster.ClipStack[Raster.ClipDepth]);
  Raster.RoundedClips[Raster.ClipDepth].Active := False;
  IntersectRegionWithRectangle(Raster.Canvas.Clip, DeviceRectangle(Raster, Item.X, Item.Y, Item.Width, Item.Height));
  if (Item.Index >= 0) and not RegionIsEmpty(Raster.Canvas.Clip) then
  begin
    Raster.RoundedClips[Raster.ClipDepth].Active := True;
    BeginShape(Raster.RoundedClips[Raster.ClipDepth].Shape);
    AddShapeRoundedRectangleCorners(Raster.RoundedClips[Raster.ClipDepth].Shape, DeviceX(Raster, Item.X),
      DeviceY(Raster, Item.Y), DeviceX(Raster, Item.X + Item.Width), DeviceY(Raster, Item.Y + Item.Height),
      ScaledRadii(Raster, Raster.List.Radii[Item.Index]), True);
    Opaque := Item;
    Opaque.Value := 1;
    PushGroup(Raster, Opaque);
  end;
  Inc(Raster.ClipDepth);
end;

procedure PopClip(var Raster: TRaster);
begin
  if Raster.ClipDepth = 0 then
    Exit;
  Dec(Raster.ClipDepth);
  if Raster.RoundedClips[Raster.ClipDepth].Active then
    PopGroupMasked(Raster, Raster.RoundedClips[Raster.ClipDepth].Shape);
  Raster.Canvas.Clip := Raster.ClipStack[Raster.ClipDepth];
end;

procedure PushGroup(var Raster: TRaster; const Item: TDisplayItem);
var
  Group: ^TGroup;
  Clip: TRegion;
begin
  if Raster.GroupDepth >= Length(Raster.Groups) then
    SetLength(Raster.Groups, Raster.GroupDepth * 2 + 4);
  Group := @Raster.Groups[Raster.GroupDepth];
  Inc(Raster.GroupDepth);
  Group^.Canvas := Raster.Canvas;
  Group^.Opacity := Round(EnsureRange(Item.Value, 0, 1) * 255);
  CopyRegion(Raster.Canvas.Clip, Clip);
  if not CreateSurface(Group^.Surface, Raster.Canvas.Surface.Width, Raster.Canvas.Surface.Height, ColorTransparent) then
  begin
    Group^.Surface.Pixels := nil;
    Exit;
  end;
  BeginCanvas(Raster.Canvas, Group^.Surface);
  SetCanvasClip(Raster.Canvas, Clip);
end;

procedure PopGroup(var Raster: TRaster);
var
  Group: ^TGroup;
  Bounds: TRectangle;
begin
  if Raster.GroupDepth = 0 then
    Exit;
  Dec(Raster.GroupDepth);
  Group := @Raster.Groups[Raster.GroupDepth];
  if Group^.Surface.Pixels = nil then
    Exit;
  Bounds := RegionBounds(Raster.Canvas.Clip);
  Raster.Canvas := Group^.Canvas;
  if not RectangleIsEmpty(Bounds) then
    DrawSurface(Raster.Canvas, Group^.Surface, Bounds, Bounds.Left, Bounds.Top, True, Group^.Opacity);
  FreeSurface(Group^.Surface);
end;

procedure PopGroupMasked(var Raster: TRaster; const Shape: TCoverageShape);
var
  Group: ^TGroup;
  Bounds: TRectangle;
  Mask: array of Byte;
  Width, Height, Row, Column: LongInt;
  Source, Target: PLongWord;
  Coverage: Byte;
begin
  if Raster.GroupDepth = 0 then
    Exit;
  Dec(Raster.GroupDepth);
  Group := @Raster.Groups[Raster.GroupDepth];
  if Group^.Surface.Pixels = nil then
    Exit;
  Bounds := RegionBounds(Raster.Canvas.Clip);
  Raster.Canvas := Group^.Canvas;
  Width := RectangleWidth(Bounds);
  Height := RectangleHeight(Bounds);
  if (Width > 0) and (Height > 0) then
  begin
    Mask := nil;
    SetLength(Mask, Width * Height);
    ShapeCoverage(Shape, Bounds, Mask);
    for Row := 0 to Height - 1 do
    begin
      Source := SurfaceLine(Group^.Surface, Bounds.Top + Row) + Bounds.Left;
      Target := SurfaceLine(Raster.Canvas.Surface, Bounds.Top + Row) + Bounds.Left;
      for Column := 0 to Width - 1 do
      begin
        Coverage := Mask[Row * Width + Column];
        { The group was drawn within the clip already. }
        if (Coverage > 0) and (AlphaOf(Source[Column]) > 0) then
          Target[Column] := BlendColors(Target[Column], FadeColor(Source[Column], Coverage));
      end;
    end;
  end;
  FreeSurface(Group^.Surface);
end;

procedure RasterizeDisplayList(List: TDisplayList; const Surface: TSurface; const View: TRasterView);
var
  Raster: TRaster;
  Index: Integer;
  Item: PDisplayItem;
  Region: TRegion;
begin
  Raster.List := List;
  Raster.View := View;
  Raster.ClipStack := nil;
  Raster.RoundedClips := nil;
  Raster.ClipDepth := 0;
  Raster.Groups := nil;
  Raster.GroupDepth := 0;
  Raster.FixedDepth := 0;
  Raster.Glyphs := nil;
  BeginCanvas(Raster.Canvas, Surface);
  SetRegionToRectangle(Region, View.Damage);
  SetCanvasClip(Raster.Canvas, Region);
  FillRectangle(Raster.Canvas, View.Damage, List.CanvasColor);
  for Index := 0 to List.Count - 1 do
  begin
    Item := @List.Items[Index];
    case Item^.Kind of
      diPushClip: PushClip(Raster, Item^);
      diPopClip: PopClip(Raster);
      diPushOpacity: PushGroup(Raster, Item^);
      diPopOpacity: PopGroup(Raster);
      diPushFixed: Inc(Raster.FixedDepth);
      diPopFixed: Dec(Raster.FixedDepth);
      diHitArea: ;
    else
      if not ItemVisible(Raster, Item^) then
        Continue;
      case Item^.Kind of
        diRectangle: FillBox(Raster, Item^.X, Item^.Y, Item^.Width, Item^.Height, Item^.Color, Item^.Index);
        diBorder: DrawBorder(Raster, Item^);
        diText: DrawText(Raster, Item^);
        diImage: DrawImage(Raster, Item^);
        diGradient: DrawGradient(Raster, Item^);
        diShadow: DrawShadow(Raster, Item^);
        diControl: DrawControl(Raster, Item^);
        diControlText: DrawControlText(Raster, Item^);
      end;
    end;
  end;
  while Raster.GroupDepth > 0 do
    PopGroup(Raster);
end;

end.
