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
  Paint's work on pixels, looked at pixel by pixel: flood fill with a
  tolerance (libimage), shapes and strokes and where they reach
  (libdrawing's new strokes, curves and rounded rectangles too), the
  freehand marks, the selection (masks, lifting, moving, putting down,
  undo, cropping), the Image menu's turns, flips, inverting and
  skewing, and the zoomed view with its checkerboard and grid.
}
unit PaintTest.Pixels;

{$mode objfpc}
{$H+}

interface

procedure TestPaintPixels;

implementation

uses
  SysUtils,
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Surfaces,
  Drawing.Canvas,
  Drawing.Rasterizer,
  Drawing.Curves,
  Drawing.SmoothStrokes,
  Image.Model,
  Image.Surfaces,
  Image.Areas,
  Image.FloodFill,
  Image.Transforms,
  Paint.ZoomMapping,
  Paint.ShapeGeometry,
  Paint.ShapeDrawing,
  Paint.Brushes,
  Paint.Document,
  Paint.Selection,
  Paint.SelectionEditing,
  Paint.ViewRendering,
  PaintTest.Checks;

const
  Red: TColor = $FFFF0000;
  Blue: TColor = $FF0000FF;

function SolidImage(Width, Height: LongInt; Color: TColor): TImage;
begin
  Result := TImage.Create(Width, Height);
  Result.Fill(Color);
end;

{ The smallest rectangle of pixels that are not Background. }
function PaintedBounds(Image: TImage; Background: TColor): TRectangle;
var
  X: LongInt;
  Y: LongInt;
begin
  Result := MakeRectangle(0, 0, 0, 0);
  for Y := 0 to Image.Height - 1 do
    for X := 0 to Image.Width - 1 do
      if Image.GetPixel(X, Y) <> Background then
        if RectangleIsEmpty(Result) then
          Result := MakeRectangle(X, Y, 1, 1)
        else
          Result := BoundingRectangle(Result, MakeRectangle(X, Y, 1, 1));
end;

function CanvasOn(Image: TImage): TCanvas;
begin
  BeginCanvas(Result, ImageSurface(Image));
end;

procedure TestFloodFill;
var
  Image: TImage;
  Changed: TRectangle;
  Mask: TBytes;
  Bounds: TRectangle;
  X: LongInt;
begin
  { A white picture with a black frame round (2,2)-(7,7) and a gap-free
    inside: filling inside stays inside. }
  Image := SolidImage(10, 10, ColorWhite);
  try
    for X := 2 to 7 do
    begin
      Image.SetPixel(X, 2, ColorBlack);
      Image.SetPixel(X, 7, ColorBlack);
      Image.SetPixel(2, X, ColorBlack);
      Image.SetPixel(7, X, ColorBlack);
    end;
    Changed := FloodFill(Image, 4, 4, Red, 0);
    CheckRectangle('fill inside a frame: the inside changed', Changed, MakeRectangle(3, 3, 4, 4));
    CheckColor('the inside is red', Image.GetPixel(5, 5), Red);
    CheckColor('the frame is untouched', Image.GetPixel(2, 4), ColorBlack);
    CheckColor('outside is untouched', Image.GetPixel(0, 0), ColorWhite);
    Changed := FloodFill(Image, 0, 0, Blue, 0);
    CheckRectangle('fill outside: the whole picture round the frame', Changed, MakeRectangle(0, 0, 10, 10));
    CheckColor('outside blue', Image.GetPixel(9, 9), Blue);
    CheckColor('inside still red', Image.GetPixel(4, 4), Red);
    Changed := FloodFill(Image, 0, 0, Blue, 0);
    Check('filling with the same colour changes nothing', RectangleIsEmpty(Changed));
    Changed := FloodFill(Image, 20, 0, Blue, 0);
    Check('outside the picture changes nothing', RectangleIsEmpty(Changed));
  finally
    Image.Free;
  end;
  { Tolerance: a gradient across the picture. }
  Image := TImage.Create(10, 1);
  try
    for X := 0 to 9 do
      Image.SetPixel(X, 0, RgbColor(X * 10, X * 10, X * 10));
    Mask := FloodFillMask(Image, 0, 0, 0, Bounds);
    CheckRectangle('no tolerance: one pixel', Bounds, MakeRectangle(0, 0, 1, 1));
    Mask := FloodFillMask(Image, 0, 0, 35, Bounds);
    CheckRectangle('a tolerance of 35 takes four steps of 10', Bounds, MakeRectangle(0, 0, 4, 1));
    Check('the mask says so', (Mask[3] = 1) and (Mask[4] = 0));
    Mask := FloodFillMask(Image, 5, 0, 10, Bounds);
    CheckRectangle('tolerance either side of the start', Bounds, MakeRectangle(4, 0, 3, 1));
    CheckNumber('100% is 255', ToleranceFromPercent(100), 255);
    CheckNumber('50% is 128', ToleranceFromPercent(50), 128);
    Check('near colours', ColorsAreNear($FF101010, $FF141010, 4) and not ColorsAreNear($FF101010, $FF151010, 4));
    Check('alpha counts too', not ColorsAreNear($FF101010, $00101010, 10));
  finally
    Image.Free;
  end;
  { A large picture fills without trouble (the run stack, not
    recursion). }
  Image := SolidImage(1000, 1000, ColorWhite);
  try
    for X := 0 to 998 do
      Image.SetPixel(X, (X * 7) mod 1000, ColorBlack);
    Changed := FloodFill(Image, 999, 999, Red, 0);
    Check('a large fill', not RectangleIsEmpty(Changed) and (Image.GetPixel(999, 999) = Red));
  finally
    Image.Free;
  end;
