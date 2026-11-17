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
  Panels and group boxes: controls that hold others.

  A panel fills itself with the face colour and may have a raised or
  sunken edge; a group box draws an etched frame with its text in the
  top edge (its children go inside, placed clear of the frame, or give
  it a ContentPadding to dock in). A group box's mnemonic focuses the
  first control in it (or after it) that takes the focus. Both would
  like to be as large as their children need (PreferredSize).

  A panel with AutoScroll scrolls its children when they need more room
  than it has: a scroll bar appears along the bottom or the right (or
  both) whenever the content is wider or taller than what is left, the
  wheel over it and Page Up, Page Down, the arrows and Ctrl+Home and
  Ctrl+End (keys its children leave alone) scroll it, and a control in
  it that gets the focus is scrolled into view. Scroll positions are
  logical units, so a change of scale keeps the same part in view.
}
unit Controls.Panels;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Canvas,
  Drawing.Rectangles,
  Windowing.Messages,
  Controls.Base,
  Controls.ScrollBar;

type
  TPanelEdge = (PanelFlat, PanelRaised, PanelSunken);

  TPanel = class(TControl)
  private
    FEdge: TPanelEdge;
    FAutoScroll: Boolean;
    FHorizontalBar: TScrollBar;
    FVerticalBar: TScrollBar;
    FCorner: TControl;
    { Logical units: how far the content is scrolled. }
    FScrollLeft: LongInt;
    FScrollTop: LongInt;
    { Pixels, from the last layout: what is shown, and the content. }
    FViewArea: TRectangle;
    FContentWidth: LongInt;
    FContentHeight: LongInt;
    procedure SetEdge(Value: TPanelEdge);
    procedure SetAutoScroll(Value: Boolean);
    procedure MakeScrollBars;
    procedure ScrollBarMoved;
    function IsOwnScrollPart(Child: TControl): Boolean;
    procedure PlaceScrollBars(const Area: TRectangle; Horizontal, Vertical: Boolean);
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PlaceChildren(const Area: TRectangle); override;
    function CountsInExtent(Child: TControl): Boolean; override;
    procedure Wheel(Steps: LongInt); override;
    function KeyDown(Code, Character, Modifiers: LongWord): Boolean; override;
  public
    { Its scroll bars' notifications are its own; the rest go to
      OnNotify as usual. }
    procedure ReceiveMessage(var Message: TPostedMessage); override;
    { As large as its children need. }
    function PreferredSize: TSize; override;
    procedure DescendantFocused(Control: TControl); override;
    { Scrolls to (Left, Top), logical units (kept within the content). }
    procedure ScrollTo(Left, Top: LongInt);
    { Scrolls just far enough for Control (in the panel, at any depth) to
      be seen. }
    procedure ScrollControlIntoView(Control: TControl);
    property Edge: TPanelEdge read FEdge write SetEdge;
    property AutoScroll: Boolean read FAutoScroll write SetAutoScroll;
    property ScrollLeft: LongInt read FScrollLeft;
    property ScrollTop: LongInt read FScrollTop;
  end;

  TGroupBox = class(TControl)
  protected
    procedure Paint(var Canvas: TCanvas); override;
  public
    function MatchesMnemonic(Character: LongWord): Boolean; override;
    procedure ActivateMnemonic(Character: LongWord); override;
    { Its children, the frame around them, and room for its text. }
    function PreferredSize: TSize; override;
  end;

implementation

uses
  Abi.SystemCalls,
  Drawing.Colors,
  Drawing.Bevels,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Keys,
  Controls.Text,
  Controls.LayoutRules,
  Controls.SplitRules;

const
  { Logical units: a step of the arrows (and each wheel step, three of
    them), and the room a group box's frame takes beyond its children. }
  ScrollStep = 16;
  WheelSteps = 3;
  GroupFrameRoom = 8;

type
  { The square where the two scroll bars meet. }
  TScrollCorner = class(TControl)
  protected
    procedure Paint(var Canvas: TCanvas); override;
  end;

procedure TScrollCorner.Paint(var Canvas: TCanvas);
begin
  FillRectangle(Canvas, MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds)), Theme.Face);
end;

{ --- TPanel ---------------------------------------------------------------------- }

procedure TPanel.SetEdge(Value: TPanelEdge);
begin
  FEdge := Value;
  Invalidate;
end;

