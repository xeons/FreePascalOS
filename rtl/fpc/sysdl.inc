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
  Loading libraries at run time (LoadLibrary, GetProcAddress) through the
  kernel's loader, which maps the library and the ones it needs into the
  process and binds their symbols. Libraries stay loaded until the
  process ends; ordinals do not exist in ELF.

  What the kernel cannot do itself is done here before LoadLibrary
  returns: the initializers of the new libraries (DT_INIT, DT_INIT_ARRAY,
  dependencies first; for a Free Pascal library that is si_dll, which
  initializes its units, syslibraries.inc) are called, and their
  finalizers kept to be called when the program ends - before its units
  are finalized, newest library first. Their thread-local storage is
  made per thread when first touched (sysdyntls.inc). Loading is
  serialized by a lock an initializer may take again (it may load a
  library itself).
}

{$i syslibraries.inc}

type
  TLibraryInitializer = procedure(Count: LongInt; Arguments, Environment: PPChar); cdecl;
  TLibraryFinalizer = procedure; cdecl;

const
  InitializerBatch = 16;

var
  LastLoadError: LongInt = 0;
  LibraryLockState: LongInt = 0;
  LibraryLockOwner: QWord = 0;
  LibraryLockDepth: LongInt = 0;
  { Finalizers of libraries loaded at run time, in calling order. }
  LateFinalizers: PQWord = nil;
  LateFinalizerCount: PtrUInt = 0;
  LateFinalizersHooked: Boolean = False;

procedure AcquireLibraryLock;
begin
  if LibraryLockOwner = KernelThreadId then
  begin
    Inc(LibraryLockDepth);
    Exit;
  end;
  AcquireWordLock(LibraryLockState);
  LibraryLockOwner := KernelThreadId;
  LibraryLockDepth := 1;
end;

procedure ReleaseLibraryLock;
begin
  Dec(LibraryLockDepth);
  if LibraryLockDepth > 0 then
    Exit;
  LibraryLockOwner := 0;
  ReleaseWordLock(LibraryLockState);
end;

