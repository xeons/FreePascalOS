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
  Absolutely positioned boxes (CSS 2.2 10.3.7, 10.6.4).

  They are laid out after their containing block (the padding box of
  the nearest positioned block ancestor, the viewport for fixed boxes)
  has its size: left, right and width (and top, bottom and height)
  solve the constraint, an auto side takes the static position (where
  the box would have been in flow), an auto width or height shrinks to
  fit or comes from the content, auto margins center a box whose three
  values are all given. The result is stored relative to the box's
  layout parent like any other box.
}
unit Web.Layout.Positioned;

{$mode objfpc}
{$H+}

interface

uses
  Web.Layout.Boxes, Web.Layout.Context;

{ Lays out the boxes of List, whose containing block is Container. }
procedure LayoutPositionedBoxes(Container: TLayoutBox; List: TPositionedList; const Input: TLayoutInput);

implementation

uses
  Css.PropertyIds, Web.Layout.Values, Web.Layout.Sizing, Web.Layout.Dispatch;

procedure LayoutOne(Container, Box: TLayoutBox; const Input: TLayoutInput);
var
  ContainingWidth, ContainingHeight, OriginX, OriginY: Single;
  LeftValue, RightValue, TopValue, BottomValue: Single;
  Width, Available: Double;
  HasLeft, HasRight, HasTop, HasBottom, AutoWidth, AutoHeight: Boolean;
  LayoutParent: TLayoutBox;
  ParentX, ParentY, StaticX, StaticY, Remaining: Single;
  ChildInput: TLayoutInput;
  OwnPositioned: TPositionedList;
begin
  if Container.Kind = bkViewport then
  begin
    ContainingWidth := Container.Width;
    ContainingHeight := Container.Height;
    OriginX := 0;
    OriginY := 0;
  end
  else
  begin
    ContainingWidth := Container.Width - Container.Border[sideLeft] - Container.Border[sideRight];
    ContainingHeight := Container.Height - Container.Border[sideTop] - Container.Border[sideBottom];
    OriginX := Container.Border[sideLeft];
    OriginY := Container.Border[sideTop];
  end;
  LayoutParent := Box.LayoutParent;
  if (bfFixed in Box.Flags) then
    Box.OffsetFrom(nil, ParentX, ParentY)
  else
    LayoutParent.OffsetFrom(Container, ParentX, ParentY);
  if bfFixed in Box.Flags then
  begin
    LayoutParent.OffsetFrom(nil, ParentX, ParentY);
    StaticX := ParentX + Box.StaticX - OriginX;
    StaticY := ParentY + Box.StaticY - OriginY;
  end
  else
  begin
    StaticX := ParentX + Box.StaticX - OriginX;
    StaticY := ParentY + Box.StaticY - OriginY;
  end;
  ResolveBoxEdges(Box, ContainingWidth);
  HasLeft := TryLength(Box.Style, cpLeft, ContainingWidth, LeftValue);
  HasRight := TryLength(Box.Style, cpRight, ContainingWidth, RightValue);
  HasTop := TryLength(Box.Style, cpTop, ContainingHeight, TopValue);
  HasBottom := TryLength(Box.Style, cpBottom, ContainingHeight, BottomValue);
  AutoWidth := SpecifiedBorderBoxWidth(Box, ContainingWidth) < 0;
  AutoHeight := SpecifiedBorderBoxHeight(Box, ContainingHeight) < 0;
  { The width. }
  if AutoWidth then
  begin
    if HasLeft and HasRight then
      Width := ContainingWidth - LeftValue - RightValue - Box.Margin[sideLeft] - Box.Margin[sideRight]
    else
    begin
      if HasLeft then
        Available := ContainingWidth - LeftValue
      else if HasRight then
        Available := ContainingWidth - RightValue
      else
        Available := ContainingWidth - StaticX;
      Width := ShrinkToFitWidth(Box, Available - Box.Margin[sideLeft] - Box.Margin[sideRight]);
    end;
    Width := ClampWidth(Box, Width, ContainingWidth);
  end
  else
    Width := ClampWidth(Box, SpecifiedBorderBoxWidth(Box, ContainingWidth), ContainingWidth);
  if not HasLeft and not HasRight then
  begin
    LeftValue := StaticX;
    HasLeft := True;
  end;
  if HasLeft and HasRight and not AutoWidth then
  begin
    Remaining := ContainingWidth - LeftValue - RightValue - Width - Box.Margin[sideLeft] - Box.Margin[sideRight];
    if IsAutoValue(Box.Style, cpMarginLeft) and IsAutoValue(Box.Style, cpMarginRight) and (Remaining > 0) then
    begin
      Box.Margin[sideLeft] := Remaining / 2;
      Box.Margin[sideRight] := Remaining / 2;
    end
    else if IsAutoValue(Box.Style, cpMarginLeft) then
      Box.Margin[sideLeft] := Remaining;
  end;
  if not HasLeft then
    LeftValue := ContainingWidth - RightValue - Width - Box.Margin[sideLeft] - Box.Margin[sideRight];
  { Lay out with that width; a height from top and bottom. }
  ChildInput := MakeChildInput(Input, ContainingWidth, ContainingHeight, wmFixed);
  ChildInput.FixedWidth := Width;
  ChildInput.Floats := nil;
  ChildInput.BfcX := 0;
  ChildInput.BfcY := 0;
  OwnPositioned := nil;
  if AutoHeight and HasTop and HasBottom then
    ChildInput.FixedHeight := ContainingHeight - TopValue - BottomValue - Box.Margin[sideTop] -
      Box.Margin[sideBottom];
  Box.MarkNeedsLayout;
  LayoutBox(Box, ChildInput);
  OwnPositioned.Free;
  if not HasTop and not HasBottom then
  begin
    TopValue := StaticY;
    HasTop := True;
  end;
  if HasTop and HasBottom and not AutoHeight then
  begin
    Remaining := ContainingHeight - TopValue - BottomValue - Box.Height - Box.Margin[sideTop] -
      Box.Margin[sideBottom];
    if IsAutoValue(Box.Style, cpMarginTop) and IsAutoValue(Box.Style, cpMarginBottom) and (Remaining > 0) then
    begin
      Box.Margin[sideTop] := Remaining / 2;
      Box.Margin[sideBottom] := Remaining / 2;
    end;
  end;
  if not HasTop then
    TopValue := ContainingHeight - BottomValue - Box.Height - Box.Margin[sideTop] - Box.Margin[sideBottom];
  { Relative to the layout parent. }
  if bfFixed in Box.Flags then
    LayoutParent.OffsetFrom(nil, ParentX, ParentY)
  else
    LayoutParent.OffsetFrom(Container, ParentX, ParentY);
  Box.X := OriginX + LeftValue + Box.Margin[sideLeft] - ParentX;
  Box.Y := OriginY + TopValue + Box.Margin[sideTop] - ParentY;
end;

procedure LayoutPositionedBoxes(Container: TLayoutBox; List: TPositionedList; const Input: TLayoutInput);
var
  Index: Integer;
begin
  Index := 0;
  { The list can grow while it is worked through (nested boxes). }
  while Index < List.Count do
  begin
    LayoutOne(Container, List.Boxes[Index], Input);
    Inc(Index);
  end;
end;

end.
