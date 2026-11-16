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
  Copying one file, symbolic link or folder entry: the pieces cp, mv and
  the file manager build tree copies from.

  CopyFileData copies a file's contents in pieces, telling a progress
  routine after each one, which may stop the copy; a copy that fails or
  is stopped part way leaves no half-written file behind (the target it
  made is removed). It says which side failed, so a caller can report
  "cannot read" or "cannot write" with the right name. The target is
  made new (ErrorExists if something is there) unless CopyReplace says
  to write over an existing file.

  With CopyKeepAttributes the copy gets the source's permissions and
  times, and its owner and group where the caller may give them (root,
  or a group of the caller's own); a file system without owners (FAT,
  exFAT) keeps its own without complaint. Without it a new file gets the
  source's permission bits less the umask, as cp does.

  CopySymbolicLink makes a link with the same target text: links are
  copied as links, never followed.
}
unit Sys.FileCopies;

{$mode objfpc}

interface

uses
  Abi.SystemCalls,
  Sys.Files;

const
  { Give the copy the source's mode, times, owner and group. }
  CopyKeepAttributes = $01;
  { Write over an existing file at the target (else ErrorExists). }
  CopyReplace = $02;

  { How much is read and written at a time. }
  CopyPieceSize = 64 * 1024;

type
  { Called after each piece with the bytes copied in it; False stops the
    copy (it then fails with ErrorInterrupted). }
  TCopyProgress = function(PieceBytes: QWord; Context: Pointer): Boolean;

  TCopyFailure = record
    { ErrorNone, or why the copy failed. }
    Error: LongInt;
    { The error came from writing (or making) the target, not from
      reading the source. }
    AtTarget: Boolean;
  end;

{ Copies the contents of the file Source to a file Target; Progress
  (may be nil) hears of every piece. }
function CopyFileData(Source, Target: PChar; Flags: LongWord; Progress: TCopyProgress;
  Context: Pointer): TCopyFailure;
{ Makes Target a symbolic link with Source's target; with CopyReplace an
  existing link or file at Target is replaced. }
function CopySymbolicLink(Source, Target: PChar; Flags: LongWord): TCopyFailure;
{ Gives Target (not following a final link) Information's mode, times
  and, where allowed, owner and group. 0 or the error setting the mode
  and times. }
function CopyAttributes(Target: PChar; const Information: TFileInformation): LongInt;

implementation

uses
  Sys.Errors,
  Sys.Memory;

const
  PermissionBits = $FFF;

function Failure(Error: LongInt; AtTarget: Boolean): TCopyFailure;
begin
  Result.Error := Error;
  Result.AtTarget := AtTarget;
end;

function CopyAttributes(Target: PChar; const Information: TFileInformation): LongInt;
var
  Changes: TAttributeChanges;
begin
  Changes.Fields := ChangeFieldModificationTime or ChangeFieldAccessTime or ChangeFieldOwner or ChangeFieldGroup;
  Changes.ModificationTime := Information.ModificationTime;
  Changes.AccessTime := Information.AccessTime;
  Changes.OwnerId := Information.OwnerId;
  Changes.GroupId := Information.GroupId;
  Changes.Mode := Information.Mode and PermissionBits;
  { A link's own mode means nothing. }
  if Information.Kind <> KindSymbolicLink then
    Changes.Fields := Changes.Fields or ChangeFieldMode;
  Result := SetPathAttributes(Target, Changes, False);
  if Result = ErrorNone then
    Exit;
  { Not allowed to give the owner away (or no owners here): the mode and
    times alone. }
  Changes.Fields := Changes.Fields and not (ChangeFieldOwner or ChangeFieldGroup);
  Result := SetPathAttributes(Target, Changes, False);
end;

{ Copies everything from SourceHandle to TargetHandle. }
function CopyPieces(SourceHandle, TargetHandle: Int64; Progress: TCopyProgress; Context: Pointer): TCopyFailure;
var
  Buffer: Pointer;
  Count: Int64;
  Error: LongInt;
begin
  Result := Failure(ErrorNone, False);
  Buffer := AllocateMemory(CopyPieceSize);
  if Buffer = nil then
    Exit(Failure(ErrorOutOfMemory, False));
  repeat
    Count := ReadFile(SourceHandle, Buffer, CopyPieceSize);
    if Count < 0 then
    begin
      Result := Failure(ErrorCodeOf(Count), False);
      Break;
    end;
    if Count = 0 then
      Break;
    Error := WriteAll(TargetHandle, Buffer, QWord(Count));
    if Error <> ErrorNone then
    begin
      Result := Failure(Error, True);
      Break;
    end;
    if Assigned(Progress) and not Progress(QWord(Count), Context) then
    begin
      Result := Failure(ErrorInterrupted, False);
      Break;
    end;
  until False;
  FreeMemory(Buffer);
end;

function CopyFileData(Source, Target: PChar; Flags: LongWord; Progress: TCopyProgress;
  Context: Pointer): TCopyFailure;
var
  Information: TFileInformation;
  SourceHandle: Int64;
  TargetHandle: Int64;
  OpenFlags: LongWord;
  Error: LongInt;
  TargetExisted: Boolean;
begin
  TargetExisted := ((Flags and CopyReplace) <> 0) and PathExists(Target);
  SourceHandle := OpenFile(Source, OpenRead);
  if SourceHandle < 0 then
    Exit(Failure(ErrorCodeOf(SourceHandle), False));
  Error := GetHandleInformation(SourceHandle, Information);
  if Error <> ErrorNone then
  begin
    CloseFile(SourceHandle);
    Exit(Failure(Error, False));
  end;
  OpenFlags := OpenWrite or OpenCreate;
  if (Flags and CopyReplace) <> 0 then
    OpenFlags := OpenFlags or OpenTruncate
  else
    OpenFlags := OpenFlags or OpenExclusive;
  TargetHandle := OpenFile(Target, OpenFlags);
  if TargetHandle < 0 then
  begin
    CloseFile(SourceHandle);
    Exit(Failure(ErrorCodeOf(TargetHandle), True));
  end;
  Result := CopyPieces(SourceHandle, TargetHandle, Progress, Context);
  CloseFile(SourceHandle);
  CloseFile(TargetHandle);
  if Result.Error <> ErrorNone then
  begin
    { Half a file is worse than none: whoever looks would take it for
      the whole. }
    RemovePath(Target);
    Exit;
  end;
  if (Flags and CopyKeepAttributes) <> 0 then
    CopyAttributes(Target, Information)
  else if not TargetExisted then
    ChangeMode(Target, Information.Mode and $1FF and not CurrentUmask);
end;

function CopySymbolicLink(Source, Target: PChar; Flags: LongWord): TCopyFailure;
var
  LinkTarget: array[0..PathCapacity - 1] of Char;
  Information: TFileInformation;
  Error: LongInt;
begin
  Error := ReadSymbolicLink(Source, @LinkTarget[0], PathCapacity);
  if Error <> ErrorNone then
    Exit(Failure(Error, False));
  if ((Flags and CopyReplace) <> 0) and (GetLinkInformation(Target, Information) = ErrorNone) and
     (Information.Kind <> KindDirectory) then
    RemovePath(Target);
  Error := CreateSymbolicLink(@LinkTarget[0], Target);
  if Error <> ErrorNone then
    Exit(Failure(Error, True));
  if ((Flags and CopyKeepAttributes) <> 0) and (GetLinkInformation(Source, Information) = ErrorNone) then
    CopyAttributes(Target, Information);
  Result := Failure(ErrorNone, False);
end;

end.
