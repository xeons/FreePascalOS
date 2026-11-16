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
  notifytest - checks notifications and end requests

  notifytest

  Run by coretest (as root). Checks the program's own queue (empty, an
  end request it sent itself waited for among other handles, a second
  one merged into the first, a bad reason), then children of its own:
  one that takes the request and ends with a status of its own, having
  waited for it among other handles; requests it did not take ending it
  with the reason's status (143, 129, 130); a group and a session asked
  as a whole; a handler thread (Sys.EndRequests); an ordinary user who
  may not ask root's program; and, on a pseudo-terminal, Ctrl-C taken
  by the foreground program and a new size told to it.

  The program runs itself as each child (the options below), and as the
  test services of servicetest:

    --take MASK STATUS     takes the end requests of MASK, says "ready",
                           waits for one among a timer and an event,
                           says "got REASON SENDER at PLACE", ends with
                           STATUS
    --take-with-child      starts --take 30 43 in its own session, then
                           does --take 30 42 and waits for the child
    --leave                says "ready" and sleeps (takes nothing)
    --handler STATUS       says "ready"; a handler thread says
                           "handler REASON" and ends the program with
                           STATUS
    --resize               takes the terminal's size, says "ready",
                           says "size ROWS COLUMNS" for the first
    --tidy-service FILE    a handler writes the reason into FILE and
                           ends the program with status 0
    --ignore-end-requests  takes the end requests and never reads them

  Each check prints a line; the exit status is 1 if any failed.
}
program NotifyTest;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.EndRequests,
  Sys.Files,
  Sys.Kernel,
  Sys.Notifications,
  Sys.Objects,
  Sys.Processes,
  Sys.PseudoTerminals,
  Sys.Streams,
  Sys.Time;

const
  ProgramPath = '/bin/notifytest';
  ChildTimeout = 10000;
  { How long a child waits for a request before it gives up. }
  ChildPatience = 20000;
  GaveUpStatus = 99;

var
  Failures: Integer = 0;
  Checks: Integer = 0;

