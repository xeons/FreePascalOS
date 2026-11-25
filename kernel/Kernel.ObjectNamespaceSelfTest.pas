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
  Self tests of the object namespace and the mutex events, run once
  during startup after the synchronization ones:

    * the namespace: the kernel's directories, objects named and found
      by path, a name taken, a name going with its object and when
      removed, nested directories (not removed while not empty), paths
      of objects, listing, bad paths; and as a checked caller (a user
      with id 1000): search permission on the way, write permission to
      name, the sticky bit, a kernel directory not removable, chmod and
      chown rules;
    * mutex events: ownership, recursion, another thread kept waiting,
      release only by the owner, a waiter handed the mutex on release,
      a wait for all with an event, and abandonment told once.
}
unit Kernel.ObjectNamespaceSelfTest;

{$mode objfpc}

interface

procedure RunObjectNamespaceSelfTests;

implementation

uses
  Abi.SystemCalls,
  Runtime.Text,
  Kernel.Threads,
  Kernel.Scheduler,
  Kernel.Events,
  Kernel.MutexEvents,
  Kernel.SelfTest,
  Objects.Manager,
  Objects.Namespace,
  Processes.Thread;

const
  TestUser = 1000;
  WorkerWaitMilliseconds = 30000;

var
  ThingType: TObjectType;
  ThingTypeRegistered: Boolean = False;

{ --- The namespace --------------------------------------------------------- }

{ A user with id TestUser in no group but its own (1000). }
function TestUserMayAccess(Credentials: Pointer; OwnerId, GroupId, Mode, Access: LongWord): Boolean;
var
  Granted: LongWord;
begin
  if OwnerId = TestUser then
    Granted := (Mode shr 6) and 7
  else if GroupId = TestUser then
    Granted := (Mode shr 3) and 7
  else
    Granted := Mode and 7;
  Result := (Access and not Granted) = 0;
end;

function TestUserInGroup(Credentials: Pointer; GroupId: LongWord): Boolean;
begin
  Result := GroupId = TestUser;
end;

procedure MakeTestUserCaller(out Caller: TNamespaceCaller);
begin
  Caller.Checked := True;
  Caller.UserId := TestUser;
  Caller.Credentials := nil;
  Caller.MayAccess := @TestUserMayAccess;
  Caller.IsInGroup := @TestUserInGroup;
end;

function RootMayAccess(Credentials: Pointer; OwnerId, GroupId, Mode, Access: LongWord): Boolean;
begin
  Result := True;
end;

