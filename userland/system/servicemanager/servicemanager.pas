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
  servicemanager - the first program: starts the services and keeps
  them running

  servicemanager [--mode MODE] [--directory DIRECTORY] [--log-directory DIRECTORY]
                 [--port NAME] [--check]

  The kernel starts it when no init= option names another program. It
  reads every service definition in /etc/services (Services.Definitions
  has the format), starts the services of the boot mode in the order of
  what they need (independent ones together), waiting for a service to
  be ready before starting those that need it, starts failed ones again
  as their restart policy says, keeps their output in /var/log/NAME.log,
  and serves the port "servicemanager" for the `service` command. When
  the system shuts down (the kernel signals the event it watches), it
  stops the services in the reverse order and ends, and the kernel does
  the rest. Stopping a service asks its programs to end (they may tidy
  up), and ends them outright after the service's stop-timeout.

  The boot mode is --mode, else the kernel option mode=, else
  "graphical": the display server and the session (a login on the
  screen, then the desktop), with a login on the serial console for
  debugging. "text" has a login on the console (the screen and the
  serial port). A service belongs to the modes its file lists.

    --mode MODE                the boot mode
    --directory DIRECTORY      where the definitions are (/etc/services)
    --log-directory DIRECTORY  where the logs go (/var/log)
    --port NAME                the port to serve (servicemanager)
    --check                    only read the definitions: print each,
                               its problem if it has one, and the start
                               order of the mode, then end

  A second manager (for tests: another directory and port) runs its
  services until it is asked to end, when it stops them in order as at
  a shutdown; only the first program, which the kernel started, watches
  for shutdowns.

  The units are in userland/servicemanager: Services.Definitions (the
  files), Services.Catalog (the table, needs and order), Services.Launch
  (starting a program), Services.Supervisor (states, restarts,
  readiness), Services.Shutdown (stopping in order), Services.Control
  (the port), Services.Logs and Services.Manager (the loop).
}
program servicemanager;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.KernelOptions,
  Sys.Kernel,
  Sys.Processes,
  Sys.ServiceControl,
  Sys.Streams,
  Util.CommandLine,
  Util.Messages,
  Services.Definitions,
  Services.Catalog,
  Services.Control,
  Services.Launch,
  Services.Logs,
  Services.Mounts,
  Services.Manager;

const
  Usage = 'Usage: servicemanager [OPTION]...'#10 +
    'Start the services of the boot mode and keep them running.'#10#10 +
    '      --mode=MODE                the boot mode (default: the kernel option mode=, or graphical)'#10 +
    '      --directory=DIRECTORY      the service definitions (/etc/services)'#10 +
    '      --log-directory=DIRECTORY  the logs (/var/log)'#10 +
    '      --port=NAME                the port to serve (servicemanager)'#10 +
    '      --check                    print the definitions and the start order, start nothing'#10;
  DefaultServiceDirectory = '/etc/services';
  DefaultBootMode = 'graphical';
  ModeOption = 'mode';
  OptionMode = 1;
  OptionDirectory = 2;
  OptionLogDirectory = 3;
  OptionPort = 4;
  OptionCheck = 5;

var
  RequestedMode: string;
  ServiceDirectory: string;
  CheckOnly: Boolean;

