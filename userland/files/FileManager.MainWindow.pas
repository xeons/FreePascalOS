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
  The file manager's window with its menus, toolbar buttons, keys and
  context menus, all leading to the commands of FileManager.
  CommandWindow and the navigation of FileManager.BrowserWindow:

    File   Open (Enter), Open with Notepad, New Folder (Ctrl+Shift+N),
           Rename (F2), Delete (Del), Properties (Alt+Enter), Close
    Edit   Cut (Ctrl+X), Copy (Ctrl+C), Paste (Ctrl+V), Select All (Ctrl+A)
    View   Icons, List, Details, Sort By (a column, ascending or
           descending), Hidden Files (Ctrl+H), Refresh (F5)
    Go     Back (Alt+Left), Forward (Alt+Right), Up (Alt+Up or
           Backspace), Home, File System
    Help   About Files

  The keys that edit text (Ctrl+X, C, V, A, Delete, Backspace) act on
  files only while the items have the focus, so they still edit the
  address box when it has it. A right click on items (or Shift+F10)
  opens their menu (Open, Open with Notepad, Cut, Copy, Rename, Delete,
  Properties), on empty space the folder's (New Folder, Paste, Refresh,
  Properties), on a place its own (Open, Properties).

  The view, the order and hidden files are remembered as they are
  chosen (FileManager.Settings).
}
unit FileManager.MainWindow;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Controls.Window,
  Controls.Menus,
  Controls.ToolBar,
  Controls.ListView,
  FileManager.ItemOrder,
  FileManager.CommandWindow;

type
  TFileManagerWindow = class(TCommandWindow)
  private
    FFileMenu: TMenuItem;
    FEditMenu: TMenuItem;
    FViewMenu: TMenuItem;
    FOpenItem: TMenuItem;
    FNotepadItem: TMenuItem;
    FRenameItem: TMenuItem;
    FDeleteItem: TMenuItem;
    FCutItem: TMenuItem;
    FCopyItem: TMenuItem;
    FPasteItem: TMenuItem;
    FViewItems: array[0..2] of TMenuItem;
    FSortItems: array[TSortColumn] of TMenuItem;
    FAscendingItem: TMenuItem;
    FDescendingItem: TMenuItem;
    FHiddenItem: TMenuItem;
    FViewButtons: array[0..2] of TToolButton;
    FContextMenu: TMenuItem;
    procedure BuildMenus;
    procedure BuildFileMenu;
    procedure BuildEditMenu;
    procedure BuildViewMenu;
    procedure BuildGoAndHelpMenus;
    procedure BuildViewButtons;
    function AddItem(Menu: TMenuItem; const Text: string; Handler: TMenuItemEvent; const Shortcut: string;
      Code, Modifiers: LongWord): TMenuItem;
    procedure FileMenuOpening(Item: TMenuItem);
    procedure EditMenuOpening(Item: TMenuItem);
    procedure ShowViewChecks;
    procedure SetView(Index: LongInt);
    procedure ViewButtonClicked(Sender: TControl);
    procedure SelectionChanged(Sender: TControl);
    procedure OrderChanged(Sender: TControl);
    procedure ItemsKeyDown(Sender: TControl; Code, Character, Modifiers: LongWord; var Handled: Boolean);
    procedure ItemsContextMenu(Sender: TControl; X, Y: LongInt; FromKeyboard: Boolean);
    procedure PlacesContextMenu(Sender: TControl; X, Y: LongInt; FromKeyboard: Boolean);
    procedure OpenContextMenu(Control: TControl; X, Y: LongInt; const Kind: string);
    procedure OpenChosen(Item: TMenuItem);
    procedure NotepadChosen(Item: TMenuItem);
    procedure NewFolderChosen(Item: TMenuItem);
    procedure RenameChosen(Item: TMenuItem);
    procedure DeleteChosen(Item: TMenuItem);
    procedure PropertiesChosen(Item: TMenuItem);
    procedure CloseChosen(Item: TMenuItem);
    procedure CutChosen(Item: TMenuItem);
    procedure CopyChosen(Item: TMenuItem);
    procedure PasteChosen(Item: TMenuItem);
    procedure SelectAllChosen(Item: TMenuItem);
    procedure ViewChosen(Item: TMenuItem);
    procedure SortChosen(Item: TMenuItem);
    procedure DirectionChosen(Item: TMenuItem);
    procedure HiddenChosen(Item: TMenuItem);
    procedure RefreshChosen(Item: TMenuItem);
    procedure BackChosen(Item: TMenuItem);
    procedure ForwardChosen(Item: TMenuItem);
    procedure UpChosen(Item: TMenuItem);
    procedure HomeChosen(Item: TMenuItem);
    procedure RootChosen(Item: TMenuItem);
    procedure AboutChosen(Item: TMenuItem);
    procedure PlaceOpenChosen(Item: TMenuItem);
    procedure PlacePropertiesChosen(Item: TMenuItem);
  public
    constructor Create;
    destructor Destroy; override;
    procedure TellPlaces; override;
  end;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Drawing.Rectangles,
  Windowing.Connection,
  Windowing.Windows,
  Controls.Keys,
  Controls.TreeView,
  Controls.MessageBoxes,
  Controls.Text,
  FileManager.Items,
  FileManager.Settings,
  FileManager.FolderView,
  FileManager.PlacesPane,
  FileManager.BrowserWindow,
  FileManager.PropertiesDialog,
  FileManager.VolumeProperties,
  FileManager.TestPlaces,
  FileManager.Output;

