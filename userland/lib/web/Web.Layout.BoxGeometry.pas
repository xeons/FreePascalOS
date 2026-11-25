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
  Where a box is, in document coordinates (unscrolled): a block-level or
  atomic box's border box; an inline box's fragments, one per line it
  is on (CSSOM View: getClientRects gives one rect per fragment,
  getBoundingClientRect their union). An inline box whose content is
  only blocks (block-in-inline) has no fragments of its own: its
  children's boxes stand for it.
}
unit Web.Layout.BoxGeometry;

{$mode objfpc}
{$H+}

interface

uses
  Web.Layout.Boxes;

type
  TBoxRectangle = record
    X, Y, Width, Height: Single;
  end;
  TBoxRectangleArray = array of TBoxRectangle;

{ The rectangles of Box (one for a block or atomic box, one per line
  fragment for an inline box). }
function BoxRectangles(Box: TLayoutBox): TBoxRectangleArray;
{ Their union; False when there are none. }
function BoxBounds(Box: TLayoutBox; out X, Y, Width, Height: Single): Boolean;

implementation

{ The box whose inline content holds an inline box's fragments. }
function InlineContainerOf(Box: TLayoutBox): TLayoutBox;
begin
  Result := Box.Parent;
  while (Result <> nil) and (Result.Kind = bkInline) do
    Result := Result.Parent;
  if (Result <> nil) and (Result.Inline = nil) then
    Result := nil;
end;

procedure AddRectangle(var Rectangles: TBoxRectangleArray; X, Y, Width, Height: Single);
begin
  SetLength(Rectangles, Length(Rectangles) + 1);
  Rectangles[High(Rectangles)].X := X;
  Rectangles[High(Rectangles)].Y := Y;
  Rectangles[High(Rectangles)].Width := Width;
  Rectangles[High(Rectangles)].Height := Height;
end;

procedure AddChildRectangles(Box: TLayoutBox; var Rectangles: TBoxRectangleArray);
var
  Child: TLayoutBox;
  Inner: TBoxRectangleArray;
  Index: Integer;
begin
  Child := Box.FirstChild;
  while Child <> nil do
  begin
    if Child.Kind <> bkText then
    begin
      Inner := BoxRectangles(Child);
      for Index := 0 to High(Inner) do
        AddRectangle(Rectangles, Inner[Index].X, Inner[Index].Y, Inner[Index].Width, Inner[Index].Height);
    end;
    Child := Child.NextSibling;
  end;
end;

function BoxRectangles(Box: TLayoutBox): TBoxRectangleArray;
var
  Container: TLayoutBox;
  Fragment: PLineFragment;
  ContainerX, ContainerY, X, Y: Single;
  Index: Integer;
begin
  Result := nil;
  if Box = nil then
    Exit;
  if Box.Kind <> bkInline then
  begin
    Box.AbsolutePosition(X, Y);
    AddRectangle(Result, X, Y, Box.Width, Box.Height);
    Exit;
  end;
  Container := InlineContainerOf(Box);
  if Container <> nil then
  begin
    Container.AbsolutePosition(ContainerX, ContainerY);
    for Index := 0 to Container.Inline.FragmentCount - 1 do
    begin
      Fragment := @Container.Inline.Fragments[Index];
      if (Fragment^.Kind = fkInlineBox) and (Fragment^.Box = Box) then
        AddRectangle(Result, ContainerX + Fragment^.X, ContainerY + Fragment^.Y, Fragment^.Width, Fragment^.Height);
    end;
  end;
  if Result = nil then
    AddChildRectangles(Box, Result);
end;

function BoxBounds(Box: TLayoutBox; out X, Y, Width, Height: Single): Boolean;
var
  Rectangles: TBoxRectangleArray;
  Index: Integer;
  Left, Top, Right, Bottom: Single;
begin
  X := 0;
  Y := 0;
  Width := 0;
  Height := 0;
  Rectangles := BoxRectangles(Box);
  Result := Length(Rectangles) > 0;
  if not Result then
    Exit;
  Left := Rectangles[0].X;
  Top := Rectangles[0].Y;
  Right := Left + Rectangles[0].Width;
  Bottom := Top + Rectangles[0].Height;
  for Index := 1 to High(Rectangles) do
  begin
    if Rectangles[Index].X < Left then
      Left := Rectangles[Index].X;
    if Rectangles[Index].Y < Top then
      Top := Rectangles[Index].Y;
    if Rectangles[Index].X + Rectangles[Index].Width > Right then
      Right := Rectangles[Index].X + Rectangles[Index].Width;
    if Rectangles[Index].Y + Rectangles[Index].Height > Bottom then
      Bottom := Rectangles[Index].Y + Rectangles[Index].Height;
  end;
  X := Left;
  Y := Top;
  Width := Right - Left;
  Height := Bottom - Top;
end;

end.
