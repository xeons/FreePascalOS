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
  Suggestions under an edit box as the user types (an address bar's
  pages, a search box's earlier searches): a pop-up as wide as the box
  with a row per suggestion - a picture, a title and, under it in the
  link colour, a detail (an address), and a mark at the right (a star
  for a bookmark) with its tags. The pop-up does not take the keys: the
  box goes on taking the typing and moves the highlight with Up and
  Down (MoveHighlight), Enter takes the highlighted row; a click takes
  a row (OnChoose); a press elsewhere closes it.
}
unit Controls.SuggestionPopup;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Drawing.Canvas,
  Controls.Base,
  Controls.Window,
  Controls.Popups,
  Controls.ImageList;

type
  TSuggestionRow = record
    Title: string;
    { '' for a row of one line. }
    Detail: string;
    { In Images (-1: none). }
    ImageIndex: LongInt;
    { Drawn at the right (a star: bookmarked). }
    Marked: Boolean;
    { Shown before the mark, quietly (a bookmark's tags). }
    Note: string;
  end;
  TSuggestionRows = array of TSuggestionRow;

  TSuggestionChooseEvent = procedure(Sender: TObject; Index: LongInt) of object;
  TSuggestionEvent = procedure(Sender: TObject) of object;

  TSuggestionPopup = class;

  TSuggestionList = class(TControl)
  private
    FPopup: TSuggestionPopup;
    function RowAt(Y: LongInt): LongInt;
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerMove(X, Y: LongInt; Buttons: LongWord); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
  end;

  TSuggestionPopup = class
  private
    FAnchor: TControl;
    FWindow: TPopupWindow;
    FList: TSuggestionList;
    FRows: TSuggestionRows;
    FHighlighted: LongInt;
    FImages: TImageList;
    FMaximumRows: LongInt;
    FOnChoose: TSuggestionChooseEvent;
    FOnClosed: TSuggestionEvent;
    function OwnerWindow: TControlWindow;
    function ShownRows: LongInt;
    procedure Dismissed(Sender: TControl);
    procedure SetHighlighted(Value: LongInt);
    procedure Place;
  public
    constructor Create(Anchor: TControl);
    destructor Destroy; override;
    { Shows Rows under the anchor (none: closes). }
    procedure ShowRows(const Rows: TSuggestionRows);
    procedure Close;
    function IsOpen: Boolean;
    { Moves the highlight Step rows (-1 up, 1 down; off either end: none). }
    procedure MoveHighlight(Step: LongInt);
    { Logical units. }
    function RowHeight: LongInt;
    property Rows: TSuggestionRows read FRows;
    property Highlighted: LongInt read FHighlighted write SetHighlighted;
    property Images: TImageList read FImages write FImages;
    property MaximumRows: LongInt read FMaximumRows write FMaximumRows;
    property OnChoose: TSuggestionChooseEvent read FOnChoose write FOnChoose;
    { It closed (a press elsewhere, Close). }
    property OnClosed: TSuggestionEvent read FOnClosed write FOnClosed;
  end;

implementation

uses
  Controls.LayoutRules,
  Abi.SystemCalls,
  Math,
  Drawing.Colors,
  Drawing.Rectangles,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Text,
  Controls.Painting;

const
  TwoLineRowHeight = 36;
  OneLineRowHeight = 22;
  RowIconSize = 16;
  StarSize = 12;

{ ---- the list ---- }

function TSuggestionList.RowAt(Y: LongInt): LongInt;
begin
  Result := Y div Scaled(FPopup.RowHeight);
  if (Result < 0) or (Result >= FPopup.ShownRows) then
    Result := -1;
end;

procedure DrawStar(const Canvas: TCanvas; CenterX, CenterY, Radius: LongInt; Color: TColor);
var
  Row, HalfWidth: LongInt;
begin
  { A small filled star: a triangle up and a wider band across. }
  for Row := -Radius to Radius do
  begin
    if Row < 0 then
      HalfWidth := (Radius + Row) div 2 + 1
    else if Row < Radius div 3 then
      HalfWidth := Radius
    else
      HalfWidth := Radius - (Row - Radius div 3);
    if HalfWidth > 0 then
      FillRectangle(Canvas, MakeRectangle(CenterX - HalfWidth, CenterY + Row, HalfWidth * 2, 1), Color);
  end;
end;

procedure TSuggestionList.Paint(var Canvas: TCanvas);
var
  Box, Row, IconBox, TitleBox, DetailBox: TRectangle;
  Index, Height, Size, TextLeft, MarkLeft, Line: LongInt;
  Item: TSuggestionRow;
  TitleColor, DetailColor, Background: TColor;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillRectangle(Canvas, Box, Theme.Field);
  Height := Scaled(FPopup.RowHeight);
  Size := Scaled(RowIconSize);
  Line := TextHeight(ControlFace);
  for Index := 0 to FPopup.ShownRows - 1 do
  begin
    Item := FPopup.FRows[Index];
    Row := MakeRectangle(Box.Left + 1, Index * Height + 1, RectangleWidth(Box) - 2, Height);
    TitleColor := Theme.FieldText;
    DetailColor := Theme.Link;
    Background := Theme.Field;
    if Index = FPopup.FHighlighted then
    begin
      Background := Theme.Selection;
      TitleColor := Theme.SelectionText;
      DetailColor := Theme.SelectionText;
    end
    else if Odd(Index) then
      Background := MixColors(Theme.Field, Theme.Face, 40);
    FillRectangle(Canvas, Row, Background);
    IconBox := MakeRectangle(Row.Left + Scaled(4), Row.Top + Scaled(3), Size, Size);
    if (FPopup.FImages <> nil) and FPopup.FImages.ValidIndex(Item.ImageIndex) then
      FPopup.FImages.DrawInBox(Canvas, Item.ImageIndex, IconBox);
    TextLeft := IconBox.Right + Scaled(6);
    MarkLeft := Row.Right - Scaled(6);
    if Item.Marked then
    begin
      Dec(MarkLeft, Scaled(StarSize));
      DrawStar(Canvas, MarkLeft + Scaled(StarSize) div 2, Row.Top + Scaled(10), Scaled(StarSize) div 2, Theme.Selection);
      if Index = FPopup.FHighlighted then
        DrawStar(Canvas, MarkLeft + Scaled(StarSize) div 2, Row.Top + Scaled(10), Scaled(StarSize) div 2,
          Theme.SelectionText);
      Dec(MarkLeft, Scaled(4));
    end;
    if Item.Note <> '' then
    begin
      Dec(MarkLeft, Min(TextWidth(ControlFace, Item.Note), RectangleWidth(Row) div 3));
      DrawTextInBox(Canvas, ControlFace, Item.Note, MakeRectangle(MarkLeft, Row.Top + Scaled(2),
        Row.Right - Scaled(6) - MarkLeft, Line), AlignTextLeft, DetailColor);
      Dec(MarkLeft, Scaled(6));
    end;
    TitleBox := MakeRectangle(TextLeft, Row.Top + Scaled(2), MarkLeft - TextLeft, Line);
    DrawTextInBox(Canvas, ControlFace, Item.Title, TitleBox, AlignTextLeft, TitleColor);
    if Item.Detail <> '' then
    begin
      DetailBox := MakeRectangle(TextLeft, TitleBox.Bottom + Scaled(1), Row.Right - Scaled(6) - TextLeft, Line);
      DrawTextInBox(Canvas, ControlFace, Item.Detail, DetailBox, AlignTextLeft, DetailColor);
    end;
  end;
  DrawRectangleOutline(Canvas, Box, Theme.DarkShadow);
end;

procedure TSuggestionList.PointerMove(X, Y: LongInt; Buttons: LongWord);
var
  Index: LongInt;
begin
  inherited PointerMove(X, Y, Buttons);
  Index := RowAt(Y);
  if (Index >= 0) and (Index <> FPopup.FHighlighted) then
    FPopup.Highlighted := Index;
end;

procedure TSuggestionList.PointerUp(X, Y: LongInt; Button: LongWord);
var
  Index: LongInt;
begin
  inherited PointerUp(X, Y, Button);
  if not (Button in [ButtonLeft, ButtonMiddle]) then
    Exit;
  Index := RowAt(Y);
  if (Index >= 0) and Assigned(FPopup.FOnChoose) then
    FPopup.FOnChoose(FPopup, Index);
end;

{ ---- the pop-up ---- }

constructor TSuggestionPopup.Create(Anchor: TControl);
begin
  inherited Create;
  FAnchor := Anchor;
  FHighlighted := -1;
  FMaximumRows := 12;
end;

destructor TSuggestionPopup.Destroy;
begin
  Close;
  inherited Destroy;
end;

function TSuggestionPopup.OwnerWindow: TControlWindow;
begin
  Result := nil;
  if (FAnchor.Host <> nil) and (FAnchor.Host.OwnerWindow is TControlWindow) then
    Result := TControlWindow(FAnchor.Host.OwnerWindow);
end;

function TSuggestionPopup.RowHeight: LongInt;
var
  Index: LongInt;
begin
  Result := OneLineRowHeight;
  for Index := 0 to High(FRows) do
    if FRows[Index].Detail <> '' then
      Exit(TwoLineRowHeight);
end;

function TSuggestionPopup.ShownRows: LongInt;
begin
  Result := Min(Length(FRows), FMaximumRows);
end;

function TSuggestionPopup.IsOpen: Boolean;
begin
  Result := FWindow <> nil;
end;

procedure TSuggestionPopup.Dismissed(Sender: TControl);
begin
  FWindow := nil;
  FList := nil;
  FHighlighted := -1;
  if Assigned(FOnClosed) then
    FOnClosed(Self);
end;

procedure TSuggestionPopup.Close;
var
  Window: TPopupWindow;
begin
  if FWindow = nil then
    Exit;
  Window := FWindow;
  Window.OnDismiss := nil;
  FWindow := nil;
  FList := nil;
  FHighlighted := -1;
  Window.Dismiss;
  if Assigned(FOnClosed) then
    FOnClosed(Self);
end;

procedure TSuggestionPopup.Place;
var
  Owner: TControlWindow;
  Left, Top, Width, Height: LongInt;
begin
  Owner := OwnerWindow;
  if Owner = nil then
    Exit;
  Left := Owner.ScreenLeft + Unscaled(FAnchor.PixelBounds.Left);
  Top := Owner.ScreenTop + Unscaled(FAnchor.PixelBounds.Bottom);
  Width := Unscaled(RectangleWidth(FAnchor.PixelBounds));
  Height := ShownRows * RowHeight + 2;
  if FWindow = nil then
  begin
    FWindow := TPopupWindow.CreatePopup(Owner, Left, Top, Width, Height);
    FWindow.TakesKeys := False;
    FWindow.OnDismiss := @Dismissed;
    FList := TSuggestionList.Create(FWindow.Root);
    FList.FPopup := Self;
    FList.Align := AlignClient;
    FWindow.Popup;
  end
  else
  begin
    FWindow.MoveTo(Left, Top);
    FWindow.SetClientSize(Width, Height);
    FList.Invalidate;
  end;
end;

procedure TSuggestionPopup.ShowRows(const Rows: TSuggestionRows);
begin
  FRows := Copy(Rows);
  FHighlighted := -1;
  if Length(FRows) = 0 then
  begin
    Close;
    Exit;
  end;
  Place;
end;

procedure TSuggestionPopup.SetHighlighted(Value: LongInt);
begin
  if (Value < -1) or (Value >= ShownRows) then
    Value := -1;
  FHighlighted := Value;
  if FList <> nil then
    FList.Invalidate;
end;

procedure TSuggestionPopup.MoveHighlight(Step: LongInt);
var
  Value: LongInt;
begin
  if ShownRows = 0 then
    Exit;
  Value := FHighlighted + Step;
  if Value < -1 then
    Value := ShownRows - 1
  else if Value >= ShownRows then
    Value := -1;
  Highlighted := Value;
end;

end.