const
  NoKey = 0;
  ViewModes: array[0..2] of TListViewMode = (ViewLargeIcons, ViewList, ViewDetails);
  ViewCaptions: array[0..2] of string = ('&Icons', '&List', '&Details');
  SortCaptions: array[TSortColumn] of string = ('&Name', '&Size', '&Type', '&Modified', '&Permissions', '&Owner');

constructor TFileManagerWindow.Create;
begin
  inherited Create;
  BuildMenus;
  BuildViewButtons;
  ShowViewChecks;
  FView.OnChange := @SelectionChanged;
  FView.OnOrderChanged := @OrderChanged;
  FView.OnKeyDown := @ItemsKeyDown;
  FView.OnContextMenu := @ItemsContextMenu;
  FPlaces.OnContextMenu := @PlacesContextMenu;
end;

destructor TFileManagerWindow.Destroy;
begin
  FContextMenu.Free;
  inherited Destroy;
end;

function TFileManagerWindow.AddItem(Menu: TMenuItem; const Text: string; Handler: TMenuItemEvent;
  const Shortcut: string; Code, Modifiers: LongWord): TMenuItem;
begin
  Result := Menu.Add(Text, Handler, Shortcut);
  if Code <> NoKey then
    AddItemAccelerator(Self, Result, Code, Modifiers);
end;

procedure TFileManagerWindow.BuildMenus;
begin
  BuildFileMenu;
  BuildEditMenu;
  BuildViewMenu;
  BuildGoAndHelpMenus;
end;

