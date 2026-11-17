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
  Splitters: a thin bar between a docked pane and what fills the rest,
  dragged to make the pane larger or smaller.

  The splitter is docked to the same side as its pane (Pane), made right
  after it, so it sits on the pane's inner edge: docked left or right it
  is a vertical bar that changes the pane's width, docked to the top or
  bottom a horizontal bar that changes its height. Dragging it gives the
  pane a new extent in logical units, kept between MinimumWidth and
  what leaves MinimumRest for the rest (and within the pane's own
  minimum and maximum sizes); OnChange tells when the drag is over (to
  remember the extent). The pointer is the two-headed arrow across it.
  A splitter that is KeyboardMovable takes the focus, and the arrow keys
  across it move it by KeyboardStep (OnChange after each).
}
unit Controls.Splitter;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Canvas,
  Controls.Base;

const
  { Logical units across the bar. }
  SplitterThickness = 5;

type
  TSplitter = class(TControl)
  private
    FPane: TControl;
    FDragging: Boolean;
    FStartPosition: LongInt;
    FStartExtent: LongInt;
    FMinimumWidth: LongInt;
    FMinimumRest: LongInt;
    FKeyboardMovable: Boolean;
    FKeyboardStep: LongInt;
    procedure SetKeyboardMovable(Value: Boolean);
    { Along the direction the bar moves, from (X, Y) in the window. }
    function Along(X, Y: LongInt): LongInt;
    { The pane grows as the bar moves towards higher coordinates. }
    function GrowsForward: Boolean;
    function ParentExtent: LongInt;
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    procedure PointerMove(X, Y: LongInt; Buttons: LongWord); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
    function KeyDown(Code, Character, Modifiers: LongWord): Boolean; override;
  public
    constructor Create(AParent: TControl); override;
    { A vertical bar (docked left or right): it changes widths. }
    function IsVertical: Boolean;
    { The pane's width or height (logical units). }
    function PaneExtent: LongInt;
    procedure SetPaneExtent(Extent: LongInt);
    { The same for a vertical bar (as it was first made). }
    function PaneWidth: LongInt;
    procedure SetPaneWidth(Width: LongInt);
    property Pane: TControl read FPane write FPane;
    property MinimumWidth: LongInt read FMinimumWidth write FMinimumWidth;
    property MinimumRest: LongInt read FMinimumRest write FMinimumRest;
    property KeyboardMovable: Boolean read FKeyboardMovable write SetKeyboardMovable;
    property KeyboardStep: LongInt read FKeyboardStep write FKeyboardStep;
  end;

implementation

uses
  Abi.SystemCalls,
  Drawing.Rectangles,
  Drawing.Bevels,
  Windowing.Protocol,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Keys,
  Controls.LayoutRules,
  Controls.Painting;

constructor TSplitter.Create(AParent: TControl);
begin
  inherited Create(AParent);
  SetBounds(0, 0, SplitterThickness, SplitterThickness);
  Align := AlignLeft;
  PointerShape := PointerResizeHorizontal;
  FMinimumWidth := 60;
  FMinimumRest := 120;
  FKeyboardStep := 4;
end;

function TSplitter.IsVertical: Boolean;
begin
  Result := Align in [AlignLeft, AlignRight, AlignNone, AlignClient];
end;

function TSplitter.GrowsForward: Boolean;
begin
  Result := Align in [AlignLeft, AlignTop, AlignNone, AlignClient];
end;

procedure TSplitter.SetKeyboardMovable(Value: Boolean);
begin
  FKeyboardMovable := Value;
  CanFocus := Value;
end;

function TSplitter.Along(X, Y: LongInt): LongInt;
begin
  if IsVertical then
    Result := X
  else
    Result := Y;
end;

{ What the pane and the rest share (logical units): the parent's client
  area across the bar. }
function TSplitter.ParentExtent: LongInt;
var
  Area: TRectangle;
  Padding: TSpacing;
begin
  Area := Parent.PixelBounds;
  Padding := Parent.ContentPadding;
  if IsVertical then
    Result := Unscaled(RectangleWidth(Area)) - SpacingWidth(Padding)
  else
    Result := Unscaled(RectangleHeight(Area)) - SpacingHeight(Padding);
end;

function TSplitter.PaneExtent: LongInt;
begin
  if FPane = nil then
    Exit(0);
  if IsVertical then
    Result := RectangleWidth(FPane.Bounds)
  else
    Result := RectangleHeight(FPane.Bounds);
end;

procedure TSplitter.SetPaneExtent(Extent: LongInt);
var
  Largest: LongInt;
begin
  if FPane = nil then
    Exit;
  if Parent <> nil then
  begin
    Largest := ParentExtent - SplitterThickness - FMinimumRest;
    if Extent > Largest then
      Extent := Largest;
  end;
  if Extent < FMinimumWidth then
    Extent := FMinimumWidth;
  if IsVertical then
    Extent := ConstrainWidth(Extent, FPane.Constraints)
  else
    Extent := ConstrainHeight(Extent, FPane.Constraints);
  if Extent = PaneExtent then
    Exit;
  if IsVertical then
    FPane.SetBounds(0, 0, Extent, RectangleHeight(FPane.Bounds))
  else
    FPane.SetBounds(0, 0, RectangleWidth(FPane.Bounds), Extent);
end;

function TSplitter.PaneWidth: LongInt;
begin
  Result := PaneExtent;
end;

procedure TSplitter.SetPaneWidth(Width: LongInt);
begin
  SetPaneExtent(Width);
end;

procedure TSplitter.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillRectangle(Canvas, Box, Theme.Face);
  if Theme.SplitterGrip then
    DrawGripDots(Canvas, Box, IsVertical);
  if Focused then
    DrawFocusFrame(Canvas, InflateRectangle(Box, -1), Theme.FaceText);
end;

procedure TSplitter.PointerDown(X, Y: LongInt; Button: LongWord);
begin
  if Button <> ButtonLeft then
    Exit;
  if IsVertical then
    PointerShape := PointerResizeHorizontal
  else
    PointerShape := PointerResizeVertical;
  FDragging := True;
  { In the window's pixels: the splitter itself moves while dragged. }
  FStartPosition := Along(PixelBounds.Left + X, PixelBounds.Top + Y);
  FStartExtent := PaneExtent;
end;

procedure TSplitter.PointerMove(X, Y: LongInt; Buttons: LongWord);
var
  Moved: LongInt;
begin
  if not IsVertical then
    PointerShape := PointerResizeVertical
  else
    PointerShape := PointerResizeHorizontal;
  if not FDragging then
    Exit;
  Moved := Unscaled(Along(PixelBounds.Left + X, PixelBounds.Top + Y) - FStartPosition);
  if not GrowsForward then
    Moved := -Moved;
  SetPaneExtent(FStartExtent + Moved);
end;

procedure TSplitter.PointerUp(X, Y: LongInt; Button: LongWord);
begin
  if not FDragging then
    Exit;
  FDragging := False;
  Changed;
end;

function TSplitter.KeyDown(Code, Character, Modifiers: LongWord): Boolean;
var
  Step: LongInt;
begin
  Result := False;
  if not FKeyboardMovable then
    Exit;
  Step := 0;
  if IsVertical and (Code = KeyArrowLeft) then
    Step := -FKeyboardStep
  else if IsVertical and (Code = KeyArrowRight) then
    Step := FKeyboardStep
  else if not IsVertical and (Code = KeyArrowUp) then
    Step := -FKeyboardStep
  else if not IsVertical and (Code = KeyArrowDown) then
    Step := FKeyboardStep;
  if Step = 0 then
    Exit;
  if not GrowsForward then
    Step := -Step;
  SetPaneExtent(PaneExtent + Step);
  Changed;
  Result := True;
end;

end.
