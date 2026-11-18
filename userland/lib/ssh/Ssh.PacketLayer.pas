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
  The binary packet protocol (RFC 4253 section 6): payloads wrapped in
  packets with random padding, protected by the current cipher of each
  direction, numbered by 32-bit sequence numbers that wrap.

  It does no input or output itself. EncodePacket gives the bytes to
  send; received bytes are appended with AppendInput and whole payloads
  taken with NextPayload as they become complete, so it works the same
  over a socket, a pipe or a test's buffer. A packet that is too long,
  badly padded or fails its authentication raises ESshProtocolError
  (ESshIntegrityError for the last), after which the connection is
  useless.

  The ciphers start plain; the transport sets new ones after each key
  exchange, and resets the sequence numbers there when the strict key
  exchange was agreed.
}
unit Ssh.PacketLayer;

{$mode objfpc}{$H+}

interface

uses
  Ssh.Wire,
  Ssh.PacketCiphers;

const
  { The longest packet taken (OpenSSH's limit); RFC 4253 asks for at
    least 35000. }
  MaximumPacketLength = 256 * 1024;
  MinimumPadding = 4;

type
  { The authentication tag of a packet did not match. }
  ESshIntegrityError = class(ESshProtocolError);

  TSshPacketLayer = class
  private
    FSendCipher: TSshPacketCipher;
    FReceiveCipher: TSshPacketCipher;
    FSendSequence: LongWord;
    FReceiveSequence: LongWord;
    FInput: string;
    { Bytes of FInput already consumed. }
    FInputConsumed: Integer;
    FPacketLength: LongWord;
    FHavePacketLength: Boolean;
    FBytesSent: QWord;
    FBytesReceived: QWord;
    FPacketsSent: QWord;
    FPacketsReceived: QWord;
    function PaddingFor(PayloadLength: Integer): Integer;
    procedure CheckPacketLength(PacketLength: LongWord);
    procedure DropConsumedInput;
  public
    constructor Create;
    destructor Destroy; override;
    { The bytes that carry Payload; the send sequence number goes up. }
    function EncodePacket(const Payload: string): string;
    procedure AppendInput(const Data: string);
    { The next whole payload received and its sequence number; False
      while more bytes are needed. }
    function NextPayload(out Payload: string; out SequenceNumber: LongWord): Boolean;
    { Takes ownership of the cipher (the old one is freed) and starts
      counting bytes for rekeying again. }
    procedure SetSendCipher(Cipher: TSshPacketCipher);
    procedure SetReceiveCipher(Cipher: TSshPacketCipher);
    procedure ResetSendSequence;
    procedure ResetReceiveSequence;
    { Bytes not yet taken as packets. }
    function BufferedInput: Integer;
    property SendSequence: LongWord read FSendSequence;
    property ReceiveSequence: LongWord read FReceiveSequence;
    { Since the ciphers of each direction were last set. }
    property BytesSent: QWord read FBytesSent;
    property BytesReceived: QWord read FBytesReceived;
    property PacketsSent: QWord read FPacketsSent;
    property PacketsReceived: QWord read FPacketsReceived;
  end;

implementation

uses
  Crypto.Random;

{ Sequence numbers wrap around after 2^32 packets. }
function NextSequence(Sequence: LongWord): LongWord;
begin
  Result := LongWord((QWord(Sequence) + 1) and $FFFFFFFF);
end;

constructor TSshPacketLayer.Create;
begin
  inherited Create;
  FSendCipher := TSshPlainCipher.Create;
  FReceiveCipher := TSshPlainCipher.Create;
  FInput := '';
  FInputConsumed := 0;
end;

destructor TSshPacketLayer.Destroy;
begin
  FSendCipher.Free;
  FReceiveCipher.Free;
  inherited Destroy;
end;

function TSshPacketLayer.PaddingFor(PayloadLength: Integer): Integer;
var
  Block: Integer;
  Covered: Integer;
begin
  Block := FSendCipher.BlockSize;
  { What the alignment covers: the padding length byte and the payload,
    and the length field unless the cipher keeps it apart. }
  Covered := 1 + PayloadLength;
  if not FSendCipher.LengthIsSeparate then
    Covered := Covered + 4;
  Result := Block - (Covered mod Block);
  if Result < MinimumPadding then
    Result := Result + Block;
end;

function TSshPacketLayer.EncodePacket(const Payload: string): string;
var
  Padding: Integer;
  PaddingBytes: string;
  Packet: string;
begin
  Padding := PaddingFor(Length(Payload));
  PaddingBytes := '';
  SetLength(PaddingBytes, Padding);
  RandomBytes(@PaddingBytes[1], Padding);
  Packet := BigEndian32Bytes(LongWord(1 + Length(Payload) + Padding)) + Chr(Padding) + Payload + PaddingBytes;
  Result := FSendCipher.Seal(FSendSequence, Packet);
  FSendSequence := NextSequence(FSendSequence);
  FBytesSent := FBytesSent + QWord(Length(Result));
  Inc(FPacketsSent);
end;

procedure TSshPacketLayer.AppendInput(const Data: string);
begin
  FInput := FInput + Data;
end;

procedure TSshPacketLayer.CheckPacketLength(PacketLength: LongWord);
var
  Covered: QWord;
begin
  if (PacketLength < 1 + MinimumPadding) or (PacketLength > MaximumPacketLength) then
    raise ESshProtocolError.Create('bad packet length');
  Covered := PacketLength;
  if not FReceiveCipher.LengthIsSeparate then
    Covered := Covered + 4;
  if Covered mod QWord(FReceiveCipher.BlockSize) <> 0 then
    raise ESshProtocolError.Create('packet length is not a whole number of blocks');
end;

procedure TSshPacketLayer.DropConsumedInput;
begin
  if FInputConsumed = 0 then
    Exit;
  Delete(FInput, 1, FInputConsumed);
  FInputConsumed := 0;
end;

function TSshPacketLayer.NextPayload(out Payload: string; out SequenceNumber: LongWord): Boolean;
var
  Available: Integer;
  WireLength: Integer;
  Wire: string;
  Body: string;
  Padding: Integer;
begin
  Payload := '';
  SequenceNumber := FReceiveSequence;
  Result := False;
  Available := Length(FInput) - FInputConsumed;
  if not FHavePacketLength then
  begin
    if Available < 4 then
      Exit;
    FPacketLength := FReceiveCipher.DecryptLength(FReceiveSequence, Copy(FInput, FInputConsumed + 1, 4));
    CheckPacketLength(FPacketLength);
    FHavePacketLength := True;
  end;
  WireLength := 4 + Integer(FPacketLength) + FReceiveCipher.TagSize;
  if Available < WireLength then
    Exit;
  Wire := Copy(FInput, FInputConsumed + 1, WireLength);
  FInputConsumed := FInputConsumed + WireLength;
  FHavePacketLength := False;
  if FInputConsumed * 2 > Length(FInput) then
    DropConsumedInput;

  if not FReceiveCipher.Open(FReceiveSequence, Wire, FPacketLength, Body) then
    raise ESshIntegrityError.Create('packet authentication failed');
  Padding := Ord(Body[1]);
  if (Padding < MinimumPadding) or (Padding + 1 > Length(Body)) then
    raise ESshProtocolError.Create('bad padding length');
  Payload := Copy(Body, 2, Length(Body) - 1 - Padding);
  WipeString(Body);
  SequenceNumber := FReceiveSequence;
  FReceiveSequence := NextSequence(FReceiveSequence);
  FBytesReceived := FBytesReceived + QWord(WireLength);
  Inc(FPacketsReceived);
  Result := True;
end;

procedure TSshPacketLayer.SetSendCipher(Cipher: TSshPacketCipher);
begin
  FSendCipher.Free;
  FSendCipher := Cipher;
  FBytesSent := 0;
  FPacketsSent := 0;
end;

procedure TSshPacketLayer.SetReceiveCipher(Cipher: TSshPacketCipher);
begin
  FReceiveCipher.Free;
  FReceiveCipher := Cipher;
  FBytesReceived := 0;
  FPacketsReceived := 0;
end;

procedure TSshPacketLayer.ResetSendSequence;
begin
  FSendSequence := 0;
end;

procedure TSshPacketLayer.ResetReceiveSequence;
begin
  FReceiveSequence := 0;
end;

function TSshPacketLayer.BufferedInput: Integer;
begin
  Result := Length(FInput) - FInputConsumed;
end;

end.
