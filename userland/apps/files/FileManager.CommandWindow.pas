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
  What the file manager does to files in bulk, whichever menu, key,
  button or drag asked for it:

  * Delete: to the recycle bin (Delete) or for good (Shift+Delete),
    asked first either way; in the recycle bin, for good. Restore puts
    items from the recycle bin back; Empty recycle bin removes them all.
  * Cut, Copy and Paste: file lists on the clipboard (Controls.
    FileLists); cut items are drawn dimmed until pasted (then the
    clipboard is emptied: the paths lead nowhere any more). Pasting out
    of an archive extracts.
  * Drag and drop: moved or copied as FileManager.DropRules says (Ctrl
    and Shift choose); folders dropped on Home are pinned.
  * Undo and redo (Ctrl+Z, Ctrl+Y) of renames, new items, copies, moves
    and moves to the recycle bin (FileManager.UndoHistory), carried out
    with the same operations.

  Copies, moves, deletes, compressing and extracting run one after
  another in the background (FileManager.OperationRunner, with the
  progress dialog); closing the window (or being asked to end) while
  one runs asks whether to stop it. The window's place and size and the
  panes' widths are remembered when it closes.
}
unit FileManager.CommandWindow;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Controls.Base,
  Controls.DragData,
  FileManager.BrowserWindow,
  FileManager.OperationTypes,
  FileManager.OperationRunner,
  FileManager.UndoHistory;

type
  TCommandWindow = class(TBrowserWindow)
  private
    FRunner: TOperationRunner;
    FCloseWhenIdle: Boolean;
    FRedoingTrash: Boolean;
    FShowWhenExtracted: string;
    procedure FilesDropped(Sender: TControl; Paths: TStrings; const TargetFolder: string; Effect: TDropEffect);
    procedure FoldersPinned(Sender: TControl; Paths: TStrings);
    procedure OperationFinished(Sender: TObject; const Request: TOperationRequest; const Outcome: TOperationOutcome);
    procedure RunnerIdle(Sender: TObject);
    procedure RememberPlace;
    procedure RecordUndo(const Request: TOperationRequest; const Outcome: TOperationOutcome);
    procedure CarryOut(const Steps: TPlanSteps);
    procedure ForgetTrashInfo(Paths: TStrings);
  protected
    FHistory: TUndoHistory;
    procedure CloseRequested; override;
    procedure StartOperation(Kind: TOperationKind; Paths: TStrings; const TargetFolder: string;
      FromHistory: Boolean = False);
    { Asks whether to stop a running operation; True to close now. }
    function MayClose: Boolean;
    { After extracting: the place to show when it is done. }
    property ShowWhenExtracted: string read FShowWhenExtracted write FShowWhenExtracted;
  public
    constructor Create;
    destructor Destroy; override;
    procedure DeleteSelected(Permanently: Boolean);
    procedure RestoreSelected;
    procedure RestoreAll;
    procedure EmptyTrash;
    procedure CopySelected(Cut: Boolean);
    procedure PasteFiles;
    procedure Undo;
    procedure Redo;
    function HasSelection: Boolean;
    function CanPaste: Boolean;
    function CanUndo: Boolean;
    function CanRedo: Boolean;
  end;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Files,
  Windowing.Windows,
  Controls.Window,
  Controls.Dialogs,
  Controls.Clipboard,
  Controls.MessageBoxes,
  Controls.FileNames,
  Controls.FileLists,
  Util.Trash,
  FileManager.Items,
  FileManager.Entries,
  FileManager.Paths,
  FileManager.Locations,
  FileManager.Settings,
  FileManager.UserLists,
  FileManager.ErrorTexts,
  FileManager.Output;

constructor TCommandWindow.Create;
begin
  inherited Create;
  FHistory := TUndoHistory.Create;
  FRunner := TOperationRunner.Create(Self, FOptions.ProgressDelay);
  FRunner.OnFinished := @OperationFinished;
  FRunner.OnIdle := @RunnerIdle;
  FView.OnDropFiles := @FilesDropped;
  FPlaces.OnDropFiles := @FilesDropped;
  FPlaces.OnPinFolders := @FoldersPinned;
end;

destructor TCommandWindow.Destroy;
begin
  FRunner.Free;
  FHistory.Free;
  inherited Destroy;
end;

function TCommandWindow.HasSelection: Boolean;
begin
  Result := FView.SelectedCount > 0;
end;

{ --- Operations ------------------------------------------------------------------------------ }

