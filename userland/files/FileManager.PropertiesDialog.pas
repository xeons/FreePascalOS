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
  The properties of a file, folder or link: its icon and name, type,
  location, size (a folder's added up in the background, the count
  running as it goes: FileManager.FolderSizeCounter), the link's target,
  when it was modified, accessed and changed, its owner and group, and
  its permissions as check boxes, read, write and execute for the
  owner, the group and everyone else.

  The owner (or root) can change the permissions: each check box
  changes the mode at once (chmod), as the box is clicked, and the
  dialog prints "mode PATH OCTAL"; others see the boxes greyed. A
  change that fails says why and the box goes back.

  It prints "properties PATH size BYTES mode OCTAL" when it opens and
  "properties-size PATH BYTES FILES FOLDERS" when a folder's size has
  been added up, and where its check boxes are.
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
  Controls.Base,
  Controls.Labels,
  Controls.Panels,
  Controls.Toggles,
  Controls.Buttons,
  Controls.Icons,
  Controls.Dialogs,
  Controls.MessageBoxes,
  Controls.FileNames,
  Controls.FolderListing,
  Util.Accounts,
  FileManager.Items,
  FileManager.FileTypes,
  FileManager.Permissions,
  FileManager.TimeTexts,
  FileManager.FolderReading,
  FileManager.FolderSizeCounter,
  FileManager.FolderView,
  FileManager.ErrorTexts,
  FileManager.TestPlaces,
  FileManager.Output;

const
  DialogWidth = 400;
  Margin = 12;
  RowHeight = 20;
  CaptionWidth = 90;
  CountTimer = 1;
  CountMilliseconds = 200;

