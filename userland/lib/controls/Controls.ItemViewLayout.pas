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
  Where an item view's items and group headers go, in pixels of its
  content (before scrolling), for every view:

  * the icon views and tiles fill rows of equal cells, left to right,
    then the next row down;
  * details and content are one item per row, as wide as the area (or
    the columns, if wider);
  * the list fills a column of cells down, then the next to the right,
    and scrolls across (it shows no group headers).

  Grouped items (consecutive items of the same group: the view keeps
  them sorted by group) start a new row under their group's header, a
  band across the whole width; a collapsed group's items are left out.

  Moving with the arrow keys goes by the places worked out here: up and
  down to the nearest item in the row above or below, left and right
  along the order (across the columns in the list, nowhere in details).
  Plain arithmetic, no drawing.
}
unit Controls.ItemViewLayout;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles;

type
  TItemViewMode = (ItemViewExtraLargeIcons, ItemViewLargeIcons, ItemViewMediumIcons, ItemViewSmallIcons,
    ItemViewList, ItemViewDetails, ItemViewTiles, ItemViewContent);

  TItemLayoutInput = record
    Mode: TItemViewMode;
    { The area items are shown in (pixels). }
    AreaWidth: LongInt;
    AreaHeight: LongInt;
    { Each item's group (-1 for none), in the items' order. }
    ItemGroups: array of LongInt;
    GroupCollapsed: array of Boolean;
    CellWidth: LongInt;
    CellHeight: LongInt;
    GroupHeaderHeight: LongInt;
    { Space round the edges of the content. }
    Margin: LongInt;
  end;

  TItemLayout = record
    ItemRects: array of TRectangle;
    ItemShown: array of Boolean;
    GroupRects: array of TRectangle;
    GroupShown: array of Boolean;
    ContentWidth: LongInt;
    ContentHeight: LongInt;
    { The list: scrolls across rather than down. }
    Across: Boolean;
  end;

  TItemDirection = (ItemDirectionUp, ItemDirectionDown, ItemDirectionLeft, ItemDirectionRight);

function LayOutItems(const Input: TItemLayoutInput): TItemLayout;
{ The shown item whose place holds (X, Y) of the content, or -1. }
function ItemAtContentPoint(const Layout: TItemLayout; X, Y: LongInt): LongInt;
{ The shown group whose header holds (X, Y), or -1. }
function GroupAtContentPoint(const Layout: TItemLayout; X, Y: LongInt): LongInt;
{ The item a key moves to from Index (Index itself if none). }
function ItemInDirection(const Layout: TItemLayout; Mode: TItemViewMode; Index: LongInt;
  Direction: TItemDirection): LongInt;
{ The item about a page (Distance pixels) further down (or up, Distance
  negative) from Index. }
function ItemAPageAway(const Layout: TItemLayout; Index, Distance: LongInt): LongInt;
{ The first and last shown items in order (-1 if none). }
function FirstShownItem(const Layout: TItemLayout): LongInt;
function LastShownItem(const Layout: TItemLayout): LongInt;

implementation

function LayOutItems(const Input: TItemLayoutInput): TItemLayout;
var
  Count: LongInt;
  GroupCount: LongInt;
  Index: LongInt;
  PerLine: LongInt;
  Column: LongInt;
  X: LongInt;
  Y: LongInt;
  CurrentGroup: LongInt;
  Started: Boolean;
  Width: LongInt;
  Group: LongInt;
  Collapsed: Boolean;
  Row: LongInt;
  CellWidth: LongInt;
  CellHeight: LongInt;
