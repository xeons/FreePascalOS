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
  servicetest - checks the service manager and the service command

  servicetest

  Run by coretest (as root). Works in /tmp/servicetest:

    * definitions: servicemanager --check reads a good file (every
      setting) and wrong ones (an unknown setting, a bad value, no
      program, a need that does not exist, needs in a circle, a need
      that cannot start), and gives the start order of a mode (after
      what each needs, with a need outside the mode pulled in);
    * a second manager (port "servicetest") running test services: one
      that says it is ready after half a second and one that needs it
      (started only once it is ready), one that always fails (started
      again twice, then left failed, three starts in its log), one that
      writes a line and ends (in its log, stopped), one not ready in
      time (ended, failed), one running as the ordinary user, one only
      started by hand;
    * the service command: list, status, start, stop and restart (a new
      process), refused for an ordinary user, an unknown name; readiness
      refused from outside the service; stopping a service ends what it
      started (its session).

  Each check prints a line; the exit status is 1 if any failed.
}
program ServiceTest;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Classes,
  Abi.SystemCalls,
  Sys.Format,
  Sys.Files,
  Sys.Processes,
  Sys.ServiceControl,
  Sys.Streams,
  Sys.Time,
  Util.FileTree;

const
  WorkDirectory = '/tmp/servicetest';
  TestPort = 'servicetest';
  SettleTimeoutMilliseconds = 15000;

var
  Failures: Integer = 0;
  Checks: Integer = 0;
  Manager: Int64 = NoHandle;

