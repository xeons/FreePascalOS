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
  Process objects.

  A process is a container for threads, an address space, a handle table
  and a current directory. The system process owns every kernel thread
  and has no user address space; every other process runs a user program
  (see Processes.UserProcess).

  A process object outlives the program it ran: after the program exits,
  the object keeps its exit code until the last handle to it is closed.
}
unit Processes.Process;

{$mode objfpc}

interface

uses
  Runtime.LinkedList,
  Kernel.SpinLock,
  Kernel.Mutex,
  Kernel.Events,
  Kernel.ProcessorTime,
  Objects.Manager,
  Processes.AddressSpace,
  Processes.Handles,
  Processes.NotificationQueue;

const
  ProcessNameLength = 32;
  ProcessPathCapacity = 1024;
  { The arguments it was started with, joined by spaces (cut short). }
  ProcessCommandLineCapacity = 256;

const
  MaximumProcessGroups = 32;
  RootUserId = 0;
  DefaultUmask = $12; { ----w--w- : files rw-r--r--, directories rwxr-xr-x }

type
  { Who a process acts as (see Processes.Security). }
  TProcessCredentials = record
    RealUserId: LongWord;
    EffectiveUserId: LongWord;
    SavedUserId: LongWord;
    RealGroupId: LongWord;
    EffectiveGroupId: LongWord;
    SavedGroupId: LongWord;
    Groups: array[0..MaximumProcessGroups - 1] of LongWord;
    GroupCount: LongWord;
    { Permission bits removed from new files and directories. }
    Umask: LongWord;
    { -20 .. 19; lower runs at a higher thread priority. }
    Nice: LongInt;
    { The processors the process's threads may run on (bit N: the
      processor with index N), inherited like the rest. }
    AffinityMask: QWord;
  end;

  PProcess = ^TProcess;
  TProcess = record
    ProcessId: QWord;
    ParentProcessId: QWord;
    Name: array[0..ProcessNameLength - 1] of Char;
    IsUserProcess: Boolean;

    PageTableRoot: QWord;
    AddressSpace: PAddressSpace;

    ThreadListLock: TSpinLock;
    Threads: TListEntry;
    ThreadCount: LongWord;
    { User threads that have not exited yet; the one that brings this to
      zero ends the process (see Processes.UserThread). }
    ActiveUserThreads: Int64;

    { Protects the handle table, current directory and module list. }
    Lock: TMutex;
    Handles: THandleTable;
    { As the program sees it, for example "/home/user". }
    CurrentDirectory: array[0..ProcessPathCapacity - 1] of Char;
    { Loaded program and libraries, owned by Processes.ImageLoader. }
    Modules: Pointer;

    { The directory the program sees as "/": an absolute path as seen
      from the real root, normally "/" itself (see chroot). }
    RootDirectory: array[0..ProcessPathCapacity - 1] of Char;

    ExitCode: LongInt;
    HasExited: Boolean;
    ExitEvent: TEvent;

    { Set when another program asked for this one to end (see
      Processes.Termination). }
    TerminationRequested: Boolean;
    TerminationCode: LongInt;
    { When it was (UptimeMilliseconds), and whether the hang watch has
      reported it as overdue (Processes.HangWatch). }
    TerminationRequestedAt: QWord;
    OverdueEndingReported: Boolean;

    { Processes started together (a shell pipeline) share a group, which
      the console's Ctrl-C ends as a whole. }
    GroupId: QWord;
    { The session: the processes started from one service or one logon,
      ended together (CallTerminateSession). Its id is the id of the
      process that leads it. }
    SessionId: QWord;
    { Ctrl-C does not end this process, nor Ctrl-Z stop it (an
      interactive shell). }
    IgnoresInterrupt: Boolean;
    { The terminal device (a PDeviceObject) the process runs on: what
      /dev/tty opens, whose foreground group may read it, and whose
      hang-up ends it (Processes.TerminalCalls). nil for none. }
    ControllingTerminal: Pointer;

    { --- Stopping and continuing (Processes.Stopping) --- }
    { Protects the fields below. }
    StopLock: TSpinLock;
    { Asked to stop: each user thread waits at its next safe point. }
    StopRequested: Boolean;
    { Where threads continue after a processor exception
      (Processes.UserExceptions); 0 for none. }
    ExceptionDispatcher: QWord;
    { Threads waiting to be continued. }
    StoppedThreads: Int64;
    { Every active user thread is waiting: the process has stopped. }
    IsStopped: Boolean;
    { A WaitForProcessChange caller has been told about this stop. }
    StopReported: Boolean;
    { Signaled while the process may run; reset when it is asked to stop. }
    ContinueEvent: TEvent;
    { Signaled when the process stops or exits (see WaitForProcessChange). }
    StateChangedEvent: TEvent;

    { What the system tells the process: end requests, its terminal's
      size (Processes.NotificationQueue, Processes.EndRequests). }
    Notifications: TNotificationQueue;

    { --- Users, priority and accounting (Processes.Security) --- }
    Credentials: TProcessCredentials;
    { Seconds since 1970, and the system's clock (nanoseconds since it
      started) at the same moment, which measures how long it has run. }
    StartTime: Int64;
    StartUptimeNanoseconds: QWord;
    { The processor time of its threads that have ended (their own goes
      with them; see Processes.Accounting). Guarded by ThreadListLock. }
    EndedThreadTimes: TThreadTimes;
    { The arguments it was started with, joined by spaces. }
    CommandLine: array[0..ProcessCommandLineCapacity - 1] of Char;

    { Links running user processes, so they can be found by id. }
    RunningLink: TListEntry;
    IsRegistered: Boolean;

    { --- Memory running out (Processes.OutOfMemory) --- }
    { Added to its share of memory when a process to end is chosen
      (-1000 to 1000; OomScoreAdjustNever: never chosen unless it is the
      one asking). Inherited. }
    OomScoreAdjust: LongInt;
    { The initial program: never chosen unless it is the one asking. Not
      inherited. }
    NeverEndForMemory: Boolean;
    { The most processes its user may run while it starts one
      (ProcessLimitProcesses); 0 for the default. Inherited. }
    ProcessCountLimit: LongWord;
    { Restrict* flags the process put on itself (Processes.Restrictions):
      only ever added. Inherited. }
    Restrictions: LongWord;
  end;