begin
  Result := Default(TItemLayout);
  Count := Length(Input.ItemGroups);
  GroupCount := Length(Input.GroupCollapsed);
  SetLength(Result.ItemRects, Count);
  SetLength(Result.ItemShown, Count);
  SetLength(Result.GroupRects, GroupCount);
  SetLength(Result.GroupShown, GroupCount);
  CellWidth := Input.CellWidth;
  if CellWidth < 1 then
    CellWidth := 1;
  CellHeight := Input.CellHeight;
  if CellHeight < 1 then
    CellHeight := 1;
  Width := Input.AreaWidth - 2 * Input.Margin;
  if Width < CellWidth then
    Width := CellWidth;

  if Input.Mode = ItemViewList then
  begin
    { Down a column, then across; no headers. }
    Result.Across := True;
    PerLine := (Input.AreaHeight - 2 * Input.Margin) div CellHeight;
    if PerLine < 1 then
      PerLine := 1;
    for Index := 0 to Count - 1 do
    begin
      Column := Index div PerLine;
      Row := Index mod PerLine;
      Result.ItemRects[Index] := MakeRectangle(Input.Margin + Column * CellWidth, Input.Margin + Row * CellHeight,
        CellWidth, CellHeight);
      Result.ItemShown[Index] := True;
    end;
    Result.ContentWidth := Input.Margin * 2 + ((Count + PerLine - 1) div PerLine) * CellWidth;
    Result.ContentHeight := Input.AreaHeight;
    Exit;
  end;

  if Input.Mode in [ItemViewDetails, ItemViewContent] then
  begin
    PerLine := 1;
    if Input.Mode = ItemViewContent then
      CellWidth := Width
    else if CellWidth < Width then
      CellWidth := Width;
  end
  else
  begin
    PerLine := Width div CellWidth;
    if PerLine < 1 then
      PerLine := 1;
  end;

  Y := Input.Margin;
  Column := 0;
  CurrentGroup := -2;
  Started := False;
  Collapsed := False;
  for Index := 0 to Count - 1 do
  begin
    Group := Input.ItemGroups[Index];
    if (Group <> CurrentGroup) and (Group >= 0) and (Group < GroupCount) then
    begin
      { A new group: under the last row, its header across. }
      if Started and (Column > 0) then
        Y := Y + CellHeight;
      Column := 0;
      if Started then
        Y := Y + Input.Margin;
      Result.GroupRects[Group] := MakeRectangle(Input.Margin, Y, Width, Input.GroupHeaderHeight);
      Result.GroupShown[Group] := True;
      Y := Y + Input.GroupHeaderHeight;
      Collapsed := Input.GroupCollapsed[Group];
      CurrentGroup := Group;
    end
    else if Group <> CurrentGroup then
    begin
      CurrentGroup := Group;
      Collapsed := False;
    end;
    Started := True;
    if Collapsed then
    begin
      Result.ItemRects[Index] := MakeRectangle(0, 0, 0, 0);
      Result.ItemShown[Index] := False;
      Continue;
    end;
    X := Input.Margin + Column * CellWidth;
    Result.ItemRects[Index] := MakeRectangle(X, Y, CellWidth, CellHeight);
    Result.ItemShown[Index] := True;
    Inc(Column);
    if Column >= PerLine then
    begin
      Column := 0;
      Y := Y + CellHeight;
    end;
  end;
  if Column > 0 then
    Y := Y + CellHeight;
  Result.ContentHeight := Y + Input.Margin;
  Result.ContentWidth := Input.Margin * 2 + Width;
  if (Input.Mode = ItemViewDetails) and (CellWidth + 2 * Input.Margin > Result.ContentWidth) then
    Result.ContentWidth := CellWidth + 2 * Input.Margin;
end;

function ItemAtContentPoint(const Layout: TItemLayout; X, Y: LongInt): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to High(Layout.ItemRects) do
    if Layout.ItemShown[Index] and RectangleContainsPoint(Layout.ItemRects[Index], X, Y) then
      Exit(Index);
  Result := -1;
end;

function GroupAtContentPoint(const Layout: TItemLayout; X, Y: LongInt): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to High(Layout.GroupRects) do
    if Layout.GroupShown[Index] and RectangleContainsPoint(Layout.GroupRects[Index], X, Y) then
      Exit(Index);
  Result := -1;
end;

function FirstShownItem(const Layout: TItemLayout): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to High(Layout.ItemShown) do
    if Layout.ItemShown[Index] then
      Exit(Index);
  Result := -1;
end;

function LastShownItem(const Layout: TItemLayout): LongInt;
var
  Index: LongInt;
begin
  Index := High(Layout.ItemShown);
  while Index >= 0 do
  begin
    if Layout.ItemShown[Index] then
      Exit(Index);
    Dec(Index);
  end;
  Result := -1;
end;

{ The next (Step 1) or previous (Step -1) shown item in order. }
function StepAlong(const Layout: TItemLayout; Index, Step: LongInt): LongInt;
var
  Candidate: LongInt;
begin
  Candidate := Index + Step;
  while (Candidate >= 0) and (Candidate <= High(Layout.ItemShown)) do
  begin
    if Layout.ItemShown[Candidate] then
      Exit(Candidate);
    Candidate := Candidate + Step;
  end;
  Result := Index;
end;

function MiddleX(const Box: TRectangle): LongInt;
begin
  Result := (Box.Left + Box.Right) div 2;
end;

function MiddleY(const Box: TRectangle): LongInt;
begin
  Result := (Box.Top + Box.Bottom) div 2;
end;

{ The nearest item in the next row up (Below False) or down: the row
  closest in that direction, then the item closest across. }
function NearestInNextRow(const Layout: TItemLayout; Index: LongInt; Below: Boolean): LongInt;
var
  Current: TRectangle;
  Candidate: LongInt;
  BestRowTop: LongInt;
  BestDistance: LongInt;
  Box: TRectangle;
  Found: Boolean;
  Distance: LongInt;
