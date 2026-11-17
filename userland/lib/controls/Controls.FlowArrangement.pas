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
  Flow arrangement: items one after another in a row (left to right or
  right to left) or a column (top down or bottom up), each with its
  margin kept clear around it. With wrapping, an item that would run
  past the end of the area starts a new line beside the last (below a
  row, right of a column), as deep as that line's deepest item; without
  it, everything stays on one line. The arithmetic of TFlowLayoutPanel,
  in pixels, apart from the controls (checked on the host).
}
unit Controls.FlowArrangement;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles,
  Controls.LayoutRules;

type
  TFlowDirection = (FlowLeftToRight, FlowTopDown, FlowRightToLeft, FlowBottomUp);

  TFlowItem = record
    { The item's own size and the space kept around it. }
    Size: TSize;
    Margin: TSpacing;
  end;
  TFlowItems = array of TFlowItem;
  TRectangles = array of TRectangle;

function MakeFlowItem(Width, Height: LongInt; const Margin: TSpacing): TFlowItem;
{ Where each item goes in Area. }
function ArrangeFlow(const Items: TFlowItems; const Area: TRectangle; Direction: TFlowDirection;
  Wrap: Boolean): TRectangles;
{ The size the items need (margins included): with wrapping, lines are
  broken at WrapExtent along the flow (the area's width for a row). }
function FlowContentSize(const Items: TFlowItems; Direction: TFlowDirection; Wrap: Boolean;
  WrapExtent: LongInt): TSize;

implementation

type
  { An item along the flow (Main) and across it (Cross), margins in. }
  TFlowSpan = record
    MainStart: LongInt;
    CrossStart: LongInt;
  end;
  TFlowSpans = array of TFlowSpan;

function MakeFlowItem(Width, Height: LongInt; const Margin: TSpacing): TFlowItem;
begin
  Result.Size := MakeSize(Width, Height);
  Result.Margin := Margin;
end;

function FlowsInRows(Direction: TFlowDirection): Boolean;
begin
  Result := Direction in [FlowLeftToRight, FlowRightToLeft];
end;

{ The item's outer extent along the flow and across it. }
function MainExtentOf(const Item: TFlowItem; Rows: Boolean): LongInt;
begin
  if Rows then
    Result := Item.Size.cx + SpacingWidth(Item.Margin)
  else
    Result := Item.Size.cy + SpacingHeight(Item.Margin);
end;

function CrossExtentOf(const Item: TFlowItem; Rows: Boolean): LongInt;
begin
  if Rows then
    Result := Item.Size.cy + SpacingHeight(Item.Margin)
  else
    Result := Item.Size.cx + SpacingWidth(Item.Margin);
end;

{ Lays the items out from 0 along both axes; the extent used along the
  flow (longest line) and across it (all lines). }
function FlowSpans(const Items: TFlowItems; Rows, Wrap: Boolean; MainLimit: LongInt; out UsedMain,
  UsedCross: LongInt): TFlowSpans;
var
  Index: LongInt;
  Main: LongInt;
  Cross: LongInt;
  LineDepth: LongInt;
  ItemMain: LongInt;
begin
  Result := nil;
  SetLength(Result, Length(Items));
  Main := 0;
  Cross := 0;
  LineDepth := 0;
  UsedMain := 0;
  for Index := 0 to High(Items) do
  begin
    ItemMain := MainExtentOf(Items[Index], Rows);
    if Wrap and (Main > 0) and (Main + ItemMain > MainLimit) then
    begin
      Cross := Cross + LineDepth;
      Main := 0;
      LineDepth := 0;
    end;
    Result[Index].MainStart := Main;
    Result[Index].CrossStart := Cross;
    Main := Main + ItemMain;
    if Main > UsedMain then
      UsedMain := Main;
    if CrossExtentOf(Items[Index], Rows) > LineDepth then
      LineDepth := CrossExtentOf(Items[Index], Rows);
  end;
  UsedCross := Cross + LineDepth;
end;

function ArrangeFlow(const Items: TFlowItems; const Area: TRectangle; Direction: TFlowDirection;
  Wrap: Boolean): TRectangles;
var
  Rows: Boolean;
  Spans: TFlowSpans;
  UsedMain: LongInt;
  UsedCross: LongInt;
  Index: LongInt;
  Item: TFlowItem;
  Left: LongInt;
  Top: LongInt;
begin
  Rows := FlowsInRows(Direction);
  if Rows then
    Spans := FlowSpans(Items, True, Wrap, RectangleWidth(Area), UsedMain, UsedCross)
  else
    Spans := FlowSpans(Items, False, Wrap, RectangleHeight(Area), UsedMain, UsedCross);
  Result := nil;
  SetLength(Result, Length(Items));
  for Index := 0 to High(Items) do
  begin
    Item := Items[Index];
    case Direction of
      FlowLeftToRight:
        begin
          Left := Area.Left + Spans[Index].MainStart + Item.Margin.Left;
          Top := Area.Top + Spans[Index].CrossStart + Item.Margin.Top;
        end;
      FlowRightToLeft:
        begin
          Left := Area.Right - Spans[Index].MainStart - Item.Margin.Right - Item.Size.cx;
          Top := Area.Top + Spans[Index].CrossStart + Item.Margin.Top;
        end;
      FlowTopDown:
        begin
          Left := Area.Left + Spans[Index].CrossStart + Item.Margin.Left;
          Top := Area.Top + Spans[Index].MainStart + Item.Margin.Top;
        end;
    else
      begin
        Left := Area.Left + Spans[Index].CrossStart + Item.Margin.Left;
        Top := Area.Bottom - Spans[Index].MainStart - Item.Margin.Bottom - Item.Size.cy;
      end;
    end;
    Result[Index] := MakeRectangle(Left, Top, Item.Size.cx, Item.Size.cy);
  end;
end;

function FlowContentSize(const Items: TFlowItems; Direction: TFlowDirection; Wrap: Boolean;
  WrapExtent: LongInt): TSize;
var
  UsedMain: LongInt;
  UsedCross: LongInt;
begin
  FlowSpans(Items, FlowsInRows(Direction), Wrap, WrapExtent, UsedMain, UsedCross);
  if FlowsInRows(Direction) then
    Result := MakeSize(UsedMain, UsedCross)
  else
    Result := MakeSize(UsedCross, UsedMain);
end;

end.
