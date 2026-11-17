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
  Flow layout panels: children one after another, in a row or a column,
  without positions of their own.

  The children go in the order they were made, each at its own size
  (PreferredSize if AutoSize) with its Margins kept clear around it:
  left to right, top down, right to left or bottom up (FlowDirection).
  With WrapContents (the default) a child that would run past the edge
  starts a new row (or column); without it they all stay on one. With
  AutoSize the panel takes the size its children need (as wide as it is
  when it wraps, so its rows decide its height). Its Bounds, Align and
  Anchors are a child's own business in its parent; inside a flow panel
  only their sizes count. A flow panel does not scroll itself: to scroll
  one, give it AutoSize and put it in a panel with AutoScroll.
}
unit Controls.FlowPanel;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Drawing.Rectangles,
  Controls.Base,
  Controls.Panels,
  Controls.FlowArrangement;

type
  TFlowLayoutPanel = class(TPanel)
  private
    FFlowDirection: TFlowDirection;
    FWrapContents: Boolean;
    procedure SetFlowDirection(Value: TFlowDirection);
    procedure SetWrapContents(Value: Boolean);
    { The children that flow, and their sizes and margins: pixels, or
      logical units. }
    function FlowingChildren: TList;
    function FlowItems(Flowing: TList; InPixels: Boolean): TFlowItems;
    function ExtentToWrapAt: LongInt;
  protected
    procedure PlaceChildren(const Area: TRectangle); override;
    procedure PlaceOneChild(Child: TControl); override;
    procedure Layout; override;
  public
    constructor Create(AParent: TControl); override;
    function PreferredSize: TSize; override;
    property FlowDirection: TFlowDirection read FFlowDirection write SetFlowDirection;
    property WrapContents: Boolean read FWrapContents write SetWrapContents;
  end;

implementation

uses
  Windowing.Connection,
  Controls.LayoutRules;

constructor TFlowLayoutPanel.Create(AParent: TControl);
begin
  inherited Create(AParent);
  FWrapContents := True;
end;

procedure TFlowLayoutPanel.SetFlowDirection(Value: TFlowDirection);
begin
  if FFlowDirection = Value then
    Exit;
  FFlowDirection := Value;
  RequestLayout;
end;

procedure TFlowLayoutPanel.SetWrapContents(Value: Boolean);
begin
  if FWrapContents = Value then
    Exit;
  FWrapContents := Value;
  RequestLayout;
end;

function TFlowLayoutPanel.FlowingChildren: TList;
var
  Index: LongInt;
begin
  Result := TList.Create;
  for Index := 0 to ChildCount - 1 do
    if Children[Index].Visible and CountsInExtent(Children[Index]) then
      Result.Add(Children[Index]);
end;

function TFlowLayoutPanel.FlowItems(Flowing: TList; InPixels: Boolean): TFlowItems;
var
  Index: LongInt;
  Child: TControl;
  Size: TSize;
begin
  Result := nil;
  SetLength(Result, Flowing.Count);
  for Index := 0 to Flowing.Count - 1 do
  begin
    Child := TControl(Flowing[Index]);
    Size := ChildSize(Child);
    if InPixels then
      Result[Index] := MakeFlowItem(Scaled(Size.cx), Scaled(Size.cy), Child.ScaledMargin)
    else
      Result[Index] := MakeFlowItem(Size.cx, Size.cy, Child.Margins);
  end;
end;

procedure TFlowLayoutPanel.PlaceChildren(const Area: TRectangle);
var
  Flowing: TList;
  Places: TRectangles;
  Index: LongInt;
begin
  for Index := 0 to ChildCount - 1 do
    if not Children[Index].Visible then
      PlaceChild(Children[Index], MakeRectangle(Area.Left, Area.Top, 0, 0));
  Flowing := FlowingChildren;
  try
    Places := ArrangeFlow(FlowItems(Flowing, True), Area, FFlowDirection, FWrapContents);
    for Index := 0 to Flowing.Count - 1 do
      PlaceChild(TControl(Flowing[Index]), Places[Index]);
  finally
    Flowing.Free;
  end;
end;

procedure TFlowLayoutPanel.PlaceOneChild(Child: TControl);
begin
  PlaceChildren(ClientPixelArea);
end;

{ The extent it has across the flow (logical units): what docking gave
  it if it is docked along that way, else its Bounds'. }
function TFlowLayoutPanel.ExtentToWrapAt: LongInt;
var
  Rows: Boolean;
begin
  Rows := FFlowDirection in [FlowLeftToRight, FlowRightToLeft];
  if Rows and (Align in [AlignTop, AlignBottom, AlignClient]) then
    Result := Unscaled(RectangleWidth(PixelBounds))
  else if not Rows and (Align in [AlignLeft, AlignRight, AlignClient]) then
    Result := Unscaled(RectangleHeight(PixelBounds))
  else if Rows then
    Result := RectangleWidth(Bounds)
  else
    Result := RectangleHeight(Bounds);
end;

function TFlowLayoutPanel.PreferredSize: TSize;
var
  Flowing: TList;
  Extent: LongInt;
  WrapExtent: LongInt;
begin
  { Rows wrap at the width it has, columns at its height. }
  Extent := ExtentToWrapAt;
  if FFlowDirection in [FlowLeftToRight, FlowRightToLeft] then
    WrapExtent := Extent - SpacingWidth(ContentPadding)
  else
    WrapExtent := Extent - SpacingHeight(ContentPadding);
  if (WrapExtent <= 0) or not FWrapContents then
    WrapExtent := High(LongInt) div 2;
  Flowing := FlowingChildren;
  try
    Result := FlowContentSize(FlowItems(Flowing, False), FFlowDirection, FWrapContents, WrapExtent);
  finally
    Flowing.Free;
  end;
  Result := MakeSize(Result.cx + SpacingWidth(ContentPadding), Result.cy + SpacingHeight(ContentPadding));
  { Wrapping rows keep the width they have (and columns their height). }
  if FWrapContents and (Extent > 0) and (FFlowDirection in [FlowLeftToRight, FlowRightToLeft]) then
    Result.cx := Extent
  else if FWrapContents and (Extent > 0) and (FFlowDirection in [FlowTopDown, FlowBottomUp]) then
    Result.cy := Extent;
end;

{ Docked and sized to its content, its depth follows its width: when that
  changed what its rows need, its parent places it again. }
procedure TFlowLayoutPanel.Layout;
var
  Wanted: TSize;
begin
  inherited Layout;
  if not AutoSize or (Parent = nil) or not FWrapContents or (Align = AlignNone) then
    Exit;
  Wanted := ConstrainSize(PreferredSize, Constraints);
  if (Wanted.cx <> RectangleWidth(Bounds)) or (Wanted.cy <> RectangleHeight(Bounds)) then
    Parent.RequestLayout;
end;

end.