end;

procedure TestShapes;
var
  Image: TImage;
  Canvas: TCanvas;
  Bounds: TRectangle;
  Style: TShapeStyle;
  Points: array[0..2] of TPoint;
  Curve: TPrecisePoints;
begin
  Image := SolidImage(60, 40, ColorWhite);
  try
    Canvas := CanvasOn(Image);
    Bounds := RectangleFromCorners(10, 5, 30, 20);
    DrawRectangleShape(Canvas, Bounds, MakeShapeStyle(FillStyleOutline, 3, ColorBlack, Red));
    CheckRectangle('rectangle outline: exactly its corners', PaintedBounds(Image, ColorWhite), Bounds);
    CheckColor('outline 3 wide: its third pixel', Image.GetPixel(12, 12), ColorBlack);
    CheckColor('outline 3 wide: the fourth is inside', Image.GetPixel(13, 12), ColorWhite);
    CheckColor('outline crisp at its corner', Image.GetPixel(30, 20), ColorBlack);
    Image.Fill(ColorWhite);
    DrawRectangleShape(Canvas, Bounds, MakeShapeStyle(FillStyleOutlineAndInterior, 2, ColorBlack, Red));
    CheckColor('outline and interior: the interior', Image.GetPixel(20, 12), Red);
    CheckColor('outline and interior: the outline', Image.GetPixel(11, 12), ColorBlack);
    Image.Fill(ColorWhite);
    DrawRectangleShape(Canvas, Bounds, MakeShapeStyle(FillStyleInterior, 2, ColorBlack, Red));
    CheckColor('interior only: right to the corner', Image.GetPixel(10, 5), Red);
    Image.Fill(ColorWhite);
    DrawEllipseShape(Canvas, Bounds, MakeShapeStyle(FillStyleOutlineAndInterior, 2, ColorBlack, Red));
    Check('ellipse within its bounds', RectangleContains(Bounds, PaintedBounds(Image, ColorWhite)));
    CheckColor('ellipse filled in the middle', Image.GetPixel(20, 12), Red);
    CheckColor('ellipse leaves the corner', Image.GetPixel(10, 5), ColorWhite);
    Image.Fill(ColorWhite);
    DrawRoundedRectangleShape(Canvas, Bounds, MakeShapeStyle(FillStyleInterior, 1, ColorBlack, Red));
    Check('rounded rectangle within its bounds', RectangleContains(Bounds, PaintedBounds(Image, ColorWhite)));
    CheckColor('rounded rectangle: the corner left out', Image.GetPixel(10, 5), ColorWhite);
    CheckColor('rounded rectangle: the middle of a side in', Image.GetPixel(20, 5), Red);
    Image.Fill(ColorWhite);
    DrawLineShape(Canvas, 5, 30, 50, 30, 5, ColorBlack);
    Check('a thick line within its stroke extent', RectangleContains(StrokeExtent([MakePoint(5, 30),
      MakePoint(50, 30)], 5), PaintedBounds(Image, ColorWhite)));
    CheckColor('a thick line: solid two pixels off its middle', Image.GetPixel(30, 32), ColorBlack);
    Check('round ends: past the end point', Image.GetPixel(52, 30) <> ColorWhite);
    Check('round ends: the corner a square end would fill is not solid', Image.GetPixel(52, 32) <> ColorBlack);
    Image.Fill(ColorWhite);
    Points[0] := MakePoint(10, 5);
    Points[1] := MakePoint(40, 5);
    Points[2] := MakePoint(25, 30);
    Style := MakeShapeStyle(FillStyleInterior, 1, ColorBlack, Blue);
    DrawPolygonShape(Canvas, Points, Style);
    CheckColor('polygon filled inside', Image.GetPixel(25, 12), Blue);
    CheckColor('polygon not outside', Image.GetPixel(12, 25), ColorWhite);
    Check('polygon within its points', RectangleContains(StrokeExtent(Points, 1), PaintedBounds(Image, ColorWhite)));
    Image.Fill(ColorWhite);
    DrawCurveShape(Canvas, MakePoint(5, 35), MakePoint(55, 35), [MakePoint(30, 0)], 3, ColorBlack);
    Check('a curve bends towards its control point', Image.GetPixel(30, 17) <> ColorWhite);
    CheckColor('but does not reach it', Image.GetPixel(30, 3), ColorWhite);
    Curve := FlattenCubicCurve(PrecisePoint(0, 0), PrecisePoint(0, 30), PrecisePoint(30, 30), PrecisePoint(30, 0));
    Check('a cubic curve starts and ends at its ends', (Curve[0].X = 0) and (Curve[High(Curve)].X = 30) and
      (Length(Curve) > 4));
    Curve := FlattenQuadraticCurve(PrecisePoint(0, 0), PrecisePoint(5, 0), PrecisePoint(10, 0));
    CheckNumber('a straight quadratic is one piece', Length(Curve), 2);
  finally
    Image.Free;
  end;
