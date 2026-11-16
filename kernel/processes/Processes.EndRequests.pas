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
  Asking processes to end, and telling them their terminal's size.

  Every way a process is asked to end comes here with a reason: someone
  asking (CallRequestEnd: kill, the service manager stopping a service,
  the session manager logging a user off), the shutdown, a terminal's
  Ctrl-C (its foreground group) and its hang-up (the processes it
  controls). A process that selected the reason (CallSelectNotifications)
  gets an end-requested notification in its queue and decides itself:
  it may tidy up and end, ask its user, or carry on. Any other process
  is ended at once with the reason's status, which is exactly what
  happened before notifications existed - so a program that never
  heard of them behaves as it always did, and a program that does not
  answer cannot hold anything up: whoever asked may still end it
  outright (TerminateProcess) once it has waited long enough.

  The choice is made here, in the kernel, rather than by a handler in
  every program's runtime, so that it also holds for a program that is
  stuck or that never looks at its queue.

  A process already being ended counts as asked but gets nothing more.
  A group or session asked from a program leaves that program out (it
  usually wants to see the others go), and the processes of other users
  are skipped unless the asker is root.
}
unit Processes.EndRequests;

{$mode objfpc}

interface

uses
  Processes.Process;

{ The status a process gets when it is ended for Reason without taking
  the request itself. }
function EndStatusOf(Reason: LongWord): LongInt;

{ CallRequestEnd: the count of processes asked, or minus an error. }
function RequestEnd(TargetKind, TargetId, Reason: QWord): Int64;

{ Ctrl-C on a terminal: asks every process of group GroupId that does
  not ignore interrupts; returns how many. }
function InterruptProcessGroup(GroupId: QWord): Integer;
{ A terminal hung up: asks every process whose controlling terminal has
  the line discipline Terminal (a PLineDiscipline), ignoring interrupts
  or not; returns how many. }
function HangUpProcessesOfTerminal(Terminal: Pointer): Integer;
{ The shutdown: asks every user process; returns how many. }
function AskAllUserProcessesToEnd(Reason: LongWord): Integer;
{ A terminal's size changed: tells every process of group GroupId that
  selected NotifyTerminalResized (Size: rows shl 16 or columns). }
procedure TellGroupTerminalResized(GroupId: QWord; Size: QWord);

implementation

uses
  Abi.SystemCalls,
  Processes.NotificationQueue,
  Processes.Security,
  Processes.Termination,
  Processes.Thread,
  Io.Manager;

type
  TTargetMatch = (MatchProcess, MatchGroup, MatchSession, MatchTerminal, MatchAllUserProcesses);

  TEndRequest = record
    Match: TTargetMatch;
    { The process, group or session id to match. }
    Id: QWord;
    { The line discipline, for MatchTerminal. }
    Terminal: Pointer;
    Reason: LongWord;
    { The program asking, nil for the system; it is left out of groups
      and sessions, and may only ask processes it may control. }
    Asker: PProcess;
    SenderProcessId: QWord;
    { Ctrl-C spares processes that ignore it (an interactive shell). }
    SparesInterruptIgnorers: Boolean;
    Count: Integer;
    Denied: Integer;
  end;
  PEndRequest = ^TEndRequest;

function EndStatusOf(Reason: LongWord): LongInt;
begin
  case Reason of
    EndReasonHangUp: Result := EndStatusHangUp;
    EndReasonInterrupt: Result := EndStatusInterrupted;
  else
    Result := EndStatusRequested;
  end;
end;

{ Requires the registry lock. }
procedure AskProcessToEndLocked(Process: PProcess; Reason: LongWord; SenderProcessId: QWord);
begin
  if Process^.TerminationRequested then
    Exit;
  if NotificationIsSelected(Process^.Notifications, LongWord(1) shl Reason) then
    PostNotification(Process^.Notifications, NotificationEndRequested, Reason, SenderProcessId, 0)
  else
    RequestProcessTerminationLocked(Process, EndStatusOf(Reason));
end;

function ControlledByTerminal(Process: PProcess; Terminal: Pointer): Boolean;
begin
  Result := (Process^.ControllingTerminal <> nil) and
    (PDeviceObject(Process^.ControllingTerminal)^.Terminal = Terminal);
end;

function MatchesTarget(Process: PProcess; const Request: TEndRequest): Boolean;
begin
  case Request.Match of
    MatchProcess: Result := Process^.ProcessId = Request.Id;
    MatchGroup: Result := (Process^.GroupId = Request.Id) and (Process <> Request.Asker);
    MatchSession: Result := (Process^.SessionId = Request.Id) and (Process <> Request.Asker);
    MatchTerminal: Result := ControlledByTerminal(Process, Request.Terminal);
  else
    Result := True;
  end;
