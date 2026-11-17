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
  The image viewer's view: a scrolling panel (TPanel with AutoScroll)
  holding a picture box that fills it and takes the zoomed picture's
  size (AutoSize, Zoom): the picture is centred while smaller than the
  view and scrolls, with scroll bars, the wheel and the keys, when it is
  larger. Nothing is placed by hand: zooming only changes the picture
  box's preferred size.

  Fit (the default) keeps the zoom at what fits the view as the window
  resizes; any other zoom stays as chosen. Ctrl+wheel zooms about the
  pointer, dragging with the left button pans, and the arrow keys pan a
  picture that does not fit; one that fits sends Left and Right (and
  Page Up and Page Down always) to OnNavigate, for the folder's
  previous and next image.
}
unit ImageViewer.ImageView;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Controls.Panels,
  Controls.PictureBox;

type
  TNavigateEvent = procedure(Step: LongInt) of object;

  TImageView = class;

  { The picture: pans when dragged, zooms with Ctrl and the wheel. }
  TViewPicture = class(TPictureBox)
  private
    FView: TImageView;
    FDragging: Boolean;
    FDragStartX: LongInt;
    FDragStartY: LongInt;
    FDragScrollLeft: LongInt;
    FDragScrollTop: LongInt;
    FPointerX: LongInt;
    FPointerY: LongInt;
  protected
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    procedure PointerMove(X, Y: LongInt; Buttons: LongWord); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
    procedure Wheel(Steps: LongInt); override;
  end;

  TImageView = class(TPanel)
  private
    FPicture: TViewPicture;
    FFitting: Boolean;
    FOnZoomChanged: TControlEvent;
    FOnNavigate: TNavigateEvent;
    function GetZoom: Double;
    procedure SetFitting(Value: Boolean);
    function ViewWidth: LongInt;
    function ViewHeight: LongInt;
    function FitsAcross: Boolean;
    procedure ZoomChanged;
  protected
    procedure Layout; override;
    function KeyDown(Code, Character, Modifiers: LongWord): Boolean; override;
  public
    constructor Create(AParent: TControl); override;
    { Zoom (clamped), keeping the picture's spot at (X, Y) of the view
      (logical units) where it is; fitting stops. }
    procedure ZoomAbout(NewZoom: Double; X, Y: LongInt);
    procedure ZoomIn;
    procedure ZoomOut;
    procedure ActualSize;
    procedure FitToWindow;
    property Picture: TViewPicture read FPicture;
    property Zoom: Double read GetZoom;
    { The zoom follows the view's size. }
    property Fitting: Boolean read FFitting write SetFitting;
    property OnZoomChanged: TControlEvent read FOnZoomChanged write FOnZoomChanged;
    property OnNavigate: TNavigateEvent read FOnNavigate write FOnNavigate;
  end;

implementation

uses
  Abi.SystemCalls,
  Drawing.Rectangles,
  Windowing.Connection,
  Windowing.Windows,
  Controls.Keys,
  Controls.PictureGeometry,
  ImageViewer.ViewGeometry;

const
  LeftButton = 1;

{ --- TViewPicture ----------------------------------------------------------------- }

procedure TViewPicture.PointerDown(X, Y: LongInt; Button: LongWord);
begin
  inherited PointerDown(X, Y, Button);
  FView.SetFocus;
  if Button <> LeftButton then
    Exit;
  { Window pixels: the box itself moves as it scrolls. }
  FDragging := True;
  FDragStartX := X + PixelBounds.Left;
  FDragStartY := Y + PixelBounds.Top;
  FDragScrollLeft := FView.ScrollLeft;
  FDragScrollTop := FView.ScrollTop;
end;

procedure TViewPicture.PointerMove(X, Y: LongInt; Buttons: LongWord);
var
  WindowX: LongInt;
  WindowY: LongInt;
begin
  inherited PointerMove(X, Y, Buttons);
  WindowX := X + PixelBounds.Left;
  WindowY := Y + PixelBounds.Top;
  FPointerX := WindowX;
  FPointerY := WindowY;
  if not FDragging then
    Exit;
  if (Buttons and LeftButton) = 0 then
  begin
    FDragging := False;
    Exit;
  end;
  FView.ScrollTo(FDragScrollLeft - Unscaled(WindowX - FDragStartX), FDragScrollTop - Unscaled(WindowY - FDragStartY));
end;

procedure TViewPicture.PointerUp(X, Y: LongInt; Button: LongWord);
begin
  inherited PointerUp(X, Y, Button);
  if Button = LeftButton then
    FDragging := False;
end;

procedure TViewPicture.Wheel(Steps: LongInt);
var
  NewZoom: Double;
  Index: LongInt;
  ViewX: LongInt;
  ViewY: LongInt;
begin
  if (HeldModifiers and ModifierControl) = 0 then
  begin
    inherited Wheel(Steps);
    Exit;
  end;
  NewZoom := FView.Zoom;
  for Index := 1 to Abs(Steps) do
    if Steps > 0 then
      NewZoom := ZoomedIn(NewZoom)
    else
      NewZoom := ZoomedOut(NewZoom);
  { The pointer in the view's logical units. }
  ViewX := Unscaled(FPointerX - FView.PixelBounds.Left);
  ViewY := Unscaled(FPointerY - FView.PixelBounds.Top);
  FView.ZoomAbout(NewZoom, ViewX, ViewY);
end;

{ --- TImageView -------------------------------------------------------------------- }

constructor TImageView.Create(AParent: TControl);
begin
  inherited Create(AParent);
  AutoScroll := True;
  CanFocus := True;
  FFitting := True;
  FPicture := TViewPicture.Create(Self);
  FPicture.FView := Self;
  FPicture.SizeMode := PictureSizeCenter;
  FPicture.Align := AlignClient;
  FPicture.AutoSize := True;
end;

function TImageView.GetZoom: Double;
begin
  Result := FPicture.Zoom;
end;

function TImageView.ViewWidth: LongInt;
begin
  Result := Unscaled(RectangleWidth(ClientPixelArea));
end;

function TImageView.ViewHeight: LongInt;
begin
  Result := Unscaled(RectangleHeight(ClientPixelArea));
end;

function TImageView.FitsAcross: Boolean;
begin
  Result := ZoomedExtent(FPicture.PictureWidth, Zoom) <= ViewWidth;
end;

procedure TImageView.ZoomChanged;
begin
  if Assigned(FOnZoomChanged) then
    FOnZoomChanged(Self);
end;

procedure TImageView.SetFitting(Value: Boolean);
begin
  if FFitting = Value then
    Exit;
  FFitting := Value;
  RequestLayout;
  ZoomChanged;
end;

{ Fitting: the zoom follows the view before the children are placed. }
procedure TImageView.Layout;
var
  Fitted: Double;
begin
  if FFitting and (FPicture.PictureWidth > 0) then
  begin
    Fitted := FitZoom(FPicture.PictureWidth, FPicture.PictureHeight, ViewWidth, ViewHeight, False);
    if Abs(Fitted - FPicture.Zoom) > 1e-9 then
    begin
      FPicture.Zoom := Fitted;
      ZoomChanged;
    end;
  end;
  inherited Layout;
end;

procedure TImageView.ZoomAbout(NewZoom: Double; X, Y: LongInt);
var
  OldWidth: LongInt;
  OldHeight: LongInt;
  NewWidth: LongInt;
  NewHeight: LongInt;
  Left: LongInt;
  Top: LongInt;
begin
  NewZoom := ClampZoom(NewZoom);
  OldWidth := ZoomedExtent(FPicture.PictureWidth, FPicture.Zoom);
  OldHeight := ZoomedExtent(FPicture.PictureHeight, FPicture.Zoom);
  NewWidth := ZoomedExtent(FPicture.PictureWidth, NewZoom);
  NewHeight := ZoomedExtent(FPicture.PictureHeight, NewZoom);
  Left := ScrollKeepingPoint(ScrollLeft, X, OldWidth, NewWidth, ViewWidth);
  Top := ScrollKeepingPoint(ScrollTop, Y, OldHeight, NewHeight, ViewHeight);
  FFitting := False;
  FPicture.Zoom := NewZoom;
  { Reading a place lays out what waits, so the scroll range is the new
    content's before scrolling. }
  if RectangleWidth(FPicture.Bounds) > 0 then
    ScrollTo(Left, Top);
  ZoomChanged;
end;

procedure TImageView.ZoomIn;
begin
  ZoomAbout(ZoomedIn(Zoom), ViewWidth div 2, ViewHeight div 2);
end;

procedure TImageView.ZoomOut;
begin
  ZoomAbout(ZoomedOut(Zoom), ViewWidth div 2, ViewHeight div 2);
end;

procedure TImageView.ActualSize;
begin
  ZoomAbout(1, ViewWidth div 2, ViewHeight div 2);
end;

procedure TImageView.FitToWindow;
begin
  Fitting := True;
end;

function TImageView.KeyDown(Code, Character, Modifiers: LongWord): Boolean;
var
  Step: LongInt;
begin
  Step := 0;
  if Code = KeyPageDown then
    Step := 1
  else if Code = KeyPageUp then
    Step := -1
  else if FitsAcross and (Code = KeyArrowRight) then
    Step := 1
  else if FitsAcross and (Code = KeyArrowLeft) then
    Step := -1;
  if (Step <> 0) and Assigned(FOnNavigate) and ((Modifiers and (ModifierControl or ModifierAlt)) = 0) then
  begin
    FOnNavigate(Step);
    Exit(True);
  end;
  Result := inherited KeyDown(Code, Character, Modifiers);
end;

end.
