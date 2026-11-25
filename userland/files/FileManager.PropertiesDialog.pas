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
  The properties of a file, folder or link, on three pages:

  * General: its icon and name, type, location, size and size on disk
    (a folder's added up in the background, the count running:
    FileManager.FolderSizeCounter, with what it contains), when it was
    created, modified and accessed, and its attributes: read-only (no
    one may write it: the write bits) and hidden (its name starts with a
    dot: ticking it renames the item);
  * Security: its owner and group (root may change them: chown) and its
    permissions as check boxes, read, write and execute for the owner,
    the group and everyone else; the owner (or root) changes them at
    once (chmod), others see them greyed;
  * Details: every property there is: the full path, the link's target,
    a picture's dimensions, a sound's format and length, the change
    time, the mode in octal, the node and link count.

  A change that fails says why and the box goes back. It prints
  "properties PATH size BYTES mode OCTAL" when it opens, "properties-
  size PATH BYTES FILES FOLDERS" when a folder's size is added up,
  "mode PATH OCTAL", "owner PATH USER GROUP", "hidden PATH" for
  changes, and where its parts are.
}
unit FileManager.PropertiesDialog;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Windows;

{ Shows the properties of the item at Path. }
procedure ShowItemProperties(const Path: string; Owner: TWindow);

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Files,
  Drawing.Rectangles,
  Drawing.Canvas,
  Drawing.Surfaces,
  Controls.Base,
  Controls.Labels,
  Controls.Panels,
  Controls.Toggles,
  Controls.Buttons,
  Controls.EditBox,
  Controls.Icons,
  Controls.IconTheme,
  Controls.Dialogs,
  Controls.TabControl,
  Controls.MessageBoxes,
  Controls.FileNames,
  Controls.FolderListing,
  Controls.ThumbnailLoader,
  Util.Accounts,
  FileManager.Items,
  FileManager.Entries,
  FileManager.FileTypes,
  FileManager.FileKinds,
  FileManager.Permissions,
  FileManager.TimeTexts,
  FileManager.FolderReading,
  FileManager.FolderSizeCounter,
  FileManager.FolderView,
  FileManager.ItemColumns,
  FileManager.AudioInfo,
  FileManager.Paths,
  FileManager.ErrorTexts,
  FileManager.TestPlaces,
  FileManager.Output;

type
  { Controls.FolderListing has a TFolderEntry of its own. }
  TFolderEntry = FileManager.Entries.TFolderEntry;

const
  DialogWidth = 420;
  DialogHeight = 470;
  Margin = 12;
  RowHeight = 20;
  CaptionWidth = 110;
  CountTimer = 1;
  CountMilliseconds = 200;

