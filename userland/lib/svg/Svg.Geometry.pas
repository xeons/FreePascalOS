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
  The geometry of SVG's basic shapes (SVG 2 chapter 10) as paths: rect
  (with rx and ry: either alone stands for both, each at most half its
  side), circle, ellipse (rx and ry may be auto), line, polyline,
  polygon and path. Lengths resolve against the viewport (percentages)
  and the element's font size (em, ex).

  A shape with a negative or zero size where SVG says it is not drawn
  gives no path.
}
unit Svg.Geometry;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Paths,
  Svg.Nodes,
  Svg.Numbers;

{ The attribute as a length in user units; Default when it is absent or
  malformed. }
function AttributeLength(Node: TSvgNode; const Name: string; Direction: TSvgLengthDirection;
  const Viewport: TSvgViewport; Default: Double): Double;
{ The shape element's outline added to Path; False when it draws nothing. }
function BuildShapePath(Node: TSvgNode; const Viewport: TSvgViewport; var Path: TPath): Boolean;
function IsShapeKind(Kind: TSvgElementKind): Boolean;

implementation

uses
  SysUtils,
  Svg.PathData;

function IsShapeKind(Kind: TSvgElementKind): Boolean;
begin
  Result := Kind in [SvgRect, SvgCircle, SvgEllipse, SvgLine, SvgPolyline, SvgPolygon, SvgPath];
end;

function AttributeLength(Node: TSvgNode; const Name: string; Direction: TSvgLengthDirection;
  const Viewport: TSvgViewport; Default: Double): Double;
var
  Length: TSvgLength;
  Index: Integer;
begin
  Index := Node.AttributeIndex(Name);
  if (Index < 0) or not ParseLength(Node.Attributes[Index].Value, Length) then
    Exit(Default);
  Result := ResolveLength(Length, Direction, Viewport);
end;

{ A radius attribute: its length, or -1 when absent, malformed, negative
  or auto. }
function RadiusAttribute(Node: TSvgNode; const Name: string; Direction: TSvgLengthDirection;
  const Viewport: TSvgViewport): Double;
begin
  Result := AttributeLength(Node, Name, Direction, Viewport, -1);
  if Result < 0 then
    Result := -1;
end;

function BuildRect(Node: TSvgNode; const Viewport: TSvgViewport; var Path: TPath): Boolean;
var
  X, Y, Width, Height, RadiusX, RadiusY: Double;
begin
  X := AttributeLength(Node, 'x', DirectionHorizontal, Viewport, 0);
  Y := AttributeLength(Node, 'y', DirectionVertical, Viewport, 0);
  Width := AttributeLength(Node, 'width', DirectionHorizontal, Viewport, 0);
  Height := AttributeLength(Node, 'height', DirectionVertical, Viewport, 0);
  if (Width <= 0) or (Height <= 0) then
    Exit(False);
  RadiusX := RadiusAttribute(Node, 'rx', DirectionHorizontal, Viewport);
  RadiusY := RadiusAttribute(Node, 'ry', DirectionVertical, Viewport);
  if RadiusX < 0 then
    RadiusX := RadiusY;
  if RadiusY < 0 then
    RadiusY := RadiusX;
  if RadiusX < 0 then
  begin
    RadiusX := 0;
    RadiusY := 0;
  end;
  if RadiusX > Width / 2 then
    RadiusX := Width / 2;
  if RadiusY > Height / 2 then
    RadiusY := Height / 2;
  PathAddRoundedRectangle(Path, X, Y, Width, Height, RadiusX, RadiusY);
  Result := True;
end;

function BuildEllipse(Node: TSvgNode; const Viewport: TSvgViewport; var Path: TPath; Circle: Boolean): Boolean;
var
  CentreX, CentreY, RadiusX, RadiusY: Double;
begin
  CentreX := AttributeLength(Node, 'cx', DirectionHorizontal, Viewport, 0);
  CentreY := AttributeLength(Node, 'cy', DirectionVertical, Viewport, 0);
  if Circle then
  begin
    RadiusX := AttributeLength(Node, 'r', DirectionOther, Viewport, 0);
    RadiusY := RadiusX;
  end
  else
  begin
    RadiusX := RadiusAttribute(Node, 'rx', DirectionHorizontal, Viewport);
    RadiusY := RadiusAttribute(Node, 'ry', DirectionVertical, Viewport);
    if RadiusX < 0 then
      RadiusX := RadiusY;
    if RadiusY < 0 then
      RadiusY := RadiusX;
  end;
  if (RadiusX <= 0) or (RadiusY <= 0) then
    Exit(False);
  PathAddEllipse(Path, CentreX, CentreY, RadiusX, RadiusY);
  Result := True;
end;

function BuildShapePath(Node: TSvgNode; const Viewport: TSvgViewport; var Path: TPath): Boolean;
var
  Before: Integer;
begin
  Before := Path.Count;
  case Node.ElementKind of
    SvgRect:
      Exit(BuildRect(Node, Viewport, Path));
    SvgCircle:
      Exit(BuildEllipse(Node, Viewport, Path, True));
    SvgEllipse:
      Exit(BuildEllipse(Node, Viewport, Path, False));
    SvgLine:
      begin
        PathMoveTo(Path, AttributeLength(Node, 'x1', DirectionHorizontal, Viewport, 0),
          AttributeLength(Node, 'y1', DirectionVertical, Viewport, 0));
        PathLineTo(Path, AttributeLength(Node, 'x2', DirectionHorizontal, Viewport, 0),
          AttributeLength(Node, 'y2', DirectionVertical, Viewport, 0));
      end;
    SvgPolyline:
      ParsePointsInto(Node.Attribute('points'), Path, False);
    SvgPolygon:
      ParsePointsInto(Node.Attribute('points'), Path, True);
    SvgPath:
      ParsePathData(Node.Attribute('d'), Path);
    else
      Exit(False);
  end;
  Result := Path.Count > Before;
end;

end.
