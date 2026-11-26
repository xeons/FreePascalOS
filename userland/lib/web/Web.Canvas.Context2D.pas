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
  CanvasRenderingContext2D's drawing (HTML Standard 4.12.5.1), the part
  that does not depend on script: the state stack, transforms, the
  current default path, filling, stroking (in user space, then
  transformed, so non-uniform scales give the right outlines; dashes
  and caps from libdrawing), clipping, hit testing, rectangles, text,
  images and pixel access, all through the drawing model of
  Web.Canvas.Rendering. OffscreenCanvasRenderingContext2D is the same
  class on an offscreen surface. The bindings (Web.Bindings.Canvas)
  turn script values into these calls.
}
unit Web.Canvas.Context2D;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Transforms,
  Drawing.Rasterizer,
  Drawing.Paths,
  Drawing.Paints,
  Drawing.Surfaces,
  Image.Model,
  Web.Canvas.Surfaces,
  Web.Canvas.Paths,
  Web.Canvas.Styles,
  Web.Canvas.Text,
  Web.Canvas.State,
  Web.Canvas.Rendering;

type
  ECanvasInvalidStateError = class(Exception);
  ECanvasSecurityError = class(Exception);

  { A source of drawImage and createPattern: its pixels and the part to
    use (whole pixels of Image). }
  TCanvasImageSource = record
    Image: TImage;
    Width, Height: Double;
    OriginClean: Boolean;
  end;

  TCanvasContext2D = class(TCanvasContextBase)
  private
    FState: TCanvasDrawingState;
    FStack: array of TCanvasDrawingState;
    FPath: TCanvasPath;
    FAlpha: Boolean;
    FWillReadFrequently: Boolean;
    function Settings: TCanvasDrawSettings;
    procedure DrawShape(const Shape: TCoverageShape; Rule: TFillRule; const Style: TCanvasPaintStyle);
    function FillShapeOf(const Path: TPath; const Transform: TAffineTransform): TCoverageShape;
    function StrokeShapeOf(const Path: TPath; const PathTransform: TAffineTransform): TCoverageShape;
    procedure KeepOpaque;
    procedure Touched;
  public
    constructor Create(Alpha, WillReadFrequently: Boolean);
    destructor Destroy; override;
    procedure SurfaceReset; override;
    function Bitmap: TImage;

    { The state }
    procedure Save;
    procedure Restore;
    procedure Reset;
    function IsContextLost: Boolean;
    property State: TCanvasDrawingState read FState write FState;
    { For setters that change the state in place. }
    function StateRef: PCanvasDrawingState;

    { Transforms }
    procedure Scale(X, Y: Double);
    procedure Rotate(Angle: Double);
    procedure Translate(X, Y: Double);
    procedure Transform(A, B, C, D, E, F: Double);
    procedure SetTransform(A, B, C, D, E, F: Double);
    procedure ResetTransform;

    { Styles }
    procedure SetFillStyle(const Style: TCanvasPaintStyle);
    procedure SetStrokeStyle(const Style: TCanvasPaintStyle);
    procedure SetLineDash(const Segments: array of Double);

    { Rectangles }
    procedure ClearRect(X, Y, Width, Height: Double);
    procedure FillRect(X, Y, Width, Height: Double);
    procedure StrokeRect(X, Y, Width, Height: Double);

    { Paths: Path nil is the current default path; a Path2D's points are
      in user space and go through the current transform. }
    procedure BeginPath;
    function CurrentPath: PCanvasPath;
    procedure Fill(Path: PCanvasPath; Rule: TFillRule);
    procedure Stroke(Path: PCanvasPath);
    procedure Clip(Path: PCanvasPath; Rule: TFillRule);
    function IsPointInPath(Path: PCanvasPath; X, Y: Double; Rule: TFillRule): Boolean;
    function IsPointInStroke(Path: PCanvasPath; X, Y: Double): Boolean;

    { Text }
    procedure FillText(const Text: string; X, Y: Double; HasMaxWidth: Boolean; MaxWidth: Double);
    procedure StrokeText(const Text: string; X, Y: Double; HasMaxWidth: Boolean; MaxWidth: Double);
    function MeasureText(const Text: string): TCanvasTextMeasure;

    { Images: the source rectangle in Source's coordinates. }
    procedure DrawImage(const Source: TCanvasImageSource; SX, SY, SW, SH, DX, DY, DW, DH: Double);

    { Pixels as RGBA bytes, row by row (not premultiplied). }
    procedure GetImageBytes(X, Y, Width, Height: LongInt; Target: PByte);
    { Writes the dirty part of a Width x Height RGBA image at (DX, DY). }
    procedure PutImageBytes(Source: PByte; Width, Height: LongInt; DX, DY, DirtyX, DirtyY, DirtyWidth,
      DirtyHeight: LongInt);

    property Alpha: Boolean read FAlpha;
    property WillReadFrequently: Boolean read FWillReadFrequently;
  end;

implementation

uses
  Math,
  Drawing.Curves,
  Drawing.Stroking,
  Drawing.Dashing,
  Drawing.Compositing;

{ Points in polylines: the winding number of (X, Y). }
function WindingOf(const Lines: TPolylines; X, Y: Double; EvenOdd: Boolean): Boolean;
var
  LineIndex, Index, Count, Winding, Crossings: LongInt;
  A, B: TPrecisePoint;
  Side: Double;
begin
  Winding := 0;
  Crossings := 0;
  for LineIndex := 0 to High(Lines) do
  begin
    Count := Lines[LineIndex].Count;
    if Count < 2 then
      Continue;
    for Index := 0 to Count - 1 do
    begin
      A := Lines[LineIndex].Points[Index];
      B := Lines[LineIndex].Points[(Index + 1) mod Count];
      { A point on an edge is inside. }
      Side := (B.X - A.X) * (Y - A.Y) - (X - A.X) * (B.Y - A.Y);
      if (Abs(Side) < 1E-9) and (X >= Min(A.X, B.X) - 1E-9) and (X <= Max(A.X, B.X) + 1E-9) and
         (Y >= Min(A.Y, B.Y) - 1E-9) and (Y <= Max(A.Y, B.Y) + 1E-9) then
        Exit(True);
      if A.Y <= Y then
      begin
        if (B.Y > Y) and (Side > 0) then
        begin
          Inc(Winding);
          Inc(Crossings);
        end;
      end
      else if (B.Y <= Y) and (Side < 0) then
      begin
        Dec(Winding);
        Inc(Crossings);
      end;
    end;
  end;
  if EvenOdd then
    Result := Odd(Crossings)
  else
    Result := Winding <> 0;
end;

constructor TCanvasContext2D.Create(Alpha, WillReadFrequently: Boolean);
begin
  inherited Create;
  FAlpha := Alpha;
  FWillReadFrequently := WillReadFrequently;
  FState := DefaultDrawingState;
  ClearCanvasPath(FPath);
end;

destructor TCanvasContext2D.Destroy;
var
  Index: Integer;
begin
  ReleaseDrawingState(FState);
  for Index := 0 to High(FStack) do
    ReleaseDrawingState(FStack[Index]);
  inherited Destroy;
end;

function TCanvasContext2D.Bitmap: TImage;
begin
  if Surface = nil then
    Exit(nil);
  Result := Surface.Bitmap;
end;

procedure TCanvasContext2D.KeepOpaque;
var
  Image: TImage;
  Index: PtrInt;
begin
  Image := Bitmap;
  if FAlpha or (Image = nil) then
    Exit;
  for Index := 0 to PtrInt(Image.Width) * Image.Height - 1 do
    Image.Pixels[Index] := Image.Pixels[Index] or $FF000000;
end;

procedure TCanvasContext2D.Touched;
begin
  if Surface <> nil then
    Surface.Changed;
end;

procedure TCanvasContext2D.SurfaceReset;
begin
  Reset;
end;

function TCanvasContext2D.StateRef: PCanvasDrawingState;
begin
  Result := @FState;
end;

procedure TCanvasContext2D.Save;
begin
  SetLength(FStack, Length(FStack) + 1);
  FStack[High(FStack)] := CopyDrawingState(FState);
end;

procedure TCanvasContext2D.Restore;
begin
  if Length(FStack) = 0 then
    Exit;
  ReleaseDrawingState(FState);
  FState := FStack[High(FStack)];
  FStack[High(FStack)] := Default(TCanvasDrawingState);
  SetLength(FStack, Length(FStack) - 1);
end;

procedure TCanvasContext2D.Reset;
var
  Index: Integer;
  Image: TImage;
begin
  for Index := 0 to High(FStack) do
    ReleaseDrawingState(FStack[Index]);
  FStack := nil;
  ReleaseDrawingState(FState);
  FState := DefaultDrawingState;
  ClearCanvasPath(FPath);
  Image := Bitmap;
  if Image <> nil then
  begin
    if FAlpha then
      Image.Fill(ColorTransparent)
    else
      Image.Fill(ColorBlack);
  end;
  Touched;
end;

function TCanvasContext2D.IsContextLost: Boolean;
begin
  Result := False;
end;

{ Transforms }

procedure TCanvasContext2D.Scale(X, Y: Double);
begin
  if not AllFinite([X, Y]) then
    Exit;
  FState.Transform := CombineTransforms(FState.Transform, ScalingTransform(X, Y));
end;

procedure TCanvasContext2D.Rotate(Angle: Double);
begin
  if not AllFinite([Angle]) then
    Exit;
  FState.Transform := CombineTransforms(FState.Transform, MakeTransform(Cos(Angle), Sin(Angle), -Sin(Angle),
    Cos(Angle), 0, 0));
end;

procedure TCanvasContext2D.Translate(X, Y: Double);
begin
  if not AllFinite([X, Y]) then
    Exit;
  FState.Transform := CombineTransforms(FState.Transform, TranslationTransform(X, Y));
end;

procedure TCanvasContext2D.Transform(A, B, C, D, E, F: Double);
begin
  if not AllFinite([A, B, C, D, E, F]) then
    Exit;
  FState.Transform := CombineTransforms(FState.Transform, MakeTransform(A, B, C, D, E, F));
end;

procedure TCanvasContext2D.SetTransform(A, B, C, D, E, F: Double);
begin
  if not AllFinite([A, B, C, D, E, F]) then
    Exit;
  FState.Transform := MakeTransform(A, B, C, D, E, F);
end;

procedure TCanvasContext2D.ResetTransform;
begin
  FState.Transform := IdentityTransform;
end;

{ Styles }

procedure TCanvasContext2D.SetFillStyle(const Style: TCanvasPaintStyle);
begin
  AssignStyle(FState.FillStyle, Style);
end;

procedure TCanvasContext2D.SetStrokeStyle(const Style: TCanvasPaintStyle);
begin
  AssignStyle(FState.StrokeStyle, Style);
end;

procedure TCanvasContext2D.SetLineDash(const Segments: array of Double);
var
  Index, Count: Integer;
begin
  for Index := 0 to High(Segments) do
    if not AllFinite([Segments[Index]]) or (Segments[Index] < 0) then
      Exit;
  Count := Length(Segments);
  FState.LineDash := nil;
  if Odd(Count) then
    SetLength(FState.LineDash, Count * 2)
  else
    SetLength(FState.LineDash, Count);
  for Index := 0 to High(FState.LineDash) do
    FState.LineDash[Index] := Segments[Index mod Count];
end;

{ Drawing }

function TCanvasContext2D.Settings: TCanvasDrawSettings;
begin
  Result.Operation := FState.Operation;
  Result.GlobalAlpha := FState.GlobalAlpha;
  Result.Shadow.Color := FState.ShadowColor;
  Result.Shadow.OffsetX := FState.ShadowOffsetX;
  Result.Shadow.OffsetY := FState.ShadowOffsetY;
  Result.Shadow.Blur := FState.ShadowBlur;
  Result.Filter := FState.Filter;
  Result.Clip := FState.Clip;
end;

procedure TCanvasContext2D.DrawShape(const Shape: TCoverageShape; Rule: TFillRule; const Style: TCanvasPaintStyle);
var
  Image: TImage;
  Paint: TPaint;
  Layer: TCanvasLayer;
  DrawSettings: TCanvasDrawSettings;
  Painted: Boolean;
begin
  Image := Bitmap;
  if Image = nil then
    Exit;
  DrawSettings := Settings;
  Painted := StylePaint(Style, FState.Transform, FState.ImageSmoothingEnabled, Paint);
  if Painted then
    MakeShapeLayer(Shape, Rule, Paint, DrawingInterestArea(Image.Width, Image.Height, DrawSettings), Layer)
  else
  begin
    Layer.Area := MakeRectangle(0, 0, 0, 0);
    Layer.Pixels := nil;
  end;
  DrawLayer(Image, Layer, DrawSettings);
  if DrawSettings.Operation <> CompositeSourceOver then
    KeepOpaque;
  Touched;
end;

function TCanvasContext2D.FillShapeOf(const Path: TPath; const Transform: TAffineTransform): TCoverageShape;
begin
  BeginShape(Result);
  AddPolylinesToShape(Result, FlattenPath(Path, Transform, DefaultFlatteningTolerance));
end;

function TCanvasContext2D.StrokeShapeOf(const Path: TPath; const PathTransform: TAffineTransform): TCoverageShape;
var
  ToUser, PathToUser: TAffineTransform;
  Lines, Pieces: TPolylines;
  Style: TStrokeStyle;
  Tolerance, Scale_: Double;
begin
  BeginShape(Result);
  if not InvertTransform(FState.Transform, ToUser) then
    Exit;
  { The path in the user space of the current transform. }
  PathToUser := CombineTransforms(ToUser, PathTransform);
  Scale_ := TransformScale(FState.Transform);
  if Scale_ <= 0 then
    Exit;
  Tolerance := DefaultFlatteningTolerance / Scale_;
  Lines := FlattenPath(Path, PathToUser, Tolerance);
  if Length(FState.LineDash) > 0 then
    Lines := DashPolylines(Lines, FState.LineDash, FState.LineDashOffset);
  Style := DefaultStrokeStyle(FState.LineWidth);
  Style.Cap := FState.LineCap;
  Style.Join := FState.LineJoin;
  Style.MiterLimit := FState.MiterLimit;
  Pieces := StrokePolylines(Lines, Style, Tolerance);
  TransformPolylines(Pieces, FState.Transform);
  AddPolylinesToShape(Result, Pieces);
end;

{ Rectangles }

procedure TCanvasContext2D.ClearRect(X, Y, Width, Height: Double);
var
  Image: TImage;
  Path: TCanvasPath;
  Shape: TCoverageShape;
  Area: TRectangle;
  Coverage: TCoverageBytes;
  Row, Column, AreaWidth: LongInt;
  Weight: LongWord;
  Cleared: TColor;
  Line: PLongWord;
begin
  Image := Bitmap;
  if (Image = nil) or not AllFinite([X, Y, Width, Height]) or (Width = 0) or (Height = 0) then
    Exit;
  ClearCanvasPath(Path);
  CanvasRect(Path, FState.Transform, X, Y, Width, Height);
  Shape := FillShapeOf(Path.Path, IdentityTransform);
  if not IntersectRectangles(ShapeSurfaceBounds(Shape, 0, 0), MakeRectangle(0, 0, Image.Width, Image.Height),
     Area) then
    Exit;
  if FAlpha then
    Cleared := ColorTransparent
  else
    Cleared := ColorBlack;
  Coverage := ShapeCoverageBytes(Shape, Area, FillRuleNonZero);
  AreaWidth := RectangleWidth(Area);
  for Row := 0 to RectangleHeight(Area) - 1 do
  begin
    Line := Image.Line(Area.Top + Row);
    for Column := 0 to AreaWidth - 1 do
    begin
      Weight := Coverage[Row * AreaWidth + Column];
      if FState.Clip <> nil then
        Weight := (Weight * FState.Clip[(Area.Top + Row) * Image.Width + Area.Left + Column] + 127) div 255;
      if Weight = 0 then
        Continue;
      if Weight = 255 then
        Line[Area.Left + Column] := Cleared
      else if FAlpha then
        Line[Area.Left + Column] := CompositeColors(Line[Area.Left + Column], WithAlpha(ColorBlack, Weight),
          CompositeDestinationOut)
      else
        Line[Area.Left + Column] := MixColors(Line[Area.Left + Column], ColorBlack, Weight);
    end;
  end;
  Touched;
end;

procedure TCanvasContext2D.FillRect(X, Y, Width, Height: Double);
var
  Path: TCanvasPath;
begin
  if not AllFinite([X, Y, Width, Height]) or (Width = 0) or (Height = 0) then
    Exit;
  ClearCanvasPath(Path);
  CanvasRect(Path, FState.Transform, X, Y, Width, Height);
  DrawShape(FillShapeOf(Path.Path, IdentityTransform), FillRuleNonZero, FState.FillStyle);
end;

procedure TCanvasContext2D.StrokeRect(X, Y, Width, Height: Double);
var
  Path: TCanvasPath;
begin
  if not AllFinite([X, Y, Width, Height]) or ((Width = 0) and (Height = 0)) then
    Exit;
  ClearCanvasPath(Path);
  if (Width = 0) or (Height = 0) then
  begin
    CanvasMoveTo(Path, FState.Transform, X, Y);
    CanvasLineTo(Path, FState.Transform, X + Width, Y + Height);
  end
  else
    CanvasRect(Path, FState.Transform, X, Y, Width, Height);
  DrawShape(StrokeShapeOf(Path.Path, IdentityTransform), FillRuleNonZero, FState.StrokeStyle);
end;

{ Paths }

procedure TCanvasContext2D.BeginPath;
begin
  ClearCanvasPath(FPath);
end;

function TCanvasContext2D.CurrentPath: PCanvasPath;
begin
  Result := @FPath;
end;

procedure TCanvasContext2D.Fill(Path: PCanvasPath; Rule: TFillRule);
begin
  if Path = nil then
    DrawShape(FillShapeOf(FPath.Path, IdentityTransform), Rule, FState.FillStyle)
  else
    DrawShape(FillShapeOf(Path^.Path, FState.Transform), Rule, FState.FillStyle);
end;

procedure TCanvasContext2D.Stroke(Path: PCanvasPath);
begin
  if Path = nil then
    DrawShape(StrokeShapeOf(FPath.Path, IdentityTransform), FillRuleNonZero, FState.StrokeStyle)
  else
    DrawShape(StrokeShapeOf(Path^.Path, FState.Transform), FillRuleNonZero, FState.StrokeStyle);
end;

procedure TCanvasContext2D.Clip(Path: PCanvasPath; Rule: TFillRule);
var
  Image: TImage;
  Shape: TCoverageShape;
begin
  Image := Bitmap;
  if Image = nil then
    Exit;
  if Path = nil then
    Shape := FillShapeOf(FPath.Path, IdentityTransform)
  else
    Shape := FillShapeOf(Path^.Path, FState.Transform);
  FState.Clip := NarrowClip(FState.Clip, Shape, Rule, Image.Width, Image.Height);
end;

function TCanvasContext2D.IsPointInPath(Path: PCanvasPath; X, Y: Double; Rule: TFillRule): Boolean;
var
  Lines: TPolylines;
begin
  if not AllFinite([X, Y]) then
    Exit(False);
  if Path = nil then
    Lines := FlattenPath(FPath.Path, IdentityTransform, DefaultFlatteningTolerance)
  else
    Lines := FlattenPath(Path^.Path, FState.Transform, DefaultFlatteningTolerance);
  Result := WindingOf(Lines, X, Y, Rule = FillRuleEvenOdd);
end;

function TCanvasContext2D.IsPointInStroke(Path: PCanvasPath; X, Y: Double): Boolean;
var
  Shape: TCoverageShape;
  Index, Winding: LongInt;
  Edge: TPreciseEdge;
  Side: Double;
begin
  if not AllFinite([X, Y]) then
    Exit(False);
  if Path = nil then
    Shape := StrokeShapeOf(FPath.Path, IdentityTransform)
  else
    Shape := StrokeShapeOf(Path^.Path, FState.Transform);
  { The non-zero winding number of the stroke's outline (its edges are
    the pieces' closed outlines). }
  Winding := 0;
  for Index := 0 to Shape.Count - 1 do
  begin
    Edge := Shape.Edges[Index];
    Side := (Edge.ToX - Edge.FromX) * (Y - Edge.FromY) - (X - Edge.FromX) * (Edge.ToY - Edge.FromY);
    if Edge.FromY <= Y then
    begin
      if (Edge.ToY > Y) and (Side > 0) then
        Inc(Winding);
    end
    else if (Edge.ToY <= Y) and (Side < 0) then
      Dec(Winding);
  end;
  Result := Winding <> 0;
end;

{ Text }

procedure TCanvasContext2D.FillText(const Text: string; X, Y: Double; HasMaxWidth: Boolean; MaxWidth: Double);
var
  Path: TPath;
begin
  if not AllFinite([X, Y]) then
    Exit;
  if HasMaxWidth then
  begin
    if not AllFinite([MaxWidth]) or (MaxWidth <= 0) then
      Exit;
  end
  else
    MaxWidth := -1;
  Drawing.Paths.BeginPath(Path);
  CanvasTextPath(Text, FState.Text, X, Y, MaxWidth, FState.Transform, Path);
  DrawShape(FillShapeOf(Path, IdentityTransform), FillRuleNonZero, FState.FillStyle);
end;

procedure TCanvasContext2D.StrokeText(const Text: string; X, Y: Double; HasMaxWidth: Boolean; MaxWidth: Double);
var
  Path: TPath;
begin
  if not AllFinite([X, Y]) then
    Exit;
  if HasMaxWidth then
  begin
    if not AllFinite([MaxWidth]) or (MaxWidth <= 0) then
      Exit;
  end
  else
    MaxWidth := -1;
  Drawing.Paths.BeginPath(Path);
  CanvasTextPath(Text, FState.Text, X, Y, MaxWidth, FState.Transform, Path);
  DrawShape(StrokeShapeOf(Path, IdentityTransform), FillRuleNonZero, FState.StrokeStyle);
end;

function TCanvasContext2D.MeasureText(const Text: string): TCanvasTextMeasure;
begin
  Result := MeasureCanvasText(Text, FState.Text);
end;

{ Images }

procedure TCanvasContext2D.DrawImage(const Source: TCanvasImageSource; SX, SY, SW, SH, DX, DY, DW, DH: Double);
var
  Image: TImage;
  ScaleX, ScaleY, Clipped: Double;
  Path: TCanvasPath;
  ToSource, SourceToUser: TAffineTransform;
  Paint: TPaint;
  Layer: TCanvasLayer;
  DrawSettings: TCanvasDrawSettings;
  PixelsX, PixelsY: Double;
begin
  Image := Bitmap;
  if (Image = nil) or (Source.Image = nil) then
    Exit;
  if not AllFinite([SX, SY, SW, SH, DX, DY, DW, DH]) then
    Exit;
  if (SW = 0) or (SH = 0) or (DW = 0) or (DH = 0) then
    Exit;
  if SW < 0 then
  begin
    SX := SX + SW;
    SW := -SW;
  end;
  if SH < 0 then
  begin
    SY := SY + SH;
    SH := -SH;
  end;
  if DW < 0 then
  begin
    DX := DX + DW;
    DW := -DW;
  end;
  if DH < 0 then
  begin
    DY := DY + DH;
    DH := -DH;
  end;
  { Source's coordinates are its own size (an image's natural size);
    its pixels may be more or fewer. }
  PixelsX := Source.Image.Width / Source.Width;
  PixelsY := Source.Image.Height / Source.Height;
  ScaleX := DW / SW;
  ScaleY := DH / SH;
  { The source rectangle clipped to the source, the destination with it. }
  if SX < 0 then
  begin
    Clipped := -SX;
    SX := 0;
    SW := SW - Clipped;
    DX := DX + Clipped * ScaleX;
    DW := DW - Clipped * ScaleX;
  end;
  if SY < 0 then
  begin
    Clipped := -SY;
    SY := 0;
    SH := SH - Clipped;
    DY := DY + Clipped * ScaleY;
    DH := DH - Clipped * ScaleY;
  end;
  if SX + SW > Source.Width then
  begin
    Clipped := SX + SW - Source.Width;
    SW := SW - Clipped;
    DW := DW - Clipped * ScaleX;
  end;
  if SY + SH > Source.Height then
  begin
    Clipped := SY + SH - Source.Height;
    SH := SH - Clipped;
    DH := DH - Clipped * ScaleY;
  end;
  if (SW <= 0) or (SH <= 0) or (DW <= 0) or (DH <= 0) then
    Exit;
  if not Source.OriginClean and (Surface <> nil) then
    Surface.OriginClean := False;
  ClearCanvasPath(Path);
  CanvasRect(Path, FState.Transform, DX, DY, DW, DH);
  { Source pixels to user space, then to the device. }
  SourceToUser := MakeTransform(ScaleX / PixelsX, 0, 0, ScaleY / PixelsY, DX - SX * ScaleX, DY - SY * ScaleY);
  if not InvertTransform(CombineTransforms(FState.Transform, SourceToUser), ToSource) then
    Exit;
  Paint := PatternPaint(SurfaceOnPixels(Source.Image.Pixels, Source.Image.Width, Source.Image.Height,
    Source.Image.Width * 4), ToSource);
  Paint.TileRepeat := False;
  Paint.Smooth := FState.ImageSmoothingEnabled;
  DrawSettings := Settings;
  MakeShapeLayer(FillShapeOf(Path.Path, IdentityTransform), FillRuleNonZero, Paint,
    DrawingInterestArea(Image.Width, Image.Height, DrawSettings), Layer);
  DrawLayer(Image, Layer, DrawSettings);
  if DrawSettings.Operation <> CompositeSourceOver then
    KeepOpaque;
  Touched;
end;

{ Pixels }

procedure TCanvasContext2D.GetImageBytes(X, Y, Width, Height: LongInt; Target: PByte);
var
  Image: TImage;
  Row, Column, SourceX, SourceY: LongInt;
  Color: TColor;
  Pixel: PByte;
begin
  Image := Bitmap;
  FillChar(Target^, PtrInt(Width) * Height * 4, 0);
  if Image = nil then
    Exit;
  for Row := 0 to Height - 1 do
  begin
    SourceY := Y + Row;
    if (SourceY < 0) or (SourceY >= Image.Height) then
      Continue;
    for Column := 0 to Width - 1 do
    begin
      SourceX := X + Column;
      if (SourceX < 0) or (SourceX >= Image.Width) then
        Continue;
      Color := Image.Line(SourceY)[SourceX];
      Pixel := Target + (PtrInt(Row) * Width + Column) * 4;
      if AlphaOf(Color) = 0 then
        Continue;
      Pixel[0] := RedOf(Color);
      Pixel[1] := GreenOf(Color);
      Pixel[2] := BlueOf(Color);
      Pixel[3] := AlphaOf(Color);
    end;
  end;
end;

procedure TCanvasContext2D.PutImageBytes(Source: PByte; Width, Height: LongInt; DX, DY, DirtyX, DirtyY,
  DirtyWidth, DirtyHeight: LongInt);
var
  Image: TImage;
  Row, Column, TargetX, TargetY: LongInt;
  Pixel: PByte;
  AlphaValue: Byte;
begin
  Image := Bitmap;
  if Image = nil then
    Exit;
  if DirtyWidth < 0 then
  begin
    DirtyX := DirtyX + DirtyWidth;
    DirtyWidth := -DirtyWidth;
  end;
  if DirtyHeight < 0 then
  begin
    DirtyY := DirtyY + DirtyHeight;
    DirtyHeight := -DirtyHeight;
  end;
  if DirtyX < 0 then
  begin
    Inc(DirtyWidth, DirtyX);
    DirtyX := 0;
  end;
  if DirtyY < 0 then
  begin
    Inc(DirtyHeight, DirtyY);
    DirtyY := 0;
  end;
  if DirtyX + DirtyWidth > Width then
    DirtyWidth := Width - DirtyX;
  if DirtyY + DirtyHeight > Height then
    DirtyHeight := Height - DirtyY;
  if (DirtyWidth <= 0) or (DirtyHeight <= 0) then
    Exit;
  for Row := DirtyY to DirtyY + DirtyHeight - 1 do
  begin
    TargetY := DY + Row;
    if (TargetY < 0) or (TargetY >= Image.Height) then
      Continue;
    for Column := DirtyX to DirtyX + DirtyWidth - 1 do
    begin
      TargetX := DX + Column;
      if (TargetX < 0) or (TargetX >= Image.Width) then
        Continue;
      Pixel := Source + (PtrInt(Row) * Width + Column) * 4;
      AlphaValue := Pixel[3];
      if not FAlpha then
        AlphaValue := 255;
      if AlphaValue = 0 then
        Image.Line(TargetY)[TargetX] := ColorTransparent
      else
        Image.Line(TargetY)[TargetX] := ArgbColor(AlphaValue, Pixel[0], Pixel[1], Pixel[2]);
    end;
  end;
  Touched;
end;

end.
