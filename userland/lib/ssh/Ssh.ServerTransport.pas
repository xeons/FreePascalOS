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
  The server side of the SSH transport (RFC 4253): the version lines,
  the key exchanges (the first and every rekeying), the switch to new
  keys, and the transport's own messages.

  Like the packet layer it does no input or output: received bytes go
  in with Receive, the messages for the layers above (user
  authentication, connection) come out of NextMessage, their replies go
  in with Send, and TakeOutput gives the bytes to send. While a key
  exchange runs, messages sent are held back and go out once the new
  keys are in use.

  OpenSSH's extensions: with ext-info-c in the client's first KEXINIT,
  SSH_MSG_EXT_INFO follows the server's first NEWKEYS with
  server-sig-algs (RFC 8308), which makes clients sign with
  rsa-sha2-256/512 rather than SHA-1. With kex-strict-c-v00@openssh.com
  (the server always offers kex-strict-s-v00@openssh.com) the strict
  key exchange applies: during the first exchange only its own
  messages may come, the client's KEXINIT must be its first packet, and
  the sequence numbers start again at zero after every NEWKEYS, so that
  nobody can slip in or remove packets unnoticed (the Terrapin attack).

  The server starts a new key exchange itself after 1 GiB in either
  direction or 2^28 packets, and takes the client's at any time.

  A peer that breaks the protocol raises ESshDisconnect with the reason
  to send (SendDisconnect sends it); the peer's own DISCONNECT raises
  ESshPeerDisconnected.
}
unit Ssh.ServerTransport;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  Ssh.Algorithms,
  Ssh.HostKeys,
  Ssh.KeyExchange,
  Ssh.PacketCiphers,
  Ssh.PacketLayer;

type
  ESshDisconnect = class(Exception)
  private
    FReason: LongWord;
  public
    constructor CreateWithReason(Reason: LongWord; const Description: string);
    property Reason: LongWord read FReason;
  end;

  ESshPeerDisconnected = class(Exception);

  TSshReceivedMessage = record
    Payload: string;
    SequenceNumber: LongWord;
  end;

  TSshServerTransport = class
  private
    FHostKeys: THostKeyArray;
    FHostKeyNames: TStringArray;
    FPackets: TSshPacketLayer;
    FOutput: string;
    FVersionInput: string;
    FVersionReceived: Boolean;
    FClientVersion: string;
    FServerVersion: string;
    FIncoming: array of TSshReceivedMessage;
    FIncomingFirst: Integer;
    FHeldOutgoing: array of string;
    { The key exchange under way. }
    FServerInit: string;
    FClientInit: string;
    FSentInit: Boolean;
    FReceivedInit: Boolean;
    FAwaitingEcdhInit: Boolean;
    FSentNewKeys: Boolean;
    FAwaitingNewKeys: Boolean;
    FNegotiated: TSshNegotiated;
    FPendingReceiveCipher: TSshPacketCipher;
    FSkipGuessedPacket: Boolean;
    { The whole connection. }
    FSessionId: string;
    FFirstExchangeDone: Boolean;
    FStrictKeyExchange: Boolean;
    FClientTakesExtensionInformation: Boolean;
    FClosed: Boolean;
    FKeyExchangeCount: Integer;
    procedure WritePacket(const Payload: string);
    procedure ReceiveVersion;
    procedure ReceivePackets;
    procedure HandlePacket(const Payload: string; SequenceNumber: LongWord);
    procedure StartKeyExchange;
    procedure HandleKeyExchangeInit(const Payload: string; SequenceNumber: LongWord);
    procedure HandleEcdhInit(const Payload: string);
    procedure HandleNewKeys;
    procedure SendExtensionInformation;
    procedure ReleaseHeldMessages;
    procedure QueueIncoming(const Payload: string; SequenceNumber: LongWord);
    function OutgoingIsHeld: Boolean;
    procedure CheckRekeyLimits;
  public
    { HostKeys are not owned and must outlive the transport.
      SoftwareVersion goes after "SSH-2.0-". }
    constructor Create(const HostKeys: THostKeyArray; const SoftwareVersion: string);
    destructor Destroy; override;
    { Sends the version line and the first KEXINIT. }
    procedure Start;
    procedure Receive(const Data: string);
    { The next message for the layers above. }
    function NextMessage(out Message: TSshReceivedMessage): Boolean;
    procedure Send(const Payload: string);
    { SSH_MSG_UNIMPLEMENTED for a message the layers above do not know. }
    procedure SendUnimplemented(SequenceNumber: LongWord);
    { Sends DISCONNECT (at once, past any held messages) and closes. }
    procedure SendDisconnect(Reason: LongWord; const Description: string);
    function TakeOutput: string;
    function HasOutput: Boolean;
    property SessionId: string read FSessionId;
    property ClientVersion: string read FClientVersion;
    property ServerVersion: string read FServerVersion;
    property Negotiated: TSshNegotiated read FNegotiated;
    property FirstExchangeDone: Boolean read FFirstExchangeDone;
    property StrictKeyExchange: Boolean read FStrictKeyExchange;
    property KeyExchangeCount: Integer read FKeyExchangeCount;
    property Closed: Boolean read FClosed;
  end;

