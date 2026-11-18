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
  Algorithm negotiation (RFC 4253 section 7.1): the SSH_MSG_KEXINIT
  message, read and made, and the choice for each kind - the first
  algorithm on the client's list that the server also has.

  The server offers curve25519-sha256 (and its libssh.org name), the
  host key algorithms it has keys for, the ciphers of Ssh.CipherSuites
  and no compression. All its ciphers are authenticated encryption, so
  no MAC is chosen (as OpenSSH does for them); the MAC lists only have
  to be well formed. The key exchange list also carries
  kex-strict-s-v00@openssh.com.
}
unit Ssh.Algorithms;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  TSshKeyExchangeInit = record
    Cookie: string;
    KeyExchange: TStringArray;
    HostKey: TStringArray;
    CiphersClientToServer: TStringArray;
    CiphersServerToClient: TStringArray;
    MacsClientToServer: TStringArray;
    MacsServerToClient: TStringArray;
    CompressionClientToServer: TStringArray;
    CompressionServerToClient: TStringArray;
    FirstPacketFollows: Boolean;
  end;

  TSshNegotiated = record
    KeyExchange: string;
    HostKey: string;
    CipherClientToServer: string;
    CipherServerToClient: string;
  end;

  ESshNegotiationError = class(Exception);

{ Raises ESshProtocolError for a malformed message. }
function ParseKeyExchangeInit(const Payload: string): TSshKeyExchangeInit;
{ The server's SSH_MSG_KEXINIT payload, with a new random cookie. }
function MakeServerKeyExchangeInit(const HostKeyAlgorithms: array of string): string;
{ Raises ESshNegotiationError when some kind has nothing in common. }
function NegotiateAlgorithms(const Client: TSshKeyExchangeInit;
  const HostKeyAlgorithms: array of string): TSshNegotiated;
{ The first name of Client also in Server; '' if none. }
function FirstCommonName(const Client: TStringArray; const Server: array of string): string;
function KeyExchangeIsSupported(const Name: string): Boolean;

implementation

uses
  Crypto.Random,
  Ssh.Constants,
  Ssh.Wire,
  Ssh.CipherSuites;

const
  CookieSize = 16;
  SupportedKeyExchanges: array[0..1] of string = ('curve25519-sha256', 'curve25519-sha256@libssh.org');
  OfferedMacs: array[0..0] of string = ('hmac-sha2-256');

function ParseKeyExchangeInit(const Payload: string): TSshKeyExchangeInit;
var
  Reader: TSshReader;
  Index: Integer;
begin
  Result := Default(TSshKeyExchangeInit);
  Reader.Start(Payload);
  if Reader.ReadByte <> MessageKeyExchangeInit then
    raise ESshProtocolError.Create('not a KEXINIT');
  Result.Cookie := '';
  for Index := 1 to CookieSize do
    Result.Cookie := Result.Cookie + Chr(Reader.ReadByte);
  Result.KeyExchange := Reader.ReadNameList;
  Result.HostKey := Reader.ReadNameList;
  Result.CiphersClientToServer := Reader.ReadNameList;
  Result.CiphersServerToClient := Reader.ReadNameList;
  Result.MacsClientToServer := Reader.ReadNameList;
  Result.MacsServerToClient := Reader.ReadNameList;
  Result.CompressionClientToServer := Reader.ReadNameList;
  Result.CompressionServerToClient := Reader.ReadNameList;
  { The languages are read and ignored. }
  Reader.ReadNameList;
  Reader.ReadNameList;
  Result.FirstPacketFollows := Reader.ReadBoolean;
  { The reserved uint32 0. }
  Reader.ReadUInt32;
end;

function MakeServerKeyExchangeInit(const HostKeyAlgorithms: array of string): string;
var
  Cookie: string;
begin
  Cookie := '';
  SetLength(Cookie, CookieSize);
  RandomBytes(@Cookie[1], CookieSize);
  Result := SshByte(MessageKeyExchangeInit) + Cookie +
    SshNameList([KeyExchangeCurve25519, KeyExchangeCurve25519LibSsh, StrictKeyExchangeServer]) +
    SshNameList(HostKeyAlgorithms) +
    SshNameList(SupportedCiphers) + SshNameList(SupportedCiphers) +
    SshNameList(OfferedMacs) + SshNameList(OfferedMacs) +
    SshNameList([CompressionNone]) + SshNameList([CompressionNone]) +
    SshString('') + SshString('') +
    SshBoolean(False) + SshUInt32(0);
end;

function FirstCommonName(const Client: TStringArray; const Server: array of string): string;
var
  ClientIndex, ServerIndex: Integer;
begin
  for ClientIndex := 0 to High(Client) do
    for ServerIndex := 0 to High(Server) do
      if Client[ClientIndex] = Server[ServerIndex] then
        Exit(Client[ClientIndex]);
  Result := '';
end;

function KeyExchangeIsSupported(const Name: string): Boolean;
begin
  Result := (Name = KeyExchangeCurve25519) or (Name = KeyExchangeCurve25519LibSsh);
end;

function Choose(const Client: TStringArray; const Server: array of string; const Kind: string): string;
begin
  Result := FirstCommonName(Client, Server);
  if Result = '' then
    raise ESshNegotiationError.Create('no ' + Kind + ' in common');
end;

function NegotiateAlgorithms(const Client: TSshKeyExchangeInit;
  const HostKeyAlgorithms: array of string): TSshNegotiated;
begin
  Result.KeyExchange := Choose(Client.KeyExchange, SupportedKeyExchanges, 'key exchange method');
  Result.HostKey := Choose(Client.HostKey, HostKeyAlgorithms, 'host key algorithm');
  Result.CipherClientToServer := Choose(Client.CiphersClientToServer, SupportedCiphers,
    'cipher (client to server)');
  Result.CipherServerToClient := Choose(Client.CiphersServerToClient, SupportedCiphers,
    'cipher (server to client)');
  Choose(Client.CompressionClientToServer, [CompressionNone], 'compression (client to server)');
  Choose(Client.CompressionServerToClient, [CompressionNone], 'compression (server to client)');
end;

end.
