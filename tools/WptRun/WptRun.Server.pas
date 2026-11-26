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
  WPT's own server for a run: "wpt serve" from the checkout with the
  system's Python and the checkout's vendored modules (no virtualenv
  is set up: --venv names one, --skip-venv-setup uses it as it is), our
  config (tools/WptRun/server/config.json: it listens on 127.0.0.1 and
  does not probe the test domains, which only our clients resolve) and
  an alias that serves tools/WptRun/harness/testharnessreport.js as
  /resources/testharnessreport.js.

  It runs in a session of its own, so stopping it (SIGINT, as Ctrl-C
  would, then SIGKILL to the whole process group) takes its worker
  processes along. A server already listening on the HTTP port is used
  as it is and left running.
}
unit WptRun.Server;

{$mode objfpc}
{$H+}

interface

const
  WptHttpPort = 8000;
  WptHttpsPort = 8443;

{ True when something accepts connections on 127.0.0.1:Port. }
function PortOpen(Port: Word): Boolean;
{ Starts wpt serve from the checkout at WptRoot (unless one is already
  listening) and waits for it; WorkDirectory receives its alias file
  and log. False when it does not come up. }
function StartWptServer(const WptRoot, ConfigFile, HarnessDirectory, WorkDirectory: string): Boolean;
{ Stops the server StartWptServer started, if it did. }
procedure StopWptServer;

implementation

uses
  SysUtils,
  Classes,
  BaseUnix,
  Unix,
  Sockets;

var
  ServerPid: TPid = 0;

function PortOpen(Port: Word): Boolean;
var
  Handle: LongInt;
  Address: TInetSockAddr;
begin
  Handle := fpSocket(AF_INET, SOCK_STREAM, 0);
  if Handle < 0 then
    Exit(False);
  Address := Default(TInetSockAddr);
  Address.sin_family := AF_INET;
  Address.sin_port := htons(Port);
  Address.sin_addr := StrToNetAddr('127.0.0.1');
  Result := fpConnect(Handle, @Address, SizeOf(Address)) = 0;
  CloseSocket(Handle);
end;

procedure WriteAliasFile(const FileName, HarnessDirectory: string);
var
  Text: TStringList;
begin
  Text := TStringList.Create;
  try
    Text.Add('/resources/testharnessreport.js, ' + ExpandFileName(HarnessDirectory));
    Text.SaveToFile(FileName);
  finally
    Text.Free;
  end;
end;

function StartWptServer(const WptRoot, ConfigFile, HarnessDirectory, WorkDirectory: string): Boolean;
var
  Arguments: array of AnsiString;
  ArgumentPointers: array of PChar;
  AliasFile, LogFile: string;
  Index, Waited: Integer;
  Log: LongInt;
begin
  if PortOpen(WptHttpPort) then
  begin
    WriteLn(StdErr, 'wptrun: using the server already on port ', WptHttpPort);
    Exit(True);
  end;
  ForceDirectories(WorkDirectory);
  AliasFile := ExpandFileName(IncludeTrailingPathDelimiter(WorkDirectory) + 'aliases.txt');
  LogFile := ExpandFileName(IncludeTrailingPathDelimiter(WorkDirectory) + 'server.log');
  WriteAliasFile(AliasFile, HarnessDirectory);
  Arguments := ['python3', IncludeTrailingPathDelimiter(WptRoot) + 'wpt',
    '--venv', IncludeTrailingPathDelimiter(WptRoot) + '_venv3', '--skip-venv-setup',
    'serve', '--config', ExpandFileName(ConfigFile), '--alias_file', AliasFile, '--no-h2'];
  SetLength(ArgumentPointers, Length(Arguments) + 1);
  for Index := 0 to High(Arguments) do
    ArgumentPointers[Index] := PChar(Arguments[Index]);
  ArgumentPointers[High(ArgumentPointers)] := nil;
  ServerPid := fpFork;
  if ServerPid < 0 then
  begin
    ServerPid := 0;
    Exit(False);
  end;
  if ServerPid = 0 then
  begin
    fpSetsid;
    Log := fpOpen(LogFile, O_WRONLY or O_CREAT or O_TRUNC, &644);
    if Log >= 0 then
    begin
      fpDup2(Log, 1);
      fpDup2(Log, 2);
    end;
    fpChdir(WptRoot);
    fpExecvp('python3', PPChar(@ArgumentPointers[0]));
    fpExit(127);
  end;
  WriteLn(StdErr, 'wptrun: starting wpt serve (log: ', LogFile, ')');
  for Waited := 1 to 600 do
  begin
    if PortOpen(WptHttpPort) and PortOpen(WptHttpsPort) then
      Exit(True);
    if fpWaitPid(ServerPid, nil, WNOHANG) = ServerPid then
    begin
      ServerPid := 0;
      WriteLn(StdErr, 'wptrun: wpt serve exited; see ', LogFile);
      Exit(False);
    end;
    Sleep(100);
  end;
  WriteLn(StdErr, 'wptrun: wpt serve did not start; see ', LogFile);
  StopWptServer;
  Result := False;
end;

procedure StopWptServer;
var
  Waited: Integer;
begin
  if ServerPid <= 0 then
    Exit;
  fpKill(-ServerPid, SIGINT);
  for Waited := 1 to 100 do
  begin
    if fpWaitPid(ServerPid, nil, WNOHANG) = ServerPid then
      Break;
    Sleep(100);
  end;
  { What is left of its session (the servers it forked). }
  fpKill(-ServerPid, SIGKILL);
  fpWaitPid(ServerPid, nil, WNOHANG);
  ServerPid := 0;
end;

end.