implementation

uses
  Ssh.Constants,
  Ssh.Wire,
  Ssh.CipherSuites;

const
  MaximumVersionInput = 8192;
  MaximumVersionLine = 255;
  RekeyByteLimit = QWord(1) shl 30;
  RekeyPacketLimit = QWord(1) shl 28;
  ServerSignatureAlgorithms = 'ssh-ed25519,ecdsa-sha2-nistp256,rsa-sha2-512,rsa-sha2-256';

constructor ESshDisconnect.CreateWithReason(Reason: LongWord; const Description: string);
begin
  inherited Create(Description);
  FReason := Reason;
end;

constructor TSshServerTransport.Create(const HostKeys: THostKeyArray; const SoftwareVersion: string);
begin
  inherited Create;
  FHostKeys := Copy(HostKeys);
  FHostKeyNames := HostKeyAlgorithms(FHostKeys);
  FPackets := TSshPacketLayer.Create;
  FServerVersion := 'SSH-2.0-' + SoftwareVersion;
  FOutput := '';
end;

destructor TSshServerTransport.Destroy;
begin
  FPendingReceiveCipher.Free;
  FPackets.Free;
  inherited Destroy;
end;

procedure TSshServerTransport.Start;
begin
  FOutput := FOutput + FServerVersion + #13#10;
  StartKeyExchange;
end;

procedure TSshServerTransport.WritePacket(const Payload: string);
begin
  FOutput := FOutput + FPackets.EncodePacket(Payload);
end;

function TSshServerTransport.TakeOutput: string;
begin
  Result := FOutput;
  FOutput := '';
end;

function TSshServerTransport.HasOutput: Boolean;
begin
  Result := FOutput <> '';
end;

procedure TSshServerTransport.Receive(const Data: string);
begin
  if FClosed then
    Exit;
  if not FVersionReceived then
  begin
    FVersionInput := FVersionInput + Data;
    ReceiveVersion;
    if not FVersionReceived then
      Exit;
  end
  else
    FPackets.AppendInput(Data);
  ReceivePackets;
end;

{ Lines before the version line are allowed (RFC 4253 section 4.2);
  what follows it is already packets. }
procedure TSshServerTransport.ReceiveVersion;
var
  LineEnd: Integer;
  Line: string;
