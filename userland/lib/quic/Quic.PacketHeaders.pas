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
  QUIC packet headers (RFC 9000 section 17), as far as they can be read
  before header protection is removed:

    long header   1 1 TT xxxx | version | DCID len, DCID | SCID len, SCID
                  Initial: token length, token; Initial, 0-RTT and
                  Handshake: length (of packet number and payload),
                  then the protected packet number
                  Retry: retry token, 16-byte integrity tag
                  version 0: Version Negotiation, a list of versions
    short header  0 1 S RR K PP | DCID (of the length this end chose)
                  | packet number | payload

  A datagram may carry several long header packets one after another
  and a short header one last (coalescing, section 12.2):
  ParsePacketHeader tells where the packet ends (PacketLength).

  Packet numbers are sent truncated to 1-4 bytes (section 17.1); the
  receiver puts the full number back from the largest it has seen
  (appendix A.3).
}
unit Quic.PacketHeaders;

{$mode objfpc}
{$pointermath on}

interface

uses
  Quic.ConnectionIds;

type
  TQuicPacketType = (PacketInitial, PacketZeroRtt, PacketHandshake, PacketRetry, PacketVersionNegotiation,
    PacketOneRtt);

  TQuicPacketHeader = record
    PacketType: TQuicPacketType;
    IsLongHeader: Boolean;
    Version: LongWord;
    DestinationId: TQuicConnectionId;
    SourceId: TQuicConnectionId;
    { Initial and Retry. }
    Token: PByte;
    TokenLength: PtrUInt;
    { Where the (protected) packet number starts. }
    PacketNumberOffset: PtrUInt;
    { The whole packet (header included); for a short header packet or
      a Retry, the rest of the datagram. }
    PacketLength: PtrUInt;
  end;

{ The header of the packet at Data (Available bytes left in the
  datagram); ShortIdLength is the length of this end's connection IDs.
  False when the packet cannot be read (it and what follows it in the
  datagram are dropped). A long header packet of a version other than
  1 comes back with its version (the caller drops it), as does Version
  Negotiation (version 0). }
