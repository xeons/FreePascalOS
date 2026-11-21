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
  The file manager's window as a whole: the command bar and the keys,
  on top of the menus (FileManager.MenuWindow), the commands and the
  navigation.

  The command bar (Controls.CommandBar): New, then Cut, Copy, Paste,
  Rename, Share and Delete as pictures, Sort, View and Filter, and what
  the place calls for (Extract all in an archive or on one; Restore and
  Empty recycle bin in the recycle bin), the "..." menu, and the details
  and preview panes at the right. Buttons are enabled by the selection
  and the place, and Delete says "Delete permanently" in the recycle bin.

  The keys: Ctrl+C, X, V, A, Z, Y, F2, Delete, Shift+Delete, Enter,
  Backspace (up) and Ctrl+Shift+C while the items have the focus (the
  address bar and the search box keep their own); and anywhere F5
  (refresh), Alt+Enter (properties), Alt+Left, Right and Up, Ctrl+L,
  Alt+D and F4 (the address bar), Ctrl+E and Ctrl+F (search), Ctrl+T,
  Ctrl+W, Ctrl+Tab and Ctrl+Shift+Tab (tabs), Ctrl+N (a new window),
  Ctrl+Shift+N (a new folder), Alt+P and Alt+Shift+P (the panes),
  Ctrl+Shift+1 to 8 (the views), Ctrl+H (hidden items) and Ctrl with
  the wheel (bigger or smaller icons). Typing a name's first letters
  goes to it, the arrows move in every view.
}
unit FileManager.MainWindow;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Controls.Window,
  Controls.Menus,
  Controls.CommandBar,
  Controls.ItemView,
  FileManager.MenuWindow;

type
  TFileManagerWindow = class(TMenuWindow)
  private
    FNewButton: TCommandButton;
    FCutButton: TCommandButton;
    FCopyButton: TCommandButton;
    FPasteButton: TCommandButton;
    FRenameButton: TCommandButton;
    FShareButton: TCommandButton;
    FDeleteButton: TCommandButton;
    FSortButton: TCommandButton;
    FViewButton: TCommandButton;
    FFilterButton: TCommandButton;
    FExtractButton: TCommandButton;
    FRestoreButton: TCommandButton;
    FRestoreAllButton: TCommandButton;
    FEmptyTrashButton: TCommandButton;
    FDetailsButton: TCommandButton;
    FPreviewButton: TCommandButton;
    FExtractDue: Boolean;
    procedure BuildCommandBar;
    procedure BuildAccelerators;
    function AddButton(const Caption, Icon, Hint: string; Command: LongInt; ShowCaption: Boolean): TCommandButton;
    procedure ButtonClicked(Sender: TControl);
    procedure NewOpening(Sender: TCommandButton; Menu: TMenuItem);
    procedure SortOpening(Sender: TCommandButton; Menu: TMenuItem);
    procedure ViewOpening(Sender: TCommandButton; Menu: TMenuItem);
    procedure FilterOpening(Sender: TCommandButton; Menu: TMenuItem);
    procedure OverflowOpening(Sender: TCommandButton; Menu: TMenuItem);
    procedure ItemsKeyDown(Sender: TControl; Code, Character, Modifiers: LongWord; var Handled: Boolean);
    procedure SelectionChanged(Sender: TControl);
    procedure SettingsChanged(Sender: TControl);
    procedure Zoomed(Sender: TItemView; Steps: LongInt);
    procedure KeyRefresh(Sender: TControlWindow);
    procedure KeyProperties(Sender: TControlWindow);
    procedure KeyBack(Sender: TControlWindow);
    procedure KeyForward(Sender: TControlWindow);
    procedure KeyUp(Sender: TControlWindow);
    procedure KeyAddress(Sender: TControlWindow);
    procedure KeySearch(Sender: TControlWindow);
    procedure KeyNewTab(Sender: TControlWindow);
    procedure KeyCloseTab(Sender: TControlWindow);
    procedure KeyNextTab(Sender: TControlWindow);
    procedure KeyPreviousTab(Sender: TControlWindow);
    procedure KeyNewWindow(Sender: TControlWindow);
    procedure KeyNewFolder(Sender: TControlWindow);
    procedure KeyPreview(Sender: TControlWindow);
    procedure KeyDetails(Sender: TControlWindow);
    procedure KeyHidden(Sender: TControlWindow);
    procedure KeyView(Sender: TControlWindow);
  protected
    procedure CommandsChanged; override;
    procedure FolderShown; override;
    procedure SelectionShown; override;
    procedure ShowOptions; override;
  public
    constructor Create;
    procedure TellPlaces; override;
  end;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Drawing.Rectangles,
  Windowing.Windows,
  Controls.Keys,
  Controls.ItemViewLayout,
  FileManager.Entries,
  FileManager.Locations,
  FileManager.Settings,
  FileManager.Commands,
  FileManager.SidePane,
  FileManager.OptionsDialog,
  FileManager.TestPlaces,
  FileManager.Output;

