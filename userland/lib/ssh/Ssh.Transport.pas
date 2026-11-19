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
  The SSH transport (RFC 4253), what both sides share: the version
  lines, the binary packets, the key exchange's bookkeeping (KEXINIT
  each way, NEWKEYS, the keys derived and put to use), rekeying, and
  the transport's own messages. Ssh.ServerTransport and
  Ssh.ClientTransport add each side's half of the key exchange.

  It does no input or output: received bytes go in with Receive, the
  messages for the layers above (user authentication, connection) come
  out of NextMessage, their messages go in with Send, and TakeOutput
  gives the bytes to send. While a key exchange runs, messages sent are
  held back and go out once the new keys are in use.

  Strict key exchange (OpenSSH's kex-strict-*-v00@openssh.com, on when
  both offer it): during the first exchange only its own messages may
  come, the peer's KEXINIT must be its first packet, and the sequence
  numbers start again at zero after every NEWKEYS, so that nobody can
  slip in or remove packets unnoticed (the Terrapin attack).

  A new key exchange starts after 1 GiB in either direction or 2^28
  packets, and the peer's is taken at any time.

  A peer that breaks the protocol raises ESshDisconnect with the reason
  to send (SendDisconnect sends it); the peer's own DISCONNECT raises
  ESshPeerDisconnected.
}
unit Ssh.Transport;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  Ssh.Algorithms,
  Ssh.KeyExchangeMethods,
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

  TSshTransport = class
  private
    FPackets: TSshPacketLayer;
    FOutput: string;
    FVersionInput: string;
    FVersionReceived: Boolean;
    FIncoming: array of TSshReceivedMessage;
    FIncomingFirst: Integer;
    FHeldOutgoing: array of string;
    FSentNewKeys: Boolean;
    FAwaitingNewKeys: Boolean;
    FPendingReceiveCipher: TSshPacketCipher;
    FSkipGuessedPacket: Boolean;
    FClosed: Boolean;
    FKeyExchangeCount: Integer;
    procedure ReceiveVersion;
    procedure ReceivePackets;
    procedure HandlePacket(const Payload: string; SequenceNumber: LongWord);
    procedure HandleKeyExchangeInit(const Payload: string; SequenceNumber: LongWord);
    procedure HandleNewKeys;
    procedure ReleaseHeldMessages;
    procedure QueueIncoming(const Payload: string; SequenceNumber: LongWord);
    function OutgoingIsHeld: Boolean;
    procedure CheckRekeyLimits;
  protected
    FLocalVersion: string;
    FPeerVersion: string;
    FLocalInit: string;
    FPeerInit: string;
    FSentInit: Boolean;
    FReceivedInit: Boolean;
    FNegotiated: TSshNegotiated;
    FMethod: TSshKeyExchangeMethod;
    FSessionId: string;
    FFirstExchangeDone: Boolean;
    FStrictKeyExchange: Boolean;
    procedure WritePacket(const Payload: string);
    procedure StartKeyExchange;
    function IsServer: Boolean; virtual; abstract;
    function MakeKeyExchangeInit: string; virtual; abstract;
    { The peer's KEXINIT has come and both are known: negotiate, decide
      on strict kex (first exchange) and start this side's part. }
    procedure KeyExchangeInitsKnown(const Peer: TSshKeyExchangeInit; SequenceNumber: LongWord); virtual; abstract;
    { Messages 30 to 49. }
    procedure HandleKeyExchangeMessage(const Payload: string); virtual; abstract;
    procedure HandleExtensionInformation(const Payload: string); virtual;
    { After this side's first NEWKEYS has gone out. }
    procedure FirstNewKeysSent; virtual;
    { Derives both directions' keys from K and H, sends NEWKEYS and
      starts sending with the new keys. }
    procedure UseNewKeys(const EncodedSecret, ExchangeHash: string);
    function ClientVersionLine: string;
    function ServerVersionLine: string;
    function ClientInitPayload: string;
    function ServerInitPayload: string;
  public
    { SoftwareVersion goes after "SSH-2.0-". }
    constructor Create(const SoftwareVersion: string);
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
    { Starts a new key exchange unless one is under way. }
    procedure Rekey;
    function TakeOutput: string;
    function HasOutput: Boolean;
    property SessionId: string read FSessionId;
    property ClientVersion: string read ClientVersionLine;
    property ServerVersion: string read ServerVersionLine;
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
  Ssh.KeyExchange,
  Ssh.CipherSuites;

const
  MaximumVersionInput = 8192;
  MaximumVersionLine = 255;
  RekeyByteLimit = QWord(1) shl 30;
  RekeyPacketLimit = QWord(1) shl 28;

constructor ESshDisconnect.CreateWithReason(Reason: LongWord; const Description: string);
begin
  inherited Create(Description);
  FReason := Reason;
end;

constructor TSshTransport.Create(const SoftwareVersion: string);
begin
  inherited Create;
  FPackets := TSshPacketLayer.Create;
  FLocalVersion := 'SSH-2.0-' + SoftwareVersion;
  FOutput := '';
end;

destructor TSshTransport.Destroy;
begin
  FPendingReceiveCipher.Free;
  FPackets.Free;
  inherited Destroy;
end;

function TSshTransport.ClientVersionLine: string;
begin
  if IsServer then
    Result := FPeerVersion
  else
    Result := FLocalVersion;
end;

function TSshTransport.ServerVersionLine: string;
begin
  if IsServer then
    Result := FLocalVersion
  else
    Result := FPeerVersion;
end;

function TSshTransport.ClientInitPayload: string;
begin
  if IsServer then
    Result := FPeerInit
  else
    Result := FLocalInit;
end;

function TSshTransport.ServerInitPayload: string;
begin
  if IsServer then
    Result := FLocalInit
  else
    Result := FPeerInit;
end;

procedure TSshTransport.Start;
begin
  FOutput := FOutput + FLocalVersion + #13#10;
  StartKeyExchange;
end;

procedure TSshTransport.WritePacket(const Payload: string);
begin
  FOutput := FOutput + FPackets.EncodePacket(Payload);
end;

function TSshTransport.TakeOutput: string;
begin
  Result := FOutput;
  FOutput := '';
end;

function TSshTransport.HasOutput: Boolean;
begin
  Result := FOutput <> '';
end;

procedure TSshTransport.Receive(const Data: string);
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
procedure TSshTransport.ReceiveVersion;
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
  FPeerVersion := Line;
  FVersionReceived := True;
  FPackets.AppendInput(FVersionInput);
  FVersionInput := '';
end;

procedure TSshTransport.ReceivePackets;
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

procedure TSshTransport.QueueIncoming(const Payload: string; SequenceNumber: LongWord);
var
  Count: Integer;
begin
  Count := Length(FIncoming);
  SetLength(FIncoming, Count + 1);
  FIncoming[Count].Payload := Payload;
  FIncoming[Count].SequenceNumber := SequenceNumber;
end;

function TSshTransport.NextMessage(out Message: TSshReceivedMessage): Boolean;
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

procedure TSshTransport.HandlePacket(const Payload: string; SequenceNumber: LongWord);
var
  MessageType: Byte;
  InFirstExchange: Boolean;
begin
  if Payload = '' then
    raise ESshProtocolError.Create('empty packet');
  if FSkipGuessedPacket then
  begin
    { The peer guessed the key exchange wrong; its guess is ignored
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
        raise ESshPeerDisconnected.Create('the peer disconnected');
      end;
    MessageIgnore, MessageDebug, MessageUnimplemented:
      ;
    MessageKeyExchangeInit:
      HandleKeyExchangeInit(Payload, SequenceNumber);
    MessageNewKeys:
      HandleNewKeys;
    MessageExtensionInformation:
      HandleExtensionInformation(Payload);
  else
    if MessageType in [FirstKeyExchangeMethodMessage..LastKeyExchangeMethodMessage] then
    begin
      if not FReceivedInit then
        raise ESshProtocolError.Create('unexpected key exchange message');
      HandleKeyExchangeMessage(Payload);
    end
    else
    begin
      if InFirstExchange then
        raise ESshProtocolError.Create('message before the first key exchange ended');
      QueueIncoming(Payload, SequenceNumber);
    end;
  end;
end;

procedure TSshTransport.HandleExtensionInformation(const Payload: string);
begin
end;

procedure TSshTransport.FirstNewKeysSent;
begin
end;

procedure TSshTransport.StartKeyExchange;
begin
  FLocalInit := MakeKeyExchangeInit;
  FSentInit := True;
  FSentNewKeys := False;
  WritePacket(FLocalInit);
end;

procedure TSshTransport.Rekey;
begin
  if FFirstExchangeDone and not FSentInit and not FReceivedInit and not FClosed then
    StartKeyExchange;
end;

procedure TSshTransport.HandleKeyExchangeInit(const Payload: string; SequenceNumber: LongWord);
var
  Peer, Own: TSshKeyExchangeInit;
begin
  if FReceivedInit then
    raise ESshProtocolError.Create('second KEXINIT during a key exchange');
  FReceivedInit := True;
  FPeerInit := Payload;
  Peer := ParseKeyExchangeInit(Payload);
  if not FSentInit then
    StartKeyExchange;
  KeyExchangeInitsKnown(Peer, SequenceNumber);
  if not FindKeyExchangeMethod(FNegotiated.KeyExchange, FMethod) then
    raise ESshNegotiationError.Create('no key exchange method in common');
  if Peer.FirstPacketFollows then
  begin
    Own := ParseKeyExchangeInit(FLocalInit);
    if (Length(Peer.KeyExchange) = 0) or (Length(Own.KeyExchange) = 0) or
      (Peer.KeyExchange[0] <> Own.KeyExchange[0]) or (Length(Peer.HostKey) = 0) or (Length(Own.HostKey) = 0) or
      (Peer.HostKey[0] <> Own.HostKey[0]) then
      FSkipGuessedPacket := True;
  end;
end;

procedure TSshTransport.UseNewKeys(const EncodedSecret, ExchangeHash: string);
var
  ClientToServer, ServerToClient, SendCipher: TSshPacketCipher;

  function Derive(Letter: Char; Size: Integer): string;
  begin
    Result := DeriveExchangeKey(FMethod, EncodedSecret, ExchangeHash, FSessionId, Letter, Size);
  end;

begin
  ClientToServer := CreatePacketCipher(FNegotiated.CipherClientToServer,
    Derive(KeyLetterEncryptionClientToServer, CipherKeySize(FNegotiated.CipherClientToServer)),
    Derive(KeyLetterInitialValueClientToServer, CipherInitialValueSize(FNegotiated.CipherClientToServer)));
  ServerToClient := CreatePacketCipher(FNegotiated.CipherServerToClient,
    Derive(KeyLetterEncryptionServerToClient, CipherKeySize(FNegotiated.CipherServerToClient)),
    Derive(KeyLetterInitialValueServerToClient, CipherInitialValueSize(FNegotiated.CipherServerToClient)));
  FPendingReceiveCipher.Free;
  if IsServer then
  begin
    FPendingReceiveCipher := ClientToServer;
    SendCipher := ServerToClient;
  end
  else
  begin
    FPendingReceiveCipher := ServerToClient;
    SendCipher := ClientToServer;
  end;
  WritePacket(SshByte(MessageNewKeys));
  FPackets.SetSendCipher(SendCipher);
  if FStrictKeyExchange then
    FPackets.ResetSendSequence;
  FSentNewKeys := True;
  FAwaitingNewKeys := True;
  if FKeyExchangeCount = 0 then
    FirstNewKeysSent;
  ReleaseHeldMessages;
end;

procedure TSshTransport.HandleNewKeys;
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
  FLocalInit := '';
  FPeerInit := '';
  Inc(FKeyExchangeCount);
end;

function TSshTransport.OutgoingIsHeld: Boolean;
begin
  Result := FSentInit and not FSentNewKeys;
end;

procedure TSshTransport.ReleaseHeldMessages;
var
  Index: Integer;
begin
  for Index := 0 to High(FHeldOutgoing) do
    WritePacket(FHeldOutgoing[Index]);
  FHeldOutgoing := nil;
end;

procedure TSshTransport.CheckRekeyLimits;
begin
  if not FFirstExchangeDone or FSentInit or FReceivedInit then
    Exit;
  if (FPackets.BytesSent >= RekeyByteLimit) or (FPackets.BytesReceived >= RekeyByteLimit) or
    (FPackets.PacketsSent >= RekeyPacketLimit) or (FPackets.PacketsReceived >= RekeyPacketLimit) then
    StartKeyExchange;
end;

procedure TSshTransport.Send(const Payload: string);
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

procedure TSshTransport.SendUnimplemented(SequenceNumber: LongWord);
begin
  Send(SshByte(MessageUnimplemented) + SshUInt32(SequenceNumber));
end;

procedure TSshTransport.SendDisconnect(Reason: LongWord; const Description: string);
begin
  if FClosed then
    Exit;
  WritePacket(SshByte(MessageDisconnect) + SshUInt32(Reason) + SshString(Description) + SshString(''));
  FClosed := True;
end;

end.