procedure TCommandWindow.StartOperation(Kind: TOperationKind; Paths: TStrings; const TargetFolder: string;
  FromHistory: Boolean);
var
  Request: TOperationRequest;
  Index: LongInt;
begin
  if Paths.Count = 0 then
    Exit;
  if Kind in [OperationCopy, OperationMove] then
    for Index := 0 to Paths.Count - 1 do
      if IsSameOrInside(TargetFolder, Paths[Index]) and (ParentFolderOf(Paths[Index]) <> TargetFolder) then
      begin
        Say('error ' + LastPartOf(Paths[Index]) + ' cannot go into itself');
        ShowMessageBox(ProgramTitle, 'The folder ' + LastPartOf(Paths[Index]) + ' cannot be put into itself.',
          MessageOk, SignError, Self);
        Exit;
      end;
  Request := Default(TOperationRequest);
  Request.Kind := Kind;
  Request.TargetFolder := TargetFolder;
  Request.FromHistory := FromHistory;
  SetLength(Request.Sources, Paths.Count);
  for Index := 0 to Paths.Count - 1 do
    Request.Sources[Index] := Paths[Index];
  FRunner.Start(Request);
end;

procedure TCommandWindow.RecordUndo(const Request: TOperationRequest; const Outcome: TOperationOutcome);
var
  Kind: TUndoKind;
begin
  if Request.FromHistory or (Length(Outcome.DoneSources) = 0) then
    Exit;
  case Request.Kind of
    OperationCopy, OperationExtract: Kind := UndoCopy;
    OperationMove: Kind := UndoMove;
    OperationTrash: Kind := UndoTrash;
    OperationCompress: Kind := UndoNewFile;
  else
    Exit;
  end;
  FHistory.Push(MakeEntry(Kind, Outcome.DoneSources, Outcome.DoneTargets));
  Say('undo-recorded ' + EntryDescription(FHistory.NextUndo, True));
end;

procedure TCommandWindow.OperationFinished(Sender: TObject; const Request: TOperationRequest;
  const Outcome: TOperationOutcome);
var
  Index: LongInt;
begin
  RecordUndo(Request, Outcome);
  { A redo of a move to the trash: the items have new names there. }
  if FRedoingTrash and (Request.Kind = OperationTrash) then
  begin
    FRedoingTrash := False;
    FHistory.ReplaceLastDone(MakeEntry(UndoTrash, Outcome.DoneSources, Outcome.DoneTargets));
  end;
  if Request.Kind = OperationMove then
    for Index := 0 to High(Outcome.DoneSources) do
      RenameInLists(Outcome.DoneSources[Index], Outcome.DoneTargets[Index]);
  if FCloseWhenIdle then
    Exit;
  if (Request.Kind = OperationExtract) and (FShowWhenExtracted <> '') and not Outcome.Stopped then
  begin
    NavigateAddress(FShowWhenExtracted);
    FShowWhenExtracted := '';
  end
  else
    RefreshFolder;
  FPlaces.UpdateTrash;
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

{ --- Deleting and the recycle bin -------------------------------------------------------------- }

procedure TCommandWindow.ForgetTrashInfo(Paths: TStrings);
var
  Index: LongInt;
  Trashed: TTrashItem;
begin
  for Index := 0 to Paths.Count - 1 do
    if TrashItemAt(Paths[Index], Trashed) then
      ForgetTrashItem(Trashed);
end;

procedure TCommandWindow.DeleteSelected(Permanently: Boolean);
var
  Paths: TStringList;
  Question: string;
  InTrash: Boolean;
begin
  Paths := TStringList.Create;
  try
    InTrash := FView.Location.Kind = LocationTrash;
    FView.GetSelectedPaths(Paths, InTrash);
    if Paths.Count = 0 then
      Exit;
    if InTrash then
      Permanently := True;
    if Paths.Count = 1 then
      Question := '"' + FView.FocusedEntry.Item.Name + '"'
    else
      Question := 'these ' + IntToStr(Paths.Count) + ' items';
    if Permanently then
      Question := 'Permanently delete ' + Question + '?'#10'They cannot be brought back.'
    else
      Question := 'Move ' + Question + ' to the recycle bin?';
    Say('asking delete ' + IntToStr(Paths.Count));
    if ShowMessageBox('Delete', Question, MessageYesNo, SignWarning, Self) <> ResultYes then
    begin
      Say('delete cancelled');
      Exit;
    end;
    if InTrash then
    begin
      { The info files go now; the items themselves in the background. }
      ForgetTrashInfo(Paths);
      StartOperation(OperationDelete, Paths, '');
    end
    else if Permanently then
      StartOperation(OperationDelete, Paths, '')
    else
      StartOperation(OperationTrash, Paths, '');
  finally
    Paths.Free;
  end;
