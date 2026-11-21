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
  The browser window's toolbars (libcontrols' customizable toolbox):
  the Navigation Toolbar (Back and Forward, each with its history on a
  held or right press; Reload, Stop and Home; the location bar; the
  search bar) and the Bookmarks Toolbar (the bookmarks toolbar's items).
  View > Toolbars > Customize... lets the user drag these and more
  (Downloads, Print, New Tab, New Window, History, Bookmarks, Cut, Copy,
  Paste, Zoom In, Zoom Out, Full Screen, separators, spaces) between the
  toolbars and the palette; the arrangement, the look (icons, text or
  both) and small icons are settings.

  A button's Tag is its command (Browser.Commands); the window runs it
  (OnCommand) and hooks the location bar, the search bar and the
  bookmarks items as they are made (OnItemMade). Controls are looked up
  by id each time (LocationBar, BackButton...): the user may remove
  any of them.
}
unit Browser.Toolbars;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Controls.Base,
  Controls.ImageList,
  Controls.ToolBar,
  Controls.Menus,
  Controls.CustomToolBars,
  Controls.ToolbarPalette,
  Browser.Settings,
  Browser.Bookmarks,
  Browser.LocationBar,
  Browser.SearchBar,
  Browser.BookmarksToolbar;

type
  TToolbarCommandEvent = procedure(Command: LongInt) of object;
  TToolbarItemEvent = procedure(const Id: string; Control: TControl) of object;

  TBrowserToolbars = class
  private
    FToolbox: TToolbox;
    FNavigation: TCustomToolBar;
    FBookmarksBar: TCustomToolBar;
    FPalette: TToolbarPalette;
    FLargeImages: TImageList;
    FSmallImages: TImageList;
    FStore: TBookmarkStore;
    FMode: TToolbarMode;
    FSmallIcons: Boolean;
    FBackMenu: TMenuItem;
    FForwardMenu: TMenuItem;
    FOnCommand: TToolbarCommandEvent;
    FOnItemMade: TToolbarItemEvent;
    FOnBackMenu: TControlEvent;
    FOnForwardMenu: TControlEvent;
    FOnChanged: TControlEvent;
    FOnCustomizeDone: TControlEvent;
    function CreateItem(Toolbar: TCustomToolBar; const Id: string): TControl;
    function MakeButton(Toolbar: TCustomToolBar; const Id: string): TToolButton;
    procedure ButtonClicked(Sender: TControl);
    procedure BackDropDown(Sender: TControl);
    procedure ForwardDropDown(Sender: TControl);
    procedure ToolboxChanged(Sender: TControl);
    procedure PaletteModeChanged(Sender: TControl);
    procedure PaletteSmallIconsChanged(Sender: TControl);
    procedure PaletteDone(Sender: TControl);
    function Images: TImageList;
  public
    constructor Create(Parent: TControl; Store: TBookmarkStore);
    destructor Destroy; override;
    { The items and look from the settings. }
    procedure Load(constref Settings: TBrowserSettings);
    { The arrangement and look into the settings. }
    procedure Store(var Settings: TBrowserSettings);
    function ItemControl(const Id: string): TControl;
    function Button(const Id: string): TToolButton;
    function LocationBar: TLocationBar;
    function SearchBar: TSearchBar;
    function BookmarksItems: TBookmarksToolbar;
    procedure BeginCustomize(PaletteParent: TControl);
    procedure EndCustomize;
    function Customizing: Boolean;
    property Toolbox: TToolbox read FToolbox;
    property Navigation: TCustomToolBar read FNavigation;
    property BookmarksBar: TCustomToolBar read FBookmarksBar;
    property Palette: TToolbarPalette read FPalette;
    property BackMenu: TMenuItem read FBackMenu;
    property ForwardMenu: TMenuItem read FForwardMenu;
    property SmallImages: TImageList read FSmallImages;
    property OnCommand: TToolbarCommandEvent read FOnCommand write FOnCommand;
    property OnItemMade: TToolbarItemEvent read FOnItemMade write FOnItemMade;
    { Fill BackMenu or ForwardMenu: they are about to drop down. }
    property OnBackMenu: TControlEvent read FOnBackMenu write FOnBackMenu;
    property OnForwardMenu: TControlEvent read FOnForwardMenu write FOnForwardMenu;
    { The user rearranged the items or changed the look. }
    property OnChanged: TControlEvent read FOnChanged write FOnChanged;
    property OnCustomizeDone: TControlEvent read FOnCustomizeDone write FOnCustomizeDone;
  end;

