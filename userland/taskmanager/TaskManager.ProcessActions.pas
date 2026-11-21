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
  What the task manager does to processes: asks them to end (they may
  save their work first, or refuse), ends them outright (after asking
  the user, since anything not saved is lost), stops and continues
  them (job control) and changes their priority.

  Asking is never the end of it: a program that has stopped responding
  takes the request and never acts on it. One whose windows the display
  server marks as not responding is not asked at all - the user is
  offered to end it outright at once - and one that is still there when
  its wait is over (TaskManager.EndWatch) is offered the same
  (OfferToEndNow).

  The kernel decides who may do what - root anything, a user only to
  their own processes, and only root raises a priority - and the task
  manager says the same before trying (MayActOn), so it can grey out
  what would fail. Whatever fails anyway is told in one message box
  that names each process and why.
}
unit TaskManager.ProcessActions;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Windows,
  Sys.ProcessList,
  TaskManager.Targets;

type
  TProcessTarget = TaskManager.Targets.TProcessTarget;
  TProcessTargets = TaskManager.Targets.TProcessTargets;

const
  { The priorities offered, as nice values: High, Above normal, Normal,
    Below normal, Low. }
  PriorityNiceValues: array[0..4] of LongInt = (-10, -5, 0, 5, 10);
  PriorityCaptions: array[0..4] of string = ('&High', '&Above normal', '&Normal', '&Below normal', '&Low');
  { What a process ended outright exits with: 128 plus KILL's number. }
  EndedOutrightStatus = 137;

{ Whether this user may act on the process: root, or its own. }
function MayActOn(const Details: TProcessDetails): Boolean;
function TargetOf(const Details: TProcessDetails): TProcessTarget;

{ Each asks (or ends, stops...) every target and reports what failed
  in a message box owned by Owner. }
procedure AskToEnd(Owner: TWindow; const Targets: TProcessTargets);
{ Asks the user first; False if they said no. }
function EndNow(Owner: TWindow; const Targets: TProcessTargets): Boolean;
{ Targets were asked to end and have not (or do not respond): offers
  the user to end them outright. }
procedure OfferToEndNow(Owner: TWindow; const Targets: TProcessTargets);
procedure StopTargets(Owner: TWindow; const Targets: TProcessTargets);
procedure ContinueTargets(Owner: TWindow; const Targets: TProcessTargets);
procedure SetTargetsPriority(Owner: TWindow; const Targets: TProcessTargets; Nice: LongInt);

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Kernel,
  Sys.Notifications,
  Sys.Processes,
  Util.Accounts,
  Util.Messages,
  Controls.Dialogs,
  Controls.MessageBoxes,
  TaskManager.EndWatch,
  TaskManager.NotResponding,
  TaskManager.Output;

const
  ProgramName = 'Task Manager';

function MayActOn(const Details: TProcessDetails): Boolean;
begin
  Result := (CurrentUserId = 0) or (Details.RealUserId = CurrentUserId) or (Details.EffectiveUserId = CurrentUserId);
end;

function TargetOf(const Details: TProcessDetails): TProcessTarget;
begin
  Result := MakeTarget(Details.ProcessId, StrPas(@Details.Name[0]));
end;

{ Adds a line about Target's failure to Failures. }
procedure NoteFailure(var Failures: string; const Target: TProcessTarget; Error: LongInt);
var
  Line: string;
begin
  Line := Describe(Target) + ': ' + ErrorText(Error);
  Say('error ' + Line);
  if Failures <> '' then
    Failures := Failures + #10;
  Failures := Failures + Line;
end;

procedure ReportFailures(Owner: TWindow; const What, Failures: string);
begin
  if Failures = '' then
    Exit;
  ShowMessageBox(ProgramName, What + #10#10 + Failures, MessageOk, SignError, Owner);
end;

{ Ends every target outright, without asking anyone. }
procedure EndTargetsNow(Owner: TWindow; const Targets: TProcessTargets);
var
  Index: LongInt;
  Error: LongInt;
  Failures: string;
begin
  Failures := '';
  for Index := 0 to High(Targets) do
  begin
    Error := TerminateProgram(Targets[Index].ProcessId, EndedOutrightStatus);
    if Error = ErrorNone then
    begin
      Say('ended-now ' + IntToStr(Targets[Index].ProcessId));
      WatchEndedOutright(Targets[Index].ProcessId);
    end
    else
      NoteFailure(Failures, Targets[Index], Error);
  end;
  ReportFailures(Owner, 'Could not end these:', Failures);
end;

{ "NAME (PID)" for one target, "these N processes" for more. }
function DescribeAll(const Targets: TProcessTargets): string;
begin
  if Length(Targets) = 1 then
    Result := Describe(Targets[0])
  else
    Result := 'These ' + IntToStr(Length(Targets)) + ' processes';
end;

procedure OfferToEndNow(Owner: TWindow; const Targets: TProcessTargets);
var
  Index: LongInt;
  Question: string;
  Answer: LongInt;
begin
  if Length(Targets) = 0 then
    Exit;
  for Index := 0 to High(Targets) do
    Say('not-responding ' + IntToStr(Targets[Index].ProcessId));
  if Length(Targets) = 1 then
    Question := DescribeAll(Targets) + ' did not end when asked.' + #10#10 +
      'It may have stopped responding. End it now?' + #10 + 'Anything it has not saved is lost.'
  else
    Question := DescribeAll(Targets) + ' did not end when asked.' + #10#10 +
      'They may have stopped responding. End them now?' + #10 + 'Anything they have not saved is lost.';
  Answer := ShowMessageBox(ProgramName, Question, MessageYesNo, SignWarning, Owner);
  if Answer = ResultYes then
    EndTargetsNow(Owner, Targets)
  else
    Say('end-now cancelled');
end;

{ Targets not responding: asking them is no use, so the user is offered
  to end them outright at once. }
procedure OfferToEndUnresponsive(Owner: TWindow; const Targets: TProcessTargets);
var
  Index: LongInt;
  Question: string;
begin
  if Length(Targets) = 0 then
    Exit;
  for Index := 0 to High(Targets) do
    Say('not-responding ' + IntToStr(Targets[Index].ProcessId));
  if Length(Targets) = 1 then
    Question := DescribeAll(Targets) + ' is not responding, so it cannot be asked to end.' + #10#10 +
      'End it now?' + #10 + 'Anything it has not saved is lost.'
  else
    Question := DescribeAll(Targets) + ' are not responding, so they cannot be asked to end.' + #10#10 +
      'End them now?' + #10 + 'Anything they have not saved is lost.';
  if ShowMessageBox(ProgramName, Question, MessageYesNo, SignWarning, Owner) = ResultYes then
    EndTargetsNow(Owner, Targets)
  else
    Say('end-now cancelled');
end;

procedure AskToEnd(Owner: TWindow; const Targets: TProcessTargets);
var
  Index: LongInt;
  Error: LongInt;
  Failures: string;
  Unresponsive: TProcessTargets;
begin
  Failures := '';
  Unresponsive := nil;
  for Index := 0 to High(Targets) do
  begin
    if IsNotResponding(Targets[Index].ProcessId) then
    begin
      AddTarget(Unresponsive, Targets[Index]);
      Continue;
    end;
    Error := AskProcessToEnd(Targets[Index].ProcessId, EndReasonAsked);
    if Error = ErrorNone then
    begin
      Say('asked ' + IntToStr(Targets[Index].ProcessId));
      WatchAskedToEnd(Targets[Index]);
    end
    else
      NoteFailure(Failures, Targets[Index], Error);
  end;
  ReportFailures(Owner, 'Could not ask these to end:', Failures);
  OfferToEndUnresponsive(Owner, Unresponsive);
end;

function EndNow(Owner: TWindow; const Targets: TProcessTargets): Boolean;
var
  Question: string;
begin
  if Length(Targets) = 0 then
    Exit(False);
  if Length(Targets) = 1 then
    Question := 'End ' + Describe(Targets[0]) + ' now?'
  else
    Question := 'End these ' + IntToStr(Length(Targets)) + ' processes now?';
  Question := Question + #10#10 + 'It is not asked first, so anything it has not saved is lost.';
  if ShowMessageBox(ProgramName, Question, MessageYesNo, SignWarning, Owner) <> ResultYes then
  begin
    Say('end-now cancelled');
    Exit(False);
  end;
  EndTargetsNow(Owner, Targets);
  Result := True;
end;

procedure StopTargets(Owner: TWindow; const Targets: TProcessTargets);
var
  Index: LongInt;
  Error: LongInt;
  Failures: string;
begin
  Failures := '';
  for Index := 0 to High(Targets) do
  begin
    Error := StopPrograms(Int64(Targets[Index].ProcessId));
    if Error = ErrorNone then
      Say('stopped ' + IntToStr(Targets[Index].ProcessId))
    else
      NoteFailure(Failures, Targets[Index], Error);
  end;
  ReportFailures(Owner, 'Could not stop these:', Failures);
end;

procedure ContinueTargets(Owner: TWindow; const Targets: TProcessTargets);
var
  Index: LongInt;
  Error: LongInt;
  Failures: string;
begin
  Failures := '';
  for Index := 0 to High(Targets) do
  begin
    Error := ContinuePrograms(Int64(Targets[Index].ProcessId));
    if Error = ErrorNone then
      Say('continued ' + IntToStr(Targets[Index].ProcessId))
    else
      NoteFailure(Failures, Targets[Index], Error);
  end;
  ReportFailures(Owner, 'Could not continue these:', Failures);
end;

procedure SetTargetsPriority(Owner: TWindow; const Targets: TProcessTargets; Nice: LongInt);
var
  Index: LongInt;
  Error: LongInt;
  Failures: string;
begin
  Failures := '';
  for Index := 0 to High(Targets) do
  begin
    Error := ErrorCodeOf(KernelSetPriority(Targets[Index].ProcessId, Nice));
    if Error = ErrorNone then
      Say('priority ' + IntToStr(Targets[Index].ProcessId) + ' ' + IntToStr(Nice))
    else
      NoteFailure(Failures, Targets[Index], Error);
  end;
  ReportFailures(Owner, 'Could not change the priority of these (only root may raise one):', Failures);
end;

end.