end;

procedure TCommandWindow.RestoreSelected;
var
  Paths: TStringList;
begin
  if FView.Location.Kind <> LocationTrash then
    Exit;
  Paths := TStringList.Create;
  try
    FView.GetSelectedPaths(Paths, True);
    StartOperation(OperationRestore, Paths, '');
  finally
    Paths.Free;
  end;
end;

procedure TCommandWindow.RestoreAll;
var
  Paths: TStringList;
  Trashed: TTrashItem;
begin
  Paths := TStringList.Create;
  try
    for Trashed in ListTrash do
      Paths.Add(TrashItemPath(Trashed));
    StartOperation(OperationRestore, Paths, '');
  finally
    Paths.Free;
  end;
end;

procedure TCommandWindow.EmptyTrash;
var
  Paths: TStringList;
  Trashed: TTrashItem;
begin
  Paths := TStringList.Create;
  try
    for Trashed in ListTrash do
      Paths.Add(TrashItemPath(Trashed));
    if Paths.Count = 0 then
      Exit;
    Say('asking empty ' + IntToStr(Paths.Count));
    if ShowMessageBox('Empty recycle bin', 'Permanently delete the ' + IntToStr(Paths.Count) +
      ' items in the recycle bin?', MessageYesNo, SignWarning, Self) <> ResultYes then
      Exit;
    ForgetTrashInfo(Paths);
    StartOperation(OperationDelete, Paths, '');
  finally
    Paths.Free;
  end;
end;

{ --- The clipboard ---------------------------------------------------------------------------- }

procedure TCommandWindow.CopySelected(Cut: Boolean);
var
  Paths: TStringList;
begin
  Paths := TStringList.Create;
  try
    FView.GetSelectedPaths(Paths, FView.Location.Kind in [LocationArchive, LocationSearch]);
    if Paths.Count = 0 then
      Exit;
    if Cut and (FView.Location.Kind = LocationFolder) then
    begin
      SetClipboardFileList(FileListCut, Paths);
      FView.MarkCut(Paths);
      Say('clipboard cut ' + IntToStr(Paths.Count));
    end
    else
    begin
      SetClipboardFileList(FileListCopy, Paths);
      FView.MarkCut(nil);
      Say('clipboard copy ' + IntToStr(Paths.Count));
    end;
  finally
    Paths.Free;
  end;
end;

function TCommandWindow.CanPaste: Boolean;
begin
  Result := ClipboardHoldsFileList and (FView.Location.Kind = LocationFolder);
end;

{ The archive a path leads into, and the entry inside it ('' if the
  path is not inside an archive). }
function SplitArchived(const Path: string; out Archive, Inner: string): Boolean;
var
  Location: TLocation;
begin
  Result := ParseAddress(Path, '/', Location) and (Location.Kind = LocationArchive) and (Location.InnerPath <> '');
  Archive := Location.Path;
  Inner := Location.InnerPath;
end;

procedure TCommandWindow.PasteFiles;
var
  Paths: TStringList;
  Action: TFileListAction;
  Archive: string;
  Inner: string;
  Each: string;
  ArchivePart: string;
  InnerPart: string;
  Extracted: TStringList;
begin
  if FView.Location.Kind <> LocationFolder then
    Exit;
  Paths := TStringList.Create;
  Extracted := TStringList.Create;
  try
    if not ClipboardFileList(Action, Paths) or (Paths.Count = 0) then
      Exit;
    { Out of an archive: extracted here. }
    if not PathExists(PChar(Paths[0])) and SplitArchived(Paths[0], Archive, Inner) then
    begin
      Extracted.Add(Archive);
      for Each in Paths do
        if SplitArchived(Each, ArchivePart, InnerPart) then
          Extracted.Add(InnerPart);
      StartOperation(OperationExtract, Extracted, FView.Folder);
      Exit;
    end;
    if Action = FileListCut then
    begin
      SetClipboardText('');
      FView.MarkCut(nil);
      StartOperation(OperationMove, Paths, FView.Folder);
    end
    else
      StartOperation(OperationCopy, Paths, FView.Folder);
  finally
    Extracted.Free;
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

procedure TCommandWindow.FoldersPinned(Sender: TControl; Paths: TStrings);
var
  Path: string;
