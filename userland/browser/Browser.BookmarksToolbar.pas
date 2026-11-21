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
  The bookmarks toolbar's items: what is in the Bookmarks Toolbar
  folder, a flat button each (a page's icon and its name cut to fit; a
  folder opens a menu of what it holds; separators as lines), lit
  under the pointer; what does not fit is in a ">>" menu at the end.

  A click opens a bookmark (a middle click or Ctrl+click in a new tab);
  a right click offers Open, Open in a New Tab, Open in a New Window,
  Open All in Tabs (a folder), New Bookmark..., New Folder..., New
  Separator, Delete and Properties.... Dragging an address onto the bar
  (the location bar's site button, or text) bookmarks it there; a
  bookmark dragged along the bar moves.
}
unit Browser.BookmarksToolbar;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Canvas,
  Drawing.Rectangles,
  Controls.Base,
  Controls.Menus,
  Controls.DragData,
  WebView.Control,
  Browser.Bookmarks;

const
  DragFormatBookmark = 'browser-bookmark';

type
  TBookmarkOpenEvent = procedure(const Url: string; Disposition: TLinkDisposition) of object;
  { A bookmark, folder or separator to make in Folder at Index (Kind),
    or Node's properties to edit. }
  TBookmarkAddEvent = procedure(Kind: TBookmarkKind; Folder: TBookmarkNode; Index: Integer) of object;
  TBookmarkEditEvent = procedure(Node: TBookmarkNode) of object;
  TBookmarkFolderEvent = procedure(Folder: TBookmarkNode) of object;

  TBookmarksToolbar = class(TControl)
  private
    FStore: TBookmarkStore;
    FHot: Integer;
    FMenu: TMenuItem;
    FMenuNode: TBookmarkNode;
    FMenuIndex: Integer;
    FDropIndex: Integer;
    FPressIndex: Integer;
    FPressX, FPressY: LongInt;
    FOnOpen: TBookmarkOpenEvent;
    FOnAdd: TBookmarkAddEvent;
    FOnEdit: TBookmarkEditEvent;
    FOnOpenAll: TBookmarkFolderEvent;
    function Folder: TBookmarkNode;
    function ItemWidth(Index: Integer): LongInt;
    function ItemBox(Index: Integer): TRectangle;
    function ShownCount: Integer;
    function ChevronBox: TRectangle;
    function ItemAt(X, Y: LongInt): Integer;
    function DropIndexAt(X: LongInt): Integer;
    procedure OpenFolderMenu(Index: Integer);
    procedure OpenChevronMenu;
    procedure FolderItemChosen(Item: TMenuItem);
    procedure ContextChosen(Item: TMenuItem);
    procedure SetDropIndex(Value: Integer);
    procedure ShowMenuAt(Menu: TMenuItem; const Box: TRectangle);
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerMove(X, Y: LongInt; Buttons: LongWord); override;
    procedure PointerLeave; override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
    procedure ContextMenu(X, Y: LongInt; FromKeyboard: Boolean); override;
    function DragOver(Data: TDragData; X, Y: LongInt; Modifiers: LongWord): TDropEffect; override;
    procedure DragLeave; override;
    procedure DragDrop(Data: TDragData; X, Y: LongInt; Effect: TDropEffect); override;
  public
    constructor CreateFor(AParent: TControl; Store: TBookmarkStore);
    destructor Destroy; override;
    function PreferredSize: TSize; override;
    function HintAt(X, Y: LongInt; out Area: TRectangle): string; override;
    procedure BookmarksChanged;
    property OnOpen: TBookmarkOpenEvent read FOnOpen write FOnOpen;
    property OnAdd: TBookmarkAddEvent read FOnAdd write FOnAdd;
    property OnEdit: TBookmarkEditEvent read FOnEdit write FOnEdit;
    property OnOpenAll: TBookmarkFolderEvent read FOnOpenAll write FOnOpenAll;
  end;

{ The address and title a drag carries (a page link, a bookmark's id
  resolved by the caller, or text); False if none. }
function DraggedLink(Data: TDragData; out Url, Title: string): Boolean;

implementation

uses
  Windowing.Windows,
  SysUtils,
  DateUtils,
  Math,
  Abi.SystemCalls,
  Drawing.Colors,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Window,
  Controls.Text,
  Controls.Painting,
  Controls.IconTheme,
  Controls.LayoutRules,
  Browser.BookmarkMenus,
  Browser.LocationBar;

const
  BarHeight = 24;
  MaximumItemWidth = 160;
  ItemPadding = 6;
  IconSize = 16;
  SeparatorWidth = 8;
  ChevronWidth = 18;
  DragThreshold = 4;
  { Context menu commands. }
  ContextOpen = 1;
  ContextOpenTab = 2;
  ContextOpenWindow = 3;
  ContextOpenAll = 4;
  ContextNewBookmark = 5;
  ContextNewFolder = 6;
  ContextNewSeparator = 7;
  ContextDelete = 8;
  ContextProperties = 9;

function DraggedLink(Data: TDragData; out Url, Title: string): Boolean;
var
  Lines: TStringArray;
begin
  Url := '';
  Title := '';
  if Data.Format = DragFormatPageLink then
  begin
    Lines := Data.Text.Split([#10]);
    if Length(Lines) > 0 then
      Url := Lines[0];
    if Length(Lines) > 1 then
      Title := Lines[1];
  end
  else if Data.Format = DragFormatText then
  begin
    Url := Trim(Data.Text);
    if (Pos(#10, Url) > 0) or (Pos(' ', Url) > 0) or (Pos('://', Url) = 0) then
      Url := '';
  end;
  Result := Url <> '';
end;

constructor TBookmarksToolbar.CreateFor(AParent: TControl; Store: TBookmarkStore);
begin
  inherited Create(AParent);
  FStore := Store;
  FHot := -1;
  FDropIndex := -1;
  FPressIndex := -1;
  FMenu := TMenuItem.Create('');
  SetBounds(0, 0, 400, BarHeight);
end;

destructor TBookmarksToolbar.Destroy;
begin
  FMenu.Free;
  inherited Destroy;
end;

function TBookmarksToolbar.Folder: TBookmarkNode;
begin
  Result := FStore.ToolbarFolder;
end;

function TBookmarksToolbar.PreferredSize: TSize;
begin
  Result := MakeSize(100, BarHeight);
end;

procedure TBookmarksToolbar.BookmarksChanged;
begin
  FHot := -1;
  Invalidate;
end;

{ Pixels. }
function TBookmarksToolbar.ItemWidth(Index: Integer): LongInt;
var
  Node: TBookmarkNode;
begin
  Node := Folder[Index];
  if Node.Kind = BookmarkSeparator then
    Exit(Scaled(SeparatorWidth));
  Result := Min(Scaled(MaximumItemWidth), TextWidth(ControlFace, Node.ShownTitle) + Scaled(IconSize + 3 *
    ItemPadding));
  if Node.IsFolder then
    Inc(Result, Scaled(10));
end;

function TBookmarksToolbar.ItemBox(Index: Integer): TRectangle;
var
  Left, Item: Integer;
begin
  Left := Scaled(2);
  for Item := 0 to Index - 1 do
    Inc(Left, ItemWidth(Item) + Scaled(1));
  Result := MakeRectangle(Left, Scaled(1), ItemWidth(Index), RectangleHeight(PixelBounds) - Scaled(2));
end;

function TBookmarksToolbar.ChevronBox: TRectangle;
var
  Width: LongInt;
begin
  Width := RectangleWidth(PixelBounds);
  Result := MakeRectangle(Width - Scaled(ChevronWidth), Scaled(1), Scaled(ChevronWidth),
    RectangleHeight(PixelBounds) - Scaled(2));
end;

{ The items that fit before the ">>" (all if they all fit). }
function TBookmarksToolbar.ShownCount: Integer;
var
  Room, Right, Index: Integer;
begin
  Room := RectangleWidth(PixelBounds);
  Right := Scaled(2);
  for Index := 0 to Folder.Count - 1 do
  begin
    Inc(Right, ItemWidth(Index) + Scaled(1));
    if Right > Room then
    begin
      { Not all fit: leave room for the chevron. }
      Right := Scaled(2);
      Result := 0;
      while (Result < Folder.Count) and (Right + ItemWidth(Result) <= Room - Scaled(ChevronWidth)) do
      begin
        Inc(Right, ItemWidth(Result) + Scaled(1));
        Inc(Result);
      end;
      Exit;
    end;
  end;
  Result := Folder.Count;
end;

function TBookmarksToolbar.ItemAt(X, Y: LongInt): Integer;
var
  Index: Integer;
begin
  for Index := 0 to ShownCount - 1 do
    if RectangleContainsPoint(ItemBox(Index), X, Y) then
      Exit(Index);
  if (ShownCount < Folder.Count) and RectangleContainsPoint(ChevronBox, X, Y) then
    Exit(-2);
  Result := -1;
end;

function TBookmarksToolbar.DropIndexAt(X: LongInt): Integer;
var
  Index: Integer;
  Box: TRectangle;
begin
  for Index := 0 to ShownCount - 1 do
  begin
    Box := ItemBox(Index);
    if X < (Box.Left + Box.Right) div 2 then
      Exit(Index);
  end;
  Result := ShownCount;
end;

procedure TBookmarksToolbar.Paint(var Canvas: TCanvas);
var
  Index, Size, Shown: Integer;
  Box, IconBox, TextBox: TRectangle;
  Node: TBookmarkNode;
  X: LongInt;
begin
  Size := Scaled(IconSize);
  Shown := ShownCount;
  if Folder.Count = 0 then
    DrawTextInBox(Canvas, ControlFace, 'Drag a page''s icon from the location bar here to bookmark it',
      MakeRectangle(Scaled(6), 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds)), AlignTextLeft,
      Theme.DisabledText);
  for Index := 0 to Shown - 1 do
  begin
    Node := Folder[Index];
    Box := ItemBox(Index);
    if Node.Kind = BookmarkSeparator then
    begin
      DrawEtchedVerticalLine(Canvas, (Box.Left + Box.Right) div 2, Box.Top + Scaled(3), Box.Bottom - Scaled(3));
      Continue;
    end;
    if Index = FHot then
    begin
      FillRectangle(Canvas, Box, Theme.HotButtonFace);
      DrawRaisedEdge(Canvas, Box);
    end;
    IconBox := MakeRectangle(Box.Left + Scaled(ItemPadding), Box.Top + (RectangleHeight(Box) - Size) div 2, Size, Size);
    if Node.IsFolder then
      DrawThemeIcon(Canvas, 'folder', IconBox)
    else
      DrawThemeIcon(Canvas, 'internet', IconBox);
    TextBox := MakeRectangle(IconBox.Right + Scaled(4), Box.Top, Box.Right - IconBox.Right - Scaled(4 + ItemPadding div 2),
      RectangleHeight(Box));
    if Node.IsFolder then
    begin
      Dec(TextBox.Right, Scaled(10));
      DrawArrowGlyph(Canvas, MakeRectangle(TextBox.Right, Box.Top, Scaled(10), RectangleHeight(Box)), ArrowDown,
        Max(2, Scaled(2)), Theme.FaceText);
    end;
    DrawTextInBox(Canvas, ControlFace, Node.ShownTitle, TextBox, AlignTextLeft, Theme.FaceText);
  end;
  if Shown < Folder.Count then
  begin
    Box := ChevronBox;
    if FHot = -2 then
      FillRectangle(Canvas, Box, Theme.HotButtonFace);
    DrawTextInBox(Canvas, ControlBoldFace, #194#187, Box, AlignTextCenter, Theme.FaceText);
  end;
  if FDropIndex >= 0 then
  begin
    if FDropIndex < Shown then
      X := ItemBox(FDropIndex).Left - Scaled(1)
    else if Shown > 0 then
      X := ItemBox(Shown - 1).Right + Scaled(1)
    else
      X := Scaled(2);
    FillRectangle(Canvas, MakeRectangle(X - Scaled(1), Scaled(2), Max(2, Scaled(2)), RectangleHeight(PixelBounds) -
      Scaled(4)), Theme.Selection);
  end;
end;

procedure TBookmarksToolbar.PointerMove(X, Y: LongInt; Buttons: LongWord);
var
  Index: Integer;
begin
  inherited PointerMove(X, Y, Buttons);
  if (FPressIndex >= 0) and ((Buttons and ButtonLeft) <> 0) and
     ((Abs(X - FPressX) >= Scaled(DragThreshold)) or (Abs(Y - FPressY) >= Scaled(DragThreshold))) then
  begin
    Index := FPressIndex;
    FPressIndex := -1;
    if Folder[Index].Kind = BookmarkItem then
      BeginDrag(TDragData.Create(DragFormatBookmark, IntToStr(Folder[Index].Id), Self))
    else
      BeginDrag(TDragData.Create(DragFormatBookmark, IntToStr(Folder[Index].Id), Self));
    Exit;
  end;
  Index := ItemAt(X, Y);
  if Index <> FHot then
  begin
    FHot := Index;
    Invalidate;
  end;
end;

procedure TBookmarksToolbar.PointerLeave;
begin
  inherited PointerLeave;
  FHot := -1;
  Invalidate;
end;

procedure TBookmarksToolbar.ShowMenuAt(Menu: TMenuItem; const Box: TRectangle);
var
  Window: TControlWindow;
begin
  if (Host = nil) or not (Host.OwnerWindow is TControlWindow) then
    Exit;
  Window := TControlWindow(Host.OwnerWindow);
  ShowPopupMenu(Window, Menu, Window.ScreenLeft + Unscaled(PixelBounds.Left + Box.Left),
    Window.ScreenTop + Unscaled(PixelBounds.Top + Box.Bottom));
end;

procedure TBookmarksToolbar.OpenFolderMenu(Index: Integer);
begin
  FMenu.Clear;
  AddFolderItems(FMenu, Folder[Index], @FolderItemChosen);
  if FMenu.Count = 0 then
    FMenu.Add('(Empty)').Enabled := False;
  ShowMenuAt(FMenu, ItemBox(Index));
end;

procedure TBookmarksToolbar.OpenChevronMenu;
var
  Index: Integer;
  Node: TBookmarkNode;
  Sub: TMenuItem;
begin
  FMenu.Clear;
  for Index := ShownCount to Folder.Count - 1 do
  begin
    Node := Folder[Index];
    case Node.Kind of
      BookmarkSeparator:
        FMenu.AddSeparator;
      BookmarkFolder:
        begin
          Sub := FMenu.Add(MenuCaption(Node.ShownTitle));
          AddFolderItems(Sub, Node, @FolderItemChosen);
        end;
      BookmarkItem:
        FMenu.Add(MenuCaption(Node.ShownTitle), @FolderItemChosen).Tag := Node.Id;
    end;
  end;
  ShowMenuAt(FMenu, ChevronBox);
end;

procedure TBookmarksToolbar.FolderItemChosen(Item: TMenuItem);
var
  Node: TBookmarkNode;
begin
  if Item.Tag < 0 then
  begin
    Node := FStore.NodeById(-Item.Tag);
    if (Node <> nil) and Assigned(FOnOpenAll) then
      FOnOpenAll(Node);
    Exit;
  end;
  Node := FStore.NodeById(Item.Tag);
  if (Node <> nil) and Assigned(FOnOpen) then
    FOnOpen(Node.Url, LinkInView);
end;

procedure TBookmarksToolbar.PointerDown(X, Y: LongInt; Button: LongWord);
var
  Index: Integer;
begin
  FPressIndex := -1;
  Index := ItemAt(X, Y);
  if Button <> ButtonLeft then
    Exit;
  if Index = -2 then
  begin
    OpenChevronMenu;
    Exit;
  end;
  if Index < 0 then
    Exit;
  if Folder[Index].IsFolder then
  begin
    OpenFolderMenu(Index);
    Exit;
  end;
  FPressIndex := Index;
  FPressX := X;
  FPressY := Y;
end;

procedure TBookmarksToolbar.PointerUp(X, Y: LongInt; Button: LongWord);
var
  Index: Integer;
  Node: TBookmarkNode;
begin
  inherited PointerUp(X, Y, Button);
  Index := ItemAt(X, Y);
  FPressIndex := -1;
  if (Index < 0) or not Assigned(FOnOpen) then
    Exit;
  Node := Folder[Index];
  if Node.Kind <> BookmarkItem then
    Exit;
  if Button = ButtonMiddle then
    FOnOpen(Node.Url, LinkInBackgroundTab)
  else if Button = ButtonLeft then
  begin
    if (HeldModifiers and ModifierControl) <> 0 then
      FOnOpen(Node.Url, LinkInBackgroundTab)
    else if (HeldModifiers and ModifierShift) <> 0 then
      FOnOpen(Node.Url, LinkInNewWindow)
    else
      FOnOpen(Node.Url, LinkInView);
  end;
end;

procedure TBookmarksToolbar.ContextMenu(X, Y: LongInt; FromKeyboard: Boolean);
var
  Index: Integer;
  Window: TControlWindow;
  Node: TBookmarkNode;
begin
  Index := ItemAt(X, Y);
  if Index = -2 then
    Index := -1;
  FMenuIndex := Index;
  FMenuNode := nil;
  if Index >= 0 then
    FMenuNode := Folder[Index];
  Node := FMenuNode;
  FMenu.Clear;
  if (Node <> nil) and (Node.Kind = BookmarkItem) then
  begin
    FMenu.Add('&Open', @ContextChosen).Tag := ContextOpen;
    FMenu.Add('Open in a New &Tab', @ContextChosen).Tag := ContextOpenTab;
    FMenu.Add('Open in a New &Window', @ContextChosen).Tag := ContextOpenWindow;
    FMenu.AddSeparator;
  end
  else if (Node <> nil) and Node.IsFolder then
  begin
    FMenu.Add('Open All in &Tabs', @ContextChosen).Tag := ContextOpenAll;
    FMenu.AddSeparator;
  end;
  FMenu.Add('New &Bookmark...', @ContextChosen).Tag := ContextNewBookmark;
  FMenu.Add('New &Folder...', @ContextChosen).Tag := ContextNewFolder;
  FMenu.Add('New &Separator', @ContextChosen).Tag := ContextNewSeparator;
  if Node <> nil then
  begin
    FMenu.AddSeparator;
    FMenu.Add('&Delete', @ContextChosen).Tag := ContextDelete;
    if Node.Kind <> BookmarkSeparator then
    begin
      FMenu.AddSeparator;
      FMenu.Add('P&roperties', @ContextChosen).Tag := ContextProperties;
    end;
  end;
  if (Host = nil) or not (Host.OwnerWindow is TControlWindow) then
    Exit;
  Window := TControlWindow(Host.OwnerWindow);
  ShowPopupMenu(Window, FMenu, Window.ScreenLeft + Unscaled(PixelBounds.Left + X),
    Window.ScreenTop + Unscaled(PixelBounds.Top + Y));
end;

procedure TBookmarksToolbar.ContextChosen(Item: TMenuItem);
var
  Node: TBookmarkNode;
  Place: Integer;
begin
  Node := FMenuNode;
  Place := FMenuIndex;
  if Place < 0 then
    Place := Folder.Count;
  case Item.Tag of
    ContextOpen:
      if Assigned(FOnOpen) then
        FOnOpen(Node.Url, LinkInView);
    ContextOpenTab:
      if Assigned(FOnOpen) then
        FOnOpen(Node.Url, LinkInNewTab);
    ContextOpenWindow:
      if Assigned(FOnOpen) then
        FOnOpen(Node.Url, LinkInNewWindow);
    ContextOpenAll:
      if Assigned(FOnOpenAll) then
        FOnOpenAll(Node);
    ContextNewBookmark:
      if Assigned(FOnAdd) then
        FOnAdd(BookmarkItem, Folder, Place);
    ContextNewFolder:
      if Assigned(FOnAdd) then
        FOnAdd(BookmarkFolder, Folder, Place);
    ContextNewSeparator:
      FStore.AddSeparator(Folder, Place);
    ContextDelete:
      FStore.Delete(Node);
    ContextProperties:
      if Assigned(FOnEdit) then
        FOnEdit(Node);
  end;
end;

procedure TBookmarksToolbar.SetDropIndex(Value: Integer);
begin
  if FDropIndex <> Value then
  begin
    FDropIndex := Value;
    Invalidate;
  end;
end;

function TBookmarksToolbar.DragOver(Data: TDragData; X, Y: LongInt; Modifiers: LongWord): TDropEffect;
var
  Url, Title: string;
begin
  if Data.Format = DragFormatBookmark then
  begin
    SetDropIndex(DropIndexAt(X));
    Exit(DropMove);
  end;
  if DraggedLink(Data, Url, Title) then
  begin
    SetDropIndex(DropIndexAt(X));
    Exit(DropLink);
  end;
  Result := inherited DragOver(Data, X, Y, Modifiers);
end;

procedure TBookmarksToolbar.DragLeave;
begin
  SetDropIndex(-1);
  inherited DragLeave;
end;

procedure TBookmarksToolbar.DragDrop(Data: TDragData; X, Y: LongInt; Effect: TDropEffect);
var
  Url, Title: string;
  Node: TBookmarkNode;
  Place: Integer;
begin
  SetDropIndex(-1);
  Place := DropIndexAt(X);
  if Data.Format = DragFormatBookmark then
  begin
    Node := FStore.NodeById(StrToIntDef(Data.Text, 0));
    if Node <> nil then
      FStore.Move(Node, Folder, Place);
    Exit;
  end;
  if DraggedLink(Data, Url, Title) then
  begin
    if Title = '' then
      Title := Url;
    FStore.AddBookmark(Folder, Title, Url, Place, DateTimeToUnix(LocalTimeToUniversal(Now)));
  end;
end;

function TBookmarksToolbar.HintAt(X, Y: LongInt; out Area: TRectangle): string;
var
  Index: Integer;
  Node: TBookmarkNode;
begin
  Area := MakeRectangle(0, 0, 0, 0);
  Index := ItemAt(X, Y);
  if Index = -2 then
  begin
    Area := ChevronBox;
    Exit('More bookmarks');
  end;
  if Index < 0 then
    Exit('');
  Area := ItemBox(Index);
  Node := Folder[Index];
  if Node.Kind = BookmarkItem then
    Result := Node.ShownTitle + LineEnding + Node.Url
  else
    Result := Node.ShownTitle;
end;

end.
