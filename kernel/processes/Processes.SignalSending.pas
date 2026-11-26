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
  Sending signals between processes: kill (CallSendSignal) and sigqueue
  (CallQueueSignal). Each process reached is handled by its own
  dispositions (Processes.Signals); a real-time signal queues with its
  sender and value, and fails with ErrorWouldBlock where the queue is
  full.
}
unit Processes.SignalSending;

{$mode objfpc}

interface

function PerformSendSignal(Target: Int64; Signal: QWord): Int64;
{ CallQueueSignal (sigqueue). }
function PerformQueueSignal(Target: Int64; Signal: QWord; Value: Int64): Int64;

implementation

uses
  Runtime.Memory,
  Abi.SystemCalls,
  Processes.Process,
  Processes.Thread,
  Processes.Security,
  Processes.Stopping,
  Processes.Signals;

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;


{ What to do with each process a kill reaches. }
type
  TSignalRequest = record
    Caller: PProcess;
    Information: TAbiSignalInformation;
    Target: Int64;
    Count: Integer;
    Denied: Integer;
    Full: Integer;
  end;
  PSignalRequest = ^TSignalRequest;

function TargetMatches(Process: PProcess; const Request: TSignalRequest): Boolean;
begin
  if Request.Target > 0 then
    Result := Process^.ProcessId = QWord(Request.Target)
  else if Request.Target = 0 then
    Result := Process^.GroupId = Request.Caller^.GroupId
  else if Request.Target = -1 then
    Result := (Process <> Request.Caller) and not Process^.NeverEndForMemory
  else
    Result := Process^.GroupId = QWord(-Request.Target);
end;

procedure PostRequested(Process: PProcess; Request: PSignalRequest);
begin
  if PostSignalWithInformationLocked(Process, Request^.Information) <> ErrorNone then
    Inc(Request^.Full);
end;

procedure SignalVisitedProcess(Process: PProcess; Context: Pointer);
var
  Request: PSignalRequest;
  Signal: LongInt;
begin
  Request := PSignalRequest(Context);
  if not Process^.IsUserProcess or Process^.HasExited or not TargetMatches(Process, Request^) then
    Exit;
  if not MayControlProcess(Request^.Caller, Process) then
  begin
    Inc(Request^.Denied);
    Exit;
  end;
  Inc(Request^.Count);
  Signal := LongInt(Request^.Information.Signal);
  if Signal = 0 then
    Exit;
  { Each process the walk reaches is handled by its own dispositions:
    SIGSTOP always stops, SIGCONT continues (and is delivered), and the
    other stopping signals stop only where their action is the default
    one, are delivered where they are handled and do nothing where they
    are ignored. }
  if Signal = SignalStop then
    StopProcessLocked(Process)
  else if Signal = SignalContinue then
  begin
    ContinueProcessLocked(Process);
    PostRequested(Process, Request);
  end
  else if SignalStopsByDefault(Signal) then
  begin
    if Process^.Posix.Dispositions[Signal] = SignalDispositionDefault then
      StopProcessLocked(Process)
    else if Process^.Posix.Dispositions[Signal] = SignalDispositionHandle then
      PostRequested(Process, Request);
  end
  else
    PostRequested(Process, Request);
end;

function SendRequest(var Request: TSignalRequest): Int64;
begin
  Request.Count := 0;
  Request.Denied := 0;
  Request.Full := 0;
  LockProcessRegistry;
  VisitRunningProcessesLocked(@SignalVisitedProcess, @Request);
  UnlockProcessRegistry;
  if Request.Count = 0 then
  begin
    if Request.Denied > 0 then
      Exit(Failure(ErrorNotPermitted));
    Exit(Failure(ErrorNoSuchProcess));
  end;
  if Request.Full = Request.Count then
    Exit(Failure(ErrorWouldBlock));
  Result := 0;
end;

function NewRequest(Target: Int64; Signal: QWord; Code: LongWord; Value: Int64): TSignalRequest;
begin
  ZeroMemory(@Result, SizeOf(Result));
  Result.Caller := CurrentProcess;
  Result.Target := Target;
  Result.Information.Signal := LongWord(Signal);
  Result.Information.Code := Code;
  Result.Information.SenderProcessId := Int64(Result.Caller^.ProcessId);
  Result.Information.SenderUserId := Result.Caller^.Credentials.RealUserId;
  Result.Information.Value := Value;
end;

function PerformSendSignal(Target: Int64; Signal: QWord): Int64;
var
  Request: TSignalRequest;
begin
  if Signal > HighestSignal then
    Exit(Failure(ErrorInvalidArgument));
  { No group has the negation of the lowest Int64 for its id. }
  if Target = Low(Int64) then
    Exit(Failure(ErrorNoSuchProcess));
  Request := NewRequest(Target, Signal, SignalFromProcess, 0);
  Result := SendRequest(Request);
end;

function PerformQueueSignal(Target: Int64; Signal: QWord; Value: Int64): Int64;
var
  Request: TSignalRequest;
begin
  if Signal > HighestSignal then
    Exit(Failure(ErrorInvalidArgument));
  { sigqueue reaches one process. }
  if Target <= 0 then
    Exit(Failure(ErrorNoSuchProcess));
  Request := NewRequest(Target, Signal, SignalFromQueue, Value);
  Result := SendRequest(Request);
end;

end.