begin
  Current := Layout.ItemRects[Index];
  Found := False;
  BestRowTop := 0;
  for Candidate := 0 to High(Layout.ItemRects) do
  begin
    if not Layout.ItemShown[Candidate] then
      Continue;
    Box := Layout.ItemRects[Candidate];
    if Below and (Box.Top > Current.Top) and (not Found or (Box.Top < BestRowTop)) then
    begin
      BestRowTop := Box.Top;
      Found := True;
    end
    else if not Below and (Box.Top < Current.Top) and (not Found or (Box.Top > BestRowTop)) then
    begin
      BestRowTop := Box.Top;
      Found := True;
    end;
  end;
  if not Found then
    Exit(Index);
  Result := Index;
  BestDistance := High(LongInt);
  for Candidate := 0 to High(Layout.ItemRects) do
  begin
    if not Layout.ItemShown[Candidate] or (Layout.ItemRects[Candidate].Top <> BestRowTop) then
      Continue;
    Distance := Abs(MiddleX(Layout.ItemRects[Candidate]) - MiddleX(Current));
    if Distance < BestDistance then
    begin
      BestDistance := Distance;
      Result := Candidate;
    end;
  end;
end;

{ The list: the item in the next column across, at the nearest height. }
function NearestInNextColumn(const Layout: TItemLayout; Index: LongInt; Right: Boolean): LongInt;
var
  Current: TRectangle;
  Candidate: LongInt;
  BestColumnLeft: LongInt;
  BestDistance: LongInt;
  Box: TRectangle;
  Found: Boolean;
  Distance: LongInt;
begin
  Current := Layout.ItemRects[Index];
  Found := False;
  BestColumnLeft := 0;
  for Candidate := 0 to High(Layout.ItemRects) do
  begin
    Box := Layout.ItemRects[Candidate];
    if Right and (Box.Left > Current.Left) and (not Found or (Box.Left < BestColumnLeft)) then
    begin
      BestColumnLeft := Box.Left;
      Found := True;
    end
    else if not Right and (Box.Left < Current.Left) and (not Found or (Box.Left > BestColumnLeft)) then
    begin
      BestColumnLeft := Box.Left;
      Found := True;
    end;
  end;
  if not Found then
    Exit(Index);
  Result := Index;
  BestDistance := High(LongInt);
  for Candidate := 0 to High(Layout.ItemRects) do
  begin
    if Layout.ItemRects[Candidate].Left <> BestColumnLeft then
      Continue;
    Distance := Abs(MiddleY(Layout.ItemRects[Candidate]) - MiddleY(Current));
    if Distance < BestDistance then
    begin
      BestDistance := Distance;
      Result := Candidate;
    end;
  end;
end;

function ItemInDirection(const Layout: TItemLayout; Mode: TItemViewMode; Index: LongInt;
  Direction: TItemDirection): LongInt;
begin
  if (Index < 0) or (Index > High(Layout.ItemShown)) or not Layout.ItemShown[Index] then
    Exit(FirstShownItem(Layout));
  if Mode = ItemViewList then
  begin
    case Direction of
      ItemDirectionUp: Result := StepAlong(Layout, Index, -1);
      ItemDirectionDown: Result := StepAlong(Layout, Index, 1);
      ItemDirectionLeft: Result := NearestInNextColumn(Layout, Index, False);
    else
      Result := NearestInNextColumn(Layout, Index, True);
    end;
    Exit;
  end;
  case Direction of
    ItemDirectionUp: Result := NearestInNextRow(Layout, Index, False);
    ItemDirectionDown: Result := NearestInNextRow(Layout, Index, True);
    ItemDirectionLeft:
      if Mode in [ItemViewDetails, ItemViewContent] then
        Result := Index
      else
        Result := StepAlong(Layout, Index, -1);
  else
    if Mode in [ItemViewDetails, ItemViewContent] then
      Result := Index
    else
      Result := StepAlong(Layout, Index, 1);
  end;
end;

function ItemAPageAway(const Layout: TItemLayout; Index, Distance: LongInt): LongInt;
var
  Target: LongInt;
  Candidate: LongInt;
  Current: TRectangle;
  BestDistance: LongInt;
  Measure: LongInt;
begin
  if (Index < 0) or (Index > High(Layout.ItemShown)) then
    Exit(FirstShownItem(Layout));
  Current := Layout.ItemRects[Index];
  if Layout.Across then
    Target := MiddleX(Current) + Distance
  else
    Target := MiddleY(Current) + Distance;
  Result := Index;
  BestDistance := High(LongInt);
  for Candidate := 0 to High(Layout.ItemRects) do
  begin
    if not Layout.ItemShown[Candidate] then
      Continue;
    if Layout.Across then
      Measure := Abs(MiddleX(Layout.ItemRects[Candidate]) - Target) * 4 +
        Abs(MiddleY(Layout.ItemRects[Candidate]) - MiddleY(Current))
    else
      Measure := Abs(MiddleY(Layout.ItemRects[Candidate]) - Target) * 4 +
        Abs(MiddleX(Layout.ItemRects[Candidate]) - MiddleX(Current));
    if Measure < BestDistance then
    begin
      BestDistance := Measure;
      Result := Candidate;
    end;
  end;
end;

end.
