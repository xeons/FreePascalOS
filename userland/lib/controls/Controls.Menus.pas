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
  Menus: a menu bar along the top of a window, the menus that drop from
  it, submenus, and pop-up (context) menus.

  A TMenuItem is a line of a menu: its text, a shortcut shown at the
  right (shown only: the window's accelerators do the work), whether it
  is enabled or checked, a separator, or the head of a submenu (its own
  items). Choosing one closes every open menu, then runs its OnClick
  and the OnChoose of whoever opened the menu.

  An open menu is a pop-up window holding a TMenuList. Clicking a
  heading of the menu bar opens its menu below it; while one is open,
  pointing at another heading opens that one instead. In a menu the
  pointer highlights, a click chooses, and a submenu opens to the right
  of its item when highlighted; the arrows move, Enter chooses, Escape
  closes one level, Left and Right go between submenus and the bar's
  menus. Only the newest pop-up holds the pointer, so it passes what
  happens over the others (its parents, the menu bar) on to them.
}
unit Controls.Menus;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Drawing.Rectangles,
  Drawing.Canvas,
  Controls.Base,
  Controls.Window,
  Controls.Popups;

type
  TMenuItem = class;
  TMenuItemEvent = procedure(Item: TMenuItem) of object;

  TMenuItem = class
  private
    FText: string;
    FShortcutText: string;
    FEnabled: Boolean;
    FChecked: Boolean;
    FIsSeparator: Boolean;
    FItems: TList;
    FTag: PtrInt;
    FOnClick: TMenuItemEvent;
    function GetItem(Index: LongInt): TMenuItem;
    function GetCount: LongInt;
  public
    constructor Create(const AText: string);
    destructor Destroy; override;
    function Add(const AText: string; AOnClick: TMenuItemEvent = nil; const AShortcutText: string = ''): TMenuItem;
    procedure AddSeparator;
    property Text: string read FText write FText;
    property ShortcutText: string read FShortcutText write FShortcutText;
    property Enabled: Boolean read FEnabled write FEnabled;
    property Checked: Boolean read FChecked write FChecked;
    property IsSeparator: Boolean read FIsSeparator;
    property Count: LongInt read GetCount;
    property Items[Index: LongInt]: TMenuItem read GetItem; default;
    property Tag: PtrInt read FTag write FTag;
    property OnClick: TMenuItemEvent read FOnClick write FOnClick;
  end;

  TMenuBar = class;

  { The items of an open menu, filling its pop-up. }
  TMenuList = class(TControl)
  private
    FMenu: TMenuItem;
    FPopup: TPopupWindow;
    FHighlighted: LongInt;
    FSubmenu: TMenuList;
    FParentList: TMenuList;
    FMenuBar: TMenuBar;
    FOnChoose: TMenuItemEvent;
    function ItemTop(Index: LongInt): LongInt;
    function ItemAt(Y: LongInt): LongInt;
    procedure Highlight(Index: LongInt);
    procedure OpenSubmenu;
    procedure CloseSubmenu;
    procedure Choose(Item: TMenuItem);
    function PassOn(X, Y: LongInt; Pressed: Boolean): Boolean;
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerMove(X, Y: LongInt; Buttons: LongWord); override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
    function KeyDown(Code, Character, Modifiers: LongWord): Boolean; override;
  public
    { Closes this menu and every one it came from. }
    procedure CloseAll;
    property Menu: TMenuItem read FMenu;
  end;

  TMenuBar = class(TControl)
  private
    FMenu: TMenuItem;
    FOpenIndex: LongInt;
    FOpenList: TMenuList;
    FOnChoose: TMenuItemEvent;
    function HeadingLeft(Index: LongInt): LongInt;
    function HeadingWidth(Index: LongInt): LongInt;
    function HeadingAt(X: LongInt): LongInt;
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
  public
    constructor Create(AParent: TControl); override;
    destructor Destroy; override;
    { Opens heading Index's menu (closing any other); -1 closes. }
    procedure OpenMenu(Index: LongInt);
    { The headings; each heading's items are its menu. }
    property Menu: TMenuItem read FMenu;
    property OnChoose: TMenuItemEvent read FOnChoose write FOnChoose;
  end;

{ Opens Menu's items at (Left, Top) of the screen (logical units) for
  Owner: a context menu. }
function ShowPopupMenu(Owner: TControlWindow; Menu: TMenuItem; Left, Top: LongInt;
  OnChoose: TMenuItemEvent = nil): TMenuList;

implementation

uses
  Abi.SystemCalls,
  Drawing.Colors,
  Drawing.Bevels,
  Drawing.Shapes,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Keys,
  Controls.Text;

const
  SeparatorHeight = 8;
  { Logical units: the check column, gaps, the submenu arrow column. }
  CheckColumn = 20;
  ArrowColumn = 16;
  ColumnGap = 16;

{ --- TMenuItem ------------------------------------------------------------------ }

constructor TMenuItem.Create(const AText: string);
begin
  inherited Create;
  FText := AText;
  FEnabled := True;
  FItems := TList.Create;
end;

destructor TMenuItem.Destroy;
var
  Index: LongInt;
begin
  for Index := 0 to FItems.Count - 1 do
    TMenuItem(FItems[Index]).Free;
  FItems.Free;
  inherited Destroy;
end;

function TMenuItem.GetItem(Index: LongInt): TMenuItem;
begin
  Result := TMenuItem(FItems[Index]);
end;

function TMenuItem.GetCount: LongInt;
begin
  Result := FItems.Count;
end;

function TMenuItem.Add(const AText: string; AOnClick: TMenuItemEvent; const AShortcutText: string): TMenuItem;
begin
  Result := TMenuItem.Create(AText);
  Result.FOnClick := AOnClick;
  Result.FShortcutText := AShortcutText;
  FItems.Add(Result);
end;

procedure TMenuItem.AddSeparator;
var
  Separator: TMenuItem;
begin
  Separator := TMenuItem.Create('');
  Separator.FIsSeparator := True;
  FItems.Add(Separator);
end;

{ --- Opening menus ------------------------------------------------------------------ }

{ Logical units. }
function ItemHeightOf(Item: TMenuItem): LongInt;
begin
  if Item.IsSeparator then
    Result := SeparatorHeight
  else
    Result := Theme.MenuItemHeight;
end;

procedure MeasureMenu(Menu: TMenuItem; out Width, Height: LongInt);
var
  Index: LongInt;
  TextPart: LongInt;
  ShortcutPart: LongInt;
  Measured: LongInt;
begin
  TextPart := 0;
  ShortcutPart := 0;
  Height := 4;
  for Index := 0 to Menu.Count - 1 do
  begin
    Height := Height + ItemHeightOf(Menu[Index]);
    Measured := Unscaled(TextWidth(ControlFace, Menu[Index].Text));
    if Measured > TextPart then
      TextPart := Measured;
    Measured := Unscaled(TextWidth(ControlFace, Menu[Index].ShortcutText));
    if Measured > ShortcutPart then
      ShortcutPart := Measured;
  end;
  Width := 4 + CheckColumn + TextPart + ColumnGap + ShortcutPart + ArrowColumn;
end;

{ A menu list in a new pop-up at (Left, Top) of the screen, logical. }
function OpenMenuList(Owner: TControlWindow; Menu: TMenuItem; Left, Top: LongInt): TMenuList;
var
  Width: LongInt;
  Height: LongInt;
  Popup: TPopupWindow;
begin
  MeasureMenu(Menu, Width, Height);
  { Kept on the screen. }
  if Left + Width > Unscaled(ScreenWidth) then
    Left := Unscaled(ScreenWidth) - Width;
  if Top + Height > Unscaled(ScreenHeight) then
    Top := Unscaled(ScreenHeight) - Height;
  if Left < 0 then
    Left := 0;
  if Top < 0 then
    Top := 0;
  Popup := TPopupWindow.CreatePopup(Owner, Left, Top, Width, Height);
  Result := TMenuList.Create(Popup.Root);
  Result.Align := AlignClient;
  Result.CanFocus := True;
  Result.FMenu := Menu;
  Result.FPopup := Popup;
  Result.FHighlighted := -1;
  Result.SetFocus;
  Popup.Popup;
end;

function ShowPopupMenu(Owner: TControlWindow; Menu: TMenuItem; Left, Top: LongInt;
  OnChoose: TMenuItemEvent): TMenuList;
begin
  Result := OpenMenuList(Owner, Menu, Left, Top);
  Result.FOnChoose := OnChoose;
end;

{ --- TMenuList ------------------------------------------------------------------------ }

function TMenuList.ItemTop(Index: LongInt): LongInt;
var
  Position: LongInt;
begin
  Result := Scaled(2);
  for Position := 0 to Index - 1 do
    Result := Result + Scaled(ItemHeightOf(FMenu[Position]));
end;

function TMenuList.ItemAt(Y: LongInt): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to FMenu.Count - 1 do
    if (Y >= ItemTop(Index)) and (Y < ItemTop(Index + 1)) then
      Exit(Index);
  Result := -1;
end;

procedure TMenuList.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
  Index: LongInt;
  Row: TRectangle;
  Item: TMenuItem;
  TextColor: TColor;
  Arrow: array[0..2] of TPoint;
  Middle: LongInt;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillRectangle(Canvas, Box, Theme.Face);
  DrawBevel(Canvas, Box, RaisedThemeBevel);
  for Index := 0 to FMenu.Count - 1 do
  begin
    Item := FMenu[Index];
    Row := MakeRectangle(Scaled(2), ItemTop(Index), RectangleWidth(Box) - Scaled(4), ItemTop(Index + 1) - ItemTop(Index));
    if Item.IsSeparator then
    begin
      Middle := Row.Top + RectangleHeight(Row) div 2 - 1;
      DrawHorizontalLine(Canvas, Row.Left + 1, Row.Right - 1, Middle, Theme.Shadow);
      DrawHorizontalLine(Canvas, Row.Left + 1, Row.Right - 1, Middle + 1, Theme.Highlight);
      Continue;
    end;
    TextColor := Theme.FaceText;
    if Index = FHighlighted then
    begin
      FillRectangle(Canvas, Row, Theme.Selection);
      TextColor := Theme.SelectionText;
    end;
    if not Item.Enabled then
      TextColor := Theme.DisabledText;
    if Item.Checked then
      FillEllipse(Canvas, MakeRectangle(Row.Left + Scaled(7), Row.Top + RectangleHeight(Row) div 2 - Scaled(3), Scaled(6),
        Scaled(6)), TextColor);
    DrawTextInBox(Canvas, ControlFace, Item.Text, MakeRectangle(Row.Left + Scaled(CheckColumn), Row.Top,
      RectangleWidth(Row), RectangleHeight(Row)), AlignTextLeft, TextColor);
    DrawTextInBox(Canvas, ControlFace, Item.ShortcutText, MakeRectangle(Row.Left, Row.Top,
      RectangleWidth(Row) - Scaled(ArrowColumn), RectangleHeight(Row)), AlignTextRight, TextColor);
    if Item.Count > 0 then
    begin
      Middle := Row.Top + RectangleHeight(Row) div 2;
      Arrow[0] := MakePoint(Row.Right - Scaled(10), Middle - Scaled(4));
      Arrow[1] := MakePoint(Row.Right - Scaled(10), Middle + Scaled(4));
      Arrow[2] := MakePoint(Row.Right - Scaled(6), Middle);
      FillPolygon(Canvas, Arrow, TextColor);
    end;
  end;
end;

procedure TMenuList.Highlight(Index: LongInt);
begin
  if Index = FHighlighted then
    Exit;
  CloseSubmenu;
  FHighlighted := Index;
  Invalidate;
  if (Index >= 0) and FMenu[Index].Enabled and (FMenu[Index].Count > 0) then
    OpenSubmenu;
end;

procedure TMenuList.OpenSubmenu;
var
  Window: TControlWindow;
begin
  if (FHighlighted < 0) or (FSubmenu <> nil) then
    Exit;
  Window := FPopup.OwnerWindow;
  FSubmenu := OpenMenuList(Window, FMenu[FHighlighted],
    FPopup.ScreenLeft + Unscaled(RectangleWidth(PixelBounds)) - 4,
    FPopup.ScreenTop + Unscaled(ItemTop(FHighlighted)) - 2);
  FSubmenu.FParentList := Self;
  FSubmenu.FMenuBar := FMenuBar;
  FSubmenu.FOnChoose := FOnChoose;
end;

procedure TMenuList.CloseSubmenu;
var
  Submenu: TMenuList;
begin
  if FSubmenu = nil then
    Exit;
  Submenu := FSubmenu;
  FSubmenu := nil;
  Submenu.CloseSubmenu;
  Submenu.FParentList := nil;
  Submenu.FPopup.Dismiss;
  { This menu has the pointer again. }
  FPopup.Popup;
  SetFocus;
end;

procedure TMenuList.CloseAll;
var
  List: TMenuList;
begin
  List := Self;
  while List.FParentList <> nil do
    List := List.FParentList;
  List.CloseSubmenu;
  if List.FMenuBar <> nil then
    List.FMenuBar.OpenMenu(-1)
  else
    List.FPopup.Dismiss;
end;

procedure TMenuList.Choose(Item: TMenuItem);
var
  OnChoose: TMenuItemEvent;
begin
  if Item.IsSeparator or not Item.Enabled or (Item.Count > 0) then
    Exit;
  OnChoose := FOnChoose;
  CloseAll;
  if Assigned(Item.OnClick) then
    Item.OnClick(Item);
  if Assigned(OnChoose) then
    OnChoose(Item);
end;

{ The pointer at (X, Y) of this list: if it is over a parent menu or the
  menu bar instead, they act on it. True if one did. }
function TMenuList.PassOn(X, Y: LongInt; Pressed: Boolean): Boolean;
var
  ScreenX: LongInt;
  ScreenY: LongInt;
  List: TMenuList;
  Bar: TMenuBar;
  BarWindow: TControlWindow;
  LocalX: LongInt;
  LocalY: LongInt;
begin
  Result := False;
  ScreenX := Scaled(FPopup.ScreenLeft) + X;
  ScreenY := Scaled(FPopup.ScreenTop) + Y;
  List := FParentList;
  while List <> nil do
  begin
    LocalX := ScreenX - Scaled(List.FPopup.ScreenLeft);
    LocalY := ScreenY - Scaled(List.FPopup.ScreenTop);
    if List.FPopup.ContainsPixel(LocalX, LocalY) then
    begin
      if List.ItemAt(LocalY) <> List.FHighlighted then
        List.Highlight(List.ItemAt(LocalY));
      Exit(True);
    end;
    List := List.FParentList;
  end;
  Bar := FMenuBar;
  if Bar = nil then
    Exit;
  BarWindow := FPopup.OwnerWindow;
  LocalX := ScreenX - Scaled(BarWindow.ScreenLeft) - Bar.PixelBounds.Left;
  LocalY := ScreenY - Scaled(BarWindow.ScreenTop) - Bar.PixelBounds.Top;
  if (LocalY >= 0) and (LocalY < RectangleHeight(Bar.PixelBounds)) and (Bar.HeadingAt(LocalX) >= 0) then
  begin
    if Pressed or (Bar.HeadingAt(LocalX) <> Bar.FOpenIndex) then
      Bar.OpenMenu(Bar.HeadingAt(LocalX));
    Exit(True);
  end;
end;

procedure TMenuList.PointerMove(X, Y: LongInt; Buttons: LongWord);
begin
  if FPopup.ContainsPixel(X, Y) then
    Highlight(ItemAt(Y))
  else
    PassOn(X, Y, False);
end;

procedure TMenuList.PointerDown(X, Y: LongInt; Button: LongWord);
begin
  if not FPopup.ContainsPixel(X, Y) and not PassOn(X, Y, True) then
    CloseAll;
end;

procedure TMenuList.PointerUp(X, Y: LongInt; Button: LongWord);
var
  Index: LongInt;
begin
  if not FPopup.ContainsPixel(X, Y) then
    Exit;
  Index := ItemAt(Y);
  if Index >= 0 then
    Choose(FMenu[Index]);
end;

function TMenuList.KeyDown(Code, Character, Modifiers: LongWord): Boolean;
var
  Index: LongInt;
  Step: LongInt;
  Tries: LongInt;
begin
  Result := True;
  Step := 0;
  case Code of
    KeyArrowUp: Step := -1;
    KeyArrowDown: Step := 1;
    KeyEscape:
      if FParentList <> nil then
        FParentList.CloseSubmenu
      else
        CloseAll;
    KeyArrowRight:
      if (FHighlighted >= 0) and (FMenu[FHighlighted].Count > 0) then
      begin
        OpenSubmenu;
        if FSubmenu <> nil then
          FSubmenu.Highlight(0);
      end
      else if FMenuBar <> nil then
        FMenuBar.OpenMenu((FMenuBar.FOpenIndex + 1) mod FMenuBar.FMenu.Count);
    KeyArrowLeft:
      if FParentList <> nil then
        FParentList.CloseSubmenu
      else if FMenuBar <> nil then
        FMenuBar.OpenMenu((FMenuBar.FOpenIndex + FMenuBar.FMenu.Count - 1) mod FMenuBar.FMenu.Count);
  else
    if IsEnterKey(Code) and (FHighlighted >= 0) then
      Choose(FMenu[FHighlighted])
    else
      Result := False;
  end;
  if Step = 0 then
    Exit;
  { The next item that is not a separator. }
  Index := FHighlighted;
  for Tries := 1 to FMenu.Count do
  begin
    Index := (Index + Step + FMenu.Count) mod FMenu.Count;
    if not FMenu[Index].IsSeparator then
      Break;
  end;
  Highlight(Index);
end;

{ --- TMenuBar ------------------------------------------------------------------------ }

constructor TMenuBar.Create(AParent: TControl);
begin
  inherited Create(AParent);
  FMenu := TMenuItem.Create('');
  FOpenIndex := -1;
  SetBounds(0, 0, 0, Theme.MenuBarHeight);
  Align := AlignTop;
end;

destructor TMenuBar.Destroy;
begin
  OpenMenu(-1);
  FMenu.Free;
  inherited Destroy;
end;

function TMenuBar.HeadingWidth(Index: LongInt): LongInt;
begin
  Result := TextWidth(ControlFace, FMenu[Index].Text) + Scaled(14);
end;

function TMenuBar.HeadingLeft(Index: LongInt): LongInt;
var
  Position: LongInt;
begin
  Result := Scaled(2);
  for Position := 0 to Index - 1 do
    Result := Result + HeadingWidth(Position);
end;

function TMenuBar.HeadingAt(X: LongInt): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to FMenu.Count - 1 do
    if (X >= HeadingLeft(Index)) and (X < HeadingLeft(Index) + HeadingWidth(Index)) then
      Exit(Index);
  Result := -1;
end;

procedure TMenuBar.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
  Index: LongInt;
  Heading: TRectangle;
  TextColor: TColor;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillRectangle(Canvas, Box, Theme.Face);
  for Index := 0 to FMenu.Count - 1 do
  begin
    Heading := MakeRectangle(HeadingLeft(Index), 1, HeadingWidth(Index), RectangleHeight(Box) - 2);
    TextColor := Theme.FaceText;
    if Index = FOpenIndex then
    begin
      FillRectangle(Canvas, Heading, Theme.Selection);
      TextColor := Theme.SelectionText;
    end;
    if not FMenu[Index].Enabled then
      TextColor := Theme.DisabledText;
    DrawTextInBox(Canvas, ControlFace, FMenu[Index].Text, Heading, AlignTextCenter, TextColor);
  end;
end;

procedure TMenuBar.OpenMenu(Index: LongInt);
var
  Window: TControlWindow;
begin
  if FOpenList <> nil then
  begin
    FOpenList.CloseSubmenu;
    FOpenList.FPopup.Dismiss;
    FOpenList := nil;
  end;
  FOpenIndex := -1;
  if (Index >= 0) and (Index < FMenu.Count) and FMenu[Index].Enabled and (FMenu[Index].Count > 0) then
  begin
    Window := TControlWindow(Host.OwnerWindow);
    FOpenIndex := Index;
    FOpenList := OpenMenuList(Window, FMenu[Index],
      Window.ScreenLeft + Unscaled(PixelBounds.Left + HeadingLeft(Index)),
      Window.ScreenTop + Unscaled(PixelBounds.Bottom));
    FOpenList.FMenuBar := Self;
    FOpenList.FOnChoose := FOnChoose;
  end;
  Invalidate;
end;

procedure TMenuBar.PointerDown(X, Y: LongInt; Button: LongWord);
var
  Index: LongInt;
begin
  if Button <> ButtonLeft then
    Exit;
  Index := HeadingAt(X);
  if Index = FOpenIndex then
    OpenMenu(-1)
  else
    OpenMenu(Index);
end;

end.
