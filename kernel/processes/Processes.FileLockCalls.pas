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
  Advisory file locks for programs: the ControlLockFile and
  ControlUnlockFile requests of CallControlHandle on a file or directory
  handle (see FileSystem.Locks).

  The open file is referenced for as long as the request runs, since a
  wait for a lock may be long and another thread of the program may
  close the handle meanwhile.
}
unit Processes.FileLockCalls;

{$mode objfpc}

interface

{ Carries out Request (ControlLockFile or ControlUnlockFile) on the open
  file behind Handle. Returns 0 or minus an Abi error code. }
function PerformFileLockRequest(Handle: Int64; Request: QWord; Argument: QWord): Int64;

implementation

uses
  Abi.SystemCalls,
  Kernel.Mutex,
  Objects.Manager,
  FileSystem.Types,
  FileSystem.Files,
  FileSystem.Locks,
  Processes.Process,
  Processes.Handles,
  Processes.Thread;

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

{ The open file behind Handle, referenced; nil if Handle is not a file. }
function ReferenceOpenFile(Handle: Int64): POpenFile;
var
  Process: PProcess;
  Kind: THandleKind;
  ObjectBody: Pointer;
begin
  Result := nil;
  Process := CurrentProcess;
  AcquireMutex(Process^.Lock);
  if LookupHandle(Process^.Handles, Handle, Kind, ObjectBody) and (Kind = HandleKindFile) then
  begin
    ReferenceObject(ObjectBody);
    Result := POpenFile(ObjectBody);
  end;
  ReleaseMutex(Process^.Lock);
end;

function ErrorFromLockResult(LockResult: TFileLockResult): LongInt;
begin
  case LockResult of
    FileLockGranted: Result := ErrorNone;
    FileLockBusy: Result := ErrorWouldBlock;
    FileLockInterrupted: Result := ErrorInterrupted;
    FileLockDenied: Result := ErrorAccessDenied;
    FileLockOutOfMemory: Result := ErrorOutOfMemory;
  else
    Result := ErrorUnsupported;
  end;
end;

function LockKindOf(Argument: QWord; out Kind: TFileLockKind): Boolean;
begin
  Result := True;
  case Argument and not QWord(FileLockNoWait) of
    FileLockShared: Kind := LockKindShared;
    FileLockExclusive: Kind := LockKindExclusive;
  else
    Kind := LockKindNone;
    Result := False;
  end;
end;

function PerformFileLockRequest(Handle: Int64; Request: QWord; Argument: QWord): Int64;
var
  OpenedFile: POpenFile;
  Kind: TFileLockKind;
  Wait: Boolean;
begin
  if (Request = ControlLockFile) and not LockKindOf(Argument, Kind) then
    Exit(Failure(ErrorInvalidArgument));
  OpenedFile := ReferenceOpenFile(Handle);
  if OpenedFile = nil then
    Exit(Failure(ErrorBadHandle));
  Result := 0;
  if Request = ControlLockFile then
  begin
    Wait := (Argument and FileLockNoWait) = 0;
    Result := Failure(ErrorFromLockResult(LockOpenFile(OpenedFile, Kind, Wait)));
  end
  else
    UnlockOpenFile(OpenedFile);
  DereferenceObject(OpenedFile);
end;

end.