constructor TFileManagerWindow.Create;
begin
  inherited Create;
  BuildCommandBar;
  BuildAccelerators;
  FView.OnKeyDown := @ItemsKeyDown;
  FView.OnChange := @SelectionChanged;
  FView.OnSettingsChanged := @SettingsChanged;
  FView.OnZoom := @Zoomed;
  CommandsChanged;
end;

function TFileManagerWindow.AddButton(const Caption, Icon, Hint: string; Command: LongInt;
  ShowCaption: Boolean): TCommandButton;
begin
  Result := FCommandBar.AddCommand(Caption, CommandIcon(Icon), Hint, @ButtonClicked, ShowCaption);
  Result.Tag := Command;
end;

procedure TFileManagerWindow.BuildCommandBar;
begin
  FNewButton := FCommandBar.AddDropDown('New', CommandIcon('action-new'), 'Make a new folder or file', @NewOpening);
  FCommandBar.AddSeparator;
  FCutButton := AddButton('Cut', 'action-cut', 'Cut (Ctrl+X)', CommandCut, False);
  FCopyButton := AddButton('Copy', 'action-copy', 'Copy (Ctrl+C)', CommandCopy, False);
  FPasteButton := AddButton('Paste', 'action-paste', 'Paste (Ctrl+V)', CommandPaste, False);
  FRenameButton := AddButton('Rename', 'action-rename', 'Rename (F2)', CommandRename, False);
  FShareButton := AddButton('Share', 'action-share', 'Share: copy the path', CommandCopyPath, False);
  FDeleteButton := AddButton('Delete', 'action-delete', 'Delete (Del)', CommandDelete, False);
  FCommandBar.AddSeparator;
  FSortButton := FCommandBar.AddDropDown('Sort', CommandIcon('action-sort'), 'Sort and group the items',
    @SortOpening);
  FViewButton := FCommandBar.AddDropDown('View', CommandIcon('action-view'), 'How the items are shown',
    @ViewOpening);
  FFilterButton := FCommandBar.AddDropDown('Filter', CommandIcon('action-filter'), 'Show only some items',
    @FilterOpening);
  FCommandBar.AddSeparator;
  FExtractButton := AddButton('Extract all', 'action-extract', 'Extract the compressed folder', CommandExtract, True);
  FRestoreButton := AddButton('Restore', 'action-undo', 'Restore the selected items', CommandRestore, True);
  FRestoreAllButton := AddButton('Restore all', 'action-undo', 'Restore all items', CommandRestoreAll, True);
  FEmptyTrashButton := AddButton('Empty recycle bin', 'trash-empty', 'Delete everything in the recycle bin',
    CommandEmptyTrash, True);
  FPreviewButton := AddButton('Preview', 'action-preview-pane', 'Preview pane (Alt+P)', CommandPreviewPane, True);
  FPreviewButton.AlignRight := True;
  FPreviewButton.IsToggle := True;
  FDetailsButton := AddButton('Details', 'action-details-pane', 'Details pane (Alt+Shift+P)', CommandDetailsPane,
    True);
  FDetailsButton.AlignRight := True;
  FDetailsButton.IsToggle := True;
  FCommandBar.OnOverflowOpening := @OverflowOpening;