implementation

uses
  Controls.IconTheme,
  Controls.LayoutRules,
  Browser.Commands;

type
  TButtonDefinition = record
    Id: string;
    Caption: string;
    Hint: string;
    Icon: string;
    Command: LongInt;
  end;

const
  ButtonDefinitions: array[0..16] of TButtonDefinition = (
    (Id: 'back'; Caption: 'Back'; Hint: 'Go back one page (Alt+Left); hold for history'; Icon: 'action-back';
      Command: CommandBack),
    (Id: 'forward'; Caption: 'Forward'; Hint: 'Go forward one page (Alt+Right); hold for history';
      Icon: 'action-forward'; Command: CommandForward),
    (Id: 'reload'; Caption: 'Reload'; Hint: 'Reload current page (F5)'; Icon: 'action-refresh'; Command: CommandReload),
    (Id: 'stop'; Caption: 'Stop'; Hint: 'Stop loading this page (Esc)'; Icon: 'action-stop'; Command: CommandStop),
    (Id: 'home'; Caption: 'Home'; Hint: 'Go to the home page (Alt+Home)'; Icon: 'home'; Command: CommandHome),
    (Id: 'downloads'; Caption: 'Downloads'; Hint: 'Show the downloads (Ctrl+J)'; Icon: 'folder-downloads';
      Command: CommandDownloads),
    (Id: 'print'; Caption: 'Print'; Hint: 'Print this page (Ctrl+P)'; Icon: 'action-print'; Command: CommandPrint),
    (Id: 'newtab'; Caption: 'New Tab'; Hint: 'Open a new tab (Ctrl+T)'; Icon: 'action-add'; Command: CommandNewTab),
    (Id: 'newwindow'; Caption: 'New Window'; Hint: 'Open a new window (Ctrl+N)'; Icon: 'action-new';
      Command: CommandNewWindow),
    (Id: 'history'; Caption: 'History'; Hint: 'Show the history sidebar (Ctrl+H)'; Icon: 'library';
      Command: CommandSidebarHistory),
    (Id: 'bookmarksmenu'; Caption: 'Bookmarks'; Hint: 'Show the bookmarks sidebar (Ctrl+B)'; Icon: 'favourites';
      Command: CommandSidebarBookmarks),
    (Id: 'cut'; Caption: 'Cut'; Hint: 'Cut'; Icon: 'action-cut'; Command: CommandCut),
    (Id: 'copy'; Caption: 'Copy'; Hint: 'Copy'; Icon: 'action-copy'; Command: CommandCopy),
    (Id: 'paste'; Caption: 'Paste'; Hint: 'Paste'; Icon: 'action-paste'; Command: CommandPaste),
    (Id: 'zoomin'; Caption: 'Zoom In'; Hint: 'Zoom in (Ctrl++)'; Icon: 'action-zoom'; Command: CommandZoomIn),
    (Id: 'zoomout'; Caption: 'Zoom Out'; Hint: 'Zoom out (Ctrl+-)'; Icon: 'action-remove'; Command: CommandZoomOut),
    (Id: 'fullscreen'; Caption: 'Full Screen'; Hint: 'Full screen (F11)'; Icon: 'device-display';
      Command: CommandFullScreen));

  LargeIconSize = 24;
  SmallIconSize = 16;

constructor TBrowserToolbars.Create(Parent: TControl; Store: TBookmarkStore);
var
  Index: Integer;
