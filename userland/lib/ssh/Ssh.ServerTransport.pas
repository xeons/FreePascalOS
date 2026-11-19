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
  The server's side of the SSH transport (Ssh.Transport has what both
  sides share): its KEXINIT, its half of each key exchange method (the
  client's value in KEX_ECDH_INIT or KEX_HYBRID_INIT, both message 30;
  the host key, the server's value and the host key's signature over H
  in message 31), and OpenSSH's extensions.

  With ext-info-c in the client's first KEXINIT, SSH_MSG_EXT_INFO
  follows the server's first NEWKEYS (RFC 8308) with server-sig-algs,
  which makes clients sign with rsa-sha2-256/512 rather than SHA-1, and
  publickey-hostbound@openssh.com, which lets them bind a publickey
  signature to this server's host key. With
  kex-strict-c-v00@openssh.com (the server always offers
  kex-strict-s-v00@openssh.com) the key exchange is strict.

  Host keys may be certified (Ssh.HostKeys: a host certificate with the
  key that signs for it): the certificate's algorithm is offered and it
  goes as K_S.
}
unit Ssh.ServerTransport;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  Ssh.Algorithms,
  Ssh.HostKeys,
  Ssh.Transport;

type
  TSshServerTransport = class(TSshTransport)
  private
    FHostKeys: THostKeyArray;
    FHostKeyNames: TStringArray;
    FAwaitingClientValue: Boolean;
    FClientTakesExtensionInformation: Boolean;
    procedure SendExtensionInformation;
  protected
    function IsServer: Boolean; override;
    function MakeKeyExchangeInit: string; override;
    procedure KeyExchangeInitsKnown(const Peer: TSshKeyExchangeInit; SequenceNumber: LongWord); override;
    procedure HandleKeyExchangeMessage(const Payload: string); override;
    procedure FirstNewKeysSent; override;
  public
    { HostKeys are not owned and must outlive the transport.
      SoftwareVersion goes after "SSH-2.0-". }
    constructor Create(const HostKeys: THostKeyArray; const SoftwareVersion: string);
    { Whether Blob is one of this server's host keys (or certificates). }
    function IsOwnHostKey(const Blob: string): Boolean;
  end;

implementation

uses
  Ssh.Constants,
  Ssh.Wire,
  Ssh.KeyExchangeMethods;

const
  ServerSignatureAlgorithms = 'ssh-ed25519,ecdsa-sha2-nistp256,rsa-sha2-512,rsa-sha2-256';
  ExtensionPublicKeyHostBound = 'publickey-hostbound@openssh.com';

constructor TSshServerTransport.Create(const HostKeys: THostKeyArray; const SoftwareVersion: string);
begin
  inherited Create(SoftwareVersion);
  FHostKeys := Copy(HostKeys);
  FHostKeyNames := HostKeyAlgorithms(FHostKeys);
end;

function TSshServerTransport.IsServer: Boolean;
begin
  Result := True;
end;

function TSshServerTransport.IsOwnHostKey(const Blob: string): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(FHostKeys) do
    if FHostKeys[Index].PublicBlob = Blob then
      Exit(True);
  Result := False;
end;

function TSshServerTransport.MakeKeyExchangeInit: string;
begin
  Result := MakeServerKeyExchangeInit(FHostKeyNames);
end;

procedure TSshServerTransport.KeyExchangeInitsKnown(const Peer: TSshKeyExchangeInit; SequenceNumber: LongWord);
begin
  if not FFirstExchangeDone then
  begin
    FStrictKeyExchange := NameListContains(Peer.KeyExchange, StrictKeyExchangeClient);
    FClientTakesExtensionInformation := NameListContains(Peer.KeyExchange, ExtensionInformationClient);
    if FStrictKeyExchange and (SequenceNumber <> 0) then
      raise ESshDisconnect.CreateWithReason(DisconnectProtocolError,
        'strict key exchange: KEXINIT was not the first packet');
  end;
  FNegotiated := NegotiateAlgorithms(Peer, ParseKeyExchangeInit(FLocalInit));
  FAwaitingClientValue := True;
end;

procedure TSshServerTransport.HandleKeyExchangeMessage(const Payload: string);
var
  Reader: TSshReader;
  ClientValue, ServerValue, EncodedSecret: string;
  HostKey: TSshHostKey;
  HostKeyBlob, ExchangeHash: string;
begin
  if (Ord(Payload[1]) <> MessageKeyExchangeEcdhInit) or not FAwaitingClientValue then
    raise ESshProtocolError.Create('unexpected key exchange message');
  FAwaitingClientValue := False;
  Reader.Start(Payload);
  Reader.ReadByte;
  ClientValue := Reader.ReadString;
  if not AnswerClientExchange(FMethod, ClientValue, ServerValue, EncodedSecret) then
    raise ESshDisconnect.CreateWithReason(DisconnectKeyExchangeFailed, 'bad client key exchange value');
  try
    HostKey := FindHostKey(FHostKeys, FNegotiated.HostKey);
    HostKeyBlob := HostKey.PublicBlob;
    ExchangeHash := ExchangeHashOf(FMethod, ClientVersionLine, ServerVersionLine, ClientInitPayload,
      ServerInitPayload, HostKeyBlob, ClientValue, ServerValue, EncodedSecret);
    if FSessionId = '' then
      FSessionId := ExchangeHash;
    WritePacket(SshByte(MessageKeyExchangeEcdhReply) + SshString(HostKeyBlob) + SshString(ServerValue) +
      SshString(HostKey.Sign(ExchangeHash)));
    UseNewKeys(EncodedSecret, ExchangeHash);
  finally
    WipeString(EncodedSecret);
  end;
end;

procedure TSshServerTransport.FirstNewKeysSent;
begin
  if FClientTakesExtensionInformation then
    SendExtensionInformation;
end;

procedure TSshServerTransport.SendExtensionInformation;
begin
  WritePacket(SshByte(MessageExtensionInformation) + SshUInt32(2) +
    SshString(ExtensionServerSignatureAlgorithms) + SshString(ServerSignatureAlgorithms) +
    SshString(ExtensionPublicKeyHostBound) + SshString('0'));
end;

end.
