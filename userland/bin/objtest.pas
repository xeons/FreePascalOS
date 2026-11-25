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
  objtest - checks the object namespace, named objects and mutexes

  objtest              the checks (as root)
  objtest --user       the checks an ordinary user makes against what
                       root named (started by objtest through su)
  objtest --abandon P  opens the mutex named P, takes it and ends
                       without releasing it
  objtest --secure     prints "secure N": the AT_SECURE value it was
                       started with (a program its user cannot read
                       runs with 1)

  Checked: the kernel's directories and what is in them; events,
  semaphores, mutexes and sections created or opened by name (the
  second program gets the first one's object), the kind asked for, a
  name taken, a name going with the last handle or when removed, the
  object living on without it; directories (nested names, not empty,
  the kernel's not removable, a path through something that is not a
  directory, bad paths); listing (types, kinds, owners, modes); chmod
  and chown of a name; ports listed but not opened; mutexes (recursion,
  release by a thread that does not own it, a wait for all with an
  event, abandoned by a thread and by another process); and an ordinary
  user kept out by the modes (a private object, a closed directory, the
  sticky \Shared, \Kernel), while making names of its own.

  Each check prints a line; the last line is "objtest: N checks, M
  failed" and the exit status is 1 if any failed.
}
program ObjTest;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Objects,
  Sys.NamedObjects,
  Sys.Processes,
  Sys.Threads;

const
  ProgramPath: PChar = '/bin/objtest';
  ChildTimeout = 10000;
  AtSecure = 23;

var
  Checks: Integer = 0;
  Failures: Integer = 0;
  Prefix: string = 'objtest';

procedure Check(Passed: Boolean; const Name: string);
begin
  Inc(Checks);
  if Passed then
    WriteLn(Prefix, ': pass: ', Name)
  else
  begin
    Inc(Failures);
    WriteLn(Prefix, ': FAIL: ', Name);
  end;
end;

function FindEntry(const Entries: TObjectEntryArray; const Name: string; out Entry: TObjectEntry): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Entries) do
    if Entries[Index].Name = Name then
    begin
      Entry := Entries[Index];
      Exit(True);
    end;
  Result := False;
end;

function Listed(const Path, Name: string; out Entry: TObjectEntry): Boolean;
var
  Entries: TObjectEntryArray;
begin
  Result := (ListObjectDirectory(Path, Entries) = ErrorNone) and FindEntry(Entries, Name, Entry);
end;

function IsListed(const Path, Name: string): Boolean;
var
  Entry: TObjectEntry;
begin
  Result := Listed(Path, Name, Entry);
end;

{ Starts this program with Arguments (through su as the user if AsUser)
  and returns its exit status, -1 if it could not run. }
function RunSelf(const Arguments: string; AsUser: Boolean): LongInt;
var
  Values: array[0..4] of PChar;
  Line: string;
  Options: TProcessOptions;
  Process: Int64;
begin
  Line := string(ProgramPath) + ' ' + Arguments;
  if AsUser then
  begin
    Values[0] := '/bin/su';
    Values[1] := 'user';
    Values[2] := '-c';
    Values[3] := PChar(Line);
    Values[4] := nil;
  end
  else
  begin
    Values[0] := '/bin/sh';
    Values[1] := '-c';
    Values[2] := PChar(Line);
    Values[3] := nil;
  end;
  DefaultProcessOptions(Options);
  Process := StartProgram(Values[0], @Values[0], Options);
  if Process < 0 then
    Exit(-1);
  if WaitForProgramWithTimeout(Process, ChildTimeout, Result) <> ErrorNone then
    Result := -1;
  CloseHandle(Process);
end;

{ --- The namespace ------------------------------------------------------- }

procedure TestKernelDirectories;
var
  Entry: TObjectEntry;