procedure TFileManagerWindow.BuildFileMenu;
begin
  FFileMenu := FMenuBar.Menu.Add('&File');
  FFileMenu.OnOpening := @FileMenuOpening;
  { Enter, F2 and Delete are the items' own keys (ItemsKeyDown). }
  FOpenItem := AddItem(FFileMenu, '&Open', @OpenChosen, 'Enter', NoKey, 0);
  FNotepadItem := AddItem(FFileMenu, 'Open with &Notepad', @NotepadChosen, '', NoKey, 0);
  FFileMenu.AddSeparator;
  AddItem(FFileMenu, 'New &Folder', @NewFolderChosen, 'Ctrl+Shift+N', KeyN, ModifierControl or ModifierShift);
  FRenameItem := AddItem(FFileMenu, '&Rename', @RenameChosen, 'F2', NoKey, 0);
  FDeleteItem := AddItem(FFileMenu, '&Delete', @DeleteChosen, 'Del', NoKey, 0);
  FFileMenu.AddSeparator;
  AddItem(FFileMenu, 'P&roperties', @PropertiesChosen, 'Alt+Enter', KeyEnter, ModifierAlt);
  FFileMenu.AddSeparator;
  AddItem(FFileMenu, '&Close', @CloseChosen, '', NoKey, 0);
end;

procedure TFileManagerWindow.BuildEditMenu;
begin
  FEditMenu := FMenuBar.Menu.Add('&Edit');
  FEditMenu.OnOpening := @EditMenuOpening;
  FCutItem := AddItem(FEditMenu, 'Cu&t', @CutChosen, 'Ctrl+X', NoKey, 0);
  FCopyItem := AddItem(FEditMenu, '&Copy', @CopyChosen, 'Ctrl+C', NoKey, 0);
  FPasteItem := AddItem(FEditMenu, '&Paste', @PasteChosen, 'Ctrl+V', NoKey, 0);
  FEditMenu.AddSeparator;
  AddItem(FEditMenu, 'Select &All', @SelectAllChosen, 'Ctrl+A', NoKey, 0);
end;

procedure TFileManagerWindow.BuildViewMenu;
var
  Index: LongInt;
  Column: TSortColumn;
  SortMenu: TMenuItem;
begin
  FViewMenu := FMenuBar.Menu.Add('&View');
  for Index := 0 to High(ViewCaptions) do
  begin
    FViewItems[Index] := AddItem(FViewMenu, ViewCaptions[Index], @ViewChosen, '', NoKey, 0);
    FViewItems[Index].Tag := Index;
  end;
  FViewMenu.AddSeparator;
  SortMenu := FViewMenu.Add('&Sort By');
  for Column := Low(TSortColumn) to High(TSortColumn) do
  begin
    FSortItems[Column] := AddItem(SortMenu, SortCaptions[Column], @SortChosen, '', NoKey, 0);
    FSortItems[Column].Tag := Ord(Column);
  end;
  SortMenu.AddSeparator;
  FAscendingItem := AddItem(SortMenu, '&Ascending', @DirectionChosen, '', NoKey, 0);
  FAscendingItem.Tag := 1;
  FDescendingItem := AddItem(SortMenu, 'D&escending', @DirectionChosen, '', NoKey, 0);
  FDescendingItem.Tag := 0;
  FHiddenItem := AddItem(FViewMenu, '&Hidden Files', @HiddenChosen, 'Ctrl+H', KeyH, ModifierControl);
  FViewMenu.AddSeparator;
  AddItem(FViewMenu, '&Refresh', @RefreshChosen, 'F5', KeyF5, 0);
end;

procedure TFileManagerWindow.BuildGoAndHelpMenus;
var
  Menu: TMenuItem;
begin
  Menu := FMenuBar.Menu.Add('&Go');
  AddItem(Menu, '&Back', @BackChosen, 'Alt+Left', KeyArrowLeft, ModifierAlt);
  AddItem(Menu, '&Forward', @ForwardChosen, 'Alt+Right', KeyArrowRight, ModifierAlt);
  AddItem(Menu, '&Up', @UpChosen, 'Alt+Up', KeyArrowUp, ModifierAlt);
  Menu.AddSeparator;
  AddItem(Menu, '&Home', @HomeChosen, '', NoKey, 0);
  AddItem(Menu, 'File &System', @RootChosen, '', NoKey, 0);
  Menu := FMenuBar.Menu.Add('&Help');
  AddItem(Menu, '&About Files', @AboutChosen, '', NoKey, 0);
end;

procedure TFileManagerWindow.BuildViewButtons;
var
  Index: LongInt;
const
  ButtonCaptions: array[0..2] of string = ('Icons', 'List', 'Details');
  ButtonWidths: array[0..2] of LongInt = (48, 40, 56);
begin
  FToolBar.AddSeparator;
  for Index := 0 to High(ButtonCaptions) do
  begin
    FViewButtons[Index] := FToolBar.AddButton(ButtonCaptions[Index], ButtonWidths[Index], @ViewButtonClicked);
    FViewButtons[Index].Tag := Index;
  end;
end;

{ --- Menus as things are ----------------------------------------------------------------------- }

procedure TFileManagerWindow.FileMenuOpening(Item: TMenuItem);
var
  Entry: TFolderEntry;
begin
  Entry := FView.EntryAt(FView.ItemIndex);
  FOpenItem.Enabled := Entry <> nil;
  FNotepadItem.Enabled := (Entry <> nil) and not IsFolderItem(Entry.Item);
  FRenameItem.Enabled := Entry <> nil;
  FDeleteItem.Enabled := HasSelection;
end;

procedure TFileManagerWindow.EditMenuOpening(Item: TMenuItem);
begin
  FCutItem.Enabled := HasSelection;
  FCopyItem.Enabled := HasSelection;
  FPasteItem.Enabled := CanPaste;
end;

procedure TFileManagerWindow.ShowViewChecks;
var
  Index: LongInt;
  Column: TSortColumn;
begin
  for Index := 0 to High(ViewModes) do
  begin
    FViewItems[Index].Checked := FView.ViewMode = ViewModes[Index];
    FViewButtons[Index].Down := FView.ViewMode = ViewModes[Index];
  end;
  for Column := Low(TSortColumn) to High(TSortColumn) do
    FSortItems[Column].Checked := FView.OrderColumn = Column;
  FAscendingItem.Checked := FView.OrderAscending;
  FDescendingItem.Checked := not FView.OrderAscending;
  FHiddenItem.Checked := FView.ShowHidden;
end;

{ --- Views and order ------------------------------------------------------------------------------ }

procedure TFileManagerWindow.SetView(Index: LongInt);
begin
  FView.ViewMode := ViewModes[Index];
  ShowViewChecks;
  RememberView(FView.ViewMode);
  Say('view ' + ViewName(FView.ViewMode));
  FView.TellPlaces;
end;

procedure TFileManagerWindow.ViewButtonClicked(Sender: TControl);
begin
  SetView(Sender.Tag);
end;

procedure TFileManagerWindow.ViewChosen(Item: TMenuItem);
begin
  SetView(Item.Tag);
end;

procedure TFileManagerWindow.OrderChanged(Sender: TControl);
begin
  ShowViewChecks;
  RememberOrder(FView.OrderColumn, FView.OrderAscending);
  if FView.OrderAscending then
    Say('sort ' + SortColumnName(FView.OrderColumn) + ' ascending')
  else
    Say('sort ' + SortColumnName(FView.OrderColumn) + ' descending');
  FView.TellPlaces;
end;

procedure TFileManagerWindow.SortChosen(Item: TMenuItem);
begin
  FView.SortBy(TSortColumn(Item.Tag), FView.OrderAscending);
  OrderChanged(FView);
end;

procedure TFileManagerWindow.DirectionChosen(Item: TMenuItem);
begin
  FView.SortBy(FView.OrderColumn, Item.Tag = 1);
  OrderChanged(FView);
end;

procedure TFileManagerWindow.HiddenChosen(Item: TMenuItem);
begin
  FView.ShowHidden := not FView.ShowHidden;
  ShowViewChecks;
  RememberShowHidden(FView.ShowHidden);
  if FView.ShowHidden then
    Say('hidden shown')
  else
    Say('hidden not shown');
  UpdateStatus;
end;

procedure TFileManagerWindow.RefreshChosen(Item: TMenuItem);
begin
  RefreshFolder;
end;

procedure TFileManagerWindow.SelectionChanged(Sender: TControl);
begin
  UpdateStatus;
  Say('selected ' + IntToStr(FView.SelectedCount));
end;

{ --- Keys ---------------------------------------------------------------------------------------- }

{ The keys that act on files while the items have the focus. }
procedure TFileManagerWindow.ItemsKeyDown(Sender: TControl; Code, Character, Modifiers: LongWord;
  var Handled: Boolean);
var
  Held: LongWord;
begin
  if FView.IsEditing then
    Exit;
  Held := Modifiers and (ModifierShift or ModifierControl or ModifierAlt);
  Handled := True;
  if (Code = KeyDelete) and (Held = 0) then
    DeleteSelected
  else if (Code = KeyF2) and (Held = 0) then
    RenameFocused
  else if (Code = KeyBackspace) and (Held = 0) then
    GoUp
  else if (Code = KeyC) and (Held = ModifierControl) then
    CopySelected(False)
  else if (Code = KeyX) and (Held = ModifierControl) then
    CopySelected(True)
  else if (Code = KeyV) and (Held = ModifierControl) then
    PasteFiles
  else
    Handled := False;
end;

{ --- Context menus -------------------------------------------------------------------------------- }

procedure TFileManagerWindow.OpenContextMenu(Control: TControl; X, Y: LongInt; const Kind: string);
var
  Left: LongInt;
  Top: LongInt;
  Index: LongInt;
  Width: LongInt;
  Height: LongInt;
begin
  Left := ScreenLeft + Unscaled(Control.PixelBounds.Left + X);
  Top := ScreenTop + Unscaled(Control.PixelBounds.Top + Y);
  Say('context-menu ' + Kind);
  MeasurePopupMenu(FContextMenu, Width, Height);
  for Index := 0 to FContextMenu.Count - 1 do
    if not FContextMenu[Index].IsSeparator then
      Say(Format('place context-%s %d %d', [StringReplace(LowerCase(TextWithoutMnemonic(FContextMenu[Index].Text)),
        ' ', '-', [rfReplaceAll]), Scaled(Left + 30), Scaled(Top + PopupMenuItemTop(FContextMenu, Index) + 9)]));
  ShowPopupMenu(Self, FContextMenu, Left, Top);
end;

procedure TFileManagerWindow.ItemsContextMenu(Sender: TControl; X, Y: LongInt; FromKeyboard: Boolean);
var
  Entry: TFolderEntry;
  Item: TMenuItem;
begin
  FContextMenu.Free;
  FContextMenu := TMenuItem.Create('');
  Entry := FView.EntryAt(FView.ItemIndex);
  if HasSelection and (Entry <> nil) and FView.Selected[FView.ItemIndex] then
  begin
    FContextMenu.Add('&Open', @OpenChosen);
    if not IsFolderItem(Entry.Item) then
      FContextMenu.Add('Open with &Notepad', @NotepadChosen);
    FContextMenu.AddSeparator;
    FContextMenu.Add('Cu&t', @CutChosen, 'Ctrl+X');
    FContextMenu.Add('&Copy', @CopyChosen, 'Ctrl+C');
    FContextMenu.AddSeparator;
    FContextMenu.Add('&Rename', @RenameChosen, 'F2');
    FContextMenu.Add('&Delete', @DeleteChosen, 'Del');
    FContextMenu.AddSeparator;
    FContextMenu.Add('P&roperties', @PropertiesChosen, 'Alt+Enter');
    OpenContextMenu(FView, X, Y, 'items');
  end
  else
  begin
    FContextMenu.Add('New &Folder', @NewFolderChosen, 'Ctrl+Shift+N');
    Item := FContextMenu.Add('&Paste', @PasteChosen, 'Ctrl+V');
    Item.Enabled := CanPaste;
    FContextMenu.AddSeparator;
    FContextMenu.Add('&Refresh', @RefreshChosen, 'F5');
    FContextMenu.AddSeparator;
    FContextMenu.Add('P&roperties', @PropertiesChosen, 'Alt+Enter');
    OpenContextMenu(FView, X, Y, 'folder');
  end;
end;

procedure TFileManagerWindow.PlacesContextMenu(Sender: TControl; X, Y: LongInt; FromKeyboard: Boolean);
var
  Node: TTreeNode;
  Item: TMenuItem;
begin
  if FromKeyboard then
    Node := FPlaces.Selected
  else
    Node := FPlaces.NodeAt(X, Y);
  if Node = nil then
    Exit;
  FContextMenu.Free;
  FContextMenu := TMenuItem.Create('');
  Item := FContextMenu.Add('&Open', @PlaceOpenChosen);
  Item.Tag := PtrInt(Node);
  FContextMenu.AddSeparator;
  Item := FContextMenu.Add('P&roperties', @PlacePropertiesChosen);
  Item.Tag := PtrInt(Node);
  OpenContextMenu(FPlaces, X, Y, 'place');
end;

procedure TFileManagerWindow.PlaceOpenChosen(Item: TMenuItem);
begin
  Navigate(FPlaces.PlaceOf(TTreeNode(Item.Tag)).Path);
end;

procedure TFileManagerWindow.PlacePropertiesChosen(Item: TMenuItem);
var
  Place: TPlace;
begin
  Place := FPlaces.PlaceOf(TTreeNode(Item.Tag));
  if Place.VolumeName <> '' then
    ShowVolumeProperties(Place.VolumeName, Self)
  else
    ShowItemProperties(Place.Path, Self);
end;

{ --- Commands ------------------------------------------------------------------------------------ }

procedure TFileManagerWindow.OpenChosen(Item: TMenuItem);
begin
  OpenFocused;
end;

procedure TFileManagerWindow.NotepadChosen(Item: TMenuItem);
begin
  OpenFocusedWithNotepad;
end;

procedure TFileManagerWindow.NewFolderChosen(Item: TMenuItem);
begin
  CreateNewFolder;
end;

procedure TFileManagerWindow.RenameChosen(Item: TMenuItem);
begin
  RenameFocused;
end;

procedure TFileManagerWindow.DeleteChosen(Item: TMenuItem);
begin
  DeleteSelected;
end;

procedure TFileManagerWindow.PropertiesChosen(Item: TMenuItem);
begin
  ShowProperties;
end;

procedure TFileManagerWindow.CloseChosen(Item: TMenuItem);
begin
  CloseRequested;
end;

procedure TFileManagerWindow.CutChosen(Item: TMenuItem);
begin
  CopySelected(True);
end;

procedure TFileManagerWindow.CopyChosen(Item: TMenuItem);
begin
  CopySelected(False);
end;

procedure TFileManagerWindow.PasteChosen(Item: TMenuItem);
begin
  PasteFiles;
end;

procedure TFileManagerWindow.SelectAllChosen(Item: TMenuItem);
begin
  FView.SelectAll;
end;

procedure TFileManagerWindow.BackChosen(Item: TMenuItem);
begin
  GoBack;
end;

procedure TFileManagerWindow.ForwardChosen(Item: TMenuItem);
begin
  GoForward;
end;

procedure TFileManagerWindow.UpChosen(Item: TMenuItem);
begin
  GoUp;
end;

procedure TFileManagerWindow.HomeChosen(Item: TMenuItem);
begin
  Navigate(HomeFolder);
end;

procedure TFileManagerWindow.RootChosen(Item: TMenuItem);
begin
  Navigate('/');
end;

procedure TFileManagerWindow.AboutChosen(Item: TMenuItem);
begin
  ShowMessageBox('About Files', 'Files'#10'A file manager for FreePascalOS.', MessageOk, SignInformation, Self);
end;

procedure TFileManagerWindow.TellPlaces;
var
  Index: LongInt;
  Heading: string;
begin
  for Index := 0 to FMenuBar.Menu.Count - 1 do
  begin
    Heading := LowerCase(TextWithoutMnemonic(FMenuBar.Menu[Index].Text));
    TellPlace('menu-' + Heading, FMenuBar, FMenuBar.HeadingLeft(Index) + FMenuBar.HeadingWidth(Index) div 2,
      RectangleHeight(FMenuBar.PixelBounds) div 2);
  end;
  for Index := 0 to High(FViewButtons) do
    TellControlPlace('view-' + LowerCase(FViewButtons[Index].Text), FViewButtons[Index]);
  inherited TellPlaces;
end;

end.
