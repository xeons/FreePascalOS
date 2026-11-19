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
  The client's side of the SSH transport (Ssh.Transport has what both
  sides share): its KEXINIT (with ext-info-c and
  kex-strict-c-v00@openssh.com), its half of each key exchange method
  (its value in message 30, the server's reply in 31: the host key, the
  server's value and the host key's signature over H, which is checked
  here), and SSH_MSG_EXT_INFO from the server.

  Whether the host key is the right one for the server is the
  program's to say (OnHostKey, with known_hosts); a key refused ends the
  connection with HOST_KEY_NOT_VERIFIABLE before anything is sent under
  the new keys.
}
unit Ssh.ClientTransport;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  Ssh.Algorithms,
  Ssh.KeyExchangeMethods,
  Ssh.Transport;

const
  ClientHostKeyAlgorithms: array[0..3] of string = ('ssh-ed25519', 'ecdsa-sha2-nistp256', 'rsa-sha2-512',
    'rsa-sha2-256');

type
  { Whether HostKeyBlob may stand for the server. }
  TSshHostKeyCheck = function(const HostKeyBlob: string): Boolean of object;

  TSshClientTransport = class(TSshTransport)
  private
    FOffer: TSshAlgorithmOffer;
    FSecret: TSshClientExchangeSecret;
    FClientValue: string;
    FAwaitingReply: Boolean;
    FOnHostKey: TSshHostKeyCheck;
    FHostKeyBlob: string;
    FServerSignatureAlgorithms: TStringArray;
    FServerTakesHostBound: Boolean;
    FExtensionInformationReceived: Boolean;
  protected
    function IsServer: Boolean; override;
    function MakeKeyExchangeInit: string; override;
    procedure KeyExchangeInitsKnown(const Peer: TSshKeyExchangeInit; SequenceNumber: LongWord); override;
    procedure HandleKeyExchangeMessage(const Payload: string); override;
    procedure HandleExtensionInformation(const Payload: string); override;
  public
    { Offer: the algorithms in order of preference (DefaultClientOffer). }
    constructor Create(const Offer: TSshAlgorithmOffer; const SoftwareVersion: string);
    destructor Destroy; override;
    property OnHostKey: TSshHostKeyCheck read FOnHostKey write FOnHostKey;
    { The server's host key blob, once the first exchange has checked it. }
    property HostKeyBlob: string read FHostKeyBlob;
    { From EXT_INFO: server-sig-algs and publickey-hostbound. }
    property ServerSignatureAlgorithms: TStringArray read FServerSignatureAlgorithms;
    property ServerTakesHostBound: Boolean read FServerTakesHostBound;
    property ExtensionInformationReceived: Boolean read FExtensionInformationReceived;
  end;

function DefaultClientOffer: TSshAlgorithmOffer;

implementation

uses
  Ssh.Constants,
  Ssh.Wire,
  Ssh.PublicKeys;

const
  ExtensionPublicKeyHostBound = 'publickey-hostbound@openssh.com';

function DefaultClientOffer: TSshAlgorithmOffer;
begin
  Result := DefaultOffer(ClientHostKeyAlgorithms);
end;

constructor TSshClientTransport.Create(const Offer: TSshAlgorithmOffer; const SoftwareVersion: string);
begin
  inherited Create(SoftwareVersion);
  FOffer := Offer;
end;

destructor TSshClientTransport.Destroy;
begin
  WipeClientExchangeSecret(FSecret);
  inherited Destroy;
end;

function TSshClientTransport.IsServer: Boolean;
begin
  Result := False;
end;

function TSshClientTransport.MakeKeyExchangeInit: string;
var
  Offer: TSshAlgorithmOffer;
  Count: Integer;
begin
  Offer := FOffer;
  Offer.KeyExchange := Copy(FOffer.KeyExchange);
  if not FFirstExchangeDone then
  begin
    Count := Length(Offer.KeyExchange);
    SetLength(Offer.KeyExchange, Count + 2);
    Offer.KeyExchange[Count] := ExtensionInformationClient;
    Offer.KeyExchange[Count + 1] := StrictKeyExchangeClient;
  end
  else if FStrictKeyExchange then
  begin
    { Rekeying: the strict marker stays, ext-info-c goes (RFC 8308). }
    Count := Length(Offer.KeyExchange);
    SetLength(Offer.KeyExchange, Count + 1);
    Offer.KeyExchange[Count] := StrictKeyExchangeClient;
  end;
  Result := Ssh.Algorithms.MakeKeyExchangeInit(Offer);
end;

procedure TSshClientTransport.KeyExchangeInitsKnown(const Peer: TSshKeyExchangeInit; SequenceNumber: LongWord);
begin
  if not FFirstExchangeDone then
  begin
    FStrictKeyExchange := NameListContains(Peer.KeyExchange, StrictKeyExchangeServer);
    if FStrictKeyExchange and (SequenceNumber <> 0) then
      raise ESshDisconnect.CreateWithReason(DisconnectProtocolError,
        'strict key exchange: KEXINIT was not the first packet');
  end;
  FNegotiated := NegotiateAlgorithms(ParseKeyExchangeInit(FLocalInit), Peer);
  if not FindKeyExchangeMethod(FNegotiated.KeyExchange, FMethod) then
    raise ESshNegotiationError.Create('no key exchange method in common');
  WipeClientExchangeSecret(FSecret);
  FClientValue := StartClientExchange(FMethod, FSecret);
  WritePacket(SshByte(MessageKeyExchangeEcdhInit) + SshString(FClientValue));
  FAwaitingReply := True;
end;

procedure TSshClientTransport.HandleKeyExchangeMessage(const Payload: string);
var
  Reader: TSshReader;
  ReceivedHostKey, ServerValue, Signature, EncodedSecret, ExchangeHash: string;
  HostKey: TSshPublicKey;
begin
  if (Ord(Payload[1]) <> MessageKeyExchangeEcdhReply) or not FAwaitingReply then
    raise ESshProtocolError.Create('unexpected key exchange message');
  FAwaitingReply := False;
  Reader.Start(Payload);
  Reader.ReadByte;
  ReceivedHostKey := Reader.ReadString;
  ServerValue := Reader.ReadString;
  Signature := Reader.ReadString;
  if not FinishClientExchange(FSecret, ServerValue, EncodedSecret) then
    raise ESshDisconnect.CreateWithReason(DisconnectKeyExchangeFailed, 'bad server key exchange value');
  WipeClientExchangeSecret(FSecret);
  try
    ExchangeHash := ExchangeHashOf(FMethod, ClientVersionLine, ServerVersionLine, ClientInitPayload,
      ServerInitPayload, ReceivedHostKey, FClientValue, ServerValue, EncodedSecret);
    if not ParsePublicKeyBlob(ReceivedHostKey, HostKey) or
      not VerifySshSignature(HostKey, FNegotiated.HostKey, ExchangeHash, Signature) then
      raise ESshDisconnect.CreateWithReason(DisconnectKeyExchangeFailed, 'the host key''s signature is wrong');
    if FFirstExchangeDone then
    begin
      if ReceivedHostKey <> FHostKeyBlob then
        raise ESshDisconnect.CreateWithReason(DisconnectHostKeyNotVerifiable, 'the host key changed in a rekeying');
    end
    else
    begin
      if Assigned(FOnHostKey) and not FOnHostKey(ReceivedHostKey) then
        raise ESshDisconnect.CreateWithReason(DisconnectHostKeyNotVerifiable, 'host key refused');
      FHostKeyBlob := ReceivedHostKey;
    end;
    if FSessionId = '' then
      FSessionId := ExchangeHash;
    UseNewKeys(EncodedSecret, ExchangeHash);
  finally
    WipeString(EncodedSecret);
  end;
end;

procedure TSshClientTransport.HandleExtensionInformation(const Payload: string);
var
  Reader: TSshReader;
  Count, Index: LongWord;
  Name, Value: string;
begin
  Reader.Start(Payload);
  Reader.ReadByte;
  Count := Reader.ReadUInt32;
  Index := 0;
  while Index < Count do
  begin
    Name := Reader.ReadString;
    Value := Reader.ReadString;
    if Name = ExtensionServerSignatureAlgorithms then
      FServerSignatureAlgorithms := SplitNameList(Value)
    else if Name = ExtensionPublicKeyHostBound then
      FServerTakesHostBound := Value = '0';
    Inc(Index);
  end;
  FExtensionInformationReceived := True;
end;

end.