end;

procedure TestStrokes;
var
  Image: TImage;
  Canvas: TCanvas;
  Seed: LongWord;
  Count: LongInt;
  X: LongInt;
  Y: LongInt;
begin
  Image := SolidImage(40, 40, ColorWhite);
  try
    Canvas := CanvasOn(Image);
    DrawSmoothDot(Canvas, 20, 20, 9, ColorBlack);
    CheckColor('a dot: solid in the middle', Image.GetPixel(20, 20), ColorBlack);
    CheckColor('a dot: solid at radius 3', Image.GetPixel(23, 20), ColorBlack);
    CheckColor('a dot: nothing at radius 6', Image.GetPixel(26, 20), ColorWhite);
    CheckColor('a dot: round, not square', Image.GetPixel(24, 24), ColorWhite);
    Image.Fill(ColorWhite);
    DrawPencilLine(Canvas, 0, 0, 9, 9, ColorBlack);
    CheckRectangle('pencil: exact pixels', PaintedBounds(Image, ColorWhite), MakeRectangle(0, 0, 10, 10));
    CheckColor('pencil: solid', Image.GetPixel(5, 5), ColorBlack);
    Image.Fill(ColorWhite);
    DrawEraserLine(Canvas, 10, 10, 20, 10, 4, Red);
    CheckRectangle('eraser: its square all the way', PaintedBounds(Image, ColorWhite), MakeRectangle(8, 8, 14, 4));
    Image.Fill(ColorWhite);
    Seed := 1234;
    SprayAirbrush(Canvas, 20, 20, 10, ColorBlack, Seed);
    Check('airbrush within its circle', RectangleContains(AirbrushExtent(20, 20, 10),
      PaintedBounds(Image, ColorWhite)));
    Count := 0;
    for Y := 0 to 39 do
      for X := 0 to 39 do
        if Image.GetPixel(X, Y) <> ColorWhite then
          Inc(Count);
    Check('airbrush sprays some dots, not all', (Count > 3) and (Count < 81));
    Image.Fill(ColorWhite);
    DrawBrushLine(Canvas, 5, 5, 30, 5, 4, ColorBlack);
    CheckColor('brush solid along its middle', Image.GetPixel(15, 5), ColorBlack);
    Check('brush anti-aliased at its edge', (Image.GetPixel(15, 7) <> ColorBlack) and
      (Image.GetPixel(15, 7) <> ColorWhite));
  finally
    Image.Free;
  end;
end;

procedure TestSelection;
var
  Selection: TSelection;
  Document: TPaintDocument;
  Editor: TSelectionEditor;
  Copied: TImage;
  Area: TRectangle;
  Triangle: array[0..2] of TPoint;