procedure ReadOptions;
var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
begin
  RequestedMode := '';
  ServiceDirectory := DefaultServiceDirectory;
  ControlPortName := ServiceManagerPortName;
  CheckOnly := False;
  CommandLine := TCommandLine.Create([
    CommandOption(#0, 'mode', True, OptionMode),
    CommandOption(#0, 'directory', True, OptionDirectory),
    CommandOption(#0, 'log-directory', True, OptionLogDirectory),
    CommandOption(#0, 'port', True, OptionPort),
    CommandOption(#0, 'check', False, OptionCheck)], Usage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionMode: RequestedMode := Value;
      OptionDirectory: ServiceDirectory := Value;
      OptionLogDirectory: LogDirectory := Value;
      OptionPort: ControlPortName := Value;
      OptionCheck: CheckOnly := True;
    end;
  if CommandLine.OperandCount > 0 then
    FailWithUsageHint('no operands are taken');
  CommandLine.Free;
end;

function ChooseBootMode: string;
var
  Value: string;
begin
  if RequestedMode <> '' then
    Exit(RequestedMode);
  if GetKernelOption(ModeOption, Value) and (Value <> '') then
    Exit(Value);
  Result := DefaultBootMode;
end;

procedure Print(const Text: string);
begin
  PrintStringLine(Text);
end;

function JoinWords(const Words: array of string): string;
var
  Index: LongInt;
begin
  Result := '';
  for Index := 0 to High(Words) do
  begin
    if Index > 0 then
      Result := Result + ' ';
    Result := Result + Words[Index];
  end;
  if Result = '' then
    Result := '-';
end;

function DescribeOutput(const Definition: TServiceDefinition): string;
begin
  if Definition.OnConsole then
    Result := 'console'
  else
    Result := 'log';
end;

procedure PrintDefinitions(const BootMode: string);
var
  Index: LongInt;
  Definition: TServiceDefinition;
  Order: TServiceList;
  Names: array of string;
begin
  for Index := 0 to High(ServiceTable) do
  begin
    Definition := ServiceTable[Index].Definition;
    if ServiceTable[Index].Problem <> '' then
    begin
      Print('problem ' + Definition.Name + ': ' + ServiceTable[Index].Problem);
      Continue;
    end;
    Print(Format('service %s: program %s, arguments %s, user %s, needs %s, modes %s, ' +
      'restart %s (limit %d, delay %d ms), ready %s (timeout %d ms), stop timeout %d ms, output %s',
      [Definition.Name, Definition.ProgramPath, JoinWords(Definition.Arguments), Definition.UserName,
       JoinWords(Definition.Needs), JoinWords(Definition.Modes), RestartPolicyName(Definition.Restart),
       Definition.RestartLimit, Definition.RestartDelayMilliseconds, ReadinessName(Definition.Readiness),
       Definition.ReadyTimeoutMilliseconds, Definition.StopTimeoutMilliseconds, DescribeOutput(Definition)]));
  end;
  Order := StartOrder(BootMode);
  SetLength(Names, Length(Order));
  for Index := 0 to High(Order) do
    Names[Index] := Order[Index].Definition.Name;
  Print('order ' + BootMode + ': ' + JoinWords(Names));
end;

{ True for the first program, which the kernel started (it has no
  parent). }
function IsFirstProgram: Boolean;
var
  Information: TAbiProcessInformation;
  Index: QWord;
  Own: QWord;
begin
  Own := QWord(CurrentProcessId);
  Index := 0;
  while KernelListProcesses(Index, Information) >= 0 do
  begin
    if Information.ProcessId = Own then
      Exit(Information.ParentProcessId = 0);
    Inc(Index);
  end;
  Result := False;
end;

{ The kernel's shutdown event; NoHandle for a second manager (tests),
  which leaves shutting down to the first. }
function WatchForShutdown: Int64;
begin
  if not IsFirstProgram then
    Exit(NoHandle);
  Result := KernelWatchShutdown;
  if Result < 0 then
    Result := NoHandle;
end;

var
  BootMode: string;
  ShutdownEvent: Int64;
  Error: LongInt;
begin
  ReadOptions;
  BootMode := ChooseBootMode;
  LoadServices(ServiceDirectory);
  if CheckOnly then
  begin
    PrintDefinitions(BootMode);
    FlushStream(StandardOutput);
    Halt(0);
  end;
  { Ctrl-C on the console is for the programs there, never the manager. }
  IgnoreInterrupts(True);
  PrepareLogDirectory;
  Error := OpenControlPort(ControlPortName);
  if Error <> ErrorNone then
    FailWithError(1, Error, 'the port ' + ControlPortName);
  ShutdownEvent := WatchForShutdown;
  { The first manager mounts what /etc/fstab says before any service. }
  if ShutdownEvent <> NoHandle then
    MountFileSystems;
  Say('boot mode ' + BootMode + ', ' + IntToStr(Length(ServiceTable)) + ' services in ' + ServiceDirectory);
  RunServices(BootMode, ShutdownEvent);
  Halt(0);
end.
