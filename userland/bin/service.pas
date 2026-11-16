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
  service - ask the service manager about the services, or change them

  service [-p PORT] list
  service [-p PORT] status NAME
  service [-p PORT] start|stop|restart NAME
  service ready

  list prints every service: its name, state, process, restarts and
  description. status prints one in full. start (with what it needs),
  stop and restart are for root. ready, run by a service (or a script it
  runs), tells the manager the service is ready (Sys.ServiceControl);
  outside a service it does nothing. -p talks to the manager serving
  another port (a second manager, for tests).

  Exits with 0, or 1 when the manager refused or could not be reached.
}
program service;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.ServiceControl,
  Sys.Streams,
  Util.CommandLine,
  Util.Messages;

const
  Usage = 'Usage: service [-p PORT] list'#10 +
    '       service [-p PORT] status NAME'#10 +
    '       service [-p PORT] start|stop|restart NAME'#10 +
    '       service ready'#10 +
    'Ask the service manager about the services, or start and stop them (root).'#10#10 +
    '  -p, --port=PORT  the manager''s port (servicemanager)'#10;
  OptionPort = 1;
  StatusFailed = 1;

var
  { The manager's port; the system's when not given. }
  PortName: string;
  Command: string;
  ServiceName: string;

procedure ReadOptions;
var
  CommandLine: TCommandLine;
begin
  CommandLine := TCommandLine.Create([CommandOption('p', 'port', True, OptionPort)], Usage);
  try
    CommandLine.ReadOperandsOnly;
    PortName := CommandLine.OptionValue(OptionPort);
    if CommandLine.OperandCount = 0 then
      FailWithUsageHint('a command is needed');
    Command := CommandLine.Operands[0];
    ServiceName := '';
    if CommandLine.OperandCount > 1 then
      ServiceName := CommandLine.Operands[1];
    if CommandLine.OperandCount > 2 then
      FailWithUsageHint(Format('extra operand ''%s''', [CommandLine.Operands[2]]));
  finally
    CommandLine.Free;
  end;
end;

function SecondsText(Milliseconds: QWord): string;
begin
  Result := Format('%d.%.3d s', [Milliseconds div 1000, Milliseconds mod 1000]);
end;

procedure PrintList(const Reply: TServiceReply);
var
  Index: LongWord;
  Status: TServiceStatus;
  ProcessText: string;
begin
  PrintStringLine(Format('%-16s %-11s %7s %8s  %s', ['NAME', 'STATE', 'PID', 'RESTARTS', 'DESCRIPTION']));
  Index := 0;
  while Index < Reply.Count do
  begin
    Status := Reply.Services[Index];
    if Status.ProcessId <> 0 then
      ProcessText := IntToStr(Status.ProcessId)
    else
      ProcessText := '-';
    PrintStringLine(Format('%-16s %-11s %7s %8d  %s', [string(PChar(@Status.Name[0])),
      ServiceStateName(Status.State), ProcessText, Status.Restarts,
      string(PChar(@Status.Description[0]))]));
    Inc(Index);
  end;
end;

procedure PrintStatus(const Status: TServiceStatus);
var
  Line: string;
begin
  Line := string(PChar(@Status.Name[0]));
  if Status.Description[0] <> #0 then
    Line := Line + ' - ' + string(PChar(@Status.Description[0]));
  PrintStringLine(Line);
  Line := '  state: ' + ServiceStateName(Status.State);
  if (Status.State = ServiceStateRunning) and (Status.ReadyAt >= Status.StartedAt) then
    Line := Line + ' (ready after ' + SecondsText(Status.ReadyAt - Status.StartedAt) + ')';
  PrintStringLine(Line);
  if Status.ProcessId <> 0 then
    PrintStringLine('  process: ' + IntToStr(Status.ProcessId));
  if Status.InBootMode <> 0 then
    PrintStringLine('  boot mode: yes')
  else
    PrintStringLine('  boot mode: no');
  PrintStringLine('  restarts: ' + IntToStr(Status.Restarts));
  if Status.HasEnded <> 0 then
    PrintStringLine('  last ended: with status ' + IntToStr(Status.LastExitCode));
  if Status.Reason[0] <> #0 then
    PrintStringLine('  note: ' + string(PChar(@Status.Reason[0])));
end;

function RequestCode: LongWord;
begin
  if Command = 'list' then
    Result := ServiceRequestList
  else if Command = 'status' then
    Result := ServiceRequestStatus
  else if Command = 'start' then
    Result := ServiceRequestStart
  else if Command = 'stop' then
    Result := ServiceRequestStop
  else if Command = 'restart' then
    Result := ServiceRequestRestart
  else
  begin
    FailWithUsageHint(Format('unknown command ''%s''', [Command]));
    Result := 0;
  end;
end;

var
  Code: LongWord;
  Reply: TServiceReply;
  Error: LongInt;
begin
  ReadOptions;
  if Command = 'ready' then
  begin
    NotifyServiceReady;
    Halt(0);
  end;
  Code := RequestCode;
  if (Code <> ServiceRequestList) and (ServiceName = '') then
    FailWithUsageHint(Command + ' needs the name of a service');
  Error := AskServiceManager(PortName, Code, ServiceName, Reply);
  if Error <> ErrorNone then
    FailWithError(StatusFailed, Error, 'the service manager');
  if Reply.Error <> ErrorNone then
  begin
    if Reply.Error = ErrorNotFound then
      Fail(StatusFailed, 'no service is called ' + ServiceName);
    FailWithError(StatusFailed, Reply.Error, Format('cannot %s %s', [Command, ServiceName]));
  end;
  if Code = ServiceRequestList then
    PrintList(Reply)
  else if (Code = ServiceRequestStatus) and (Reply.Count > 0) then
    PrintStatus(Reply.Services[0]);
  FlushStream(StandardOutput);
end.
