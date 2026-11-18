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
  The binary packet protocol: payloads of many lengths through two
  packet layers (one sending, one receiving) in plain form and with each
  cipher, fed whole, in one go and a byte at a time; the padding rules
  (at least four bytes, whole blocks, the length left out for the
  authenticated ciphers); sequence numbers going up and starting again;
  and refusals of a changed packet and of impossible lengths.
}
unit SshTest.Framing;

{$mode objfpc}
{$H+}

interface

procedure TestPacketFraming;

implementation

uses
  SysUtils,
  TestChecks,
  SshTest.Helpers,
  Ssh.Wire,
  Ssh.PacketCiphers,
  Ssh.CipherSuites,
  Ssh.PacketLayer;

function MakePayload(Size, Seed: Integer): string;
var
  Index: Integer;
begin
  Result := '';
  SetLength(Result, Size);
  for Index := 1 to Size do
    Result[Index] := Chr((Seed * 31 + Index * 7) and $FF);
end;

function MakeKey(Size, Seed: Integer): string;
begin
  Result := MakePayload(Size, Seed);
end;

procedure SetCiphers(Sender, Receiver: TSshPacketLayer; const Name: string);
var
  Key, InitialValue: string;
begin
  if Name = 'none' then
    Exit;
  Key := MakeKey(CipherKeySize(Name), 3);
  InitialValue := MakeKey(CipherInitialValueSize(Name), 4);
  Sender.SetSendCipher(CreatePacketCipher(Name, Key, InitialValue));
  Receiver.SetReceiveCipher(CreatePacketCipher(Name, Key, InitialValue));
end;

procedure CheckRoundTrips(const Name: string);
const
  Sizes: array[0..8] of Integer = (1, 2, 3, 15, 16, 17, 255, 4096, 40000);
var
  Sender, Receiver: TSshPacketLayer;
  Index, Position: Integer;
  Wire, AllWire, Payload: string;
  SequenceNumber: LongWord;
  AllGood, Whole: Boolean;
  Count: Integer;
begin
  Sender := TSshPacketLayer.Create;
  Receiver := TSshPacketLayer.Create;
  try
    SetCiphers(Sender, Receiver, Name);
    { Each packet whole. }
    AllGood := True;
    for Index := 0 to High(Sizes) do
    begin
      Wire := Sender.EncodePacket(MakePayload(Sizes[Index], Index));
      Receiver.AppendInput(Wire);
      if not Receiver.NextPayload(Payload, SequenceNumber) or (Payload <> MakePayload(Sizes[Index], Index)) or
        (SequenceNumber <> LongWord(Index)) then
        AllGood := False;
    end;
    Check(AllGood, Name + ': payloads of 1 to 40000 bytes, whole');
    { All in one buffer. }
    AllWire := '';
    for Index := 0 to High(Sizes) do
      AllWire := AllWire + Sender.EncodePacket(MakePayload(Sizes[Index], Index + 50));
    Receiver.AppendInput(AllWire);
    Count := 0;
    AllGood := True;
    while Receiver.NextPayload(Payload, SequenceNumber) do
    begin
      if Payload <> MakePayload(Sizes[Count], Count + 50) then
        AllGood := False;
      Inc(Count);
    end;
    Check(AllGood and (Count = Length(Sizes)), Name + ': several packets in one buffer');
    { A byte at a time. }
    Wire := Sender.EncodePacket(MakePayload(300, 9));
    Whole := False;
    AllGood := True;
    for Position := 1 to Length(Wire) do
    begin
      Receiver.AppendInput(Wire[Position]);
      if Receiver.NextPayload(Payload, SequenceNumber) then
      begin
        Whole := Payload = MakePayload(300, 9);
        if Position <> Length(Wire) then
          AllGood := False;
      end;
    end;
    Check(Whole and AllGood, Name + ': a packet fed a byte at a time');
    Check(Sender.SendSequence = LongWord(2 * Length(Sizes) + 1), Name + ': sequence numbers counted');
    Sender.ResetSendSequence;
    Receiver.ResetReceiveSequence;
    Receiver.AppendInput(Sender.EncodePacket('after reset'));
    Check(Receiver.NextPayload(Payload, SequenceNumber) and (SequenceNumber = 0) and (Payload = 'after reset'),
      Name + ': sequence numbers start again (strict key exchange)');
  finally
    Sender.Free;
    Receiver.Free;
  end;
