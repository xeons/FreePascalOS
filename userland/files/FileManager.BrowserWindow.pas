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
  The file manager's window as far as finding one's way goes: its
  parts, laid out, and going from folder to folder.

  From the top: the menu bar (its menus are FileManager.MainWindow's),
  the toolbar (Back, Forward, Up, then what the main window adds), the
  address box (type a folder and press Enter to go there; Ctrl+L or
  Alt+D selects it), then the places at the left (FileManager.
  PlacesPane) beside the folder's items (FileManager.FolderView), with
  a splitter between them to drag, and the status bar at the bottom:
  how many items there are, and how many are selected and their size.

  Going to a folder adds it to the history (FileManager.History) for
  Back and Forward; Up goes to the folder above. The title is the
  folder's name. A folder that goes away while shown (removed, or its
  volume unplugged) is left for the nearest folder above it that is
  still there (or the home folder), and forgotten from the history. It
  prints "folder PATH COUNT" for each folder shown, and where its parts
  are.
}
unit FileManager.BrowserWindow;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Controls.Base,
  Controls.Window,
  Controls.Panels,
  Controls.Labels,
  Controls.EditBox,
  Controls.Menus,
  Controls.ToolBar,
  Controls.ImageList,
  Controls.StatusBar,
  Controls.Splitter,
  FileManager.Settings,
  FileManager.History,
  FileManager.FolderView,
  FileManager.PlacesPane;