procedure Check(const Name: string; Passed: Boolean);
begin
  Inc(Checks);
  if Passed then
    WriteString(StandardOutput, Format('notifytest: pass: %s'#10, [PChar(Name)]))
  else
  begin
    WriteString(StandardOutput, Format('notifytest: FAIL: %s'#10, [PChar(Name)]));
    Inc(Failures);
  end;
  FlushStream(StandardOutput);
end;

procedure Note(const Text: string);
begin
  WriteString(StandardOutput, Format('notifytest: %s'#10, [PChar(Text)]));
  FlushStream(StandardOutput);
end;

procedure Say(const Text: string);
begin
  WriteString(StandardOutput, Format('%s'#10, [PChar(Text)]));
  FlushStream(StandardOutput);
end;

{ --- The children ---------------------------------------------------- }

{ Waits for an end request among a timer and an event that never come,
  says what came and where, and ends with Status. }
procedure TakeAndEnd(Mask: LongWord; Status: LongInt);
var
  Timer: Int64;
  Event: Int64;
  Ready: Int64;
  Notification: TAbiNotification;
begin
  TakeNotifications(Mask);
  Timer := CreateTimer(False);
  Event := CreateEvent(False, False);
  SetTimer(Timer, ChildPatience, 0);
  Say('ready');
  Ready := WaitForHandles([Timer, Event, NotificationsHandle], InfiniteWait);
  if (Ready = 2) and ReceiveNotification(Notification) then
  begin
    Say(Format('got %s %d at %d', [EndReasonName(Notification.Reason), Notification.SenderProcessId, Ready]));
    Halt(Status);
  end;
  Say('gave up');
  Halt(GaveUpStatus);
end;

procedure TakeWithChild;
var
  Arguments: array[0..4] of PChar;
  Options: TProcessOptions;
  Child: Int64;
  ExitCode: LongInt;
  Notification: TAbiNotification;
begin
  Arguments[0] := ProgramPath;
  Arguments[1] := '--take';
  Arguments[2] := '30';
  Arguments[3] := '43';
  Arguments[4] := nil;
  DefaultProcessOptions(Options);
  Child := StartProgram(ProgramPath, @Arguments[0], Options);
  { The parent asks once both said they are ready; the child's answer
    comes before this program ends. }
  TakeNotifications(NotifyEndRequests);
  Say('ready');
  if WaitForNotification(Notification, ChildPatience) then
  begin
    WaitForProgramWithTimeout(Child, ChildTimeout, ExitCode);
    Say('got log-off as the leader');
    Halt(42);
  end;
  Halt(GaveUpStatus);
end;

procedure HandlerSaysAndEnds(Reason: LongWord; SenderProcessId: QWord);
begin
  Say('handler ' + EndReasonName(Reason));
  Halt(StrToIntDef(ParamStr(2), 0));
end;

procedure TidyUpService(Reason: LongWord; SenderProcessId: QWord);
var
  Handle: Int64;
  Text: string;
begin
  Text := EndReasonName(Reason) + #10;
  Handle := OpenFile(PChar(ParamStr(2)), OpenWrite or OpenCreate or OpenTruncate);
  if Handle >= 0 then
  begin
    WriteFile(Handle, @Text[1], Length(Text));
    CloseFile(Handle);
  end;
  Halt(0);
end;

procedure WaitForResize;
var
  Notification: TAbiNotification;
begin
  TakeNotifications(NotifyTerminalResized);
  Say('ready');
  if WaitForNotification(Notification, ChildPatience) and (Notification.Kind = NotificationTerminalResized) then
  begin
    Say(Format('size %d %d', [Notification.Value shr 16, Notification.Value and $FFFF]));
    Halt(0);
  end;
  Halt(GaveUpStatus);
end;

procedure SleepForever;
begin
  repeat
    SleepMilliseconds(1000);
  until False;
end;

{ --- Starting children and reading what they say ---------------------- }

var
  ChildOutput: Int64 = NoHandle;
  ChildOutputWriteEnd: Int64 = NoHandle;
  ChildSaid: string = '';

procedure OpenChildOutput;
begin
  CreatePipe(ChildOutput, ChildOutputWriteEnd);
  ChildSaid := '';
end;

procedure CloseChildOutput;
begin
  CloseFile(ChildOutput);
  if ChildOutputWriteEnd <> NoHandle then
    CloseFile(ChildOutputWriteEnd);
  ChildOutput := NoHandle;
  ChildOutputWriteEnd := NoHandle;
end;

function TextOf(const Buffer: array of Char; Count: Int64): string;
begin
  SetString(Result, PChar(@Buffer[0]), Count);
end;

function CountOf(const Part, Text: string): LongInt;
var
  Rest: string;
  Found: LongInt;
begin
  Result := 0;
  Rest := Text;
  repeat
    Found := Pos(Part, Rest);
    if Found > 0 then
    begin
      Inc(Result);
      Delete(Rest, 1, Found + Length(Part) - 1);
    end;
  until Found = 0;
end;

{ Reads from Handle into ChildSaid until Part was said Count times;
  False after ChildTimeout. }
function WaitUntilSaid(Handle: Int64; const Part: string; Count: LongInt): Boolean;
var
  Buffer: array[0..511] of Char;
  Got: Int64;
  Deadline: QWord;
begin
  Deadline := UptimeMilliseconds + ChildTimeout;
  while CountOf(Part, ChildSaid) < Count do
  begin
    if UptimeMilliseconds > Deadline then
      Exit(False);
    if WaitForHandle(Handle, 100) <> ErrorNone then
      Continue;
    Got := ReadFile(Handle, @Buffer[0], SizeOf(Buffer));
    if Got <= 0 then
      Exit(CountOf(Part, ChildSaid) >= Count);
    ChildSaid := ChildSaid + TextOf(Buffer, Got);
  end;
  Result := True;
end;

{ Starts this program with Arguments, its output going to the pipe. }
function StartChild(const Arguments: array of string; GroupId: Int64; NewSession: Boolean): Int64;
var
  Values: array[0..7] of PChar;
  Index: LongInt;
  Options: TProcessOptions;
begin
  Values[0] := ProgramPath;
  for Index := 0 to High(Arguments) do
    Values[Index + 1] := PChar(Arguments[Index]);
  Values[Length(Arguments) + 1] := nil;
  DefaultProcessOptions(Options);
  Options.OutputHandle := ChildOutputWriteEnd;
  Options.GroupId := GroupId;
  Options.NewSession := NewSession;
  Result := StartProgram(ProgramPath, @Values[0], Options);
end;

function StatusOf(Child: Int64): LongInt;
begin
  if WaitForProgramWithTimeout(Child, ChildTimeout, Result) <> ErrorNone then
    Result := -1;
  CloseHandle(Child);
end;

{ --- The checks --------------------------------------------------------- }

procedure TestOwnQueue;
var
  Notification: TAbiNotification;
  Event: Int64;
  Own: QWord;
begin
  Own := QWord(CurrentProcessId);
  Check('nothing waits at first', not ReceiveNotification(Notification) and
    (WaitForHandles([NotificationsHandle], 0) = -ErrorTimedOut));
  TakeNotifications(NotifyEndAsked);
  Check('asking itself', AskProcessToEnd(0, EndReasonAsked) = ErrorNone);
  Event := CreateEvent(False, False);
  Check('the queue is waited for among other handles', WaitForHandles([Event, NotificationsHandle], 1000) = 1);
  Check('the request merged with a second one', AskProcessToEnd(Own, EndReasonAsked) = ErrorNone);
  Check('it says what and who', ReceiveNotification(Notification) and
    (Notification.Kind = NotificationEndRequested) and (Notification.Reason = EndReasonAsked) and
    (Notification.SenderProcessId = Own));
  Check('only one was queued', not ReceiveNotification(Notification) and
    (WaitForHandles([Event, NotificationsHandle], 0) = -ErrorTimedOut));
  Check('a reason that does not exist', AskProcessToEnd(0, 99) = ErrorInvalidArgument);
  Check('a process that does not exist', AskProcessToEnd(999999, EndReasonAsked) = ErrorNoSuchProcess);
  LeaveNotifications(NotifyEndAsked);
  Check('nothing is taken any more', TakenNotifications = 0);
  CloseHandle(Event);
end;

procedure TestTakenRequest;
var
  Child: Int64;
begin
  OpenChildOutput;
  Child := StartChild(['--take', IntToStr(NotifyEndAsked), '42'], GroupInherit, False);
  Check('a child that takes requests is ready', (Child >= 0) and WaitUntilSaid(ChildOutput, 'ready', 1));
  Check('asking it', AskProcessToEnd(QWord(ProcessIdOf(Child)), EndReasonAsked) = ErrorNone);
  Check('it ends with its own status', StatusOf(Child) = 42);
  Check('it was told the reason and the sender, among its other handles',
    WaitUntilSaid(ChildOutput, Format('got asked %d at 2', [CurrentProcessId]), 1));
  CloseChildOutput;
end;

procedure TestUntakenRequest(Reason: LongWord; Expected: LongInt; const Name: string);
var
  Child: Int64;
begin
  OpenChildOutput;
  Child := StartChild(['--take', IntToStr(NotifyEndAsked), '42'], GroupInherit, False);
  WaitUntilSaid(ChildOutput, 'ready', 1);
  AskProcessToEnd(QWord(ProcessIdOf(Child)), Reason);
  Check(Name, StatusOf(Child) = Expected);
  CloseChildOutput;
end;

procedure TestLeftRequests;
var
  Child: Int64;
begin
  TestUntakenRequest(EndReasonLogOff, EndStatusRequested, 'a reason it does not take ends it with 143');
  TestUntakenRequest(EndReasonHangUp, EndStatusHangUp, 'a hang-up it does not take ends it with 129');
  TestUntakenRequest(EndReasonInterrupt, EndStatusInterrupted, 'Ctrl-C it does not take ends it with 130');
  OpenChildOutput;
  Child := StartChild(['--leave'], GroupInherit, False);
  WaitUntilSaid(ChildOutput, 'ready', 1);
  AskProcessToEnd(QWord(ProcessIdOf(Child)), EndReasonAsked);
  Check('a program that takes nothing ends as it always did (143)', StatusOf(Child) = EndStatusRequested);
  CloseChildOutput;
end;

procedure TestGroup;
var
  First: Int64;
  Second: Int64;
  GroupId: QWord;
begin
  OpenChildOutput;
  First := StartChild(['--take', IntToStr(NotifyEndRequests), '42'], GroupNew, False);
  GroupId := QWord(ProcessIdOf(First));
  Second := StartChild(['--take', IntToStr(NotifyEndRequests), '43'], Int64(GroupId), False);
  WaitUntilSaid(ChildOutput, 'ready', 2);
  Check('a group asked as a whole', AskGroupToEnd(GroupId, EndReasonServiceStop) = 2);
  Check('each of the group ends with its own status', (StatusOf(First) = 42) and (StatusOf(Second) = 43));
  Check('each heard the reason', WaitUntilSaid(ChildOutput, 'got service-stop', 2));
  Check('a group that does not exist', AskGroupToEnd(999999, EndReasonAsked) = -ErrorNoSuchProcess);
  CloseChildOutput;
end;

procedure TestSession;
var
  Leader: Int64;
  SessionId: QWord;
begin
  OpenChildOutput;
  Leader := StartChild(['--take-with-child'], GroupNew, True);
  SessionId := QWord(ProcessIdOf(Leader));
  WaitUntilSaid(ChildOutput, 'ready', 2);
  Check('a session asked as a whole', AskSessionToEnd(SessionId, EndReasonLogOff) = 2);
  Check('its leader ends once its child did', StatusOf(Leader) = 42);
  Check('both heard the reason', WaitUntilSaid(ChildOutput, 'got log-off', 2));
  CloseChildOutput;
end;

procedure TestHandlerThread;
var
  Child: Int64;
begin
  OpenChildOutput;
  Child := StartChild(['--handler', '7'], GroupInherit, False);
  WaitUntilSaid(ChildOutput, 'ready', 1);
  AskProcessToEnd(QWord(ProcessIdOf(Child)), EndReasonShutdown);
  Check('a handler thread takes the request and ends the program', StatusOf(Child) = 7);
  Check('the handler heard the reason', WaitUntilSaid(ChildOutput, 'handler shutdown', 1));
  CloseChildOutput;
end;

{ Runs Line as the ordinary user (su user -c); what it printed. }
function RunAsUser(const Line: string): string;
var
  Arguments: array[0..4] of PChar;
  Options: TProcessOptions;
  ReadEnd: Int64;
  WriteEnd: Int64;
  Process: Int64;
  Buffer: array[0..511] of Char;
  Got: Int64;
begin
  Result := '';
  if CreatePipe(ReadEnd, WriteEnd) <> ErrorNone then
    Exit;
  Arguments[0] := '/bin/su';
  Arguments[1] := 'user';
  Arguments[2] := '-c';
  Arguments[3] := PChar(Line);
  Arguments[4] := nil;
  DefaultProcessOptions(Options);
  Options.OutputHandle := WriteEnd;
  Process := StartProgram('/bin/su', @Arguments[0], Options);
  CloseFile(WriteEnd);
  if Process >= 0 then
  begin
    repeat
      Got := ReadFile(ReadEnd, @Buffer[0], SizeOf(Buffer));
      if Got > 0 then
        Result := Result + TextOf(Buffer, Got);
    until Got <= 0;
    StatusOf(Process);
  end;
  CloseFile(ReadEnd);
end;

procedure TestPermission;
var
  Child: Int64;
  Said: string;
  ExitCode: LongInt;
begin
  OpenChildOutput;
  Child := StartChild(['--leave'], GroupNew, False);
  WaitUntilSaid(ChildOutput, 'ready', 1);
  Said := RunAsUser(Format('kill %d 2>/dev/null; echo $?; kill -TERM -- -%d 2>/dev/null; echo $?',
    [ProcessIdOf(Child), ProcessIdOf(Child)]));
  Check('an ordinary user may not ask root''s program, nor its group', Said = '1'#10'1'#10);
  if Said <> '1'#10'1'#10 then
    Note('received: ' + Said);
  Check('root''s program still runs', WaitForProgramWithTimeout(Child, 300, ExitCode) = ErrorTimedOut);
  TerminateProgram(QWord(ProcessIdOf(Child)), EndStatusRequested);
  StatusOf(Child);
  CloseChildOutput;
end;

procedure TestTerminal;
var
  Terminal: TAbiPseudoTerminal;
  Arguments: array[0..4] of PChar;
  Mask: string;
  Child: Int64;
  Interrupt: Char;
begin
  if CreatePseudoTerminal(25, 80, Terminal) <> ErrorNone then
  begin
    Check('a pseudo-terminal', False);
    Exit;
  end;
  ChildSaid := '';
  Mask := IntToStr(NotifyEndInterrupt);
  Arguments[0] := ProgramPath;
  Arguments[1] := '--take';
  Arguments[2] := PChar(Mask);
  Arguments[3] := '42';
  Arguments[4] := nil;
  Child := StartOnTerminal(ProgramPath, @Arguments[0], Terminal.TerminalHandle);
  WaitUntilSaid(Terminal.OutputHandle, 'ready', 1);
  Interrupt := #3;
  WriteFile(Terminal.InputHandle, @Interrupt, 1);
  Check('Ctrl-C taken by the foreground program', StatusOf(Child) = 42);
  Check('it heard the interrupt from the system', WaitUntilSaid(Terminal.OutputHandle, 'got interrupt 0 at 2', 1));

  ChildSaid := '';
  Arguments[1] := '--resize';
  Arguments[2] := nil;
  Child := StartOnTerminal(ProgramPath, @Arguments[0], Terminal.TerminalHandle);
  WaitUntilSaid(Terminal.OutputHandle, 'ready', 1);
  KernelControlHandle(Terminal.InputHandle, ControlSetConsoleSize, (30 shl 16) or 100);
  Check('a new size is told to the foreground program', (StatusOf(Child) = 0) and
    WaitUntilSaid(Terminal.OutputHandle, 'size 30 100', 1));
  CloseHandle(Terminal.TerminalHandle);
  CloseHandle(Terminal.InputHandle);
  CloseHandle(Terminal.OutputHandle);
end;

begin
  if ParamStr(1) = '--take' then
    TakeAndEnd(StrToIntDef(ParamStr(2), 0), StrToIntDef(ParamStr(3), 0));
  if ParamStr(1) = '--take-with-child' then
    TakeWithChild;
  if ParamStr(1) = '--leave' then
  begin
    Say('ready');
    SleepForever;
  end;
  if ParamStr(1) = '--handler' then
  begin
    HandleEndRequests(@HandlerSaysAndEnds, NotifyEndRequests);
    Say('ready');
    SleepForever;
  end;
  if ParamStr(1) = '--resize' then
    WaitForResize;
  if ParamStr(1) = '--tidy-service' then
  begin
    HandleEndRequests(@TidyUpService, NotifyEndRequests);
    SleepForever;
  end;
  if ParamStr(1) = '--ignore-end-requests' then
  begin
    TakeNotifications(NotifyEndRequests);
    SleepForever;
  end;

  TestOwnQueue;
  TestTakenRequest;
  TestLeftRequests;
  TestGroup;
  TestSession;
  TestHandlerThread;
  TestPermission;
  TestTerminal;
  WriteString(StandardOutput, Format('notifytest: %d checks, %d failed'#10, [Checks,
    Failures]));
  if Failures > 0 then
    Halt(1);
  Halt(0);
end.