end;

procedure TFileManagerWindow.BuildAccelerators;
var
  Index: LongInt;
begin
  AddAccelerator(KeyF5, 0, @KeyRefresh);
  AddAccelerator(KeyR, ModifierControl, @KeyRefresh);
  AddAccelerator(KeyEnter, ModifierAlt, @KeyProperties);
  AddAccelerator(KeyArrowLeft, ModifierAlt, @KeyBack);
  AddAccelerator(KeyArrowRight, ModifierAlt, @KeyForward);
  AddAccelerator(KeyArrowUp, ModifierAlt, @KeyUp);
  AddAccelerator(KeyL, ModifierControl, @KeyAddress);
  AddAccelerator(KeyD, ModifierAlt, @KeyAddress);
  AddAccelerator(KeyF4, 0, @KeyAddress);
  AddAccelerator(KeyE, ModifierControl, @KeySearch);
  AddAccelerator(KeyF, ModifierControl, @KeySearch);
  AddAccelerator(KeyF3, 0, @KeySearch);
  AddAccelerator(KeyT, ModifierControl, @KeyNewTab);
  AddAccelerator(KeyW, ModifierControl, @KeyCloseTab);
  AddAccelerator(KeyTab, ModifierControl, @KeyNextTab);
  AddAccelerator(KeyTab, ModifierControl or ModifierShift, @KeyPreviousTab);
  AddAccelerator(KeyN, ModifierControl, @KeyNewWindow);
  AddAccelerator(KeyN, ModifierControl or ModifierShift, @KeyNewFolder);
  AddAccelerator(KeyP, ModifierAlt, @KeyPreview);
  AddAccelerator(KeyP, ModifierAlt or ModifierShift, @KeyDetails);
  AddAccelerator(KeyH, ModifierControl, @KeyHidden);
  for Index := 0 to 7 do
    AddAccelerator(Key1 + LongWord(Index), ModifierControl or ModifierShift, @KeyView);
end;

{ --- The command bar ------------------------------------------------------------------------- }

procedure TFileManagerWindow.ButtonClicked(Sender: TControl);
begin
  RunCommand(Sender.Tag);
end;

procedure TFileManagerWindow.NewOpening(Sender: TCommandButton; Menu: TMenuItem);
begin
  FillNewMenu(Menu);
end;

procedure TFileManagerWindow.SortOpening(Sender: TCommandButton; Menu: TMenuItem);
begin
  FillSortMenu(Menu);
end;

procedure TFileManagerWindow.ViewOpening(Sender: TCommandButton; Menu: TMenuItem);
begin
  FillViewMenu(Menu);
end;

procedure TFileManagerWindow.FilterOpening(Sender: TCommandButton; Menu: TMenuItem);
begin
  FillFilterMenu(Menu);
end;

procedure TFileManagerWindow.OverflowOpening(Sender: TCommandButton; Menu: TMenuItem);
begin
  FillOverflowMenu(Menu);
end;

procedure TFileManagerWindow.CommandsChanged;
var
  Kind: TLocationKind;
  Selected: Boolean;
  Real: Boolean;
  Entry: TFolderEntry;
  WasShown: Boolean;
begin
  if FNewButton = nil then
    Exit;
  Kind := FView.Location.Kind;
  Selected := HasSelection;
  Entry := FocusedEntry;
  Real := Selected and (Entry <> nil) and Entry.IsRealFile;
  FNewButton.Enabled := Kind = LocationFolder;
  FCutButton.Enabled := Real and (Kind = LocationFolder);
  FCopyButton.Enabled := Selected and (Kind in [LocationFolder, LocationArchive, LocationSearch, LocationHome,
    LocationGallery]);
  FPasteButton.Enabled := CanPaste;
  FRenameButton.Enabled := Real;
  FShareButton.Enabled := Selected or (FView.Folder <> '');
  FDeleteButton.Enabled := Selected and (Real or (Kind = LocationTrash));
  if Kind = LocationTrash then
    FDeleteButton.Hint := 'Delete permanently (Del)'
  else
    FDeleteButton.Hint := 'Delete (Del)';
  FFilterButton.Enabled := not (Kind in [LocationHome, LocationComputer, LocationNetwork]);
  WasShown := FExtractButton.Visible;
  FExtractButton.Visible := FocusedIsArchive or (Kind = LocationArchive);
  { Appearing: where it is now (for tests). }
  if FExtractButton.Visible and not WasShown then
    FCommandBar.RequestLayout;
  FExtractDue := FExtractButton.Visible and not WasShown;
  FRestoreButton.Visible := (Kind = LocationTrash) and Selected;
  FRestoreAllButton.Visible := Kind = LocationTrash;
  FEmptyTrashButton.Visible := Kind = LocationTrash;
  FPreviewButton.Down := SidePaneShown and (FSidePane.Kind = SidePanePreview);
  FDetailsButton.Down := SidePaneShown and (FSidePane.Kind = SidePaneDetails);