type
  TBrowserWindow = class(TControlWindow)
  private
    FHistory: TNavigationHistory;
    FAddressPanel: TPanel;
    FAddressLabel: TLabel;
    FBackButton: TToolButton;
    FForwardButton: TToolButton;
    FUpButton: TToolButton;
    procedure BackClicked(Sender: TControl);
    procedure ForwardClicked(Sender: TControl);
    procedure UpClicked(Sender: TControl);
    procedure AddressKeyDown(Sender: TControl; Code, Character, Modifiers: LongWord; var Handled: Boolean);
    procedure PlaceChosen(Sender: TControl; const Path: string);
    procedure VolumeRemoved(Sender: TControl; const VolumeName, MountPoint: string);
    procedure FolderGone(Sender: TControl);
    procedure FolderRefreshed(Sender: TControl);
    procedure PlaceStatusPanels;
    procedure FocusAddress(Sender: TControlWindow);
  protected
    FSettings: TFileManagerSettings;
    FMenuBar: TMenuBar;
    FToolBar: TToolBar;
    { The toolbar's pictures (the theme's icons; none without them). }
    FToolImages: TImageList;
    FAddressBox: TEditBox;
    FPlaces: TPlacesPane;
    FSplitter: TSplitter;
    FView: TFolderView;
    FStatusBar: TStatusBar;
    { The scale changed: the places are told again once laid out. }
    FScaleWasChanged: Boolean;
    procedure Resized; override;
    { Moved by the user: where things are is told again (for tests). }
    procedure Moved; override;
    procedure ScaleChanged; override;
    { The folder shown changed (another folder, or read again). }
    procedure FolderShown; virtual;
    procedure UpdateNavigation;
  public
    constructor Create;
    destructor Destroy; override;
    { Goes to Folder (a path typed or chosen); False (after saying why)
      if it cannot be shown. AddToHistory: not for Back and Forward. }
    function Navigate(const Folder: string; AddToHistory: Boolean = True): Boolean;
    procedure GoBack;
    procedure GoForward;
    procedure GoUp;
    procedure RefreshFolder;
    procedure UpdateStatus;
    { Says where the window's parts are (place NAME X Y). }
    procedure TellPlaces; virtual;
  end;

const
  ProgramTitle = 'Files';

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Files,
  Windowing.Windows,
  Controls.Keys,
  Controls.MessageBoxes,
  Controls.Icons,
  Controls.IconTheme,
  Controls.FileNames,
  Controls.FolderListing,
  FileManager.Paths,
  FileManager.ErrorTexts,
  FileManager.TestPlaces,
  FileManager.Output;

const
  AddressHeight = 28;
  ItemsPanelWidth = 160;

constructor TBrowserWindow.Create;
begin
  FSettings := RememberedSettings;
  inherited Create(ProgramTitle, FSettings.WindowLeft, FSettings.WindowTop, FSettings.WindowWidth,
    FSettings.WindowHeight);
  FHistory := TNavigationHistory.Create;
  { Docked in the order made: the bars at the top, the status bar at the
    bottom, the places at the left, the splitter on their edge, and the
    items in what is left. }
  FMenuBar := TMenuBar.Create(Root);
  FToolBar := TToolBar.Create(Root);
  FToolImages := TImageList.Create(SmallIconSize, SmallIconSize);
  FToolBar.Images := FToolImages;
  FBackButton := FToolBar.AddImageButton(AddThemeIcon(FToolImages, 'action-back'), 'Back', '', 74, @BackClicked);
  FForwardButton := FToolBar.AddImageButton(AddThemeIcon(FToolImages, 'action-forward'), 'Forward', '', 84,
    @ForwardClicked);
  FUpButton := FToolBar.AddImageButton(AddThemeIcon(FToolImages, 'action-up'), 'Up', '', 52, @UpClicked);
  FAddressPanel := TPanel.Create(Root);
  FAddressPanel.SetBounds(0, 0, 0, AddressHeight);
  FAddressPanel.Align := AlignTop;
  FAddressLabel := TLabel.Create(FAddressPanel);
  FAddressLabel.Text := 'A&ddress:';
  FAddressLabel.SetBounds(6, 6, 60, 18);
  FAddressBox := TEditBox.Create(FAddressPanel);
  FAddressBox.OnKeyDown := @AddressKeyDown;
  FStatusBar := TStatusBar.Create(Root);
  FPlaces := TPlacesPane.Create(Root);
  FPlaces.SetBounds(0, 0, FSettings.PlacesWidth, 0);
  FPlaces.Align := AlignLeft;
  FPlaces.OnPlaceChosen := @PlaceChosen;
  FPlaces.OnVolumeRemoved := @VolumeRemoved;
  FSplitter := TSplitter.Create(Root);
  FSplitter.Pane := FPlaces;
  FView := TFolderView.Create(Root);
  FView.Align := AlignClient;
  FView.ViewMode := FSettings.View;
  FView.ShowHidden := FSettings.ShowHidden;
  FView.SortBy(FSettings.SortColumn, FSettings.SortAscending);
  FView.OnFolderGone := @FolderGone;
  FView.OnRefreshed := @FolderRefreshed;
  AddAccelerator(KeyL, ModifierControl, @FocusAddress);
  PlaceStatusPanels;
  Resized;
  FocusControl(FView);
end;

destructor TBrowserWindow.Destroy;
var
  Images: TImageList;
begin
  FHistory.Free;
  { The toolbar goes with the window, before its pictures. }
  Images := FToolImages;
  inherited Destroy;
  Images.Free;
end;

procedure TBrowserWindow.PlaceStatusPanels;
begin
  FStatusBar.SetPanels([ItemsPanelWidth, ClientWidth - ItemsPanelWidth]);
end;

procedure TBrowserWindow.Moved;
begin
  inherited Moved;
  if FAddressBox <> nil then
    TellPlaces;
end;

procedure TBrowserWindow.Resized;
begin
  inherited Resized;
  if FAddressBox = nil then
    Exit;
  FAddressBox.SetBounds(68, 3, ClientWidth - 68 - 6, 22);
  PlaceStatusPanels;
  if FScaleWasChanged then
  begin
    FScaleWasChanged := False;
    TellPlaces;
  end;
end;

procedure TBrowserWindow.ScaleChanged;
begin
  inherited ScaleChanged;
  FScaleWasChanged := True;
end;

procedure TBrowserWindow.FocusAddress(Sender: TControlWindow);
begin
  FocusControl(FAddressBox);
  FAddressBox.SelectAll;
end;

{ --- Going places ----------------------------------------------------------------------- }

function TBrowserWindow.Navigate(const Folder: string; AddToHistory: Boolean): Boolean;
var
  Target: string;
  Error: LongInt;
  Information: TFileInformation;
begin
  Target := CleanPath(Folder);
  Error := GetFileInformation(PChar(Target), Information);
  if (Error = ErrorNone) and (Information.Kind <> KindDirectory) then
    Error := ErrorNotDirectory;
  if Error = ErrorNone then
    Error := FView.ShowFolder(Target);
  if Error <> ErrorNone then
  begin
    Say('error cannot show ' + Target + ': ' + ReasonText(Error));
    if Error = ErrorNotDirectory then
      ShowMessageBox(ProgramTitle, Target + ' is not a folder.', MessageOk, SignError, Self)
    else
      ShowMessageBox(ProgramTitle, 'Cannot show ' + Target + ':'#10 + ReasonText(Error), MessageOk, SignError, Self);
    { The folder shown before stays (read again, in case it went). }
    FAddressBox.Text := FView.Folder;
    Exit(False);
  end;
  if AddToHistory then
    FHistory.Visit(Target);
  FolderShown;
  Result := True;
end;

procedure TBrowserWindow.FolderShown;
var
  Name: string;
begin
  Name := LastPartOf(FView.Folder);
  if Name = '' then
    Name := 'File system';
  Title := Name + ' - ' + ProgramTitle;
  FAddressBox.Text := FView.Folder;
  FPlaces.ShowPath(FView.Folder);
  UpdateNavigation;
  UpdateStatus;
  Say('folder ' + FView.Folder + ' ' + IntToStr(FView.RowCount));
  FView.TellPlaces;
end;

procedure TBrowserWindow.UpdateNavigation;
begin
  FBackButton.Enabled := FHistory.CanGoBack;
  FForwardButton.Enabled := FHistory.CanGoForward;
  FUpButton.Enabled := FView.Folder <> '/';
end;

procedure TBrowserWindow.GoBack;
var
  Current: string;
begin
  if not FHistory.CanGoBack then
    Exit;
  Current := FView.Folder;
  if not Navigate(FHistory.GoBack, False) then
    FHistory.GoForward;
  { Coming back up: the folder just left is selected, as one expects. }
  if IsSameOrInside(Current, FView.Folder) then
    FView.ItemIndex := FView.IndexOfName(LastPartOf(Current));
end;

procedure TBrowserWindow.GoForward;
begin
  if not FHistory.CanGoForward then
    Exit;
  if not Navigate(FHistory.GoForward, False) then
    FHistory.GoBack;
end;

procedure TBrowserWindow.GoUp;
var
  Current: string;
begin
  Current := FView.Folder;
  if Current = '/' then
    Exit;
  if Navigate(ParentFolderOf(Current)) then
    FView.ItemIndex := FView.IndexOfName(LastPartOf(Current));
end;

procedure TBrowserWindow.RefreshFolder;
begin
  FView.Refresh;
end;

procedure TBrowserWindow.BackClicked(Sender: TControl);
begin
  GoBack;
end;

procedure TBrowserWindow.ForwardClicked(Sender: TControl);
begin
  GoForward;
end;

procedure TBrowserWindow.UpClicked(Sender: TControl);
begin
  GoUp;
end;

procedure TBrowserWindow.AddressKeyDown(Sender: TControl; Code, Character, Modifiers: LongWord; var Handled: Boolean);
begin
  if IsEnterKey(Code) then
  begin
    Handled := True;
    if Navigate(CombinePath(FView.Folder, FAddressBox.Text)) then
      FocusControl(FView);
  end
  else if Code = KeyEscape then
  begin
    Handled := True;
    FAddressBox.Text := FView.Folder;
    FocusControl(FView);
  end;
end;

procedure TBrowserWindow.PlaceChosen(Sender: TControl; const Path: string);
begin
  Navigate(Path);
end;

{ The nearest folder at or above Path that can be shown, else home. }
function NearestFolder(const Path: string): string;
begin
  Result := Path;
  while (Result <> '/') and not IsDirectory(PChar(Result)) do
    Result := ParentFolderOf(Result);
  if not IsDirectory(PChar(Result)) then
    Result := HomeFolder;
end;

procedure TBrowserWindow.FolderGone(Sender: TControl);
var
  Gone: string;
begin
  Gone := FView.Folder;
  Say('folder-gone ' + Gone);
  FHistory.Forget(Gone);
  Navigate(NearestFolder(ParentFolderOf(Gone)));
end;

procedure TBrowserWindow.FolderRefreshed(Sender: TControl);
begin
  UpdateStatus;
end;

procedure TBrowserWindow.VolumeRemoved(Sender: TControl; const VolumeName, MountPoint: string);
begin
  FHistory.Forget(MountPoint);
  if IsSameOrInside(FView.Folder, MountPoint) then
    FolderGone(FView);
  UpdateNavigation;
end;

{ --- Status ------------------------------------------------------------------------------ }

procedure TBrowserWindow.UpdateStatus;
var
  Count: LongInt;
  Chosen: LongInt;
begin
  Count := FView.RowCount;
  if Count = 1 then
    FStatusBar.PanelText[0] := '1 item'
  else
    FStatusBar.PanelText[0] := IntToStr(Count) + ' items';
  Chosen := FView.SelectedCount;
  if Chosen = 0 then
    FStatusBar.PanelText[1] := ''
  else
    FStatusBar.PanelText[1] := IntToStr(Chosen) + ' selected (' + SizeText(FView.SelectedTotalSize) + ')';
end;

procedure TBrowserWindow.TellPlaces;
begin
  TellControlPlace('back', FBackButton);
  TellControlPlace('forward', FForwardButton);
  TellControlPlace('up', FUpButton);
  TellControlPlace('address', FAddressBox);
  FPlaces.TellPlaces;
  FView.TellPlaces;
end;

end.