begin
  inherited Create;
  FStore := Store;
  FLargeImages := TImageList.Create(LargeIconSize, LargeIconSize);
  FSmallImages := TImageList.Create(SmallIconSize, SmallIconSize);
  FBackMenu := TMenuItem.Create('');
  FForwardMenu := TMenuItem.Create('');
  FToolbox := TToolbox.Create(Parent);
  FToolbox.Images := FLargeImages;
  for Index := Low(ButtonDefinitions) to High(ButtonDefinitions) do
  begin
    AddThemeIcon(FLargeImages, ButtonDefinitions[Index].Icon);
    AddThemeIcon(FSmallImages, ButtonDefinitions[Index].Icon);
    FToolbox.DefineItem(ButtonDefinitions[Index].Id, ButtonDefinitions[Index].Caption, Index);
  end;
  FToolbox.DefineItem('location', 'Location', -1, True, 4, 150);
  FToolbox.DefineItem('search', 'Search', -1, True, 1, 120);
  FToolbox.DefineItem('bookmarks', 'Bookmarks Toolbar Items', -1, True, 1, 60);
  FToolbox.OnCreateItem := @CreateItem;
  FToolbox.OnChanged := @ToolboxChanged;
  FNavigation := FToolbox.AddToolbar('navigation', DefaultNavigationItems);
  FBookmarksBar := FToolbox.AddToolbar('bookmarks', DefaultBookmarksItems);
end;

destructor TBrowserToolbars.Destroy;
begin
  FBackMenu.Free;
  FForwardMenu.Free;
  FLargeImages.Free;
  FSmallImages.Free;
  inherited Destroy;
end;

function TBrowserToolbars.Images: TImageList;
begin
  if FSmallIcons then
    Result := FSmallImages
  else
    Result := FLargeImages;
end;

procedure TBrowserToolbars.Load(constref Settings: TBrowserSettings);
begin
  FMode := Settings.ToolbarMode;
  FSmallIcons := Settings.SmallIcons;
  { Emptied first, so an item may move from one toolbar to the other. }
  FNavigation.SetItems('');
  FBookmarksBar.SetItems('');
  FNavigation.SetItems(Settings.NavigationItems);
  FBookmarksBar.SetItems(Settings.BookmarksItems);
end;

procedure TBrowserToolbars.Store(var Settings: TBrowserSettings);
begin
  Settings.NavigationItems := FNavigation.Items;
  Settings.BookmarksItems := FBookmarksBar.Items;
  Settings.ToolbarMode := FMode;
  Settings.SmallIcons := FSmallIcons;
end;

function TBrowserToolbars.MakeButton(Toolbar: TCustomToolBar; const Id: string): TToolButton;
var
  Index: Integer;
begin
  Result := nil;
  for Index := Low(ButtonDefinitions) to High(ButtonDefinitions) do
    if ButtonDefinitions[Index].Id = Id then
    begin
      Result := TToolButton.Create(Toolbar);
      Result.Images := Images;
      if FSmallIcons then
        Result.IconSize := SmallIconSize
      else
        Result.IconSize := LargeIconSize;
      if FMode <> ToolbarText then
        Result.ImageIndex := Index;
      if FMode <> ToolbarIcons then
        Result.Text := ButtonDefinitions[Index].Caption;
      Result.CaptionBelow := FMode = ToolbarIconsAndText;
      Result.Hint := ButtonDefinitions[Index].Hint;
      Result.Tag := ButtonDefinitions[Index].Command;
      Result.OnClick := @ButtonClicked;
      Result.AutoSize := True;
      Exit;
    end;
end;

function TBrowserToolbars.CreateItem(Toolbar: TCustomToolBar; const Id: string): TControl;
var
  Made: TToolButton;
begin
  if Id = 'location' then
    Result := TLocationBar.Create(Toolbar)
  else if Id = 'search' then
    Result := TSearchBar.Create(Toolbar)
  else if Id = 'bookmarks' then
    Result := TBookmarksToolbar.CreateFor(Toolbar, FStore)
  else
  begin
    Made := MakeButton(Toolbar, Id);
    if Made <> nil then
    begin
      if Id = 'back' then
      begin
        Made.DropDownKind := DropDownOnHold;
        Made.DropDownMenu := FBackMenu;
        Made.OnDropDown := @BackDropDown;
      end
      else if Id = 'forward' then
      begin
        Made.DropDownKind := DropDownOnHold;
        Made.DropDownMenu := FForwardMenu;
        Made.OnDropDown := @ForwardDropDown;
      end;
    end;
    Result := Made;
  end;
  if (Result <> nil) and Assigned(FOnItemMade) then
    FOnItemMade(Id, Result);