end;

procedure CheckPadding(const Name: string; BlockSize: Integer; LengthSeparate: Boolean);
var
  Sender, Receiver: TSshPacketLayer;
  Size: Integer;
  Wire: string;
  PacketLength: Integer;
  Good: Boolean;
  Tag: Integer;
begin
  Sender := TSshPacketLayer.Create;
  Receiver := TSshPacketLayer.Create;
  try
    if Name = 'none' then
      Tag := 0
    else
      Tag := 16;
    SetCiphers(Sender, Receiver, Name);
    Good := True;
    for Size := 0 to 80 do
    begin
      Wire := Sender.EncodePacket(MakePayload(Size, Size));
      PacketLength := Length(Wire) - 4 - Tag;
      if LengthSeparate then
        Good := Good and (PacketLength mod BlockSize = 0)
      else
        Good := Good and ((PacketLength + 4) mod BlockSize = 0);
      { At least 4 bytes of padding. }
      Good := Good and (PacketLength - 1 - Size >= 4) and (PacketLength - 1 - Size < 4 + BlockSize);
    end;
    Check(Good, Name + ': padding of 4 or more bytes to whole blocks');
  finally
    Sender.Free;
    Receiver.Free;
  end;
end;

procedure CheckRefusals(const Name: string);
var
  Sender, Receiver: TSshPacketLayer;
  Wire, Payload: string;
  SequenceNumber: LongWord;
  Raised: Boolean;
begin
  Sender := TSshPacketLayer.Create;
  Receiver := TSshPacketLayer.Create;
  try
    SetCiphers(Sender, Receiver, Name);
    Wire := Sender.EncodePacket('a payload to change');
    Wire[Length(Wire) - 20] := Chr(Ord(Wire[Length(Wire) - 20]) xor $40);
    Receiver.AppendInput(Wire);
    Raised := False;
    try
      Receiver.NextPayload(Payload, SequenceNumber);
    except
      on ESshIntegrityError do
        Raised := True;
    end;
    Check(Raised, Name + ': a changed packet fails its authentication');
  finally
    Sender.Free;
    Receiver.Free;
  end;
end;

procedure CheckBadLengths;
var
  Receiver: TSshPacketLayer;
  Payload: string;
  SequenceNumber: LongWord;
  Raised: Boolean;
begin
  Receiver := TSshPacketLayer.Create;
  try
    Receiver.AppendInput(FromHex('7fffffff'));
    Raised := False;
    try
      Receiver.NextPayload(Payload, SequenceNumber);
    except
      on ESshProtocolError do
        Raised := True;
    end;
    Check(Raised, 'plain: a packet longer than 256 KiB refused');
  finally
    Receiver.Free;
  end;
  Receiver := TSshPacketLayer.Create;
  try
    { 13 bytes: not a whole number of 8-byte blocks with the length. }
    Receiver.AppendInput(FromHex('0000000d'));
    Raised := False;
    try
      Receiver.NextPayload(Payload, SequenceNumber);
    except
      on ESshProtocolError do
        Raised := True;
    end;
    Check(Raised, 'plain: a length that is not whole blocks refused');
  finally
    Receiver.Free;
  end;
  Receiver := TSshPacketLayer.Create;
  try
    { Length 12, padding length 2 (under the minimum of 4). }
    Receiver.AppendInput(FromHex('0000000c02' + '414243444546474849' + '5152'));
    Raised := False;
    try
      Receiver.NextPayload(Payload, SequenceNumber);
    except
      on ESshProtocolError do
        Raised := True;
    end;
    Check(Raised, 'plain: padding under 4 bytes refused');
  finally
    Receiver.Free;
  end;
end;

procedure TestPacketFraming;
begin
  CheckRoundTrips('none');
  CheckRoundTrips('chacha20-poly1305@openssh.com');
  CheckRoundTrips('aes256-gcm@openssh.com');
  CheckRoundTrips('aes128-gcm@openssh.com');
  CheckPadding('none', 8, False);
  CheckPadding('chacha20-poly1305@openssh.com', 8, True);
  CheckPadding('aes256-gcm@openssh.com', 16, True);
  CheckRefusals('chacha20-poly1305@openssh.com');
  CheckRefusals('aes256-gcm@openssh.com');
  CheckBadLengths;
end;

end.
