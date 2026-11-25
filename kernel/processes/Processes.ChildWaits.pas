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
  POSIX children: waitpid, process groups and sessions.

  A process keeps a reference to every child fork made (its "children",
  Process^.Posix.Children) until it waits for it, or until it ends
  itself: an ended child is a zombie until then, its exit code and the
  signal that ended it kept in the process object. When a child ends (or
  stops), its parent's ChildChangedEvent is signaled and, if the parent
  handles SIGCHLD, the signal is sent (Processes.Signals).

  CallWaitForChild reports the Linux status word: the exit code shl 8,
  or the signal that ended the process (and 0x7F plus the signal shl 8
  for a stopped one).
}
unit Processes.ChildWaits;

{$mode objfpc}

interface

uses
  Processes.Process;

{ Records Child (taking a reference) among Parent's children. }
function AddChild(Parent, Child: PProcess): LongInt;
{ Gives back every child reference (the process is ending or execs
  nothing more). }
procedure ReleaseChildren(Process: PProcess);
{ Called when Process ended or stopped: tells its parent. }
procedure NotifyParentOfChange(Process: PProcess; Stopped: Boolean);

function PerformWaitForChild(ProcessId: Int64; StatusAddress: QWord; Flags: QWord): Int64;
function PerformSetProcessGroup(ProcessId, GroupId: QWord): Int64;
function PerformCreateSession: Int64;
function PerformGetProcessGroupOf(ProcessId, Which: QWord): Int64;

implementation

uses
  Runtime.Memory,
  Abi.SystemCalls,
  Memory.KernelHeap,
  Kernel.Mutex,
  Kernel.Events,
  Kernel.Threads,
  Kernel.Scheduler,
  Objects.Manager,
  Processes.Thread,
  Processes.UserAccess,
  Processes.Signals;

const
  StatusStoppedMarker = $7F;

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

function AddChild(Parent, Child: PProcess): LongInt;
var
  Grown: PPointer;
  Capacity: LongInt;
begin
  AcquireMutex(Parent^.Lock);
  if Parent^.Posix.ChildCount = Parent^.Posix.ChildCapacity then
  begin
    Capacity := Parent^.Posix.ChildCapacity * 2;
    if Capacity < 8 then
      Capacity := 8;
    Grown := PPointer(AllocateZeroedKernelMemory(QWord(Capacity) * SizeOf(Pointer)));
    if Grown = nil then
    begin
      ReleaseMutex(Parent^.Lock);
      Exit(ErrorOutOfMemory);
    end;
    if Parent^.Posix.Children <> nil then
    begin
      CopyMemory(Grown, Parent^.Posix.Children, QWord(Parent^.Posix.ChildCount) * SizeOf(Pointer));
      FreeKernelMemory(Parent^.Posix.Children);
    end;
    Parent^.Posix.Children := Grown;
    Parent^.Posix.ChildCapacity := Capacity;
  end;
  ReferenceObject(Child);
  Parent^.Posix.Children[Parent^.Posix.ChildCount] := Child;
  Inc(Parent^.Posix.ChildCount);
  ReleaseMutex(Parent^.Lock);
  Result := ErrorNone;
end;

procedure ReleaseChildren(Process: PProcess);
var
  Index: LongInt;
  Children: PPointer;
  Count: LongInt;
begin
  AcquireMutex(Process^.Lock);
  Children := Process^.Posix.Children;
  Count := Process^.Posix.ChildCount;
  Process^.Posix.Children := nil;
  Process^.Posix.ChildCount := 0;
  Process^.Posix.ChildCapacity := 0;
  ReleaseMutex(Process^.Lock);
  for Index := 0 to Count - 1 do
    DereferenceObject(Children[Index]);
  FreeKernelMemory(Children);
end;

procedure NotifyParentOfChange(Process: PProcess; Stopped: Boolean);
var
  Parent: PProcess;
begin
  if Process^.ParentProcessId = 0 then
    Exit;
  LockProcessRegistry;
  Parent := FindRunningProcessLocked(Process^.ParentProcessId);
  if Parent <> nil then
  begin
    SignalEvent(Parent^.Posix.ChildChangedEvent);
    if not Stopped then
      PostSignalFromKernelLocked(Parent, SignalChild, Process^.ProcessId);
  end;
  UnlockProcessRegistry;
end;

{ Whether Child is one ProcessId (waitpid's argument) asks for. }
function ChildMatches(Caller, Child: PProcess; ProcessId: Int64): Boolean;
begin
  if ProcessId > 0 then
    Result := Child^.ProcessId = QWord(ProcessId)
  else if ProcessId = -1 then
    Result := True
  else if ProcessId = 0 then
    Result := Child^.GroupId = Caller^.GroupId
  else
    Result := Child^.GroupId = QWord(-ProcessId);
end;

{ The status of a child seen to have ended. }
function StatusOf(Child: PProcess): LongInt;
var
  ExitCode: LongInt;
begin
  { After the barrier: the end signal and code were set before the
    child was marked ended. }
  ExitCode := ReadExitCode(Child);
  if Child^.Posix.EndSignal <> 0 then
    Result := Child^.Posix.EndSignal and $7F
  else
    Result := (ExitCode and $FF) shl 8;
end;

{ Looks once through the caller's children for one to report. Found
  tells whether any child matches at all. Returns the reported child's
  id (0 if none yet) and its status; a reaped child comes back in Reaped
  for the caller to dereference once it let go of the lock (that may
  delete it). Caller holds the process's Lock. }
function ReportChildLocked(Caller: PProcess; ProcessId: Int64; Flags: QWord; out Found: Boolean;
  out Status: LongInt; out Reaped: PProcess): QWord;
var
  Index: LongInt;
  Child: PProcess;
  Last: LongInt;
begin
  Result := 0;
  Found := False;
  Status := 0;
  Reaped := nil;
  Index := 0;
  while Index < Caller^.Posix.ChildCount do
  begin
    Child := PProcess(Caller^.Posix.Children[Index]);
    if ChildMatches(Caller, Child, ProcessId) then
    begin
      Found := True;
      if Child^.HasExited then
      begin
        Status := StatusOf(Child);
        Result := Child^.ProcessId;
        { Reaped: out of the list, its reference given back. }
        Last := Caller^.Posix.ChildCount - 1;
        Caller^.Posix.Children[Index] := Caller^.Posix.Children[Last];
        Caller^.Posix.Children[Last] := nil;
        Caller^.Posix.ChildCount := Last;
        Reaped := Child;
        Exit;
      end;
      if ((Flags and WaitUntraced) <> 0) and Child^.IsStopped and not Child^.Posix.StopReportedToParent then
      begin
        Child^.Posix.StopReportedToParent := True;
        Status := (SignalStop shl 8) or StatusStoppedMarker;
        Result := Child^.ProcessId;
        Exit;
      end;
    end;
    Inc(Index);
  end;
end;

function PerformWaitForChild(ProcessId: Int64; StatusAddress: QWord; Flags: QWord): Int64;
var
  Caller: PProcess;
  Found: Boolean;
  Status: LongInt;
  Reported: QWord;
  Reaped: PProcess;
begin
  Caller := CurrentProcess;
  if (Flags and not QWord(WaitNoHang or WaitUntraced or WaitContinued)) <> 0 then
    Exit(Failure(ErrorInvalidArgument));
  repeat
    ResetEvent(Caller^.Posix.ChildChangedEvent);
    AcquireMutex(Caller^.Lock);
    Reported := ReportChildLocked(Caller, ProcessId, Flags, Found, Status, Reaped);
    ReleaseMutex(Caller^.Lock);
    if Reaped <> nil then
      DereferenceObject(Reaped);
    if not Found then
      Exit(Failure(ErrorNoChildProcess));
    if Reported <> 0 then
    begin
      if StatusAddress <> 0 then
      begin
        Result := -Int64(CopyToUser(StatusAddress, @Status, SizeOf(Status)));
        if Result <> 0 then
          Exit;
      end;
      Exit(Int64(Reported));
    end;
    if (Flags and WaitNoHang) <> 0 then
      Exit(0);
    if WaitForEventWithOptions(Caller^.Posix.ChildChangedEvent, InfiniteTimeout, True) <> WaitSignaled then
      Exit(Failure(ErrorInterrupted));
  until False;
end;

function IsChildOf(Caller: PProcess; ProcessId: QWord): Boolean;
var
  Index: LongInt;
begin
  Result := False;
  AcquireMutex(Caller^.Lock);
  for Index := 0 to Caller^.Posix.ChildCount - 1 do
    if PProcess(Caller^.Posix.Children[Index])^.ProcessId = ProcessId then
      Result := True;
  ReleaseMutex(Caller^.Lock);
end;

type
  TGroupSearch = record
    GroupId: QWord;
    SessionId: QWord;
    Found: Boolean;
  end;
  PGroupSearch = ^TGroupSearch;

procedure NoteGroupMember(Process: PProcess; Context: Pointer);
var
  Search: PGroupSearch;
begin
  Search := PGroupSearch(Context);
  if Process^.IsUserProcess and not Process^.HasExited and (Process^.GroupId = Search^.GroupId) and
     (Process^.SessionId = Search^.SessionId) then
    Search^.Found := True;
end;

{ True if a group GroupId has a member in session SessionId (the
  registry lock held). }
function GroupExistsInSessionLocked(GroupId, SessionId: QWord): Boolean;
var
  Search: TGroupSearch;
begin
  Search.GroupId := GroupId;
  Search.SessionId := SessionId;
  Search.Found := False;
  VisitRunningProcessesLocked(@NoteGroupMember, @Search);
  Result := Search.Found;
end;

function PerformSetProcessGroup(ProcessId, GroupId: QWord): Int64;
var
  Caller: PProcess;
  Target: PProcess;
begin
  Caller := CurrentProcess;
  if ProcessId = 0 then
    ProcessId := Caller^.ProcessId;
  if (ProcessId <> Caller^.ProcessId) and not IsChildOf(Caller, ProcessId) then
    Exit(Failure(ErrorNoSuchProcess));
  if GroupId = 0 then
    GroupId := ProcessId;
  LockProcessRegistry;
  Target := FindRunningProcessLocked(ProcessId);
  if Target = nil then
    Result := Failure(ErrorNoSuchProcess)
  else if Target^.SessionId <> Caller^.SessionId then
    Result := Failure(ErrorNotPermitted)
  else if Target^.SessionId = Target^.ProcessId then
    { A session leader stays the leader of its own group. }
    Result := Failure(ErrorNotPermitted)
  { A process leads a group of its own, or joins one of its session
    (never one of another session, nor a number nobody has). }
  else if (GroupId <> ProcessId) and not GroupExistsInSessionLocked(GroupId, Target^.SessionId) then
    Result := Failure(ErrorNotPermitted)
  else
  begin
    Target^.GroupId := GroupId;
    Result := 0;
  end;
  UnlockProcessRegistry;
end;

function PerformCreateSession: Int64;
var
  Caller: PProcess;
begin
  Caller := CurrentProcess;
  LockProcessRegistry;
  if Caller^.GroupId = Caller^.ProcessId then
    Result := Failure(ErrorNotPermitted)
  else
  begin
    Caller^.SessionId := Caller^.ProcessId;
    Caller^.GroupId := Caller^.ProcessId;
    Caller^.ControllingTerminal := nil;
    Result := Int64(Caller^.ProcessId);
  end;
  UnlockProcessRegistry;
end;

function PerformGetProcessGroupOf(ProcessId, Which: QWord): Int64;
var
  Target: PProcess;
begin
  if ProcessId = 0 then
    ProcessId := CurrentProcess^.ProcessId;
  LockProcessRegistry;
  Target := FindRunningProcessLocked(ProcessId);
  if Target = nil then
    Result := Failure(ErrorNoSuchProcess)
  else if Which = 0 then
    Result := Int64(Target^.GroupId)
  else
    Result := Int64(Target^.SessionId);
  UnlockProcessRegistry;
end;

end.
