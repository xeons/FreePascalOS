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
  algorithm on the client's list that the server also has, which both
  sides work out the same way.

  Offered: mlkem768x25519-sha256 first (post-quantum hybrid; OpenSSH 9.9
  and later choose it by default), then curve25519-sha256 and its
  libssh.org name; the host key algorithms there are keys for; the
  ciphers of Ssh.CipherSuites; no compression. All the ciphers are
  authenticated encryption, so no MAC is chosen (as OpenSSH does for
  them); the MAC lists only have to be well formed. The key exchange
  lists also carry the pseudo algorithms: kex-strict-s-v00@openssh.com
  from a server; ext-info-c and kex-strict-c-v00@openssh.com from a
  client.
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

  { What a side offers, in order of preference. }
  TSshAlgorithmOffer = record
    KeyExchange: TStringArray;
    HostKey: TStringArray;
    Ciphers: TStringArray;
  end;

  ESshNegotiationError = class(Exception);

const
  SupportedKeyExchanges: array[0..2] of string = ('mlkem768x25519-sha256', 'curve25519-sha256',
    'curve25519-sha256@libssh.org');

{ Raises ESshProtocolError for a malformed message. }
function ParseKeyExchangeInit(const Payload: string): TSshKeyExchangeInit;
{ A KEXINIT payload with a new random cookie. }
function MakeKeyExchangeInit(const Offer: TSshAlgorithmOffer): string;
{ The server's: every supported key exchange and cipher, and
  kex-strict-s. }
function MakeServerKeyExchangeInit(const HostKeyAlgorithms: array of string): string;
{ What a server offers, without the pseudo algorithms. }
function DefaultOffer(const HostKeyAlgorithms: array of string): TSshAlgorithmOffer;
{ Raises ESshNegotiationError when some kind has nothing in common. }
function NegotiateAlgorithms(const Client, Server: TSshKeyExchangeInit): TSshNegotiated;
{ The first name of Client also in Server; '' if none. }
function FirstCommonName(const Client: TStringArray; const Server: array of string): string;
function KeyExchangeIsSupported(const Name: string): Boolean;
function ToStringArray(const Names: array of string): TStringArray;

implementation

uses
  Crypto.Random,
  Ssh.Constants,
  Ssh.Wire,
  Ssh.CipherSuites;

const
  CookieSize = 16;
  OfferedMacs: array[0..0] of string = ('hmac-sha2-256');

function ToStringArray(const Names: array of string): TStringArray;
var
  Index: Integer;
begin
  Result := nil;
  SetLength(Result, Length(Names));
  for Index := 0 to High(Names) do
    Result[Index] := Names[Index];
end;

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

function MakeKeyExchangeInit(const Offer: TSshAlgorithmOffer): string;
var
  Cookie: string;
begin
  Cookie := '';
  SetLength(Cookie, CookieSize);
  RandomBytes(@Cookie[1], CookieSize);
  Result := SshByte(MessageKeyExchangeInit) + Cookie +
    SshNameList(Offer.KeyExchange) +
    SshNameList(Offer.HostKey) +
    SshNameList(Offer.Ciphers) + SshNameList(Offer.Ciphers) +
    SshNameList(OfferedMacs) + SshNameList(OfferedMacs) +
    SshNameList([CompressionNone]) + SshNameList([CompressionNone]) +
    SshString('') + SshString('') +
    SshBoolean(False) + SshUInt32(0);
end;

function DefaultOffer(const HostKeyAlgorithms: array of string): TSshAlgorithmOffer;
begin
  Result.KeyExchange := ToStringArray(SupportedKeyExchanges);
  Result.HostKey := ToStringArray(HostKeyAlgorithms);
  Result.Ciphers := ToStringArray(SupportedCiphers);
end;

function MakeServerKeyExchangeInit(const HostKeyAlgorithms: array of string): string;
var
  Offer: TSshAlgorithmOffer;
begin
  Offer := DefaultOffer(HostKeyAlgorithms);
  SetLength(Offer.KeyExchange, Length(Offer.KeyExchange) + 1);
  Offer.KeyExchange[High(Offer.KeyExchange)] := StrictKeyExchangeServer;
  Result := MakeKeyExchangeInit(Offer);
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
var
  Index: Integer;
begin
  for Index := 0 to High(SupportedKeyExchanges) do
    if SupportedKeyExchanges[Index] = Name then
      Exit(True);
  Result := False;
end;

function Choose(const Client: TStringArray; const Server: TStringArray; const Kind: string): string;
begin
  Result := FirstCommonName(Client, Server);
  if Result = '' then
    raise ESshNegotiationError.Create('no ' + Kind + ' in common');
end;

{ Only real methods count: the pseudo algorithms are never chosen. }
function RealKeyExchanges(const Names: TStringArray): TStringArray;
var
  Index: Integer;
begin
  Result := nil;
  for Index := 0 to High(Names) do
    if KeyExchangeIsSupported(Names[Index]) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Names[Index];
    end;
end;

function NegotiateAlgorithms(const Client, Server: TSshKeyExchangeInit): TSshNegotiated;
begin
  Result.KeyExchange := Choose(Client.KeyExchange, RealKeyExchanges(Server.KeyExchange), 'key exchange method');
  Result.HostKey := Choose(Client.HostKey, Server.HostKey, 'host key algorithm');
  Result.CipherClientToServer := Choose(Client.CiphersClientToServer, Server.CiphersClientToServer,
    'cipher (client to server)');
  Result.CipherServerToClient := Choose(Client.CiphersServerToClient, Server.CiphersServerToClient,
    'cipher (server to client)');
  if not CipherIsSupported(Result.CipherClientToServer) or not CipherIsSupported(Result.CipherServerToClient) then
    raise ESshNegotiationError.Create('no cipher in common');
  Choose(Client.CompressionClientToServer, ToStringArray([CompressionNone]), 'compression (client to server)');
  Choose(Client.CompressionServerToClient, ToStringArray([CompressionNone]), 'compression (server to client)');
end;

end.
