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
  What the user runtime needs to finish loading a library at run time
  (CallLoadLibrary): its thread-local storage (CallGetModuleTls) and
  the initializers and finalizers of it and the libraries loaded with
  it (CallTakeModuleInitializers).

  The kernel binds a late library's symbols itself, but its
  initializers are user code, and its thread-local storage is made per
  thread by the runtime (dynamic TLS, Processes.ImageLoader). So when
  CallLoadLibrary has loaded a library, NoteLibraryInitializers
  collects the entries in calling order (Processes.ImageInitializers)
  and keeps them with the library's module until the runtime takes
  them, which it does before LoadLibrary returns. Everything happens
  under the process's lock, as loading does.
}
unit Processes.ModuleCalls;

{$mode objfpc}
{$pointermath on}

interface

uses
  Processes.Process;

{ Keeps the initializers and finalizers that loading the library with
  handle ModuleHandle brought in (the process's lock held). }
function NoteLibraryInitializers(Process: PProcess; ModuleHandle: Integer): LongInt;

function PerformGetModuleTls(ModuleHandle: Int64; InformationAddress: QWord): Int64;
function PerformTakeModuleInitializers(ModuleHandle: Int64; ListsAddress: QWord): Int64;

implementation

uses
  Runtime.Memory,
  Abi.SystemCalls,
  Memory.KernelHeap,
  Kernel.Mutex,
  Processes.Thread,
  Processes.ImageLoader,
  Processes.ImageInitializers,
  Processes.UserAccess;

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

{ The module with this handle (the process's lock held), or nil. }
function ModuleOf(Process: PProcess; ModuleHandle: Int64): PLoadedModule;
var
  List: PModuleList;
begin
  Result := nil;
  List := PModuleList(Process^.Modules);
  if (List = nil) or (ModuleHandle < 0) or (ModuleHandle >= List^.Count) then
    Exit;
  Result := List^.Modules[ModuleHandle];
end;

{ First followed by Second, in a new kernel array (nil if both are
  empty); frees neither. }
function JoinEntries(First: PQWord; FirstCount: QWord; Second: PQWord; SecondCount: QWord;
  out Joined: PQWord): Boolean;
begin
  Joined := nil;
  if FirstCount + SecondCount = 0 then
    Exit(True);
  Joined := PQWord(AllocateKernelMemory((FirstCount + SecondCount) * SizeOf(QWord)));
  if Joined = nil then
    Exit(False);
  if FirstCount > 0 then
    CopyMemory(Joined, First, FirstCount * SizeOf(QWord));
  if SecondCount > 0 then
    CopyMemory(Joined + FirstCount, Second, SecondCount * SizeOf(QWord));
  Result := True;
end;

function NoteLibraryInitializers(Process: PProcess; ModuleHandle: Integer): LongInt;
var
  Module: PLoadedModule;
  Lists: TInitializerLists;
  Initializers: PQWord;
  Finalizers: PQWord;
begin
  Module := ModuleOf(Process, ModuleHandle);
  if Module = nil then
    Exit(ErrorBadHandle);
  Result := CollectModuleInitializers(Process, ModuleHandle, Lists);
  if (Result = ErrorNone) and (Lists.InitializerCount + Lists.FinalizerCount > 0) then
  begin
    { Entries from an earlier load nobody took yet come first; the new
      finalizers run before the older ones. }
    if not JoinEntries(Module^.PendingInitializers, Module^.PendingInitializerCount, Lists.Initializers,
         Lists.InitializerCount, Initializers) then
      Result := ErrorOutOfMemory
    else if not JoinEntries(Lists.Finalizers, Lists.FinalizerCount, Module^.PendingFinalizers,
         Module^.PendingFinalizerCount, Finalizers) then
    begin
      FreeKernelMemory(Initializers);
      Result := ErrorOutOfMemory;
    end
    else
    begin
      FreeKernelMemory(Module^.PendingInitializers);
      FreeKernelMemory(Module^.PendingFinalizers);
      Module^.PendingInitializers := Initializers;
      Module^.PendingInitializerCount := Module^.PendingInitializerCount + Lists.InitializerCount;
      Module^.PendingFinalizers := Finalizers;
      Module^.PendingFinalizerCount := Module^.PendingFinalizerCount + Lists.FinalizerCount;
    end;
  end;
  FreeInitializerLists(Lists);
end;

function PerformGetModuleTls(ModuleHandle: Int64; InformationAddress: QWord): Int64;
var
  Process: PProcess;
  Module: PLoadedModule;
  Information: TAbiModuleTls;
  Error: LongInt;
begin
  Process := CurrentProcess;
  FillMemory(@Information, SizeOf(Information), 0);
  Error := ErrorNone;
  AcquireMutex(Process^.Lock);
  Module := ModuleOf(Process, ModuleHandle);
  if Module = nil then
    Error := ErrorBadHandle
  else if not Module^.HasThreadLocalStorage then
    Error := ErrorNotFound
  else
  begin
    Information.ImageAddress := Module^.TlsImageAddress;
    Information.ImageSize := Module^.TlsImageSize;
    Information.BlockSize := Module^.TlsSize;
    Information.Alignment := Module^.TlsAlignment;
  end;
  ReleaseMutex(Process^.Lock);
  if Error = ErrorNone then
    Error := CopyToUser(InformationAddress, @Information, SizeOf(Information));
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Result := 0;
end;

function PerformTakeModuleInitializers(ModuleHandle: Int64; ListsAddress: QWord): Int64;
var
  Process: PProcess;
  Module: PLoadedModule;
  Request: TAbiModuleInitializers;
  Initializers: PQWord;
  Finalizers: PQWord;
  Error: LongInt;
begin
  Error := CopyFromUser(@Request, ListsAddress, SizeOf(Request));
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Process := CurrentProcess;
  Initializers := nil;
  Finalizers := nil;

  { Taken out of the module under the lock, copied out after it. }
  AcquireMutex(Process^.Lock);
  Module := ModuleOf(Process, ModuleHandle);
  if Module = nil then
    Error := ErrorBadHandle
  else
  begin
    Request.InitializerCount := Module^.PendingInitializerCount;
    Request.FinalizerCount := Module^.PendingFinalizerCount;
    if (Request.InitializerCount > Request.InitializerCapacity) or
       (Request.FinalizerCount > Request.FinalizerCapacity) then
      Error := ErrorMessageTooLong
    else
    begin
      Initializers := Module^.PendingInitializers;
      Finalizers := Module^.PendingFinalizers;
      Module^.PendingInitializers := nil;
      Module^.PendingInitializerCount := 0;
      Module^.PendingFinalizers := nil;
      Module^.PendingFinalizerCount := 0;
    end;
  end;
  ReleaseMutex(Process^.Lock);

  if (Error = ErrorNone) and (Request.InitializerCount > 0) then
    Error := CopyToUser(Request.Initializers, Initializers, Request.InitializerCount * SizeOf(QWord));
  if (Error = ErrorNone) and (Request.FinalizerCount > 0) then
    Error := CopyToUser(Request.Finalizers, Finalizers, Request.FinalizerCount * SizeOf(QWord));
  FreeKernelMemory(Initializers);
  FreeKernelMemory(Finalizers);
  { The counts go back in either case: too small arrays say how large
    they must be. }
  if (Error = ErrorNone) or (Error = ErrorMessageTooLong) then
    if CopyToUser(ListsAddress, @Request, SizeOf(Request)) <> ErrorNone then
      Error := ErrorBadAddress;
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Result := 0;
end;

end.