end;

procedure TBrowserToolbars.ButtonClicked(Sender: TControl);
begin
  if Assigned(FOnCommand) then
    FOnCommand(Sender.Tag);
end;

procedure TBrowserToolbars.BackDropDown(Sender: TControl);
begin
  if Assigned(FOnBackMenu) then
    FOnBackMenu(Sender);
end;

procedure TBrowserToolbars.ForwardDropDown(Sender: TControl);
begin
  if Assigned(FOnForwardMenu) then
    FOnForwardMenu(Sender);
end;

function TBrowserToolbars.ItemControl(const Id: string): TControl;
var
  Index: Integer;
begin
  Index := FNavigation.IndexOfId(Id);
  if Index >= 0 then
    Exit(FNavigation.ItemControls[Index]);
  Index := FBookmarksBar.IndexOfId(Id);
  if Index >= 0 then
    Exit(FBookmarksBar.ItemControls[Index]);
  Result := nil;
end;

function TBrowserToolbars.Button(const Id: string): TToolButton;
var
  Control: TControl;
begin
  Control := ItemControl(Id);
  if Control is TToolButton then
    Result := TToolButton(Control)
  else
    Result := nil;
end;

function TBrowserToolbars.LocationBar: TLocationBar;
var
  Control: TControl;
begin
  Control := ItemControl('location');
  if Control is TLocationBar then
    Result := TLocationBar(Control)
  else
    Result := nil;
end;

function TBrowserToolbars.SearchBar: TSearchBar;
var
  Control: TControl;
begin
  Control := ItemControl('search');
  if Control is TSearchBar then
    Result := TSearchBar(Control)
  else
    Result := nil;
end;

function TBrowserToolbars.BookmarksItems: TBookmarksToolbar;
var
  Control: TControl;
begin
  Control := ItemControl('bookmarks');
  if Control is TBookmarksToolbar then
    Result := TBookmarksToolbar(Control)
  else
    Result := nil;
end;

procedure TBrowserToolbars.ToolboxChanged(Sender: TControl);
begin
  if Assigned(FOnChanged) then
    FOnChanged(Sender);
end;

procedure TBrowserToolbars.BeginCustomize(PaletteParent: TControl);
begin
  if FPalette <> nil then
    Exit;
  FToolbox.BeginCustomize;
  FPalette := TToolbarPalette.CreateFor(PaletteParent, FToolbox);
  FPalette.Align := AlignTop;
  FPalette.Mode := Ord(FMode);
  FPalette.SmallIcons := FSmallIcons;
  FPalette.OnModeChanged := @PaletteModeChanged;
  FPalette.OnSmallIconsChanged := @PaletteSmallIconsChanged;
  FPalette.OnDone := @PaletteDone;
end;

procedure TBrowserToolbars.EndCustomize;
begin
  if FPalette = nil then
    Exit;
  FToolbox.EndCustomize;
  FreeAndNil(FPalette);
end;

function TBrowserToolbars.Customizing: Boolean;
begin
  Result := FPalette <> nil;
end;

procedure TBrowserToolbars.PaletteModeChanged(Sender: TControl);
begin
  FMode := TToolbarMode(FPalette.Mode);
  FToolbox.RebuildItems;
  ToolboxChanged(Sender);
end;

procedure TBrowserToolbars.PaletteSmallIconsChanged(Sender: TControl);
begin
  FSmallIcons := FPalette.SmallIcons;
  FToolbox.RebuildItems;
  ToolboxChanged(Sender);
end;

procedure TBrowserToolbars.PaletteDone(Sender: TControl);
begin
  if Assigned(FOnCustomizeDone) then
    FOnCustomizeDone(Sender);
end;

end.
