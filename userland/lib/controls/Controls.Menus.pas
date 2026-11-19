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
  right (shown only: the window's accelerators do the work, and
  AddItemAccelerator makes one that chooses the item), whether it is
  enabled or checked, a separator, or the head of a submenu (its own
  items); a picture in its check column, of the image list of its menu
  or a menu above it (Images, ImageIndex). Choosing one closes every open menu, then runs its OnClick
  and the OnChoose of whoever opened the menu. A menu's OnOpening runs
  just before it opens (and before an accelerator chooses one of its
  items), for the program to enable and check its items as things are
  now.

  An open menu is a pop-up window holding a TMenuList. Clicking a
  heading of the menu bar opens its menu below it; while one is open,
  pointing at another heading opens that one instead. In a menu the
  pointer highlights, a click chooses, and a submenu opens to the right
  of its item once the pointer has rested on it a moment (SubmenuDelay;
  a click opens it at once). While a submenu is open, the pointer may
  cross its parent's other items on the way to it: moves heading for
  the submenu (inside the triangle from where the pointer was to the
  submenu's near edge) leave it open, and only a pointer that stays on
  another item for SubmenuDelay switches to that one. The arrows move,
  Enter chooses (or opens a submenu), Escape closes one level, Left and
  Right go between submenus and the bar's menus. Only the newest pop-up holds the pointer, so it passes what
  happens over the others (its parents, the menu bar) on to them.

  Items and headings may have mnemonics ("&File", Controls.Text): Alt
  and a heading's letter opens its menu (the window asks the bar like
  any other control), and in an open menu an item's letter, with or
  without Alt, chooses it (or opens its submenu). F10, or Alt pressed
  and let go alone, puts the bar in keyboard mode (the window starts
  it): a heading is picked, Left and Right pick another, Down, Up or
  Enter open its menu with the first item highlighted, a heading's
  letter opens that one, and Escape or Alt again leave. Escape in a
  menu opened from the bar goes back to its heading.
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
  Controls.Popups,
  Controls.ImageList,
  Controls.Timers;