begin
  Selection := TSelection.Create;
  try
    Selection.SetRectangle(MakeRectangle(2, 3, 4, 5));
    Check('a rectangle selection contains its pixels', Selection.Contains(2, 3) and Selection.Contains(5, 7) and
      not Selection.Contains(6, 7) and Selection.IsRectangular);
    Triangle[0] := MakePoint(0, 0);
    Triangle[1] := MakePoint(10, 0);
    Triangle[2] := MakePoint(0, 10);
    Selection.SetFreeForm(Triangle);
    CheckRectangle('free-form bounds hold its line', Selection.Bounds, MakeRectangle(0, 0, 11, 11));
    Check('free-form: inside the triangle', Selection.Contains(2, 2));
    Check('free-form: outside it', not Selection.Contains(9, 9));
    Selection.MoveBy(5, 5);
    Check('moved: the mask moves along', Selection.Contains(7, 7) and not Selection.Contains(2, 2));
    Check('moved: the outline too', (Selection.OutlinePoints[1].X = 15) and (Selection.OutlinePoints[1].Y = 5));
  finally
    Selection.Free;
  end;
  Document := TPaintDocument.Create(SolidImage(20, 20, ColorWhite));
  Editor := TSelectionEditor.Create(Document);
  try
    Document.Image.SetPixel(2, 2, Red);
    Document.MarkSaved;
    Editor.SelectRectangle(MakeRectangle(0, 0, 5, 5));
    Editor.Lift(False, Blue);
    Check('lifted: floating', Editor.IsFloating);
    CheckColor('lifted: its place takes the background colour', Document.Image.GetPixel(2, 2), Blue);
    Editor.MoveBy(10, 10);
    Editor.PutDown;
    Check('put down: not floating, still selected', not Editor.IsFloating and Editor.Selection.Active);
    CheckColor('put down where it was moved', Document.Image.GetPixel(12, 12), Red);
    CheckNumber('moving is one step', Document.History.UndoCount, 1);
    Check('moving made changes', Document.Modified);
    Editor.Forget;
    Document.Undo(Area);
    CheckRectangle('the step covers where it came from and went', Area, MakeRectangle(0, 0, 15, 15));
    CheckColor('undone: back where it was', Document.Image.GetPixel(2, 2), Red);
    CheckColor('undone: gone from where it went', Document.Image.GetPixel(12, 12), ColorWhite);
    { Copy (Ctrl): the picture keeps the pixels. }
    Editor.SelectRectangle(MakeRectangle(0, 0, 5, 5));
    Editor.Lift(True, Blue);
    Editor.MoveBy(5, 0);
    Editor.Deselect;
    Check('copied: both there', (Document.Image.GetPixel(2, 2) = Red) and (Document.Image.GetPixel(7, 2) = Red));
    Check('deselected', not Editor.Selection.Active);
    { Copy out, paste back in. }
    Editor.SelectRectangle(MakeRectangle(1, 1, 3, 3));
    Copied := Editor.CopySelected;
    Check('copied pixels', (Copied.Width = 3) and (Copied.GetPixel(1, 1) = Red));
    Editor.PasteImage(Copied, 15, 15);
    Check('pasted: floating at its place', Editor.IsFloating and (Editor.Area.Left = 15));
    CheckColor('pasted: not on the picture until put down', Document.Image.GetPixel(16, 16), ColorWhite);
    Editor.PutDown;
    CheckColor('pasted and put down', Document.Image.GetPixel(16, 16), Red);
    { Delete clears to the background colour. }
    Editor.SelectRectangle(MakeRectangle(15, 15, 3, 3));
    Editor.DeleteSelected(Blue);
    CheckColor('deleted', Document.Image.GetPixel(16, 16), Blue);
    { A selection reaching past the picture is cut to it. }
    Editor.SelectRectangle(MakeRectangle(18, 18, 10, 10));
    CheckRectangle('selection cut to the picture', Editor.Area, MakeRectangle(18, 18, 2, 2));
    { Crop. }
    Editor.SelectRectangle(MakeRectangle(1, 1, 3, 4));
    Check('cropped', Editor.CropToSelection);
    Check('cropped size', (Document.Image.Width = 3) and (Document.Image.Height = 4));
    CheckColor('cropped pixels', Document.Image.GetPixel(1, 1), Red);
    Document.Undo(Area);
    CheckNumber('crop undone', Document.Image.Width, 20);
    { A free-form selection lifts only what is inside. }
    Document.Image.Fill(Red);
    Editor.SelectFreeForm(Triangle);
    Editor.Lift(False, ColorWhite);
    CheckColor('free-form lift: inside cleared', Document.Image.GetPixel(2, 2), ColorWhite);
    CheckColor('free-form lift: outside kept', Document.Image.GetPixel(9, 9), Red);
    CheckColor('free-form floating: transparent outside', Editor.Floating.GetPixel(9, 9), ColorTransparent);
    Editor.Deselect;
  finally
    Editor.Free;
    Document.Free;
  end;