end;

procedure TFileManagerWindow.FolderShown;
begin
  inherited FolderShown;
  CommandsChanged;
end;

procedure TFileManagerWindow.SelectionShown;
begin
  inherited SelectionShown;
  CommandsChanged;
end;

procedure TFileManagerWindow.SelectionChanged(Sender: TControl);
var
  Box: TRectangle;
begin
  SelectionShown;
  Say('selected ' + IntToStr(FView.SelectedCount));
  if FExtractDue then
  begin
    FExtractDue := False;
    Box := FCommandBar.ButtonBounds(FExtractButton);
    if RectangleWidth(Box) > 0 then
      TellPlace('command-extract', FCommandBar, Box.Left + RectangleWidth(Box) div 2,
        Box.Top + RectangleHeight(Box) div 2);
  end;
end;

procedure TFileManagerWindow.SettingsChanged(Sender: TControl);
begin
  CommandsChanged;
  FView.TellPlaces;
end;

procedure TFileManagerWindow.Zoomed(Sender: TItemView; Steps: LongInt);
const
  { Small to large, as Ctrl and the wheel go through them. }
  Order: array[0..6] of TItemViewMode = (ItemViewDetails, ItemViewList, ItemViewSmallIcons, ItemViewMediumIcons,
    ItemViewLargeIcons, ItemViewExtraLargeIcons, ItemViewExtraLargeIcons);
var
  Index: LongInt;
  Current: LongInt;
begin
  Current := 0;
  for Index := 0 to 5 do
    if Order[Index] = FView.Mode then
      Current := Index;
  Current := Current + Steps;
  if Current < 0 then
    Current := 0;
  if Current > 5 then
    Current := 5;
  if Order[Current] <> FView.Mode then
    RunCommand(CommandViewBase + Ord(Order[Current]));
end;

procedure TFileManagerWindow.ShowOptions;
begin
  if ShowOptionsDialog(Self, FOptions) then
  begin
    RememberOptions(FOptions);
    FView.Compact := FOptions.Compact;
    FView.ShowCheckBoxes := FOptions.ShowCheckBoxes;
    FView.SingleClickOpens := FOptions.SingleClick;
    FView.SetShowHidden(FOptions.ShowHidden);
    FView.SetShowExtensions(FOptions.ShowExtensions);
    FView.SetHomeSections(FOptions.ShowRecent, FOptions.ShowFavorites);
    Say('options saved');
  end;
end;

{ --- Keys ------------------------------------------------------------------------------------- }

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
    RunCommand(CommandDelete)
  else if (Code = KeyDelete) and (Held = ModifierShift) then
    RunCommand(CommandDeletePermanently)
  else if (Code = KeyF2) and (Held = 0) then
    RunCommand(CommandRename)
  else if (Code = KeyBackspace) and (Held = 0) then
    GoUp
  else if (Code = KeyC) and (Held = ModifierControl) then
    RunCommand(CommandCopy)
  else if (Code = KeyC) and (Held = ModifierControl or ModifierShift) then
    RunCommand(CommandCopyPath)
  else if (Code = KeyX) and (Held = ModifierControl) then
    RunCommand(CommandCut)
  else if (Code = KeyV) and (Held = ModifierControl) then
    RunCommand(CommandPaste)
  else if (Code = KeyZ) and (Held = ModifierControl) then
    RunCommand(CommandUndo)
  else if (Code = KeyY) and (Held = ModifierControl) then
    RunCommand(CommandRedo)
  else if IsEnterKey(Code) and (Held = ModifierControl) then
    RunCommand(CommandOpenInNewWindow)
  else
    Handled := False;
