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
  The tools that draw a shape by dragging from one corner (or end) to
  the other: the line, the rectangle, the ellipse and the rounded
  rectangle. The shape is drawn on the picture as it is dragged (what
  was under it put back each time) and the edit made when the button is
  let go. Shift keeps a line to multiples of 45 degrees and the others
  square. The outline is in the button's colour and the interior in the
  other one, as the tool box's fill style says (Paint.ShapeDrawing).
}
unit Paint.ShapeTools;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles,
  Paint.Tools,
  Paint.ToolKinds,
  Paint.ShapeDrawing;

type
  TDragShapeTool = class(TPaintTool)
  private
    FButton: LongWord;
    FStart: TPoint;
    FLastExtent: TRectangle;
    procedure Redraw(X, Y: Double; Modifiers: LongWord);
  protected
    function Kind: TToolKind; virtual; abstract;
    { The end of the drag with Shift's constraint applied. }
    function ConstrainedEnd(const Corner: TPoint; Constrained: Boolean): TPoint; virtual;
    { Draws the shape from FStart to Corner; returns what it can touch. }
    function DrawShape(const Corner: TPoint): TRectangle; virtual; abstract;
    property PressedButton: LongWord read FButton;
    property Start: TPoint read FStart;
  public
    procedure PointerDown(X, Y: Double; Button, Modifiers: LongWord); override;
    procedure PointerMove(X, Y: Double; Buttons, Modifiers: LongWord); override;
    procedure PointerUp(X, Y: Double; Button, Modifiers: LongWord); override;
  end;

  TLineTool = class(TDragShapeTool)
  protected
    function Kind: TToolKind; override;
    function ConstrainedEnd(const Corner: TPoint; Constrained: Boolean): TPoint; override;
    function DrawShape(const Corner: TPoint): TRectangle; override;
  end;

  TBoxShapeTool = class(TDragShapeTool)
  protected
    function ShapeStyle: TShapeStyle;
    function DrawShape(const Corner: TPoint): TRectangle; override;
    procedure DrawInBounds(const Bounds: TRectangle); virtual; abstract;
  end;

  TRectangleTool = class(TBoxShapeTool)
  protected
    function Kind: TToolKind; override;
    procedure DrawInBounds(const Bounds: TRectangle); override;
  end;

  TEllipseTool = class(TBoxShapeTool)
  protected
    function Kind: TToolKind; override;
    procedure DrawInBounds(const Bounds: TRectangle); override;
  end;

  TRoundedRectangleTool = class(TBoxShapeTool)
  protected
    function Kind: TToolKind; override;
    procedure DrawInBounds(const Bounds: TRectangle); override;
  end;

implementation

uses
  Abi.SystemCalls,
  Paint.ShapeGeometry;

procedure TDragShapeTool.PointerDown(X, Y: Double; Button, Modifiers: LongWord);
begin
  if Editing then
    Exit;
  FButton := Button;
  FStart := MakePoint(PixelOf(X), PixelOf(Y));
  FLastExtent := MakeRectangle(0, 0, 0, 0);
  BeginEdit;
  Redraw(X, Y, Modifiers);
end;

function TDragShapeTool.ConstrainedEnd(const Corner: TPoint; Constrained: Boolean): TPoint;
begin
  if Constrained then
    Result := SquareCorner(FStart.X, FStart.Y, Corner.X, Corner.Y)
  else
    Result := Corner;
end;

procedure TDragShapeTool.Redraw(X, Y: Double; Modifiers: LongWord);
var
  Corner: TPoint;
begin
  RestoreArea(FLastExtent);
  Corner := ConstrainedEnd(MakePoint(PixelOf(X), PixelOf(Y)), (Modifiers and ModifierShift) <> 0);
  FLastExtent := DrawShape(Corner);
  Touch(FLastExtent);
end;

procedure TDragShapeTool.PointerMove(X, Y: Double; Buttons, Modifiers: LongWord);
begin
  if Editing then
    Redraw(X, Y, Modifiers);
end;

procedure TDragShapeTool.PointerUp(X, Y: Double; Button, Modifiers: LongWord);
begin
  if not Editing or (Button <> FButton) then
    Exit;
  Redraw(X, Y, Modifiers);
  CommitEdit(ToolWords[Kind]);
end;

function TLineTool.Kind: TToolKind;
begin
  Result := ToolLine;
end;

function TLineTool.ConstrainedEnd(const Corner: TPoint; Constrained: Boolean): TPoint;
begin
  if Constrained then
    Result := LineAtSnappedAngle(Start.X, Start.Y, Corner.X, Corner.Y)
  else
    Result := Corner;
end;

function TLineTool.DrawShape(const Corner: TPoint): TRectangle;
var
  Width: LongInt;
begin
  Width := FSession.ToolSize(ToolLine);
  DrawLineShape(ImageCanvas, Start.X, Start.Y, Corner.X, Corner.Y, Width, ColorFor(PressedButton));
  Result := StrokeExtent([Start, Corner], Width);
end;

function TBoxShapeTool.DrawShape(const Corner: TPoint): TRectangle;
begin
  Result := RectangleFromCorners(Start.X, Start.Y, Corner.X, Corner.Y);
  DrawInBounds(Result);
  Result := InflateRectangle(Result, 1);
end;

function TBoxShapeTool.ShapeStyle: TShapeStyle;
begin
  Result := MakeShapeStyle(FSession.Settings.FillStyle, FSession.ToolSize(Kind), ColorFor(PressedButton),
    OtherColorFor(PressedButton));
end;

function TRectangleTool.Kind: TToolKind;
begin
  Result := ToolRectangle;
end;

procedure TRectangleTool.DrawInBounds(const Bounds: TRectangle);
begin
  DrawRectangleShape(ImageCanvas, Bounds, ShapeStyle);
end;

function TEllipseTool.Kind: TToolKind;
begin
  Result := ToolEllipse;
end;

procedure TEllipseTool.DrawInBounds(const Bounds: TRectangle);
begin
  DrawEllipseShape(ImageCanvas, Bounds, ShapeStyle);
end;

function TRoundedRectangleTool.Kind: TToolKind;
begin
  Result := ToolRoundedRectangle;
end;

procedure TRoundedRectangleTool.DrawInBounds(const Bounds: TRectangle);
begin
  DrawRoundedRectangleShape(ImageCanvas, Bounds, ShapeStyle);
end;

end.
