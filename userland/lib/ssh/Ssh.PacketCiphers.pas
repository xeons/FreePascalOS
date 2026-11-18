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
  What protects packets in one direction: the base of the ciphers, and
  the plain one used before the first key exchange ends.

  A packet (RFC 4253 section 6) is

    uint32 packet_length, byte padding_length, payload, padding

  and the cipher turns it into what goes on the wire (Seal) and back
  (DecryptLength on the first four bytes as they arrive, then Open on
  the whole packet and its tag). The ciphers here are all authenticated
  encryption, so there is no separate MAC: the length is either
  encrypted with a key of its own (chacha20-poly1305@openssh.com) or
  sent in the clear and authenticated (AES-GCM).
}
unit Ssh.PacketCiphers;

{$mode objfpc}{$H+}

interface

type
  TSshPacketCipher = class
  public
    { Padding makes the packet a whole number of these. }
    function BlockSize: Integer; virtual; abstract;
    { Bytes of authentication tag after the packet. }
    function TagSize: Integer; virtual; abstract;
    { True when the length field is left out of the block alignment
      (it is not encrypted with the rest). }
    function LengthIsSeparate: Boolean; virtual; abstract;
    { Packet: the four length bytes and the rest; the result is what is
      sent, its tag included. }
    function Seal(SequenceNumber: LongWord; const Packet: string): string; virtual; abstract;
    { The packet length from the first four bytes received. }
    function DecryptLength(SequenceNumber: LongWord; const LengthBytes: string): LongWord; virtual; abstract;
    { Wire: the four length bytes, PacketLength bytes and the tag.
      Body: padding_length, payload and padding. False when the tag is
      wrong. }
    function Open(SequenceNumber: LongWord; const Wire: string; PacketLength: LongWord;
      out Body: string): Boolean; virtual; abstract;
  end;

  { No protection: the packets of the first key exchange. }
  TSshPlainCipher = class(TSshPacketCipher)
  public
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
  Ssh.Wire;

function TSshPlainCipher.BlockSize: Integer;
begin
  Result := 8;
end;

function TSshPlainCipher.TagSize: Integer;
begin
  Result := 0;
end;

function TSshPlainCipher.LengthIsSeparate: Boolean;
begin
  Result := False;
end;

function TSshPlainCipher.Seal(SequenceNumber: LongWord; const Packet: string): string;
begin
  Result := Packet;
end;

function TSshPlainCipher.DecryptLength(SequenceNumber: LongWord; const LengthBytes: string): LongWord;
begin
  Result := ReadBigEndian32(LengthBytes, 1);
end;

function TSshPlainCipher.Open(SequenceNumber: LongWord; const Wire: string; PacketLength: LongWord;
  out Body: string): Boolean;
begin
  Body := Copy(Wire, 5, Integer(PacketLength));
  Result := True;
end;

end.