begin
  Check(Listed('\', 'Shared', Entry) and Entry.IsDirectory and ((Entry.Mode and ObjectModeSticky) <> 0) and
    ((Entry.Mode and $1FF) = $1FF), '\Shared is a sticky directory anyone may write');
  Check(IsListed('\', 'Device') and IsListed('\', 'Storage') and IsListed('\', 'Kernel') and IsListed('\', 'Ports'),
    'the kernel''s directories');
  Check(Listed('\Kernel', 'Console', Entry) and (Entry.TypeName = 'Console') and IsListed('\Kernel', 'System'),
    'the console and the system process in \Kernel');
  Check(Listed('\Device', 'null', Entry) and (Entry.TypeName = 'Device') and (Entry.Kind = 0),
    'the devices of /dev in \Device');
  Check(OpenNamedObject('\Device\null') = -ErrorUnsupported, 'a device is not opened by name');
  Check(OpenNamedObject('\Kernel') = -ErrorUnsupported, 'nor a directory');
  Check(RemoveObjectName('\Shared') = ErrorNotPermitted, 'a kernel directory stays, even for root');
  Check(OpenNamedObject('\Shared\no-such-thing') = -ErrorNotFound, 'a name nobody has');
  Check(OpenNamedObject('\Kernel\Console\below') = -ErrorNotDirectory, 'a path through an object');
  Check((OpenNamedObject('Shared\x') = -ErrorInvalidArgument) and (OpenNamedObject('\Shared\\x') = -ErrorInvalidArgument)
    and (OpenNamedObject('\Shared\') = -ErrorInvalidArgument), 'paths that are not paths');
  Check(OpenNamedObject('\Shared\' + StringOfChar('n', 80)) = -ErrorNameTooLong, 'a name too long');
end;

procedure TestNamedEvent;
var
  First: Int64;
  Second: Int64;
  Other: Int64;
  Created: Boolean;
  SecondCreated: Boolean;
  Entry: TObjectEntry;
begin
  First := CreateNamedEvent('\Shared\objtest-event', False, False, Created);
  Second := CreateNamedEvent('\Shared\objtest-event', False, False, SecondCreated);
  Check((First >= 0) and Created and (Second >= 0) and not SecondCreated, 'the second create opens the first event');
  SetEvent(First);
  Check(WaitForHandle(Second, 0) = ErrorNone, 'one event behind both names');
  Check(OpenNamedObject('\Shared\objtest-event', HandleKindSemaphore) = -ErrorInvalidArgument,
    'opened as another kind');
  Other := CreateEvent(False, False);
  Check(NameObject(Other, '\Shared\objtest-event') = ErrorExists, 'a name taken');
  Check(NameObject(First, '\Shared\objtest-again') = ErrorBusy, 'an object named already');
  CloseHandle(Other);
  Check(Listed('\Shared', 'objtest-event', Entry) and (Entry.TypeName = 'Event') and (Entry.Kind = HandleKindEvent)
    and (Entry.OwnerId = 0) and ((Entry.Mode and $1FF) = ($1B6 and not $12)),
    'listed with its type, kind, owner and mode (less the umask)');
  Check(SetObjectSecurity('\Shared\objtest-event', $180, KeepObjectSecurity, 7) = ErrorNone, 'chmod and chgrp');
  Check(Listed('\Shared', 'objtest-event', Entry) and (Entry.Mode = $180) and (Entry.GroupId = 7), 'as changed');
  CloseHandle(First);
  Other := OpenNamedObject('\Shared\objtest-event');
  Check(Other >= 0, 'the name stays while a handle is open');
  CloseHandle(Second);
  CloseHandle(Other);
  Check(not IsListed('\Shared', 'objtest-event'), 'and goes with the last');
end;

procedure TestNameLifetime;
var
  Event: Int64;
  Opened: Int64;
begin
  Event := CreateEvent(True, False);
  Check(NameObject(Event, '\Shared\objtest-short') = ErrorNone, 'an event named');
  CloseHandle(Event);
  Check(OpenNamedObject('\Shared\objtest-short') = -ErrorNotFound, 'its name goes with its last handle');
  Event := CreateEvent(True, False);
  NameObject(Event, '\Shared\objtest-removed');
  Opened := OpenNamedObject('\Shared\objtest-removed', HandleKindEvent);
  Check(RemoveObjectName('\Shared\objtest-removed') = ErrorNone, 'a name removed');
  Check(not IsListed('\Shared', 'objtest-removed'), 'no longer listed');
  SetEvent(Event);
  Check(WaitForHandle(Opened, 0) = ErrorNone, 'the object lives on without its name');
  Check(NameObject(Event, '\Shared\objtest-renamed') = ErrorNone, 'and may be named again');
  CloseHandle(Event);
  CloseHandle(Opened);
  Check(not IsListed('\Shared', 'objtest-renamed'), 'that name goes with it too');
end;

procedure TestNamedSemaphoreAndSection;
var
  First: Int64;
  Second: Int64;
  Created: Boolean;
  FirstView: PLongWord;
  SecondView: PLongWord;
  Previous: LongInt;
begin
  First := CreateNamedSemaphore('\Shared\objtest-semaphore', 0, 4, Created);
  Second := CreateNamedSemaphore('\Shared\objtest-semaphore', 0, 4, Created);
  Check((First >= 0) and (Second >= 0) and not Created, 'a semaphore by name');
  Check(ReleaseSemaphore(First, 2, Previous) = ErrorNone, 'released through one name');
  Check(GetSemaphoreCount(Second) = 2, 'counted through the other');
  CloseHandle(First);
  CloseHandle(Second);
  First := CreateNamedSection('\Shared\objtest-section', 4096, Created);
  Second := CreateNamedSection('\Shared\objtest-section', 4096, Created);
  FirstView := PLongWord(MapSection(First, 0, 4096));
  SecondView := PLongWord(MapSection(Second, 0, 4096));
  Check((FirstView <> nil) and (SecondView <> nil) and not Created, 'a section by name, mapped twice');
  if (FirstView <> nil) and (SecondView <> nil) then
  begin
    FirstView^ := $5EC7;
    Check(SecondView^ = $5EC7, 'the same memory');
    UnmapSection(FirstView);
    UnmapSection(SecondView);
  end;
  CloseHandle(First);
  CloseHandle(Second);
end;

procedure TestDirectories;
var
  Event: Int64;
  Entry: TObjectEntry;
begin
  Check(CreateObjectDirectory('\Shared\objtest-dir', $1ED) = ErrorNone, 'a directory made');
  Check(CreateObjectDirectory('\Shared\objtest-dir') = ErrorExists, 'not twice');
  Check(CreateObjectDirectory('\Shared\objtest-dir\inner\deeper') = ErrorNotFound, 'not below a missing one');
  Check(CreateObjectDirectory('\Shared\objtest-dir\inner') = ErrorNone, 'one inside it');
  Event := CreateEvent(False, False);
  Check(NameObject(Event, '\Shared\objtest-dir\inner\event') = ErrorNone, 'an event named deep down');
  Check(Listed('\Shared', 'objtest-dir', Entry) and Entry.IsDirectory and Entry.IsPermanent and
    (Entry.EntryCount = 1) and (ObjectModeText(Entry) = 'drwxr-xr-x'), 'listed as a directory');
  Check(RemoveObjectName('\Shared\objtest-dir') = ErrorDirectoryNotEmpty, 'not removed while not empty');
  Check(RemoveObjectName('\Shared\objtest-dir\inner\event') = ErrorNone, 'its event''s name removed');
  Check(RemoveObjectName('\Shared\objtest-dir\inner') = ErrorNone, 'then the inner directory');
  Check(RemoveObjectName('\Shared\objtest-dir') = ErrorNone, 'then the outer');
  Check(not IsListed('\Shared', 'objtest-dir'), 'gone');
  CloseHandle(Event);
end;

procedure TestPorts;
var
  Port: Int64;
  Entry: TObjectEntry;
begin
  Port := CreatePort('objtest');
  Check(Listed('\Ports', 'objtest', Entry) and (Entry.TypeName = 'Port') and (Entry.Kind = 0),
    'a port is \Ports\<name>');
  Check(OpenNamedObject('\Ports\objtest') = -ErrorUnsupported, 'connected to, not opened');
  CloseHandle(Port);
  Check(not IsListed('\Ports', 'objtest'), 'and gone with its handle');
  Check(CreatePort('back\slash') = -ErrorInvalidArgument, 'a port name with a backslash');
end;

{ --- Mutexes ------------------------------------------------------------- }

var
  SharedMutex: Int64;

function TryTakeMain(Argument: Pointer): LongInt;
begin
  Result := WaitForObject(SharedMutex, 50);
end;

function TakeAndEndMain(Argument: Pointer): LongInt;
begin
  Result := WaitForObject(SharedMutex, 1000);
end;

function ReleaseForeignMain(Argument: Pointer): LongInt;
var
  Holds: LongInt;
begin
  Result := ReleaseMutex(SharedMutex, Holds);
end;

function RunThread(Routine: TThreadRoutine): LongInt;
var
  Thread: Int64;
begin
  Thread := CreateThread(Routine, nil);
  if (Thread < 0) or (WaitForThread(Thread, ChildTimeout, Result) <> 0) then
    Result := -1;
  if Thread >= 0 then
    CloseThreadHandle(Thread);
end;

procedure TestMutexes;
var
  Holds: LongInt;
  Event: Int64;
  Named: Int64;
  Created: Boolean;
begin
  SharedMutex := CreateMutex(True);
  Check(SharedMutex >= 0, 'a mutex made, owned');
  Check(WaitForObject(SharedMutex, 0) = ErrorNone, 'its owner takes it again');
  Check(RunThread(@TryTakeMain) = ErrorTimedOut, 'another thread waits for it');
  Check(RunThread(@ReleaseForeignMain) = ErrorNotPermitted, 'and may not release it');
  Check((ReleaseMutex(SharedMutex, Holds) = ErrorNone) and (Holds = 1), 'one take released, one left');
  Check((ReleaseMutex(SharedMutex, Holds) = ErrorNone) and (Holds = 0), 'free');
  Check(ReleaseMutex(SharedMutex, Holds) = ErrorNotPermitted, 'nothing more to release');
  Check(RunThread(@TryTakeMain) = ErrorNone, 'a thread takes the free mutex');
  { That thread ended holding it. }
  Check(WaitForObject(SharedMutex, 1000) = MutexAbandoned, 'abandoned by a thread that ended');
  Check(WaitForObject(SharedMutex, 0) = ErrorNone, 'told only once');
  ReleaseMutex(SharedMutex, Holds);
  ReleaseMutex(SharedMutex, Holds);
  Event := CreateEvent(False, True);
  Check(WaitForAllHandles([SharedMutex, Event], 0) = ErrorNone, 'a wait for all with an event');
  Check(RunThread(@TryTakeMain) = ErrorTimedOut, 'took the mutex');
  ReleaseMutex(SharedMutex, Holds);
  CloseHandle(Event);
  CloseHandle(SharedMutex);

  Named := CreateNamedMutex('\Shared\objtest-mutex', Created);
  Check((Named >= 0) and Created, 'a named mutex');
  Check(RunSelf('--abandon \\Shared\\objtest-mutex', False) = 0, 'another program took it and ended');
  Check(WaitForObject(Named, 1000) = MutexAbandoned, 'abandoned by a program that ended');
  ReleaseMutex(Named, Holds);
  CloseHandle(Named);
end;

procedure AbandonNamedMutex(const Path: string);
var
  Mutex: Int64;
begin
  Mutex := OpenNamedObject(Path, HandleKindMutex);
  if (Mutex < 0) or (WaitForObject(Mutex, 1000) <> ErrorNone) then
    Halt(1);
  Halt(0);
end;

{ --- Permissions --------------------------------------------------------- }

procedure TestUserKeptOut;
var
  Private: Int64;
  Readable: Int64;
begin
  Private := CreateEvent(False, False);
  NameObject(Private, '\Shared\objtest-private', $180);
  Readable := CreateEvent(False, False);
  NameObject(Readable, '\Shared\objtest-public', $1B6);
  CreateObjectDirectory('\Shared\objtest-closed', $1C0);
  Check(RunSelf('--user', True) = 0, 'what an ordinary user may and may not do');
  RemoveObjectName('\Shared\objtest-closed');
  RemoveObjectName('\Shared\objtest-user');
  CloseHandle(Private);
  CloseHandle(Readable);
end;

procedure UserChecks;
var
  Event: Int64;
  Entries: TObjectEntryArray;
  Entry: TObjectEntry;
begin
  Prefix := 'objtest --user';
  Check(OpenNamedObject('\Shared\objtest-private') = -ErrorAccessDenied, 'root''s private event');
  Event := OpenNamedObject('\Shared\objtest-public');
  Check(Event >= 0, 'an event anyone may open');
  CloseHandle(Event);
  Check(ListObjectDirectory('\Shared\objtest-closed', Entries) = ErrorAccessDenied, 'a closed directory not listed');
  Event := CreateEvent(False, False);
  Check(NameObject(Event, '\Shared\objtest-closed\mine') = ErrorAccessDenied, 'nor named in');
  Check(NameObject(Event, '\Kernel\mine') = ErrorAccessDenied, 'nothing named in \Kernel');
  Check(RemoveObjectName('\Shared\objtest-public') = ErrorAccessDenied, 'another''s name in the sticky \Shared stays');
  Check(SetObjectSecurity('\Shared\objtest-public', $1FF, KeepObjectSecurity, KeepObjectSecurity) = ErrorNotPermitted,
    'another''s mode not changed');
  Check(CreateObjectDirectory('\Shared\objtest-user', $1ED) = ErrorNone, 'a directory of its own');
  Check(Listed('\Shared', 'objtest-user', Entry) and (Entry.OwnerId <> 0), 'owned by the user');
  Check(SetObjectSecurity('\Shared\objtest-user', $1FF, 0, KeepObjectSecurity) = ErrorNotPermitted,
    'not given away');
  Check(NameObject(Event, '\Shared\objtest-user\mine') = ErrorNone, 'its own object named in it');
  CloseHandle(Event);
end;

{ --- AT_SECURE ----------------------------------------------------------- }

function AuxiliaryValue(Key: QWord): Int64;
var
  Position: PPChar;
  Entry: PQWord;
begin
  Position := envp;
  while Position^ <> nil do
    Inc(Position);
  Entry := PQWord(Position + 1);
  while Entry[0] <> 0 do
  begin
    if Entry[0] = Key then
      Exit(Int64(Entry[1]));
    Inc(Entry, 2);
  end;
  Result := -1;
end;

begin
  if ParamStr(1) = '--secure' then
  begin
    WriteLn('secure ', AuxiliaryValue(AtSecure));
    Halt(0);
  end;
  if ParamStr(1) = '--abandon' then
    AbandonNamedMutex(ParamStr(2));
  if ParamStr(1) = '--user' then
    UserChecks
  else
  begin
    TestKernelDirectories;
    TestNamedEvent;
    TestNameLifetime;
    TestNamedSemaphoreAndSection;
    TestDirectories;
    TestPorts;
    TestMutexes;
    TestUserKeptOut;
  end;
  WriteLn(Prefix, ': ', Checks, ' checks, ', Failures, ' failed');
  if Failures > 0 then
    Halt(1);
end.
