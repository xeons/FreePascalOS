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
  Starting a service's program.

  Each service runs in a session of its own (ProcessNewSession), so
  stopping it ends whatever it started too. It runs as its user (the
  user's ids and groups, through the kernel), in "/", with a small
  environment: PATH, HOME, USER, LOGNAME, SHELL, TERM, and SERVICE_NAME
  and SERVICE_PORT for telling the manager it is ready
  (Sys.ServiceControl). A service on the console gets the console as
  its three standard handles and its foreground (it may read it: login);
  any other reads nothing (/dev/null) and writes to its log.
}
unit Services.Launch;

{$mode objfpc}
{$H+}

interface

uses
  Services.Catalog;

var
  { The port the manager serves, told to every service. }
  ControlPortName: string;

{ Starts Service's program: ErrorNone with its process handle and id
  (and its log handle) set in Service, or an error code with Reason set. }
function LaunchService(Service: TService): LongInt;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Files,
  Sys.Processes,
  Sys.ServiceControl,
  Util.Logins,
  Services.Logs;

type
  TLaunchEnvironment = record
    Texts: array of string;
    Values: array of PChar;
  end;

procedure AddVariable(var Environment: TLaunchEnvironment; const Name, Value: string);
begin
  SetLength(Environment.Texts, Length(Environment.Texts) + 1);
  Environment.Texts[High(Environment.Texts)] := Name + '=' + Value;
end;

procedure BuildEnvironment(Service: TService; const Account: TLoginAccount; var Environment: TLaunchEnvironment);
var
  Index: LongInt;
begin
  Environment.Texts := nil;
  AddVariable(Environment, 'PATH', '/bin');
  AddVariable(Environment, 'HOME', PChar(@Account.Home[0]));
  AddVariable(Environment, 'USER', PChar(@Account.Name[0]));
  AddVariable(Environment, 'LOGNAME', PChar(@Account.Name[0]));
  AddVariable(Environment, 'SHELL', PChar(@Account.Shell[0]));
  AddVariable(Environment, 'TERM', 'console');
  AddVariable(Environment, ServiceNameVariable, Service.Definition.Name);
  AddVariable(Environment, ServicePortVariable, ControlPortName);
  SetLength(Environment.Values, Length(Environment.Texts) + 1);
  for Index := 0 to High(Environment.Texts) do
    Environment.Values[Index] := PChar(Environment.Texts[Index]);
  Environment.Values[High(Environment.Values)] := nil;
end;

procedure BuildArguments(Service: TService; out Arguments: array of PChar; out Count: LongInt);
var
  Index: LongInt;
begin
  Arguments[0] := PChar(Service.Definition.ProgramPath);
  Count := 1;
  for Index := 0 to High(Service.Definition.Arguments) do
    if Count < High(Arguments) then
    begin
      Arguments[Count] := PChar(Service.Definition.Arguments[Index]);
      Inc(Count);
    end;
  Arguments[Count] := nil;
end;

function LaunchService(Service: TService): LongInt;
const
  MaximumArguments = 32;
var
  Account: TLoginAccount;
  Environment: TLaunchEnvironment;
  Arguments: array[0..MaximumArguments] of PChar;
  ArgumentCount: LongInt;
  Options: TProcessOptions;
  NullInput: Int64;
  Process: Int64;
begin
  if not FindLoginAccount(PChar(Service.Definition.UserName), Account) then
  begin
    Service.Reason := 'its user ' + Service.Definition.UserName + ' does not exist';
    Exit(ErrorNotFound);
  end;
  BuildEnvironment(Service, Account, Environment);
  BuildArguments(Service, Arguments, ArgumentCount);
  DefaultProcessOptions(Options);
  Options.Environment := @Environment.Values[0];
  Options.WorkingDirectory := '/';
  Options.Identity := @Account.Identity;
  Options.NewSession := True;
  NullInput := NoHandle;
  if Service.Definition.OnConsole then
    Options.GroupId := GroupNewInForeground
  else
  begin
    Options.GroupId := GroupNew;
    NullInput := OpenFile('/dev/null', OpenRead or OpenWrite);
    Options.InputHandle := NullInput;
    Service.LogHandle := OpenServiceLog(Service.Definition.Name, 'starting ' + Service.Definition.ProgramPath);
    if Service.LogHandle <> NoHandle then
    begin
      Options.OutputHandle := Service.LogHandle;
      Options.ErrorHandle := Service.LogHandle;
    end
    else
    begin
      Options.OutputHandle := NullInput;
      Options.ErrorHandle := NullInput;
    end;
  end;
  Process := StartProgram(PChar(Service.Definition.ProgramPath), @Arguments[0], Options);
  if NullInput >= 0 then
    CloseFile(NullInput);
  if Process < 0 then
  begin
    if Service.LogHandle <> NoHandle then
      CloseFile(Service.LogHandle);
    Service.LogHandle := NoHandle;
    Service.Reason := 'could not start ' + Service.Definition.ProgramPath;
    Exit(LongInt(-Process));
  end;
  Service.ProcessHandle := Process;
  Service.ProcessId := QWord(ProcessIdOf(Process));
  Result := ErrorNone;
end;

end.
