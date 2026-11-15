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
  List views (details): rows of items in columns under a header.

  Each item is a row of texts, one per column (Cells). The header shows
  the columns' captions; a click on one is announced (OnColumnClick:
  sorting is the program's to do), dragging the edge between two
  resizes the left one. Rows are chosen as in a list box (arrows, Page
  Up and Down, Home, End, a click); a double click or Enter activates
  (OnActivate, NotifyActivated). A vertical scroll bar shows when the
  rows do not fit.
}
unit Controls.ListView;

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
  TListView = class;
  TColumnEvent = procedure(Sender: TListView; Column: LongInt) of object;

  TListView = class(TControl)
  private
    FCaptions: TStringList;
    FWidths: array of LongInt;
    FRows: TList;
    FItemIndex: LongInt;
    FTopIndex: LongInt;
    FScrollBar: TScrollBar;
    FResizing: LongInt;
    FResizeStartX: LongInt;
    FResizeStartWidth: LongInt;
    FLastClickTime: QWord;
    FLastClickIndex: LongInt;
    FOnColumnClick: TColumnEvent;
    FOnActivate: TControlEvent;
    function HeaderHeight: LongInt;
    function RowHeight: LongInt;
    function VisibleRows: LongInt;
    function ColumnLeft(Column: LongInt): LongInt;
    function ColumnEdgeAt(X: LongInt): LongInt;
    function GetCell(Row, Column: LongInt): string;
    procedure SetCell(Row, Column: LongInt; const Value: string);
    function GetRowCount: LongInt;
    procedure SetItemIndex(Value: LongInt);
    procedure SetTopIndex(Value: LongInt);
    procedure UpdateScrollBar;
    procedure EnsureVisible(Index: LongInt);
    procedure Activate;
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    procedure PointerMove(X, Y: LongInt; Buttons: LongWord); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
    procedure Wheel(Steps: LongInt); override;
    function KeyDown(Code, Character, Modifiers: LongWord): Boolean; override;
    procedure Layout; override;
  public
    constructor Create(AParent: TControl); override;
    destructor Destroy; override;
    procedure ReceiveMessage(var Message: TPostedMessage); override;
    { Width in logical units. }
    procedure AddColumn(const Caption: string; Width: LongInt);
    { A row with these texts (the first column's first); its index. }
    function AddRow(const Texts: array of string): LongInt;
    procedure DeleteRow(Index: LongInt);
    procedure Clear;
    function ColumnCount: LongInt;
    { Logical units. }
    function ColumnWidth(Column: LongInt): LongInt;
    { The middle of row Index (as shown now) and of the header, in this
      control's pixels. }
    function RowMiddle(Index: LongInt): LongInt;
    function HeaderMiddle: LongInt;
    property Cells[Row, Column: LongInt]: string read GetCell write SetCell;
    property RowCount: LongInt read GetRowCount;
    property ItemIndex: LongInt read FItemIndex write SetItemIndex;
    property OnColumnClick: TColumnEvent read FOnColumnClick write FOnColumnClick;
    property OnActivate: TControlEvent read FOnActivate write FOnActivate;
  end;

implementation

uses
  Abi.SystemCalls,
  Sys.Time,
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Bevels,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Keys,
  Controls.Text,
  Controls.Buttons,
  Controls.ListBox;

const
  MinimumColumnWidth = 16;
  EdgeGrip = 3;

constructor TListView.Create(AParent: TControl);
begin
  inherited Create(AParent);
  CanFocus := True;
  FCaptions := TStringList.Create;
  FRows := TList.Create;
  FItemIndex := -1;
  FResizing := -1;
  FLastClickIndex := -1;
  FScrollBar := TScrollBar.Create(Self);
  FScrollBar.Visible := False;
end;

destructor TListView.Destroy;
begin
  Clear;
  FRows.Free;
  FCaptions.Free;
  inherited Destroy;
end;

procedure TListView.AddColumn(const Caption: string; Width: LongInt);
begin
  FCaptions.Add(Caption);
  SetLength(FWidths, FCaptions.Count);
  FWidths[FCaptions.Count - 1] := Width;
  Invalidate;
end;

function TListView.ColumnCount: LongInt;
begin
  Result := FCaptions.Count;
end;

function TListView.ColumnWidth(Column: LongInt): LongInt;
begin
  Result := FWidths[Column];
end;

function TListView.AddRow(const Texts: array of string): LongInt;
var
  Row: TStringList;
  Index: LongInt;
begin
  Row := TStringList.Create;
  for Index := 0 to High(Texts) do
    Row.Add(Texts[Index]);
  Result := FRows.Add(Row);
  UpdateScrollBar;
  Invalidate;
end;

procedure TListView.DeleteRow(Index: LongInt);
begin
  if (Index < 0) or (Index >= FRows.Count) then
    Exit;
  TStringList(FRows[Index]).Free;
  FRows.Delete(Index);
  if FItemIndex >= FRows.Count then
    FItemIndex := FRows.Count - 1;
  SetTopIndex(FTopIndex);
  UpdateScrollBar;
  Invalidate;
end;

procedure TListView.Clear;
var
  Index: LongInt;
begin
  for Index := 0 to FRows.Count - 1 do
    TStringList(FRows[Index]).Free;
  FRows.Clear;
  FItemIndex := -1;
  FTopIndex := 0;
  UpdateScrollBar;
  Invalidate;
end;

function TListView.GetRowCount: LongInt;
begin
  Result := FRows.Count;
end;

function TListView.GetCell(Row, Column: LongInt): string;
var
  Texts: TStringList;
begin
  Result := '';
  if (Row < 0) or (Row >= FRows.Count) then
    Exit;
  Texts := TStringList(FRows[Row]);
  if (Column >= 0) and (Column < Texts.Count) then
    Result := Texts[Column];
end;

procedure TListView.SetCell(Row, Column: LongInt; const Value: string);
var
  Texts: TStringList;
begin
  if (Row < 0) or (Row >= FRows.Count) or (Column < 0) then
    Exit;
  Texts := TStringList(FRows[Row]);
  while Texts.Count <= Column do
    Texts.Add('');
  Texts[Column] := Value;
  Invalidate;
end;

function TListView.RowMiddle(Index: LongInt): LongInt;
begin
  Result := 2 + HeaderHeight + (Index - FTopIndex) * RowHeight + RowHeight div 2;
end;

function TListView.HeaderMiddle: LongInt;
begin
  Result := 2 + HeaderHeight div 2;
end;

function TListView.HeaderHeight: LongInt;
begin
  Result := TextHeight(ControlFace) + Scaled(6);
end;

function TListView.RowHeight: LongInt;
begin
  Result := TextHeight(ControlFace) + Scaled(2);
  if Result < 1 then
    Result := 1;
end;

function TListView.VisibleRows: LongInt;
begin
  Result := (RectangleHeight(PixelBounds) - 4 - HeaderHeight) div RowHeight;
  if Result < 1 then
    Result := 1;
end;

function TListView.ColumnLeft(Column: LongInt): LongInt;
var
  Index: LongInt;
begin
  Result := 2;
  for Index := 0 to Column - 1 do
    Result := Result + Scaled(FWidths[Index]);
end;

{ The column whose right edge is at X (within a grip), or -1. }
function TListView.ColumnEdgeAt(X: LongInt): LongInt;
var
  Column: LongInt;
begin
  for Column := 0 to ColumnCount - 1 do
    if Abs(X - ColumnLeft(Column + 1)) <= Scaled(EdgeGrip) then
      Exit(Column);
  Result := -1;
end;

procedure TListView.Layout;
var
  Width: LongInt;
begin
  Width := Scaled(Theme.ScrollBarWidth);
  FScrollBar.AssignBounds(Unscaled(RectangleWidth(PixelBounds) - 2 - Width), Unscaled(2 + HeaderHeight),
    Unscaled(Width), Unscaled(RectangleHeight(PixelBounds) - 4 - HeaderHeight));
  UpdateScrollBar;
  inherited Layout;
end;

procedure TListView.UpdateScrollBar;
var
  Needed: Boolean;
begin
  Needed := FRows.Count > VisibleRows;
  FScrollBar.SetRange(0, FRows.Count, VisibleRows);
  FScrollBar.Position := FTopIndex;
  if FScrollBar.Visible <> Needed then
    FScrollBar.Visible := Needed;
end;

procedure TListView.ReceiveMessage(var Message: TPostedMessage);
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

procedure TListView.SetTopIndex(Value: LongInt);
begin
  if Value > FRows.Count - VisibleRows then
    Value := FRows.Count - VisibleRows;
  if Value < 0 then
    Value := 0;
  if Value = FTopIndex then
    Exit;
  FTopIndex := Value;
  FScrollBar.Position := Value;
  Invalidate;
end;

procedure TListView.EnsureVisible(Index: LongInt);
begin
  if Index < FTopIndex then
    SetTopIndex(Index)
  else if Index >= FTopIndex + VisibleRows then
    SetTopIndex(Index - VisibleRows + 1);
end;

procedure TListView.SetItemIndex(Value: LongInt);
begin
  if Value >= FRows.Count then
    Value := FRows.Count - 1;
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

procedure TListView.Activate;
begin
  if Assigned(FOnActivate) then
    FOnActivate(Self);
  Notify(NotifyActivated);
end;

procedure TListView.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
  Inner: TCanvas;
  Column: LongInt;
  Row: LongInt;
  Cell: TRectangle;
  Line: TRectangle;
  Right: LongInt;
  Top: LongInt;
  TextColor: TColor;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillRectangle(Canvas, Box, Theme.Field);
  DrawBevel(Canvas, Box, SunkenThemeBevel);
  Right := RectangleWidth(Box) - 2;
  if FScrollBar.Visible then
    Right := Right - RectangleWidth(FScrollBar.PixelBounds);
  Inner := Canvas;
  NarrowCanvasClip(Inner, MakeRectangle(2, 2, RectangleWidth(Box) - 4, RectangleHeight(Box) - 4));
  { The header: a button face per column, and what is left after them. }
  for Column := 0 to ColumnCount - 1 do
  begin
    Cell := MakeRectangle(ColumnLeft(Column), 2, Scaled(FWidths[Column]), HeaderHeight);
    DrawButtonFace(Inner, Cell, False, False);
    DrawTextInBox(Inner, ControlFace, FCaptions[Column], InflateRectangle(Cell, -Scaled(4)), AlignTextLeft,
      Theme.FaceText);
  end;
  Cell := MakeRectangle(ColumnLeft(ColumnCount), 2, RectangleWidth(Box), HeaderHeight);
  DrawButtonFace(Inner, Cell, False, False);
  NarrowCanvasClip(Inner, MakeRectangle(2, 2 + HeaderHeight, Right - 2, RectangleHeight(Box) - 4 - HeaderHeight));
  for Row := FTopIndex to FRows.Count - 1 do
  begin
    Top := 2 + HeaderHeight + (Row - FTopIndex) * RowHeight;
    if Top >= RectangleHeight(Box) then
      Break;
    Line := MakeRectangle(2, Top, Right - 2, RowHeight);
    TextColor := Theme.FieldText;
    if Row = FItemIndex then
    begin
      FillRectangle(Inner, Line, Theme.Selection);
      TextColor := Theme.SelectionText;
    end;
    for Column := 0 to ColumnCount - 1 do
    begin
      Cell := MakeRectangle(ColumnLeft(Column) + Scaled(4), Top, Scaled(FWidths[Column]) - Scaled(8), RowHeight);
      DrawTextInBox(Inner, ControlFace, GetCell(Row, Column), Cell, AlignTextLeft, TextColor);
    end;
    if (Row = FItemIndex) and Focused then
      DrawFocusFrame(Inner, Line, Theme.SelectionText);
  end;
end;

procedure TListView.PointerDown(X, Y: LongInt; Button: LongWord);
var
  Column: LongInt;
  Row: LongInt;
  Now: QWord;
begin
  if Button <> ButtonLeft then
    Exit;
  if Y < 2 + HeaderHeight then
  begin
    FResizing := ColumnEdgeAt(X);
    if FResizing >= 0 then
    begin
      FResizeStartX := X;
      FResizeStartWidth := FWidths[FResizing];
      Exit;
    end;
    for Column := 0 to ColumnCount - 1 do
      if (X >= ColumnLeft(Column)) and (X < ColumnLeft(Column + 1)) and Assigned(FOnColumnClick) then
        FOnColumnClick(Self, Column);
    Exit;
  end;
  Row := FTopIndex + (Y - 2 - HeaderHeight) div RowHeight;
  if Row >= FRows.Count then
    Exit;
  Now := UptimeMilliseconds;
  ItemIndex := Row;
  if (Row = FLastClickIndex) and (Now - FLastClickTime <= DoubleClickMilliseconds) then
  begin
    FLastClickIndex := -1;
    Activate;
    Exit;
  end;
  FLastClickIndex := Row;
  FLastClickTime := Now;
end;

procedure TListView.PointerMove(X, Y: LongInt; Buttons: LongWord);
var
  Width: LongInt;
begin
  if FResizing < 0 then
    Exit;
  Width := FResizeStartWidth + Unscaled(X - FResizeStartX);
  if Width < MinimumColumnWidth then
    Width := MinimumColumnWidth;
  FWidths[FResizing] := Width;
  Invalidate;
end;

procedure TListView.PointerUp(X, Y: LongInt; Button: LongWord);
begin
  FResizing := -1;
end;

procedure TListView.Wheel(Steps: LongInt);
begin
  SetTopIndex(FTopIndex - Steps * 3);
end;

function TListView.KeyDown(Code, Character, Modifiers: LongWord): Boolean;
begin
  Result := True;
  case Code of
    KeyArrowUp: ItemIndex := FItemIndex - 1;
    KeyArrowDown: ItemIndex := FItemIndex + 1;
    KeyPageUp: ItemIndex := FItemIndex - VisibleRows;
    KeyPageDown: ItemIndex := FItemIndex + VisibleRows;
    KeyHome: ItemIndex := 0;
    KeyEnd: ItemIndex := FRows.Count - 1;
  else
    if IsEnterKey(Code) and (FItemIndex >= 0) then
      Activate
    else
      Result := False;
  end;
  if (FItemIndex < 0) and (FRows.Count > 0) and ((Code = KeyArrowUp) or (Code = KeyPageUp)) then
    ItemIndex := 0;
end;

end.
