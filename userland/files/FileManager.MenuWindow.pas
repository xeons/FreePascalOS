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
  The file manager's menus, and the one place every command is carried
  out (RunCommand, FileManager.Commands' numbers):

  * New: a folder, then the file templates;
  * Sort: by any column shown (and more), ascending or descending, and
    Group by (none, name, date, type, size);
  * View: the eight views, compact view, item check boxes, file name
    extensions, hidden items, the details and preview panes;
  * Filter: by kind or by date (the search syntax underneath), or none;
  * "..." (the overflow): Undo and Redo, select all, none, invert,
    compress to ZIP, extract all, pin to Home, options, properties;
  * the context menu of items (open, open with, open in a new tab or
    window, pin, favourites, compress or extract, copy as path, cut,
    copy, rename, delete, properties, and "Show more options", the full
    classic menu with Send to and the rest), of the background (view,
    sort by, group by, refresh, paste, undo, new, properties), and of a
    place in the navigation pane.

  Menus print "context-menu KIND" and where their items are ("place
  context-ITEM X Y") for tests.
}
unit FileManager.MenuWindow;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Controls.Base,
  Controls.Menus,
  Controls.CommandBar,
  FileManager.ItemCommands;

type
  TMenuWindow = class(TItemCommandWindow)
  private
    FContextMenu: TMenuItem;
    FIconIndexes: TStringList;
    FContextPlace: string;
    procedure ItemsContextMenu(Sender: TControl; X, Y: LongInt; FromKeyboard: Boolean);
    procedure PlacesContextMenu(Sender: TControl; X, Y: LongInt; FromKeyboard: Boolean);
    procedure ShowContextMenu(Control: TControl; X, Y: LongInt; const Kind: string);
    procedure FillItemMenu(Menu: TMenuItem);
    procedure FillClassicMenu(Menu: TMenuItem);
    procedure FillBackgroundMenu(Menu: TMenuItem);
    procedure FillOpenWithMenu(Menu: TMenuItem);
  protected
    function CommandIcon(const Name: string): LongInt;
    function AddCommandItem(Menu: TMenuItem; const Text: string; Command: LongInt; const Shortcut: string = '';
      const Icon: string = ''): TMenuItem;
    procedure MenuChosen(Item: TMenuItem);
    procedure FillNewMenu(Menu: TMenuItem);
    procedure FillSortMenu(Menu: TMenuItem);
    procedure FillGroupMenu(Menu: TMenuItem);
    procedure FillViewMenu(Menu: TMenuItem);
    procedure FillFilterMenu(Menu: TMenuItem);
    procedure FillOverflowMenu(Menu: TMenuItem);
    { Carries out a command (by its number). }
    procedure RunCommand(Command: LongInt); virtual;
    { The view, panes, options changed by a command: the bars follow. }
    procedure CommandsChanged; virtual;
    procedure ShowOptions; virtual; abstract;
  public
    constructor Create;
    destructor Destroy; override;
  end;

implementation

uses
  SysUtils,
  Drawing.Rectangles,
  Windowing.Theme,
  Windowing.Windows,
  Windowing.Connection,
  Abi.SystemCalls,
  Controls.Window,
  Controls.Text,
  Controls.TreeView,
  Controls.MessageBoxes,
  Controls.ItemViewLayout,
  Controls.IconTheme,
  Controls.Clipboard,
  Controls.FileNames,
  Configuration.ProgramInfo,
  Configuration.ProgramFolders,
  FileManager.Items,
  FileManager.Entries,
  FileManager.Locations,
  FileManager.FileKinds,
  FileManager.ItemColumns,
  FileManager.Grouping,
  FileManager.Settings,
  FileManager.Templates,
  FileManager.Handlers,
  FileManager.Commands,
  FileManager.UndoHistory,
  FileManager.NavigationPane,
  FileManager.SidePane,
  FileManager.Launching,
  FileManager.PropertiesDialog,
  FileManager.BrowserWindow,
  FileManager.Output;

constructor TMenuWindow.Create;
begin
  FIconIndexes := TStringList.Create;
  inherited Create;
  FView.OnContextMenu := @ItemsContextMenu;
  FPlaces.OnContextMenu := @PlacesContextMenu;
end;

destructor TMenuWindow.Destroy;
begin
  FContextMenu.Free;
  FIconIndexes.Free;
  inherited Destroy;
end;

function TMenuWindow.CommandIcon(const Name: string): LongInt;
var
  Position: LongInt;
begin
  if Name = '' then
    Exit(-1);
  Position := FIconIndexes.IndexOf(Name);
  if Position >= 0 then
    Exit(PtrInt(FIconIndexes.Objects[Position]));
  Result := Controls.IconTheme.AddThemeIcon(FCommandImages, Name);
  FIconIndexes.AddObject(Name, TObject(PtrInt(Result)));
end;

function TMenuWindow.AddCommandItem(Menu: TMenuItem; const Text: string; Command: LongInt; const Shortcut: string;
  const Icon: string): TMenuItem;
begin
  Result := Menu.Add(Text, @MenuChosen, Shortcut);
  Result.Tag := Command;
  Result.ImageIndex := CommandIcon(Icon);
end;

procedure TMenuWindow.MenuChosen(Item: TMenuItem);
begin
  RunCommand(Item.Tag);
end;

procedure TMenuWindow.CommandsChanged;
begin
end;

{ --- The command bar's menus ---------------------------------------------------------------- }

procedure TMenuWindow.FillNewMenu(Menu: TMenuItem);
var
  Templates: TFileTemplates;
  Index: LongInt;
  Item: TMenuItem;
  CanMake: Boolean;
begin
  Menu.Images := FCommandImages;
  CanMake := FView.Location.Kind = LocationFolder;
  Item := AddCommandItem(Menu, '&Folder', CommandNewFolder, 'Ctrl+Shift+N', 'action-new-folder');
  Item.Enabled := CanMake;
  Menu.AddSeparator;
  Templates := FileTemplates;
  for Index := 0 to High(Templates) do
  begin
    Item := AddCommandItem(Menu, Templates[Index].Caption, CommandNewFileBase + Index, '', Templates[Index].IconName);
    Item.Enabled := CanMake;
  end;
end;

procedure TMenuWindow.FillSortMenu(Menu: TMenuItem);
var
  Column: TColumnKind;
  Item: TMenuItem;
  Shown: TColumnKinds;
  Each: TColumnKind;
begin
  Shown := [ColumnName, ColumnModified, ColumnType, ColumnSize];
  for Each in FView.Settings.Columns do
    Include(Shown, Each);
  for Column := Low(TColumnKind) to High(TColumnKind) do
    if Column in Shown then
    begin
      Item := AddCommandItem(Menu, ColumnCaptions[Column], CommandSortBase + Ord(Column));
      Item.Checked := FView.Settings.SortColumn = Column;
    end;
  Menu.AddSeparator;
  Item := AddCommandItem(Menu, '&Ascending', CommandAscending);
  Item.Checked := FView.Settings.SortAscending;
  Item := AddCommandItem(Menu, '&Descending', CommandDescending);
  Item.Checked := not FView.Settings.SortAscending;
  Menu.AddSeparator;
  FillGroupMenu(Menu.Add('&Group by'));
end;

procedure TMenuWindow.FillGroupMenu(Menu: TMenuItem);
var
  GroupBy: TGroupBy;
  Item: TMenuItem;
begin
  for GroupBy := GroupNone to GroupBySize do
  begin
    Item := AddCommandItem(Menu, GroupByCaptions[GroupBy], CommandGroupBase + Ord(GroupBy));
    Item.Checked := FView.Settings.GroupBy = GroupBy;
  end;
end;

procedure TMenuWindow.FillViewMenu(Menu: TMenuItem);
var
  Mode: TItemViewMode;
  Item: TMenuItem;
  Shortcut: string;
begin
  for Mode := Low(TItemViewMode) to High(TItemViewMode) do
  begin
    Shortcut := 'Ctrl+Shift+' + IntToStr(Ord(Mode) + 1);
    Item := AddCommandItem(Menu, ViewModeCaptions[Mode], CommandViewBase + Ord(Mode), Shortcut);
    Item.Checked := FView.Mode = Mode;
  end;
  Menu.AddSeparator;
  Item := AddCommandItem(Menu, 'Co&mpact view', CommandCompact);
  Item.Checked := FView.Compact;
  Menu.AddSeparator;
  Item := AddCommandItem(Menu, 'Item &check boxes', CommandCheckBoxes);
  Item.Checked := FView.ShowCheckBoxes;
  Item := AddCommandItem(Menu, 'File name e&xtensions', CommandExtensions);
  Item.Checked := FView.ShowExtensions;
  Item := AddCommandItem(Menu, '&Hidden items', CommandHiddenItems, 'Ctrl+H');
  Item.Checked := FView.ShowHidden;
  Menu.AddSeparator;
  Item := AddCommandItem(Menu, 'Details &pane', CommandDetailsPane, 'Alt+Shift+P', 'action-details-pane');
  Item.Checked := SidePaneShown and (FSidePane.Kind = SidePaneDetails);
  Item := AddCommandItem(Menu, 'Pre&view pane', CommandPreviewPane, 'Alt+P', 'action-preview-pane');
  Item.Checked := SidePaneShown and (FSidePane.Kind = SidePanePreview);
  Item := AddCommandItem(Menu, '&Navigation pane', CommandShowNavigationPane);
  Item.Checked := FPlaces.Visible;
end;

procedure TMenuWindow.FillFilterMenu(Menu: TMenuItem);
var
  Kind: TFileKind;
  Item: TMenuItem;
  Index: LongInt;
begin
  for Kind := FileKindFolder to FileKindProgram do
  begin
    Item := AddCommandItem(Menu, FileKindTitles[Kind], CommandFilterKindBase + Ord(Kind));
    Item.Checked := FView.FilterText = 'kind:' + FileKindNames[Kind];
  end;
  Menu.AddSeparator;
  for Index := 0 to High(DateFilters) do
  begin
    Item := AddCommandItem(Menu, DateFilterCaptions[Index], CommandFilterDateBase + Index);
    Item.Checked := FView.FilterText = 'modified:' + DateFilters[Index];
  end;
  Menu.AddSeparator;
  Item := AddCommandItem(Menu, '&Clear filter', CommandClearFilter);
  Item.Enabled := FView.FilterText <> '';
end;

procedure TMenuWindow.FillOverflowMenu(Menu: TMenuItem);
var
  Item: TMenuItem;
begin
  Menu.Images := FCommandImages;
  Item := AddCommandItem(Menu, '&Undo', CommandUndo, 'Ctrl+Z', 'action-undo');
  Item.Enabled := CanUndo;
  if CanUndo then
    Item.Text := '&' + EntryDescription(FHistory.NextUndo, True);
  Item := AddCommandItem(Menu, '&Redo', CommandRedo, 'Ctrl+Y', 'action-redo');
  Item.Enabled := CanRedo;
  if CanRedo then
    Item.Text := '&' + EntryDescription(FHistory.NextRedo, False);
  Menu.AddSeparator;
  AddCommandItem(Menu, 'Select &all', CommandSelectAll, 'Ctrl+A', 'action-select-all');
  AddCommandItem(Menu, 'Select &none', CommandSelectNone);
  AddCommandItem(Menu, '&Invert selection', CommandInvertSelection);
  Menu.AddSeparator;
  Item := AddCommandItem(Menu, '&Compress to ZIP file', CommandCompress, '', 'action-compress');
  Item.Enabled := HasSelection and (FView.Location.Kind = LocationFolder);
  Item := AddCommandItem(Menu, '&Extract all...', CommandExtract, '', 'action-extract');
  Item.Enabled := FocusedIsArchive or (FView.Location.Kind = LocationArchive);
  if SelectionIsPinned then
    AddCommandItem(Menu, 'Un&pin from Home', CommandUnpin, '', 'action-unpin')
  else
    AddCommandItem(Menu, '&Pin to Home', CommandPin, '', 'action-pin');
  AddCommandItem(Menu, '&Copy as path', CommandCopyPath, 'Ctrl+Shift+C');
  Menu.AddSeparator;
  AddCommandItem(Menu, '&Options', CommandOptions, '', 'action-options');
  AddCommandItem(Menu, 'P&roperties', CommandProperties, 'Alt+Enter', 'action-properties');
  Menu.AddSeparator;
  AddCommandItem(Menu, 'About &Files', CommandAbout);
end;

procedure TMenuWindow.FillOpenWithMenu(Menu: TMenuItem);
var
  Handlers: TProgramList;
  Index: LongInt;
begin
  if FocusedEntry = nil then
    Exit;
  Handlers := HandlersForFile(FocusedEntry.FullPath);
  for Index := 0 to High(Handlers) do
  begin
    if Index >= CommandRangeSize then
      Break;
    AddCommandItem(Menu, Handlers[Index].Name, CommandOpenWithBase + Index);
  end;
  if Length(Handlers) > 0 then
    Menu.AddSeparator;
  AddCommandItem(Menu, '&Choose another program...', CommandOpenWith);
  AddCommandItem(Menu, 'Choose a &default...', CommandChooseDefault);
end;

{ --- Context menus -------------------------------------------------------------------------- }

procedure TMenuWindow.FillItemMenu(Menu: TMenuItem);
var
  Entry: TFolderEntry;
  Item: TMenuItem;
  Real: Boolean;
begin
  Entry := FocusedEntry;
  Real := Entry.IsRealFile;
  if Entry.Kind = EntryTrashed then
  begin
    AddCommandItem(Menu, '&Restore', CommandRestore, '', 'action-undo');
    AddCommandItem(Menu, '&Delete permanently', CommandDelete, 'Del', 'action-delete');
    Menu.AddSeparator;
    AddCommandItem(Menu, 'P&roperties', CommandProperties, 'Alt+Enter', 'action-properties');
    Exit;
  end;
  { The common actions first (the icon row of the modern menu). }
  if Real then
  begin
    AddCommandItem(Menu, 'Cu&t', CommandCut, 'Ctrl+X', 'action-cut');
    AddCommandItem(Menu, '&Copy', CommandCopy, 'Ctrl+C', 'action-copy');
    AddCommandItem(Menu, 'Rena&me', CommandRename, 'F2', 'action-rename');
    AddCommandItem(Menu, '&Share (copy path)', CommandCopyPath, '', 'action-share');
    AddCommandItem(Menu, '&Delete', CommandDelete, 'Del', 'action-delete');
    Menu.AddSeparator;
  end
  else if Entry.Kind = EntryArchived then
  begin
    AddCommandItem(Menu, '&Copy', CommandCopy, 'Ctrl+C', 'action-copy');
    Menu.AddSeparator;
  end;
  AddCommandItem(Menu, '&Open', CommandOpen, 'Enter', 'action-open');
  if not Entry.IsFolder then
    FillOpenWithMenu(Menu.Add('Open &with'));
  if Entry.IsFolder or IsBrowsableArchiveExtension(Entry.Item.Name) then
  begin
    AddCommandItem(Menu, 'Open in new &tab', CommandOpenInNewTab, '', 'action-new-tab');
    AddCommandItem(Menu, 'Open in new &window', CommandOpenInNewWindow);
  end;
  if Real and Entry.IsFolder then
  begin
    if SelectionIsPinned then
      AddCommandItem(Menu, 'Un&pin from Home', CommandUnpin, '', 'action-unpin')
    else
      AddCommandItem(Menu, '&Pin to Home', CommandPin, '', 'action-pin');
  end;
  if Real and not Entry.IsFolder then
  begin
    if SelectionIsFavorite then
      AddCommandItem(Menu, 'Remove from &favorites', CommandUnfavorite, '', 'action-star')
    else
      AddCommandItem(Menu, 'Add to &favorites', CommandFavorite, '', 'action-star');
  end;
  if Real then
  begin
    if FocusedIsArchive then
      AddCommandItem(Menu, 'E&xtract all...', CommandExtract, '', 'action-extract');
    Item := AddCommandItem(Menu, 'Compress to &ZIP file', CommandCompress, '', 'action-compress');
    Item.Enabled := FView.Location.Kind = LocationFolder;
    AddCommandItem(Menu, 'Copy as p&ath', CommandCopyPath, 'Ctrl+Shift+C');
  end;
  AddCommandItem(Menu, 'P&roperties', CommandProperties, 'Alt+Enter', 'action-properties');
  Menu.AddSeparator;
  AddCommandItem(Menu, 'Show more &options', CommandShowMoreOptions, '', 'action-more');
end;

procedure TMenuWindow.FillClassicMenu(Menu: TMenuItem);
var
  Entry: TFolderEntry;
  SendToMenu: TMenuItem;
  Item: TMenuItem;
begin
  Entry := FocusedEntry;
  AddCommandItem(Menu, '&Open', CommandOpen, 'Enter');
  if not Entry.IsFolder then
    FillOpenWithMenu(Menu.Add('Open &with'));
  AddCommandItem(Menu, 'Open in new &tab', CommandOpenInNewTab);
  AddCommandItem(Menu, 'Open in new &window', CommandOpenInNewWindow);
  Menu.AddSeparator;
  if Entry.IsRealFile then
  begin
    if SelectionIsPinned then
      AddCommandItem(Menu, 'Un&pin from Home', CommandUnpin)
    else if Entry.IsFolder then
      AddCommandItem(Menu, '&Pin to Home', CommandPin);
    SendToMenu := Menu.Add('Se&nd to');
    AddCommandItem(SendToMenu, 'Compressed (ZIP) folder', CommandCompress);
    AddCommandItem(SendToMenu, 'Desktop', CommandSendToDesktop);
    AddCommandItem(SendToMenu, 'Documents', CommandSendToDocuments);
    Menu.AddSeparator;
    AddCommandItem(Menu, 'Cu&t', CommandCut, 'Ctrl+X');
  end;
  AddCommandItem(Menu, '&Copy', CommandCopy, 'Ctrl+C');
  Item := AddCommandItem(Menu, '&Paste', CommandPaste, 'Ctrl+V');
  Item.Enabled := CanPaste and Entry.IsFolder;
  Menu.AddSeparator;
  if Entry.IsRealFile then
  begin
    AddCommandItem(Menu, '&Delete', CommandDelete, 'Del');
    AddCommandItem(Menu, 'Delete permanentl&y', CommandDeletePermanently, 'Shift+Del');
    AddCommandItem(Menu, 'Rena&me', CommandRename, 'F2');
    Menu.AddSeparator;
  end;
  AddCommandItem(Menu, 'Copy as p&ath', CommandCopyPath, 'Ctrl+Shift+C');
  AddCommandItem(Menu, 'P&roperties', CommandProperties, 'Alt+Enter');
end;

procedure TMenuWindow.FillBackgroundMenu(Menu: TMenuItem);
var
  Item: TMenuItem;
begin
  Menu.Images := FCommandImages;
  FillViewMenu(Menu.Add('&View'));
  FillSortMenu(Menu.Add('&Sort by'));
  FillGroupMenu(Menu.Add('&Group by'));
  AddCommandItem(Menu, '&Refresh', CommandRefresh, 'F5', 'action-refresh');
  Menu.AddSeparator;
  Item := AddCommandItem(Menu, '&Paste', CommandPaste, 'Ctrl+V', 'action-paste');
  Item.Enabled := CanPaste;
  Item := AddCommandItem(Menu, '&Undo', CommandUndo, 'Ctrl+Z', 'action-undo');
  Item.Enabled := CanUndo;
  if CanUndo then
    Item.Text := '&' + EntryDescription(FHistory.NextUndo, True);
  if FView.Location.Kind = LocationFolder then
  begin
    Menu.AddSeparator;
    FillNewMenu(Menu.Add('&New'));
  end;
  if FView.Location.Kind = LocationTrash then
  begin
    Menu.AddSeparator;
    AddCommandItem(Menu, '&Empty recycle bin', CommandEmptyTrash, '', 'trash-empty');
    AddCommandItem(Menu, 'Restore &all items', CommandRestoreAll);
  end;
  Menu.AddSeparator;
  AddCommandItem(Menu, 'P&roperties', CommandProperties, 'Alt+Enter', 'action-properties');
end;

procedure TMenuWindow.ShowContextMenu(Control: TControl; X, Y: LongInt; const Kind: string);
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
        ' ', '-', [rfReplaceAll]), Scaled(Left + 30),
        Scaled(Top + PopupMenuItemTop(FContextMenu, Index) + Theme.MenuItemHeight div 2)]));
  ShowPopupMenu(Self, FContextMenu, Left, Top);
