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
  chacha20-poly1305@openssh.com (OpenSSH's PROTOCOL.chacha20poly1305).

  The 64-byte key is two ChaCha20 keys: the first 32 bytes encrypt the
  packet (the "main" key), the last 32 the four length bytes (the
  "header" key). Both use the packet's sequence number as their 64-bit
  nonce (big endian). The main key's block 0 gives the Poly1305 key,
  and the packet is encrypted from block 1; the tag covers the
  encrypted length and the encrypted packet.

  This is the original ChaCha20, with a 64-bit counter and nonce. With
  the IETF variant of Crypto.ChaCha20 (32-bit counter, 96-bit nonce) it
  is the nonce 00000000 || sequence number: the counter's high word is
  always zero, as a packet is far shorter than 2^32 blocks.
}
unit Ssh.ChaChaPolyCipher;

{$mode objfpc}{$H+}

interface

uses
  Ssh.PacketCiphers;

const
  ChaChaPolyKeySize = 64;

type
  TSshChaChaPolyCipher = class(TSshPacketCipher)
  private
    FMainKey: array[0..31] of Byte;
    FHeaderKey: array[0..31] of Byte;
    procedure MakeNonce(SequenceNumber: LongWord; Nonce: PByte);
    procedure ApplyStream(Key: PByte; SequenceNumber: LongWord; Counter: LongWord; Source, Destination: PByte;
      Count: Integer);
    procedure ComputeTag(SequenceNumber: LongWord; Data: PByte; Count: Integer; Tag: PByte);
  public
    { Key: ChaChaPolyKeySize bytes. }
    constructor Create(const Key: string);
    destructor Destroy; override;
    function BlockSize: Integer; override;
    function TagSize: Integer; override;
    function LengthIsSeparate: Boolean; override;
    function Seal(SequenceNumber: LongWord; const Packet: string): string; override;
    function DecryptLength(SequenceNumber: LongWord; const LengthBytes: string): LongWord; override;
    function Open(SequenceNumber: LongWord; const Wire: string; PacketLength: LongWord;
      out Body: string): Boolean; override;
  end;

implementation

uses
  Crypto.Bits,
  Crypto.ChaCha20,
  Crypto.Poly1305,
  Ssh.Wire;

const
  PolyTagSize = 16;

constructor TSshChaChaPolyCipher.Create(const Key: string);
begin
  inherited Create;
  Move(Key[1], FMainKey[0], 32);
  Move(Key[33], FHeaderKey[0], 32);
end;

destructor TSshChaChaPolyCipher.Destroy;
begin
  WipeMemory(@FMainKey[0], SizeOf(FMainKey));
  WipeMemory(@FHeaderKey[0], SizeOf(FHeaderKey));
  inherited Destroy;
end;

function TSshChaChaPolyCipher.BlockSize: Integer;
begin
  Result := 8;
end;

function TSshChaChaPolyCipher.TagSize: Integer;
begin
  Result := PolyTagSize;
end;

function TSshChaChaPolyCipher.LengthIsSeparate: Boolean;
begin
  Result := True;
end;

procedure TSshChaChaPolyCipher.MakeNonce(SequenceNumber: LongWord; Nonce: PByte);
begin
  FillChar(Nonce^, ChaCha20NonceSize, 0);
  { Bytes 4..11: the 64-bit sequence number, big endian (its top half is
    zero: SSH sequence numbers are 32 bits). }
  StoreBigEndian32(Nonce + 8, SequenceNumber);
end;

procedure TSshChaChaPolyCipher.ApplyStream(Key: PByte; SequenceNumber: LongWord; Counter: LongWord;
  Source, Destination: PByte; Count: Integer);
var
  Nonce: array[0..ChaCha20NonceSize - 1] of Byte;
  Context: TChaCha20Context;
begin
  MakeNonce(SequenceNumber, @Nonce[0]);
  BeginChaCha20(Context, Key, @Nonce[0], Counter);
  ApplyChaCha20(Context, Source, Destination, Count);
  EndChaCha20(Context);
end;

procedure TSshChaChaPolyCipher.ComputeTag(SequenceNumber: LongWord; Data: PByte; Count: Integer; Tag: PByte);
var
  PolyKey: array[0..Poly1305KeySize - 1] of Byte;
begin
  FillChar(PolyKey, SizeOf(PolyKey), 0);
  ApplyStream(@FMainKey[0], SequenceNumber, 0, @PolyKey[0], @PolyKey[0], Poly1305KeySize);
  ComputePoly1305(@PolyKey[0], Data, Count, Tag);
  WipeMemory(@PolyKey[0], SizeOf(PolyKey));
end;

function TSshChaChaPolyCipher.Seal(SequenceNumber: LongWord; const Packet: string): string;
var
  Count: Integer;
begin
  Count := Length(Packet);
  Result := '';
  SetLength(Result, Count + PolyTagSize);
  ApplyStream(@FHeaderKey[0], SequenceNumber, 0, @Packet[1], @Result[1], 4);
  ApplyStream(@FMainKey[0], SequenceNumber, 1, @Packet[5], @Result[5], Count - 4);
  ComputeTag(SequenceNumber, @Result[1], Count, @Result[Count + 1]);
end;

function TSshChaChaPolyCipher.DecryptLength(SequenceNumber: LongWord; const LengthBytes: string): LongWord;
var
  Plain: array[0..3] of Byte;
begin
  ApplyStream(@FHeaderKey[0], SequenceNumber, 0, @LengthBytes[1], @Plain[0], 4);
  Result := LoadBigEndian32(@Plain[0]);
end;

function TSshChaChaPolyCipher.Open(SequenceNumber: LongWord; const Wire: string; PacketLength: LongWord;
  out Body: string): Boolean;
var
  Expected: array[0..PolyTagSize - 1] of Byte;
  Count: Integer;
begin
  Body := '';
  Count := 4 + Integer(PacketLength);
  if Length(Wire) < Count + PolyTagSize then
    Exit(False);
  ComputeTag(SequenceNumber, @Wire[1], Count, @Expected[0]);
  if not ConstantTimeEqual(@Expected[0], @Wire[Count + 1], PolyTagSize) then
    Exit(False);
  SetLength(Body, Integer(PacketLength));
  if PacketLength > 0 then
    ApplyStream(@FMainKey[0], SequenceNumber, 1, @Wire[5], @Body[1], Integer(PacketLength));
  Result := True;
end;

end.
