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
  Split containers: two panels with a splitter between them, side by
  side (SplitVertical: the bar is upright) or one above the other
  (SplitHorizontal).

  Panel1 and Panel2 hold the program's controls. SplitterDistance is
  Panel1's extent along the split (logical units), kept so that each
  panel has at least its minimum (Panel1MinSize, Panel2MinSize; the
  first wins if there is not room for both). When the container is
  resized the fixed panel keeps its extent (FixedPanel; with none fixed
  the splitter keeps its share of the whole). The splitter is dragged
  with the mouse, or takes the focus (Tab) and moves with the arrow
  keys; OnSplitterMoved tells when it was moved. Built from docking: a
  panel docked to the left (or top), a TSplitter after it, the other
  panel filling the rest. Panel2Collapsed hides the second panel and the
  splitter, the first filling the container, until it is shown again
  with the extents it had (a fixed panel's kept).
}
unit Controls.SplitContainer;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Messages,
  Controls.Base,
  Controls.Panels,
  Controls.Splitter,
  Controls.SplitRules;

type
  TSplitOrientation = (SplitVertical, SplitHorizontal);

  TSplitContainer = class(TControl)
  private
    FPanel1: TPanel;
    FPanel2: TPanel;
    FSplitter: TSplitter;
    FOrientation: TSplitOrientation;
    FFixedPanel: TFixedPanel;
    FPanel1MinSize: LongInt;
    FPanel2MinSize: LongInt;
    { Logical units along the split at the last layout (-1: none yet). }
    FLastTotal: LongInt;
    FOnSplitterMoved: TControlEvent;
    FPanel2Collapsed: Boolean;
    procedure SetPanel2Collapsed(Value: Boolean);
    function DockedPanel1Align: TAlign;
    procedure SetOrientation(Value: TSplitOrientation);
    procedure SetPanel1MinSize(Value: LongInt);
    procedure SetPanel2MinSize(Value: LongInt);
    function GetSplitterDistance: LongInt;
    procedure SetSplitterDistance(Value: LongInt);
    { Logical units the container has along the split. }
    function TotalExtent: LongInt;
    procedure AssignPanel1Extent(Extent: LongInt);
  protected
    procedure Layout; override;
  public
    constructor Create(AParent: TControl); override;
    { Its splitter's notifications are its own (OnSplitterMoved). }
    procedure ReceiveMessage(var Message: TPostedMessage); override;
    { Both panels' preferred sizes, side by side (or one above the
      other), and the splitter. }
    function PreferredSize: TSize; override;
    property Panel1: TPanel read FPanel1;
    property Panel2: TPanel read FPanel2;
    property Splitter: TSplitter read FSplitter;
    property Orientation: TSplitOrientation read FOrientation write SetOrientation;
    property SplitterDistance: LongInt read GetSplitterDistance write SetSplitterDistance;
    property FixedPanel: TFixedPanel read FFixedPanel write FFixedPanel;
    property Panel1MinSize: LongInt read FPanel1MinSize write SetPanel1MinSize;
    property Panel2MinSize: LongInt read FPanel2MinSize write SetPanel2MinSize;
    property OnSplitterMoved: TControlEvent read FOnSplitterMoved write FOnSplitterMoved;
    { Panel2 and the splitter hidden, Panel1 filling the container. }
    property Panel2Collapsed: Boolean read FPanel2Collapsed write SetPanel2Collapsed;
  end;

implementation

uses
  Drawing.Rectangles,
  Windowing.Connection,
  Controls.LayoutRules;

const
  { Logical units. }
  DefaultPanelMinSize = 25;
  DefaultSplitterDistance = 100;

constructor TSplitContainer.Create(AParent: TControl);
begin
  inherited Create(AParent);
  FLastTotal := -1;
  FPanel1MinSize := DefaultPanelMinSize;
  FPanel2MinSize := DefaultPanelMinSize;
  FPanel1 := TPanel.Create(Self);
  FPanel1.SetBounds(0, 0, DefaultSplitterDistance, DefaultSplitterDistance);
  FPanel1.Align := AlignLeft;
  FSplitter := TSplitter.Create(Self);
  FSplitter.Pane := FPanel1;
  FSplitter.KeyboardMovable := True;
  FSplitter.MinimumWidth := FPanel1MinSize;
  FSplitter.MinimumRest := FPanel2MinSize;
  FPanel2 := TPanel.Create(Self);
  FPanel2.Align := AlignClient;
end;

procedure TSplitContainer.SetOrientation(Value: TSplitOrientation);
var
  Distance: LongInt;
begin
  if FOrientation = Value then
    Exit;
  Distance := SplitterDistance;
  FOrientation := Value;
  FSplitter.Align := DockedPanel1Align;
  if not FPanel2Collapsed then
    FPanel1.Align := DockedPanel1Align;
  FLastTotal := -1;
  AssignPanel1Extent(Distance);
  RequestLayout;