begin
  repeat
    LineEnd := Pos(#10, FVersionInput);
    if LineEnd = 0 then
    begin
      if Length(FVersionInput) > MaximumVersionInput then
        raise ESshDisconnect.CreateWithReason(DisconnectProtocolError, 'no version line');
      Exit;
    end;
    Line := Copy(FVersionInput, 1, LineEnd - 1);
    Delete(FVersionInput, 1, LineEnd);
    if (Line <> '') and (Line[Length(Line)] = #13) then
      Delete(Line, Length(Line), 1);
    if Length(Line) > MaximumVersionLine then
      raise ESshDisconnect.CreateWithReason(DisconnectProtocolError, 'version line too long');
  until Copy(Line, 1, 4) = 'SSH-';
  if (Copy(Line, 1, 8) <> 'SSH-2.0-') and (Copy(Line, 1, 9) <> 'SSH-1.99-') then
    raise ESshDisconnect.CreateWithReason(DisconnectProtocolVersionNotSupported,
      'protocol version not supported');
  FClientVersion := Line;
  FVersionReceived := True;
  FPackets.AppendInput(FVersionInput);
  FVersionInput := '';
end;

procedure TSshServerTransport.ReceivePackets;
var
  Payload: string;
  SequenceNumber: LongWord;
begin
  try
    while not FClosed and FPackets.NextPayload(Payload, SequenceNumber) do
      HandlePacket(Payload, SequenceNumber);
  except
    on Error: ESshIntegrityError do
      raise ESshDisconnect.CreateWithReason(DisconnectMacError, Error.Message);
    on Error: ESshProtocolError do
      raise ESshDisconnect.CreateWithReason(DisconnectProtocolError, Error.Message);
    on Error: ESshNegotiationError do
      raise ESshDisconnect.CreateWithReason(DisconnectKeyExchangeFailed, Error.Message);
  end;
end;

procedure TSshServerTransport.QueueIncoming(const Payload: string; SequenceNumber: LongWord);
var
  Count: Integer;
begin
  Count := Length(FIncoming);
  SetLength(FIncoming, Count + 1);
  FIncoming[Count].Payload := Payload;
  FIncoming[Count].SequenceNumber := SequenceNumber;
end;

function TSshServerTransport.NextMessage(out Message: TSshReceivedMessage): Boolean;
begin
  Message := Default(TSshReceivedMessage);
  Result := FIncomingFirst < Length(FIncoming);
  if not Result then
  begin
    FIncoming := nil;
    FIncomingFirst := 0;
    Exit;
  end;
  Message := FIncoming[FIncomingFirst];
  FIncoming[FIncomingFirst].Payload := '';
  Inc(FIncomingFirst);
end;

procedure TSshServerTransport.HandlePacket(const Payload: string; SequenceNumber: LongWord);
var
  MessageType: Byte;
  InFirstExchange: Boolean;
begin
  if Payload = '' then
    raise ESshProtocolError.Create('empty packet');
  if FSkipGuessedPacket then
  begin
    { The client guessed the key exchange wrong; its guess is ignored
      (RFC 4253 section 7). }
    FSkipGuessedPacket := False;
    Exit;
  end;
  MessageType := Ord(Payload[1]);
  InFirstExchange := not FFirstExchangeDone;
  if InFirstExchange and FStrictKeyExchange and
    not (MessageType in [MessageKeyExchangeInit, MessageNewKeys, FirstKeyExchangeMethodMessage..LastKeyExchangeMethodMessage]) then
    raise ESshDisconnect.CreateWithReason(DisconnectProtocolError,
      'unexpected message during the strict key exchange');
  case MessageType of
    MessageDisconnect:
      begin
        FClosed := True;
        raise ESshPeerDisconnected.Create('the client disconnected');
      end;
    MessageIgnore, MessageDebug, MessageUnimplemented:
      ;
    MessageKeyExchangeInit:
      HandleKeyExchangeInit(Payload, SequenceNumber);
    MessageKeyExchangeEcdhInit:
      HandleEcdhInit(Payload);
    MessageNewKeys:
      HandleNewKeys;
    MessageExtensionInformation:
      { Not asked for (the server does not offer ext-info-s). }
      ;
  else
    if MessageType in [FirstKeyExchangeMethodMessage..LastKeyExchangeMethodMessage] then
      raise ESshProtocolError.Create('unexpected key exchange message');
    if InFirstExchange then
      raise ESshProtocolError.Create('message before the first key exchange ended');
    QueueIncoming(Payload, SequenceNumber);
  end;
end;

procedure TSshServerTransport.StartKeyExchange;
begin
  FServerInit := MakeServerKeyExchangeInit(FHostKeyNames);
  FSentInit := True;
  FSentNewKeys := False;
  WritePacket(FServerInit);
end;

procedure TSshServerTransport.HandleKeyExchangeInit(const Payload: string; SequenceNumber: LongWord);
var
  ClientInit: TSshKeyExchangeInit;
begin
  if FReceivedInit then
    raise ESshProtocolError.Create('second KEXINIT during a key exchange');
  FReceivedInit := True;
  FClientInit := Payload;
  ClientInit := ParseKeyExchangeInit(Payload);
  if not FFirstExchangeDone then
  begin
    FStrictKeyExchange := NameListContains(ClientInit.KeyExchange, StrictKeyExchangeClient);
    FClientTakesExtensionInformation := NameListContains(ClientInit.KeyExchange, ExtensionInformationClient);
    if FStrictKeyExchange and (SequenceNumber <> 0) then
      raise ESshDisconnect.CreateWithReason(DisconnectProtocolError,
        'strict key exchange: KEXINIT was not the first packet');
  end;
  if not FSentInit then
    StartKeyExchange;
  FNegotiated := NegotiateAlgorithms(ClientInit, FHostKeyNames);
  if ClientInit.FirstPacketFollows and
    ((Length(ClientInit.KeyExchange) = 0) or (ClientInit.KeyExchange[0] <> FNegotiated.KeyExchange) or
    (Length(ClientInit.HostKey) = 0) or (ClientInit.HostKey[0] <> FNegotiated.HostKey)) then
    FSkipGuessedPacket := True;
  FAwaitingEcdhInit := True;
end;

procedure TSshServerTransport.HandleEcdhInit(const Payload: string);
var
  Reader: TSshReader;
  ClientPublicKey: string;
  Ephemeral: TSshEphemeralKey;
  SharedSecret: string;
  HostKey: TSshHostKey;
  HostKeyBlob: string;
  ExchangeHash: string;
  SendCipher: TSshPacketCipher;

  function Derive(Letter: Char; Size: Integer): string;
  begin
    Result := DeriveKey(SharedSecret, ExchangeHash, FSessionId, Letter, Size);
  end;

begin
  if not FAwaitingEcdhInit then
    raise ESshProtocolError.Create('KEX_ECDH_INIT out of turn');
  FAwaitingEcdhInit := False;
  Reader.Start(Payload);
  Reader.ReadByte;
  ClientPublicKey := Reader.ReadString;
  if Length(ClientPublicKey) <> Curve25519PublicKeySize then
    raise ESshDisconnect.CreateWithReason(DisconnectKeyExchangeFailed, 'bad client public key');
  Ephemeral := NewEphemeralKey;
  try
    if not ComputeSharedSecret(Ephemeral, ClientPublicKey, SharedSecret) then
      raise ESshDisconnect.CreateWithReason(DisconnectKeyExchangeFailed, 'client public key of small order');
    HostKey := FindHostKey(FHostKeys, FNegotiated.HostKey);
    HostKeyBlob := HostKey.PublicBlob;
    ExchangeHash := ComputeExchangeHash(FClientVersion, FServerVersion, FClientInit, FServerInit, HostKeyBlob,
      ClientPublicKey, Ephemeral.PublicKey, SharedSecret);
    if FSessionId = '' then
      FSessionId := ExchangeHash;

    WritePacket(SshByte(MessageKeyExchangeEcdhReply) + SshString(HostKeyBlob) + SshString(Ephemeral.PublicKey) +
      SshString(HostKey.Sign(ExchangeHash)));

    FPendingReceiveCipher.Free;
    FPendingReceiveCipher := CreatePacketCipher(FNegotiated.CipherClientToServer,
      Derive(KeyLetterEncryptionClientToServer, CipherKeySize(FNegotiated.CipherClientToServer)),
      Derive(KeyLetterInitialValueClientToServer, CipherInitialValueSize(FNegotiated.CipherClientToServer)));
    SendCipher := CreatePacketCipher(FNegotiated.CipherServerToClient,
      Derive(KeyLetterEncryptionServerToClient, CipherKeySize(FNegotiated.CipherServerToClient)),
      Derive(KeyLetterInitialValueServerToClient, CipherInitialValueSize(FNegotiated.CipherServerToClient)));
  finally
    WipeEphemeralKey(Ephemeral);
    WipeString(SharedSecret);
  end;

  WritePacket(SshByte(MessageNewKeys));
  FPackets.SetSendCipher(SendCipher);
  if FStrictKeyExchange then
    FPackets.ResetSendSequence;
  FSentNewKeys := True;
  FAwaitingNewKeys := True;
  if (FKeyExchangeCount = 0) and FClientTakesExtensionInformation then
    SendExtensionInformation;
  ReleaseHeldMessages;
end;

procedure TSshServerTransport.SendExtensionInformation;
begin
  WritePacket(SshByte(MessageExtensionInformation) + SshUInt32(1) +
    SshString(ExtensionServerSignatureAlgorithms) + SshString(ServerSignatureAlgorithms));
end;

procedure TSshServerTransport.HandleNewKeys;
begin
  if not FAwaitingNewKeys then
    raise ESshProtocolError.Create('NEWKEYS out of turn');
  FAwaitingNewKeys := False;
  FPackets.SetReceiveCipher(FPendingReceiveCipher);
  FPendingReceiveCipher := nil;
  if FStrictKeyExchange then
    FPackets.ResetReceiveSequence;
  { The exchange is over in both directions. }
  FFirstExchangeDone := True;
  FSentInit := False;
  FReceivedInit := False;
  FServerInit := '';
  FClientInit := '';
  Inc(FKeyExchangeCount);
end;

function TSshServerTransport.OutgoingIsHeld: Boolean;
begin
  Result := FSentInit and not FSentNewKeys;
end;

procedure TSshServerTransport.ReleaseHeldMessages;
var
  Index: Integer;
begin
  for Index := 0 to High(FHeldOutgoing) do
    WritePacket(FHeldOutgoing[Index]);
  FHeldOutgoing := nil;
end;

procedure TSshServerTransport.CheckRekeyLimits;
begin
  if not FFirstExchangeDone or FSentInit or FReceivedInit then
    Exit;
  if (FPackets.BytesSent >= RekeyByteLimit) or (FPackets.BytesReceived >= RekeyByteLimit) or
    (FPackets.PacketsSent >= RekeyPacketLimit) or (FPackets.PacketsReceived >= RekeyPacketLimit) then
    StartKeyExchange;
end;

procedure TSshServerTransport.Send(const Payload: string);
var
  Count: Integer;
begin
  if FClosed then
    Exit;
  if OutgoingIsHeld then
  begin
    Count := Length(FHeldOutgoing);
    SetLength(FHeldOutgoing, Count + 1);
    FHeldOutgoing[Count] := Payload;
    Exit;
  end;
  WritePacket(Payload);
  CheckRekeyLimits;
end;

procedure TSshServerTransport.SendUnimplemented(SequenceNumber: LongWord);
begin
  Send(SshByte(MessageUnimplemented) + SshUInt32(SequenceNumber));
end;

procedure TSshServerTransport.SendDisconnect(Reason: LongWord; const Description: string);
begin
  if FClosed then
    Exit;
  WritePacket(SshByte(MessageDisconnect) + SshUInt32(Reason) + SshString(Description) + SshString(''));
  FClosed := True;
end;

end.
