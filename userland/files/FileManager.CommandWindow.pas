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
  What the file manager does to files, whichever menu, key, button or
  drag asked for it:

  * Open: a folder is shown, anything else opened as
    FileManager.Associations decides (a program run, text in Notepad);
    "Open with Notepad" opens any file in Notepad.
  * New folder: "New folder" (or "New folder (2)", ...), made at once
    and put up for renaming.
  * Rename: in place, over the item's name (F2); a name that cannot be
    is refused with the reason ("renamed OLD NEW" when it worked).
  * Delete: asked first, saying it is permanent (there is no recycle
    bin), then done like a copy, in the background.
  * Cut, Copy and Paste: the selected items' paths go on the clipboard
    as a file list (Controls.FileLists); Paste copies them into the
    folder shown, or moves them if they were cut (the clipboard is then
    emptied, as the files are no longer where it says).
  * Drag and drop: files dropped on a folder are moved or copied
    (FileManager.DropRules decides which; Ctrl and Shift choose).
  * Properties: of the selected item, or of the folder shown.

  Copies, moves and deletes run one after another in the background
  (FileManager.OperationRunner); closing the window (or being asked to
  end) while one runs asks whether to stop it: Yes stops it and the
  window closes as soon as it has stopped cleanly; No goes on. The
  window's place and size, and the places' width, are remembered when
  it closes.
}
unit FileManager.CommandWindow;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Controls.Base,
  Controls.DragData,
  Controls.ListView,
  FileManager.BrowserWindow,
  FileManager.OperationTypes,
  FileManager.OperationRunner;

type
  TCommandWindow = class(TBrowserWindow)
  private
    FRunner: TOperationRunner;
    FCloseWhenIdle: Boolean;
    procedure ItemActivated(Sender: TControl);
    procedure ItemRenamed(Sender: TListView; Index: LongInt; const NewCaption: string; var Accept: Boolean);
    procedure FilesDropped(Sender: TControl; Paths: TStrings; const TargetFolder: string; Effect: TDropEffect);
    procedure OperationFinished(Sender: TObject; const Request: TOperationRequest; const Outcome: TOperationOutcome);
    procedure RunnerIdle(Sender: TObject);
    function NameTakenHere(const Name: string): Boolean;
    procedure RememberPlace;
  protected
    procedure CloseRequested; override;
    procedure StartOperation(Kind: TOperationKind; Paths: TStrings; const TargetFolder: string);
  public
    constructor Create;
    destructor Destroy; override;
    procedure OpenItem(Index: LongInt);
    procedure OpenFocused;
    procedure OpenFocusedWithNotepad;
    procedure CreateNewFolder;
    procedure RenameFocused;
    procedure DeleteSelected;
    procedure CopySelected(Cut: Boolean);
    procedure PasteFiles;
    procedure ShowProperties;
    function HasSelection: Boolean;
    function CanPaste: Boolean;
  end;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Files,
  Windowing.Windows,
  Controls.Window,
  Controls.Clipboard,
  Controls.Dialogs,
  Controls.MessageBoxes,
  Controls.FileNames,
  Controls.FileLists,
  FileManager.Items,
  FileManager.Paths,
  FileManager.ConflictNames,
  FileManager.FolderView,
  FileManager.FolderReading,
  FileManager.Associations,
  FileManager.Launching,
  FileManager.Settings,
  FileManager.ErrorTexts,
  FileManager.PropertiesDialog,
  FileManager.Output;

constructor TCommandWindow.Create;
begin
  inherited Create;
  FRunner := TOperationRunner.Create(Self, FSettings.ProgressDelay);
  FRunner.OnFinished := @OperationFinished;
  FRunner.OnIdle := @RunnerIdle;
  FView.OnActivate := @ItemActivated;
  FView.OnEdited := @ItemRenamed;
  FView.OnDropFiles := @FilesDropped;
  FPlaces.OnDropFiles := @FilesDropped;
end;

destructor TCommandWindow.Destroy;
begin
  FRunner.Free;
  inherited Destroy;
end;

function TCommandWindow.HasSelection: Boolean;
begin
  Result := FView.SelectedCount > 0;
end;

{ --- Opening ------------------------------------------------------------------------------ }

procedure TCommandWindow.OpenItem(Index: LongInt);
var
  Entry: TFolderEntry;
  Path: string;
