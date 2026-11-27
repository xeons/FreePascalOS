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
  images scaled (and tiled for backgrounds; the scaled copies kept in
  Web.Paint.ImageCache); gradients from a ramp of their colours; box
  shadows as a blurred coverage mask (kept in Web.Paint.ShadowCache).
  Clips narrow the canvas's clip region (a rounded clip draws into a
  group composited through its coverage); an opacity group is drawn on
  a transparent surface as big as what it draws (Web.Paint.GroupExtents)
  and composited, or, holding one item that takes an opacity, not made
  at all: the item is drawn at the group's opacity.
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
    { The viewport's size in CSS px (sticky boxes keep inside it). }
    ViewportWidth, ViewportHeight: Single;
    { The part of the surface to draw (device pixels). }
    Damage: TRectangle;
    { The surface's pixel (0, 0) shows the viewport's device pixel
      (ShiftX, ShiftY) (a frame painted into the visible part of its
      box); 0 for a whole viewport. }
    ShiftX, ShiftY: LongInt;
  end;

procedure RasterizeDisplayList(List: TDisplayList; const Surface: TSurface; const View: TRasterView);

var
  { Draw glyphs hinted (sharper at small sizes). }
  WebTextHinting: Boolean = True;

implementation

uses
  Math, SysUtils, Drawing.Colors, Drawing.Canvas, Drawing.Regions, Drawing.Rasterizer, Drawing.SmoothRoundedRectangles,
  Drawing.CoverageBlending, Drawing.Scaling, Drawing.SmoothShapes, Drawing.Blurring, Web.Paint.Filters, Css.Keywords, Font.Outlines,
  Font.GlyphCache, Font.GlyphDrawing, Image.Model, Image.Surfaces, Image.Scalable, Web.Layout.Boxes, Web.Layout.TreeBuilder, Web.Text.Fonts,
  Web.Text.FontInstances, Web.Paint.Gradients, Web.Paint.Sticky, Web.Layout.EmbeddedContent, Drawing.Transforms,
  Drawing.Paints, Drawing.PaintFilling, Css.TransformMatrices, Web.Paint.GroupExtents, Web.Paint.SurfacePool,
  Web.Paint.ShadowCache, Web.Paint.ImageCache;

type
  { A group: drawn into a surface of its own (as big as what it draws
    within the clip when it began, at Left, Top of the surface below;
    from the surface pool), then composited. A mask
    group draws its mask layers first, then (BeginMaskContent) its
    content into a second surface, composited through the first's
    alpha. }
  TGroup = record
    Canvas: TCanvas;
    Surface: TSurface;
    MaskSurface: TSurface;
    Left, Top: LongInt;
    Opacity: Byte;
    { A transform group: its surface holds the content untransformed
      (device pixels of the surface below, from Left, Top), composited
      through DeviceTransform (untransformed to transformed device
      pixels of the surface below). }
    IsTransform: Boolean;
    DeviceTransform: TAffineTransform;
    { A mask layer's group: how it combines with the layers below. }
    Composite: TMaskComposite;
    { A filter's group: its operations (Filters of the list), else -1. }
    Filter: Integer;
  end;
  PGroup = ^TGroup;

  { A rounded clip: what is drawn inside goes to a group composited
    through the clip's coverage. }
  TRoundedClip = record
    Active: Boolean;
    Shape: TCoverageShape;
  end;

  TOrigin = record
    X, Y: Single;
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
    { The document point drawn at the surface's top left: the scroll
      offset, (0, 0) in fixed subtrees, less sticky offsets. }
    OriginX, OriginY: Single;
    Origins: array of TOrigin;
    OriginDepth: Integer;
    { Device pixel (0, 0) is at (-ShiftX, -ShiftY) of the surface drawn
      into (groups are only as big as their clips). }
    ShiftX, ShiftY: LongInt;
    Glyphs: TPlacedGlyphArray;
    { The opacity the item being drawn is drawn at: an opacity group of
      that one item folded into it (255 otherwise). }
    ItemOpacity: Byte;
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
  Result := (X - Raster.OriginX) * Raster.View.Scale - Raster.ShiftX;
end;

function DeviceY(const Raster: TRaster; Y: Single): Double; inline;
begin
  Result := (Y - Raster.OriginY) * Raster.View.Scale - Raster.ShiftY;
end;

procedure PushOrigin(var Raster: TRaster; X, Y: Single);
begin
  if Raster.OriginDepth >= Length(Raster.Origins) then
    SetLength(Raster.Origins, Raster.OriginDepth * 2 + 4);
  Raster.Origins[Raster.OriginDepth].X := Raster.OriginX;
  Raster.Origins[Raster.OriginDepth].Y := Raster.OriginY;
  Inc(Raster.OriginDepth);
  Raster.OriginX := X;
  Raster.OriginY := Y;
end;

procedure PopOrigin(var Raster: TRaster);
begin
  if Raster.OriginDepth = 0 then
    Exit;
  Dec(Raster.OriginDepth);
  Raster.OriginX := Raster.Origins[Raster.OriginDepth].X;
  Raster.OriginY := Raster.Origins[Raster.OriginDepth].Y;
end;

{ A sticky subtree is drawn moved by its offset for the scrollport the
  current origin shows. }
procedure PushSticky(var Raster: TRaster; const Item: TDisplayItem);
var
  OffsetX, OffsetY: Single;
begin
  StickyOffset(Raster.List.Stickies[Item.Index], Item.X, Item.Y, Item.Width, Item.Height, Raster.OriginX,
    Raster.OriginY, Raster.View.ViewportWidth, Raster.View.ViewportHeight, OffsetX, OffsetY);
  PushOrigin(Raster, Raster.OriginX - OffsetX, Raster.OriginY - OffsetY);
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

{ Color at the opacity of the item being drawn. }
function ItemColor(const Raster: TRaster; Color: TColor): TColor; inline;
begin
  if Raster.ItemOpacity = 255 then
    Result := Color
  else
    Result := FadeColor(Color, Raster.ItemOpacity);
end;

procedure FillBox(var Raster: TRaster; X, Y, Width, Height: Single; Color: TColor; RadiiIndex: Integer);
var
  Shape: TCoverageShape;
begin
  Color := ItemColor(Raster, Color);
  if (Width <= 0) or (Height <= 0) or (AlphaOf(Color) = 0) then
    Exit;
  if RadiiIndex < 0 then
  begin
    FillRectangle(Raster.Canvas, DeviceRectangle(Raster, X, Y, Width, Height), Color);
    Exit;
  end;
  BeginShape(Shape);
  AddShapeRoundedRectangleCorners(Shape, Floor(DeviceX(Raster, X) + 0.5), Floor(DeviceY(Raster, Y) + 0.5),
    Floor(DeviceX(Raster, X + Width) + 0.5), Floor(DeviceY(Raster, Y + Height) + 0.5),
    ScaledRadii(Raster, Raster.List.Radii[RadiiIndex]), True);
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
  { The border box snapped to device pixels, as its background is
    (FillBox): the edges of a box at a fractional position stay sharp
    and meet its background exactly. Widths are whole device pixels
    already (Css.StyleCompute's SnapBorderWidth). }
  Left := Floor(DeviceX(Raster, Item.X) + 0.5);
  Top := Floor(DeviceY(Raster, Item.Y) + 0.5);
  Right := Floor(DeviceX(Raster, Item.X + Item.Width) + 0.5);
  Bottom := Floor(DeviceY(Raster, Item.Y + Item.Height) + 0.5);
  for Side := 0 to 3 do
  begin
    Widths[Side] := Sides.Widths[Side] * Raster.View.Scale;
    if Widths[Side] > 0 then
      Widths[Side] := Max(1, Floor(Widths[Side] + 0.5));
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
  if IsColorGlyph(Bitmap^) then
  begin
    { An emoji: its own colours, never made bold. }
    DrawGlyphBitmap(Raster.Canvas, Bitmap^, Whole, BaselinePixel, Color, Slant);
    Exit;
  end;
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
  Color: TColor;
begin
  Run := Raster.List.Texts[Item.Index];
  Color := ItemColor(Raster, Item.Color);
  Slant := 0;
  if Run.Font.SyntheticItalic then
    Slant := 0.2;
  if Run.Literal >= 0 then
    Run.Font.PlaceGlyphs(Raster.List.Strings[Run.Literal], 1, Length(Raster.List.Strings[Run.Literal]),
      Raster.Glyphs, Count)
  else
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
      DrawGlyph(Raster, Font, PixelSize, Raster.Glyphs[Index].Glyph, PenX, Baseline, Color,
        Run.Font.SyntheticBold, Slant);
    if Raster.Glyphs[Index].CodePoint = 32 then
      Inc(Spaces);
    Inc(Characters);
  end;
end;

{ ---- images ---- }

const
  { 4096 x 4096: larger images are scaled from their own pixels. }
  MaximumVectorRenderingPixels = 16 * 1024 * 1024;

{ One tile of an image at Destination (device pixels), at the item's
  opacity. Smoothly scaled images come from the scaled image cache. }
procedure DrawImageTile(var Raster: TRaster; const Run: TImageRun; const Source: TSurface;
  const Destination: TRectangle);
var
  Rendered: TImage;
  Scaled: TSurface;
  SourceRectangle: TRectangle;
  Width, Height: LongInt;
begin
  Width := RectangleWidth(Destination);
  Height := RectangleHeight(Destination);
  SourceRectangle := MakeRectangle(0, 0, Run.Image.Width, Run.Image.Height);
  { A vector image (SVG) is drawn again at the size shown. }
  Rendered := nil;
  if (Run.Image is TScalableImage) and not Run.Pixelated and
     (Int64(Width) * Height <= MaximumVectorRenderingPixels) then
    Rendered := TScalableImage(Run.Image).RenderedAt(Width, Height);
  if Rendered <> nil then
    DrawSurface(Raster.Canvas, ImageSurface(Rendered), MakeRectangle(0, 0, Rendered.Width, Rendered.Height),
      Destination.Left, Destination.Top, True, Raster.ItemOpacity)
  else if (Width = Run.Image.Width) and (Height = Run.Image.Height) then
    DrawSurface(Raster.Canvas, Source, SourceRectangle, Destination.Left, Destination.Top, True, Raster.ItemOpacity)
  else if Run.Pixelated then
    DrawSurfaceStretched(Raster.Canvas, Source, SourceRectangle, Destination, True)
  else if ScaledImage(Run.Image, Source, SourceRectangle, Width, Height, Raster.List.Revision, Scaled) then
    DrawSurface(Raster.Canvas, Scaled, MakeRectangle(0, 0, Width, Height), Destination.Left, Destination.Top, True,
      Raster.ItemOpacity)
  else
    DrawSurfaceScaled(Raster.Canvas, Source, SourceRectangle, Destination, True);
end;

{ Whether every tile of the image can be drawn at an opacity (the paths
  of DrawImageTile that take one). }
function ImageTakesOpacity(const Raster: TRaster; const Item: TDisplayItem): Boolean;
var
  Run: TImageRun;
  Tile: TRectangle;
begin
  Run := Raster.List.Images[Item.Index];
  if (Run.Image = nil) or Run.Pixelated then
    Exit(False);
  { Tiles round to a pixel more or less. }
  Tile := DeviceRectangle(Raster, Run.TileX, Run.TileY, Run.TileWidth, Run.TileHeight);
  Result := ScaledImageFits(RectangleWidth(Tile) + 1, RectangleHeight(Tile) + 1);
end;

procedure DrawImage(var Raster: TRaster; const Item: TDisplayItem);
var
  Run: TImageRun;
  Source: TSurface;
  Destination, Area, Common: TRectangle;
  Saved: TRegion;
  TileX, TileY, StartX, StartY, EndX, EndY: Single;
  Guard: Integer;
begin
  Run := Raster.List.Images[Item.Index];
  if (Run.Image = nil) or (Run.TileWidth <= 0) or (Run.TileHeight <= 0) then
    Exit;
  Source := ImageSurface(Run.Image);
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
          DrawImageTile(Raster, Run, Source, Destination);
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

{ Count colors from Left over line Y, within the clip. }
procedure BlendRow(const Canvas: TCanvas; Y, Left: LongInt; const Colors: array of TColor; Count: LongInt);
var
  Index, Start, Finish, X: LongInt;
  Piece: TRectangle;
  Line: PLongWord;
  Color: TColor;
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
    begin
      Color := Colors[X - Left];
      if AlphaOf(Color) = AlphaOpaque then
        Line[X] := Color
      else if AlphaOf(Color) <> 0 then
        Line[X] := BlendColors(Line[X], Color);
    end;
  end;
end;

{ The gradient's position at every column's centre (wrapped into the
  tile when the gradient repeats), as GradientColumnTerm. }
procedure ColumnTerms(const Prepared: TPreparedGradient; const Bounds: TRectangle; BoxLeft, TileWidth: Double;
  Repeating: Boolean; var Terms: array of Single);
var
  Column: LongInt;
  PointX: Double;
begin
  for Column := Bounds.Left to Bounds.Right - 1 do
  begin
    PointX := Column + 0.5 - BoxLeft;
    if Repeating then
      PointX := PointX - TileWidth * Floor(PointX / TileWidth);
    Terms[Column - Bounds.Left] := GradientColumnTerm(Prepared, PointX);
  end;
end;

{ A gradient's colours from a ramp: one per row when it changes only
  down the box, one row copied down when it changes only across, else
  pixel by pixel from the column and row parts of the position. }
procedure DrawGradient(var Raster: TRaster; const Item: TDisplayItem);
var
  Run: TGradientRun;
  Prepared: TPreparedGradient;
  Ramp: TGradientRamp;
  Area, Bounds: TRectangle;
  Row, Column, Width: LongInt;
  Colors: array of TColor;
  Terms: array of Single;
  BoxLeft, BoxTop, TileWidth, TileHeight, PointY: Double;
  RowTerm: Single;
  Repeating, AlongX, AlongY: Boolean;
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
  PrepareGradientRamp(Prepared, Raster.ItemOpacity, Ramp);
  GradientVariation(Prepared, AlongX, AlongY);
  Width := RectangleWidth(Bounds);
  Colors := nil;
  SetLength(Colors, Width);
  Terms := nil;
  SetLength(Terms, Width);
  ColumnTerms(Prepared, Bounds, BoxLeft, TileWidth, Repeating, Terms);
  for Row := Bounds.Top to Bounds.Bottom - 1 do
  begin
    PointY := Row + 0.5 - BoxTop;
    if Repeating then
      PointY := PointY - TileHeight * Floor(PointY / TileHeight);
    RowTerm := GradientRowTerm(Prepared, PointY);
    if not AlongX then
    begin
      FillSpan(Raster.Canvas, Row, Bounds.Left, Bounds.Right,
        RampColorAt(Prepared, Ramp, GradientPosition(Prepared, 0, RowTerm)));
      Continue;
    end;
    if AlongY or (Row = Bounds.Top) then
      for Column := 0 to Width - 1 do
        Colors[Column] := RampColorAt(Prepared, Ramp, GradientPosition(Prepared, Terms[Column], RowTerm));
    BlendRow(Raster.Canvas, Row, Bounds.Left, Colors, Width);
  end;
end;

{ ---- shadows ---- }

{ The shadow's blurred mask (Web.Paint.ShadowCache) over its area, the
  rows within the clip blended in its color. }
procedure DrawShadow(var Raster: TRaster; const Item: TDisplayItem);
var
  Run: TShadowRun;
  Geometry: TShadowGeometry;
  Area, Bounds: TRectangle;
  Mask: PByte;
  Radii: TCornerRadii;
  Blur, Scale: Double;
  Row: LongInt;
begin
  Run := Raster.List.Shadows[Item.Index];
  Scale := Raster.View.Scale;
  Blur := Run.Blur * Scale;
  FillChar(Radii, SizeOf(Radii), 0);
  if Run.Radii >= 0 then
    Radii := ScaledRadii(Raster, Raster.List.Radii[Run.Radii]);
  Geometry := Default(TShadowGeometry);
  Geometry.Margin := Ceil(Blur) + 2;
  Area := DeviceRectangle(Raster, Item.X, Item.Y, Item.Width, Item.Height);
  Area := InflateRectangle(Area, Geometry.Margin);
  if not IntersectRectangles(Area, RegionBounds(Raster.Canvas.Clip), Bounds) then
    Exit;
  Geometry.Width := RectangleWidth(Area);
  Geometry.Height := RectangleHeight(Area);
  Geometry.BoxLeft := DeviceX(Raster, Run.BoxX) - Area.Left;
  Geometry.BoxTop := DeviceY(Raster, Run.BoxY) - Area.Top;
  Geometry.BoxRight := DeviceX(Raster, Run.BoxX + Run.BoxWidth) - Area.Left;
  Geometry.BoxBottom := DeviceY(Raster, Run.BoxY + Run.BoxHeight) - Area.Top;
  Geometry.OffsetX := Run.OffsetX * Scale;
  Geometry.OffsetY := Run.OffsetY * Scale;
  Geometry.Spread := Run.Spread * Scale;
  Geometry.BlurRadius := Round(Blur / 2);
  Geometry.Radii := Radii;
  Geometry.Inset := Run.Inset;
  Mask := ShadowMask(Geometry);
  if Mask = nil then
    Exit;
  for Row := Bounds.Top to Bounds.Bottom - 1 do
    BlendMaskSpan(Raster.Canvas, Row, Area.Left, @Mask[(Row - Area.Top) * Geometry.Width], Geometry.Width,
      ItemColor(Raster, Item.Color));
end;

{ ---- controls ---- }

{ A range input: a thin track, filled up to the thumb, and the round
  thumb at Fraction of the way along. }
procedure DrawRange(var Raster: TRaster; const Bounds: TRectangle; Fraction: Single);
var
  Track, Filled, Thumb: TRectangle;
  ThumbSize, TrackHeight, Travel, Center: LongInt;
begin
  ThumbSize := RectangleHeight(Bounds);
  if ThumbSize > RectangleWidth(Bounds) then
    ThumbSize := RectangleWidth(Bounds);
  TrackHeight := Max(2, ThumbSize div 4);
  Travel := RectangleWidth(Bounds) - ThumbSize;
  Center := Bounds.Left + ThumbSize div 2 + Round(Travel * Fraction);
  Track := Bounds;
  Track.Top := Bounds.Top + (RectangleHeight(Bounds) - TrackHeight) div 2;
  Track.Bottom := Track.Top + TrackHeight;
  FillSmoothRoundedRectangle(Raster.Canvas, Track, TrackHeight / 2, RgbColor($C8, $C8, $C8));
  Filled := Track;
  Filled.Right := Center;
  if Filled.Right > Filled.Left then
    FillSmoothRoundedRectangle(Raster.Canvas, Filled, TrackHeight / 2, RgbColor($00, $75, $FF));
  Thumb.Left := Center - ThumbSize div 2;
  Thumb.Right := Thumb.Left + ThumbSize;
  Thumb.Top := Bounds.Top + (RectangleHeight(Bounds) - ThumbSize) div 2;
  Thumb.Bottom := Thumb.Top + ThumbSize;
  FillSmoothEllipse(Raster.Canvas, Thumb, RgbColor($00, $75, $FF));
end;

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
        if Item.Value < 0 then
        begin
          { Indeterminate: a stripe in the middle. }
          Inner.Left := Bounds.Left + RectangleWidth(Bounds) * 3 div 8;
          Inner.Right := Bounds.Left + RectangleWidth(Bounds) * 5 div 8;
        end
        else
          Inner.Right := Bounds.Left + Round(RectangleWidth(Bounds) * Item.Value);
        if Inner.Right > Inner.Left then
          FillSmoothRoundedRectangle(Raster.Canvas, Inner, RectangleHeight(Bounds) / 2, RgbColor($10, $7C, $10));
      end;
    ControlRange:
      DrawRange(Raster, Bounds, Item.Value);
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

const
  { How far past an extent's rounded device rectangle drawing can reach
    (anti-aliased edges, rounding). }
  GroupInkMargin = 3;
  { Device coordinates beyond this are off any surface. }
  DeviceLimit = 1E7;

procedure PushGroup(var Raster: TRaster; const Item: TDisplayItem; PushIndex: Integer); forward;
procedure PopGroupMasked(var Raster: TRaster; const Shape: TCoverageShape); forward;

procedure PushClip(var Raster: TRaster; const Item: TDisplayItem; PushIndex: Integer);
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
    PushGroup(Raster, Opaque, PushIndex);
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

{ Device pixels (of the surface drawn into) that what the group at
  PushIndex draws can touch; False when that is not known. Empty when
  it draws nothing. }
function GroupContentBounds(const Raster: TRaster; PushIndex: Integer; out Bounds: TRectangle): Boolean;
var
  Extent: TGroupExtent;
begin
  Bounds := EdgesRectangle(0, 0, 0, 0);
  Extent := Raster.List.GroupExtents[PushIndex];
  if not Extent.Bounded then
    Exit(False);
  Result := True;
  if (Extent.Left >= Extent.Right) or (Extent.Top >= Extent.Bottom) then
    Exit;
  Bounds := EdgesRectangle(Floor(EnsureRange(DeviceX(Raster, Extent.Left), -DeviceLimit, DeviceLimit)),
    Floor(EnsureRange(DeviceY(Raster, Extent.Top), -DeviceLimit, DeviceLimit)),
    Ceil(EnsureRange(DeviceX(Raster, Extent.Right), -DeviceLimit, DeviceLimit)),
    Ceil(EnsureRange(DeviceY(Raster, Extent.Bottom), -DeviceLimit, DeviceLimit)));
  Bounds := InflateRectangle(Bounds, GroupInkMargin);
end;

{ A new group on top, drawing nowhere yet (Surface nil: straight below). }
function NewGroup(var Raster: TRaster): PGroup;
begin
  if Raster.GroupDepth >= Length(Raster.Groups) then
    SetLength(Raster.Groups, Raster.GroupDepth * 2 + 4);
  Result := @Raster.Groups[Raster.GroupDepth];
  Inc(Raster.GroupDepth);
  Result^.Canvas := Raster.Canvas;
  Result^.Opacity := 255;
  Result^.MaskSurface.Pixels := nil;
  Result^.Surface.Pixels := nil;
  Result^.IsTransform := False;
  Result^.Filter := -1;
end;

{ The group draws into a pooled surface over Area (device pixels of the
  surface below), clipped to Clip (the same). False when there is no
  memory (the group draws straight below). }
function BeginGroupSurface(var Raster: TRaster; Group: PGroup; const Area: TRectangle; const Clip: TRegion): Boolean;
var
  Local: TRegion;
begin
  Result := TakePooledSurface(Group^.Surface, RectangleWidth(Area), RectangleHeight(Area));
  if not Result then
    Exit;
  Group^.Left := Area.Left;
  Group^.Top := Area.Top;
  CopyRegion(Clip, Local);
  OffsetRegion(Local, -Area.Left, -Area.Top);
  BeginCanvas(Raster.Canvas, Group^.Surface);
  SetCanvasClip(Raster.Canvas, Local);
  Inc(Raster.ShiftX, Area.Left);
  Inc(Raster.ShiftY, Area.Top);
end;

{ An opacity, mask or mask layer group (or a rounded clip's): its
  surface covers what it draws within the clip. }
procedure PushGroup(var Raster: TRaster; const Item: TDisplayItem; PushIndex: Integer);
var
  Group: PGroup;
  Bounds, Content: TRectangle;
  Nowhere: TRegion;
begin
  Group := NewGroup(Raster);
  Group^.Opacity := Round(EnsureRange(Item.Value, 0, 1) * 255);
  Bounds := RegionBounds(Raster.Canvas.Clip);
  { Drawn straight below when nothing shows (the clip is empty). }
  if RectangleIsEmpty(Bounds) then
    Exit;
  if GroupContentBounds(Raster, PushIndex, Content) and not IntersectRectangles(Bounds, Content, Bounds) then
  begin
    { It draws nothing: a pixel of surface, clipped to nothing. }
    SetRegionToRectangle(Nowhere, EdgesRectangle(0, 0, 0, 0));
    BeginGroupSurface(Raster, Group, MakeRectangle(Bounds.Left, Bounds.Top, 1, 1), Nowhere);
    Exit;
  end;
  BeginGroupSurface(Raster, Group, Bounds, Raster.Canvas.Clip);
end;

{ The top group's drawing is over: back to the surface below. False when
  the group drew straight below. }
function LeaveGroup(var Raster: TRaster; out Group: PGroup): Boolean;
begin
  Result := False;
  Group := nil;
  if Raster.GroupDepth = 0 then
    Exit;
  Dec(Raster.GroupDepth);
  Group := @Raster.Groups[Raster.GroupDepth];
  if Group^.Surface.Pixels = nil then
  begin
    ReturnPooledSurface(Group^.MaskSurface);
    Exit;
  end;
  Raster.Canvas := Group^.Canvas;
  Dec(Raster.ShiftX, Group^.Left);
  Dec(Raster.ShiftY, Group^.Top);
  Result := True;
end;

procedure PopGroup(var Raster: TRaster);
var
  Group: PGroup;
begin
  if not LeaveGroup(Raster, Group) then
    Exit;
  DrawSurface(Raster.Canvas, Group^.Surface, MakeRectangle(0, 0, Group^.Surface.Width, Group^.Surface.Height),
    Group^.Left, Group^.Top, True, Group^.Opacity);
  ReturnPooledSurface(Group^.Surface);
end;

{ A rounded clip's group put below through the clip's coverage: what is
  not covered is skipped, what is fully covered blended as it is. }
procedure PopGroupMasked(var Raster: TRaster; const Shape: TCoverageShape);
var
  Group: PGroup;
  Bounds: TRectangle;
  Mask: array of Byte;
  Width, Height, Row, Column: LongInt;
  Source, Target: PLongWord;
  Coverage: PByte;
  Pixel: TColor;
begin
  if not LeaveGroup(Raster, Group) then
    Exit;
  Width := Group^.Surface.Width;
  Height := Group^.Surface.Height;
  Bounds := MakeRectangle(Group^.Left, Group^.Top, Width, Height);
  Mask := nil;
  SetLength(Mask, Width * Height);
  ShapeCoverage(Shape, Bounds, Mask);
  for Row := 0 to Height - 1 do
  begin
    Source := SurfaceLine(Group^.Surface, Row);
    Target := SurfaceLine(Raster.Canvas.Surface, Bounds.Top + Row) + Bounds.Left;
    Coverage := @Mask[Row * Width];
    for Column := 0 to Width - 1 do
    begin
      { The group was drawn within the clip already. }
      Pixel := Source[Column];
      if (Coverage[Column] = 0) or (AlphaOf(Pixel) = 0) then
        Continue;
      if Coverage[Column] < 255 then
        Pixel := FadeColor(Pixel, Coverage[Column]);
      if AlphaOf(Pixel) = AlphaOpaque then
        Target[Column] := Pixel
      else
        Target[Column] := BlendColors(Target[Column], Pixel);
    end;
  end;
  ReturnPooledSurface(Group^.Surface);
end;

{ ---- transforms ---- }

function AffineOf(const Matrix: TCssMatrix2D): TAffineTransform;
begin
  Result := MakeTransform(Matrix.A, Matrix.B, Matrix.C, Matrix.D, Matrix.E, Matrix.F);
end;

{ A transform of document coordinates as one of device pixels of the
  surface drawn into: device to document, the transform, back. }
function DeviceTransformOf(const Raster: TRaster; const Transform: TAffineTransform): TAffineTransform;
var
  ToDocument, ToDevice: TAffineTransform;
  Scale: Double;
begin
  Scale := Raster.View.Scale;
  ToDocument := CombineTransforms(TranslationTransform(Raster.OriginX, Raster.OriginY),
    CombineTransforms(ScalingTransform(1 / Scale, 1 / Scale), TranslationTransform(Raster.ShiftX, Raster.ShiftY)));
  ToDevice := CombineTransforms(TranslationTransform(-Raster.ShiftX, -Raster.ShiftY),
    CombineTransforms(ScalingTransform(Scale, Scale), TranslationTransform(-Raster.OriginX, -Raster.OriginY)));
  Result := CombineTransforms(ToDevice, CombineTransforms(Transform, ToDocument));
end;

const
  { The largest side of a transform group's surface. }
  MaximumGroupSide = 8192;

{ The content is drawn untransformed into a surface covering what of it
  can show through the clip (the clip mapped back through the
  transform, within the group's bounds). }
procedure PushTransform(var Raster: TRaster; const Item: TDisplayItem);
var
  Group: PGroup;
  Inverse: TAffineTransform;
  Clip, Content, Area: TRectangle;
  Point: TPrecisePoint;
  Corner: Integer;
  MinX, MinY, MaxX, MaxY: Double;
  Region: TRegion;
  Empty: Boolean;
begin
  Group := NewGroup(Raster);
  Group^.IsTransform := True;
  Group^.DeviceTransform := DeviceTransformOf(Raster, AffineOf(Raster.List.Transforms[Item.Index]));
  Clip := RegionBounds(Raster.Canvas.Clip);
  Empty := RectangleIsEmpty(Clip) or not InvertTransform(Group^.DeviceTransform, Inverse);
  if not Empty then
  begin
    MinX := Infinity;
    MinY := Infinity;
    MaxX := -Infinity;
    MaxY := -Infinity;
    for Corner := 0 to 3 do
    begin
      if Corner mod 2 = 0 then
        Point.X := Clip.Left
      else
        Point.X := Clip.Right;
      if Corner div 2 = 0 then
        Point.Y := Clip.Top
      else
        Point.Y := Clip.Bottom;
      Point := TransformPoint(Inverse, Point.X, Point.Y);
      MinX := Min(MinX, Point.X);
      MinY := Min(MinY, Point.Y);
      MaxX := Max(MaxX, Point.X);
      MaxY := Max(MaxY, Point.Y);
    end;
    Area := EdgesRectangle(Floor(Max(MinX, -1E7)) - 1, Floor(Max(MinY, -1E7)) - 1, Ceil(Min(MaxX, 1E7)) + 1,
      Ceil(Min(MaxY, 1E7)) + 1);
    Content := InflateRectangle(DeviceRectangle(Raster, Item.X, Item.Y, Item.Width, Item.Height), 2);
    Empty := not IntersectRectangles(Area, Content, Area);
  end;
  if not Empty then
  begin
    if RectangleWidth(Area) > MaximumGroupSide then
      Area.Right := Area.Left + MaximumGroupSide;
    if RectangleHeight(Area) > MaximumGroupSide then
      Area.Bottom := Area.Top + MaximumGroupSide;
  end;
  if Empty then
    Area := EdgesRectangle(0, 0, 1, 1);
  if not TakePooledSurface(Group^.Surface, RectangleWidth(Area), RectangleHeight(Area)) then
  begin
    Empty := True;
    Area := EdgesRectangle(0, 0, 1, 1);
    TakePooledSurface(Group^.Surface, 1, 1);
  end;
  Group^.Left := Area.Left;
  Group^.Top := Area.Top;
  BeginCanvas(Raster.Canvas, Group^.Surface);
  if Empty then
    SetRegionToRectangle(Region, EdgesRectangle(0, 0, 0, 0))
  else
    SetRegionToRectangle(Region, EdgesRectangle(0, 0, RectangleWidth(Area), RectangleHeight(Area)));
  SetCanvasClip(Raster.Canvas, Region);
  Inc(Raster.ShiftX, Area.Left);
  Inc(Raster.ShiftY, Area.Top);
end;

procedure PopTransform(var Raster: TRaster);
var
  Group: PGroup;
  Inverse, ToTile: TAffineTransform;
  Corners: array[0..3] of TPrecisePoint;
  Shape: TCoverageShape;
  Paint: TPaint;
  Width, Height: LongInt;
begin
  if not LeaveGroup(Raster, Group) then
    Exit;
  Width := Group^.Surface.Width;
  Height := Group^.Surface.Height;
  if InvertTransform(Group^.DeviceTransform, Inverse) and (Width > 1) then
  begin
    { Surface pixels of the canvas below to the group's pixels. }
    ToTile := CombineTransforms(TranslationTransform(-Group^.Left, -Group^.Top),
      CombineTransforms(Inverse, TranslationTransform(-Raster.Canvas.OriginX, -Raster.Canvas.OriginY)));
    Corners[0] := TransformPoint(Group^.DeviceTransform, Group^.Left, Group^.Top);
    Corners[1] := TransformPoint(Group^.DeviceTransform, Group^.Left + Width, Group^.Top);
    Corners[2] := TransformPoint(Group^.DeviceTransform, Group^.Left + Width, Group^.Top + Height);
    Corners[3] := TransformPoint(Group^.DeviceTransform, Group^.Left, Group^.Top + Height);
    for Width := 0 to 3 do
    begin
      Corners[Width].X := Corners[Width].X + Raster.Canvas.OriginX;
      Corners[Width].Y := Corners[Width].Y + Raster.Canvas.OriginY;
    end;
    BeginShape(Shape);
    AddShapePolygon(Shape, Corners);
    Paint := PatternPaint(Group^.Surface, ToTile);
    Paint.TileRepeat := False;
    Paint.Smooth := not IsAxisAligned(Group^.DeviceTransform) or
      (Abs(Group^.DeviceTransform.A - 1) > 1E-6) or (Abs(Group^.DeviceTransform.D - 1) > 1E-6) or
      (Frac(Abs(Group^.DeviceTransform.E)) > 1E-6) or (Frac(Abs(Group^.DeviceTransform.F)) > 1E-6);
    PreparePaint(Paint);
    FillShapeWithPaint(Raster.Canvas, Shape, FillRuleNonZero, Paint, 255, nil);
  end;
  ReturnPooledSurface(Group^.Surface);
end;

{ ---- masks (CSS Masking: mask-image layers, by alpha) ---- }

{ The mask layers are drawn: keep them, draw the content anew. }
procedure BeginMaskContent(var Raster: TRaster);
var
  Group: PGroup;
  Clip: TRegion;
begin
  if Raster.GroupDepth = 0 then
    Exit;
  Group := @Raster.Groups[Raster.GroupDepth - 1];
  if Group^.Surface.Pixels = nil then
    Exit;
  Group^.MaskSurface := Group^.Surface;
  Group^.Surface.Pixels := nil;
  CopyRegion(Raster.Canvas.Clip, Clip);
  if not TakePooledSurface(Group^.Surface, Group^.MaskSurface.Width, Group^.MaskSurface.Height) then
  begin
    { No room for the content: it is drawn into the mask surface and
      dropped at the pop. }
    Group^.Surface := Group^.MaskSurface;
    Group^.MaskSurface.Pixels := nil;
    Exit;
  end;
  BeginCanvas(Raster.Canvas, Group^.Surface);
  SetCanvasClip(Raster.Canvas, Clip);
end;

{ A filter's group covers what it draws within the clip and, for a
  blur, as far around that as the blur reaches (what is drawn there
  blurs into the clip; a blur sees nothing past the surface's edges, so
  the transparent margin around the content changes nothing); the clips
  of the surface below apply when it is put back. }
const
  { The largest side of a filter group's surface. }
  MaximumFilterSide = 8192;

procedure PushFilter(var Raster: TRaster; const Item: TDisplayItem; PushIndex: Integer);
var
  Group: PGroup;
  Bounds, Content: TRectangle;
  Operations: TFilterOperations;
  Index, Margin: LongInt;
begin
  Group := NewGroup(Raster);
  Group^.Filter := Item.Index;
  Operations := Raster.List.Filters[Item.Index];
  Margin := 0;
  for Index := 0 to High(Operations) do
    if Operations[Index].Kind = foBlur then
      Inc(Margin, BlurMargin(Operations[Index].Amount * Raster.View.Scale));
  Bounds := RegionBounds(Raster.Canvas.Clip);
  if RectangleIsEmpty(Bounds) then
    Exit;
  Bounds := InflateRectangle(Bounds, Margin);
  if GroupContentBounds(Raster, PushIndex, Content) and
     not IntersectRectangles(Bounds, InflateRectangle(Content, Margin), Bounds) then
    Bounds := MakeRectangle(Bounds.Left, Bounds.Top, 1, 1);
  Group^.Left := Bounds.Left;
  Group^.Top := Bounds.Top;
  if (RectangleWidth(Bounds) > MaximumFilterSide) or (RectangleHeight(Bounds) > MaximumFilterSide) or
     not TakePooledSurface(Group^.Surface, RectangleWidth(Bounds), RectangleHeight(Bounds)) then
  begin
    Group^.Surface.Pixels := nil;
    Exit;
  end;
  BeginCanvas(Raster.Canvas, Group^.Surface);
  Inc(Raster.ShiftX, Bounds.Left);
  Inc(Raster.ShiftY, Bounds.Top);
end;

{ The group's drawing filtered, then put on the surface below (within
  its clips). }
procedure PopFilter(var Raster: TRaster);
var
  Group: PGroup;
begin
  if not LeaveGroup(Raster, Group) then
    Exit;
  ApplyFilterOperations(Group^.Surface, Raster.List.Filters[Group^.Filter], Raster.View.Scale);
  DrawSurface(Raster.Canvas, Group^.Surface, MakeRectangle(0, 0, Group^.Surface.Width, Group^.Surface.Height),
    Group^.Left, Group^.Top, True, 255);
  ReturnPooledSurface(Group^.Surface);
end;

procedure PushMaskLayer(var Raster: TRaster; const Item: TDisplayItem; PushIndex: Integer);
begin
  PushGroup(Raster, Item, PushIndex);
  Raster.Groups[Raster.GroupDepth - 1].Composite := TMaskComposite(Item.Index);
end;

{ CSS Masking 7.2: the layer (source) over the layers below it
  (destination), by alpha; outside the layer's area its alpha is 0. }
function CompositeAlpha(Source, Destination: LongWord; Composite: TMaskComposite): LongWord; inline;
begin
  case Composite of
    mcSubtract: Result := Source * (255 - Destination) div 255;
    mcIntersect: Result := Source * Destination div 255;
    mcExclude: Result := (Source * (255 - Destination) + Destination * (255 - Source)) div 255;
  else
    Result := Source + Destination * (255 - Source) div 255;
  end;
end;

procedure PopMaskLayer(var Raster: TRaster);
var
  Group: PGroup;
  Row, Column, Left, Top: LongInt;
  Line, Source: PLongWord;
  SourceAlpha: LongWord;
begin
  if not LeaveGroup(Raster, Group) then
    Exit;
  for Row := 0 to Raster.Canvas.Surface.Height - 1 do
  begin
    Line := SurfaceLine(Raster.Canvas.Surface, Row);
    Top := Row - Group^.Top;
    for Column := 0 to Raster.Canvas.Surface.Width - 1 do
    begin
      Left := Column - Group^.Left;
      SourceAlpha := 0;
      if (Top >= 0) and (Top < Group^.Surface.Height) and (Left >= 0) and (Left < Group^.Surface.Width) then
      begin
        Source := SurfaceLine(Group^.Surface, Top);
        SourceAlpha := AlphaOf(Source[Left]);
      end;
      if (SourceAlpha = 0) and (Group^.Composite <> mcIntersect) then
        Continue;
      Line[Column] := ArgbColor(Byte(CompositeAlpha(SourceAlpha, AlphaOf(Line[Column]), Group^.Composite)), 0, 0, 0);
    end;
  end;
  ReturnPooledSurface(Group^.Surface);
end;

procedure PopMask(var Raster: TRaster);
var
  Group: PGroup;
  Row, Column: LongInt;
  Source, Mask, Target: PLongWord;
  Alpha: Byte;
begin
  if not LeaveGroup(Raster, Group) then
    Exit;
  if Group^.MaskSurface.Pixels <> nil then
    for Row := 0 to Group^.Surface.Height - 1 do
    begin
      Source := SurfaceLine(Group^.Surface, Row);
      Mask := SurfaceLine(Group^.MaskSurface, Row);
      Target := SurfaceLine(Raster.Canvas.Surface, Group^.Top + Row) + Group^.Left;
      for Column := 0 to Group^.Surface.Width - 1 do
      begin
        Alpha := AlphaOf(Mask[Column]);
        if (Alpha > 0) and (AlphaOf(Source[Column]) > 0) then
          Target[Column] := BlendColors(Target[Column], FadeColor(Source[Column], Alpha));
      end;
    end;
  ReturnPooledSurface(Group^.MaskSurface);
  ReturnPooledSurface(Group^.Surface);
end;

{ A frame's document paints itself into the frame's content box, within
  the clip (rounded clips are taken as their bounds). }
procedure DrawFrame(var Raster: TRaster; const Item: TDisplayItem);
var
  Bounds, Clip: TRectangle;
  Content: TEmbeddedContent;
begin
  Content := TEmbeddedContent(Raster.List.Frames[Item.Index]);
  Bounds := DeviceRectangle(Raster, Item.X, Item.Y, Item.Width, Item.Height);
  Bounds := OffsetRectangle(Bounds, Raster.Canvas.OriginX, Raster.Canvas.OriginY);
  if not IntersectRectangles(Bounds, RegionBounds(Raster.Canvas.Clip), Clip) then
    Exit;
  Content.PaintInto(Raster.Canvas.Surface, Bounds.Left, Bounds.Top, Clip);
end;

{ ---- folding opacity into an item ---- }

{ Whether an item drawn at an opacity looks as it would in a group of
  that opacity: it touches no pixel twice (borders meet at the corners)
  and its drawing takes an opacity. Not text: glyphs are blended
  gamma-correct over an opaque surface but plainly into a group's
  transparent one, so their edges would come out a little darker. }
function TakesOpacity(const Raster: TRaster; const Item: TDisplayItem): Boolean;
begin
  case Item.Kind of
    diRectangle, diGradient, diShadow:
      Result := True;
    diImage:
      Result := ImageTakesOpacity(Raster, Item);
  else
    Result := False;
  end;
end;

{ Gecko's ApplyOpacityToChildren: an opacity group holding one item that
  takes an opacity is drawn without a group, the item at the group's
  opacity. The item's index, else -1. }
function FoldableItem(const Raster: TRaster; PushIndex: Integer): Integer;
var
  Index, PopIndex: Integer;
begin
  Result := -1;
  PopIndex := Raster.List.GroupExtents[PushIndex].PopIndex;
  if PopIndex < 0 then
    Exit;
  for Index := PushIndex + 1 to PopIndex - 1 do
  begin
    if Raster.List.Items[Index].Kind = diHitArea then
      Continue;
    if Result >= 0 then
      Exit(-1);
    Result := Index;
  end;
  if (Result >= 0) and not TakesOpacity(Raster, Raster.List.Items[Result]) then
    Result := -1;
end;

procedure DrawItem(var Raster: TRaster; const Item: TDisplayItem);
begin
  if not ItemVisible(Raster, Item) then
    Exit;
  case Item.Kind of
    diRectangle: FillBox(Raster, Item.X, Item.Y, Item.Width, Item.Height, Item.Color, Item.Index);
    diBorder: DrawBorder(Raster, Item);
    diText: DrawText(Raster, Item);
    diImage: DrawImage(Raster, Item);
    diGradient: DrawGradient(Raster, Item);
    diShadow: DrawShadow(Raster, Item);
    diControl: DrawControl(Raster, Item);
    diControlText: DrawControlText(Raster, Item);
    diFrame: DrawFrame(Raster, Item);
  end;
end;

{ An opacity group from PushIndex: nothing at all when it is fully
  transparent, its one item at its opacity when that can be, else a
  group. Index: the last item dealt with. }
procedure BeginOpacity(var Raster: TRaster; PushIndex: Integer; out Index: Integer);
var
  Item: PDisplayItem;
  Folded, PopIndex: Integer;
begin
  Item := @Raster.List.Items[PushIndex];
  Index := PushIndex;
  PopIndex := Raster.List.GroupExtents[PushIndex].PopIndex;
  if PopIndex >= 0 then
  begin
    if Round(EnsureRange(Item^.Value, 0, 1) * 255) = 0 then
    begin
      Index := PopIndex;
      Exit;
    end;
    Folded := FoldableItem(Raster, PushIndex);
    if Folded >= 0 then
    begin
      Raster.ItemOpacity := Round(EnsureRange(Item^.Value, 0, 1) * 255);
      DrawItem(Raster, Raster.List.Items[Folded]);
      Raster.ItemOpacity := 255;
      Index := PopIndex;
      Exit;
    end;
  end;
  PushGroup(Raster, Item^, PushIndex);
end;

procedure RasterizeDisplayList(List: TDisplayList; const Surface: TSurface; const View: TRasterView);
var
  Raster: TRaster;
  Index: Integer;
  Item: PDisplayItem;
  Region: TRegion;
begin
  EnsureGroupExtents(List);
  Raster.List := List;
  Raster.View := View;
  Raster.ClipStack := nil;
  Raster.RoundedClips := nil;
  Raster.ClipDepth := 0;
  Raster.Groups := nil;
  Raster.GroupDepth := 0;
  Raster.OriginX := View.ScrollX;
  Raster.OriginY := View.ScrollY;
  Raster.Origins := nil;
  Raster.OriginDepth := 0;
  Raster.ShiftX := View.ShiftX;
  Raster.ShiftY := View.ShiftY;
  Raster.Glyphs := nil;
  Raster.ItemOpacity := 255;
  BeginCanvas(Raster.Canvas, Surface);
  SetRegionToRectangle(Region, View.Damage);
  SetCanvasClip(Raster.Canvas, Region);
  FillRectangle(Raster.Canvas, View.Damage, List.CanvasColor);
  Index := 0;
  while Index < List.Count do
  begin
    Item := @List.Items[Index];
    case Item^.Kind of
      diPushClip: PushClip(Raster, Item^, Index);
      diPopClip: PopClip(Raster);
      diPushOpacity: BeginOpacity(Raster, Index, Index);
      diPopOpacity: PopGroup(Raster);
      diPushMask: PushGroup(Raster, Item^, Index);
      diPushMaskLayer: PushMaskLayer(Raster, Item^, Index);
      diPushFilter: PushFilter(Raster, Item^, Index);
      diPopFilter: PopFilter(Raster);
      diPopMaskLayer: PopMaskLayer(Raster);
      diPushTransform: PushTransform(Raster, Item^);
      diPopTransform: PopTransform(Raster);
      diMaskContent: BeginMaskContent(Raster);
      diPopMask: PopMask(Raster);
      diPushFixed: PushOrigin(Raster, 0, 0);
      diPushSticky: PushSticky(Raster, Item^);
      diPopFixed, diPopSticky: PopOrigin(Raster);
      diHitArea: ;
    else
      DrawItem(Raster, Item^);
    end;
    Inc(Index);
  end;
  while Raster.GroupDepth > 0 do
    if Raster.Groups[Raster.GroupDepth - 1].IsTransform then
      PopTransform(Raster)
    else
      PopGroup(Raster);
end;

end.
