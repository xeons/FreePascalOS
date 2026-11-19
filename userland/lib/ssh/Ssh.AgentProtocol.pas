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
  The SSH agent protocol (draft-ietf-sshm-ssh-agent), the part a client
  uses: listing the agent's keys and having it sign. Every message is

    uint32 length, byte type, contents

  over a stream: OpenSSH's agent listens on a Unix domain socket named
  by SSH_AUTH_SOCK. Here the stream is a local channel instead (sshd's
  agent forwarding: SSH_AUTH_SOCK=port:NAME, a named port); the bytes
  are the same, cut into messages of the channel's size, so a reader
  puts them back together (TSshAgentFrameReader).
}
unit Ssh.AgentProtocol;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

const
  AgentFailure = 5;
  AgentSuccess = 6;
  AgentRequestIdentities = 11;
  AgentIdentitiesAnswer = 12;
  AgentSignRequest = 13;
  AgentSignResponse = 14;
  { Sign request flags for RSA keys. }
  AgentRsaSha256 = 2;
  AgentRsaSha512 = 4;
  { No agent message is anywhere near this. }
  MaximumAgentMessage = 256 * 1024;
  { The prefix of SSH_AUTH_SOCK for an agent behind a named port. }
  AgentPortPrefix = 'port:';

type
  TSshAgentIdentity = record
    Blob: string;
    Comment: string;
  end;
  TSshAgentIdentities = array of TSshAgentIdentity;

  { Puts a byte stream back into whole messages. }
  TSshAgentFrameReader = record
  private
    FBuffer: string;
  public
    procedure Append(const Data: string);
    { The next whole message's payload (type and contents); False if
      none is complete yet. Raises ESshProtocolError for a length out of
      range. }
    function NextMessage(out Payload: string): Boolean;
  end;

{ A message with its length in front. }
function FrameAgentMessage(const Payload: string): string;
function MakeIdentitiesRequest: string;
function MakeSignRequest(const Blob, Data: string; Flags: LongWord): string;
function ParseIdentitiesAnswer(const Payload: string; out Identities: TSshAgentIdentities): Boolean;
function ParseSignResponse(const Payload: string; out Signature: string): Boolean;
{ The flags that ask for the signature algorithm Algorithm. }
function SignFlagsFor(const Algorithm: string): LongWord;

implementation

uses
  Ssh.Constants,
  Ssh.Wire;

procedure TSshAgentFrameReader.Append(const Data: string);
begin
  FBuffer := FBuffer + Data;
end;

function TSshAgentFrameReader.NextMessage(out Payload: string): Boolean;
var
  Size: LongWord;
begin
  Payload := '';
  if Length(FBuffer) < 4 then
    Exit(False);
  Size := ReadBigEndian32(FBuffer, 1);
  if (Size = 0) or (Size > MaximumAgentMessage) then
    raise ESshProtocolError.Create('agent message of a bad length');
  if QWord(Length(FBuffer)) < QWord(Size) + 4 then
    Exit(False);
  Payload := Copy(FBuffer, 5, Integer(Size));
  Delete(FBuffer, 1, Integer(Size) + 4);
  Result := True;
end;

function FrameAgentMessage(const Payload: string): string;
begin
  Result := SshUInt32(Length(Payload)) + Payload;
end;

function MakeIdentitiesRequest: string;
begin
  Result := FrameAgentMessage(SshByte(AgentRequestIdentities));
end;

function MakeSignRequest(const Blob, Data: string; Flags: LongWord): string;
begin
  Result := FrameAgentMessage(SshByte(AgentSignRequest) + SshString(Blob) + SshString(Data) + SshUInt32(Flags));
end;

function ParseIdentitiesAnswer(const Payload: string; out Identities: TSshAgentIdentities): Boolean;
var
  Reader: TSshReader;
  Count, Index: LongWord;
begin
  Identities := nil;
  Result := False;
  try
    Reader.Start(Payload);
    if Reader.ReadByte <> AgentIdentitiesAnswer then
      Exit;
    Count := Reader.ReadUInt32;
    if Count > 1024 then
      Exit;
    SetLength(Identities, Count);
    Index := 0;
    while Index < Count do
    begin
      Identities[Index].Blob := Reader.ReadString;
      Identities[Index].Comment := Reader.ReadString;
      Inc(Index);
    end;
    Result := True;
  except
    on ESshProtocolError do
    begin
      Identities := nil;
      Result := False;
    end;
  end;
end;

function ParseSignResponse(const Payload: string; out Signature: string): Boolean;
var
  Reader: TSshReader;
begin
  Signature := '';
  Result := False;
  try
    Reader.Start(Payload);
    if Reader.ReadByte <> AgentSignResponse then
      Exit;
    Signature := Reader.ReadString;
    Result := True;
  except
    on ESshProtocolError do
      Result := False;
  end;
end;

function SignFlagsFor(const Algorithm: string): LongWord;
begin
  if Algorithm = SignatureRsaSha512 then
    Result := AgentRsaSha512
  else if Algorithm = SignatureRsaSha256 then
    Result := AgentRsaSha256
  else
    Result := 0;
end;

end.