type
  TMenuItem = class;
  TMenuList = class;
  TMenuItemEvent = procedure(Item: TMenuItem) of object;
  TMenuListEvent = procedure(List: TMenuList) of object;

  TMenuItem = class
  private
    FText: string;
    FShortcutText: string;
    FEnabled: Boolean;
    FChecked: Boolean;
    FIsSeparator: Boolean;
    FItems: TList;
    FTag: PtrInt;
    FParent: TMenuItem;
    FOnClick: TMenuItemEvent;
    FOnOpening: TMenuItemEvent;
    FOnOpened: TMenuListEvent;
    FImages: TImageList;
    FImageIndex: LongInt;
    FSideBand: string;
    function GetItem(Index: LongInt): TMenuItem;
    function GetCount: LongInt;
  public
    constructor Create(const AText: string);
    destructor Destroy; override;
    function Add(const AText: string; AOnClick: TMenuItemEvent = nil; const AShortcutText: string = ''): TMenuItem;
    procedure AddSeparator;
    { The text as shown ("Open..." for "&Open..."). }
    function Caption: string;
    { The image list its picture is in: its menu's, or the nearest one
      above (nil: none). }
    function ImageListOf: TImageList;
    { The text with its mnemonic mark ("&Open..."). }
    property Text: string read FText write FText;
    property ShortcutText: string read FShortcutText write FShortcutText;
    property Enabled: Boolean read FEnabled write FEnabled;
    property Checked: Boolean read FChecked write FChecked;
    property IsSeparator: Boolean read FIsSeparator;
    property Count: LongInt read GetCount;
    property Items[Index: LongInt]: TMenuItem read GetItem; default;
    property Tag: PtrInt read FTag write FTag;
    { The pictures of the items below it, and of theirs unless they have
      their own (shared: the menu does not own it). }
    property Images: TImageList read FImages write FImages;
    { Its picture (-1, the default: none). }
    property ImageIndex: LongInt read FImageIndex write FImageIndex;
    { The menu it is in (nil for the top of a menu bar or pop-up). }
    property Parent: TMenuItem read FParent;
    property OnClick: TMenuItemEvent read FOnClick write FOnClick;
    { Its items are about to show (it is a menu, or a submenu's head). }
    property OnOpening: TMenuItemEvent read FOnOpening write FOnOpening;
    { Its items have just shown, in List's pop-up (where they are on the
      screen is known now). }
    property OnOpened: TMenuListEvent read FOnOpened write FOnOpened;
    { The text of a band down the left of its pop-up, where the theme
      draws one (TTheme.StartMenuBand: Controls.MenuBand); '' (the
      default): none. }
    property SideBand: string read FSideBand write FSideBand;
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
    { Hovering: the item the pointer is on, to be highlighted (and its
      submenu opened) when the timer fires; where the pointer last was
      over this menu (screen pixels). }
    FHoverTimer: TTimer;
    FPendingIndex: LongInt;
    FLastPointerX: LongInt;
    FLastPointerY: LongInt;
    FPointerSeen: Boolean;
    function ItemTop(Index: LongInt): LongInt;
    function ItemAt(Y: LongInt): LongInt;
    procedure Highlight(Index: LongInt);
    procedure HighlightFirst;
    procedure OpenSubmenu;
    procedure PointerOver(LocalY, ScreenX, ScreenY: LongInt);
    procedure PressedOn(LocalY: LongInt);
    procedure PointerLeft;
    procedure StartHoverTimer(Index: LongInt);
    procedure StopHoverTimer;
    procedure HoverTimerFired(Sender: TTimer);
    procedure KeepSubmenu;
    function TowardSubmenu(ScreenX, ScreenY: LongInt): Boolean;
    function ChooseByMnemonic(Character: LongWord): Boolean;
    procedure CloseSubmenu;
    procedure Choose(Item: TMenuItem);
    function PassOn(X, Y: LongInt; Pressed: Boolean): Boolean;
    function PressedOutside(X, Y: LongInt; Button: LongWord): Boolean;
    procedure PointerMovedOutside(X, Y: LongInt);
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerMove(X, Y: LongInt; Buttons: LongWord); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
    function KeyDown(Code, Character, Modifiers: LongWord): Boolean; override;
  public
    destructor Destroy; override;
    { Closes this menu and every one it came from. }
    procedure CloseAll;
    property Menu: TMenuItem read FMenu;
  end;

  TMenuBar = class(TWindowMenuBar)
  private
    FMenu: TMenuItem;
    FOpenIndex: LongInt;
    { The heading picked in keyboard mode while no menu is open; -1 when
      not in keyboard mode. }
    FPickedIndex: LongInt;
    FOpenList: TMenuList;
    FOnChoose: TMenuItemEvent;
    function HeadingAt(X: LongInt): LongInt;
    function HeadingWithMnemonic(Character: LongWord): LongInt;
    function NextHeading(Index, Step: LongInt): LongInt;
    procedure ReturnToHeading;
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    function KeyDown(Code, Character, Modifiers: LongWord): Boolean; override;
  public
    constructor Create(AParent: TControl); override;
    destructor Destroy; override;
    { Opens heading Index's menu (closing any other); -1 closes. }
    procedure OpenMenu(Index: LongInt);
    { The same with its first item highlighted, as the keyboard opens it. }
    procedure OpenMenuWithKeyboard(Index: LongInt);
    procedure EnterMenuMode; override;
    procedure LeaveMenuMode; override;
    function InMenuMode: Boolean; override;
    function MatchesMnemonic(Character: LongWord): Boolean; override;
    procedure ActivateMnemonic(Character: LongWord); override;
    { Where heading Index is across the bar (this control's pixels). }
    function HeadingLeft(Index: LongInt): LongInt;
    function HeadingWidth(Index: LongInt): LongInt;
    { The headings; each heading's items are its menu. }
    property Menu: TMenuItem read FMenu;
    property OnChoose: TMenuItemEvent read FOnChoose write FOnChoose;
  end;

{ The size Menu's items take in a pop-up, and where item Index starts
  in it (logical units): to open one where it fits, above a taskbar. }
procedure MeasurePopupMenu(Menu: TMenuItem; out Width, Height: LongInt);
function PopupMenuItemTop(Menu: TMenuItem; Index: LongInt): LongInt;
{ Opens Menu's items at (Left, Top) of the screen (logical units) for
  Owner: a context menu. }
function ShowPopupMenu(Owner: TControlWindow; Menu: TMenuItem; Left, Top: LongInt;
  OnChoose: TMenuItemEvent = nil): TMenuList;
{ Code with Modifiers (an accelerator of Window) chooses Item, as a click
  on it would, if it is enabled once its menu's OnOpening has run. The
  item must last as long as the window. }
procedure AddItemAccelerator(Window: TControlWindow; Item: TMenuItem; Code, Modifiers: LongWord);

implementation

uses
  Abi.SystemCalls,
  Drawing.Colors,
  Drawing.Bevels,
  Drawing.Shapes,
  Drawing.SmoothShapes,
  Windowing.Theme,
  Windowing.Connection,
  Windowing.Displays,
  Controls.Keys,
  Controls.Icons,
  Controls.Text,
  Controls.MenuBand,
  Controls.Painting;

const
  { Logical units: a pop-up menu's raised edge, inside which its items
    sit Theme.MenuPadding in (the other metrics are the theme's). }
  MenuEdge = 2;
  { Milliseconds the pointer rests on an item before its submenu opens,
    or before it takes over from an open submenu it crossed. }
  SubmenuDelay = 350;

{ --- TMenuItem ------------------------------------------------------------------ }

constructor TMenuItem.Create(const AText: string);
begin
  inherited Create;
  FText := AText;
  FEnabled := True;
  FImageIndex := -1;
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
  Result.FParent := Self;
  FItems.Add(Result);
end;

function TMenuItem.Caption: string;
begin
  Result := TextWithoutMnemonic(FText);
end;

function TMenuItem.ImageListOf: TImageList;
var
  Menu: TMenuItem;
begin
  Menu := FParent;
  while Menu <> nil do
  begin
    if Menu.FImages <> nil then
      Exit(Menu.FImages);
    Menu := Menu.FParent;
  end;
  Result := nil;
end;

procedure TMenuItem.AddSeparator;
var
  Separator: TMenuItem;
begin
  Separator := TMenuItem.Create('');
  Separator.FIsSeparator := True;
  Separator.FParent := Self;
  FItems.Add(Separator);
end;

{ --- Opening menus ------------------------------------------------------------------ }

{ Logical units. }
function ItemHeightOf(Item: TMenuItem): LongInt;
begin
  if Item.IsSeparator then
    Result := Theme.MenuSeparatorHeight
  else
    Result := Theme.MenuItemHeight;
end;

{ Logical units from a pop-up menu's edge to its items. }
function MenuInset: LongInt;
begin
  Result := MenuEdge + Theme.MenuPadding;
end;

{ The width of the band down Menu's pop-up (logical units; 0: none). }
function SideBandWidth(Menu: TMenuItem): LongInt;
begin
  if (Menu.SideBand <> '') and Theme.StartMenuBand then
    Result := Theme.StartMenuBandWidth
  else
    Result := 0;
end;

procedure MeasurePopupMenu(Menu: TMenuItem; out Width, Height: LongInt);
var
  Index: LongInt;
  TextPart: LongInt;
  ShortcutPart: LongInt;
  Measured: LongInt;
begin
  TextPart := 0;
  ShortcutPart := 0;
  Height := 2 * MenuInset;
  for Index := 0 to Menu.Count - 1 do
  begin
    Height := Height + ItemHeightOf(Menu[Index]);
    Measured := Unscaled(MnemonicTextWidth(ControlFace, Menu[Index].Text));
    if Measured > TextPart then
      TextPart := Measured;
    Measured := Unscaled(TextWidth(ControlFace, Menu[Index].ShortcutText));
    if Measured > ShortcutPart then
      ShortcutPart := Measured;
  end;
  if ShortcutPart > 0 then
    ShortcutPart := Theme.MenuShortcutGap + ShortcutPart;
  Width := 2 * MenuInset + Theme.MenuIconColumnWidth + Theme.MenuTextGap + TextPart + ShortcutPart +
    Theme.MenuArrowColumnWidth + SideBandWidth(Menu);
end;

function PopupMenuItemTop(Menu: TMenuItem; Index: LongInt): LongInt;
var
  Position: LongInt;
begin
  Result := MenuInset;
  for Position := 0 to Index - 1 do
    Result := Result + ItemHeightOf(Menu[Position]);
end;

{ A menu list in a new pop-up at (Left, Top) of the screen, logical. }
function OpenMenuList(Owner: TControlWindow; Menu: TMenuItem; Left, Top: LongInt): TMenuList;
var
  Width: LongInt;
  Height: LongInt;
  Popup: TPopupWindow;
  Band: TMenuBand;
begin
  if Assigned(Menu.OnOpening) then
    Menu.OnOpening(Menu);
  MeasurePopupMenu(Menu, Width, Height);
  { Kept on the display it opens on. }
  KeepOnDisplay(Left, Top, Width, Height);
  Popup := TPopupWindow.CreatePopup(Owner, Left, Top, Width, Height);
  if SideBandWidth(Menu) > 0 then
  begin
    Band := TMenuBand.Create(Popup.Root);
    Band.Text := Menu.SideBand;
    Band.Align := AlignLeft;
    Band.SetBounds(0, 0, SideBandWidth(Menu), Height);
  end;
  Result := TMenuList.Create(Popup.Root);
  Result.Align := AlignClient;
  Result.CanFocus := True;
  Result.FMenu := Menu;
  Result.FPopup := Popup;
  Result.FHighlighted := -1;
  Result.FPendingIndex := -1;
  Popup.OnPressedOutside := @Result.PressedOutside;
  Popup.OnPointerMovedOutside := @Result.PointerMovedOutside;
  Result.SetFocus;
  Popup.Popup;
  if Assigned(Menu.OnOpened) then
    Menu.OnOpened(Result);
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
  Result := Scaled(MenuInset);
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
  ArrowMiddle: LongInt;
  Pictures: TImageList;
  Picture: TRectangle;
  Size: LongInt;
  State: TImageDrawState;
  Inset: LongInt;
  IconColumn: LongInt;
  ColumnRight: LongInt;
  TextLeft: LongInt;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillRectangle(Canvas, Box, Theme.Face);
  DrawRaisedBevel(Canvas, Box);
  Inset := Scaled(MenuInset);
  IconColumn := Scaled(Theme.MenuIconColumnWidth);
  ColumnRight := Inset + IconColumn;
  TextLeft := ColumnRight + Scaled(Theme.MenuTextGap);
  if Theme.MenuIconColumnShown then
  begin
    { The icon column, shaded, with an etched line beside it. }
    FillRectangle(Canvas, MakeRectangle(BevelWidth, BevelWidth, ColumnRight - BevelWidth,
      RectangleHeight(Box) - 2 * BevelWidth), Theme.MenuIconColumn);
    DrawEtchedVerticalLine(Canvas, ColumnRight - BevelLine, BevelWidth, RectangleHeight(Box) - BevelWidth);
  end;
  for Index := 0 to FMenu.Count - 1 do
  begin
    Item := FMenu[Index];
    Row := MakeRectangle(Inset, ItemTop(Index), RectangleWidth(Box) - 2 * Inset, ItemTop(Index + 1) - ItemTop(Index));
    if Item.IsSeparator then
    begin
      { A groove in the middle of its row: under the text, past the icon
        column where there is one. }
      Middle := Row.Top + (RectangleHeight(Row) - BevelWidth) div 2;
      if Theme.MenuIconColumnShown then
        DrawEtchedHorizontalLine(Canvas, TextLeft - Scaled(Theme.MenuTextGap div 2), Row.Right, Middle)
      else
        DrawEtchedHorizontalLine(Canvas, Row.Left, Row.Right, Middle);
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
    Pictures := Item.ImageListOf;
    if (Pictures <> nil) and Pictures.ValidIndex(Item.ImageIndex) then
    begin
      Size := Scaled(SmallIconSize);
      if Size > RectangleHeight(Row) - 2 then
        Size := RectangleHeight(Row) - 2;
      Picture := MakeRectangle(Row.Left + (IconColumn - Size) div 2, Row.Top + (RectangleHeight(Row) - Size) div 2,
        Size, Size);
      State := ImageDrawNormal;
      if not Item.Enabled then
        State := ImageDrawDisabled;
      Pictures.DrawInBox(Canvas, Item.ImageIndex, Picture, State);
      { Checked: a frame around its picture. }
      if Item.Checked then
        DrawRectangleOutline(Canvas, InflateRectangle(Picture, Scaled(2)), TextColor);
    end
    else if Item.Checked then
      FillSmoothEllipse(Canvas, MakeRectangle(Row.Left + (IconColumn - Scaled(6)) div 2,
        Row.Top + RectangleHeight(Row) div 2 - Scaled(3), Scaled(6), Scaled(6)), TextColor);
    DrawMnemonicTextInBox(Canvas, ControlFace, Item.Text, MakeRectangle(TextLeft, Row.Top,
      Row.Right - TextLeft, RectangleHeight(Row)), AlignTextLeft, TextColor);
    DrawTextInBox(Canvas, ControlFace, Item.ShortcutText, MakeRectangle(Row.Left, Row.Top,
      RectangleWidth(Row) - Scaled(Theme.MenuArrowColumnWidth), RectangleHeight(Row)), AlignTextRight, TextColor);
    if Item.Count > 0 then
    begin
      { A small triangle in the middle of the arrow column. }
      Middle := Row.Top + RectangleHeight(Row) div 2;
      ArrowMiddle := Row.Right - Scaled(Theme.MenuArrowColumnWidth) div 2;
      Arrow[0] := MakePoint(ArrowMiddle - Scaled(2), Middle - Scaled(4));
      Arrow[1] := MakePoint(ArrowMiddle - Scaled(2), Middle + Scaled(4));
      Arrow[2] := MakePoint(ArrowMiddle + Scaled(2), Middle);
      FillPolygon(Canvas, Arrow, TextColor);
    end;
  end;
end;

{ Highlights item Index (-1: none) at once, closing any submenu open; a
  submenu of its own opens only when asked (OpenSubmenu): the pointer
  resting on it, a click, Right or its letter. }
procedure TMenuList.Highlight(Index: LongInt);
begin
  StopHoverTimer;
  FPendingIndex := Index;
  if Index = FHighlighted then
    Exit;
  CloseSubmenu;
  FHighlighted := Index;
  Invalidate;
end;

procedure TMenuList.StartHoverTimer(Index: LongInt);
begin
  FPendingIndex := Index;
  if FHoverTimer = nil then
  begin
    FHoverTimer := TTimer.Create(FPopup);
    FHoverTimer.OnTimer := @HoverTimerFired;
  end;
  FHoverTimer.Interval := SubmenuDelay;
  FHoverTimer.Start;
end;

procedure TMenuList.StopHoverTimer;
begin
  if FHoverTimer <> nil then
    FHoverTimer.Stop;
end;

{ The pointer rested: the item it is on is highlighted, and its submenu
  opens. }
procedure TMenuList.HoverTimerFired(Sender: TTimer);
var
  Index: LongInt;
begin
  StopHoverTimer;
  { Closed meanwhile (it waits to be freed). }
  if FPopup.Closing then
    Exit;
  Index := FPendingIndex;
  if Index <> FHighlighted then
    Highlight(Index);
  if (Index >= 0) and FMenu[Index].Enabled and (FMenu[Index].Count > 0) then
    OpenSubmenu;
end;

{ The pointer went into this menu's open submenu: what it crossed on the
  way is forgotten and the submenu's item stays highlighted, up through
  the menus this one came from. }
procedure TMenuList.KeepSubmenu;
begin
  if FSubmenu <> nil then
  begin
    StopHoverTimer;
    FPendingIndex := FHighlighted;
  end;
  if FParentList <> nil then
    FParentList.KeepSubmenu;
end;

{ Whether the pointer, moving from where it last was over this menu to
  (ScreenX, ScreenY), is heading for the open submenu: inside the
  triangle from its last place to the submenu's near edge. Screen
  pixels. }
function TMenuList.TowardSubmenu(ScreenX, ScreenY: LongInt): Boolean;
var
  EdgeX: LongInt;
  TopY: LongInt;
  BottomY: LongInt;
  SubmenuLeft: LongInt;
  Side1: Int64;
  Side2: Int64;
  Side3: Int64;

  function Cross(AX, AY, BX, BY, CX, CY: LongInt): Int64;
  begin
    Result := Int64(BX - AX) * (CY - AY) - Int64(BY - AY) * (CX - AX);
  end;

begin
  Result := False;
  if (FSubmenu = nil) or not FPointerSeen then
    Exit;
  if (ScreenX = FLastPointerX) and (ScreenY = FLastPointerY) then
    Exit;
  SubmenuLeft := Scaled(FSubmenu.FPopup.ScreenLeft);
  { The submenu's side facing this menu (it opens to the right unless
    there is no room), a little longer than the submenu, so a pointer
    aiming at its first or last item still counts. }
  if SubmenuLeft >= FLastPointerX then
    EdgeX := SubmenuLeft
  else
    EdgeX := SubmenuLeft + FSubmenu.FPopup.PixelWidth;
  TopY := Scaled(FSubmenu.FPopup.ScreenTop) - Scaled(4);
  BottomY := Scaled(FSubmenu.FPopup.ScreenTop) + FSubmenu.FPopup.PixelHeight + Scaled(4);
  Side1 := Cross(FLastPointerX, FLastPointerY, EdgeX, TopY, ScreenX, ScreenY);
  Side2 := Cross(EdgeX, TopY, EdgeX, BottomY, ScreenX, ScreenY);
  Side3 := Cross(EdgeX, BottomY, FLastPointerX, FLastPointerY, ScreenX, ScreenY);
  Result := ((Side1 >= 0) and (Side2 >= 0) and (Side3 >= 0)) or ((Side1 <= 0) and (Side2 <= 0) and (Side3 <= 0));
end;

{ The pointer moved to (ScreenX, ScreenY), over this menu at LocalY of
  this list. }
procedure TMenuList.PointerOver(LocalY, ScreenX, ScreenY: LongInt);
var
  Index: LongInt;
  Toward: Boolean;
begin
  Index := ItemAt(LocalY);
  if (Index >= 0) and FMenu[Index].IsSeparator then
    Index := -1;
  Toward := TowardSubmenu(ScreenX, ScreenY);
  FLastPointerX := ScreenX;
  FLastPointerY := ScreenY;
  FPointerSeen := True;
  if FSubmenu <> nil then
  begin
    if Index = FHighlighted then
    begin
      { Back on the submenu's own item. }
      StopHoverTimer;
      FPendingIndex := FHighlighted;
    end
    else if Toward then
      { On the way to the submenu: it stays, unless the pointer rests
        here. }
      StartHoverTimer(Index)
    else if Index >= 0 then
    begin
      Highlight(Index);
      if FMenu[Index].Enabled and (FMenu[Index].Count > 0) then
        StartHoverTimer(Index);
    end
    else if FPendingIndex <> FHighlighted then
    begin
      StopHoverTimer;
      FPendingIndex := FHighlighted;
    end;
    Exit;
  end;
  if Index <> FHighlighted then
    Highlight(Index);
  if (Index >= 0) and FMenu[Index].Enabled and (FMenu[Index].Count > 0) and
     ((FHoverTimer = nil) or not FHoverTimer.Enabled) then
    StartHoverTimer(Index);
end;

{ A press at LocalY of this list (a menu a submenu came from): its item
  is highlighted, and its submenu opened, at once. }
procedure TMenuList.PressedOn(LocalY: LongInt);
var
  Index: LongInt;
begin
  Index := ItemAt(LocalY);
  if (Index >= 0) and FMenu[Index].IsSeparator then
    Index := -1;
  Highlight(Index);
  if (Index >= 0) and FMenu[Index].Enabled and (FMenu[Index].Count > 0) then
    OpenSubmenu;
end;

{ The pointer is over no menu: nothing is highlighted, unless a submenu
  is open (its item stays). }
procedure TMenuList.PointerLeft;
begin
  FPointerSeen := False;
  if FSubmenu = nil then
    Highlight(-1)
  else if FPendingIndex <> FHighlighted then
  begin
    StopHoverTimer;
    FPendingIndex := FHighlighted;
  end;
end;

{ The first item that can be chosen (or the first that is not a line). }
procedure TMenuList.HighlightFirst;
var
  Index: LongInt;
begin
  for Index := 0 to FMenu.Count - 1 do
    if not FMenu[Index].IsSeparator and FMenu[Index].Enabled then
    begin
      Highlight(Index);
      Exit;
    end;
  for Index := 0 to FMenu.Count - 1 do
    if not FMenu[Index].IsSeparator then
    begin
      Highlight(Index);
      Exit;
    end;
end;

procedure TMenuList.OpenSubmenu;
var
  Window: TControlWindow;
begin
  if (FHighlighted < 0) or (FSubmenu <> nil) then
    Exit;
  StopHoverTimer;
  FPendingIndex := FHighlighted;
  Window := FPopup.OwnerWindow;
  { Over this menu's edge, its first item level with this one. }
  FSubmenu := OpenMenuList(Window, FMenu[FHighlighted],
    FPopup.ScreenLeft + Unscaled(PixelBounds.Right) - MenuInset,
    FPopup.ScreenTop + Unscaled(ItemTop(FHighlighted)) - MenuInset);
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
  Submenu.FMenuBar := nil;
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
  ScreenX := Scaled(FPopup.ScreenLeft) + PixelBounds.Left + X;
  ScreenY := Scaled(FPopup.ScreenTop) + Y;
  List := FParentList;
  while List <> nil do
  begin
    LocalX := ScreenX - Scaled(List.FPopup.ScreenLeft);
    LocalY := ScreenY - Scaled(List.FPopup.ScreenTop);
    if List.FPopup.ContainsPixel(LocalX, LocalY) then
    begin
      if Pressed then
        List.PressedOn(LocalY)
      else
        List.PointerOver(LocalY, ScreenX, ScreenY);
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
    { A press on the open menu's own heading closes it, as a press on
      a closed heading would open it. }
    if Pressed and (Bar.HeadingAt(LocalX) = Bar.FOpenIndex) then
      Bar.OpenMenu(-1)
    else if Pressed or (Bar.HeadingAt(LocalX) <> Bar.FOpenIndex) then
      Bar.OpenMenu(Bar.HeadingAt(LocalX));
    Exit(True);
  end;
end;

procedure TMenuList.PointerMove(X, Y: LongInt; Buttons: LongWord);
begin
  if FPopup.ContainsPixel(X, Y) then
  begin
    { In this menu: the menus it came from keep it open. }
    if FParentList <> nil then
      FParentList.KeepSubmenu;
    PointerOver(Y, Scaled(FPopup.ScreenLeft) + PixelBounds.Left + X, Scaled(FPopup.ScreenTop) + Y);
  end
  else if not PassOn(X, Y, False) then
    PointerLeft;
end;

{ A press outside the menu: on a menu it came from or a heading of its
  menu bar it goes there, anywhere else it closes every menu. Either
  way the menus close through the menu bar or the menu that opened
  them, which forget them; left to itself the pop-up would be freed
  while they still pointed at it. }
function TMenuList.PressedOutside(X, Y: LongInt; Button: LongWord): Boolean;
begin
  if not PassOn(X, Y, True) then
    CloseAll;
  Result := True;
end;

{ The pointer moved outside the menu, to (X, Y) of its pop-up: over a
  menu it came from or a heading of its menu bar, they act on it. }
procedure TMenuList.PointerMovedOutside(X, Y: LongInt);
begin
  if not PassOn(X - PixelBounds.Left, Y - PixelBounds.Top, False) then
    PointerLeft;
end;

destructor TMenuList.Destroy;
begin
  { However the menu went, nothing may go on pointing at it, and a menu
  opened from it goes too. (A menu closed the usual way was already
  forgotten by the menu bar or menu that opened it.) }
  if FSubmenu <> nil then
  begin
    FSubmenu.FParentList := nil;
    FSubmenu.FMenuBar := nil;
    FSubmenu.FPopup.Dismiss;
    FSubmenu := nil;
  end;
  if (FParentList <> nil) and (FParentList.FSubmenu = Self) then
    FParentList.FSubmenu := nil;
  if (FMenuBar <> nil) and (FMenuBar.FOpenList = Self) then
  begin
    FMenuBar.FOpenList := nil;
    FMenuBar.FOpenIndex := -1;
    FMenuBar.Invalidate;
  end;
  FHoverTimer.Free;
  inherited Destroy;
end;

procedure TMenuList.PointerUp(X, Y: LongInt; Button: LongWord);
var
  Index: LongInt;
begin
  if not FPopup.ContainsPixel(X, Y) then
    Exit;
  Index := ItemAt(Y);
  if Index < 0 then
    Exit;
  { A click on a submenu's item opens it without waiting. }
  if (FMenu[Index].Count > 0) and FMenu[Index].Enabled and not FMenu[Index].IsSeparator then
  begin
    Highlight(Index);
    OpenSubmenu;
  end
  else
    Choose(FMenu[Index]);
end;

{ The first enabled item whose mnemonic is Character: chosen, or its
  submenu opened with its first item highlighted. False if none. }
function TMenuList.ChooseByMnemonic(Character: LongWord): Boolean;
var
  Index: LongInt;
  Item: TMenuItem;
begin
  for Index := 0 to FMenu.Count - 1 do
  begin
    Item := FMenu[Index];
    if Item.IsSeparator or not Item.Enabled or not MnemonicMatches(Item.Text, Character) then
      Continue;
    if Item.Count > 0 then
    begin
      Highlight(Index);
      OpenSubmenu;
      if FSubmenu <> nil then
        FSubmenu.HighlightFirst;
    end
    else
      Choose(Item);
    Exit(True);
  end;
  Result := False;
end;

function TMenuList.KeyDown(Code, Character, Modifiers: LongWord): Boolean;
var
  Index: LongInt;
  Step: LongInt;
  Tries: LongInt;
  Heading: LongInt;
begin
  Result := True;
  Step := 0;
  case Code of
    KeyArrowUp: Step := -1;
    KeyArrowDown: Step := 1;
    KeyEscape:
      if FParentList <> nil then
        FParentList.CloseSubmenu
      else if FMenuBar <> nil then
        FMenuBar.ReturnToHeading
      else
        CloseAll;
    KeyArrowRight:
      if (FHighlighted >= 0) and (FMenu[FHighlighted].Count > 0) and FMenu[FHighlighted].Enabled then
      begin
        OpenSubmenu;
        if FSubmenu <> nil then
          FSubmenu.HighlightFirst;
      end
      else if FMenuBar <> nil then
        FMenuBar.OpenMenuWithKeyboard(FMenuBar.NextHeading(FMenuBar.FOpenIndex, 1));
    KeyArrowLeft:
      if FParentList <> nil then
        FParentList.CloseSubmenu
      else if FMenuBar <> nil then
        FMenuBar.OpenMenuWithKeyboard(FMenuBar.NextHeading(FMenuBar.FOpenIndex, -1));
  else
    if IsEnterKey(Code) and (FHighlighted >= 0) then
    begin
      { Enter on a submenu's item opens it, as Right does. }
      if (FMenu[FHighlighted].Count > 0) and FMenu[FHighlighted].Enabled then
      begin
        OpenSubmenu;
        if FSubmenu <> nil then
          FSubmenu.HighlightFirst;
      end
      else
        Choose(FMenu[FHighlighted]);
    end
    else
    begin
      { Alt and a heading's letter goes to that heading's menu; a letter
        otherwise picks an item here. }
      Heading := -1;
      if (FMenuBar <> nil) and ((Modifiers and ModifierAlt) <> 0) then
        Heading := FMenuBar.HeadingWithMnemonic(Character);
      if Heading >= 0 then
        FMenuBar.OpenMenuWithKeyboard(Heading)
      else
        Result := ChooseByMnemonic(Character);
    end;
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
  FPickedIndex := -1;
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
  Result := MnemonicTextWidth(ControlFace, FMenu[Index].Text) + Scaled(14);
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
    if (Index = FOpenIndex) or (Index = FPickedIndex) then
    begin
      FillRectangle(Canvas, Heading, Theme.Selection);
      TextColor := Theme.SelectionText;
    end;
    if not FMenu[Index].Enabled then
      TextColor := Theme.DisabledText;
    DrawMnemonicTextInBox(Canvas, ControlFace, FMenu[Index].Text, Heading, AlignTextCenter, TextColor);
  end;
end;

procedure TMenuBar.OpenMenu(Index: LongInt);
var
  Window: TControlWindow;
begin
  if FOpenList <> nil then
  begin
    FOpenList.CloseSubmenu;
    { Freed later (posted): by then it must not point back here. }
    FOpenList.FMenuBar := nil;
    FOpenList.FPopup.Dismiss;
    FOpenList := nil;
  end;
  FOpenIndex := -1;
  FPickedIndex := -1;
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

procedure TMenuBar.OpenMenuWithKeyboard(Index: LongInt);
begin
  OpenMenu(Index);
  if FOpenList <> nil then
    FOpenList.HighlightFirst;
end;

{ The heading Step (1 or -1) along from Index, round the ends, skipping
  disabled ones; Index itself if no other will do. }
function TMenuBar.NextHeading(Index, Step: LongInt): LongInt;
var
  Tries: LongInt;
begin
  Result := Index;
  if FMenu.Count = 0 then
    Exit;
  for Tries := 1 to FMenu.Count do
  begin
    Result := (Result + Step + FMenu.Count) mod FMenu.Count;
    if FMenu[Result].Enabled then
      Exit;
  end;
  Result := Index;
end;

function TMenuBar.HeadingWithMnemonic(Character: LongWord): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to FMenu.Count - 1 do
    if FMenu[Index].Enabled and MnemonicMatches(FMenu[Index].Text, Character) then
      Exit(Index);
  Result := -1;
end;

{ Escape in a menu opened from the bar: the menu closes, its heading
  stays picked. }
procedure TMenuBar.ReturnToHeading;
var
  Index: LongInt;
begin
  Index := FOpenIndex;
  OpenMenu(-1);
  FPickedIndex := Index;
  Invalidate;
end;

procedure TMenuBar.EnterMenuMode;
begin
  if FMenu.Count = 0 then
    Exit;
  OpenMenu(-1);
  { The first enabled heading: the one after the last. }
  FPickedIndex := NextHeading(FMenu.Count - 1, 1);
  Invalidate;
end;

procedure TMenuBar.LeaveMenuMode;
begin
  OpenMenu(-1);
end;

function TMenuBar.InMenuMode: Boolean;
begin
  Result := (FPickedIndex >= 0) or (FOpenIndex >= 0);
end;

function TMenuBar.MatchesMnemonic(Character: LongWord): Boolean;
begin
  Result := HeadingWithMnemonic(Character) >= 0;
end;

procedure TMenuBar.ActivateMnemonic(Character: LongWord);
begin
  OpenMenuWithKeyboard(HeadingWithMnemonic(Character));
end;

{ Keys in keyboard mode with no menu open (the window sends them here;
  an open menu gets them itself). Every key is used: one that means
  nothing here does nothing, as it would in an open menu. }
function TMenuBar.KeyDown(Code, Character, Modifiers: LongWord): Boolean;
var
  Heading: LongInt;
begin
  if FPickedIndex < 0 then
    Exit(False);
  Result := True;
  case Code of
    KeyArrowLeft:
      FPickedIndex := NextHeading(FPickedIndex, -1);
    KeyArrowRight:
      FPickedIndex := NextHeading(FPickedIndex, 1);
    KeyArrowDown, KeyArrowUp:
      OpenMenuWithKeyboard(FPickedIndex);
    KeyEscape:
      LeaveMenuMode;
  else
    if IsEnterKey(Code) then
      OpenMenuWithKeyboard(FPickedIndex)
    else
    begin
      Heading := HeadingWithMnemonic(Character);
      if Heading >= 0 then
        OpenMenuWithKeyboard(Heading);
    end;
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

{ --- Accelerators for items ------------------------------------------------------------ }

type
  { What an accelerator made by AddItemAccelerator runs. }
  TItemAccelerator = class
  public
    Item: TMenuItem;
    procedure Run(Sender: TControlWindow);
  end;

var
  { Every one made, freed when the program ends (an accelerator stays
    with its window for good). }
  ItemAccelerators: TList;

procedure TItemAccelerator.Run(Sender: TControlWindow);
begin
  if (Item.Parent <> nil) and Assigned(Item.Parent.OnOpening) then
    Item.Parent.OnOpening(Item.Parent);
  if Item.Enabled and not Item.IsSeparator and Assigned(Item.OnClick) then
    Item.OnClick(Item);
end;

procedure AddItemAccelerator(Window: TControlWindow; Item: TMenuItem; Code, Modifiers: LongWord);
var
  Accelerator: TItemAccelerator;
begin
  if ItemAccelerators = nil then
    ItemAccelerators := TList.Create;
  Accelerator := TItemAccelerator.Create;
  Accelerator.Item := Item;
  ItemAccelerators.Add(Accelerator);
  Window.AddAccelerator(Code, Modifiers, @Accelerator.Run);
end;

procedure FreeItemAccelerators;
var
  Index: LongInt;
begin
  if ItemAccelerators = nil then
    Exit;
  for Index := 0 to ItemAccelerators.Count - 1 do
    TItemAccelerator(ItemAccelerators[Index]).Free;
  ItemAccelerators.Free;
end;

finalization
  FreeItemAccelerators;
end.