function ParsePacketHeader(Data: PByte; Available: PtrUInt; ShortIdLength: Integer;
  out Header: TQuicPacketHeader): Boolean;
{ The first byte's type bits for a long header packet. }
function LongHeaderTypeBits(PacketType: TQuicPacketType): Byte;
{ How many bytes to send PacketNumber in, given the largest number the
  peer acknowledged in that space (LargestAcknowledged = High(QWord)
  when none): enough for twice the unacknowledged range. }
function PacketNumberLength(PacketNumber, LargestAcknowledged: QWord): Integer;
{ The full packet number from its truncated form (Length bytes) and
  the largest number received so far in the space (-1: none yet). }
function DecodePacketNumber(LargestReceived: Int64; Truncated: QWord; Length: Integer): QWord;

implementation

uses
  Quic.Buffers,
  Quic.Constants;

function LongHeaderTypeBits(PacketType: TQuicPacketType): Byte;
begin
  case PacketType of
    PacketInitial: Result := $00;
    PacketZeroRtt: Result := $10;
    PacketHandshake: Result := $20;
  else
    Result := $30;
  end;
end;

function ReadConnectionId(var Reader: TQuicReader; out Id: TQuicConnectionId): Boolean;
var
  IdLength: Byte;
  Bytes: PByte;
begin
  Id := Default(TQuicConnectionId);
  if not Reader.ReadByte(IdLength) then
    Exit(False);
  if IdLength > MaximumConnectionIdLength then
    Exit(False);
  if not Reader.ReadBytes(IdLength, Bytes) then
    Exit(False);
  Result := MakeConnectionId(Bytes, IdLength, Id);
end;

function ParseLongHeader(var Reader: TQuicReader; FirstByte: Byte; Available: PtrUInt;
  var Header: TQuicPacketHeader): Boolean;
var
  Version: LongWord;
  Length: QWord;
begin
  if not Reader.ReadUInt32(Version) then
    Exit(False);
  Header.Version := Version;
  if not ReadConnectionId(Reader, Header.DestinationId) or not ReadConnectionId(Reader, Header.SourceId) then
    Exit(False);
  if Version = 0 then
  begin
    Header.PacketType := PacketVersionNegotiation;
    Header.PacketNumberOffset := Reader.Consumed;
    Header.PacketLength := Available;
    Exit(True);
  end;
  if Version <> QuicVersion1 then
  begin
    { Not ours: the caller drops it, so the rest does not matter. }
    Header.PacketLength := Available;
    Exit(True);
  end;
  case (FirstByte shr 4) and $03 of
    0: Header.PacketType := PacketInitial;
    1: Header.PacketType := PacketZeroRtt;
    2: Header.PacketType := PacketHandshake;
  else
    Header.PacketType := PacketRetry;
  end;
  if Header.PacketType = PacketRetry then
  begin
    { The token is everything up to the 16-byte tag. }
    if Reader.Remaining < PacketTagLength then
      Exit(False);
    Header.Token := Reader.Position;
    Header.TokenLength := Reader.Remaining - PacketTagLength;
    Header.PacketNumberOffset := Reader.Consumed;
    Header.PacketLength := Available;
    Exit(True);
  end;
  if Header.PacketType = PacketInitial then
  begin
    if not Reader.ReadVariable(Length) or not Reader.ReadBytes(Length, Header.Token) then
      Exit(False);
    Header.TokenLength := Length;
  end;
  if not Reader.ReadVariable(Length) then
    Exit(False);
  if Length > Reader.Remaining then
    Exit(False);
  Header.PacketNumberOffset := Reader.Consumed;
  Header.PacketLength := Reader.Consumed + Length;
  Result := True;
end;

function ParsePacketHeader(Data: PByte; Available: PtrUInt; ShortIdLength: Integer;
  out Header: TQuicPacketHeader): Boolean;
var
  Reader: TQuicReader;
  FirstByte: Byte;
  Bytes: PByte;
begin
  Header := Default(TQuicPacketHeader);
  Reader.Initialize(Data, Available);
  if not Reader.ReadByte(FirstByte) then
    Exit(False);
  if (FirstByte and $80) <> 0 then
  begin
    Header.IsLongHeader := True;
    Exit(ParseLongHeader(Reader, FirstByte, Available, Header));
  end;
  { The fixed bit must be set (section 17.3.1). }
  if (FirstByte and $40) = 0 then
    Exit(False);
  Header.PacketType := PacketOneRtt;
  Header.Version := QuicVersion1;
  if not Reader.ReadBytes(ShortIdLength, Bytes) then
    Exit(False);
  MakeConnectionId(Bytes, ShortIdLength, Header.DestinationId);
  Header.PacketNumberOffset := Reader.Consumed;
  Header.PacketLength := Available;
  Result := True;
end;

function PacketNumberLength(PacketNumber, LargestAcknowledged: QWord): Integer;
var
  Unacknowledged: QWord;
begin
  if LargestAcknowledged = High(QWord) then
    Unacknowledged := PacketNumber + 1
  else
    Unacknowledged := PacketNumber - LargestAcknowledged;
  { Twice the range must fit in the bits sent. }
  if Unacknowledged < $80 then
    Result := 1
  else if Unacknowledged < $8000 then
    Result := 2
  else if Unacknowledged < $800000 then
    Result := 3
  else
    Result := 4;
end;

function DecodePacketNumber(LargestReceived: Int64; Truncated: QWord; Length: Integer): QWord;
var
  Expected, Window, HalfWindow, Mask, Candidate: QWord;
begin
  Expected := QWord(LargestReceived + 1);
  Window := QWord(1) shl (8 * Length);
  HalfWindow := Window div 2;
  Mask := Window - 1;
  Candidate := (Expected and not Mask) or Truncated;
  if (Candidate + HalfWindow <= Expected) and (Candidate < (QWord(1) shl 62) - Window) then
    Result := Candidate + Window
  else if (Candidate > Expected + HalfWindow) and (Candidate >= Window) then
    Result := Candidate - Window
  else
    Result := Candidate;
end;

end.