end;

function TSplitContainer.DockedPanel1Align: TAlign;
begin
  if FOrientation = SplitVertical then
    Result := AlignLeft
  else
    Result := AlignTop;
end;

procedure TSplitContainer.SetPanel2Collapsed(Value: Boolean);
begin
  if FPanel2Collapsed = Value then
    Exit;
  FPanel2Collapsed := Value;
  FPanel2.Visible := not Value;
  FSplitter.Visible := not Value;
  if Value then
    FPanel1.Align := AlignClient
  else
    FPanel1.Align := DockedPanel1Align;
  RequestLayout;
  Invalidate;
end;

procedure TSplitContainer.SetPanel1MinSize(Value: LongInt);
begin
  FPanel1MinSize := Value;
  FSplitter.MinimumWidth := Value;
  RequestLayout;
end;

procedure TSplitContainer.SetPanel2MinSize(Value: LongInt);
begin
  FPanel2MinSize := Value;
  FSplitter.MinimumRest := Value;
  RequestLayout;
end;

function TSplitContainer.GetSplitterDistance: LongInt;
begin
  Result := FSplitter.PaneExtent;
end;

procedure TSplitContainer.AssignPanel1Extent(Extent: LongInt);
begin
  if FOrientation = SplitVertical then
    FPanel1.AssignBounds(0, 0, Extent, RectangleHeight(FPanel1.Bounds))
  else
    FPanel1.AssignBounds(0, 0, RectangleWidth(FPanel1.Bounds), Extent);
end;

procedure TSplitContainer.SetSplitterDistance(Value: LongInt);
var
  Total: LongInt;
begin
  Total := TotalExtent;
  if Total > 0 then
    Value := ClampSplitDistance(Value, Total, SplitterThickness, FPanel1MinSize, FPanel2MinSize);
  AssignPanel1Extent(Value);
  RequestLayout;
end;

function TSplitContainer.TotalExtent: LongInt;
var
  Area: TRectangle;
begin
  Area := ClientPixelArea;
  if FOrientation = SplitVertical then
    Result := Unscaled(RectangleWidth(Area))
  else
    Result := Unscaled(RectangleHeight(Area));
end;

{ The fixed panel keeps its extent as the container resizes; the
  distance always within both minimums. }
procedure TSplitContainer.Layout;
var
  Total: LongInt;
  Distance: LongInt;
begin
  Total := TotalExtent;
  { Collapsed: the extents wait, as they were, for the panel to come back
    (the last total kept, so a fixed panel keeps its extent). }
  if (Total > 0) and not FPanel2Collapsed then
  begin
    Distance := GetSplitterDistance;
    if (FLastTotal > 0) and (Total <> FLastTotal) then
      Distance := ResizedSplitDistance(FFixedPanel, Distance, FLastTotal, Total, SplitterThickness);
    Distance := ClampSplitDistance(Distance, Total, SplitterThickness, FPanel1MinSize, FPanel2MinSize);
    if Distance <> GetSplitterDistance then
      AssignPanel1Extent(Distance);
    FLastTotal := Total;
  end;
  inherited Layout;
end;

procedure TSplitContainer.ReceiveMessage(var Message: TPostedMessage);
begin
  if (Message.Code = MessageNotify) and (TControl(Message.Parameter1) = FSplitter) then
  begin
    if (Message.Parameter2 = NotifyChanged) and Assigned(FOnSplitterMoved) then
      FOnSplitterMoved(Self);
    Exit;
  end;
  inherited ReceiveMessage(Message);
end;

function TSplitContainer.PreferredSize: TSize;
var
  First: TSize;
  Second: TSize;
begin
  First := FPanel1.PreferredSize;
  if FPanel2Collapsed then
    Exit(First);
  Second := FPanel2.PreferredSize;
  if FOrientation = SplitVertical then
  begin
    if First.cx < FPanel1MinSize then
      First.cx := FPanel1MinSize;
    if Second.cx < FPanel2MinSize then
      Second.cx := FPanel2MinSize;
    Result := MakeSize(First.cx + SplitterThickness + Second.cx, First.cy);
    if Second.cy > Result.cy then
      Result.cy := Second.cy;
  end
  else
  begin
    if First.cy < FPanel1MinSize then
      First.cy := FPanel1MinSize;
    if Second.cy < FPanel2MinSize then
      Second.cy := FPanel2MinSize;
    Result := MakeSize(First.cx, First.cy + SplitterThickness + Second.cy);
    if Second.cx > Result.cx then
      Result.cx := Second.cx;
  end;
  Result := MakeSize(Result.cx + SpacingWidth(ContentPadding), Result.cy + SpacingHeight(ContentPadding));
end;

end.
