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
  SNTP messages (RFC 4330, NTP version 4's 48-byte header).

  A request is mode 3 (client), version 4, with the client's send time
  T1 as its transmit timestamp. The server's reply (mode 4) copies T1 as
  its originate timestamp and adds when it received the request (T2)
  and sent the reply (T3); the client notes when the reply came (T4).
  Then
    offset = ((T2 - T1) + (T3 - T4)) / 2   (how far the server is ahead)
    delay  = (T4 - T1) - (T3 - T2)          (the round trip on the wire)
  A reply is refused if it is short, not from a server, not an answer
  to this request (its originate timestamp is not T1), a "kiss of
  death" (stratum 0: the server asks to be left alone), from a server
  that is not synchronized itself (leap indicator 3, or stratum 16 and
  up) or has no transmit time.

  NTP timestamps are seconds since 1900 (32 bits; era 1 begins in 2036)
  and a binary fraction; here times are nanoseconds since 1970.

  Plain Pascal: built into the timesync service and the host test
  (tools/SntpTest).
}
unit TimeSync.Packets;

{$mode objfpc}{$H+}

interface

const
  NtpPacketLength = 48;
  NtpPort = 123;

type
  TNtpPacket = array[0..NtpPacketLength - 1] of Byte;

  TSntpSample = record
    OffsetNanoseconds: Int64;
    DelayNanoseconds: Int64;
    Stratum: Byte;
    { The server's reference id: four letters for stratum 1 ("GPS"),
      an address for others; for a kiss of death its code ("RATE"). }
    ReferenceId: LongWord;
  end;

  TReplyVerdict = (ReplyAccepted, ReplyTooShort, ReplyNotFromServer, ReplyNotOurs, ReplyKissOfDeath,
    ReplyUnsynchronized, ReplyWithoutTime);

{ The NTP timestamp of a time in nanoseconds since 1970, and back (for
  timestamps of either era near now). }
function NanosecondsToNtpTimestamp(UnixNanoseconds: Int64): QWord;
function NtpTimestampToNanoseconds(Timestamp: QWord): Int64;

{ A client request sent at SendNanoseconds; Sent is the transmit
  timestamp written, which the reply must carry back. }
procedure BuildRequest(out Packet: TNtpPacket; SendNanoseconds: Int64; out Sent: QWord);
{ Checks a reply (Length bytes) to the request with transmit timestamp
  Sent, sent at T1 and received at T4 (nanoseconds since 1970), and
  works out the offset and delay. }
function ParseReply(constref Packet: TNtpPacket; Length: Integer; Sent: QWord; T1, T4: Int64;
  out Sample: TSntpSample): TReplyVerdict;
function VerdictText(Verdict: TReplyVerdict): string;

{ For the test's server: a reply to Request with the server's times. }
procedure BuildReply(constref Request: TNtpPacket; ReceiveNanoseconds, TransmitNanoseconds: Int64;
  Stratum: Byte; out Reply: TNtpPacket);

implementation

const
  { Seconds from 1900-01-01 to 1970-01-01. }
  NtpToUnixSeconds = Int64(2208988800);
  NanosecondsPerSecond = Int64(1000000000);
  EraSeconds = Int64(1) shl 32;
  VersionFour = 4;
  ModeClient = 3;
  ModeServer = 4;
  LeapUnsynchronized = 3;
  StratumKissOfDeath = 0;
  StratumUnsynchronized = 16;
  OffsetOriginate = 24;
  OffsetReceive = 32;
  OffsetTransmit = 40;
  OffsetReference = 12;

function ReadBigEndian64(constref Packet: TNtpPacket; Offset: Integer): QWord;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to 7 do
    Result := (Result shl 8) or Packet[Offset + Index];
end;

procedure WriteBigEndian64(var Packet: TNtpPacket; Offset: Integer; Value: QWord);
var
  Index: Integer;
begin
  for Index := 7 downto 0 do
  begin
    Packet[Offset + Index] := Byte(Value and $FF);
    Value := Value shr 8;
  end;
end;

function NanosecondsToNtpTimestamp(UnixNanoseconds: Int64): QWord;
var
  Seconds: Int64;
  Remainder: Int64;
  Fraction: QWord;
begin
  Seconds := UnixNanoseconds div NanosecondsPerSecond;
  Remainder := UnixNanoseconds mod NanosecondsPerSecond;
  if Remainder < 0 then
  begin
    Dec(Seconds);
    Inc(Remainder, NanosecondsPerSecond);
  end;
  { The seconds field wraps at 2^32 (era 1 from 2036 on). }
  Seconds := (Seconds + NtpToUnixSeconds) and $FFFFFFFF;
  Fraction := (QWord(Remainder) shl 32) div QWord(NanosecondsPerSecond);
  Result := (QWord(Seconds) shl 32) or Fraction;
