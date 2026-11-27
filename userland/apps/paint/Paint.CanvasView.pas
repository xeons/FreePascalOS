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
  The view of the picture: zoomed (Paint.ZoomMapping), scrolled by its
  scroll bars (docked to its right and bottom), the picture a little in
  from the top left on the workspace colour, transparency over a
  checkerboard and the pixel grid at high zoom (Paint.ViewRendering),
  the selection outlined with dots and what floats drawn where it is.

  The pointer over the picture goes to the current tool, in image
  coordinates, with the keys held; the view takes the focus when
  pressed, and the keys go to the tool first (Enter, Escape, the arrows
  moving a selection), then scroll it (the arrows, Page Up and Page
  Down; Home and End to the left and right). The wheel scrolls (with
  Shift, across) and zooms with Ctrl, keeping the point under the
  pointer where it is. Only the part of the view a change touches is
  painted again. A file dragged over it is the window's business (the
  view passes it on).
}
unit Paint.CanvasView;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles,
  Drawing.Canvas,
  Controls.Base,
  Controls.ScrollBar,
  Paint.ZoomMapping,
  Paint.Session,
  Paint.Tools;

type
  TCanvasView = class;
  TPointerPlaceEvent = procedure(View: TCanvasView; Inside: Boolean; X, Y: LongInt) of object;
  TCanvasViewEvent = procedure(View: TCanvasView) of object;

  { The part that shows the picture (the view less its scroll bars). }
  TCanvasArea = class(TControl)
  private
    FView: TCanvasView;
    procedure PaintSelection(const Canvas: TCanvas; const Mapping: TViewMapping);
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    procedure PointerMove(X, Y: LongInt; Buttons: LongWord); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
    procedure PointerLeave; override;
    procedure Wheel(Steps: LongInt); override;
    function KeyDown(Code, Character, Modifiers: LongWord): Boolean; override;
  end;

  TCanvasView = class(TControl)
  private
    FSession: TPaintSession;
    FTool: TPaintTool;
    FArea: TCanvasArea;
    FHorizontalBar: TScrollBar;
    FVerticalBar: TScrollBar;
    FZoom: LongInt;
    FScrollX: LongInt;
    FScrollY: LongInt;
    FShowGrid: Boolean;
    FUpdatingBars: Boolean;
    FOnPointerPlace: TPointerPlaceEvent;
    FOnToolEventDone: TCanvasViewEvent;
    FOnZoomChanged: TCanvasViewEvent;
    procedure ScrollBarChanged(Sender: TControl);
    procedure AreaResized(Sender: TControl);
    procedure SetShowGrid(Value: Boolean);
    procedure SetTool(Value: TPaintTool);
    function Origin: LongInt;
    function ContentWidth: LongInt;
    function ContentHeight: LongInt;
    procedure ToolEventDone;
    { Image coordinates of the middle of view pixel (X, Y). }
    function ImageX(X: LongInt): Double;
    function ImageY(Y: LongInt): Double;
  public
    constructor Create(AParent: TControl); override;
    procedure AttachSession(ASession: TPaintSession);
    function Mapping: TViewMapping;
    { Area of the picture changed (empty: all of it, its size perhaps). }
    procedure ImageChanged(const Area: TRectangle);
    { Ranges and positions of the scroll bars from the picture's size. }
    procedure UpdateScrollBars;
    procedure ScrollTo(X, Y: LongInt);
    { Zooms to NewZoom keeping the image point under view pixel (X, Y)
      of the picture area where it is. }
    procedure ZoomAt(NewZoom, X, Y: LongInt);
    { Zooms keeping the middle of what is shown. }
    procedure SetZoom(NewZoom: LongInt);
    { The image pixel at the top left of what is shown (where a paste
      goes). }
    function VisibleTopLeft: TPoint;
    { The area's pixels of image pixel (X, Y)'s top left. }
    function ViewPointOf(X, Y: LongInt): TPoint;
    property Area: TCanvasArea read FArea;
    property Tool: TPaintTool read FTool write SetTool;
    property Zoom: LongInt read FZoom;
    property ShowGrid: Boolean read FShowGrid write SetShowGrid;
    property OnPointerPlace: TPointerPlaceEvent read FOnPointerPlace write FOnPointerPlace;
    { A tool heard the pointer or a key (it may have asked for another
      tool: the window changes it now, not while the tool runs). }
    property OnToolEventDone: TCanvasViewEvent read FOnToolEventDone write FOnToolEventDone;
    property OnZoomChanged: TCanvasViewEvent read FOnZoomChanged write FOnZoomChanged;
  end;

implementation

uses
  Math,
  Abi.SystemCalls,
  Drawing.Colors,
  Drawing.Surfaces,
  Drawing.Regions,
  Drawing.Shapes,
  Windowing.Connection,
  Windowing.Windows,
  Windowing.Theme,
  Controls.Keys,
  Paint.ViewRendering;

const
  { Logical units between the view's top left and the picture's. }
  PictureMargin = 4;
  { Logical units a scroll bar's arrow or an arrow key scrolls. }
  ScrollStep = 16;
  WheelSteps = 3;

{ --- The area --------------------------------------------------------------------------------- }

procedure TCanvasArea.PaintSelection(const Canvas: TCanvas; const Mapping: TViewMapping);
var
  Session: TPaintSession;
  Selected: TRectangle;
  Left: LongInt;
  Top: LongInt;
  Right: LongInt;
  Bottom: LongInt;
  Index: LongInt;
  FromPoint: TPoint;
  ToPoint: TPoint;
begin
  Session := FView.FSession;
  if not Session.Editor.Selection.Active then
    Exit;
  Selected := Session.Editor.Selection.Bounds;
  Left := PixelStartX(Mapping, Selected.Left);
  Top := PixelStartY(Mapping, Selected.Top);
  Right := PixelStartX(Mapping, Selected.Right);
  Bottom := PixelStartY(Mapping, Selected.Bottom);
  { White under black dots: seen on any picture. }
  DrawRectangleOutline(Canvas, MakeRectangle(Left - 1, Top - 1, Right - Left + 2, Bottom - Top + 2), ColorWhite);
  DrawDottedHorizontalLine(Canvas, Left - 1, Right + 1, Top - 1, 1, ColorBlack);
  DrawDottedHorizontalLine(Canvas, Left - 1, Right + 1, Bottom, 1, ColorBlack);
  DrawDottedVerticalLine(Canvas, Left - 1, Top - 1, Bottom + 1, 1, ColorBlack);
  DrawDottedVerticalLine(Canvas, Right, Top - 1, Bottom + 1, 1, ColorBlack);
  for Index := 0 to Session.Editor.Selection.OutlineCount - 1 do
  begin
    FromPoint := Session.Editor.Selection.OutlinePoints[Index];
    ToPoint := Session.Editor.Selection.OutlinePoints[(Index + 1) mod Session.Editor.Selection.OutlineCount];
    DrawLine(Canvas, Round(ImageToViewX(Mapping, FromPoint.X + 0.5)), Round(ImageToViewY(Mapping, FromPoint.Y + 0.5)),
      Round(ImageToViewX(Mapping, ToPoint.X + 0.5)), Round(ImageToViewY(Mapping, ToPoint.Y + 0.5)), ColorBlack);
  end;
end;

procedure TCanvasArea.Paint(var Canvas: TCanvas);
var
  Own: TRectangle;
  Wanted: TRectangle;
  Target: TSurface;
  Floating: TFloatingPixels;
  Session: TPaintSession;
  Mapping: TViewMapping;
begin
  Session := FView.FSession;
  Own := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  if Session = nil then
  begin
    FillRectangle(Canvas, Own, Theme.Shadow);
    Exit;
  end;
  { Only what needs painting: the clip, in the area's own pixels. }
  Wanted := OffsetRectangle(RegionBounds(Canvas.Clip), -Canvas.OriginX, -Canvas.OriginY);
  if not IntersectRectangles(Wanted, Own, Wanted) then
    Exit;
  Mapping := FView.Mapping;
  if not CreateSurface(Target, RectangleWidth(Wanted), RectangleHeight(Wanted), Theme.Shadow) then
    Exit;
  try
    Floating := NoFloatingPixels;
    if Session.Editor.IsFloating then
    begin
      Floating.Image := Session.Editor.Floating;
      Floating.Left := Session.Editor.Area.Left;
      Floating.Top := Session.Editor.Area.Top;
      Floating.Mask := Session.Editor.Selection.Mask;
    end;
    RenderPictureView(Target, Wanted, Session.Document.Image, Floating, Mapping, FView.FShowGrid, Theme.Shadow);
    DrawSurface(Canvas, Target, SurfaceBounds(Target), Wanted.Left, Wanted.Top, False, AlphaOpaque);
  finally
    FreeSurface(Target);
  end;
  PaintSelection(Canvas, Mapping);
  if FView.FTool <> nil then
    FView.FTool.DrawOverlay(Canvas, Mapping);
end;

procedure TCanvasArea.PointerDown(X, Y: LongInt; Button: LongWord);
begin
  SetFocus;
  if FView.FTool = nil then
    Exit;
  FView.FTool.PointerDown(FView.ImageX(X), FView.ImageY(Y), Button, HeldModifiers);
  FView.ToolEventDone;
end;

procedure TCanvasArea.PointerMove(X, Y: LongInt; Buttons: LongWord);
var
  PixelX: LongInt;
  PixelY: LongInt;
  Image: TObject;
begin
  if FView.FSession = nil then
    Exit;
  PixelX := Floor(FView.ImageX(X));
  PixelY := Floor(FView.ImageY(Y));
  Image := FView.FSession.Document.Image;
  if Assigned(FView.FOnPointerPlace) then
    FView.FOnPointerPlace(FView, (Image <> nil) and (PixelX >= 0) and (PixelY >= 0) and
      (PixelX < FView.FSession.Document.Image.Width) and (PixelY < FView.FSession.Document.Image.Height),
      PixelX, PixelY);
  if FView.FTool = nil then
    Exit;
  FView.FTool.PointerMove(FView.ImageX(X), FView.ImageY(Y), Buttons, HeldModifiers);
  FView.ToolEventDone;
end;

procedure TCanvasArea.PointerUp(X, Y: LongInt; Button: LongWord);
begin
  if FView.FTool = nil then
    Exit;
  FView.FTool.PointerUp(FView.ImageX(X), FView.ImageY(Y), Button, HeldModifiers);
  FView.ToolEventDone;
end;

procedure TCanvasArea.PointerLeave;
begin
  if Assigned(FView.FOnPointerPlace) then
    FView.FOnPointerPlace(FView, False, 0, 0);
end;

procedure TCanvasArea.Wheel(Steps: LongInt);
var
  Modifiers: LongWord;
  Middle: TPoint;
begin
  Modifiers := HeldModifiers;
  if (Modifiers and ModifierControl) <> 0 then
  begin
    { Zoomed about the middle of the area (the pointer's place is not
      told with the wheel). }
    Middle := MakePoint(RectangleWidth(PixelBounds) div 2, RectangleHeight(PixelBounds) div 2);
    if Steps > 0 then
      FView.ZoomAt(ZoomedIn(FView.FZoom), Middle.X, Middle.Y)
    else
      FView.ZoomAt(ZoomedOut(FView.FZoom), Middle.X, Middle.Y);
  end
  else if (Modifiers and ModifierShift) <> 0 then
    FView.ScrollTo(FView.FScrollX - Steps * WheelSteps * Scaled(ScrollStep), FView.FScrollY)
  else
    FView.ScrollTo(FView.FScrollX, FView.FScrollY - Steps * WheelSteps * Scaled(ScrollStep));
end;

function TCanvasArea.KeyDown(Code, Character, Modifiers: LongWord): Boolean;
var
  Step: LongInt;
  PageY: LongInt;
begin
  if (FView.FTool <> nil) and FView.FTool.KeyDown(Code, Modifiers) then
  begin
    FView.ToolEventDone;
    Exit(True);
  end;
  Step := Scaled(ScrollStep);
  PageY := Max(Step, RectangleHeight(PixelBounds) - Step);
  Result := True;
  case Code of
    KeyArrowLeft: FView.ScrollTo(FView.FScrollX - Step, FView.FScrollY);
    KeyArrowRight: FView.ScrollTo(FView.FScrollX + Step, FView.FScrollY);
    KeyArrowUp: FView.ScrollTo(FView.FScrollX, FView.FScrollY - Step);
    KeyArrowDown: FView.ScrollTo(FView.FScrollX, FView.FScrollY + Step);
    KeyPageUp: FView.ScrollTo(FView.FScrollX, FView.FScrollY - PageY);
    KeyPageDown: FView.ScrollTo(FView.FScrollX, FView.FScrollY + PageY);
    KeyHome: FView.ScrollTo(0, FView.FScrollY);
    KeyEnd: FView.ScrollTo(FView.ContentWidth, FView.FScrollY);
  else
    Result := False;
  end;
  if not Result then
    Result := inherited KeyDown(Code, Character, Modifiers);
end;

{ --- The view --------------------------------------------------------------------------------- }

constructor TCanvasView.Create(AParent: TControl);
begin
  inherited Create(AParent);
  FZoom := ActualSizeZoom;
  FShowGrid := True;
  FHorizontalBar := TScrollBar.Create(Self);
  FHorizontalBar.Kind := ScrollHorizontal;
  FHorizontalBar.SetBounds(0, 0, 0, Theme.ScrollBarWidth);
  FHorizontalBar.Align := AlignBottom;
  FHorizontalBar.DockOrder := 0;
  FHorizontalBar.OnChange := @ScrollBarChanged;
  FVerticalBar := TScrollBar.Create(Self);
  FVerticalBar.Kind := ScrollVertical;
  FVerticalBar.SetBounds(0, 0, Theme.ScrollBarWidth, 0);
  FVerticalBar.Align := AlignRight;
  FVerticalBar.DockOrder := 1;
  FVerticalBar.OnChange := @ScrollBarChanged;
  FArea := TCanvasArea.Create(Self);
  FArea.FView := Self;
  FArea.Align := AlignClient;
  FArea.CanFocus := True;
  FArea.OnResize := @AreaResized;
end;

procedure TCanvasView.AttachSession(ASession: TPaintSession);
begin
  FSession := ASession;
  UpdateScrollBars;
  FArea.Invalidate;
end;

function TCanvasView.Origin: LongInt;
begin
  Result := Scaled(PictureMargin);
end;

function TCanvasView.ContentWidth: LongInt;
begin
  Result := 0;
  if FSession <> nil then
    Result := ZoomedLength(FSession.Document.Image.Width, FZoom) + 2 * Origin;
end;

function TCanvasView.ContentHeight: LongInt;
begin
  Result := 0;
  if FSession <> nil then
    Result := ZoomedLength(FSession.Document.Image.Height, FZoom) + 2 * Origin;
end;

function TCanvasView.Mapping: TViewMapping;
begin
  Result := MakeViewMapping(FZoom, Origin, Origin, FScrollX, FScrollY);
end;

function TCanvasView.ImageX(X: LongInt): Double;
begin
  Result := ViewToImageX(Mapping, X + 0.5);
end;

function TCanvasView.ImageY(Y: LongInt): Double;
begin
  Result := ViewToImageY(Mapping, Y + 0.5);
end;

procedure TCanvasView.ToolEventDone;
begin
  if Assigned(FOnToolEventDone) then
    FOnToolEventDone(Self);
end;

procedure TCanvasView.SetTool(Value: TPaintTool);
begin
  FTool := Value;
  FArea.Invalidate;
end;

procedure TCanvasView.SetShowGrid(Value: Boolean);
begin
  if FShowGrid = Value then
    Exit;
  FShowGrid := Value;
  FArea.Invalidate;
end;

procedure TCanvasView.UpdateScrollBars;
var
  VisibleWidth: LongInt;
  VisibleHeight: LongInt;
begin
  VisibleWidth := Max(1, RectangleWidth(FArea.PixelBounds));
  VisibleHeight := Max(1, RectangleHeight(FArea.PixelBounds));
  FScrollX := ClampScroll(FScrollX, ContentWidth, VisibleWidth);
  FScrollY := ClampScroll(FScrollY, ContentHeight, VisibleHeight);
  FUpdatingBars := True;
  try
    FHorizontalBar.Step := Scaled(ScrollStep);
    FVerticalBar.Step := Scaled(ScrollStep);
    FHorizontalBar.SetRange(0, Max(ContentWidth, VisibleWidth), VisibleWidth);
    FVerticalBar.SetRange(0, Max(ContentHeight, VisibleHeight), VisibleHeight);
    FHorizontalBar.Position := FScrollX;
    FVerticalBar.Position := FScrollY;
    FHorizontalBar.Enabled := ContentWidth > VisibleWidth;
    FVerticalBar.Enabled := ContentHeight > VisibleHeight;
  finally
    FUpdatingBars := False;
  end;
end;

procedure TCanvasView.ScrollBarChanged(Sender: TControl);
begin
  if FUpdatingBars then
    Exit;
  FScrollX := FHorizontalBar.Position;
  FScrollY := FVerticalBar.Position;
  FArea.Invalidate;
end;

procedure TCanvasView.AreaResized(Sender: TControl);
begin
  UpdateScrollBars;
end;

procedure TCanvasView.ScrollTo(X, Y: LongInt);
var
  NewX: LongInt;
  NewY: LongInt;
begin
  NewX := ClampScroll(X, ContentWidth, RectangleWidth(FArea.PixelBounds));
  NewY := ClampScroll(Y, ContentHeight, RectangleHeight(FArea.PixelBounds));
  if (NewX = FScrollX) and (NewY = FScrollY) then
    Exit;
  FScrollX := NewX;
  FScrollY := NewY;
  UpdateScrollBars;
  FArea.Invalidate;
end;

procedure TCanvasView.ZoomAt(NewZoom, X, Y: LongInt);
var
  PointX: Double;
  PointY: Double;
begin
  NewZoom := ClampZoom(NewZoom);
  if NewZoom = FZoom then
    Exit;
  PointX := ViewToImageX(Mapping, X);
  PointY := ViewToImageY(Mapping, Y);
  FZoom := NewZoom;
  if FSession <> nil then
    FSession.ViewScale := FZoom / ActualSizeZoom;
  FScrollX := ScrollKeepingPoint(PointX, X, Origin, FZoom);
  FScrollY := ScrollKeepingPoint(PointY, Y, Origin, FZoom);
  UpdateScrollBars;
  FArea.Invalidate;
  if Assigned(FOnZoomChanged) then
    FOnZoomChanged(Self);
end;

procedure TCanvasView.SetZoom(NewZoom: LongInt);
begin
  ZoomAt(NewZoom, RectangleWidth(FArea.PixelBounds) div 2, RectangleHeight(FArea.PixelBounds) div 2);
end;

function TCanvasView.VisibleTopLeft: TPoint;
begin
  Result := MakePoint(Max(0, Floor(ViewToImageX(Mapping, Origin))), Max(0, Floor(ViewToImageY(Mapping, Origin))));
end;

function TCanvasView.ViewPointOf(X, Y: LongInt): TPoint;
begin
  Result := MakePoint(PixelStartX(Mapping, X), PixelStartY(Mapping, Y));
end;

procedure TCanvasView.ImageChanged(const Area: TRectangle);
var
  ViewArea: TRectangle;
  Own: TRectangle;
begin
  if RectangleIsEmpty(Area) then
  begin
    UpdateScrollBars;
    FArea.Invalidate;
    Exit;
  end;
  ViewArea.Left := PixelStartX(Mapping, Area.Left) - 2;
  ViewArea.Top := PixelStartY(Mapping, Area.Top) - 2;
  ViewArea.Right := PixelStartX(Mapping, Area.Right) + 2;
  ViewArea.Bottom := PixelStartY(Mapping, Area.Bottom) + 2;
  Own := MakeRectangle(0, 0, RectangleWidth(FArea.PixelBounds), RectangleHeight(FArea.PixelBounds));
  if not IntersectRectangles(ViewArea, Own, ViewArea) then
    Exit;
  if FArea.Host <> nil then
    FArea.Host.InvalidatePixels(OffsetRectangle(ViewArea, FArea.PixelBounds.Left, FArea.PixelBounds.Top));
end;

end.
