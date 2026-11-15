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
}
unit Controls.TreeView;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Drawing.Canvas,
  Windowing.Messages,
  Controls.Base,
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
    function GetChild(Index: LongInt): TTreeNode;
    function GetCount: LongInt;
    procedure SetExpanded(Value: Boolean);
    procedure SetText(const Value: string);
  public
    constructor Create(ATree: TTreeView; AParent: TTreeNode; const AText: string);
    destructor Destroy; override;
    function Add(const AText: string): TTreeNode;
    function Depth: LongInt;
    property Text: string read FText write SetText;
    property Parent: TTreeNode read FParent;
    property Count: LongInt read GetCount;
    property Children[Index: LongInt]: TTreeNode read GetChild; default;
    property Expanded: Boolean read FExpanded write SetExpanded;
    property Data: Pointer read FData write FData;
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
    FOnExpandChanged: TTreeNodeEvent;
    procedure Rebuild;
    procedure AddVisible(Node: TTreeNode);
    function RowHeight: LongInt;
    function VisibleRows: LongInt;
    function BoxRectangleLeft(Node: TTreeNode): LongInt;
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
    destructor Destroy; override;
    procedure ReceiveMessage(var Message: TPostedMessage); override;
    { A node at the top level. }
    function AddRoot(const AText: string): TTreeNode;
    procedure Clear;
    { The node shown on line Index (counting what is visible). }
    function VisibleNode(Index: LongInt): TTreeNode;
    function VisibleCount: LongInt;
    { The middle of visible line Index (as scrolled now), in this
      control's pixels. }
    function RowMiddle(Index: LongInt): LongInt;
    property Selected: TTreeNode read FSelected write SetSelected;
    property OnExpandChanged: TTreeNodeEvent read FOnExpandChanged write FOnExpandChanged;
  end;

implementation

uses
  Abi.SystemCalls,
  Sys.Time,
  Drawing.Rectangles,
  Drawing.Bevels,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Keys,
  Controls.Text,
  Controls.ListBox;

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

procedure TTreeView.Clear;
begin
  FRoots.FTree := nil;
  FRoots.Free;
  FRoots := TTreeNode.Create(Self, nil, '');
  FRoots.FExpanded := True;
  FSelected := nil;
  NodeChanged;
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
  Result := 2 + (Index - FTopIndex) * RowHeight + RowHeight div 2;
end;

function TTreeView.RowHeight: LongInt;
begin
  Result := TextHeight(ControlFace) + Scaled(2);
  if Result < 1 then
    Result := 1;
end;

function TTreeView.VisibleRows: LongInt;
begin
  Result := (RectangleHeight(PixelBounds) - 4) div RowHeight;
  if Result < 1 then
    Result := 1;
end;

function TTreeView.BoxRectangleLeft(Node: TTreeNode): LongInt;
begin
  Result := Scaled(4 + Node.Depth * IndentStep);
end;

procedure TTreeView.Layout;
var
  Width: LongInt;
begin
  Width := Scaled(Theme.ScrollBarWidth);
  FScrollBar.AssignBounds(Unscaled(RectangleWidth(PixelBounds) - 2 - Width), Unscaled(2), Unscaled(Width),
    Unscaled(RectangleHeight(PixelBounds) - 4));
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

procedure TTreeView.Paint(var Canvas: TCanvas);
var
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
  DrawBevel(Canvas, Box, SunkenThemeBevel);
  Right := RectangleWidth(Box) - 2;
  if FScrollBar.Visible then
    Right := Right - RectangleWidth(FScrollBar.PixelBounds);
  Inner := Canvas;
  NarrowCanvasClip(Inner, MakeRectangle(2, 2, Right - 2, RectangleHeight(Box) - 4));
  Size := Scaled(BoxSize);
  for Index := FTopIndex to FVisible.Count - 1 do
  begin
    Node := TTreeNode(FVisible[Index]);
    Top := 2 + (Index - FTopIndex) * RowHeight;
    if Top >= RectangleHeight(Box) then
      Break;
    Left := BoxRectangleLeft(Node);
    if Node.Count > 0 then
    begin
      Toggle := MakeRectangle(Left, Top + (RowHeight - Size) div 2, Size, Size);
      FillRectangle(Inner, Toggle, Theme.Field);
      DrawRectangleOutline(Inner, Toggle, Theme.Shadow);
      Middle := Toggle.Top + Size div 2;
      DrawHorizontalLine(Inner, Toggle.Left + 2, Toggle.Right - 2, Middle, Theme.FieldText);
      if not Node.Expanded then
        DrawVerticalLine(Inner, Toggle.Left + Size div 2, Toggle.Top + 2, Toggle.Bottom - 2, Theme.FieldText);
    end;
    TextBox := MakeRectangle(Left + Size + Scaled(5), Top, TextWidth(ControlFace, Node.Text) + Scaled(4), RowHeight);
    if Node = FSelected then
    begin
      FillRectangle(Inner, TextBox, Theme.Selection);
      DrawTextInBox(Inner, ControlFace, Node.Text, InflateRectangle(TextBox, -Scaled(2)), AlignTextLeft,
        Theme.SelectionText);
      if Focused then
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
  if (Button <> ButtonLeft) or (Y < 2) then
    Exit;
  Index := FTopIndex + (Y - 2) div RowHeight;
  Node := VisibleNode(Index);
  if Node = nil then
    Exit;
  Left := BoxRectangleLeft(Node);
  if (Node.Count > 0) and (X >= Left) and (X < Left + Scaled(BoxSize)) then
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
        if (FSelected.Count > 0) and not FSelected.Expanded then
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