end;

function NtpTimestampToNanoseconds(Timestamp: QWord): Int64;
var
  Seconds: Int64;
  Fraction: QWord;
begin
  Seconds := Int64(Timestamp shr 32);
  { Seconds below 2^31 belong to era 1 (after 2036-02-07). }
  if Seconds < (Int64(1) shl 31) then
    Seconds := Seconds + EraSeconds;
  Fraction := Timestamp and $FFFFFFFF;
  Result := (Seconds - NtpToUnixSeconds) * NanosecondsPerSecond +
    Int64((Fraction * QWord(NanosecondsPerSecond)) shr 32);
end;

procedure BuildRequest(out Packet: TNtpPacket; SendNanoseconds: Int64; out Sent: QWord);
begin
  FillChar(Packet, SizeOf(Packet), 0);
  Packet[0] := (VersionFour shl 3) or ModeClient;
  Sent := NanosecondsToNtpTimestamp(SendNanoseconds);
  WriteBigEndian64(Packet, OffsetTransmit, Sent);
end;

function ParseReply(constref Packet: TNtpPacket; Length: Integer; Sent: QWord; T1, T4: Int64;
  out Sample: TSntpSample): TReplyVerdict;
var
  Leap: Byte;
  Mode: Byte;
  T2: Int64;
  T3: Int64;
begin
  FillChar(Sample, SizeOf(Sample), 0);
  if Length < NtpPacketLength then
    Exit(ReplyTooShort);
  Leap := Packet[0] shr 6;
  Mode := Packet[0] and 7;
  if Mode <> ModeServer then
    Exit(ReplyNotFromServer);
  if ReadBigEndian64(Packet, OffsetOriginate) <> Sent then
    Exit(ReplyNotOurs);
  Sample.Stratum := Packet[1];
  Sample.ReferenceId := (LongWord(Packet[OffsetReference]) shl 24) or (LongWord(Packet[OffsetReference + 1]) shl 16) or
    (LongWord(Packet[OffsetReference + 2]) shl 8) or Packet[OffsetReference + 3];
  if Sample.Stratum = StratumKissOfDeath then
    Exit(ReplyKissOfDeath);
  if (Leap = LeapUnsynchronized) or (Sample.Stratum >= StratumUnsynchronized) then
    Exit(ReplyUnsynchronized);
  if ReadBigEndian64(Packet, OffsetTransmit) = 0 then
    Exit(ReplyWithoutTime);
  T2 := NtpTimestampToNanoseconds(ReadBigEndian64(Packet, OffsetReceive));
  T3 := NtpTimestampToNanoseconds(ReadBigEndian64(Packet, OffsetTransmit));
  { Halves first, so the sums cannot overflow. }
  Sample.OffsetNanoseconds := (T2 - T1) div 2 + (T3 - T4) div 2;
  Sample.DelayNanoseconds := (T4 - T1) - (T3 - T2);
  if Sample.DelayNanoseconds < 0 then
    Sample.DelayNanoseconds := 0;
  Result := ReplyAccepted;
end;

function VerdictText(Verdict: TReplyVerdict): string;
begin
  case Verdict of
    ReplyAccepted: Result := 'accepted';
    ReplyTooShort: Result := 'too short';
    ReplyNotFromServer: Result := 'not from a server';
    ReplyNotOurs: Result := 'not an answer to our request';
    ReplyKissOfDeath: Result := 'kiss of death (the server asks to be left alone)';
    ReplyUnsynchronized: Result := 'the server is not synchronized';
    ReplyWithoutTime: Result := 'no time in the reply';
  else
    Result := 'unknown';
  end;
end;

procedure BuildReply(constref Request: TNtpPacket; ReceiveNanoseconds, TransmitNanoseconds: Int64;
  Stratum: Byte; out Reply: TNtpPacket);
begin
  FillChar(Reply, SizeOf(Reply), 0);
  Reply[0] := (VersionFour shl 3) or ModeServer;
  Reply[1] := Stratum;
  Move(Request[OffsetTransmit], Reply[OffsetOriginate], 8);
  WriteBigEndian64(Reply, OffsetReceive, NanosecondsToNtpTimestamp(ReceiveNanoseconds));
  WriteBigEndian64(Reply, OffsetTransmit, NanosecondsToNtpTimestamp(TransmitNanoseconds));
end;

end.