end;

procedure TFileManagerWindow.KeyRefresh(Sender: TControlWindow);
begin
  RunCommand(CommandRefresh);
end;

procedure TFileManagerWindow.KeyProperties(Sender: TControlWindow);
begin
  RunCommand(CommandProperties);
end;

procedure TFileManagerWindow.KeyBack(Sender: TControlWindow);
begin
  GoBack;
end;

procedure TFileManagerWindow.KeyForward(Sender: TControlWindow);
begin
  GoForward;
end;

procedure TFileManagerWindow.KeyUp(Sender: TControlWindow);
begin
  GoUp;
end;

procedure TFileManagerWindow.KeyAddress(Sender: TControlWindow);
begin
  FocusAddress;
end;

procedure TFileManagerWindow.KeySearch(Sender: TControlWindow);
begin
  FocusSearch;
end;

procedure TFileManagerWindow.KeyNewTab(Sender: TControlWindow);
begin
  RunCommand(CommandNewTab);
end;

procedure TFileManagerWindow.KeyCloseTab(Sender: TControlWindow);
begin
  RunCommand(CommandCloseTab);
end;

procedure TFileManagerWindow.KeyNextTab(Sender: TControlWindow);
begin
  NextTab(True);
end;

procedure TFileManagerWindow.KeyPreviousTab(Sender: TControlWindow);
begin
  NextTab(False);
end;

procedure TFileManagerWindow.KeyNewWindow(Sender: TControlWindow);
begin
  RunCommand(CommandNewWindow);
end;

procedure TFileManagerWindow.KeyNewFolder(Sender: TControlWindow);
begin
  RunCommand(CommandNewFolder);
end;

procedure TFileManagerWindow.KeyPreview(Sender: TControlWindow);
begin
  RunCommand(CommandPreviewPane);
end;

procedure TFileManagerWindow.KeyDetails(Sender: TControlWindow);
begin
  RunCommand(CommandDetailsPane);
end;

procedure TFileManagerWindow.KeyHidden(Sender: TControlWindow);
begin
  RunCommand(CommandHiddenItems);
end;

procedure TFileManagerWindow.KeyView(Sender: TControlWindow);
var
  Index: LongInt;
begin
  { Which of Ctrl+Shift+1 to 8: the key last pressed. }
  Index := LastAcceleratorCode - Key1;
  if (Index >= 0) and (Index <= Ord(High(TItemViewMode))) then
    RunCommand(CommandViewBase + Index);
end;

procedure TFileManagerWindow.TellPlaces;
  procedure TellButton(const Name: string; Button: TCommandButton);
  var
    Box: TRectangle;
  begin
    Box := FCommandBar.ButtonBounds(Button);
    if RectangleWidth(Box) > 0 then
      TellPlace(Name, FCommandBar, Box.Left + RectangleWidth(Box) div 2, Box.Top + RectangleHeight(Box) div 2);
  end;
begin
  if FNewButton = nil then
  begin
    inherited TellPlaces;
    Exit;
  end;
  TellButton('command-new', FNewButton);
  TellButton('command-cut', FCutButton);
  TellButton('command-copy', FCopyButton);
  TellButton('command-paste', FPasteButton);
  TellButton('command-rename', FRenameButton);
  TellButton('command-share', FShareButton);
  TellButton('command-delete', FDeleteButton);
  TellButton('command-sort', FSortButton);
  TellButton('command-view', FViewButton);
  TellButton('command-filter', FFilterButton);
  TellButton('command-extract', FExtractButton);
  TellButton('command-more', FCommandBar.OverflowButton);
  TellButton('command-details', FDetailsButton);
  TellButton('command-preview', FPreviewButton);
  inherited TellPlaces;
end;

end.
