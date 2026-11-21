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
  Handles a program passes to a program it starts (CallCreateProcess
  with ProcessPassHandles), beyond the three standard ones.

  The caller names its handles; each is looked up (and its object
  referenced, so it stays while the new process is set up) before the
  process is made, then stored in the new process's table under the
  same number. Thread handles are not passed: they stand for threads of
  the caller.
}
unit Processes.HandlePassing;

{$mode objfpc}

interface

uses
  Processes.Process,
  Processes.Handles;

type
  TPassedHandle = record
    Handle: LongWord;
    Kind: THandleKind;
    ObjectBody: Pointer;
  end;
  PPassedHandle = ^TPassedHandle;

  TPassedHandles = record
    Items: PPassedHandle;
    Count: LongWord;
  end;

{ Copies Count handle numbers from UserAddress and looks each up in
  Caller's table, referencing its object. On failure nothing is held. }
function CollectPassedHandles(Caller: PProcess; UserAddress: QWord; Count: QWord;
  out Passed: TPassedHandles): LongInt;
{ Stores the handles in Process's table under their numbers. }
function InstallPassedHandles(Process: PProcess; const Passed: TPassedHandles): LongInt;
{ Drops what CollectPassedHandles took (the new process holds its own
  references by then). }
procedure ReleasePassedHandles(var Passed: TPassedHandles);

implementation

uses
  Abi.SystemCalls,
  Memory.KernelHeap,
  Kernel.Mutex,
  Objects.Manager,
  Processes.UserAccess;

procedure ReleasePassedHandles(var Passed: TPassedHandles);
var
  Index: LongWord;
begin
  Index := 0;
  while Index < Passed.Count do
  begin
    DereferenceObject(Passed.Items[Index].ObjectBody);
    Inc(Index);
  end;
  FreeKernelMemory(Passed.Items);
  Passed.Items := nil;
  Passed.Count := 0;
end;

{ Looks up the numbers in Numbers (Passed.Count of them) under the
  caller's lock, counting in Passed.Count only those referenced. }
function LookUpPassedHandles(Caller: PProcess; Numbers: PInt64; Count: LongWord;
  var Passed: TPassedHandles): LongInt;
var
  Index: LongWord;
  Item: PPassedHandle;
begin
  Result := ErrorNone;
  Passed.Count := 0;
  AcquireMutex(Caller^.Lock);
  Index := 0;
  while Index < Count do
  begin
    Item := @Passed.Items[Index];
    if not LookupHandle(Caller^.Handles, Numbers[Index], Item^.Kind, Item^.ObjectBody) then
    begin
      Result := ErrorBadHandle;
      Break;
    end;
    if Item^.Kind = Processes.Handles.HandleKindThread then
    begin
      Result := ErrorInvalidArgument;
      Break;
    end;
    Item^.Handle := LongWord(Numbers[Index]);
    ReferenceObject(Item^.ObjectBody);
    Inc(Passed.Count);
    Inc(Index);
  end;
  ReleaseMutex(Caller^.Lock);
end;

function CollectPassedHandles(Caller: PProcess; UserAddress: QWord; Count: QWord;
  out Passed: TPassedHandles): LongInt;
var
  Numbers: PInt64;
begin
  Passed.Items := nil;
  Passed.Count := 0;
  if Count = 0 then
    Exit(ErrorNone);
  if Count > HandleLimitCeiling then
    Exit(ErrorInvalidArgument);
  Numbers := PInt64(AllocateKernelMemory(Count * SizeOf(Int64)));
  Passed.Items := PPassedHandle(AllocateZeroedKernelMemory(Count * SizeOf(TPassedHandle)));
  if (Numbers = nil) or (Passed.Items = nil) then
    Result := ErrorOutOfMemory
  else
    Result := CopyFromUser(Numbers, UserAddress, Count * SizeOf(Int64));
  if Result = ErrorNone then
    Result := LookUpPassedHandles(Caller, Numbers, LongWord(Count), Passed);
  FreeKernelMemory(Numbers);
  if Result <> ErrorNone then
    ReleasePassedHandles(Passed);
end;

function InstallPassedHandles(Process: PProcess; const Passed: TPassedHandles): LongInt;
var
  Index: LongWord;
  Item: PPassedHandle;
begin
  Result := ErrorNone;
  AcquireMutex(Process^.Lock);
  Index := 0;
  while Index < Passed.Count do
  begin
    Item := @Passed.Items[Index];
    if not SetHandle(Process^.Handles, Integer(Item^.Handle), Item^.Kind, Item^.ObjectBody) then
    begin
      Result := ErrorTooManyHandles;
      Break;
    end;
    Inc(Index);
  end;
  ReleaseMutex(Process^.Lock);
end;

end.
