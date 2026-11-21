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
  Tree views: nodes in a hierarchy, each shown as a line indented by
  its depth, with a box to expand or collapse those that have children.

  The visible lines are the nodes whose parents are all expanded. The
  up and down arrows, Page Up and Down, Home and End move the choice;
  Right expands the chosen node (or goes to its first child), Left
  collapses it (or goes to its parent); a click on a box, a double
  click or Enter toggles. A new choice is announced (OnChange,
  NotifyChanged); expanding or collapsing as OnExpandChanged.

  Dotted lines (ShowLines) join each node to its parent and to its
  siblings above and below: a line runs down a level's column for as
  long as the level has more nodes to come, and across to each node's
  text. They are drawn a row at a time, with a dot pattern fixed to the
  window's pixels, so the pieces meet without a seam; their thickness
  follows the display's scale.

  A node may have a small picture before its text: one of the tree's
  image list (Images, ImageIndex), or a stock icon (SetIcon). Nodes
  can be taken away again (DeleteNode, DeleteChildren); a chosen node
  taken away leaves the choice to its parent. NodeAt tells which node
  is at a point (for a context menu, or a drop), and DropTarget shows
  the node a drag would drop on.
}
unit Controls.TreeView;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Drawing.Rectangles,
  Drawing.Canvas,
  Windowing.Messages,
  Controls.Base,
  Controls.Icons,
  Controls.ImageList,
  Controls.ScrollBar;

