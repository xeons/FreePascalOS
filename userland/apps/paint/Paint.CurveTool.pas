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
  The curve tool, in three drags: the first draws a straight line from
  one end to the other; the second bends it towards where the pointer
  is (a quadratic curve, one control point); the third bends it again
  (a cubic curve, two control points) and draws it. Enter (or changing
  the tool) after the first or second drag draws the curve as it is;
  Escape abandons it. The curve is as wide as the tool box's size says,
  in the colour of the button that started it, anti-aliased with round
  ends.
}
unit Paint.CurveTool;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles,
  Paint.Tools;

type
  TCurveTool = class(TPaintTool)
  private
    FButton: LongWord;
    { 0: nothing yet; 1: dragging the line; 2: the line drawn; 3:
      dragging the first bend; 4: bent once; 5: dragging the second. }
    FStage: LongInt;
    FFrom: TPoint;
    FTarget: TPoint;
    FControls: array of TPoint;
    FLastExtent: TRectangle;
    procedure Show;
    procedure Place(const Pixel: TPoint);
  public
    procedure PointerDown(X, Y: Double; Button, Modifiers: LongWord); override;
    procedure PointerMove(X, Y: Double; Buttons, Modifiers: LongWord); override;
    procedure PointerUp(X, Y: Double; Button, Modifiers: LongWord); override;
    procedure Finish; override;
    procedure Cancel; override;
  end;

implementation

uses
  Math,
  Drawing.Rasterizer,
  Drawing.Curves,
  Paint.ToolKinds,
  Paint.ShapeDrawing;

procedure TCurveTool.Show;
var
  Width: LongInt;
  Points: TPrecisePoints;
  Index: LongInt;
  Area: TRectangle;
begin
  RestoreArea(FLastExtent);
  Width := FSession.ToolSize(ToolCurve);
  DrawCurveShape(ImageCanvas, FFrom, FTarget, FControls, Width, ColorFor(FButton));
  { The curve stays within its control polygon's bounds. }
  Points := CurvePoints(FFrom, FTarget, FControls);
  Area := MakeRectangle(Floor(Points[0].X), Floor(Points[0].Y), 1, 1);
  for Index := 1 to High(Points) do
    Area := BoundingRectangle(Area, MakeRectangle(Floor(Points[Index].X), Floor(Points[Index].Y), 1, 1));
  FLastExtent := InflateRectangle(Area, Width div 2 + 2);
  Touch(FLastExtent);
end;

procedure TCurveTool.Place(const Pixel: TPoint);
begin
  case FStage of
    1: FTarget := Pixel;
    3: FControls[0] := Pixel;
    5: FControls[1] := Pixel;
  end;
end;

procedure TCurveTool.PointerDown(X, Y: Double; Button, Modifiers: LongWord);
var
  Pixel: TPoint;
begin
  Pixel := MakePoint(PixelOf(X), PixelOf(Y));
  case FStage of
    0:
      begin
        FButton := Button;
        FLastExtent := MakeRectangle(0, 0, 0, 0);
        FControls := nil;
        FFrom := Pixel;
        FTarget := Pixel;
        BeginEdit;
        FStage := 1;
      end;
    2:
      begin
        SetLength(FControls, 1);
        FControls[0] := Pixel;
        FStage := 3;
      end;
    4:
      begin
        SetLength(FControls, 2);
        FControls[1] := Pixel;
        FStage := 5;
      end;
  else
    Exit;
  end;
  Show;
end;

procedure TCurveTool.PointerMove(X, Y: Double; Buttons, Modifiers: LongWord);
begin
  if not (FStage in [1, 3, 5]) then
    Exit;
  Place(MakePoint(PixelOf(X), PixelOf(Y)));
  Show;
end;

procedure TCurveTool.PointerUp(X, Y: Double; Button, Modifiers: LongWord);
begin
  if not (FStage in [1, 3, 5]) then
    Exit;
  Place(MakePoint(PixelOf(X), PixelOf(Y)));
  Show;
  if FStage = 5 then
    Finish
  else
    Inc(FStage);
end;

procedure TCurveTool.Finish;
begin
  if FStage = 0 then
    Exit;
  FStage := 0;
  FControls := nil;
  CommitEdit('Curve');
end;

procedure TCurveTool.Cancel;
begin
  FStage := 0;
  FControls := nil;
  CancelEdit;
end;

end.
