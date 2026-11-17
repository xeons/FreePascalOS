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
  List boxes: a list of lines to choose one from.

  A sunken field with the items one under another, the chosen one
  highlighted, and a vertical scroll bar at the right when they do not
  all fit. The arrows, Page Up and Down, Home and End move the choice; a
  click chooses, a double click (or Enter) activates (OnActivate,
  NotifyActivated); the wheel scrolls. A new choice is announced
  (OnChange, NotifyChanged).
}
unit Controls.ListBox;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Drawing.Rectangles,
  Drawing.Canvas,
  Windowing.Messages,
  Controls.Base,
  Controls.ScrollBar;

type
  TListBox = class(TControl)
  private
    FItems: TStringList;
    FItemIndex: LongInt;
    FTopIndex: LongInt;
    FScrollBar: TScrollBar;
    FLastClickTime: QWord;
    FLastClickIndex: LongInt;
    FOnActivate: TControlEvent;
    procedure ItemsChanged(Sender: TObject);
    procedure ScrollBarMoved;
    procedure SetItemIndex(Value: LongInt);
    procedure SetTopIndex(Value: LongInt);
    procedure UpdateScrollBar;
    procedure EnsureVisible(Index: LongInt);
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    procedure Wheel(Steps: LongInt); override;
    function KeyDown(Code, Character, Modifiers: LongWord): Boolean; override;
    procedure Layout; override;
    procedure Activate; virtual;
    { Draws item Index in Row (pixels, the full width of a line); the
      default draws its text after ItemIndent, highlighted when it is
      the choice, with the focus frame. }
    procedure PaintItem(var Canvas: TCanvas; Index: LongInt; const Row: TRectangle); virtual;
    { Pixels left free before each item's text (for a check box, say). }
    function ItemIndent: LongInt; virtual;
  public
    constructor Create(AParent: TControl); override;
    destructor Destroy; override;
    { Its scroll bar's notifications are its own business; the rest go
      to OnNotify as usual. }
    procedure ReceiveMessage(var Message: TPostedMessage); override;
    { Pixels, and how many whole lines fit. }
    function ItemHeight: LongInt; virtual;
    function VisibleCount: LongInt;
    function ItemAt(Y: LongInt): LongInt;
    property Items: TStringList read FItems;
    { -1: none. }
    property ItemIndex: LongInt read FItemIndex write SetItemIndex;
    property TopIndex: LongInt read FTopIndex write SetTopIndex;
    property OnActivate: TControlEvent read FOnActivate write FOnActivate;
  end;

const
  NotifyActivated = 3;
  DoubleClickMilliseconds = 500;

implementation

uses
  Abi.SystemCalls,
  Sys.Time,
  Drawing.Bevels,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Keys,
  Controls.Text;

constructor TListBox.Create(AParent: TControl);
begin
  inherited Create(AParent);
  CanFocus := True;
  FItems := TStringList.Create;
  FItems.OnChange := @ItemsChanged;
  FItemIndex := -1;
  FLastClickIndex := -1;
  FScrollBar := TScrollBar.Create(Self);
  FScrollBar.Kind := ScrollVertical;
  FScrollBar.Visible := False;
end;

destructor TListBox.Destroy;
begin
  FItems.Free;
  inherited Destroy;
end;

function TListBox.ItemHeight: LongInt;
begin
  Result := TextHeight(ControlFace) + Scaled(2);
  if Result < 1 then
    Result := 1;
end;

function TListBox.VisibleCount: LongInt;
begin
  Result := (RectangleHeight(PixelBounds) - 4) div ItemHeight;
  if Result < 1 then
    Result := 1;
end;

function TListBox.ItemAt(Y: LongInt): LongInt;
begin
  Result := FTopIndex + (Y - 2) div ItemHeight;
  if (Y < 2) or (Result >= FItems.Count) then
    Result := -1;
end;

procedure TListBox.Layout;
var
  Width: LongInt;
begin
  Width := Scaled(Theme.ScrollBarWidth);
  { The scroll bar inside the bevel, along the right. }
  FScrollBar.AssignBounds(Unscaled(RectangleWidth(PixelBounds) - 2 - Width), Unscaled(2), Unscaled(Width),
    Unscaled(RectangleHeight(PixelBounds) - 4));
  UpdateScrollBar;
  inherited Layout;
end;

procedure TListBox.UpdateScrollBar;
var
  Needed: Boolean;
begin
  Needed := FItems.Count > VisibleCount;
  FScrollBar.SetRange(0, FItems.Count, VisibleCount);
  FScrollBar.Position := FTopIndex;
  if FScrollBar.Visible <> Needed then
    FScrollBar.Visible := Needed;
end;

procedure TListBox.ItemsChanged(Sender: TObject);
begin
  if FItemIndex >= FItems.Count then
    FItemIndex := FItems.Count - 1;
  SetTopIndex(FTopIndex);
  UpdateScrollBar;
  Invalidate;
end;

procedure TListBox.ScrollBarMoved;
begin
  if FScrollBar.Position <> FTopIndex then
  begin
    FTopIndex := FScrollBar.Position;
    Invalidate;
  end;
end;

procedure TListBox.ReceiveMessage(var Message: TPostedMessage);
begin
  if (Message.Code = MessageNotify) and (TControl(Message.Parameter1) = FScrollBar) then
  begin
    if Message.Parameter2 = NotifyChanged then
      ScrollBarMoved;
    Exit;
  end;
  inherited ReceiveMessage(Message);
end;

procedure TListBox.SetTopIndex(Value: LongInt);
begin
  if Value > FItems.Count - VisibleCount then
    Value := FItems.Count - VisibleCount;
  if Value < 0 then
    Value := 0;
  if Value = FTopIndex then
    Exit;
  FTopIndex := Value;
  FScrollBar.Position := Value;
  Invalidate;
end;

procedure TListBox.EnsureVisible(Index: LongInt);
begin
  if Index < FTopIndex then
    SetTopIndex(Index)
  else if Index >= FTopIndex + VisibleCount then
    SetTopIndex(Index - VisibleCount + 1);
end;

procedure TListBox.SetItemIndex(Value: LongInt);
begin
  if Value >= FItems.Count then
    Value := FItems.Count - 1;
  if Value < -1 then
    Value := -1;
  if Value = FItemIndex then
    Exit;
  FItemIndex := Value;
  if Value >= 0 then
    EnsureVisible(Value);
  Invalidate;
  Changed;
end;

procedure TListBox.Activate;
begin
  if Assigned(FOnActivate) then
    FOnActivate(Self);
  Notify(NotifyActivated);
end;

procedure TListBox.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
  Inner: TCanvas;
  Index: LongInt;
  Row: TRectangle;
  Right: LongInt;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillRectangle(Canvas, Box, Theme.Field);
  DrawBevel(Canvas, Box, SunkenThemeBevel);
  Right := RectangleWidth(Box) - 2;
  if FScrollBar.Visible then
    Right := Right - RectangleWidth(FScrollBar.PixelBounds);
  Inner := Canvas;
  NarrowCanvasClip(Inner, MakeRectangle(2, 2, Right - 2, RectangleHeight(Box) - 4));
  for Index := FTopIndex to FItems.Count - 1 do
  begin
    Row := MakeRectangle(2, 2 + (Index - FTopIndex) * ItemHeight, Right - 2, ItemHeight);
    if Row.Top >= RectangleHeight(Box) then
      Break;
    PaintItem(Inner, Index, Row);
  end;
end;

function TListBox.ItemIndent: LongInt;
begin
  Result := 0;
end;

procedure TListBox.PaintItem(var Canvas: TCanvas; Index: LongInt; const Row: TRectangle);
var
  TextRow: TRectangle;
begin
  TextRow := Row;
  TextRow.Left := TextRow.Left + ItemIndent;
  if Index = FItemIndex then
  begin
    FillRectangle(Canvas, TextRow, Theme.Selection);
    DrawTextInBox(Canvas, ControlFace, FItems[Index], InflateRectangle(TextRow, -Scaled(2)), AlignTextLeft,
      Theme.SelectionText);
    if Focused then
      DrawFocusFrame(Canvas, TextRow, Theme.SelectionText);
  end
  else
    DrawTextInBox(Canvas, ControlFace, FItems[Index], InflateRectangle(TextRow, -Scaled(2)), AlignTextLeft,
      Theme.FieldText);
end;

procedure TListBox.PointerDown(X, Y: LongInt; Button: LongWord);
var
  Index: LongInt;
  Now: QWord;
begin
  if Button <> ButtonLeft then
    Exit;
  Index := ItemAt(Y);
  if Index < 0 then
    Exit;
  Now := UptimeMilliseconds;
  ItemIndex := Index;
  if (Index = FLastClickIndex) and (Now - FLastClickTime <= DoubleClickMilliseconds) then
  begin
    FLastClickIndex := -1;
    Activate;
    Exit;
  end;
  FLastClickIndex := Index;
  FLastClickTime := Now;
end;

procedure TListBox.Wheel(Steps: LongInt);
begin
  SetTopIndex(FTopIndex - Steps * 3);
end;

function TListBox.KeyDown(Code, Character, Modifiers: LongWord): Boolean;
begin
  Result := True;
  case Code of
    KeyArrowUp: ItemIndex := FItemIndex - 1;
    KeyArrowDown: ItemIndex := FItemIndex + 1;
    KeyPageUp: ItemIndex := FItemIndex - VisibleCount;
    KeyPageDown: ItemIndex := FItemIndex + VisibleCount;
    KeyHome: ItemIndex := 0;
    KeyEnd: ItemIndex := FItems.Count - 1;
  else
    if IsEnterKey(Code) and (FItemIndex >= 0) then
      Activate
    else
      Result := False;
  end;
  if (ItemIndex < 0) and (FItems.Count > 0) and ((Code = KeyArrowUp) or (Code = KeyPageUp)) then
    ItemIndex := 0;
end;

end.
