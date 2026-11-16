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
  Splitters: a thin bar between a pane docked to the left and what fills
  the rest, dragged to make the pane wider or narrower.

  The splitter is docked to the left itself, made right after the pane
  (Pane), so it sits on the pane's right edge. Dragging it gives the
  pane a new width in logical units, kept between MinimumWidth and
  what leaves MinimumRest for the rest; OnChange tells when the drag
  is over (to remember the width). The pointer is the left-right arrow
  over it.
}
unit Controls.Splitter;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Canvas,
  Controls.Base;

type
  TSplitter = class(TControl)
  private
    FPane: TControl;
    FDragging: Boolean;
    FStartX: LongInt;
    FStartWidth: LongInt;
    FMinimumWidth: LongInt;
    FMinimumRest: LongInt;
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    procedure PointerMove(X, Y: LongInt; Buttons: LongWord); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
  public
    constructor Create(AParent: TControl); override;
    { The pane's width (logical units). }
    function PaneWidth: LongInt;
    procedure SetPaneWidth(Width: LongInt);
    property Pane: TControl read FPane write FPane;
    property MinimumWidth: LongInt read FMinimumWidth write FMinimumWidth;
    property MinimumRest: LongInt read FMinimumRest write FMinimumRest;
  end;

implementation

uses
  Abi.SystemCalls,
  Drawing.Rectangles,
  Windowing.Protocol,
  Windowing.Theme,
  Windowing.Connection;

const
  SplitterWidth = 5;

constructor TSplitter.Create(AParent: TControl);
begin
  inherited Create(AParent);
  SetBounds(0, 0, SplitterWidth, 0);
  Align := AlignLeft;
  PointerShape := PointerResizeHorizontal;
  FMinimumWidth := 60;
  FMinimumRest := 120;
end;

function TSplitter.PaneWidth: LongInt;
begin
  if FPane = nil then
    Exit(0);
  Result := RectangleWidth(FPane.Bounds);
end;

procedure TSplitter.SetPaneWidth(Width: LongInt);
var
  Largest: LongInt;
begin
  if FPane = nil then
    Exit;
  if Parent <> nil then
  begin
    Largest := Unscaled(RectangleWidth(Parent.PixelBounds)) - SplitterWidth - FMinimumRest;
    if Width > Largest then
      Width := Largest;
  end;
  if Width < FMinimumWidth then
    Width := FMinimumWidth;
  if Width = PaneWidth then
    Exit;
  FPane.SetBounds(0, 0, Width, 0);
end;

procedure TSplitter.Paint(var Canvas: TCanvas);
var
  Height: LongInt;
begin
  Height := RectangleHeight(PixelBounds);
  FillRectangle(Canvas, MakeRectangle(0, 0, RectangleWidth(PixelBounds), Height), Theme.Face);
end;

procedure TSplitter.PointerDown(X, Y: LongInt; Button: LongWord);
begin
  if Button <> ButtonLeft then
    Exit;
  FDragging := True;
  { In the window's pixels: the splitter itself moves while dragged. }
  FStartX := PixelBounds.Left + X;
  FStartWidth := PaneWidth;
end;

procedure TSplitter.PointerMove(X, Y: LongInt; Buttons: LongWord);
begin
  if FDragging then
    SetPaneWidth(FStartWidth + Unscaled(PixelBounds.Left + X - FStartX));
end;

procedure TSplitter.PointerUp(X, Y: LongInt; Button: LongWord);
begin
  if not FDragging then
    Exit;
  FDragging := False;
  Changed;
end;

end.
