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
  System calls for watching files and folders (CallCreateWatch,
  CallReadWatch).

  A watch (FileSystem.Watches) is a handle of its own kind, which
  CallWaitForHandles waits on like any other: it is ready while change
  records wait in it. The path is a program's path; "/volumes" (the
  kernel's namespace root) watches the list of volumes. The devices
  under /dev are not files of any volume, and are not watched.
}
unit Processes.WatchCalls;

{$mode objfpc}

interface

function PerformCreateWatch(PathAddress: QWord; Flags: QWord): Int64;
function PerformReadWatch(Handle: Int64; BufferAddress: QWord; Capacity: QWord): Int64;
{ True for /dev and everything in it (devices are not watched). }
function IsDevicePath(UserPath: PChar): Boolean;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Abi.SystemCalls,
  Memory.KernelHeap,
  Kernel.Mutex,
  FileSystem.Types,
  FileSystem.Files,
  FileSystem.Watches,
  Objects.Manager,
  Processes.Handles,
  Processes.Paths,
  Processes.Process,
  Processes.Thread,
  Processes.UserAccess,
  Processes.ObjectCalls;

const
  DeviceDirectoryPath = '/dev';
  ReportFlags = WatchNames or WatchContents or WatchAttributes;
  { Records are moved out through a kernel buffer of at most this size
    at a time (a record with two long names fits). }
  ReadBufferSize = 8192;

type
  TPathBuffer = array[0..ProcessPathCapacity - 1] of Char;

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

{ True for /dev and everything in it. }
function IsDevicePath(UserPath: PChar): Boolean;
var
  Normalized: TPathBuffer;
  PrefixLength: PtrUInt;
begin
  Result := False;
  if NormalizeUserPath(CurrentProcess, UserPath, @Normalized[0], ProcessPathCapacity) <> ErrorNone then
    Exit;
  PrefixLength := TextLength(DeviceDirectoryPath);
  Result := (TextLength(@Normalized[0]) >= PrefixLength) and
    MemoryIsEqual(@Normalized[0], PChar(DeviceDirectoryPath), PrefixLength) and
    ((Normalized[PrefixLength] = #0) or (Normalized[PrefixLength] = '/'));
end;

function PerformCreateWatch(PathAddress: QWord; Flags: QWord): Int64;
var
  UserPath: TPathBuffer;
  KernelPath: TPathBuffer;
  Watch: PWatch;
  Status: TFileSystemStatus;
  Error: LongInt;
  Process: PProcess;
begin
  if ((Flags and not (ReportFlags or WatchSubtree)) <> 0) or ((Flags and ReportFlags) = 0) then
    Exit(Failure(ErrorInvalidArgument));
  Error := CopyStringFromUser(PathAddress, @UserPath[0], ProcessPathCapacity);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  if IsDevicePath(@UserPath[0]) then
    Exit(Failure(ErrorUnsupported));
  Error := TranslateUserPath(CurrentProcess, @UserPath[0], @KernelPath[0], ProcessPathCapacity);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Status := WatchPath(@KernelPath[0], LongWord(Flags), Watch);
  if Status <> StatusSuccess then
    Exit(Failure(ErrorFromStatus(Status)));
  Process := CurrentProcess;
  AcquireMutex(Process^.Lock);
  Result := InsertHandle(Process^.Handles, HandleKindWatch, Watch, 0);
  ReleaseMutex(Process^.Lock);
  { The handle holds its own reference. }
  DereferenceObject(Watch);
  if Result < 0 then
    Result := Failure(ErrorTooManyHandles);
end;

function PerformReadWatch(Handle: Int64; BufferAddress: QWord; Capacity: QWord): Int64;
var
  Watch: PWatch;
  Buffer: PByte;
  Used: QWord;
  ReadResult: TWatchReadResult;
  Error: LongInt;
begin
  Watch := PWatch(ReferenceHandleOfKind(Handle, HandleKindWatch));
  if Watch = nil then
    Exit(Failure(ErrorBadHandle));
  if Capacity > ReadBufferSize then
    Capacity := ReadBufferSize;
  { Checked first: records taken out of the watch must reach the
    program. }
  if not UserRangeIsValid(BufferAddress, Capacity, True) then
  begin
    DereferenceObject(Watch);
    Exit(Failure(ErrorBadAddress));
  end;
  Buffer := PByte(AllocateKernelMemory(ReadBufferSize));
  if Buffer = nil then
  begin
    DereferenceObject(Watch);
    Exit(Failure(ErrorOutOfMemory));
  end;
  ReadResult := ReadWatchRecords(Watch, Buffer, Capacity, Used);
  case ReadResult of
    WatchReadEmpty: Result := Failure(ErrorWouldBlock);
    WatchReadTooSmall: Result := Failure(ErrorMessageTooLong);
  else
    begin
      Error := CopyToUser(BufferAddress, Buffer, Used);
      if Error <> ErrorNone then
        Result := Failure(Error)
      else
        Result := Int64(Used);
    end;
  end;
  FreeKernelMemory(Buffer);
  DereferenceObject(Watch);
end;

end.