procedure TPanel.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillRectangle(Canvas, Box, Theme.Face);
  case FEdge of
    PanelRaised: DrawEdge(Canvas, Box, Theme.Highlight, Theme.Shadow);
    PanelSunken: DrawEdge(Canvas, Box, Theme.Shadow, Theme.Highlight);
  end;
end;

function TPanel.PreferredSize: TSize;
begin
  Result := ChildrenExtent;
end;

function TPanel.IsOwnScrollPart(Child: TControl): Boolean;
begin
  Result := (Child <> nil) and ((Child = FHorizontalBar) or (Child = FVerticalBar) or (Child = FCorner));
end;

function TPanel.CountsInExtent(Child: TControl): Boolean;
begin
  Result := not IsOwnScrollPart(Child);
end;

procedure TPanel.MakeScrollBars;
begin
  if FVerticalBar <> nil then
    Exit;
  FHorizontalBar := TScrollBar.Create(Self);
  FHorizontalBar.Kind := ScrollHorizontal;
  FHorizontalBar.Step := ScrollStep;
  FHorizontalBar.Visible := False;
  FVerticalBar := TScrollBar.Create(Self);
  FVerticalBar.Step := ScrollStep;
  FVerticalBar.Visible := False;
  FCorner := TScrollCorner.Create(Self);
  FCorner.Visible := False;
end;

procedure TPanel.SetAutoScroll(Value: Boolean);
begin
  if FAutoScroll = Value then
    Exit;
  FAutoScroll := Value;
  if Value then
    MakeScrollBars
  else
  begin
    FHorizontalBar.Visible := False;
    FVerticalBar.Visible := False;
    FCorner.Visible := False;
    FScrollLeft := 0;
    FScrollTop := 0;
  end;
  RequestLayout;
  Invalidate;
end;

procedure TPanel.PlaceScrollBars(const Area: TRectangle; Horizontal, Vertical: Boolean);
var
  Thickness: LongInt;
  Right: LongInt;
  Bottom: LongInt;
begin
  Thickness := Scaled(Theme.ScrollBarWidth);
  Right := Area.Right;
  Bottom := Area.Bottom;
  if Vertical then
    Right := Right - Thickness;
  if Horizontal then
    Bottom := Bottom - Thickness;
  if FHorizontalBar.Visible <> Horizontal then
    FHorizontalBar.Visible := Horizontal;
  if FVerticalBar.Visible <> Vertical then
    FVerticalBar.Visible := Vertical;
  if FCorner.Visible <> (Horizontal and Vertical) then
    FCorner.Visible := Horizontal and Vertical;
  PlaceChild(FHorizontalBar, MakeRectangle(Area.Left, Bottom, Right - Area.Left, Thickness));
  PlaceChild(FVerticalBar, MakeRectangle(Right, Area.Top, Thickness, Bottom - Area.Top));
  PlaceChild(FCorner, MakeRectangle(Right, Bottom, Thickness, Thickness));
  { Over the content, and found first under the pointer. }
  KeepChildOnTop(FHorizontalBar);
  KeepChildOnTop(FVerticalBar);
  KeepChildOnTop(FCorner);
end;

{ With AutoScroll: the children in the area scrolled (as large as the
  content, or the view if that is larger), the scroll bars along the
  edges they are needed at. }
procedure TPanel.PlaceChildren(const Area: TRectangle);
var
  Content: TSize;
  Horizontal: Boolean;
  Vertical: Boolean;
  Thickness: LongInt;
  View: TRectangle;
  Scrolled: TRectangle;
