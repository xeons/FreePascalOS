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
  The polygon tool: the first press starts the polygon and its first
  side follows the pointer; every press after fixes a corner where the
  side ends and starts the next. A press near the first corner (with
  three or more), a second press on the last corner (a double click),
  Enter, or changing the tool closes it and draws it with the tool
  box's fill style; Escape abandons it. While it is being made it shows
  as a line through its corners in the button's colour. Shift keeps the
  side being drawn to multiples of 45 degrees.
}
unit Paint.PolygonTool;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles,
  Paint.Tools,
  Paint.ShapeGeometry;

type
  TPolygonTool = class(TPaintTool)
  private
    FButton: LongWord;
    FPoints: TPointArray;
    FLastExtent: TRectangle;
    procedure ShowOpen;
    procedure MoveLastCorner(X, Y: Double; Modifiers: LongWord);
    function NearCorner(Index: LongInt; const Pixel: TPoint): Boolean;
  public
    procedure PointerDown(X, Y: Double; Button, Modifiers: LongWord); override;
    procedure PointerMove(X, Y: Double; Buttons, Modifiers: LongWord); override;
    procedure Finish; override;
    procedure Cancel; override;
  end;

implementation

uses
  Abi.SystemCalls,
  Paint.ToolKinds,
  Paint.ShapeDrawing;

const
  { View pixels within which a press is on a corner. }
  CornerReach = 5;

function TPolygonTool.NearCorner(Index: LongInt; const Pixel: TPoint): Boolean;
begin
  Result := IsNear(Pixel.X, Pixel.Y, FPoints[Index].X, FPoints[Index].Y, FSession.ViewPixelsToImage(CornerReach));
end;

procedure TPolygonTool.ShowOpen;
var
  Width: LongInt;
begin
  RestoreArea(FLastExtent);
  Width := FSession.ToolSize(ToolPolygon);
  DrawPolylineShape(ImageCanvas, FPoints, Width, ColorFor(FButton));
  FLastExtent := StrokeExtent(FPoints, Width);
  Touch(FLastExtent);
end;

procedure TPolygonTool.MoveLastCorner(X, Y: Double; Modifiers: LongWord);
var
  Corner: TPoint;
  Previous: TPoint;
begin
  Corner := MakePoint(PixelOf(X), PixelOf(Y));
  if (Modifiers and ModifierShift) <> 0 then
  begin
    Previous := FPoints[High(FPoints) - 1];
    Corner := LineAtSnappedAngle(Previous.X, Previous.Y, Corner.X, Corner.Y);
  end;
  FPoints[High(FPoints)] := Corner;
end;

procedure TPolygonTool.PointerDown(X, Y: Double; Button, Modifiers: LongWord);
var
  Pixel: TPoint;
  Count: LongInt;
begin
  Pixel := MakePoint(PixelOf(X), PixelOf(Y));
  Count := Length(FPoints);
  if Count = 0 then
  begin
    FButton := Button;
    FLastExtent := MakeRectangle(0, 0, 0, 0);
    BeginEdit;
    SetLength(FPoints, 2);
    FPoints[0] := Pixel;
    FPoints[1] := Pixel;
    ShowOpen;
    Exit;
  end;
  { The fixed corners are all but the last, which follows the pointer. }
  if (Count >= 4) and (NearCorner(0, Pixel) or NearCorner(Count - 2, Pixel)) then
  begin
    SetLength(FPoints, Count - 1);
    Finish;
    Exit;
  end;
  MoveLastCorner(X, Y, Modifiers);
  SetLength(FPoints, Count + 1);
  FPoints[Count] := FPoints[Count - 1];
  ShowOpen;
end;

procedure TPolygonTool.PointerMove(X, Y: Double; Buttons, Modifiers: LongWord);
begin
  if Length(FPoints) = 0 then
    Exit;
  MoveLastCorner(X, Y, Modifiers);
  ShowOpen;
end;

procedure TPolygonTool.Finish;
var
  Style: TShapeStyle;
begin
  if Length(FPoints) = 0 then
    Exit;
  RestoreArea(FLastExtent);
  Style := MakeShapeStyle(FSession.Settings.FillStyle, FSession.ToolSize(ToolPolygon), ColorFor(FButton),
    OtherColorFor(FButton));
  DrawPolygonShape(ImageCanvas, FPoints, Style);
  Touch(StrokeExtent(FPoints, Style.Width));
  FPoints := nil;
  CommitEdit('Polygon');
end;

procedure TPolygonTool.Cancel;
begin
  FPoints := nil;
  CancelEdit;
end;

end.