end;

procedure TestTransforms;
var
  Image: TImage;
  Turned: TImage;
begin
  Image := SolidImage(3, 2, ColorWhite);
  try
    Image.SetPixel(0, 0, Red);
    Turned := RotateImageClockwise(Image);
    Check('clockwise: sides swapped, the top left goes top right',
      (Turned.Width = 2) and (Turned.Height = 3) and (Turned.GetPixel(1, 0) = Red));
    Turned.Free;
    Turned := RotateImageAnticlockwise(Image);
    Check('anticlockwise: the top left goes bottom left', Turned.GetPixel(0, 2) = Red);
    Turned.Free;
    Turned := RotateImageHalfTurn(Image);
    Check('half turn: the top left goes bottom right', Turned.GetPixel(2, 1) = Red);
    Turned.Free;
    FlipImageHorizontally(Image);
    CheckColor('flipped across', Image.GetPixel(2, 0), Red);
    FlipImageVertically(Image);
    CheckColor('flipped up and down', Image.GetPixel(2, 1), Red);
    InvertImageColors(Image);
    CheckColor('inverted: red is cyan', Image.GetPixel(2, 1), $FF00FFFF);
    CheckColor('inverted: white is black', Image.GetPixel(0, 0), ColorBlack);
  finally
    Image.Free;
  end;
  Image := SolidImage(10, 10, Red);
  try
    Turned := SkewImage(Image, 45, 0, ColorWhite);
    Check('skewed 45 degrees across: wider by the height', (Turned.Width = 19) and (Turned.Height = 10));
    CheckColor('the top line starts at the left', Turned.GetPixel(0, 0), Red);
    CheckColor('the bottom line moved right', Turned.GetPixel(0, 9), ColorWhite);
    CheckColor('the bottom line ends at the right', Turned.GetPixel(18, 9), Red);
    Turned.Free;
    Turned := SkewImage(Image, 0, -45, ColorWhite);
    Check('skewed up: taller', (Turned.Width = 10) and (Turned.Height = 19));
    CheckColor('the right column is up', Turned.GetPixel(9, 0), Red);
    Turned.Free;
  finally
    Image.Free;
  end;
end;

procedure TestViewRendering;
var
  Image: TImage;
  Target: TSurface;
  Mapping: TViewMapping;
  Floating: TFloatingPixels;
begin
  Image := SolidImage(4, 4, ColorBlack);
  try
    Image.SetPixel(1, 0, Red);
    Image.SetPixel(2, 0, ColorTransparent);
    CreateSurface(Target, 20, 10, 0);
    { 400%, the picture at (2, 2). }
    Mapping := MakeViewMapping(4000, 2, 2, 0, 0);
    RenderPictureView(Target, MakeRectangle(0, 0, 20, 10), Image, NoFloatingPixels, Mapping, False, $FF808080);
    CheckColor('outside the picture: the workspace', GetSurfacePixel(Target, 0, 0), $FF808080);
    CheckColor('the first pixel at 400%', GetSurfacePixel(Target, 5, 5), ColorBlack);
    CheckColor('the second pixel, four view pixels on', GetSurfacePixel(Target, 7, 3), Red);
    CheckColor('transparent shows the checkerboard', GetSurfacePixel(Target, 11, 3), CheckerDark);
    RenderPictureView(Target, MakeRectangle(0, 0, 20, 10), Image, NoFloatingPixels, Mapping, True, $FF808080);
    Check('the grid darkens the first view pixel of a pixel', GetSurfacePixel(Target, 6, 3) <> Red);
    CheckColor('but not the rest', GetSurfacePixel(Target, 7, 3), Red);
    { A floating pixel over the picture. }
    Floating := NoFloatingPixels;
    Floating.Image := SolidImage(1, 1, Blue);
    Floating.Left := 0;
    Floating.Top := 1;
    RenderPictureView(Target, MakeRectangle(0, 0, 20, 10), Image, Floating, Mapping, False, $FF808080);
    CheckColor('floating pixels drawn over the picture', GetSurfacePixel(Target, 3, 7), Blue);
    Floating.Image.Free;
    FreeSurface(Target);
  finally
    Image.Free;
  end;
end;

procedure TestPaintPixels;
begin
  TestFloodFill;
  TestShapes;
  TestStrokes;
  TestSelection;
  TestTransforms;
  TestViewRendering;
end;

end.