begin
  Entry := FView.EntryAt(Index);
  if Entry = nil then
    Exit;
  Path := FView.PathOf(Index);
  case OpenActionFor(Path, Entry.Item) of
    OpenActionFolder: Navigate(Path);
    OpenActionProgram: RunProgramFile(Path, Self);
    OpenActionNotepad: OpenWithNotepad(Path, Self);
  else
    begin
      Say('error no program for ' + Path);
      ShowMessageBox(ProgramTitle, 'There is no program to open ' + Entry.Item.Name + '.'#10 +
        'Use "Open with Notepad" to look at it as text.', MessageOk, SignInformation, Self);
    end;
  end;
end;

procedure TCommandWindow.ItemActivated(Sender: TControl);
begin
  OpenFocused;
end;

procedure TCommandWindow.OpenFocused;
begin
  OpenItem(FView.ItemIndex);
end;

procedure TCommandWindow.OpenFocusedWithNotepad;
var
  Entry: TFolderEntry;
begin
  Entry := FView.EntryAt(FView.ItemIndex);
  if (Entry <> nil) and not IsFolderItem(Entry.Item) then
    OpenWithNotepad(FView.PathOf(FView.ItemIndex), Self);
end;

{ --- New folder and renaming ---------------------------------------------------------------- }

function TCommandWindow.NameTakenHere(const Name: string): Boolean;
begin
  Result := PathExists(PChar(CombinePath(FView.Folder, Name)));
end;

procedure TCommandWindow.CreateNewFolder;
var
  Name: string;
  Error: LongInt;
  Index: LongInt;
begin
  Name := FirstFreeName('New folder', True, @NameTakenHere);
  Error := CreateDirectory(PChar(CombinePath(FView.Folder, Name)));
  if Error <> ErrorNone then
  begin
    Say('error new folder: ' + ReasonText(Error));
    ShowMessageBox(ProgramTitle, 'A new folder cannot be made here:'#10 + ReasonText(Error), MessageOk, SignError,
      Self);
    Exit;
  end;
  Say('new-folder ' + Name);
  { Shown at once (the watch would read it again a moment later anyway)
    and put up for its real name. }
  FView.Refresh;
  Index := FView.IndexOfName(Name);
  if Index >= 0 then
  begin
    FView.ItemIndex := Index;
    FView.EditItem(Index, False);
  end;
end;

procedure TCommandWindow.RenameFocused;
begin
  if FView.ItemIndex >= 0 then
    FView.EditItem(FView.ItemIndex);
end;

procedure TCommandWindow.ItemRenamed(Sender: TListView; Index: LongInt; const NewCaption: string;
  var Accept: Boolean);
var
  OldName: string;
  Problem: string;
  Error: LongInt;
begin
  OldName := FView.Items[Index].Caption;
  Problem := NameProblem(NewCaption);
  if Problem = '' then
  begin
    if NameTakenHere(NewCaption) and (LowerCase(NewCaption) <> LowerCase(OldName)) then
      Problem := 'There is already something named "' + NewCaption + '" here.'
    else
    begin
      Error := RenamePath(PChar(CombinePath(FView.Folder, OldName)), PChar(CombinePath(FView.Folder, NewCaption)));
      if Error <> ErrorNone then
        Problem := ReasonText(Error);
    end;
  end;
  if Problem <> '' then
  begin
    Accept := False;
    Say('error rename ' + OldName + ': ' + Problem);
    ShowMessageBox(ProgramTitle, OldName + ' cannot be renamed to "' + NewCaption + '":'#10 + Problem, MessageOk,
      SignError, Self);
    Exit;
  end;
  Say('renamed ' + OldName + ' ' + NewCaption);
  FView.Refresh;
  FView.ItemIndex := FView.IndexOfName(NewCaption);
  { The list view must not rename the row: it is read again already. }
  Accept := False;
end;

{ --- Operations ------------------------------------------------------------------------------ }

procedure TCommandWindow.StartOperation(Kind: TOperationKind; Paths: TStrings; const TargetFolder: string);
var
  Request: TOperationRequest;
  Index: LongInt;
begin
  if Paths.Count = 0 then
    Exit;
  if Kind <> OperationDelete then
    for Index := 0 to Paths.Count - 1 do
      if IsSameOrInside(TargetFolder, Paths[Index]) and (ParentFolderOf(Paths[Index]) <> TargetFolder) then
      begin
        Say('error ' + LastPartOf(Paths[Index]) + ' cannot go into itself');
        ShowMessageBox(ProgramTitle, 'The folder ' + LastPartOf(Paths[Index]) + ' cannot be put into itself.',
          MessageOk, SignError, Self);
        Exit;
      end;
  Request.Kind := Kind;
  Request.TargetFolder := TargetFolder;
  SetLength(Request.Sources, Paths.Count);
  for Index := 0 to Paths.Count - 1 do
    Request.Sources[Index] := Paths[Index];
  FRunner.Start(Request);
