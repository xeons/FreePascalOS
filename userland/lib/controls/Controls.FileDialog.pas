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
  The open and save dialogs: a user finds a folder and picks or names a
  file in it.

  At the top is the folder shown (typing another one there and pressing
  Enter goes to it); below it a list view of the folder: ".." to go up,
  then the folders, then the files that fit the filter, with their size
  and kind. Choosing a file puts its name in the file name box; a double
  click or Enter on a row opens a folder or takes the file. The filter
  box below lists the given filter and "*" for every file. OK takes
  what the file name box says: a folder there is opened, a pattern with
  "*" or "?" becomes the filter, anything else is the file (relative to
  the folder shown, or absolute).

  The open dialog only takes a file that exists; the save dialog asks
  (in a message box) before a file is replaced, and wants the folder to
  exist. Either ends with the chosen file's absolute path.

  ChooseFileToOpen and ChooseFileToSave do it all in one call; the
  classes are there for a program that wants more (OnFolderShown, say,
  to know when the list changed).
}
unit Controls.FileDialog;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Controls.Labels,
  Controls.EditBox,
  Controls.ComboBox,
  Controls.ListView,
  Controls.CommonDialogs,
  Controls.FolderListing;

type
  TFileDialog = class(TCommonDialog)
  private
    FFolder: string;
    FPath: string;
    FEntries: TFolderEntries;
    FHasParentRow: Boolean;
    FFolderEdit: TEditBox;
    FFileList: TListView;
    FNameEdit: TEditBox;
    FFilterBox: TComboBox;
    FOnFolderShown: TCommonDialogEvent;
    procedure BuildControls;
    function CurrentFilter: string;
    procedure FolderEditKeyDown(Sender: TControl; Code, Character, Modifiers: LongWord; var Handled: Boolean);
    procedure FileListChanged(Sender: TControl);
    procedure FileListActivated(Sender: TControl);
    procedure FilterChanged(Sender: TControl);
    { Filter becomes the filter box's choice (added to it if new). }
    procedure UseFilter(const Filter: string);
    { The folder entry shown in row Row, or -1 for "..". }
    function EntryOfRow(Row: LongInt): LongInt;
  protected
    procedure Showing; override;
    function Accept: Boolean; override;
    { APath (absolute, cleaned) is the file the user chose: True to end the
      dialog with it. }
    function AcceptFile(const APath: string): Boolean; virtual; abstract;
  public
    { Filter: patterns like "*.txt;*.md" ('' for every file). }
    constructor CreateFileDialog(const ATitle, StartFolder, Filter: string);
    { Shows AFolder (False, and a message, if it cannot be read). }
    function ShowFolder(const AFolder: string): Boolean;
    { The row showing Name, or -1. }
    function RowOfName(const Name: string): LongInt;
    property Folder: string read FFolder;
    { The chosen file, once the dialog ended with OK. }
    property Path: string read FPath;
    property FolderEdit: TEditBox read FFolderEdit;
    property FileList: TListView read FFileList;
    property NameEdit: TEditBox read FNameEdit;
    property FilterBox: TComboBox read FFilterBox;
    { The list shows a new folder (the first one too, before the dialog
      appears). }
    property OnFolderShown: TCommonDialogEvent read FOnFolderShown write FOnFolderShown;
  end;

  TOpenFileDialog = class(TFileDialog)
  protected
    function AcceptFile(const APath: string): Boolean; override;
  end;

  TSaveFileDialog = class(TFileDialog)
  protected
    function AcceptFile(const APath: string): Boolean; override;
  end;

{ Shows an open dialog at StartFolder ('' for the root) listing the
  files that fit Filter; True and the file's absolute path if one was
  chosen. }
function ChooseFileToOpen(const Title, StartFolder, Filter: string; out Path: string): Boolean;
{ The same for saving: the file may be new; replacing one is asked
  first. }
function ChooseFileToSave(const Title, StartFolder, Filter: string; out Path: string): Boolean;

implementation

uses
  SysUtils,
  Sys.Files,
  Controls.Keys,
  Controls.Dialogs,
  Controls.MessageBoxes,
  Controls.FileNames;

const
  DialogWidth = 440;
  DialogHeight = 330;
  LabelWidth = 64;
  FieldHeight = 22;
  ListTop = 38;
  ListHeight = 200;
  NameTop = 248;
  FilterTop = 276;
  FilterWidth = 200;
  NameColumnWidth = 210;
  SizeColumnWidth = 90;
  KindColumnWidth = 90;
  ParentRowName = '..';
  EveryFileFilter = '*';

constructor TFileDialog.CreateFileDialog(const ATitle, StartFolder, Filter: string);
begin
  inherited CreateDialog(ATitle, DialogWidth, DialogHeight);
  BuildControls;
  if (Filter <> '') and (Filter <> EveryFileFilter) then
    FFilterBox.Items.Add(Filter);
  FFilterBox.Items.Add(EveryFileFilter);
  FFilterBox.ItemIndex := 0;
  FFilterBox.OnChange := @FilterChanged;
  if (StartFolder = '') or not ShowFolder(CleanPath(StartFolder)) then
    ShowFolder('/');
end;

procedure TFileDialog.BuildControls;
var
  Caption: TLabel;
  FieldLeft: LongInt;
  FieldWidth: LongInt;
begin
  FieldLeft := DialogMargin + LabelWidth;
  FieldWidth := DialogWidth - DialogMargin - FieldLeft;
  Caption := TLabel.Create(Root);
  Caption.Text := 'Folder:';
  Caption.SetBounds(DialogMargin, DialogMargin, LabelWidth, FieldHeight);
  FFolderEdit := TEditBox.Create(Root);
  FFolderEdit.SetBounds(FieldLeft, DialogMargin, FieldWidth, FieldHeight);
  FFolderEdit.OnKeyDown := @FolderEditKeyDown;
  FFileList := TListView.Create(Root);
  FFileList.SetBounds(DialogMargin, ListTop, DialogWidth - 2 * DialogMargin, ListHeight);
  FFileList.AddColumn('Name', NameColumnWidth);
  FFileList.AddColumn('Size', SizeColumnWidth);
  FFileList.AddColumn('Kind', KindColumnWidth);
  FFileList.OnChange := @FileListChanged;
  FFileList.OnActivate := @FileListActivated;
  Caption := TLabel.Create(Root);
  Caption.Text := 'File name:';
  Caption.SetBounds(DialogMargin, NameTop, LabelWidth, FieldHeight);
  FNameEdit := TEditBox.Create(Root);
  FNameEdit.SetBounds(FieldLeft, NameTop, FieldWidth, FieldHeight);
  Caption := TLabel.Create(Root);
  Caption.Text := 'Show:';
  Caption.SetBounds(DialogMargin, FilterTop, LabelWidth, FieldHeight);
  FFilterBox := TComboBox.Create(Root);
  FFilterBox.SetBounds(FieldLeft, FilterTop, FilterWidth, FieldHeight);
  AddOkAndCancel(DialogWidth, DialogHeight);
end;

function TFileDialog.CurrentFilter: string;
begin
  Result := FFilterBox.Text;
  if Result = EveryFileFilter then
    Result := '';
end;

function TFileDialog.ShowFolder(const AFolder: string): Boolean;
var
  Entries: TFolderEntries;
  Index: LongInt;
  Filter: string;
  Shown: LongInt;
begin
  if not ReadFolder(AFolder, Entries) then
  begin
    { Only worth saying once the dialog is up: at the start the root is
      shown instead. }
    if Visible then
      ShowMessageBox(Title, 'The folder ' + AFolder + ' cannot be opened.', MessageOk, SignWarning);
    Exit(False);
  end;
  FFolder := AFolder;
  FFolderEdit.Text := AFolder;
  Filter := CurrentFilter;
  { Folders are always shown, so a user can go on looking; files only
    if they fit the filter. }
  SetLength(FEntries, Length(Entries));
  Shown := 0;
  for Index := 0 to High(Entries) do
    if Entries[Index].IsFolder or NameMatchesFilter(Entries[Index].Name, Filter) then
    begin
      FEntries[Shown] := Entries[Index];
      Inc(Shown);
    end;
  SetLength(FEntries, Shown);
  FFileList.Clear;
  FHasParentRow := AFolder <> '/';
  if FHasParentRow then
    FFileList.AddRow([ParentRowName, '', 'Folder']);
  for Index := 0 to High(FEntries) do
    if FEntries[Index].IsFolder then
      FFileList.AddRow([FEntries[Index].Name, '', FEntries[Index].KindText])
    else
      FFileList.AddRow([FEntries[Index].Name, SizeText(FEntries[Index].SizeInBytes), FEntries[Index].KindText]);
  if Assigned(FOnFolderShown) then
    FOnFolderShown(Self);
  Result := True;
end;

function TFileDialog.EntryOfRow(Row: LongInt): LongInt;
begin
  if FHasParentRow then
    Result := Row - 1
  else
    Result := Row;
end;

function TFileDialog.RowOfName(const Name: string): LongInt;
var
  Row: LongInt;
begin
  for Row := 0 to FFileList.RowCount - 1 do
    if FFileList.Cells[Row, 0] = Name then
      Exit(Row);
  Result := -1;
end;

procedure TFileDialog.Showing;
begin
  FocusControl(FNameEdit);
  inherited Showing;
end;

procedure TFileDialog.FolderEditKeyDown(Sender: TControl; Code, Character, Modifiers: LongWord;
  var Handled: Boolean);
begin
  if not IsEnterKey(Code) then
    Exit;
  Handled := True;
  ShowFolder(CombinePath(FFolder, Trim(FFolderEdit.Text)));
end;

procedure TFileDialog.FileListChanged(Sender: TControl);
var
  Entry: LongInt;
begin
  { A file chosen in the list is the one OK will take; choosing a folder
    leaves a typed name alone. }
  Entry := EntryOfRow(FFileList.ItemIndex);
  if (FFileList.ItemIndex < 0) or (Entry < 0) then
    Exit;
  if not FEntries[Entry].IsFolder then
    FNameEdit.Text := FEntries[Entry].Name;
end;

procedure TFileDialog.FileListActivated(Sender: TControl);
var
  Entry: LongInt;
begin
  if FFileList.ItemIndex < 0 then
    Exit;
  Entry := EntryOfRow(FFileList.ItemIndex);
  if Entry < 0 then
    ShowFolder(ParentFolderOf(FFolder))
  else if FEntries[Entry].IsFolder then
    ShowFolder(CombinePath(FFolder, FEntries[Entry].Name))
  else
  begin
    FNameEdit.Text := FEntries[Entry].Name;
    if Accept then
      EndModal(ResultOk);
  end;
end;

procedure TFileDialog.UseFilter(const Filter: string);
var
  Index: LongInt;
begin
  Index := FFilterBox.Items.IndexOf(Filter);
  if Index < 0 then
    Index := FFilterBox.Items.Add(Filter);
  { Choosing another entry lists the folder again (FilterChanged). }
  if Index = FFilterBox.ItemIndex then
    ShowFolder(FFolder)
  else
    FFilterBox.ItemIndex := Index;
end;

procedure TFileDialog.FilterChanged(Sender: TControl);
begin
  ShowFolder(FFolder);
end;

function TFileDialog.Accept: Boolean;
var
  Typed: string;
  Chosen: string;
  Entry: LongInt;
begin
  Result := False;
  Typed := Trim(FNameEdit.Text);
  if Typed = '' then
  begin
    { Nothing typed: OK on a folder in the list opens it. }
    if FFileList.ItemIndex >= 0 then
    begin
      Entry := EntryOfRow(FFileList.ItemIndex);
      if Entry < 0 then
        ShowFolder(ParentFolderOf(FFolder))
      else if FEntries[Entry].IsFolder then
        ShowFolder(CombinePath(FFolder, FEntries[Entry].Name));
    end;
    Exit;
  end;
  if HasWildcards(Typed) then
  begin
    UseFilter(Typed);
    FNameEdit.Text := '';
    Exit;
  end;
  Chosen := CombinePath(FFolder, Typed);
  if IsDirectory(PChar(Chosen)) then
  begin
    if ShowFolder(Chosen) then
      FNameEdit.Text := '';
    Exit;
  end;
  if AcceptFile(Chosen) then
  begin
    FPath := Chosen;
    Result := True;
  end;
end;

function TOpenFileDialog.AcceptFile(const APath: string): Boolean;
begin
  Result := PathExists(PChar(APath));
  if not Result then
    ShowMessageBox(Title, 'The file ' + APath + ' does not exist.', MessageOk, SignWarning);
end;

function TSaveFileDialog.AcceptFile(const APath: string): Boolean;
begin
  if not IsDirectory(PChar(ParentFolderOf(APath))) then
  begin
    ShowMessageBox(Title, 'The folder ' + ParentFolderOf(APath) + ' does not exist.', MessageOk, SignWarning);
    Exit(False);
  end;
  if not PathExists(PChar(APath)) then
    Exit(True);
  Result := ShowMessageBox(Title, LastPartOf(APath) + ' already exists.'#10'Do you want to replace it?', MessageYesNo,
    SignQuestion) = ResultYes;
end;

function ChooseFileToOpen(const Title, StartFolder, Filter: string; out Path: string): Boolean;
var
  Dialog: TOpenFileDialog;
begin
  Path := '';
  Dialog := TOpenFileDialog.CreateFileDialog(Title, StartFolder, Filter);
  try
    Result := Dialog.Execute;
    if Result then
      Path := Dialog.Path;
  finally
    Dialog.Free;
  end;
end;

function ChooseFileToSave(const Title, StartFolder, Filter: string; out Path: string): Boolean;
var
  Dialog: TSaveFileDialog;
begin
  Path := '';
  Dialog := TSaveFileDialog.CreateFileDialog(Title, StartFolder, Filter);
  try
    Result := Dialog.Execute;
    if Result then
      Path := Dialog.Path;
  finally
    Dialog.Free;
  end;
end;

end.
