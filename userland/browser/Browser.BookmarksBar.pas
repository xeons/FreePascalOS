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
  The bookmarks bar under the address bar: a flat button per bookmark
  (its title cut to fit, its address as the hint), lit under the
  pointer. A click opens the bookmark in the tab, a middle click or
  Ctrl+click in a new tab; a right click offers to delete it.
}
unit Browser.BookmarksBar;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Canvas,
  Drawing.Rectangles,
  Controls.Base,
  Controls.Menus,
  Browser.Stores;

type
  TBookmarkOpenEvent = procedure(const Url: string; NewTab: Boolean) of object;

  TBookmarksBar = class(TControl)
  private
    FStore: TBookmarkStore;
    FHot: Integer;
    FMenu: TMenuItem;
    FMenuIndex: Integer;
    FOnOpen: TBookmarkOpenEvent;
    FOnChanged: TControlEvent;
    function ItemBox(Index: Integer): TRectangle;
    function ItemAt(X, Y: LongInt): Integer;
    function ShownTitle(Index: Integer): string;
    procedure MenuChosen(Item: TMenuItem);
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerMove(X, Y: LongInt; Buttons: LongWord); override;
    procedure PointerLeave; override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
    procedure ContextMenu(X, Y: LongInt; FromKeyboard: Boolean); override;
  public
    constructor Create(AParent: TControl; Store: TBookmarkStore); reintroduce;
    destructor Destroy; override;
    function PreferredSize: TSize; override;
    function HintAt(X, Y: LongInt; out Area: TRectangle): string; override;
    property OnOpen: TBookmarkOpenEvent read FOnOpen write FOnOpen;
    { A bookmark was deleted from the bar. }
    property OnChanged: TControlEvent read FOnChanged write FOnChanged;
  end;

implementation

uses
  Math,
  Abi.SystemCalls,
  Drawing.Colors,
  Windowing.Theme,
  Windowing.Connection,
  Windowing.Protocol,
  Windowing.Windows,
  Controls.Window,
  Controls.Text,
  Controls.Painting;

const
  BarHeight = 26;
  ItemPadding = 8;
  MaximumItemWidth = 170;
  ItemGap = 2;

constructor TBookmarksBar.Create(AParent: TControl; Store: TBookmarkStore);
begin
  inherited Create(AParent);
  FStore := Store;
  FHot := -1;
end;

destructor TBookmarksBar.Destroy;
begin
  FMenu.Free;
  inherited Destroy;
end;

function TBookmarksBar.PreferredSize: TSize;
begin
  Result.Width := 200;
  Result.Height := BarHeight;
end;

function TBookmarksBar.ShownTitle(Index: Integer): string;
begin
  Result := FStore.Items[Index].Title;
  if Result = '' then
    Result := FStore.Items[Index].Url;
end;

function TBookmarksBar.ItemBox(Index: Integer): TRectangle;
var
  Position, Left, Width: Integer;
begin
  Left := Scaled(4);
  for Position := 0 to Index do
  begin
    Width := Min(TextWidth(ControlFace, ShownTitle(Position)) + Scaled(ItemPadding * 2), Scaled(MaximumItemWidth));
    if Position = Index then
      Exit(MakeRectangle(Left, Scaled(2), Width, RectangleHeight(PixelBounds) - Scaled(4)));
    Inc(Left, Width + Scaled(ItemGap));
  end;
  Result := MakeRectangle(0, 0, 0, 0);
end;

function TBookmarksBar.ItemAt(X, Y: LongInt): Integer;
var
  Index: Integer;
begin
  for Index := 0 to FStore.Count - 1 do
    if RectangleContainsPoint(ItemBox(Index), X, Y) then
      Exit(Index);
  Result := -1;
end;

procedure TBookmarksBar.Paint(var Canvas: TCanvas);
var
  Width, Height, Index: LongInt;
  Box: TRectangle;
