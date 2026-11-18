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
  aes128-gcm@openssh.com and aes256-gcm@openssh.com (RFC 5647 as
  OpenSSH names it).

  The packet length goes in the clear as the additional data; padding
  length, payload and padding are encrypted, a multiple of 16 bytes. The
  12-byte nonce is the key exchange's initial value: four fixed bytes
  and an 8-byte invocation counter, which goes up by one (as a big
  endian number) after every packet.
}
unit Ssh.AesGcmCipher;

{$mode objfpc}{$H+}

interface

uses
  Crypto.AesGcm,
  Ssh.PacketCiphers;

const
  AesGcmInitialValueSize = 12;

type
  TSshAesGcmCipher = class(TSshPacketCipher)
  private
    FKey: TAesGcmKey;
    FNonce: array[0..AesGcmInitialValueSize - 1] of Byte;
    procedure AdvanceNonce;
  public
    { Key: 16 or 32 bytes; InitialValue: 12 bytes. }
    constructor Create(const Key, InitialValue: string);
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
  Ssh.Wire;

constructor TSshAesGcmCipher.Create(const Key, InitialValue: string);
begin
  inherited Create;
  PrepareAesGcmKey(FKey, @Key[1], Length(Key));
  Move(InitialValue[1], FNonce[0], AesGcmInitialValueSize);
end;

destructor TSshAesGcmCipher.Destroy;
begin
  WipeAesGcmKey(FKey);
  inherited Destroy;
end;

function TSshAesGcmCipher.BlockSize: Integer;
begin
  Result := 16;
end;

function TSshAesGcmCipher.TagSize: Integer;
begin
  Result := AesGcmTagSize;
end;

function TSshAesGcmCipher.LengthIsSeparate: Boolean;
begin
  Result := True;
end;

procedure TSshAesGcmCipher.AdvanceNonce;
var
  Index: Integer;
begin
  Index := AesGcmInitialValueSize - 1;
  while Index >= 4 do
  begin
    FNonce[Index] := Byte(FNonce[Index] + 1);
    if FNonce[Index] <> 0 then
      Break;
    Dec(Index);
  end;
end;

function TSshAesGcmCipher.Seal(SequenceNumber: LongWord; const Packet: string): string;
var
  Count: Integer;
begin
  Count := Length(Packet);
  Result := '';
  SetLength(Result, Count + AesGcmTagSize);
  Move(Packet[1], Result[1], 4);
  SealAesGcm(FKey, @FNonce[0], @Packet[1], 4, @Packet[5], Count - 4, @Result[5], @Result[Count + 1]);
  AdvanceNonce;
end;

function TSshAesGcmCipher.DecryptLength(SequenceNumber: LongWord; const LengthBytes: string): LongWord;
begin
  Result := ReadBigEndian32(LengthBytes, 1);
end;

function TSshAesGcmCipher.Open(SequenceNumber: LongWord; const Wire: string; PacketLength: LongWord;
  out Body: string): Boolean;
var
  Count: Integer;
begin
  Body := '';
  Count := 4 + Integer(PacketLength);
  if Length(Wire) < Count + AesGcmTagSize then
    Exit(False);
  SetLength(Body, Integer(PacketLength));
  Result := OpenAesGcm(FKey, @FNonce[0], @Wire[1], 4, @Wire[5], PacketLength, @Wire[Count + 1], @Body[1]);
  if Result then
    AdvanceNonce
  else
    Body := '';
end;

end.