procedure Check(const Name: string; Passed: Boolean);
begin
  Inc(Checks);
  if Passed then
    WriteFormatted(StandardOutput, 'servicetest: pass: %s'#10, [ArgumentText(PChar(Name))])
  else
  begin
    WriteFormatted(StandardOutput, 'servicetest: FAIL: %s'#10, [ArgumentText(PChar(Name))]);
    Inc(Failures);
  end;
  FlushStream(StandardOutput);
end;

procedure Note(const Text: string);
begin
  WriteFormatted(StandardOutput, 'servicetest: %s'#10, [ArgumentText(PChar(Text))]);
  FlushStream(StandardOutput);
end;

procedure WriteTextFile(const Path, Contents: string);
var
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.Text := Contents;
    Lines.SaveToFile(Path);
  finally
    Lines.Free;
  end;
end;

function ReadTextFile(const Path: string): string;
var
  Lines: TStringList;
begin
  Result := '';
  if not FileExists(Path) then
    Exit;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(Path);
    Result := Lines.Text;
  finally
    Lines.Free;
  end;
end;

{ Runs CommandLine through sh; its output (and errors) and status. }
function RunCommand(const CommandLine: string; out Output: string): LongInt;
var
  Arguments: array[0..3] of PChar;
  Line: string;
begin
  Line := CommandLine + ' > ' + WorkDirectory + '/command.out 2>&1';
  Arguments[0] := '/bin/sh';
  Arguments[1] := '-c';
  Arguments[2] := PChar(Line);
  Arguments[3] := nil;
  Result := RunProgram('/bin/sh', @Arguments[0]);
  Output := ReadTextFile(WorkDirectory + '/command.out');
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

{ --- Definitions ------------------------------------------------------ }

procedure TestDefinitions;
var
  Directory: string;
  Output: string;
  Status: LongInt;
begin
  Directory := WorkDirectory + '/definitions';
  CreateDirectory(PChar(Directory));
  WriteTextFile(Directory + '/good.service',
    '# every setting'#10 +
    'description = A good one'#10 +
    'program = /bin/sleep'#10 +
    'arguments = 30 "two words"'#10 +
    'user = user'#10 +
    '   modes   =   test other   '#10 +
    'restart = always'#10 +
    'restart-limit = 0'#10 +
    'restart-delay = 0.25'#10 +
    'ready = notify'#10 +
    'ready-timeout = 2'#10 +
    'console = no'#10);
  WriteTextFile(Directory + '/badvalue.service', 'program = /bin/true'#10'restart = sometimes'#10);
  WriteTextFile(Directory + '/noprogram.service', 'description = nothing to run'#10);
  WriteTextFile(Directory + '/unknown.service', 'program = /bin/true'#10'colour = blue'#10);
  WriteTextFile(Directory + '/orphan.service', 'program = /bin/true'#10'needs = missing'#10);
  WriteTextFile(Directory + '/round1.service', 'program = /bin/true'#10'needs = round2'#10);
  WriteTextFile(Directory + '/round2.service', 'program = /bin/true'#10'needs = round1'#10);
  WriteTextFile(Directory + '/after.service', 'program = /bin/true'#10'needs = badvalue'#10);
  Status := RunCommand('servicemanager --check --mode test --directory ' + Directory, Output);
  Check('--check succeeds', Status = 0);
  Check('a good definition, every setting read',
    Pos('service good: program /bin/sleep, arguments 30 two words, user user, needs -, modes test other, ' +
      'restart always (limit 0, delay 250 ms), ready notify (timeout 2000 ms), output log', Output) > 0);
  Check('a bad value names its line',
    Pos('problem badvalue: line 2: restart is never, on-failure or always', Output) > 0);
  Check('a definition without a program', Pos('problem noprogram: no program is named', Output) > 0);
  Check('an unknown setting', Pos('problem unknown: line 2: unknown setting "colour"', Output) > 0);
  Check('a need that does not exist', Pos('problem orphan: needs missing, which does not exist', Output) > 0);
  Check('needs in a circle', (Pos('problem round1: its needs go round in a circle', Output) > 0) and
    (Pos('problem round2: its needs go round in a circle', Output) > 0));
  Check('a need that cannot start', Pos('problem after: needs badvalue, which cannot start', Output) > 0);
  Check('only good services in the order', Pos('order test: good'#10, Output) > 0);
  if Failures > 0 then
    Note('received: ' + Output);
end;

procedure TestOrder;
var
  Directory: string;
  Output: string;
begin
  Directory := WorkDirectory + '/order';
  CreateDirectory(PChar(Directory));
  WriteTextFile(Directory + '/a.service', 'program = /bin/true'#10'needs = b'#10'modes = test'#10);
  WriteTextFile(Directory + '/b.service', 'program = /bin/true'#10'needs = c'#10'modes = test'#10);
  WriteTextFile(Directory + '/c.service', 'program = /bin/true'#10'modes = other'#10);
  WriteTextFile(Directory + '/d.service', 'program = /bin/true'#10'modes = test other'#10);
  WriteTextFile(Directory + '/e.service', 'program = /bin/true'#10'needs = a d'#10'modes = test'#10);
  WriteTextFile(Directory + '/f.service', 'program = /bin/true'#10'modes = other'#10);
  RunCommand('servicemanager --check --mode test --directory ' + Directory, Output);
  Check('the start order follows the needs, and pulls a need in from another mode',
    Pos('order test: c d b a e'#10, Output) > 0);
  RunCommand('servicemanager --check --mode other --directory ' + Directory, Output);
  Check('another mode has its own order', Pos('order other: c d f'#10, Output) > 0);
  { No mode= among coretest's kernel options: graphical. }
  RunCommand('servicemanager --check --directory ' + Directory, Output);
  Check('the boot mode is graphical without mode=', Pos('order graphical: -'#10, Output) > 0);
end;

{ --- A running manager -------------------------------------------------- }

procedure WriteRunningServices(const Directory: string);
begin
  CreateDirectory(PChar(Directory));
  WriteTextFile(Directory + '/first.service',
    'description = Ready after half a second'#10 +
    'program = /bin/sh'#10 +
    'arguments = -c "sleep 0.5; service ready; sleep 30"'#10 +
    'ready = notify'#10 +
    'modes = test'#10);
  WriteTextFile(Directory + '/second.service',
    'program = /bin/sleep'#10'arguments = 30'#10'needs = first'#10'modes = test'#10);
  WriteTextFile(Directory + '/failing.service',
    'program = /bin/false'#10'restart = on-failure'#10'restart-limit = 2'#10'restart-delay = 0.2'#10 +
    'modes = test'#10);
  WriteTextFile(Directory + '/echo.service',
    'program = /bin/sh'#10'arguments = -c "echo hello from echo"'#10'restart = never'#10'modes = test'#10);
  WriteTextFile(Directory + '/slow.service',
    'program = /bin/sleep'#10'arguments = 30'#10'ready = notify'#10'ready-timeout = 0.5'#10 +
    'restart = never'#10'modes = test'#10);
  WriteTextFile(Directory + '/asuser.service',
    'program = /bin/sh'#10'arguments = -c "id > ' + WorkDirectory + '/asuser.txt; sleep 30"'#10 +
    'user = user'#10'modes = test'#10);
  WriteTextFile(Directory + '/manual.service', 'program = /bin/sleep'#10'arguments = 30'#10);
end;

function StatusOf(const Name: string; out Status: TServiceStatus): Boolean;
var
  Reply: TServiceReply;
begin
  Result := (AskServiceManager(TestPort, ServiceRequestStatus, PChar(Name), Reply) = ErrorNone) and
    (Reply.Error = ErrorNone) and (Reply.Count = 1);
  if Result then
    Status := Reply.Services[0]
  else
    FillChar(Status, SizeOf(Status), 0);
end;

function StateOf(const Name: string): LongWord;
var
  Status: TServiceStatus;
begin
  if StatusOf(Name, Status) then
    Result := Status.State
  else
    Result := High(LongWord);
end;

{ Waits until service Name is in State; False on timeout. }
function WaitForState(const Name: string; State: LongWord): Boolean;
var
  Deadline: QWord;
begin
  Deadline := UptimeMilliseconds + SettleTimeoutMilliseconds;
  repeat
    if StateOf(Name) = State then
      Exit(True);
    SleepMilliseconds(50);
  until UptimeMilliseconds > Deadline;
  Result := False;
end;

function StartManager(const Directory: string): Boolean;
var
  Arguments: array[0..9] of PChar;
  Options: TProcessOptions;
  Output: Int64;
  Reply: TServiceReply;
  Deadline: QWord;
begin
  Arguments[0] := '/bin/servicemanager';
  Arguments[1] := '--mode=test';
  Arguments[2] := PChar('--directory=' + Directory);
  Arguments[3] := PChar('--log-directory=' + WorkDirectory + '/logs');
  Arguments[4] := '--port=' + TestPort;
  Arguments[5] := nil;
  Output := OpenFile(PChar(WorkDirectory + '/manager.out'), OpenWrite or OpenCreate or OpenTruncate);
  DefaultProcessOptions(Options);
  Options.OutputHandle := Output;
  Options.ErrorHandle := Output;
  Options.GroupId := GroupNew;
  Manager := StartProgram('/bin/servicemanager', @Arguments[0], Options);
  CloseFile(Output);
  if Manager < 0 then
    Exit(False);
  Deadline := UptimeMilliseconds + 5000;
  repeat
    if AskServiceManager(TestPort, ServiceRequestList, nil, Reply) = ErrorNone then
      Exit(True);
    SleepMilliseconds(50);
  until UptimeMilliseconds > Deadline;
  Result := False;
end;

procedure TestRunningServices;
var
  First, Second, Failing, Echo, Slow, AsUser, Manual: TServiceStatus;
begin
  Check('the second manager answers', StartManager(WorkDirectory + '/running'));
  Check('a service that says it is ready runs', WaitForState('first', ServiceStateRunning));
  Check('the service that needs it runs', WaitForState('second', ServiceStateRunning));
  Check('a service failing every time is left failed', WaitForState('failing', ServiceStateFailed));
  Check('a service that ended by itself is stopped', WaitForState('echo', ServiceStateStopped));
  Check('a service not ready in time fails', WaitForState('slow', ServiceStateFailed));
  Check('a service of another user runs', WaitForState('asuser', ServiceStateRunning));
  StatusOf('first', First);
  StatusOf('second', Second);
  StatusOf('failing', Failing);
  StatusOf('echo', Echo);
  StatusOf('slow', Slow);
  StatusOf('asuser', AsUser);
  StatusOf('manual', Manual);
  Check('readiness came after half a second', (First.ReadyAt >= First.StartedAt + 400) and (First.InBootMode = 1));
  Check('the service that needs it started once it was ready', Second.StartedAt >= First.ReadyAt);
  Check('the failing service was started again twice', (Failing.Restarts = 2) and (Failing.HasEnded = 1) and
    (Failing.LastExitCode = 1));
  Check('its log shows three starts',
    CountOf('--- starting /bin/false ---', ReadTextFile(WorkDirectory + '/logs/failing.log')) = 3);
  Check('output goes to the log', Pos('hello from echo', ReadTextFile(WorkDirectory + '/logs/echo.log')) > 0);
  Check('an ended service has its status', (Echo.HasEnded = 1) and (Echo.LastExitCode = 0) and (Echo.Restarts = 0));
  Check('a service not ready in time was ended', (Slow.HasEnded = 1) and (Slow.LastExitCode = 143));
  Check('a service runs as its user with that user''s groups',
    Pos('uid=1000(user) gid=1000(user) groups=1000(user)', ReadTextFile(WorkDirectory + '/asuser.txt')) > 0);
  Check('a service of no mode waits to be started', (Manual.State = ServiceStateStopped) and (Manual.InBootMode = 0));
  Check('the manager logs what it did', Pos('failing ended with status 1; gave up after 2 restarts',
    ReadTextFile(WorkDirectory + '/logs/servicemanager.log')) > 0);
end;

procedure TestServiceCommand;
var
  Output: string;
  Status: LongInt;
  Before: TServiceStatus;
  After: TServiceStatus;
  Reply: TServiceReply;
  OldFirst: QWord;
begin
  Status := RunCommand('service -p ' + TestPort + ' list', Output);
  Check('service list', (Status = 0) and (Pos('NAME', Output) = 1) and (Pos('first ', Output) > 0) and
    (Pos('Ready after half a second', Output) > 0));
  Status := RunCommand('service -p ' + TestPort + ' status failing', Output);
  Check('service status', (Status = 0) and (Pos('failing'#10'  state: failed'#10, Output) = 1) and
    (Pos('  restarts: 2', Output) > 0) and (Pos('  last ended: with status 1', Output) > 0));
  Status := RunCommand('service -p ' + TestPort + ' status nosuch', Output);
  Check('an unknown service', (Status = 1) and (Pos('no service is called nosuch', Output) > 0));
  Status := RunCommand('service -p ' + TestPort + ' start manual', Output);
  Check('service start', (Status = 0) and WaitForState('manual', ServiceStateRunning));
  Status := RunCommand('service -p ' + TestPort + ' stop manual', Output);
  Check('service stop', (Status = 0) and WaitForState('manual', ServiceStateStopped));
  StatusOf('second', Before);
  Status := RunCommand('service -p ' + TestPort + ' restart second', Output);
  SleepMilliseconds(300);
  Check('service restart', (Status = 0) and WaitForState('second', ServiceStateRunning) and StatusOf('second', After) and
    (After.ProcessId <> 0) and (After.ProcessId <> Before.ProcessId));
  Status := RunCommand('su user -c "service -p ' + TestPort + ' stop second"', Output);
  Check('an ordinary user may not stop a service', (Status = 1) and (Pos('Operation not permitted', Output) > 0) and
    (StateOf('second') = ServiceStateRunning));
  Status := RunCommand('su user -c "service -p ' + TestPort + ' status second"', Output);
  Check('an ordinary user may ask', (Status = 0) and (Pos('state: running', Output) > 0));
  Check('readiness is refused from outside the service',
    (AskServiceManager(TestPort, ServiceRequestReady, 'second', Reply) = ErrorNone) and
    (Reply.Error = ErrorNotPermitted));
  { first is a shell running sleep: stopping it ends both. }
  StatusOf('first', Before);
  OldFirst := Before.ProcessId;
  Check('first had a program running in its session', SessionHasProcesses(OldFirst));
  RunCommand('service -p ' + TestPort + ' stop first', Output);
  Check('stopping a service ends its session', WaitForState('first', ServiceStateStopped) and
    not SessionHasProcesses(OldFirst));
end;

procedure StopEverything;
var
  Reply: TServiceReply;
  ExitCode: LongInt;
begin
  AskServiceManager(TestPort, ServiceRequestStop, 'second', Reply);
  AskServiceManager(TestPort, ServiceRequestStop, 'asuser', Reply);
  AskServiceManager(TestPort, ServiceRequestStop, 'first', Reply);
  WaitForState('second', ServiceStateStopped);
  WaitForState('asuser', ServiceStateStopped);
  if Manager >= 0 then
  begin
    TerminateProgram(QWord(ProcessIdOf(Manager)), 143);
    WaitForProgramWithTimeout(Manager, 5000, ExitCode);
  end;
end;

begin
  if PathExists(WorkDirectory) then
    RemoveTree(WorkDirectory);
  CreateDirectory(WorkDirectory);
  CreateDirectory(WorkDirectory + '/logs');
  { The ordinary user's service writes here. }
  ChangeMode(WorkDirectory, $1FF);
  TestDefinitions;
  TestOrder;
  WriteRunningServices(WorkDirectory + '/running');
  TestRunningServices;
  TestServiceCommand;
  StopEverything;
  WriteFormatted(StandardOutput, 'servicetest: %d checks, %d failed'#10, [ArgumentNumber(Checks),
    ArgumentNumber(Failures)]);
  if Failures > 0 then
    Halt(1);
  RemoveTree(WorkDirectory);
  Halt(0);
end.