var
  ProcessObjectType: TObjectType;

procedure InitializeProcessManager;

function SystemProcess: PProcess;

function AllocateProcessOrThreadId: QWord;

{ Creates an empty user process object; the caller fills it in. }
function CreateProcessObject(Name: PChar): PProcess;

{ The registry of running user processes. A process is registered while
  its program runs; holding the registry lock keeps it from ending. }
procedure RegisterRunningProcess(Process: PProcess);
{ How often a process was registered or unregistered (a sign of
  progress, for the hang watch). }
function ProcessChangeCount: QWord;
procedure UnregisterRunningProcess(Process: PProcess);
procedure LockProcessRegistry;
procedure UnlockProcessRegistry;
{ Requires the registry lock. Returns nil if no such process runs. }
function FindRunningProcessLocked(ProcessId: QWord): PProcess;

type
  TProcessVisitor = procedure(Process: PProcess; Context: Pointer);

{ Calls Visit for every running process. Requires the registry lock. }
procedure VisitRunningProcessesLocked(Visit: TProcessVisitor; Context: Pointer);

implementation

uses
  Runtime.Atomic,
  Runtime.Text,
  Kernel.Clock,
  Kernel.Threads,
  Memory.Arch.PageTables,
  Kernel.Panic;

var
  TheSystemProcess: PProcess;
  NextId: Int64;
  RegistryLock: TMutex;
  RunningProcesses: TListEntry;

procedure DeleteProcess(ObjectBody: Pointer);
var
  Process: PProcess;
begin
  Process := PProcess(ObjectBody);
  if not Process^.IsUserProcess then
    KernelPanicWithCode(PanicObjectReferenceFailure, 'the system process was deleted',
      QWord(ObjectBody), 0, 0, 0);
  { Normally released when the program exits; this covers a process that
    never started. }
  CloseAllHandles(Process^.Handles);
  DestroyAddressSpace(Process^.AddressSpace);
  Process^.AddressSpace := nil;
end;

function AllocateProcessOrThreadId: QWord;
begin
  { Process and thread ids share one counter so an id is never ambiguous. }
  Result := QWord(AtomicIncrement(NextId));