begin
  if not FAutoScroll then
  begin
    inherited PlaceChildren(Area);
    Exit;
  end;
  Content := ChildrenExtent;
  FContentWidth := Scaled(Content.cx - SpacingWidth(ContentPadding));
  FContentHeight := Scaled(Content.cy - SpacingHeight(ContentPadding));
  Thickness := Scaled(Theme.ScrollBarWidth);
  NeededScrollBars(FContentWidth, FContentHeight, RectangleWidth(Area), RectangleHeight(Area), Thickness,
    Horizontal, Vertical);
  View := Area;
  if Vertical then
    View.Right := View.Right - Thickness;
  if Horizontal then
    View.Bottom := View.Bottom - Thickness;
  if View.Right < View.Left then
    View.Right := View.Left;
  if View.Bottom < View.Top then
    View.Bottom := View.Top;
  FViewArea := View;
  FScrollLeft := Unscaled(ClampScrollPosition(Scaled(FScrollLeft), FContentWidth, RectangleWidth(View)));
  FScrollTop := Unscaled(ClampScrollPosition(Scaled(FScrollTop), FContentHeight, RectangleHeight(View)));
  Scrolled := MakeRectangle(View.Left - Scaled(FScrollLeft), View.Top - Scaled(FScrollTop),
    RectangleWidth(View), RectangleHeight(View));
  if FContentWidth > RectangleWidth(Scrolled) then
    Scrolled.Right := Scrolled.Left + FContentWidth;
  if FContentHeight > RectangleHeight(Scrolled) then
    Scrolled.Bottom := Scrolled.Top + FContentHeight;
  inherited PlaceChildren(Scrolled);
  PlaceScrollBars(Area, Horizontal, Vertical);
  FHorizontalBar.SetRange(0, Unscaled(FContentWidth), Unscaled(RectangleWidth(View)));
  FHorizontalBar.Position := FScrollLeft;
  FVerticalBar.SetRange(0, Unscaled(FContentHeight), Unscaled(RectangleHeight(View)));
  FVerticalBar.Position := FScrollTop;
end;

procedure TPanel.ScrollTo(Left, Top: LongInt);
begin
  if not FAutoScroll then
    Exit;
  Left := Unscaled(ClampScrollPosition(Scaled(Left), FContentWidth, RectangleWidth(FViewArea)));
  Top := Unscaled(ClampScrollPosition(Scaled(Top), FContentHeight, RectangleHeight(FViewArea)));
  if (Left = FScrollLeft) and (Top = FScrollTop) then
    Exit;
  FScrollLeft := Left;
  FScrollTop := Top;
  RequestLayout;
  Invalidate;
end;

procedure TPanel.ScrollBarMoved;
begin
  ScrollTo(FHorizontalBar.Position, FVerticalBar.Position);
end;

procedure TPanel.ReceiveMessage(var Message: TPostedMessage);
begin
  if (Message.Code = MessageNotify) and IsOwnScrollPart(TControl(Message.Parameter1)) then
  begin
    if Message.Parameter2 = NotifyChanged then
      ScrollBarMoved;
    Exit;
  end;
  inherited ReceiveMessage(Message);
end;

procedure TPanel.ScrollControlIntoView(Control: TControl);
var
  Place: TRectangle;
  OriginLeft: LongInt;
  OriginTop: LongInt;
  Left: LongInt;
  Top: LongInt;