type
  TTreeView = class;

  TTreeNode = class
  private
    FText: string;
    FParent: TTreeNode;
    FChildren: TList;
    FExpanded: Boolean;
    FData: Pointer;
    FTree: TTreeView;
    FHasIcon: Boolean;
    FIconKind: TStockIcon;
    FImageIndex: LongInt;
    FMayHaveChildren: Boolean;
    function GetHasIcon: Boolean;
    procedure SetImageIndex(Value: LongInt);
    function GetChild(Index: LongInt): TTreeNode;
    function GetCount: LongInt;
    procedure SetExpanded(Value: Boolean);
    procedure SetText(const Value: string);
  public
    constructor Create(ATree: TTreeView; AParent: TTreeNode; const AText: string);
    destructor Destroy; override;
    function Add(const AText: string): TTreeNode;
    { A child at Position among the others (at the end if past them). }
    function Insert(Position: LongInt; const AText: string): TTreeNode;
    function Depth: LongInt;
    { Whether another node follows it under the same parent. }
    function HasNextSibling: Boolean;
    { Shows the stock icon Kind before the text. }
    procedure SetIcon(Kind: TStockIcon);
    { Whether Node is this node or one below it. }
    function Contains(Node: TTreeNode): Boolean;
    { Whether it has a box to open it: children, or MayHaveChildren. }
    function ShowsToggle: Boolean;
    property Text: string read FText write SetText;
    property Parent: TTreeNode read FParent;
    property Count: LongInt read GetCount;
    property Children[Index: LongInt]: TTreeNode read GetChild; default;
    property Expanded: Boolean read FExpanded write SetExpanded;
    property Data: Pointer read FData write FData;
    { Shows the box before any children are added, for children made
      when it is first opened (OnExpandChanged): a folder's subfolders. }
    property MayHaveChildren: Boolean read FMayHaveChildren write FMayHaveChildren;
    { A picture shows before the text (of the image list or a stock icon). }
    property HasIcon: Boolean read GetHasIcon;
    property IconKind: TStockIcon read FIconKind;
    { Its picture in the tree's Images (-1, the default: none). }
    property ImageIndex: LongInt read FImageIndex write SetImageIndex;
  end;

  TTreeNodeEvent = procedure(Sender: TTreeView; Node: TTreeNode) of object;

  TTreeView = class(TControl)
  private
    FRoots: TTreeNode;
    FVisible: TList;
    FSelected: TTreeNode;
    FTopIndex: LongInt;
    FScrollBar: TScrollBar;
    FLastClickTime: QWord;
    FLastClickNode: TTreeNode;
    FShowLines: Boolean;
    FDropTarget: TTreeNode;
    FImages: TImageList;
    FOnExpandChanged: TTreeNodeEvent;
    procedure SetImages(Value: TImageList);
    procedure SetDropTarget(Value: TTreeNode);
    procedure Rebuild;
    procedure AddVisible(Node: TTreeNode);
    function RowHeight: LongInt;
    function VisibleRows: LongInt;
    function BoxRectangleLeft(Node: TTreeNode): LongInt;
    function LevelLineX(Depth: LongInt): LongInt;
    procedure PaintLines(const Canvas: TCanvas; Node: TTreeNode; Top: LongInt);
    procedure SetShowLines(Value: Boolean);
    procedure SetSelected(Value: TTreeNode);
    procedure SetTopIndex(Value: LongInt);
    procedure UpdateScrollBar;
    procedure EnsureVisible(Index: LongInt);
    procedure NodeChanged;
    procedure ExpandChanged(Node: TTreeNode);
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    procedure Wheel(Steps: LongInt); override;
    function KeyDown(Code, Character, Modifiers: LongWord): Boolean; override;
    procedure Layout; override;
  public
    constructor Create(AParent: TControl); override;
    function KeyboardContextPoint: TPoint; override;
    destructor Destroy; override;
    procedure ReceiveMessage(var Message: TPostedMessage); override;
    { A node at the top level. }
    function AddRoot(const AText: string): TTreeNode;
    { A node at the top level at Position among the others. }
    function InsertRoot(Position: LongInt; const AText: string): TTreeNode;
    procedure Clear;
    { Takes Node (and the nodes below it) out of the tree and frees it. }
    procedure DeleteNode(Node: TTreeNode);
    procedure DeleteChildren(Node: TTreeNode);
    { Where Node's text starts (this control's pixels). }
    function NodeTextLeft(Node: TTreeNode): LongInt;
    { The node on the line at (X, Y) of this control's pixels, or nil. }
    function NodeAt(X, Y: LongInt): TTreeNode;
    { The node shown on line Index (counting what is visible). }
    function VisibleNode(Index: LongInt): TTreeNode;
    function VisibleCount: LongInt;
    { The middle of visible line Index (as scrolled now), in this
      control's pixels. }
    function RowMiddle(Index: LongInt): LongInt;
    property Selected: TTreeNode read FSelected write SetSelected;
    property ShowLines: Boolean read FShowLines write SetShowLines;
    { The node shown as where a drop would go (nil: none). }
    property DropTarget: TTreeNode read FDropTarget write SetDropTarget;
    { The pictures nodes show by ImageIndex (shared: the tree does not
      own it). }
    property Images: TImageList read FImages write SetImages;
    property OnExpandChanged: TTreeNodeEvent read FOnExpandChanged write FOnExpandChanged;
  end;

implementation

uses
  Abi.SystemCalls,
  Sys.Time,
  Drawing.Shapes,
  Drawing.Bevels,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Keys,
  Controls.Text,
  Controls.ListBox,
  Controls.Painting;

const
  IndentStep = 16;
  BoxSize = 9;

{ --- TTreeNode ---------------------------------------------------------------- }

constructor TTreeNode.Create(ATree: TTreeView; AParent: TTreeNode; const AText: string);
begin
  inherited Create;
  FTree := ATree;
  FParent := AParent;
  FText := AText;
  FChildren := TList.Create;
  FImageIndex := -1;
end;

destructor TTreeNode.Destroy;
var
  Index: LongInt;
begin
  for Index := 0 to FChildren.Count - 1 do
    TTreeNode(FChildren[Index]).Free;
  FChildren.Free;
  inherited Destroy;
end;

function TTreeNode.GetChild(Index: LongInt): TTreeNode;
begin
  Result := TTreeNode(FChildren[Index]);
end;

function TTreeNode.ShowsToggle: Boolean;
begin
  Result := (FChildren.Count > 0) or FMayHaveChildren;
end;

function TTreeNode.GetCount: LongInt;
begin
  Result := FChildren.Count;
end;

function TTreeNode.Add(const AText: string): TTreeNode;
begin
  Result := TTreeNode.Create(FTree, Self, AText);
  FChildren.Add(Result);
  if FTree <> nil then
    FTree.NodeChanged;
end;

function TTreeNode.Insert(Position: LongInt; const AText: string): TTreeNode;
begin
  if (Position < 0) or (Position > FChildren.Count) then
    Position := FChildren.Count;
  Result := TTreeNode.Create(FTree, Self, AText);
  FChildren.Insert(Position, Result);
  if FTree <> nil then
    FTree.NodeChanged;
end;

function TTreeNode.Depth: LongInt;
var
  Node: TTreeNode;
begin
  Result := -1;
  Node := FParent;
  while Node <> nil do
  begin
    Inc(Result);
    Node := Node.FParent;
  end;
end;

function TTreeNode.HasNextSibling: Boolean;
begin
  Result := (FParent <> nil) and (FParent.FChildren.IndexOf(Self) < FParent.FChildren.Count - 1);
end;

procedure TTreeNode.SetIcon(Kind: TStockIcon);
begin
  FHasIcon := True;
  FIconKind := Kind;
  if FTree <> nil then
    FTree.Invalidate;
end;

function TTreeNode.GetHasIcon: Boolean;
begin
  Result := FHasIcon or ((FTree <> nil) and (FTree.FImages <> nil) and FTree.FImages.ValidIndex(FImageIndex));
end;

procedure TTreeNode.SetImageIndex(Value: LongInt);
begin
  FImageIndex := Value;
  if FTree <> nil then
    FTree.Invalidate;
end;

function TTreeNode.Contains(Node: TTreeNode): Boolean;
begin
  while Node <> nil do
  begin
    if Node = Self then
      Exit(True);
    Node := Node.FParent;
  end;
  Result := False;
end;

procedure TTreeNode.SetExpanded(Value: Boolean);
begin
  if FExpanded = Value then
    Exit;
  FExpanded := Value;
  if FTree <> nil then
    FTree.ExpandChanged(Self);
end;

procedure TTreeNode.SetText(const Value: string);
begin
  FText := Value;
  if FTree <> nil then
    FTree.Invalidate;
end;

{ --- TTreeView ------------------------------------------------------------------ }

constructor TTreeView.Create(AParent: TControl);
begin
  inherited Create(AParent);
  CanFocus := True;
  FRoots := TTreeNode.Create(Self, nil, '');
  FRoots.FExpanded := True;
  FShowLines := True;
  FVisible := TList.Create;
  FScrollBar := TScrollBar.Create(Self);
  FScrollBar.Visible := False;
end;

destructor TTreeView.Destroy;
begin
  FRoots.FTree := nil;
  FRoots.Free;
  FVisible.Free;
  inherited Destroy;
end;

function TTreeView.AddRoot(const AText: string): TTreeNode;
begin
  Result := FRoots.Add(AText);
end;

function TTreeView.InsertRoot(Position: LongInt; const AText: string): TTreeNode;
begin
  Result := FRoots.Insert(Position, AText);
end;

procedure TTreeView.Clear;
begin
  FRoots.FTree := nil;
  FRoots.Free;
  FRoots := TTreeNode.Create(Self, nil, '');
  FRoots.FExpanded := True;
  FSelected := nil;
  FDropTarget := nil;
  FLastClickNode := nil;
  NodeChanged;
end;

procedure TTreeView.DeleteNode(Node: TTreeNode);
var
  SelectionGoes: Boolean;
begin
  if (Node = nil) or (Node = FRoots) or (Node.FParent = nil) then
    Exit;
  SelectionGoes := Node.Contains(FSelected);
  if SelectionGoes then
  begin
    FSelected := Node.FParent;
    if FSelected = FRoots then
      FSelected := nil;
  end;
  if Node.Contains(FDropTarget) then
    FDropTarget := nil;
  if Node.Contains(FLastClickNode) then
    FLastClickNode := nil;
  Node.FParent.FChildren.Remove(Node);
  Node.Free;
  Rebuild;
  if SelectionGoes then
    Changed;
end;

procedure TTreeView.DeleteChildren(Node: TTreeNode);
begin
  while Node.Count > 0 do
    DeleteNode(Node[Node.Count - 1]);
end;

function TTreeView.NodeAt(X, Y: LongInt): TTreeNode;
begin
  if (Y < BevelWidth) or (X < 0) or (X >= RectangleWidth(PixelBounds)) then
    Exit(nil);
  Result := VisibleNode(FTopIndex + (Y - BevelWidth) div RowHeight);
end;

procedure TTreeView.SetImages(Value: TImageList);
begin
  FImages := Value;
  Invalidate;
end;

procedure TTreeView.SetDropTarget(Value: TTreeNode);
begin
  if Value = FDropTarget then
    Exit;
  FDropTarget := Value;
  Invalidate;
end;

{ Where Node's text starts: after its box, and its icon if it has one. }
function TTreeView.NodeTextLeft(Node: TTreeNode): LongInt;
begin
  Result := BoxRectangleLeft(Node) + Scaled(BoxSize) + Scaled(5);
  if Node.HasIcon then
    Result := Result + Scaled(SmallIconSize + 3);
end;

function TTreeView.KeyboardContextPoint: TPoint;
var
  Index: LongInt;
begin
  Index := FVisible.IndexOf(FSelected);
  if Index < 0 then
    Exit(inherited KeyboardContextPoint);
  EnsureVisible(Index);
  Result := MakePoint(NodeTextLeft(FSelected) + Scaled(8), RowMiddle(Index));
end;

procedure TTreeView.AddVisible(Node: TTreeNode);
var
  Index: LongInt;
begin
  for Index := 0 to Node.Count - 1 do
  begin
    FVisible.Add(Node[Index]);
    if Node[Index].Expanded then
      AddVisible(Node[Index]);
  end;
end;

procedure TTreeView.Rebuild;
begin
  FVisible.Clear;
  AddVisible(FRoots);
  if (FSelected <> nil) and (FVisible.IndexOf(FSelected) < 0) then
  begin
    { The choice was hidden: its nearest visible ancestor takes it. }
    while (FSelected <> nil) and (FVisible.IndexOf(FSelected) < 0) do
      FSelected := FSelected.Parent;
    if FSelected = FRoots then
      FSelected := nil;
    Changed;
  end;
  SetTopIndex(FTopIndex);
  UpdateScrollBar;
  Invalidate;
end;

procedure TTreeView.NodeChanged;
begin
  Rebuild;
end;

procedure TTreeView.ExpandChanged(Node: TTreeNode);
begin
  Rebuild;
  if Assigned(FOnExpandChanged) then
    FOnExpandChanged(Self, Node);
end;

function TTreeView.VisibleNode(Index: LongInt): TTreeNode;
begin
  if (Index < 0) or (Index >= FVisible.Count) then
    Exit(nil);
  Result := TTreeNode(FVisible[Index]);
end;

function TTreeView.VisibleCount: LongInt;
begin
  Result := FVisible.Count;
end;

function TTreeView.RowMiddle(Index: LongInt): LongInt;
begin
  Result := BevelWidth + (Index - FTopIndex) * RowHeight + RowHeight div 2;
end;

function TTreeView.RowHeight: LongInt;
begin
  Result := TextHeight(ControlFace) + Scaled(2);
  if Result < 1 then
    Result := 1;
end;

function TTreeView.VisibleRows: LongInt;
begin
  Result := (RectangleHeight(PixelBounds) - 2 * BevelWidth) div RowHeight;
  if Result < 1 then
    Result := 1;
end;

function TTreeView.BoxRectangleLeft(Node: TTreeNode): LongInt;
begin
  Result := Scaled(4 + Node.Depth * IndentStep);
end;

{ The column a level's line runs down: through the middle of its boxes. }
function TTreeView.LevelLineX(Depth: LongInt): LongInt;
begin
  Result := Scaled(4 + Depth * IndentStep) + Scaled(BoxSize) div 2;
end;

procedure TTreeView.SetShowLines(Value: Boolean);
begin
  if Value = FShowLines then
    Exit;
  FShowLines := Value;
  Invalidate;
end;

{ The lines on Node's row (Top its top): across to its text, up to the
  node before it, down to the next sibling, and down the columns of the
  ancestors that have more nodes to come. }
procedure TTreeView.PaintLines(const Canvas: TCanvas; Node: TTreeNode; Top: LongInt);
var
  Thickness: LongInt;
  Middle: LongInt;
  Bottom: LongInt;
  X: LongInt;
  Ancestor: TTreeNode;
  TextLeft: LongInt;
begin
  Thickness := Scaled(1);
  if Thickness < 1 then
    Thickness := 1;
  Middle := Top + RowHeight div 2;
  Bottom := Top + RowHeight;
  X := LevelLineX(Node.Depth);
  TextLeft := BoxRectangleLeft(Node) + Scaled(BoxSize) + Scaled(3);
  DrawDottedHorizontalLine(Canvas, X, TextLeft, Middle, Thickness, Theme.Shadow);
  { Up to the sibling or parent above; the very first node has neither. }
  if (Node.Parent <> FRoots) or (FRoots[0] <> Node) then
    DrawDottedVerticalLine(Canvas, X, Top, Middle, Thickness, Theme.Shadow);
  if Node.HasNextSibling then
    DrawDottedVerticalLine(Canvas, X, Middle, Bottom, Thickness, Theme.Shadow);
  Ancestor := Node.Parent;
  while (Ancestor <> nil) and (Ancestor <> FRoots) do
  begin
    if Ancestor.HasNextSibling then
      DrawDottedVerticalLine(Canvas, LevelLineX(Ancestor.Depth), Top, Bottom, Thickness, Theme.Shadow);
    Ancestor := Ancestor.Parent;
  end;
end;

procedure TTreeView.Layout;
var
  Width: LongInt;
begin
  Width := Scaled(Theme.ScrollBarWidth);
  FScrollBar.AssignBounds(Unscaled(RectangleWidth(PixelBounds) - BevelWidth - Width), Unscaled(BevelWidth), Unscaled(Width),
    Unscaled(RectangleHeight(PixelBounds) - 2 * BevelWidth));
  UpdateScrollBar;
  inherited Layout;
end;

procedure TTreeView.UpdateScrollBar;
var
  Needed: Boolean;
begin
  Needed := FVisible.Count > VisibleRows;
  FScrollBar.SetRange(0, FVisible.Count, VisibleRows);
  FScrollBar.Position := FTopIndex;
  if FScrollBar.Visible <> Needed then
    FScrollBar.Visible := Needed;
end;

procedure TTreeView.ReceiveMessage(var Message: TPostedMessage);
begin
  if (Message.Code = MessageNotify) and (TControl(Message.Parameter1) = FScrollBar) then
  begin
    if (Message.Parameter2 = NotifyChanged) and (FScrollBar.Position <> FTopIndex) then
    begin
      FTopIndex := FScrollBar.Position;
      Invalidate;
    end;
    Exit;
  end;
  inherited ReceiveMessage(Message);
end;

procedure TTreeView.SetTopIndex(Value: LongInt);
begin
  if Value > FVisible.Count - VisibleRows then
    Value := FVisible.Count - VisibleRows;
  if Value < 0 then
    Value := 0;
  if Value = FTopIndex then
    Exit;
  FTopIndex := Value;
  FScrollBar.Position := Value;
  Invalidate;
end;

procedure TTreeView.EnsureVisible(Index: LongInt);
begin
  if Index < FTopIndex then
    SetTopIndex(Index)
  else if Index >= FTopIndex + VisibleRows then
    SetTopIndex(Index - VisibleRows + 1);
end;

procedure TTreeView.SetSelected(Value: TTreeNode);
var
  Ancestor: TTreeNode;
begin
  if Value = FSelected then
    Exit;
  { Made visible first. }
  if Value <> nil then
  begin
    Ancestor := Value.Parent;
    while (Ancestor <> nil) and (Ancestor <> FRoots) do
    begin
      Ancestor.Expanded := True;
      Ancestor := Ancestor.Parent;
    end;
  end;
  FSelected := Value;
  if Value <> nil then
    EnsureVisible(FVisible.IndexOf(Value));
  Invalidate;
  Changed;
end;

{ How a node's picture looks: greyed when the tree is disabled, tinted
  when the node is chosen. }
function NodeImageState(Node: TTreeNode): TImageDrawState;
begin
  Result := ImageDrawNormal;
  if not Node.FTree.Enabled then
    Result := ImageDrawDisabled
  else if (Node = Node.FTree.FSelected) or (Node = Node.FTree.FDropTarget) then
    Result := ImageDrawSelected;
end;

procedure TTreeView.Paint(var Canvas: TCanvas);
var
  IconBox: TRectangle;
  Box: TRectangle;
  Inner: TCanvas;
  Index: LongInt;
  Node: TTreeNode;
  Top: LongInt;
  Left: LongInt;
  Toggle: TRectangle;
  Right: LongInt;
  TextBox: TRectangle;
  Middle: LongInt;
  Size: LongInt;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillRectangle(Canvas, Box, Theme.Field);
  DrawSunkenBevel(Canvas, Box);
  Right := RectangleWidth(Box) - BevelWidth;
  if FScrollBar.Visible then
    Right := Right - RectangleWidth(FScrollBar.PixelBounds);
  Inner := Canvas;
  NarrowCanvasClip(Inner, MakeRectangle(BevelWidth, BevelWidth, Right - BevelWidth, RectangleHeight(Box) - 2 * BevelWidth));
  Size := Scaled(BoxSize);
  for Index := FTopIndex to FVisible.Count - 1 do
  begin
    Node := TTreeNode(FVisible[Index]);
    Top := 2 + (Index - FTopIndex) * RowHeight;
    if Top >= RectangleHeight(Box) then
      Break;
    Left := BoxRectangleLeft(Node);
    { The lines first: a node's box is drawn over where they meet. }
    if FShowLines then
      PaintLines(Inner, Node, Top);
    if Node.ShowsToggle then
    begin
      Toggle := MakeRectangle(Left, Top + (RowHeight - Size) div 2, Size, Size);
      FillRectangle(Inner, Toggle, Theme.Field);
      DrawRectangleOutline(Inner, Toggle, Theme.Shadow);
      Middle := Toggle.Top + Size div 2;
      DrawHorizontalLine(Inner, Toggle.Left + 2, Toggle.Right - 2, Middle, Theme.FieldText);
      if not Node.Expanded then
        DrawVerticalLine(Inner, Toggle.Left + Size div 2, Toggle.Top + 2, Toggle.Bottom - 2, Theme.FieldText);
    end;
    if Node.HasIcon then
    begin
      IconBox := MakeRectangle(Left + Size + Scaled(4), Top + (RowHeight - Scaled(SmallIconSize)) div 2,
        Scaled(SmallIconSize), Scaled(SmallIconSize));
      if (FImages <> nil) and FImages.ValidIndex(Node.ImageIndex) then
        FImages.DrawInBox(Inner, Node.ImageIndex, IconBox, NodeImageState(Node))
      else
        DrawStockIcon(Inner, Node.IconKind, IconBox);
    end;
    TextBox := MakeRectangle(NodeTextLeft(Node), Top, TextWidth(ControlFace, Node.Text) + Scaled(4), RowHeight);
    if (Node = FSelected) or (Node = FDropTarget) then
    begin
      FillRectangle(Inner, TextBox, Theme.Selection);
      DrawTextInBox(Inner, ControlFace, Node.Text, InflateRectangle(TextBox, -Scaled(2)), AlignTextLeft,
        Theme.SelectionText);
      if Focused and (Node = FSelected) then
        DrawFocusFrame(Inner, TextBox, Theme.SelectionText);
    end
    else
      DrawTextInBox(Inner, ControlFace, Node.Text, InflateRectangle(TextBox, -Scaled(2)), AlignTextLeft,
        Theme.FieldText);
  end;
end;

procedure TTreeView.PointerDown(X, Y: LongInt; Button: LongWord);
var
  Index: LongInt;
  Node: TTreeNode;
  Left: LongInt;
  Now: QWord;
begin
  if (Button <> ButtonLeft) or (Y < BevelWidth) then
    Exit;
  Index := FTopIndex + (Y - BevelWidth) div RowHeight;
  Node := VisibleNode(Index);
  if Node = nil then
    Exit;
  Left := BoxRectangleLeft(Node);
  if Node.ShowsToggle and (X >= Left) and (X < Left + Scaled(BoxSize)) then
  begin
    Node.Expanded := not Node.Expanded;
    Exit;
  end;
  Now := UptimeMilliseconds;
  Selected := Node;
  if (Node = FLastClickNode) and (Now - FLastClickTime <= DoubleClickMilliseconds) then
  begin
    FLastClickNode := nil;
    Node.Expanded := not Node.Expanded;
    Exit;
  end;
  FLastClickNode := Node;
  FLastClickTime := Now;
end;

procedure TTreeView.Wheel(Steps: LongInt);
begin
  SetTopIndex(FTopIndex - Steps * 3);
end;

function TTreeView.KeyDown(Code, Character, Modifiers: LongWord): Boolean;
var
  Index: LongInt;
begin
  Result := True;
  Index := FVisible.IndexOf(FSelected);
  case Code of
    KeyArrowUp: if Index > 0 then Selected := VisibleNode(Index - 1);
    KeyArrowDown: if Index < FVisible.Count - 1 then Selected := VisibleNode(Index + 1);
    KeyPageUp: Selected := VisibleNode(Index - VisibleRows);
    KeyPageDown: Selected := VisibleNode(Index + VisibleRows);
    KeyHome: Selected := VisibleNode(0);
    KeyEnd: Selected := VisibleNode(FVisible.Count - 1);
    KeyArrowRight:
      if FSelected <> nil then
        if FSelected.ShowsToggle and not FSelected.Expanded then
          FSelected.Expanded := True
        else if FSelected.Count > 0 then
          Selected := FSelected[0];
    KeyArrowLeft:
      if FSelected <> nil then
        if FSelected.Expanded then
          FSelected.Expanded := False
        else if (FSelected.Parent <> nil) and (FSelected.Parent <> FRoots) then
          Selected := FSelected.Parent;
  else
    if IsEnterKey(Code) and (FSelected <> nil) then
      FSelected.Expanded := not FSelected.Expanded
    else
      Result := False;
  end;
  if (FSelected = nil) and (FVisible.Count > 0) and ((Code = KeyArrowDown) or (Code = KeyHome)) then
    Selected := VisibleNode(0);
end;

end.
