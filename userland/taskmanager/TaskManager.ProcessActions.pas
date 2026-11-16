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
  Sys.ProcessList;

type
  TProcessTarget = record
    ProcessId: QWord;
    Name: string;
  end;
  TProcessTargets = array of TProcessTarget;

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
  Controls.Dialogs,
  Controls.MessageBoxes,
  TaskManager.EndWatch,
  TaskManager.Output;

const
  ProgramName = 'Task Manager';

function MayActOn(const Details: TProcessDetails): Boolean;
begin
  Result := (CurrentUserId = 0) or (Details.RealUserId = CurrentUserId) or (Details.EffectiveUserId = CurrentUserId);
end;

function TargetOf(const Details: TProcessDetails): TProcessTarget;
begin
  Result.ProcessId := Details.ProcessId;
  Result.Name := StrPas(@Details.Name[0]);
end;

function Describe(const Target: TProcessTarget): string;
begin
  Result := Target.Name + ' (' + IntToStr(Target.ProcessId) + ')';
end;

{ Adds a line about Target's failure to Failures. }
procedure NoteFailure(var Failures: string; const Target: TProcessTarget; Error: LongInt);
var
  Line: string;
begin
  Line := Describe(Target) + ': ' + StrPas(ErrorMessage(Error));
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

procedure AskToEnd(Owner: TWindow; const Targets: TProcessTargets);
var
  Index: LongInt;
  Error: LongInt;
  Failures: string;
begin
  Failures := '';
  for Index := 0 to High(Targets) do
  begin
    Error := AskProcessToEnd(Targets[Index].ProcessId, EndReasonAsked);
    if Error = ErrorNone then
    begin
      Say('asked ' + IntToStr(Targets[Index].ProcessId));
      WatchForEnd(Targets[Index].ProcessId);
    end
    else
      NoteFailure(Failures, Targets[Index], Error);
  end;
  ReportFailures(Owner, 'Could not ask these to end:', Failures);
end;

function EndNow(Owner: TWindow; const Targets: TProcessTargets): Boolean;
var
  Index: LongInt;
  Error: LongInt;
  Failures: string;
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
  Failures := '';
  for Index := 0 to High(Targets) do
  begin
    Error := TerminateProgram(Targets[Index].ProcessId, EndedOutrightStatus);
    if Error = ErrorNone then
    begin
      Say('ended-now ' + IntToStr(Targets[Index].ProcessId));
      WatchForEnd(Targets[Index].ProcessId);
    end
    else
      NoteFailure(Failures, Targets[Index], Error);
  end;
  ReportFailures(Owner, 'Could not end these:', Failures);
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
