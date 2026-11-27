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
  Scrollable overflow, kept on the boxes.

  A scroll container's scrollable overflow is the union of its
  descendants' border boxes and line fragments, from its padding box;
  the viewport's makes the document's size. Each box keeps the right and
  bottom edges its descendants reach (DescendantRight, DescendantBottom,
  relative to its border box), so after a layout only the boxes that
  were laid out (bfOverflowDirty) and their ancestors
  (bfChildOverflowDirty) find theirs again, from their children's - as
  Gecko stores overflow areas on each frame and updates them bottom-up
  for the frames reflowed.

  What a child adds: its border box (moved by position: relative; not a
  text box's, its fragments count instead) and, unless it clips its
  overflow, its descendants' extent. Fixed boxes add nothing (they
  scroll with the viewport, not in it). An inline box's descendants are
  placed relative to its containing block, so it passes their extent up
  unmoved. Inline boxes and table row groups, rows and column groups
  are placed by their parent's layout without one of their own, so they
  are looked at again whenever their parent is.
}
unit Web.Layout.Overflow;

{$mode objfpc}
{$H+}

interface

uses
  Web.Layout.Boxes;

{ Brings the descendant extents of the boxes marked since the last time
  up to date, and the scroll sizes of the scroll containers below Root
  (the viewport's own is its owner's to set from Root's extent). }
procedure UpdateScrollableOverflow(Root: TLayoutBox);

implementation

uses
  Math;

const
  { Placed by their parent's layout, which does not lay them out. }
  PlacedWithParentKinds = [bkInline, bkTableRowGroup, bkTableRow, bkTableColumnGroup];

procedure Reach(var Right, Bottom: Single; ToRight, ToBottom: Single); inline;
begin
  if ToRight > Right then
    Right := ToRight;
  if ToBottom > Bottom then
    Bottom := ToBottom;
end;

function NeedsUpdate(Child: TLayoutBox): Boolean; inline;
begin
  Result := ([bfOverflowDirty, bfChildOverflowDirty] * Child.Flags <> []) or (Child.Kind in PlacedWithParentKinds);
end;

{ A scroll container's scrollable overflow from its padding box's
  origin, at least the padding box. }
procedure SetScrollSize(Box: TLayoutBox);
var
  InnerRight, InnerBottom: Single;
begin
  InnerRight := Max(0, Box.DescendantRight - Box.Border[sideLeft]);
  InnerBottom := Max(0, Box.DescendantBottom - Box.Border[sideTop]);
  Box.ScrollWidth := Max(InnerRight + Box.Padding[sideRight], Box.Width - Box.Border[sideLeft] -
    Box.Border[sideRight]);
  Box.ScrollHeight := Max(InnerBottom + Box.Padding[sideBottom], Box.Height - Box.Border[sideTop] -
    Box.Border[sideBottom]);
end;

procedure UpdateBox(Box: TLayoutBox);
var
  Child: TLayoutBox;
  Right, Bottom, ChildX, ChildY: Single;
  Index: Integer;
  Fragment: PLineFragment;
begin
  Right := NoDescendantExtent;
  Bottom := NoDescendantExtent;
  Child := Box.FirstChild;
  while Child <> nil do
  begin
    if NeedsUpdate(Child) then
      UpdateBox(Child);
    if Child.Kind = bkInline then
      Reach(Right, Bottom, Child.DescendantRight, Child.DescendantBottom)
    else if not (bfFixed in Child.Flags) then
    begin
      ChildX := Child.X + Child.RelativeX;
      ChildY := Child.Y + Child.RelativeY;
      if Child.Kind <> bkText then
        Reach(Right, Bottom, ChildX + Child.Width, ChildY + Child.Height);
      if not (bfClipsOverflow in Child.Flags) then
        Reach(Right, Bottom, ChildX + Child.DescendantRight, ChildY + Child.DescendantBottom);
    end;
    if bfScrollContainer in Child.Flags then
      SetScrollSize(Child);
    Child := Child.NextSibling;
  end;
  if Box.Inline <> nil then
    for Index := 0 to Box.Inline.FragmentCount - 1 do
    begin
      Fragment := @Box.Inline.Fragments[Index];
      Reach(Right, Bottom, Fragment^.X + Fragment^.Width, Fragment^.Y + Fragment^.Height);
    end;
  Box.DescendantRight := Right;
  Box.DescendantBottom := Bottom;
  Box.Flags := Box.Flags - [bfOverflowDirty, bfChildOverflowDirty];
end;

procedure UpdateScrollableOverflow(Root: TLayoutBox);
begin
  if NeedsUpdate(Root) then
    UpdateBox(Root);
end;

end.
