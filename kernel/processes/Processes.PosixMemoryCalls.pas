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
  System calls of the POSIX block for memory and threads (the C
  library's): CallMapMemory (mmap), CallUnmapMemory (munmap) and
  CallCreateThreadOnStack (a thread on a stack the caller made, as
  pthread_create wants). The mapping work is Processes.MemoryMapping's.
}
unit Processes.PosixMemoryCalls;

{$mode objfpc}

interface

function PerformMapMemory(Address, Length, Protection, Flags: QWord; Handle: Int64; Offset: QWord): Int64;
function PerformUnmapMemory(Address, Length: QWord): Int64;
function PerformCreateThreadOnStack(EntryPoint, Argument, StackPointer: QWord): Int64;

implementation

uses
  Abi.SystemCalls,
  Memory.Layout,
  Memory.Arch.PageTables,
  Kernel.Mutex,
  Objects.Manager,
  Processes.Process,
  Processes.Thread,
  Processes.Handles,
  Processes.ObjectCalls,
  Processes.MappedFiles,
  Processes.MemoryMapping,
  Processes.UserThread,
  FileSystem.Files;

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

function PerformMapMemory(Address, Length, Protection, Flags: QWord; Handle: Int64; Offset: QWord): Int64;
var
  OpenedFile: POpenFile;
  MappedFile: PMappedFile;
  IsPrivate: Boolean;
  Error: LongInt;
  Start: QWord;
begin
  MappedFile := nil;
  IsPrivate := (Flags and PosixMapPrivate) <> 0;
  if (Flags and PosixMapAnonymous) = 0 then
  begin
    OpenedFile := POpenFile(ReferenceHandleOfKind(Handle, HandleKindFile));
    if OpenedFile = nil then
      Exit(Failure(ErrorBadHandle));
    Error := AcquireMappedFile(OpenedFile, IsPrivate, MappedFile);
    DereferenceObject(OpenedFile);
    if Error <> ErrorNone then
      Exit(Failure(Error));
  end;
  Error := MapMemory(CurrentProcess^.AddressSpace, Address, Length, Protection, Flags, MappedFile,
    Offset, Start);
  if Error <> ErrorNone then
  begin
    if MappedFile <> nil then
      ReleaseMappedFile(MappedFile, IsPrivate);
    Exit(Failure(Error));
  end;
  Result := Int64(Start);
end;

function PerformUnmapMemory(Address, Length: QWord): Int64;
begin
  Result := -Int64(UnmapMemory(CurrentProcess^.AddressSpace, Address, Length));
end;

function PerformCreateThreadOnStack(EntryPoint, Argument, StackPointer: QWord): Int64;
var
  Process: PProcess;
  Thread: PThread;
  Error: LongInt;
  Handle: Integer;
begin
  Process := CurrentProcess;
  if (EntryPoint = 0) or (EntryPoint >= UserSpaceLimit) or (StackPointer = 0) or
     (StackPointer >= UserSpaceLimit) or ((StackPointer and 15) <> 0) then
    Exit(Failure(ErrorInvalidArgument));
  { The stack is the caller's (StackStart 0): it stays when the thread
    ends. }
  Error := StartUserThread(Process, EntryPoint, StackPointer, Argument, 0, @Process^.Name[0], True, Thread);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  AcquireMutex(Process^.Lock);
  Handle := InsertHandle(Process^.Handles, HandleKindThread, Thread, 0);
  ReleaseMutex(Process^.Lock);
  DereferenceObject(Thread);
  if Handle < 0 then
    Exit(Failure(ErrorTooManyHandles));
  Result := Handle;
end;

end.
