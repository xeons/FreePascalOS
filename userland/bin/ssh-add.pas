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
  ssh-add - lists the keys of the SSH agent

  ssh-add -l     the fingerprint of each key
  ssh-add -L     each public key, as authorized_keys takes it

  The agent is the one SSH_AUTH_SOCK names: on this system a forwarded
  agent (ssh -A to this system's sshd), SSH_AUTH_SOCK=port:NAME, a named
  port (Ssh.AgentChannels). Exit status 1 when the agent has no keys, 2
  when there is no agent.
}
program sshadd;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Util.CommandLine,
  Util.Messages,
  Ssh.Wire,
  Ssh.PublicKeys,
  Ssh.AgentProtocol,
  Ssh.AgentChannels;

const
  Usage = 'Usage: ssh-add -l | -L'#10 +
    'Lists the keys of the SSH agent (SSH_AUTH_SOCK).'#10;
  OptionFingerprints = 1;
  OptionPublicKeys = 2;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  PublicKeys: Boolean;
  Agent: TSshAgentClient;
  Keys: TSshAgentIdentities;
  Index: Integer;
  Reader: TSshReader;
begin
  PublicKeys := False;
  CommandLine := TCommandLine.Create([
    CommandOption('l', '', False, OptionFingerprints),
    CommandOption('L', '', False, OptionPublicKeys)], Usage);
  try
    while CommandLine.NextOption(Code, Value) do
      if Code = OptionPublicKeys then
        PublicKeys := True;
  finally
    CommandLine.Free;
  end;
  Agent := TSshAgentClient.Create;
  try
    if (GetEnvironmentVariable('SSH_AUTH_SOCK') = '') or not Agent.Connect(GetEnvironmentVariable('SSH_AUTH_SOCK')) then
    begin
      WriteLn(ErrOutput, 'Could not open a connection to your authentication agent.');
      Halt(2);
    end;
    if not Agent.ListKeys(Keys) then
    begin
      WriteLn(ErrOutput, 'error fetching identities from the agent');
      Halt(2);
    end;
    if Length(Keys) = 0 then
    begin
      WriteLn('The agent has no identities.');
      Halt(1);
    end;
    for Index := 0 to High(Keys) do
      if PublicKeys then
        WriteLn(PublicKeyLine(Keys[Index].Blob, Keys[Index].Comment))
      else
      begin
        Reader.Start(Keys[Index].Blob);
        WriteLn(PublicKeyFingerprint(Keys[Index].Blob), ' ', Keys[Index].Comment, ' (', Reader.ReadString, ')');
      end;
  finally
    Agent.Free;
  end;
end.