end;

procedure VisitProcess(Process: PProcess; Context: Pointer);
var
  Request: PEndRequest;
begin
  Request := PEndRequest(Context);
  if not Process^.IsUserProcess or Process^.HasExited or not MatchesTarget(Process, Request^) then
    Exit;
  if Request^.SparesInterruptIgnorers and Process^.IgnoresInterrupt then
    Exit;
  if (Request^.Asker <> nil) and not MayControlProcess(Request^.Asker, Process) then
  begin
    Inc(Request^.Denied);
    Exit;
  end;
  AskProcessToEndLocked(Process, Request^.Reason, Request^.SenderProcessId);
  Inc(Request^.Count);
end;

procedure PrepareRequest(out Request: TEndRequest; Match: TTargetMatch; Id: QWord; Reason: LongWord);
begin
  Request.Match := Match;
  Request.Id := Id;
  Request.Terminal := nil;
  Request.Reason := Reason;
  Request.Asker := nil;
  Request.SenderProcessId := 0;
  Request.SparesInterruptIgnorers := False;
  Request.Count := 0;
  Request.Denied := 0;
end;

procedure CarryOut(var Request: TEndRequest);
begin
  LockProcessRegistry;
  VisitRunningProcessesLocked(@VisitProcess, @Request);
  UnlockProcessRegistry;
end;

function RequestEnd(TargetKind, TargetId, Reason: QWord): Int64;
var
  Request: TEndRequest;
  Caller: PProcess;
begin
  if (Reason < EndReasonAsked) or (Reason > HighestEndReason) then
    Exit(-Int64(ErrorInvalidArgument));
  Caller := CurrentProcess;
  case TargetKind of
    EndTargetProcess:
      begin
        if TargetId = 0 then
          TargetId := Caller^.ProcessId;
        PrepareRequest(Request, MatchProcess, TargetId, Reason);
      end;
    EndTargetGroup:
      begin
        if TargetId = 0 then
          TargetId := Caller^.GroupId;
        PrepareRequest(Request, MatchGroup, TargetId, Reason);
      end;
    EndTargetSession:
      begin
        if TargetId = 0 then
          TargetId := Caller^.SessionId;
        PrepareRequest(Request, MatchSession, TargetId, Reason);
      end;
  else
    Exit(-Int64(ErrorInvalidArgument));
  end;
  Request.Asker := Caller;
  Request.SenderProcessId := Caller^.ProcessId;
  CarryOut(Request);
  if Request.Count > 0 then
    Result := Request.Count
  else if Request.Denied > 0 then
    Result := -Int64(ErrorNotPermitted)
  else
    Result := -Int64(ErrorNoSuchProcess);
end;

function InterruptProcessGroup(GroupId: QWord): Integer;
var
  Request: TEndRequest;
begin
  if GroupId = 0 then
    Exit(0);
  PrepareRequest(Request, MatchGroup, GroupId, EndReasonInterrupt);
  Request.SparesInterruptIgnorers := True;
  CarryOut(Request);
  Result := Request.Count;
end;

function HangUpProcessesOfTerminal(Terminal: Pointer): Integer;
var
  Request: TEndRequest;
begin
  PrepareRequest(Request, MatchTerminal, 0, EndReasonHangUp);
  Request.Terminal := Terminal;
  CarryOut(Request);
  Result := Request.Count;
end;

function AskAllUserProcessesToEnd(Reason: LongWord): Integer;
var
  Request: TEndRequest;
begin
  PrepareRequest(Request, MatchAllUserProcesses, 0, Reason);
  CarryOut(Request);
  Result := Request.Count;
end;

type
  TResizeNotice = record
    GroupId: QWord;
    Size: QWord;
  end;
  PResizeNotice = ^TResizeNotice;

procedure TellIfResizeSelected(Process: PProcess; Context: Pointer);
var
  Notice: PResizeNotice;
begin
  Notice := PResizeNotice(Context);
  if not Process^.IsUserProcess or Process^.HasExited or (Process^.GroupId <> Notice^.GroupId) then
    Exit;
  if NotificationIsSelected(Process^.Notifications, NotifyTerminalResized) then
    PostNotification(Process^.Notifications, NotificationTerminalResized, 0, 0, Notice^.Size);
end;

procedure TellGroupTerminalResized(GroupId: QWord; Size: QWord);
var
  Notice: TResizeNotice;
begin
  if GroupId = 0 then
    Exit;
  Notice.GroupId := GroupId;
  Notice.Size := Size;
  LockProcessRegistry;
  VisitRunningProcessesLocked(@TellIfResizeSelected, @Notice);
  UnlockProcessRegistry;
end;

end.
