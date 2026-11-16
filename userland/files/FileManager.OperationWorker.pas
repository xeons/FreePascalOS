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
  Doing a copy, move or delete, in a thread of its own so the window
  stays responsive (FileManager.OperationRunner starts it).

  First it counts what there is to do (files and bytes, for the
  progress window), then does it:

  * Copy: folders recursively, files in pieces (Sys.FileCopies), every
    copy keeping its permissions and times where the file system can
    hold them (owners too, for root), symbolic links copied as links.
    A folder's own permissions and times are set after its contents
    are in, so a read-only folder can be filled first.
  * Move: within a volume a rename, at once whatever the size; onto
    another volume a copy, then the original is removed once all of it
    has been copied (anything skipped or failed below an item keeps its
    original).
  * Delete: everything below a folder, then the folder; there is no
    recycle bin, it is gone.

  A name already taken at the target is a question (FileManager.
  OperationQuestions): replace it, skip, give the new one a numbered
  name ("notes (2).txt"), or stop; a folder onto a folder of the same
  name merges them, and copying a file into its own folder names the
  copy at once without asking. An error (no permission, the disk full,
  the volume unplugged) is a question too: skip the item, or stop. Cancel
  (FileManager.OperationProgress) is looked at between files and
  between the pieces of a file; a file stopped half way is removed.

  Everything that went wrong is written to Log for the window's thread
  to print once the worker is done: the output is not shared between
  threads.
}
unit FileManager.OperationWorker;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  FileManager.Items,
  FileManager.OperationTypes,
  FileManager.OperationProgress,
  FileManager.OperationQuestions;