begin
  if not FAutoScroll or (Control = nil) or (Control = Self) or IsOwnScrollPart(Control) then
    Exit;
  Place := Control.PixelBounds;
  { Content coordinates (pixels): from the scrolled area's top left. }
  OriginLeft := FViewArea.Left - Scaled(FScrollLeft);
  OriginTop := FViewArea.Top - Scaled(FScrollTop);
  Left := ScrollPositionToShow(Scaled(FScrollLeft), RectangleWidth(FViewArea), Place.Left - OriginLeft,
    RectangleWidth(Place));
  Top := ScrollPositionToShow(Scaled(FScrollTop), RectangleHeight(FViewArea), Place.Top - OriginTop,
    RectangleHeight(Place));
  ScrollTo(PixelsToLogicalCeiling(Left), PixelsToLogicalCeiling(Top));
end;

procedure TPanel.DescendantFocused(Control: TControl);
begin
  ScrollControlIntoView(Control);
end;

procedure TPanel.Wheel(Steps: LongInt);
begin
  if FAutoScroll and FVerticalBar.Visible then
    ScrollTo(FScrollLeft, FScrollTop - Steps * WheelSteps * ScrollStep)
  else if FAutoScroll and FHorizontalBar.Visible then
    ScrollTo(FScrollLeft - Steps * WheelSteps * ScrollStep, FScrollTop)
  else
    inherited Wheel(Steps);
end;

function TPanel.KeyDown(Code, Character, Modifiers: LongWord): Boolean;
var
  Page: LongInt;
  WithControl: Boolean;
begin
  Result := False;
  if not FAutoScroll or not (FVerticalBar.Visible or FHorizontalBar.Visible) then
    Exit;
  Page := Unscaled(RectangleHeight(FViewArea));
  WithControl := (Modifiers and ModifierControl) <> 0;
  Result := True;
  case Code of
    KeyPageUp: ScrollTo(FScrollLeft, FScrollTop - Page);
    KeyPageDown: ScrollTo(FScrollLeft, FScrollTop + Page);
    KeyArrowUp: ScrollTo(FScrollLeft, FScrollTop - ScrollStep);
    KeyArrowDown: ScrollTo(FScrollLeft, FScrollTop + ScrollStep);
    KeyArrowLeft: ScrollTo(FScrollLeft - ScrollStep, FScrollTop);
    KeyArrowRight: ScrollTo(FScrollLeft + ScrollStep, FScrollTop);
  else
    if WithControl and (Code = KeyHome) then
      ScrollTo(0, 0)
    else if WithControl and (Code = KeyEnd) then
      ScrollTo(FScrollLeft, Unscaled(FContentHeight))
    else
      Result := False;
  end;
end;

{ --- TGroupBox ------------------------------------------------------------------- }

function TGroupBox.MatchesMnemonic(Character: LongWord): Boolean;
begin
  Result := TextMatchesMnemonic(Character);
end;

procedure TGroupBox.ActivateMnemonic(Character: LongWord);
begin
  if Host <> nil then
    Host.FocusControlAfter(Self);
end;

function TGroupBox.PreferredSize: TSize;
var
  Caption: LongInt;
begin
  Result := ChildrenExtent;
  Result := MakeSize(Result.cx + GroupFrameRoom, Result.cy + GroupFrameRoom);
  { The text sits in the top edge, indented. }
  Caption := PixelsToLogicalCeiling(MnemonicTextWidth(ControlFace, Text)) + 3 * GroupFrameRoom;
  if Caption > Result.cx then
    Result.cx := Caption;
end;

{ The outline of Rectangle, Thickness pixels wide inside it. }
procedure DrawThickOutline(const Canvas: TCanvas; const Rectangle: TRectangle; Thickness: LongInt; Color: TColor);
var
  Width: LongInt;
  Height: LongInt;
begin
  Width := RectangleWidth(Rectangle);
  Height := RectangleHeight(Rectangle);
  FillRectangle(Canvas, MakeRectangle(Rectangle.Left, Rectangle.Top, Width, Thickness), Color);
  FillRectangle(Canvas, MakeRectangle(Rectangle.Left, Rectangle.Bottom - Thickness, Width, Thickness), Color);
  FillRectangle(Canvas, MakeRectangle(Rectangle.Left, Rectangle.Top, Thickness, Height), Color);
  FillRectangle(Canvas, MakeRectangle(Rectangle.Right - Thickness, Rectangle.Top, Thickness, Height), Color);
end;

procedure TGroupBox.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
  ShadowFrame: TRectangle;
  HighlightFrame: TRectangle;
  LineWidth: LongInt;
  TextTop: LongInt;
  Indent: LongInt;
  Width: LongInt;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillRectangle(Canvas, Box, Theme.Face);
  TextTop := TextHeight(ControlFace) div 2;
  LineWidth := Scaled(1);
  if LineWidth < 1 then
    LineWidth := 1;
  { Etched (a groove): a highlight outline a line down and right of a
    shadow outline, the shadow drawn over it. The shadow's right and
    bottom lines fall inside the highlight's, so the groove turns each
    corner cleanly; the outer corners at the top right and bottom left
    stay the face. }
  ShadowFrame := MakeRectangle(0, TextTop, RectangleWidth(Box) - LineWidth,
    RectangleHeight(Box) - TextTop - LineWidth);
  HighlightFrame := OffsetRectangle(ShadowFrame, LineWidth, LineWidth);
  DrawThickOutline(Canvas, HighlightFrame, LineWidth, Theme.Highlight);
  DrawThickOutline(Canvas, ShadowFrame, LineWidth, Theme.Shadow);
  if Text = '' then
    Exit;
  Indent := Scaled(8);
  Width := MnemonicTextWidth(ControlFace, Text) + Scaled(4);
  FillRectangle(Canvas, MakeRectangle(Indent, 0, Width, TextHeight(ControlFace)), Theme.Face);
  DrawMnemonicTextInBox(Canvas, ControlFace, Text, MakeRectangle(Indent + Scaled(2), 0, Width, TextHeight(ControlFace)),
    AlignTextLeft, Theme.FaceText);
end;

end.