begin
  for Path in Paths do
    if IsDirectory(PChar(Path)) then
    begin
      AddToUserList(ListPinned, Path);
      Say('pinned ' + Path);
    end;
  FPlaces.ShowPinned;
  if FView.Location.Kind = LocationHome then
    FView.Refresh;
end;

{ --- Undo and redo ----------------------------------------------------------------------------- }

function TCommandWindow.CanUndo: Boolean;
begin
  Result := FHistory.CanUndo;
end;

function TCommandWindow.CanRedo: Boolean;
begin
  Result := FHistory.CanRedo;
end;

{ Carries out the steps: renames and new items here and now, the rest
  as operations (one per kind of step, in order). }
procedure TCommandWindow.CarryOut(const Steps: TPlanSteps);
var
  Index: LongInt;
  Error: LongInt;
  Paths: TStringList;
  Handle: Int64;
begin
  Paths := TStringList.Create;
  try
    for Index := 0 to High(Steps) do
      case Steps[Index].Kind of
        StepRename:
          begin
            Error := RenamePath(PChar(Steps[Index].Source), PChar(Steps[Index].Target));
            if Error = ErrorNone then
              RenameInLists(Steps[Index].Source, Steps[Index].Target)
            else
              Say('error undo rename ' + Steps[Index].Source + ': ' + ReasonText(Error));
          end;
        StepCreateFolder: CreateDirectory(PChar(Steps[Index].Source));
        StepCreateFile:
          begin
            Handle := OpenFile(PChar(Steps[Index].Source), OpenWrite or OpenCreate or OpenExclusive);
            if Handle >= 0 then
              CloseFile(Handle);
          end;
        StepTrash:
          begin
            Paths.Clear;
            Paths.Add(Steps[Index].Source);
            StartOperation(OperationTrash, Paths, '', True);
          end;
        StepRestore:
          begin
            Paths.Clear;
            Paths.Add(Steps[Index].Source);
            StartOperation(OperationRestore, Paths, '', True);
          end;
        StepMove, StepCopy:
          begin
            { Each to its own name (moving back may need a rename too). }
            if LastPartOf(Steps[Index].Source) = LastPartOf(Steps[Index].Target) then
            begin
              Paths.Clear;
              Paths.Add(Steps[Index].Source);
              if Steps[Index].Kind = StepMove then
                StartOperation(OperationMove, Paths, ParentFolderOf(Steps[Index].Target), True)
              else
                StartOperation(OperationCopy, Paths, ParentFolderOf(Steps[Index].Target), True);
            end
            else if (Steps[Index].Kind = StepMove) and
              (RenamePath(PChar(Steps[Index].Source), PChar(Steps[Index].Target)) <> ErrorNone) then
              Say('error undo move ' + Steps[Index].Source);
          end;
      end;
  finally
    Paths.Free;
  end;
  RefreshFolder;
end;

procedure TCommandWindow.Undo;
var
  Entry: TUndoEntry;
begin
  if not FHistory.CanUndo then
    Exit;
  Entry := FHistory.Undo;
  Say(LowerCase(EntryDescription(Entry, True)));
  CarryOut(PlanFor(Entry, True));
end;

procedure TCommandWindow.Redo;
var
  Entry: TUndoEntry;
begin
  if not FHistory.CanRedo then
    Exit;
  Entry := FHistory.Redo;
  Say(LowerCase(EntryDescription(Entry, False)));
  FRedoingTrash := Entry.Kind = UndoTrash;
  CarryOut(PlanFor(Entry, False));
end;

{ --- The window --------------------------------------------------------------------------------- }

procedure TCommandWindow.RememberPlace;
begin
  RememberWindow(ScreenLeft, ScreenTop, ClientWidth, ClientHeight, FSplitter.PaneWidth, FSideSplitter.PaneWidth);
end;

function TCommandWindow.MayClose: Boolean;
begin
  Result := True;
  if not FRunner.Busy then
    Exit;
  Say('asking stop');
  if ShowMessageBox(ProgramTitle, 'Files are still being copied, moved or deleted.'#10 + 'Stop that and close?',
    MessageYesNo, SignWarning, Self) <> ResultYes then
  begin
    Say('answer no');
    Exit(False);
  end;
  Say('answer yes');
  FCloseWhenIdle := True;
  FRunner.CancelAll;
  Result := not FRunner.Busy;
end;

procedure TCommandWindow.CloseRequested;
begin
  if FCloseWhenIdle then
    Exit;
  if not MayClose then
    Exit;
  RememberPlace;
  Say('exit');
  QuitMessageLoop(0);
end;

end.