type
  TOperationWorker = class
  private
    FRequest: TOperationRequest;
    FProgress: TOperationProgress;
    FQuestions: TQuestionChannel;
    FOutcome: TOperationOutcome;
    FLog: TStringList;
    FStopped: Boolean;
    { The folder a numbered name is looked for in. }
    FRenameFolder: string;
    { Bytes of the file being copied that are counted as done already. }
    FFileBytesCounted: QWord;
    function Stopping: Boolean;
    procedure CountItem(const Path: string; var Files, Bytes: QWord);
    procedure CountEverything;
    function AskAboutError(const Action, Path: string; Error: LongInt): Boolean;
    function NameTakenInRenameFolder(const Name: string): Boolean;
    function ResolveConflict(const SourcePath: string; const Source: TFolderItem; var TargetPath: string): LongInt;
    function CopyFile(const SourcePath, TargetPath: string; const Source: TFolderItem; Replace: Boolean): Boolean;
    function CopyFolder(const SourcePath, TargetPath: string; Merge: Boolean): Boolean;
    function CopyItem(const SourcePath, TargetPath: string): Boolean;
    function MoveItem(const SourcePath, TargetPath: string): Boolean;
    function MoveByCopying(const SourcePath, TargetPath: string): Boolean;
    function DeleteItem(const Path: string; Counted: Boolean): Boolean;
    procedure DoTopLevelItem(const SourcePath: string);
  public
    constructor Create(const ARequest: TOperationRequest; AProgress: TOperationProgress; AQuestions: TQuestionChannel);
    destructor Destroy; override;
    { Runs in the worker's thread. }
    procedure Run;
    property Request: TOperationRequest read FRequest;
    property Outcome: TOperationOutcome read FOutcome;
    property Log: TStringList read FLog;
  end;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Files,
  Sys.FileCopies,
  Controls.FileNames,
  FileManager.Paths,
  FileManager.ConflictNames,
  FileManager.FolderReading,
  FileManager.ErrorTexts;

const
  { What ResolveConflict decides. }
  ResolutionNew = 0;
  ResolutionReplace = 1;
  ResolutionMerge = 2;
  ResolutionSkip = 3;
  ResolutionStop = 4;

{ After each piece of a file: counts it, and stops if the user said so. }
function PieceCopied(PieceBytes: QWord; Context: Pointer): Boolean;
var
  Worker: TOperationWorker;
begin
  Worker := TOperationWorker(Context);
  Worker.FProgress.AddDone(0, PieceBytes);
  Worker.FFileBytesCounted := Worker.FFileBytesCounted + PieceBytes;
  Result := not Worker.Stopping;
end;

constructor TOperationWorker.Create(const ARequest: TOperationRequest; AProgress: TOperationProgress;
  AQuestions: TQuestionChannel);
var
  Index: LongInt;
begin
  inherited Create;
  FRequest.Kind := ARequest.Kind;
  FRequest.TargetFolder := ARequest.TargetFolder;
  UniqueString(FRequest.TargetFolder);
  SetLength(FRequest.Sources, Length(ARequest.Sources));
  { Copies of their own: the thread must share no strings with the
    window's. }
  for Index := 0 to High(ARequest.Sources) do
  begin
    FRequest.Sources[Index] := ARequest.Sources[Index];
    UniqueString(FRequest.Sources[Index]);
  end;
  FProgress := AProgress;
  FQuestions := AQuestions;
  FLog := TStringList.Create;
end;

destructor TOperationWorker.Destroy;
begin
  FLog.Free;
  inherited Destroy;
end;

function TOperationWorker.Stopping: Boolean;
begin
  if not FStopped and FProgress.IsCancelled then
    FStopped := True;
  Result := FStopped;
end;

{ --- Counting --------------------------------------------------------------------------- }

procedure TOperationWorker.CountItem(const Path: string; var Files, Bytes: QWord);
var
  Item: TFolderItem;
  Children: TFolderItems;
  Index: LongInt;
begin
  if Stopping or (DescribeItem(Path, Item) <> ErrorNone) then
    Exit;
  if (Item.Kind = ItemFolder) and not Item.IsLink then
  begin
    if ReadFolderItems(Path, True, Children) <> ErrorNone then
      Exit;
    for Index := 0 to High(Children) do
      CountItem(CombinePath(Path, Children[Index].Name), Files, Bytes);
    Exit;
  end;
  Inc(Files);
  if (Item.Kind = ItemFile) and not Item.IsLink then
    Bytes := Bytes + Item.SizeInBytes;
end;

procedure TOperationWorker.CountEverything;
var
  Files: QWord;
  Bytes: QWord;
  Index: LongInt;
begin
  Files := 0;
  Bytes := 0;
  for Index := 0 to High(FRequest.Sources) do
    if (FRequest.Kind = OperationMove) and
       (VolumeNumberOf(FRequest.Sources[Index]) = VolumeNumberOf(FRequest.TargetFolder)) then
      { A rename: one step, however much is in it. }
      Inc(Files)
    else
      CountItem(FRequest.Sources[Index], Files, Bytes);
  FProgress.SetTotals(Files, Bytes);
end;

{ --- Questions ------------------------------------------------------------------------- }

{ Tells of an error and asks what to do: True to skip the item and go
  on, False to stop. }
function TOperationWorker.AskAboutError(const Action, Path: string; Error: LongInt): Boolean;
var
  Question: TOperationQuestion;
  Answer: TOperationAnswer;
begin
  Inc(FOutcome.Errors);
  FLog.Add('error ' + Action + ' ' + Path + ': ' + ReasonText(Error));
  if Stopping then
    Exit(False);
  Question := Default(TOperationQuestion);
  Question.Kind := QuestionError;
  Question.Action := Action;
  Question.ErrorPath := Path;
  Question.Error := Error;
  Answer := FQuestions.Ask(Question);
  Result := Answer.Choice = Ord(ErrorSkip);
  if not Result then
    FStopped := True;
end;

function TOperationWorker.NameTakenInRenameFolder(const Name: string): Boolean;
begin
  Result := PathExists(PChar(CombinePath(FRenameFolder, Name)));
end;

{ Something at TargetPath already: merge (folder onto folder), or ask.
  A rename changes TargetPath. }
function TOperationWorker.ResolveConflict(const SourcePath: string; const Source: TFolderItem;
  var TargetPath: string): LongInt;
var
  Target: TFolderItem;
  Question: TOperationQuestion;
  Answer: TOperationAnswer;
  SourceIsFolder: Boolean;
begin
  if DescribeItem(TargetPath, Target) <> ErrorNone then
    Exit(ResolutionNew);
  SourceIsFolder := (Source.Kind = ItemFolder) and not Source.IsLink;
  FRenameFolder := ParentFolderOf(TargetPath);
  { A copy into the folder it is in: a numbered name, no question. }
  if TargetPath = SourcePath then
  begin
    if FRequest.Kind <> OperationCopy then
      Exit(ResolutionSkip);
    TargetPath := CombinePath(FRenameFolder, FirstFreeName(Source.Name, SourceIsFolder, @NameTakenInRenameFolder));
    Exit(ResolutionNew);
  end;
  if SourceIsFolder and (Target.Kind = ItemFolder) and not Target.IsLink then
    Exit(ResolutionMerge);
  Question := Default(TOperationQuestion);
  Question.Kind := QuestionConflict;
  Question.Source := Source;
  Question.Target := Target;
  Question.SourcePath := SourcePath;
  Question.TargetPath := TargetPath;
  { A whole folder is never replaced by something else. }
  Question.CanReplace := (Target.Kind <> ItemFolder) or Target.IsLink;
  Answer := FQuestions.Ask(Question);
  case TConflictChoice(Answer.Choice) of
    ConflictReplace:
      if Question.CanReplace then
        Result := ResolutionReplace
      else
        Result := ResolutionSkip;
    ConflictRename:
      begin
        TargetPath := CombinePath(FRenameFolder, FirstFreeName(LastPartOf(TargetPath), SourceIsFolder,
          @NameTakenInRenameFolder));
        Result := ResolutionNew;
      end;
    ConflictStop:
      begin
        FStopped := True;
        Result := ResolutionStop;
      end;
  else
    Result := ResolutionSkip;
  end;
end;

{ --- Copying ---------------------------------------------------------------------------- }

function TOperationWorker.CopyFile(const SourcePath, TargetPath: string; const Source: TFolderItem;
  Replace: Boolean): Boolean;
var
  Flags: LongWord;
  Failure: TCopyFailure;
  Target: TFolderItem;
begin
  FProgress.SetCurrentName(Source.Name);
  Flags := CopyKeepAttributes;
  if Replace then
  begin
    Flags := Flags or CopyReplace;
    { Writing over a link would write into what it points to. }
    if (DescribeItem(TargetPath, Target) = ErrorNone) and Target.IsLink then
      RemovePath(PChar(TargetPath));
  end;
  FFileBytesCounted := 0;
  if Source.IsLink then
    Failure := CopySymbolicLink(PChar(SourcePath), PChar(TargetPath), Flags)
  else if Source.Kind = ItemPipe then
  begin
    Failure.Error := CreateFifo(PChar(TargetPath));
    Failure.AtTarget := True;
  end
  else if Source.Kind <> ItemFile then
  begin
    Failure.Error := ErrorUnsupported;
    Failure.AtTarget := False;
  end
  else
    Failure := CopyFileData(PChar(SourcePath), PChar(TargetPath), Flags, @PieceCopied, Self);
  Result := Failure.Error = ErrorNone;
  if Result then
  begin
    FProgress.AddDone(1, 0);
    Exit;
  end;
  { What was not copied counts as done, so the bar still ends full. }
  if (Source.Kind = ItemFile) and not Source.IsLink and (Source.SizeInBytes > FFileBytesCounted) then
    FProgress.AddDone(1, Source.SizeInBytes - FFileBytesCounted)
  else
    FProgress.AddDone(1, 0);
  if Stopping then
    Exit;
  if Failure.AtTarget then
    AskAboutError('copy', TargetPath, Failure.Error)
  else
    AskAboutError('copy', SourcePath, Failure.Error);
end;

function TOperationWorker.CopyFolder(const SourcePath, TargetPath: string; Merge: Boolean): Boolean;
var
  Children: TFolderItems;
  Index: LongInt;
  Error: LongInt;
  Information: TFileInformation;
begin
  Result := False;
  FProgress.SetCurrentName(LastPartOf(SourcePath));
  if not Merge then
  begin
    Error := CreateDirectory(PChar(TargetPath));
    if Error <> ErrorNone then
    begin
      AskAboutError('create folder', TargetPath, Error);
      Exit;
    end;
  end;
  Error := ReadFolderItems(SourcePath, True, Children);
  if Error <> ErrorNone then
  begin
    AskAboutError('read folder', SourcePath, Error);
    Exit;
  end;
  Result := True;
  for Index := 0 to High(Children) do
  begin
    if Stopping then
      Exit(False);
    if not CopyItem(CombinePath(SourcePath, Children[Index].Name), CombinePath(TargetPath, Children[Index].Name)) then
      Result := False;
  end;
  { Its permissions and times last: a read-only folder could not have
    been filled, and filling it changed its time. }
  if GetLinkInformation(PChar(SourcePath), Information) = ErrorNone then
    CopyAttributes(PChar(TargetPath), Information);
end;

{ Copies the item at SourcePath to TargetPath; True if all of it was
  copied (nothing skipped, nothing failed). }
function TOperationWorker.CopyItem(const SourcePath, TargetPath: string): Boolean;
var
  Source: TFolderItem;
  Target: string;
  Error: LongInt;
begin
  if Stopping then
    Exit(False);
  Error := DescribeItem(SourcePath, Source);
  if Error <> ErrorNone then
  begin
    AskAboutError('copy', SourcePath, Error);
    Exit(False);
  end;
  Target := TargetPath;
  case ResolveConflict(SourcePath, Source, Target) of
    ResolutionNew:
      if (Source.Kind = ItemFolder) and not Source.IsLink then
        Result := CopyFolder(SourcePath, Target, False)
      else
        Result := CopyFile(SourcePath, Target, Source, False);
    ResolutionReplace: Result := CopyFile(SourcePath, Target, Source, True);
    ResolutionMerge: Result := CopyFolder(SourcePath, Target, True);
  else
    begin
      { Skipped (or stopped): its files count as done for the bar. }
      Result := False;
      Inc(FOutcome.ItemsSkipped);
    end;
  end;
end;

{ --- Moving ------------------------------------------------------------------------------ }

{ Onto another volume: a copy, then the original goes if all of it was
  copied. }
function TOperationWorker.MoveByCopying(const SourcePath, TargetPath: string): Boolean;
begin
  Result := CopyItem(SourcePath, TargetPath) and not Stopping;
  if Result then
    Result := DeleteItem(SourcePath, False);
end;

function TOperationWorker.MoveItem(const SourcePath, TargetPath: string): Boolean;
var
  Source: TFolderItem;
  Target: string;
  Error: LongInt;
  Children: TFolderItems;
  Index: LongInt;
begin
  if Stopping then
    Exit(False);
  if VolumeNumberOf(SourcePath) <> VolumeNumberOf(ParentFolderOf(TargetPath)) then
    Exit(MoveByCopying(SourcePath, TargetPath));
  Error := DescribeItem(SourcePath, Source);
  if Error <> ErrorNone then
  begin
    AskAboutError('move', SourcePath, Error);
    Exit(False);
  end;
  FProgress.SetCurrentName(Source.Name);
  Target := TargetPath;
  case ResolveConflict(SourcePath, Source, Target) of
    ResolutionNew, ResolutionReplace:
      begin
        { A rename replaces a file at the target in one step. }
        Error := RenamePath(PChar(SourcePath), PChar(Target));
        if Error = ErrorCrossVolume then
          Exit(MoveByCopying(SourcePath, Target));
        Result := Error = ErrorNone;
        if not Result then
          AskAboutError('move', SourcePath, Error);
        FProgress.AddDone(1, 0);
      end;
    ResolutionMerge:
      begin
        { A folder onto a folder: its contents one by one, then the
          folder itself if it is left empty. }
        Result := ReadFolderItems(SourcePath, True, Children) = ErrorNone;
        for Index := 0 to High(Children) do
          if not MoveItem(CombinePath(SourcePath, Children[Index].Name),
             CombinePath(Target, Children[Index].Name)) then
            Result := False;
        if Result then
        begin
          Error := RemovePath(PChar(SourcePath));
          if Error <> ErrorNone then
          begin
            AskAboutError('move', SourcePath, Error);
            Result := False;
          end;
        end;
        FProgress.AddDone(1, 0);
      end;
  else
    begin
      Result := False;
      Inc(FOutcome.ItemsSkipped);
      FProgress.AddDone(1, 0);
    end;
  end;
end;

{ --- Deleting ---------------------------------------------------------------------------- }

{ Removes Path and everything below it; Counted: its files count in the
  progress (not when removing what a move has copied). }
function TOperationWorker.DeleteItem(const Path: string; Counted: Boolean): Boolean;
var
  Item: TFolderItem;
  Children: TFolderItems;
  Index: LongInt;
  Error: LongInt;
begin
  if Stopping then
    Exit(False);
  Error := DescribeItem(Path, Item);
  if Error <> ErrorNone then
  begin
    AskAboutError('delete', Path, Error);
    Exit(False);
  end;
  Result := True;
  if (Item.Kind = ItemFolder) and not Item.IsLink then
  begin
    Error := ReadFolderItems(Path, True, Children);
    if Error <> ErrorNone then
    begin
      AskAboutError('delete', Path, Error);
      Exit(False);
    end;
    for Index := 0 to High(Children) do
      if not DeleteItem(CombinePath(Path, Children[Index].Name), Counted) then
        Result := False;
    if not Result then
      Exit;
  end
  else
  begin
    FProgress.SetCurrentName(Item.Name);
    if Counted then
      FProgress.AddDone(1, 0);
  end;
  Error := RemovePath(PChar(Path));
  if Error <> ErrorNone then
  begin
    AskAboutError('delete', Path, Error);
    Result := False;
  end;
end;

{ --- The whole operation ------------------------------------------------------------------ }

procedure TOperationWorker.DoTopLevelItem(const SourcePath: string);
var
  TargetPath: string;
  Done: Boolean;
begin
  if FRequest.Kind = OperationDelete then
    Done := DeleteItem(SourcePath, True)
  else
  begin
    TargetPath := CombinePath(FRequest.TargetFolder, LastPartOf(SourcePath));
    if IsSameOrInside(FRequest.TargetFolder, SourcePath) and (TargetPath <> SourcePath) then
    begin
      { A folder into itself would never end. }
      Inc(FOutcome.Errors);
      FLog.Add('error ' + LowerCase(OperationVerb(FRequest.Kind)) + ' ' + SourcePath +
        ': a folder cannot go into itself');
      Exit;
    end;
    if FRequest.Kind = OperationCopy then
      Done := CopyItem(SourcePath, TargetPath)
    else
      Done := MoveItem(SourcePath, TargetPath);
  end;
  if Done then
    Inc(FOutcome.ItemsDone);
end;

procedure TOperationWorker.Run;
var
  Index: LongInt;
begin
  try
    CountEverything;
    for Index := 0 to High(FRequest.Sources) do
    begin
      if Stopping then
        Break;
      DoTopLevelItem(FRequest.Sources[Index]);
    end;
  except
    on Problem: Exception do
    begin
      Inc(FOutcome.Errors);
      FLog.Add('error ' + Problem.Message);
    end;
  end;
  FOutcome.Stopped := FStopped;
end;

end.