end;

procedure TMenuWindow.ItemsContextMenu(Sender: TControl; X, Y: LongInt; FromKeyboard: Boolean);
var
  Entry: TFolderEntry;
begin
  FContextMenu.Free;
  FContextMenu := TMenuItem.Create('');
  FContextMenu.Images := FCommandImages;
  Entry := FocusedEntry;
  FContextPlace := '';
  if HasSelection and (Entry <> nil) and FView.Selected[FView.ItemIndex] then
  begin
    { Shift with a right click: the classic menu at once. }
    if ((HeldModifiers and ModifierShift) <> 0) and not FromKeyboard then
    begin
      FillClassicMenu(FContextMenu);
      ShowContextMenu(FView, X, Y, 'classic');
    end
    else
    begin
      FillItemMenu(FContextMenu);
      ShowContextMenu(FView, X, Y, 'items');
    end;
  end
  else
  begin
    FillBackgroundMenu(FContextMenu);
    ShowContextMenu(FView, X, Y, 'folder');
  end;
end;

procedure TMenuWindow.PlacesContextMenu(Sender: TControl; X, Y: LongInt; FromKeyboard: Boolean);
var
  Node: TTreeNode;
  Place: TPlace;
begin
  if FromKeyboard then
    Node := FPlaces.Selected
  else
    Node := FPlaces.NodeAt(X, Y);
  if Node = nil then
    Exit;
  Place := FPlaces.PlaceOf(Node);
  FContextPlace := Place.Address;
  FContextMenu.Free;
  FContextMenu := TMenuItem.Create('');
  FContextMenu.Images := FCommandImages;
  AddCommandItem(FContextMenu, '&Open', CommandOpen, '', 'action-open');
  AddCommandItem(FContextMenu, 'Open in new &tab', CommandOpenInNewTab, '', 'action-new-tab');
  AddCommandItem(FContextMenu, 'Open in new &window', CommandOpenInNewWindow);
  if Place.Path <> '' then
  begin
    FContextMenu.AddSeparator;
    if Place.Pinned then
      AddCommandItem(FContextMenu, 'Un&pin from Home', CommandUnpin, '', 'action-unpin')
    else
      AddCommandItem(FContextMenu, '&Pin to Home', CommandPin, '', 'action-pin');
    AddCommandItem(FContextMenu, 'Copy as p&ath', CommandCopyPath);
  end;
  if Place.Address = TrashAddress then
  begin
    FContextMenu.AddSeparator;
    AddCommandItem(FContextMenu, '&Empty recycle bin', CommandEmptyTrash, '', 'trash-empty');
  end;
  if Place.Path <> '' then
  begin
    FContextMenu.AddSeparator;
    AddCommandItem(FContextMenu, 'P&roperties', CommandProperties, '', 'action-properties');
  end;
  ShowContextMenu(FPlaces, X, Y, 'place');