{ An exit procedure: runs before the program's units are finalized. }
procedure RunLateFinalizers;
var
  Entries: PQWord;
  Count: PtrUInt;
  Index: PtrUInt;
begin
  { Each runs once, even if one ends the process again. }
  Entries := LateFinalizers;
  Count := LateFinalizerCount;
  LateFinalizers := nil;
  LateFinalizerCount := 0;
  Index := 0;
  while Index < Count do
  begin
    TLibraryFinalizer(Pointer(Entries[Index]))();
    Inc(Index);
  end;
  FreeMem(Entries);
end;

{ The finalizers of a newer library run before the older ones. }
procedure AddLateFinalizers(Entries: PQWord; Count: PtrUInt);
var
  Joined: PQWord;
begin
  if Count = 0 then
    Exit;
  Joined := PQWord(GetMem((Count + LateFinalizerCount) * SizeOf(QWord)));
  Move(Entries^, Joined^, Count * SizeOf(QWord));
  if LateFinalizerCount > 0 then
    Move(LateFinalizers^, Joined[Count], LateFinalizerCount * SizeOf(QWord));
  FreeMem(LateFinalizers);
  LateFinalizers := Joined;
  LateFinalizerCount := LateFinalizerCount + Count;
  if not LateFinalizersHooked then
  begin
    LateFinalizersHooked := True;
    AddExitProc(@RunLateFinalizers);
  end;
end;

{ Takes the initializers and finalizers that loading Handle brought in
  from the kernel, calls the initializers and keeps the finalizers. }
procedure RunLibraryInitializers(Handle: TLibHandle);
var
  Request: TAbiModuleInitializers;
  LocalInitializers: array[0..InitializerBatch - 1] of QWord;
  LocalFinalizers: array[0..InitializerBatch - 1] of QWord;
  Initializers: PQWord;
  Finalizers: PQWord;
  CallResult: Int64;
  Index: QWord;
begin
  Initializers := @LocalInitializers[0];
  Finalizers := @LocalFinalizers[0];
  FillChar(Request, SizeOf(Request), 0);
  Request.Initializers := QWord(Initializers);
  Request.InitializerCapacity := InitializerBatch;
  Request.Finalizers := QWord(Finalizers);
  Request.FinalizerCapacity := InitializerBatch;
  CallResult := SystemCall(CallTakeModuleInitializers, QWord(Handle), QWord(@Request), 0, 0, 0, 0);
  if CallResult = -ErrorMessageTooLong then
  begin
    { The counts came back: room for all of them. }
    Initializers := PQWord(GetMem((Request.InitializerCount + 1) * SizeOf(QWord)));
    Finalizers := PQWord(GetMem((Request.FinalizerCount + 1) * SizeOf(QWord)));
    Request.Initializers := QWord(Initializers);
    Request.InitializerCapacity := Request.InitializerCount;
    Request.Finalizers := QWord(Finalizers);
    Request.FinalizerCapacity := Request.FinalizerCount;
    CallResult := SystemCall(CallTakeModuleInitializers, QWord(Handle), QWord(@Request), 0, 0, 0, 0);
  end;
  if CallResult >= 0 then
  begin
    AddLateFinalizers(Finalizers, Request.FinalizerCount);
    Index := 0;
    while Index < Request.InitializerCount do
    begin
      TLibraryInitializer(Pointer(Initializers[Index]))(argc, argv, envp);
      Inc(Index);
    end;
  end;
  if Initializers <> @LocalInitializers[0] then
  begin
    FreeMem(Initializers);
    FreeMem(Finalizers);
  end;
end;

function SysLoadLibraryHandle(Name: PChar): Int64;
var
  CallResult: Int64;
begin
  AcquireLibraryLock;
  CallResult := SystemCall(CallLoadLibrary, QWord(Name), 0, 0, 0, 0, 0);
  if CallResult >= 0 then
    RunLibraryInitializers(TLibHandle(CallResult));
  ReleaseLibraryLock;
  SysLoadLibraryHandle := CallResult;
end;

function SysLoadLibraryA(const Name: RawByteString): TLibHandle;
var
  CallResult: Int64;
begin
  CallResult := SysLoadLibraryHandle(PChar(Name));
  if CallResult < 0 then
  begin
    LastLoadError := LongInt(-CallResult);
    SysLoadLibraryA := NilHandle;
  end
  else
  begin
    LastLoadError := 0;
    SysLoadLibraryA := TLibHandle(CallResult);
  end;
end;

function SysLoadLibraryU(const Name: UnicodeString): TLibHandle;
begin
  SysLoadLibraryU := SysLoadLibraryA(ToSingleByteFileSystemEncodedFileName(Name));
end;

function SysGetProcAddress(Lib: TLibHandle; const ProcName: AnsiString): Pointer;
var
  CallResult: Int64;
begin
  CallResult := SystemCall(CallFindSymbol, QWord(Lib), QWord(PChar(ProcName)), 0, 0, 0, 0);
  if CallResult <= 0 then
    SysGetProcAddress := nil
  else
    SysGetProcAddress := Pointer(CallResult);
end;

function SysGetProcAddressOrdinal(Lib: TLibHandle; Ordinal: TOrdinalEntry): Pointer;
begin
  SysGetProcAddressOrdinal := nil;
end;

function SysUnloadLibrary(Lib: TLibHandle): Boolean;
begin
  SysUnloadLibrary := Lib <> NilHandle;
end;

function SysGetLoadErrorStr: String;
begin
  if LastLoadError = 0 then
    SysGetLoadErrorStr := ''
  else
  begin
    Str(LastLoadError, SysGetLoadErrorStr);
    SysGetLoadErrorStr := 'error ' + SysGetLoadErrorStr;
  end;
end;

const
  SystemDynLibsManager: TDynLibsManager = (
    LoadLibraryU: @SysLoadLibraryU;
    LoadLibraryA: @SysLoadLibraryA;
    GetProcAddress: @SysGetProcAddress;
    GetProcAddressOrdinal: @SysGetProcAddressOrdinal;
    UnloadLibrary: @SysUnloadLibrary;
    GetLoadErrorStr: @SysGetLoadErrorStr;
  );

procedure InitSystemDynLibs;
begin
  SetDynLibsManager(SystemDynLibsManager);
end;
