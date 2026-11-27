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
  sshd - the SSH server

  sshd [-f CONFIG] [-p PORT] [-t]

  Listens on port 22 (the configuration's Port) for SSH clients, such as
  OpenSSH's ssh, scp and sftp, and runs what they ask for as the user
  who logged in: a shell in a pseudo-terminal, a command, or the SFTP
  subsystem. Host keys missing from /etc/ssh are made on the first
  start. The service manager runs it (/etc/services/sshd.service); it
  must run as root. Units in userland/system/sshd, the protocol in libssh.

    -f CONFIG     the configuration file (/etc/ssh/sshd_config)
    -p PORT       listen on PORT instead of the configured one
    -t            check the configuration and the host keys, then end

  With --connection it serves one connection on its standard input:
  how the listening server starts a process for each connection.
}
program sshd;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Util.Accounts,
  Util.CommandLine,
  Util.Messages,
  Ssh.HostKeys,
  Sshd.Configuration,
  Sshd.ConnectionLoop,
  Sshd.HostKeyStore,
  Sshd.Listener,
  Sshd.Log;

const
  Usage = 'Usage: sshd [-f CONFIG] [-p PORT] [-t]'#10 +
    'The SSH server.'#10#10 +
    '  -f CONFIG   the configuration file (/etc/ssh/sshd_config)'#10 +
    '  -p PORT     listen on PORT instead of the configured one'#10 +
    '  -t          check the configuration and the host keys, then end'#10;
  OptionConfiguration = 1;
  OptionPort = 2;
  OptionTest = 3;
  OptionConnection = 4;

var
  ConfigurationPath: string;
  PortOverride: Integer;
  TestOnly: Boolean;
  ServeOneConnection: Boolean;

procedure ReadOptions;
var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
begin
  ConfigurationPath := DefaultConfigurationPath;
  PortOverride := 0;
  TestOnly := False;
  ServeOneConnection := False;
  CommandLine := TCommandLine.Create([
    CommandOption('f', '', True, OptionConfiguration),
    CommandOption('p', '', True, OptionPort),
    CommandOption('t', '', False, OptionTest),
    CommandOption(#0, 'connection', False, OptionConnection)], Usage);
  try
    while CommandLine.NextOption(Code, Value) do
      case Code of
        OptionConfiguration: ConfigurationPath := Value;
        OptionPort:
          if not TryStrToInt(Value, PortOverride) or (PortOverride < 1) or (PortOverride > 65535) then
            FailWithUsageHint('bad port: ' + Value);
        OptionTest: TestOnly := True;
        OptionConnection: ServeOneConnection := True;
      end;
    if CommandLine.OperandCount > 0 then
      FailWithUsageHint('no operands are taken');
  finally
    CommandLine.Free;
  end;
end;

function CheckOnly(const Configuration: TSshdConfiguration): LongInt;
var
  Keys: THostKeyArray;
  Index: Integer;
begin
  Keys := LoadOrCreateHostKeys(Configuration.HostKeyPaths, True);
  if Length(Keys) = 0 then
    Exit(1);
  for Index := 0 to High(Keys) do
    Keys[Index].Free;
  WriteLn('port ', Configuration.Port, ', password authentication ',
    BoolToStr(Configuration.PasswordAuthentication, 'yes', 'no'), ', public key authentication ',
    BoolToStr(Configuration.PublicKeyAuthentication, 'yes', 'no'), ', root login ',
    BoolToStr(Configuration.PermitRootLogin, 'yes', 'no'));
  Result := 0;
end;

var
  Configuration: TSshdConfiguration;
  Problems: TStringArray;
  Index: Integer;
begin
  ReadOptions;
  if CurrentUserId <> RootId then
    Fail(1, 'only root may run the SSH server');
  Configuration := ReadConfiguration(ConfigurationPath, Problems);
  if PortOverride > 0 then
    Configuration.Port := Word(PortOverride);
  if ServeOneConnection then
    Halt(ServeConnection(StandardInputHandle, Configuration));
  for Index := 0 to High(Problems) do
    LogLine(Problems[Index]);
  if TestOnly then
  begin
    if Length(Problems) > 0 then
      Halt(1);
    Halt(CheckOnly(Configuration));
  end;
  Halt(RunListener(Configuration, ConfigurationPath));
end.