end;

procedure TCommandWindow.DeleteSelected;
var
  Paths: TStringList;
  Question: string;
begin
  Paths := TStringList.Create;
  try
    FView.GetSelectedPaths(Paths);
    if Paths.Count = 0 then
      Exit;
    if Paths.Count = 1 then
      Question := 'Delete "' + LastPartOf(Paths[0]) + '" permanently?'
    else
      Question := 'Delete these ' + IntToStr(Paths.Count) + ' items permanently?';
    Say('asking delete ' + IntToStr(Paths.Count));
    if ShowMessageBox('Delete', Question + #10 + 'There is no recycle bin: they cannot be brought back.',
      MessageYesNo, SignWarning, Self) <> ResultYes then
    begin
      Say('delete cancelled');
      Exit;
    end;
    StartOperation(OperationDelete, Paths, '');
  finally
    Paths.Free;
  end;
end;

procedure TCommandWindow.CopySelected(Cut: Boolean);
var
  Paths: TStringList;
begin
  Paths := TStringList.Create;
  try
    FView.GetSelectedPaths(Paths);
    if Paths.Count = 0 then
      Exit;
    if Cut then
    begin
      SetClipboardFileList(FileListCut, Paths);
      Say('clipboard cut ' + IntToStr(Paths.Count));
    end
    else
    begin
      SetClipboardFileList(FileListCopy, Paths);
      Say('clipboard copy ' + IntToStr(Paths.Count));
    end;
  finally
    Paths.Free;
  end;
end;

function TCommandWindow.CanPaste: Boolean;
begin
  Result := ClipboardHoldsFileList;
end;

procedure TCommandWindow.PasteFiles;
var
  Paths: TStringList;
  Action: TFileListAction;
begin
  Paths := TStringList.Create;
  try
    if not ClipboardFileList(Action, Paths) then
      Exit;
    if Action = FileListCut then
    begin
      { Once moved, the paths on the clipboard lead nowhere. }
      SetClipboardText('');
      StartOperation(OperationMove, Paths, FView.Folder);
    end
    else
      StartOperation(OperationCopy, Paths, FView.Folder);
  finally
    Paths.Free;
  end;
end;

procedure TCommandWindow.FilesDropped(Sender: TControl; Paths: TStrings; const TargetFolder: string;
  Effect: TDropEffect);
begin
  if Effect = DropMove then
  begin
    Say('dropped move ' + IntToStr(Paths.Count) + ' ' + TargetFolder);
    StartOperation(OperationMove, Paths, TargetFolder);
  end
  else if Effect = DropCopy then
  begin
    Say('dropped copy ' + IntToStr(Paths.Count) + ' ' + TargetFolder);
    StartOperation(OperationCopy, Paths, TargetFolder);
  end;
end;

procedure TCommandWindow.OperationFinished(Sender: TObject; const Request: TOperationRequest;
  const Outcome: TOperationOutcome);
begin
  { The watch reads the folder again as it changes; this catches the
    last of it at once. }
  if not FCloseWhenIdle then
    RefreshFolder;
end;

procedure TCommandWindow.RunnerIdle(Sender: TObject);
begin
  if FCloseWhenIdle then
  begin
    RememberPlace;
    Say('exit');
    QuitMessageLoop(0);
  end;
end;

{ --- Properties --------------------------------------------------------------------------------- }

procedure TCommandWindow.ShowProperties;
begin
  if FView.ItemIndex >= 0 then
    ShowItemProperties(FView.PathOf(FView.ItemIndex), Self)
  else
    ShowItemProperties(FView.Folder, Self);
end;

{ --- The window ---------------------------------------------------------------------------------- }

procedure TCommandWindow.RememberPlace;
begin
  RememberWindow(ScreenLeft, ScreenTop, ClientWidth, ClientHeight, FSplitter.PaneWidth);
end;

procedure TCommandWindow.CloseRequested;
begin
  if FCloseWhenIdle then
    Exit;
  if FRunner.Busy then
  begin
    Say('asking stop');
    if ShowMessageBox(ProgramTitle, 'Files are still being copied, moved or deleted.'#10 +
      'Stop that and close?', MessageYesNo, SignWarning, Self) <> ResultYes then
    begin
      Say('answer no');
      Exit;
    end;
    Say('answer yes');
    { Closes once the operation has stopped cleanly (no half-written
      file left behind). }
    FCloseWhenIdle := True;
    FRunner.CancelAll;
    if FRunner.Busy then
      Exit;
  end;
  RememberPlace;
  Say('exit');
  QuitMessageLoop(0);
end;

end.