end;

{ --- Carrying out commands ------------------------------------------------------------------- }

procedure TMenuWindow.RunCommand(Command: LongInt);
var
  Place: string;
  Location: TLocation;
  Handlers: TProgramList;
  Paths: TStringList;
begin
  { A place's context menu acts on the place, not the items. }
  Place := FContextPlace;
  FContextPlace := '';
  if (Place <> '') and (Command in [CommandOpen, CommandOpenInNewTab, CommandOpenInNewWindow, CommandPin,
    CommandUnpin, CommandCopyPath, CommandProperties]) then
  begin
    if not ParseAddress(Place, '/', Location) then
      Exit;
    case Command of
      CommandOpen: Navigate(Location);
      CommandOpenInNewTab: NewTab(Location);
      CommandOpenInNewWindow: OpenNewWindow(LocationAddress(Location));
      CommandPin, CommandUnpin:
        begin
          Paths := TStringList.Create;
          try
            Paths.Add(Location.Path);
            PinPaths(Paths, Command = CommandPin);
          finally
            Paths.Free;
          end;
        end;
      CommandCopyPath:
        begin
          SetClipboardText('"' + Location.Path + '"');
          Say('copied-path 1');
        end;
      CommandProperties: ShowItemProperties(Location.Path, Self);
    end;
    Exit;
  end;
  case CommandBase(Command) of
    CommandViewBase:
      begin
        FView.SetMode(TItemViewMode(CommandIndex(Command)));
        FView.TellPlaces;
      end;
    CommandSortBase:
      FView.SetSort(TColumnKind(CommandIndex(Command)), FView.Settings.SortAscending);
    CommandGroupBase: FView.SetGroupBy(TGroupBy(CommandIndex(Command)));
    CommandNewFileBase: CreateNewFile(CommandIndex(Command));
    CommandFilterKindBase: FView.SetFilter('kind:' + FileKindNames[TFileKind(CommandIndex(Command))]);
    CommandFilterDateBase: FView.SetFilter('modified:' + DateFilters[CommandIndex(Command)]);
    CommandOpenWithBase:
      begin
        if FocusedEntry <> nil then
        begin
          Handlers := HandlersForFile(FocusedEntry.FullPath);
          if CommandIndex(Command) <= High(Handlers) then
            OpenFocusedWith(Handlers[CommandIndex(Command)]);
        end;
      end;
  else
    case Command of
      CommandOpen: OpenFocused(OpenHere);
      CommandOpenInNewTab: OpenFocused(OpenInNewTab);
      CommandOpenInNewWindow: OpenFocused(OpenInNewWindow);
      CommandOpenWith: OpenWithChooser(False);
      CommandChooseDefault: OpenWithChooser(True);
      CommandNewFolder: CreateNewFolder;
      CommandCut: CopySelected(True);
      CommandCopy: CopySelected(False);
      CommandPaste: PasteFiles;
      CommandRename: RenameFocused;
      CommandCopyPath: CopyAsPath;
      CommandSendToDesktop: SendTo(StandardFolderPath(FolderDesktop));
      CommandSendToDocuments: SendTo(StandardFolderPath(FolderDocuments));
      CommandDelete: DeleteSelected(False);
      CommandDeletePermanently: DeleteSelected(True);
      CommandUndo: Undo;
      CommandRedo: Redo;
      CommandSelectAll: FView.SelectAll;
      CommandSelectNone: SelectNone;
      CommandInvertSelection: InvertSelection;
      CommandProperties: ShowProperties;
      CommandOptions: ShowOptions;
      CommandCompress: CompressSelected;
      CommandExtract: ExtractFocused;
      CommandPin: PinSelected(True);
      CommandUnpin: PinSelected(False);
      CommandFavorite: FavoriteSelected(True);
      CommandUnfavorite: FavoriteSelected(False);
      CommandRefresh: RefreshFolder;
      CommandRestore: RestoreSelected;
      CommandRestoreAll: RestoreAll;
      CommandEmptyTrash: EmptyTrash;
      CommandNewTab: NewTab(PageLocation(LocationHome));
      CommandCloseTab: CloseTab(FTabStrip.ActiveIndex);
      CommandNewWindow: OpenNewWindow(LocationAddress(FView.Location));
      CommandCompact:
        begin
          FView.Compact := not FView.Compact;
          FOptions.Compact := FView.Compact;
          RememberOptions(FOptions);
        end;
      CommandCheckBoxes:
        begin
          FView.ShowCheckBoxes := not FView.ShowCheckBoxes;
          FOptions.ShowCheckBoxes := FView.ShowCheckBoxes;
          RememberOptions(FOptions);
        end;
      CommandExtensions:
        begin
          FView.SetShowExtensions(not FView.ShowExtensions);
          FOptions.ShowExtensions := FView.ShowExtensions;
          RememberOptions(FOptions);
        end;
      CommandHiddenItems:
        begin
          FView.SetShowHidden(not FView.ShowHidden);
          FOptions.ShowHidden := FView.ShowHidden;
          RememberOptions(FOptions);
          if FView.ShowHidden then
            Say('hidden shown')
          else
            Say('hidden not shown');
        end;
      CommandPreviewPane:
        if SidePaneShown and (FSidePane.Kind = SidePanePreview) then
          HideSidePane
        else
          ShowSidePane(SidePanePreview);
      CommandDetailsPane:
        if SidePaneShown and (FSidePane.Kind = SidePaneDetails) then
          HideSidePane
        else
          ShowSidePane(SidePaneDetails);
      CommandShowNavigationPane:
        begin
          FPlaces.Visible := not FPlaces.Visible;
          FSplitter.Visible := FPlaces.Visible;
          Root.RequestLayout;
        end;
      CommandAscending: FView.SetSort(FView.Settings.SortColumn, True);
      CommandDescending: FView.SetSort(FView.Settings.SortColumn, False);
      CommandClearFilter: FView.SetFilter('');
      CommandShowMoreOptions:
        if (FocusedEntry <> nil) and HasSelection then
        begin
          FContextMenu.Free;
          FContextMenu := TMenuItem.Create('');
          FillClassicMenu(FContextMenu);
          ShowContextMenu(FView, FView.KeyboardContextPoint.X, FView.KeyboardContextPoint.Y, 'classic');
        end;
      CommandBack: GoBack;
      CommandForward: GoForward;
      CommandUp: GoUp;
      CommandFocusAddress: FocusAddress;
      CommandFocusSearch: FocusSearch;
      CommandAbout:
        ShowMessageBox('About Files', 'Files'#10'Browse, open and organise files and folders.', MessageOk,
          SignInformation, Self);
    end;
  end;
  UpdateStatus;
  CommandsChanged;
end;

end.