begin
  Width := RectangleWidth(PixelBounds);
  Height := RectangleHeight(PixelBounds);
  FillRectangle(Canvas, MakeRectangle(0, 0, Width, Height), Theme.Face);
  DrawHorizontalLine(Canvas, 0, Width, Height - 1, Theme.Shadow);
  if FStore.Count = 0 then
  begin
    DrawTextInBox(Canvas, ControlFace, 'Bookmarks you add (Ctrl+D) show here.', MakeRectangle(Scaled(8), 0, Width,
      Height), AlignTextLeft, Theme.DisabledText);
    Exit;
  end;
  for Index := 0 to FStore.Count - 1 do
  begin
    Box := ItemBox(Index);
    if Box.Left >= Width then
      Break;
    if Index = FHot then
    begin
      FillRectangle(Canvas, Box, Theme.HotButtonFace);
      DrawRectangleOutline(Canvas, Box, Theme.Shadow);
    end;
    DrawTextInBox(Canvas, ControlFace, ShownTitle(Index), MakeRectangle(Box.Left + Scaled(ItemPadding), Box.Top,
      RectangleWidth(Box) - Scaled(ItemPadding * 2), RectangleHeight(Box)), AlignTextLeft, Theme.FaceText);
  end;
end;

procedure TBookmarksBar.PointerMove(X, Y: LongInt; Buttons: LongWord);
var
  Index: Integer;
begin
  inherited PointerMove(X, Y, Buttons);
  Index := ItemAt(X, Y);
  if Index <> FHot then
  begin
    FHot := Index;
    Invalidate;
  end;
  if Index >= 0 then
    PointerShape := PointerHand
  else
    PointerShape := PointerArrow;
end;

procedure TBookmarksBar.PointerLeave;
begin
  inherited PointerLeave;
  FHot := -1;
  Invalidate;
end;

procedure TBookmarksBar.PointerUp(X, Y: LongInt; Button: LongWord);
var
  Index: Integer;
begin
  inherited PointerUp(X, Y, Button);
  Index := ItemAt(X, Y);
  if (Index < 0) or not Assigned(FOnOpen) then
    Exit;
  if Button = ButtonMiddle then
    FOnOpen(FStore.Items[Index].Url, True)
  else if Button = ButtonLeft then
    FOnOpen(FStore.Items[Index].Url, (HeldModifiers and ModifierControl) <> 0);
end;

procedure TBookmarksBar.ContextMenu(X, Y: LongInt; FromKeyboard: Boolean);
var
  Window: TControlWindow;
begin
  FMenuIndex := ItemAt(X, Y);
  if (FMenuIndex < 0) or (Host = nil) or not (Host.OwnerWindow is TControlWindow) then
    Exit;
  Window := TControlWindow(Host.OwnerWindow);
  FMenu.Free;
  FMenu := TMenuItem.Create('');
  FMenu.Add('&Open').Tag := 1;
  FMenu.Add('Open in New &Tab').Tag := 2;
  FMenu.AddSeparator;
  FMenu.Add('&Delete').Tag := 3;
  ShowPopupMenu(Window, FMenu, Window.ScreenLeft + Unscaled(PixelBounds.Left + X),
    Window.ScreenTop + Unscaled(PixelBounds.Top + Y), @MenuChosen);
end;

procedure TBookmarksBar.MenuChosen(Item: TMenuItem);
begin
  if (FMenuIndex < 0) or (FMenuIndex >= FStore.Count) then
    Exit;
  case Item.Tag of
    1, 2:
      if Assigned(FOnOpen) then
        FOnOpen(FStore.Items[FMenuIndex].Url, Item.Tag = 2);
    3:
      begin
        FStore.Delete(FMenuIndex);
        FHot := -1;
        Invalidate;
        if Assigned(FOnChanged) then
          FOnChanged(Self);
      end;
  end;
end;

function TBookmarksBar.HintAt(X, Y: LongInt; out Area: TRectangle): string;
var
  Index: Integer;
begin
  Index := ItemAt(X, Y);
  Area := MakeRectangle(0, 0, 0, 0);
  if Index < 0 then
    Exit('');
  Area := ItemBox(Index);
  Result := FStore.Items[Index].Title + LineEnding + FStore.Items[Index].Url;
end;

end.