type
  { The item's icon, drawn at the top. }
  TItemIconControl = class(TControl)
  private
    FIcon: TStockIcon;
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
    FSizeLabel: TLabel;
    FCounter: TFolderSizeCounter;
    FBoxes: array[TPermissionClass, TPermissionRight] of TCheckBox;
    procedure AddRow(const Caption, Value: string; out ValueLabel: TLabel);
    procedure AddPlainRow(const Caption, Value: string);
    procedure AddPermissions;
    procedure PermissionClicked(Sender: TControl);
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
  DrawStockIcon(Canvas, FIcon, Box);
  DrawIconOverlay(Canvas, FOverlay, Box);
end;

{ "name (number)", or the number alone for an account with no name. }
function NameOrNumber(const Name: string; Number: LongWord): string;
begin
  if Name = '' then
    Result := IntToStr(Number)
  else
    Result := Name + ' (' + IntToStr(Number) + ')';
end;

function OwnerText(UserId: LongWord): string;
var
  Name: string;
begin
  if not FindUserName(UserId, Name) then
    Name := '';
  Result := NameOrNumber(Name, UserId);
end;

function GroupText(GroupId: LongWord): string;
var
  Name: string;
begin
  if not FindGroupName(GroupId, Name) then
    Name := '';
  Result := NameOrNumber(Name, GroupId);
end;

{ "1 file", "3 files". }
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

{ The height the dialog needs for Item: the rows it will have. }
function RowsFor(const Item: TFolderItem): LongInt;
begin
  { Type, location, size, modified, accessed, changed, owner, group. }
  Result := 8;
  if Item.IsLink then
    Inc(Result);
end;

constructor TPropertiesDialog.CreateFor(const APath: string; const AItem: TFolderItem; AOwner: TWindow);
var
  Height: LongInt;
  Icon: TItemIconControl;
  NameLabel: TLabel;
begin
  Height := Margin + 40 + RowsFor(AItem) * RowHeight + 8 + 100 + Margin + 23 + Margin;
  inherited CreateDialog(AItem.Name + ' Properties', DialogWidth, Height, AOwner);
  FPath := APath;
  FItem := AItem;
  FMode := AItem.Mode and $FFF;
  Icon := TItemIconControl.Create(Root);
  Icon.FIcon := IconOfItem(AItem);
  if AItem.IsLink then
    Icon.FOverlay := OverlayLink;
  Icon.SetBounds(Margin, Margin, 32, 32);
  NameLabel := TLabel.Create(Root);
  NameLabel.ShowsMnemonic := False;
  NameLabel.Text := AItem.Name;
  NameLabel.SetBounds(Margin + 44, Margin + 7, DialogWidth - 2 * Margin - 44, 18);
  FTop := Margin + 44;
  AddPlainRow('Type:', TypeTextOf(AItem));
  AddPlainRow('Location:', ParentFolderOf(APath));
  if AItem.Kind = ItemFolder then
  begin
    AddRow('Size:', 'Counting...', FSizeLabel);
    FCounter := TFolderSizeCounter.Create(APath);
    FCounter.Start;
    StartTimer(CountTimer, CountMilliseconds);
  end
  else
    AddRow('Size:', BytesText(AItem.SizeInBytes), FSizeLabel);
  if AItem.IsLink then
    AddPlainRow('Link to:', AItem.LinkTarget);
  AddPlainRow('Modified:', TimeText(AItem.ModificationTime));
  AddPlainRow('Accessed:', TimeText(AItem.AccessTime));
  AddPlainRow('Changed:', TimeText(AItem.ChangeTime));
  AddPlainRow('Owner:', OwnerText(AItem.OwnerId));
  AddPlainRow('Group:', GroupText(AItem.GroupId));
  AddPermissions;
  AddButton('Close', ResultOk, DialogWidth - Margin - 75, Height - Margin - 23, 75, 23, True, True);
  FocusControl(DefaultControl);
end;

destructor TPropertiesDialog.Destroy;
begin
  { Waits for the count's thread, which reads this dialog's path. }
  FCounter.Free;
  inherited Destroy;
end;

procedure TPropertiesDialog.AddRow(const Caption, Value: string; out ValueLabel: TLabel);
var
  CaptionLabel: TLabel;
begin
  CaptionLabel := TLabel.Create(Root);
  CaptionLabel.ShowsMnemonic := False;
  CaptionLabel.Text := Caption;
  CaptionLabel.SetBounds(Margin, FTop, CaptionWidth, RowHeight);
  ValueLabel := TLabel.Create(Root);
  ValueLabel.ShowsMnemonic := False;
  ValueLabel.Text := Value;
  ValueLabel.SetBounds(Margin + CaptionWidth, FTop, DialogWidth - 2 * Margin - CaptionWidth, RowHeight);
  FTop := FTop + RowHeight;
end;

procedure TPropertiesDialog.AddPlainRow(const Caption, Value: string);
var
  ValueLabel: TLabel;
begin
  AddRow(Caption, Value, ValueLabel);
end;

function TPropertiesDialog.MayChangeMode: Boolean;
begin
  Result := ((CurrentUserId = 0) or (CurrentUserId = FItem.OwnerId)) and not FItem.IsBrokenLink;
end;

procedure TPropertiesDialog.AddPermissions;
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
  Group := TGroupBox.Create(Root);
  Group.Text := 'Permissions';
  Group.SetBounds(Margin, FTop + 8, DialogWidth - 2 * Margin, 100);
  Top := FTop + 8 + 18;
  for Right := Low(TPermissionRight) to High(TPermissionRight) do
  begin
    HeaderLabel := TLabel.Create(Root);
    HeaderLabel.ShowsMnemonic := False;
    HeaderLabel.Text := RightCaptions[Right];
    HeaderLabel.SetBounds(Margin + ColumnLeft + Ord(Right) * ColumnWidth, Top, ColumnWidth, 18);
  end;
  for Who := Low(TPermissionClass) to High(TPermissionClass) do
  begin
    Top := Top + RowHeight;
    RowLabel := TLabel.Create(Root);
    RowLabel.ShowsMnemonic := False;
    RowLabel.Text := ClassCaptions[Who];
    RowLabel.SetBounds(Margin + 10, Top, ColumnLeft - 10, 18);
    for Right := Low(TPermissionRight) to High(TPermissionRight) do
    begin
      Box := TCheckBox.Create(Root);
      Box.Checked := (FMode and PermissionBit(Who, Right)) <> 0;
      Box.Tag := LongInt(PermissionBit(Who, Right));
      Box.SetBounds(Margin + ColumnLeft + Ord(Right) * ColumnWidth, Top, 20, 18);
      Box.Enabled := MayChangeMode;
      Box.OnClick := @PermissionClicked;
      FBoxes[Who, Right] := Box;
    end;
  end;
  FTop := FTop + 8 + 100;
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
  FMode := NewMode;
  Say('mode ' + FPath + ' ' + OctalModeText(FMode));
end;

procedure TPropertiesDialog.ShowCounts;
var
  Counts: TFolderCounts;
begin
  Counts := FCounter.Snapshot;
  FSizeLabel.Text := BytesText(Counts.Bytes) + ', ' + CountText(Counts.Files, 'file') + ', ' +
    CountText(Counts.Folders, 'folder');
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

procedure TPropertiesDialog.TellPlaces;
const
  ClassNames: array[TPermissionClass] of string = ('owner', 'group', 'others');
  RightNames: array[TPermissionRight] of string = ('read', 'write', 'execute');
var
  Who: TPermissionClass;
  Right: TPermissionRight;
begin
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