end;

procedure InitializeCommonFields(Process: PProcess; Name: PChar);
begin
  Process^.ProcessId := AllocateProcessOrThreadId;
  CopyText(@Process^.Name[0], Name, ProcessNameLength);
  InitializeSpinLock(Process^.ThreadListLock);
  InitializeListHead(Process^.Threads);
  InitializeMutex(Process^.Lock);
  InitializeHandleTable(Process^.Handles);
  InitializeEvent(Process^.ExitEvent, EventKindNotification, False);
  InitializeSpinLock(Process^.StopLock);
  InitializeEvent(Process^.ContinueEvent, EventKindNotification, True);
  InitializeEvent(Process^.StateChangedEvent, EventKindNotification, False);
  InitializeNotificationQueue(Process^.Notifications);
  CopyText(@Process^.CurrentDirectory[0], '/', ProcessPathCapacity);
  CopyText(@Process^.RootDirectory[0], '/', ProcessPathCapacity);
  InitializeListHead(Process^.RunningLink);
  { Root until told otherwise; user processes get their creator's. }
  Process^.Credentials.Umask := DefaultUmask;
  Process^.Credentials.AffinityMask := AllProcessors;
  Process^.StartTime := CurrentWallClockTime;
  Process^.StartUptimeNanoseconds := ClockNanoseconds;
end;

procedure InitializeProcessManager;
begin
  NextId := 0;
  InitializeMutex(RegistryLock);
  InitializeListHead(RunningProcesses);
  RegisterObjectType(ProcessObjectType, 'Process', SizeOf(TProcess), @DeleteProcess);

  TheSystemProcess := PProcess(CreateObject(ProcessObjectType, 'System'));
  if TheSystemProcess = nil then
    KernelPanicWithCode(PanicInitializationFailed, 'could not create the system process', 0, 0, 0, 0);
  InitializeCommonFields(TheSystemProcess, 'System');
  TheSystemProcess^.PageTableRoot := KernelPageTableRoot;
end;

function SystemProcess: PProcess;
begin
  Result := TheSystemProcess;
end;

function CreateProcessObject(Name: PChar): PProcess;
begin
  Result := PProcess(CreateObject(ProcessObjectType, nil));
  if Result = nil then
    Exit;
  InitializeCommonFields(Result, Name);
  Result^.IsUserProcess := True;
end;

var
  Changes: QWord = 0;

function ProcessChangeCount: QWord;
begin
  Result := Changes;
end;

procedure RegisterRunningProcess(Process: PProcess);
begin
  AcquireMutex(RegistryLock);
  Inc(Changes);
  InsertAtTail(RunningProcesses, @Process^.RunningLink);
  Process^.IsRegistered := True;
  ReleaseMutex(RegistryLock);
end;

procedure UnregisterRunningProcess(Process: PProcess);
begin
  AcquireMutex(RegistryLock);
  Inc(Changes);
  if Process^.IsRegistered then
  begin
    RemoveListEntry(@Process^.RunningLink);
    Process^.IsRegistered := False;
  end;
  ReleaseMutex(RegistryLock);
end;

procedure LockProcessRegistry;
begin
  AcquireMutex(RegistryLock);
end;

procedure UnlockProcessRegistry;
begin
  ReleaseMutex(RegistryLock);
end;

procedure VisitRunningProcessesLocked(Visit: TProcessVisitor; Context: Pointer);
var
  Entry: PListEntry;
  Next: PListEntry;
begin
  Entry := RunningProcesses.Next;
  while Entry <> @RunningProcesses do
  begin
    Next := Entry^.Next;
    Visit(PProcess(ContainingRecord(Entry, FieldOffset(PProcess(nil)^.RunningLink))), Context);
    Entry := Next;
  end;
end;

function FindRunningProcessLocked(ProcessId: QWord): PProcess;
var
  Entry: PListEntry;
  Process: PProcess;
begin
  Entry := RunningProcesses.Next;
  while Entry <> @RunningProcesses do
  begin
    Process := PProcess(ContainingRecord(Entry, FieldOffset(PProcess(nil)^.RunningLink)));
    if Process^.ProcessId = ProcessId then
      Exit(Process);
    Entry := Entry^.Next;
  end;
  Result := nil;
end;

end.