type
  { The item's icon, drawn at the top. }
  TItemIconControl = class(TControl)
  private
    FIconName: string;
    FOverlay: TIconOverlay;
  protected
    procedure Paint(var Canvas: TCanvas); override;
  end;

  TPropertiesDialog = class(TDialog)
  private
    FPath: string;
    FItem: TFolderItem;
    FMode: LongWord;
    FTop: LongInt;
    FPages: TTabControl;
    FGeneral: TControl;
    FSecurity: TControl;
    FDetails: TControl;
    FSizeLabel: TLabel;
    FDiskLabel: TLabel;
    FContainsLabel: TLabel;
    FOctalLabel: TLabel;
    FReadOnlyBox: TCheckBox;
    FHiddenBox: TCheckBox;
    FOwnerBox: TEditBox;
    FGroupBox: TEditBox;
    FApplyOwnerButton: TButton;
    FCounter: TFolderSizeCounter;
    FBoxes: array[TPermissionClass, TPermissionRight] of TCheckBox;
    function AddRow(Page: TControl; const Caption, Value: string): TLabel;
    procedure BuildGeneral;
    procedure BuildSecurity;
    procedure BuildDetails;
    procedure AddPermissions(Page: TControl);
    procedure PermissionClicked(Sender: TControl);
    procedure ReadOnlyClicked(Sender: TControl);
    procedure HiddenClicked(Sender: TControl);
    procedure ApplyOwnerClicked(Sender: TControl);
    procedure PageChanged(Sender: TControl);
    procedure SetMode(NewMode: LongWord);
    procedure ShowCounts;
    function MayChangeMode: Boolean;
  protected
    procedure TimerFired(TimerId: LongWord); override;
  public
    constructor CreateFor(const APath: string; const AItem: TFolderItem; AOwner: TWindow);
    destructor Destroy; override;
    procedure TellPlaces;
  end;

procedure TItemIconControl.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  if not DrawThemeIcon(Canvas, FIconName, Box) then
    DrawStockIcon(Canvas, StockIconFile, Box);
  DrawIconOverlay(Canvas, FOverlay, Box);
end;

function NameOrNumber(const Name: string; Number: LongWord): string;
begin
  if Name = '' then
    Result := IntToStr(Number)
  else
    Result := Name + ' (' + IntToStr(Number) + ')';
end;

function CountText(Count: QWord; const Noun: string): string;
begin
  Result := IntToStr(Count) + ' ' + Noun;
  if Count <> 1 then
    Result := Result + 's';
end;

function BytesText(Bytes: QWord): string;
begin
  Result := SizeText(Bytes);
  if Bytes >= 1024 then
    Result := Result + ' (' + IntToStr(Bytes) + ' bytes)';
end;

constructor TPropertiesDialog.CreateFor(const APath: string; const AItem: TFolderItem; AOwner: TWindow);
begin
  inherited CreateDialog(AItem.Name + ' Properties', DialogWidth, DialogHeight, AOwner);
  FPath := APath;
  FItem := AItem;
  FMode := AItem.Mode and $FFF;
  FPages := TTabControl.Create(Root);
  FPages.SetBounds(8, 8, DialogWidth - 16, DialogHeight - 8 - 23 - 2 * 8);
  FGeneral := FPages.AddPage('General');
  FSecurity := FPages.AddPage('Security');
  FDetails := FPages.AddPage('Details');
  FPages.OnChange := @PageChanged;
  BuildGeneral;
  BuildSecurity;
  BuildDetails;
  AddButton('Close', ResultOk, DialogWidth - 8 - 75, DialogHeight - 8 - 23, 75, 23, True, True);
  FocusControl(DefaultControl);
end;

destructor TPropertiesDialog.Destroy;
begin
  { Waits for the count's thread, which reads this dialog's path. }
  FCounter.Free;
  inherited Destroy;
end;

function TPropertiesDialog.AddRow(Page: TControl; const Caption, Value: string): TLabel;
var
  CaptionLabel: TLabel;
begin
  CaptionLabel := TLabel.Create(Page);
  CaptionLabel.ShowsMnemonic := False;
  CaptionLabel.Text := Caption;
  CaptionLabel.SetBounds(Margin, FTop, CaptionWidth, RowHeight);
  Result := TLabel.Create(Page);
  Result.ShowsMnemonic := False;
  Result.Text := Value;
  Result.SetBounds(Margin + CaptionWidth, FTop, DialogWidth - 40 - 2 * Margin - CaptionWidth, RowHeight);
  FTop := FTop + RowHeight;
end;

procedure TPropertiesDialog.BuildGeneral;
var
  Icon: TItemIconControl;
  NameLabel: TLabel;
  Entry: TFolderEntry;
  Information: TFileInformation;
begin
  Icon := TItemIconControl.Create(FGeneral);
  Entry := TFolderEntry.Create;
  try
    Entry.Item := FItem;
    Entry.FullPath := FPath;
    Icon.FIconName := EntryIconName(Entry);
  finally
    Entry.Free;
  end;
  if FItem.IsLink then
    Icon.FOverlay := OverlayLink;
  Icon.SetBounds(Margin, Margin, 32, 32);
  NameLabel := TLabel.Create(FGeneral);
  NameLabel.ShowsMnemonic := False;
  NameLabel.Text := FItem.Name;
  NameLabel.SetBounds(Margin + 44, Margin + 7, DialogWidth - 60 - 2 * Margin, 18);
  FTop := Margin + 48;
  AddRow(FGeneral, 'Type:', TypeTextOf(FItem));
  AddRow(FGeneral, 'Location:', ParentFolderOf(FPath));
  if FItem.Kind = ItemFolder then
  begin
    FSizeLabel := AddRow(FGeneral, 'Size:', 'Counting...');
    FContainsLabel := AddRow(FGeneral, 'Contains:', 'Counting...');
    FCounter := TFolderSizeCounter.Create(FPath);
    FCounter.Start;
    StartTimer(CountTimer, CountMilliseconds);
  end
  else
  begin
    FSizeLabel := AddRow(FGeneral, 'Size:', BytesText(FItem.SizeInBytes));
    if GetFileInformation(PChar(FPath), Information) = ErrorNone then
      FDiskLabel := AddRow(FGeneral, 'Size on disk:', BytesText(Information.AllocatedBytes));
  end;
  FTop := FTop + 8;
  if FItem.BirthTime <> 0 then
    AddRow(FGeneral, 'Created:', TimeText(FItem.BirthTime));
  AddRow(FGeneral, 'Modified:', TimeText(FItem.ModificationTime));
  AddRow(FGeneral, 'Accessed:', TimeText(FItem.AccessTime));
  FTop := FTop + 8;
  FReadOnlyBox := TCheckBox.Create(FGeneral);
  FReadOnlyBox.Text := '&Read-only';
  FReadOnlyBox.Checked := (FMode and $92) = 0;
  FReadOnlyBox.Enabled := MayChangeMode;
  FReadOnlyBox.SetBounds(Margin, FTop, 120, RowHeight);
  FReadOnlyBox.OnClick := @ReadOnlyClicked;
  FHiddenBox := TCheckBox.Create(FGeneral);
  FHiddenBox.Text := '&Hidden';
  FHiddenBox.Checked := IsHiddenName(FItem.Name);
  FHiddenBox.SetBounds(Margin + 130, FTop, 120, RowHeight);
  FHiddenBox.OnClick := @HiddenClicked;
end;

procedure TPropertiesDialog.BuildSecurity;
var
  Caption: TLabel;
  OwnerName: string;
  GroupName: string;
begin
  FTop := Margin;
  if not FindUserName(FItem.OwnerId, OwnerName) then
    OwnerName := IntToStr(FItem.OwnerId);
  if not FindGroupName(FItem.GroupId, GroupName) then
    GroupName := IntToStr(FItem.GroupId);
  Caption := TLabel.Create(FSecurity);
  Caption.Text := '&Owner:';
  Caption.SetBounds(Margin, FTop + 2, CaptionWidth, RowHeight);
  FOwnerBox := TEditBox.Create(FSecurity);
  FOwnerBox.Text := OwnerName;
  FOwnerBox.SetBounds(Margin + CaptionWidth, FTop, 140, 22);
  FTop := FTop + 28;
  Caption := TLabel.Create(FSecurity);
  Caption.Text := '&Group:';
  Caption.SetBounds(Margin, FTop + 2, CaptionWidth, RowHeight);
  FGroupBox := TEditBox.Create(FSecurity);
  FGroupBox.Text := GroupName;
  FGroupBox.SetBounds(Margin + CaptionWidth, FTop, 140, 22);
  FApplyOwnerButton := TButton.Create(FSecurity);
  FApplyOwnerButton.Text := '&Apply';
  FApplyOwnerButton.SetBounds(Margin + CaptionWidth + 150, FTop, 80, 22);
  FApplyOwnerButton.OnClick := @ApplyOwnerClicked;
  { Only root gives things away. }
  FOwnerBox.Enabled := CurrentUserId = 0;
  FGroupBox.Enabled := (CurrentUserId = 0) or (CurrentUserId = FItem.OwnerId);
  FApplyOwnerButton.Enabled := FGroupBox.Enabled;
  FTop := FTop + 34;
  AddPermissions(FSecurity);
  FOctalLabel := AddRow(FSecurity, 'Mode:', OctalModeText(FMode) + '  ' + PermissionText(FMode));
end;

procedure TPropertiesDialog.BuildDetails;
var
  Information: TFileInformation;
  Picture: TSurface;
  Width: LongInt;
  Height: LongInt;
  Audio: TAudioInfo;
begin
  FTop := Margin;
  AddRow(FDetails, 'Name:', FItem.Name);
  AddRow(FDetails, 'Item type:', TypeTextOf(FItem));
  AddRow(FDetails, 'Path:', FPath);
  if FItem.IsLink then
    AddRow(FDetails, 'Points to:', FItem.LinkTarget);
  if FItem.Kind = ItemFile then
    AddRow(FDetails, 'Size:', BytesText(FItem.SizeInBytes));
  if (FItem.Kind = ItemFile) and (FileKindOfName(FItem.Name) = FileKindPicture) and
     MakeThumbnail(FPath, 32, Picture, Width, Height) then
  begin
    FreeSurface(Picture);
    AddRow(FDetails, 'Dimensions:', IntToStr(Width) + ' x ' + IntToStr(Height));
    AddRow(FDetails, 'Width:', IntToStr(Width) + ' pixels');
    AddRow(FDetails, 'Height:', IntToStr(Height) + ' pixels');
  end;
  if (FItem.Kind = ItemFile) and (FileKindOfName(FItem.Name) = FileKindMusic) and ReadAudioInfo(FPath, Audio) then
  begin
    AddRow(FDetails, 'Length:', DurationText(Audio.DurationSeconds));
    AddRow(FDetails, 'Sample rate:', IntToStr(Audio.SampleRate) + ' Hz');
    AddRow(FDetails, 'Channels:', IntToStr(Audio.Channels));
    AddRow(FDetails, 'Bits per sample:', IntToStr(Audio.BitsPerSample));
  end;
  if FItem.BirthTime <> 0 then
    AddRow(FDetails, 'Date created:', TimeText(FItem.BirthTime));
  AddRow(FDetails, 'Date modified:', TimeText(FItem.ModificationTime));
  AddRow(FDetails, 'Date accessed:', TimeText(FItem.AccessTime));
  AddRow(FDetails, 'Date changed:', TimeText(FItem.ChangeTime));
  AddRow(FDetails, 'Owner:', NameOrNumber(OwnerName(FItem.OwnerId), FItem.OwnerId));
  AddRow(FDetails, 'Group:', NameOrNumber(GroupName(FItem.GroupId), FItem.GroupId));
  AddRow(FDetails, 'Mode:', OctalModeText(FMode));
  if GetLinkInformation(PChar(FPath), Information) = ErrorNone then
  begin
    AddRow(FDetails, 'Node:', IntToStr(Information.NodeNumber));
    AddRow(FDetails, 'Links:', IntToStr(Information.LinkCount));
    AddRow(FDetails, 'Volume:', IntToStr(Information.VolumeNumber));
  end;
end;

function TPropertiesDialog.MayChangeMode: Boolean;
begin
  Result := ((CurrentUserId = 0) or (CurrentUserId = FItem.OwnerId)) and not FItem.IsBrokenLink;
end;

procedure TPropertiesDialog.AddPermissions(Page: TControl);
const
  ClassCaptions: array[TPermissionClass] of string = ('Owner', 'Group', 'Others');
  RightCaptions: array[TPermissionRight] of string = ('Read', 'Write', 'Execute');
  ColumnLeft = 100;
  ColumnWidth = 80;
var
  Group: TGroupBox;
  Who: TPermissionClass;
  Right: TPermissionRight;
  HeaderLabel: TLabel;
  RowLabel: TLabel;
  Box: TCheckBox;
  Top: LongInt;
begin
  Group := TGroupBox.Create(Page);
  Group.Text := 'Permissions';
  Group.SetBounds(Margin, FTop, DialogWidth - 40 - 2 * Margin, 104);
  Top := 18;
  for Right := Low(TPermissionRight) to High(TPermissionRight) do
  begin
    HeaderLabel := TLabel.Create(Group);
    HeaderLabel.ShowsMnemonic := False;
    HeaderLabel.Text := RightCaptions[Right];
    HeaderLabel.SetBounds(ColumnLeft + Ord(Right) * ColumnWidth, Top, ColumnWidth, 18);
  end;
  for Who := Low(TPermissionClass) to High(TPermissionClass) do
  begin
    Top := Top + RowHeight;
    RowLabel := TLabel.Create(Group);
    RowLabel.ShowsMnemonic := False;
    RowLabel.Text := ClassCaptions[Who];
    RowLabel.SetBounds(10, Top, ColumnLeft - 10, 18);
    for Right := Low(TPermissionRight) to High(TPermissionRight) do
    begin
      Box := TCheckBox.Create(Group);
      Box.Checked := (FMode and PermissionBit(Who, Right)) <> 0;
      Box.Tag := LongInt(PermissionBit(Who, Right));
      Box.SetBounds(ColumnLeft + Ord(Right) * ColumnWidth, Top, 20, 18);
      Box.Enabled := MayChangeMode;
      Box.OnClick := @PermissionClicked;
      FBoxes[Who, Right] := Box;
    end;
  end;
  FTop := FTop + 112;
end;

procedure TPropertiesDialog.SetMode(NewMode: LongWord);
var
  Who: TPermissionClass;
  Right: TPermissionRight;
begin
  FMode := NewMode;
  for Who := Low(TPermissionClass) to High(TPermissionClass) do
    for Right := Low(TPermissionRight) to High(TPermissionRight) do
      FBoxes[Who, Right].Checked := (FMode and PermissionBit(Who, Right)) <> 0;
  FReadOnlyBox.Checked := (FMode and $92) = 0;
  FOctalLabel.Text := OctalModeText(FMode) + '  ' + PermissionText(FMode);
  Say('mode ' + FPath + ' ' + OctalModeText(FMode));
end;

procedure TPropertiesDialog.PermissionClicked(Sender: TControl);
var
  Box: TCheckBox;
  NewMode: LongWord;
  Error: LongInt;
begin
  Box := TCheckBox(Sender);
  if Box.Checked then
    NewMode := FMode or LongWord(Box.Tag)
  else
    NewMode := FMode and not LongWord(Box.Tag);
  Error := ChangeMode(PChar(FPath), NewMode);
  if Error <> ErrorNone then
  begin
    Box.Checked := not Box.Checked;
    Say('error chmod ' + FPath + ': ' + ReasonText(Error));
    ShowMessageBox('Properties', 'The permissions of ' + FItem.Name + ' could not be changed:'#10 + ReasonText(Error),
      MessageOk, SignError, Self);
    Exit;
  end;
  SetMode(NewMode);
end;

procedure TPropertiesDialog.ReadOnlyClicked(Sender: TControl);
var
  NewMode: LongWord;
  Error: LongInt;
begin
  if FReadOnlyBox.Checked then
    NewMode := FMode and not LongWord($92)
  else
    NewMode := FMode or $80;
  Error := ChangeMode(PChar(FPath), NewMode);
  if Error <> ErrorNone then
  begin
    FReadOnlyBox.Checked := not FReadOnlyBox.Checked;
    ShowMessageBox('Properties', FItem.Name + ' could not be changed:'#10 + ReasonText(Error), MessageOk, SignError,
      Self);
    Exit;
  end;
  SetMode(NewMode);
end;

procedure TPropertiesDialog.HiddenClicked(Sender: TControl);
var
  NewName: string;
  NewPath: string;
  Error: LongInt;
begin
  if FHiddenBox.Checked then
    NewName := '.' + FItem.Name
  else
  begin
    NewName := FItem.Name;
    while (NewName <> '') and (NewName[1] = '.') do
      Delete(NewName, 1, 1);
  end;
  NewPath := CombinePath(ParentFolderOf(FPath), NewName);
  if (NewName = '') or PathExists(PChar(NewPath)) then
    Error := ErrorExists
  else
    Error := RenamePath(PChar(FPath), PChar(NewPath));
  if Error <> ErrorNone then
  begin
    FHiddenBox.Checked := not FHiddenBox.Checked;
    ShowMessageBox('Properties', FItem.Name + ' could not be renamed to "' + NewName + '":'#10 + ReasonText(Error),
      MessageOk, SignError, Self);
    Exit;
  end;
  FPath := NewPath;
  FItem.Name := NewName;
  Title := NewName + ' Properties';
  Say('hidden ' + FPath);
end;

procedure TPropertiesDialog.ApplyOwnerClicked(Sender: TControl);
var
  UserId: LongWord;
  GroupId: LongWord;
  Error: LongInt;
begin
  if not FindUserId(Trim(FOwnerBox.Text), UserId) and not TryStrToDWord(Trim(FOwnerBox.Text), UserId) then
  begin
    ShowMessageBox('Properties', 'There is no user named "' + FOwnerBox.Text + '".', MessageOk, SignError, Self);
    Exit;
  end;
  if not FindGroupId(Trim(FGroupBox.Text), GroupId) and not TryStrToDWord(Trim(FGroupBox.Text), GroupId) then
  begin
    ShowMessageBox('Properties', 'There is no group named "' + FGroupBox.Text + '".', MessageOk, SignError, Self);
    Exit;
  end;
  Error := ChangeOwner(PChar(FPath), UserId, GroupId, False);
  if Error <> ErrorNone then
  begin
    ShowMessageBox('Properties', 'The owner of ' + FItem.Name + ' could not be changed:'#10 + ReasonText(Error),
      MessageOk, SignError, Self);
    Exit;
  end;
  FItem.OwnerId := UserId;
  FItem.GroupId := GroupId;
  Say('owner ' + FPath + ' ' + IntToStr(UserId) + ' ' + IntToStr(GroupId));
end;

procedure TPropertiesDialog.ShowCounts;
var
  Counts: TFolderCounts;
begin
  Counts := FCounter.Snapshot;
  FSizeLabel.Text := BytesText(Counts.Bytes);
  FContainsLabel.Text := CountText(Counts.Files, 'file') + ', ' + CountText(Counts.Folders, 'folder');
  if Counts.Finished then
  begin
    StopTimer(CountTimer);
    Say('properties-size ' + FPath + ' ' + IntToStr(Counts.Bytes) + ' ' + IntToStr(Counts.Files) + ' ' +
      IntToStr(Counts.Folders));
  end;
end;

procedure TPropertiesDialog.TimerFired(TimerId: LongWord);
begin
  if (TimerId = CountTimer) and (FCounter <> nil) then
    ShowCounts;
end;

procedure TPropertiesDialog.PageChanged(Sender: TControl);
begin
  Say('properties-page ' + IntToStr(FPages.PageIndex));
  TellPlaces;
end;

procedure TPropertiesDialog.TellPlaces;
const
  ClassNames: array[TPermissionClass] of string = ('owner', 'group', 'others');
  RightNames: array[TPermissionRight] of string = ('read', 'write', 'execute');
var
  Who: TPermissionClass;
  Right: TPermissionRight;
  Index: LongInt;
  Box: TRectangle;
const
  PageNames: array[0..2] of string = ('general', 'security', 'details');
begin
  for Index := 0 to 2 do
  begin
    Box := FPages.TabBounds(Index);
    TellPlace('properties-tab-' + PageNames[Index], FPages, Box.Left + RectangleWidth(Box) div 2,
      Box.Top + RectangleHeight(Box) div 2);
  end;
  if FPages.PageIndex = 1 then
    for Who := Low(TPermissionClass) to High(TPermissionClass) do
      for Right := Low(TPermissionRight) to High(TPermissionRight) do
        TellPlace('permission-' + ClassNames[Who] + '-' + RightNames[Right], FBoxes[Who, Right], 7, 9);
  TellControlPlace('properties-close', DefaultControl);
end;

procedure ShowItemProperties(const Path: string; Owner: TWindow);
var
  Item: TFolderItem;
  Error: LongInt;
  Dialog: TPropertiesDialog;
begin
  Error := DescribeItem(Path, Item);
  if Error <> ErrorNone then
  begin
    ShowMessageBox('Properties', 'Cannot look at ' + LastPartOf(Path) + ':'#10 + ReasonText(Error), MessageOk,
      SignError, Owner);
    Exit;
  end;
  Dialog := TPropertiesDialog.CreateFor(Path, Item, Owner);
  try
    Say('properties ' + Path + ' size ' + IntToStr(Item.SizeInBytes) + ' mode ' + OctalModeText(Item.Mode and $FFF));
    Dialog.TellPlaces;
    Dialog.ShowModal;
  finally
    Dialog.Free;
  end;
end;

end.