{ Root as a program: checked (and passing every check), so the
  directories it makes may be removed, unlike the kernel's own. }
procedure MakeRootCaller(out Caller: TNamespaceCaller);
begin
  Caller.Checked := True;
  Caller.UserId := 0;
  Caller.Credentials := nil;
  Caller.MayAccess := @RootMayAccess;
  Caller.IsInGroup := @TestUserInGroup;
end;

function NewThing(Path: PChar): Pointer;
begin
  Result := CreateObject(ThingType, Path);
end;

function EntryCountOf(Path: PChar): LongWord;
var
  Entries: array[0..0] of TAbiObjectDirectoryEntry;
  Filled: LongWord;
begin
  if ListObjectDirectory(Path, 0, @Entries[0], 0, Result, Filled, KernelNamespaceCaller) <> ErrorNone then
    Result := High(LongWord);
end;

procedure TestKernelNames;
var
  Root: TNamespaceCaller;
  First: Pointer;
  Found: Pointer;
  PathText: array[0..MaximumObjectPathLength - 1] of Char;
  Entries: array[0..7] of TAbiObjectDirectoryEntry;
  Total: LongWord;
  Filled: LongWord;
begin
  Check(LookupObjectPath('\Kernel\Console', nil, KernelNamespaceCaller, 0, Found) = ErrorNone,
    'namespace: the console is \Kernel\Console');
  DereferenceObject(Found);
  MakeRootCaller(Root);
  Check(CreateObjectDirectory('\Kernel\SelfTest', 0, 0, $1ED, Root) = ErrorNone,
    'namespace: a directory');
  First := NewThing('\Kernel\SelfTest\first');
  Check(First <> nil, 'namespace: a named object');
  Check(NewThing('\Kernel\SelfTest\first') = nil, 'namespace: a name taken');
  Check(LookupObjectByName('\Kernel\SelfTest\first', @ThingType) = First, 'namespace: found by path');
  DereferenceObject(First);
  Check(LookupObjectByName('\Kernel\SelfTest\first', @ThingType) <> nil, 'namespace: found again');
  DereferenceObject(First);
  Check(GetObjectPath(First, @PathText[0], SizeOf(PathText)) and
    TextIsEqual(@PathText[0], '\Kernel\SelfTest\first'), 'namespace: the path of an object');
  Check(ListObjectDirectory('\Kernel\SelfTest', 0, @Entries[0], 8, Total, Filled, KernelNamespaceCaller) = ErrorNone,
    'namespace: listed');
  Check((Total = 1) and (Filled = 1) and TextIsEqual(@Entries[0].Name[0], 'first') and
    TextIsEqual(@Entries[0].TypeName[0], 'SelfTestThing'), 'namespace: the entry listed');
  Check(RemoveObjectName('\Kernel\SelfTest', KernelNamespaceCaller) = ErrorDirectoryNotEmpty,
    'namespace: a directory that is not empty stays');
  DereferenceObject(First);
  Check(LookupObjectByName('\Kernel\SelfTest\first', nil) = nil, 'namespace: the name goes with its object');
  Check(EntryCountOf('\Kernel\SelfTest') = 0, 'namespace: the directory is empty again');

  First := NewThing('\Kernel\SelfTest\removed');
  Check(RemoveObjectName('\Kernel\SelfTest\removed', KernelNamespaceCaller) = ErrorNone, 'namespace: a name removed');
  Check(LookupObjectByName('\Kernel\SelfTest\removed', nil) = nil, 'namespace: not found once removed');
  Check(not GetObjectPath(First, @PathText[0], SizeOf(PathText)), 'namespace: an object without a name has no path');
  DereferenceObject(First);

  Check(LookupObjectPath('Kernel', nil, KernelNamespaceCaller, 0, Found) = ErrorInvalidArgument,
    'namespace: a relative path');
  Check(LookupObjectPath('\Kernel\', nil, KernelNamespaceCaller, 0, Found) = ErrorInvalidArgument,
    'namespace: a trailing backslash');
  Check(LookupObjectPath('\Kernel\Console\x', nil, KernelNamespaceCaller, 0, Found) = ErrorNotDirectory,
    'namespace: through an object');
  Check(RemoveObjectName('\Kernel', KernelNamespaceCaller) = ErrorNotPermitted,
    'namespace: the kernel''s directories stay');
end;

procedure TestCheckedCaller;
var
  Root: TNamespaceCaller;
  Caller: TNamespaceCaller;
  Mine: Pointer;
  Found: Pointer;
  RootsThing: Pointer;
begin
  MakeTestUserCaller(Caller);
  MakeRootCaller(Root);
  CreateObjectDirectory('\Kernel\SelfTest\closed', 0, 0, $1C0, Root);
  RootsThing := CreateObject(ThingType, nil);
  Check(InsertObjectName(RootsThing, '\Shared\selftest-root', 0, 0, $1A4, KernelNamespaceCaller) = ErrorNone,
    'namespace: root names in \Shared');
  Check(LookupObjectPath('\Kernel\SelfTest\closed', nil, Caller, 0, Found) = ErrorNone,
    'namespace: the user reaches a closed directory');
  DereferenceObject(Found);
  Mine := CreateObject(ThingType, nil);
  Check(InsertObjectName(Mine, '\Kernel\SelfTest\closed\mine', TestUser, TestUser, $180, Caller) = ErrorAccessDenied,
    'namespace: but cannot search it');
  Check(InsertObjectName(Mine, '\Kernel\SelfTest\mine', TestUser, TestUser, $180, Caller) = ErrorAccessDenied,
    'namespace: nor name in a directory it may not write');
  Check(InsertObjectName(Mine, '\Shared\selftest-mine', TestUser, TestUser, $180, Caller) = ErrorNone,
    'namespace: names in \Shared');
  Check(LookupObjectPath('\Shared\selftest-root', nil, Caller, NameAccessRead or NameAccessWrite, Found) =
    ErrorAccessDenied, 'namespace: root''s object not opened for writing');
  Check(LookupObjectPath('\Shared\selftest-mine', nil, Caller, NameAccessRead or NameAccessWrite, Found) =
    ErrorNone, 'namespace: its own opened');
  DereferenceObject(Found);
  Check(RemoveObjectName('\Shared\selftest-root', Caller) = ErrorAccessDenied,
    'namespace: the sticky bit keeps root''s name');
  Check(ChangeObjectSecurity('\Shared\selftest-root', $1FF, KeepSecurityField, KeepSecurityField, Caller) =
    ErrorNotPermitted, 'namespace: not another''s mode');
  Check(ChangeObjectSecurity('\Shared\selftest-mine', $1B6, KeepSecurityField, TestUser, Caller) = ErrorNone,
    'namespace: its own mode and group');
  Check(ChangeObjectSecurity('\Shared\selftest-mine', KeepSecurityField, 0, KeepSecurityField, Caller) =
    ErrorNotPermitted, 'namespace: not given away');
  Check(ChangeObjectSecurity('\Shared\selftest-mine', KeepSecurityField, KeepSecurityField, 5, Caller) =
    ErrorNotPermitted, 'namespace: not to a group it is not in');
  Check(CreateObjectDirectory('\Shared\selftest-dir', TestUser, TestUser, $1ED, Caller) = ErrorNone,
    'namespace: a directory of its own');
  Check(RemoveObjectName('\Shared\selftest-dir', Caller) = ErrorNone, 'namespace: removed by it');
  Check(RemoveObjectName('\Shared', Caller) = ErrorAccessDenied, 'namespace: not \Shared');
  Check(RemoveObjectName('\Shared\selftest-mine', Caller) = ErrorNone, 'namespace: its own name removed');
  DereferenceObject(Mine);
  DereferenceObject(RootsThing);
  Check(LookupObjectByName('\Shared\selftest-root', nil) = nil, 'namespace: root''s name went with it');
  Check(RemoveObjectName('\Kernel\SelfTest\closed', Root) = ErrorNone, 'namespace: cleaned up');
  Check(RemoveObjectName('\Kernel\SelfTest', Root) = ErrorNone, 'namespace: all of it');
end;

{ --- Mutex events ------------------------------------------------------------ }

var
  TestMutex: TEvent;
  HelperDone: TEvent;
  HelperResult: TWaitResult;

procedure TryTakeMain(Context: Pointer);
begin
  HelperResult := WaitForEventWithOptions(TestMutex, QWord(Context), False);
  SignalEvent(HelperDone);
end;

{ Takes the mutex and ends holding it, as an ending user thread does. }
procedure TakeAndAbandonMain(Context: Pointer);
begin
  HelperResult := WaitForEventWithOptions(TestMutex, WorkerWaitMilliseconds, False);
  AbandonOwnedMutexEvents(CurrentThread);
  SignalEvent(HelperDone);
end;

procedure RunHelper(Routine: TThreadStartRoutine; Context: Pointer);
begin
  ResetEvent(HelperDone);
  Check(CreateSystemThread(Routine, Context, DefaultThreadPriority, 'MutexTest', False) <> nil,
    'mutex events: a helper thread');
  Check(WaitForEventWithOptions(HelperDone, WorkerWaitMilliseconds, False) = WaitSignaled,
    'mutex events: the helper finished');
end;

procedure TestMutexEvents;
var
  Holds: LongInt;
  Other: TEvent;
  Pair: array[0..1] of PEvent;
begin
  InitializeMutexEvent(TestMutex);
  InitializeEvent(HelperDone, EventKindNotification, False);
  Check(WaitForEventWithOptions(TestMutex, 0, False) = WaitSignaled, 'mutex events: taken when free');
  Check(MutexEventOwner(TestMutex) = CurrentThread, 'mutex events: owned');
  Check(WaitForEventWithOptions(TestMutex, 0, False) = WaitSignaled, 'mutex events: taken again by its owner');
  Check(MutexEventHolds(TestMutex) = 2, 'mutex events: two holds');
  RunHelper(@TryTakeMain, Pointer(PtrUInt(20)));
  Check(HelperResult = WaitTimedOut, 'mutex events: another thread waits');
  Check(ReleaseMutexEvent(TestMutex, Holds) and (Holds = 1), 'mutex events: one hold released');
  Check(ReleaseMutexEvent(TestMutex, Holds) and (Holds = 0), 'mutex events: free');
  Check(not ReleaseMutexEvent(TestMutex, Holds), 'mutex events: not released by a thread that does not own it');

  RunHelper(@TakeAndAbandonMain, nil);
  Check(HelperResult = WaitSignaled, 'mutex events: the helper took it');
  Check((MutexEventOwner(TestMutex) = nil) and EventIsSignaled(TestMutex), 'mutex events: freed as it ended');
  Check(WaitForEventWithOptions(TestMutex, 0, False) = WaitSignaled, 'mutex events: taken after abandonment');
  Check(TakeAbandonedMark(TestMutex), 'mutex events: told it was abandoned');
  Check(not TakeAbandonedMark(TestMutex), 'mutex events: told once');
  ReleaseMutexEvent(TestMutex, Holds);

  InitializeEvent(Other, EventKindNotification, False);
  Pair[0] := @TestMutex;
  Pair[1] := @Other;
  Check(WaitForAllEvents(@Pair[0], 2, 0, False) = WaitTimedOut, 'mutex events: a wait for all waits for the event');
  Check(MutexEventOwner(TestMutex) = nil, 'mutex events: and took nothing');
  SignalEvent(Other);
  Check(WaitForAllEvents(@Pair[0], 2, 0, False) = WaitSignaled, 'mutex events: then takes both');
  Check(MutexEventOwner(TestMutex) = CurrentThread, 'mutex events: owned after the wait for all');
  ReleaseMutexEvent(TestMutex, Holds);
  DiscardMutexEvent(TestMutex);
end;

procedure RunObjectNamespaceSelfTests;
begin
  if not ThingTypeRegistered then
  begin
    RegisterObjectType(ThingType, 'SelfTestThing', 16, nil);
    ThingTypeRegistered := True;
  end;
  TestKernelNames;
  TestCheckedCaller;
  ReportPassed('object namespace');
  TestMutexEvents;
  ReportPassed('mutex events');
end;

end.
