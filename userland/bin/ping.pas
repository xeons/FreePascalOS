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
  ping - send ICMP echo requests to a host

  ping [-4|-6] [-q] [-n] [-c COUNT] [-i INTERVAL] [-W TIMEOUT] [-s SIZE] [-t TTL] HOST

  Sends an echo request every INTERVAL seconds (1) and prints each
  reply as it comes, like iputils' ping; COUNT requests (all of them
  until Ctrl-C without -c), then the summary: requests sent, replies,
  the loss, and the round trip times (minimum, average, maximum and
  mean deviation). TIMEOUT is how long to wait for the replies after
  the last request (10 seconds). SIZE bytes of data follow the 8-byte
  ICMP header (56); the first 8 are the time it was sent. Errors that
  come back about the requests (unreachable, time exceeded) are shown
  as they come.

  It uses an ICMP echo socket, which anyone may open (the kernel keeps
  it to echo requests and their replies). HOST is a name or an address,
  looked up by Sys.HostLookup (/etc/hosts, then DNS); the first line
  shows both, "PING name (address)", as iputils does. Replies are shown
  by address (-n is taken and changes nothing).

  IPv6 works the same with ICMPv6: an IPv6 address is pinged over IPv6,
  a name over the family the resolver puts first (IPv6 when this
  machine can reach the address), or the one -4 or -6 asks for. A
  link-local address takes its interface after a % (fe80::2%eth0).

  Exit status: 0 if a reply came, 1 if none did, 2 on errors.
}
program ping;

{$mode objfpc}
{$H+}
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Sys.Errors,
  Sys.Format,
  Sys.Kernel,
  Sys.Notifications,
  Sys.Objects,
  Sys.Sockets,
  Sys.InternetAddresses,
  Sys.HostNames,
  Sys.HostLookup,
  Sys.AddressText,
  Sys.Streams,
  Sys.Text,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: ping [OPTION]... HOST'#10 +
    'Send ICMP echo requests to HOST and show the replies.'#10 +
    #10 +
    '  -c COUNT      stop after sending COUNT requests'#10 +
    '  -i INTERVAL   seconds between requests (1; fractions allowed)'#10 +
    '  -W TIMEOUT    seconds to wait for replies after the last request (10)'#10 +
    '  -s SIZE       bytes of data in each request (56)'#10 +
    '  -t TTL        time to live of the requests (64)'#10 +
    '  -4            use IPv4 only'#10 +
    '  -6            use IPv6 only'#10 +
    '  -q            show only the summary'#10 +
    '  -n            numeric output (replies are always shown by address)'#10;

  OptionCount = 1;
  OptionInterval = 2;
  OptionTimeout = 3;
  OptionSize = 4;
  OptionTimeToLive = 5;
  OptionQuiet = 6;
  OptionNumeric = 7;
  OptionIpv4 = 8;
  OptionIpv6 = 9;

  IcmpHeaderBytes = 8;
  Ipv4HeaderBytes = 20;
  Ipv6HeaderBytes = 40;
  Icmpv4EchoRequest = 8;
  Icmpv4EchoReply = 0;
  Icmpv4DestinationUnreachable = 3;
  Icmpv4TimeExceeded = 11;
  Icmpv6DestinationUnreachable = 1;
  Icmpv6PacketTooBig = 2;
  Icmpv6TimeExceeded = 3;
  Icmpv6ParameterProblem = 4;
  Icmpv6EchoRequest = 128;
  Icmpv6EchoReply = 129;
  TimestampBytes = 8;
  MaximumDataBytes = 65507;
  BufferBytes = 2048;
  NanosecondsPerMicrosecond = 1000;
  NanosecondsPerMillisecond = 1000 * 1000;

type
  TStatistics = record
    Sent: LongWord;
    Received: LongWord;
    Duplicates: LongWord;
    Errors: LongWord;
    { Round trip times in microseconds. }
    TimedReplies: LongWord;
    MinimumMicroseconds: QWord;
    MaximumMicroseconds: QWord;
    SumMicroseconds: QWord;
    SumOfSquares: QWord;
  end;

var
  Count: QWord = 0;
  IntervalMilliseconds: QWord = 1000;
  TimeoutMilliseconds: QWord = 10000;
  DataBytes: QWord = 56;
  TimeToLive: QWord = 0;
  Quiet: Boolean = False;
  { HostFamily* of Sys.HostNames. }
  Families: LongWord = HostFamilyAny;
  HostText: PChar;
  Destination: TInternetAddress;
  { The interface of a link-local destination (fe80::2%eth0). }
  DestinationScope: LongWord = 0;
  DestinationText: string;
  Socket: Int64;
  Statistics: TStatistics;
  { Which sequence numbers were answered (to tell duplicates). }
  Answered: array[0..8191] of Byte;

function NowNanoseconds: QWord;
begin
  Result := QWord(KernelGetTime(TimeUptimeNanoseconds));
end;

procedure ParseSeconds(Text: PChar; out Milliseconds: QWord);
begin
  if not ParseThousandths(Text, Milliseconds) then
    FailWithUsageHint('invalid number of seconds: ''%s''', [ArgumentText(Text)]);
end;

procedure ParseNumber(Text: PChar; Lowest, Highest: QWord; What: PChar; out Value: QWord);
begin
  if not ParseUnsigned(Text, Value) or (Value < Lowest) or (Value > Highest) then
    Fail(2, 'invalid %s: ''%s''', [ArgumentText(What), ArgumentText(Text)]);
end;

procedure ParseArguments;
var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
begin
  BeginOptions(Parser, [
    OptionDefinition('c', 'count', True, OptionCount),
    OptionDefinition('i', 'interval', True, OptionInterval),
    OptionDefinition('W', 'timeout', True, OptionTimeout),
    OptionDefinition('s', 'size', True, OptionSize),
    OptionDefinition('t', 'ttl', True, OptionTimeToLive),
    OptionDefinition('4', nil, False, OptionIpv4),
    OptionDefinition('6', nil, False, OptionIpv6),
    OptionDefinition('q', 'quiet', False, OptionQuiet),
    OptionDefinition('n', 'numeric', False, OptionNumeric)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionCount: ParseNumber(Value, 1, High(LongWord), 'count of packets to transmit', Count);
      OptionInterval: ParseSeconds(Value, IntervalMilliseconds);
      OptionTimeout: ParseSeconds(Value, TimeoutMilliseconds);
      OptionSize: ParseNumber(Value, 0, MaximumDataBytes, 'packet size', DataBytes);
      OptionTimeToLive: ParseNumber(Value, 1, 255, 'TTL', TimeToLive);
      OptionQuiet: Quiet := True;
      OptionIpv4: Families := HostFamilyIpv4;
      OptionIpv6: Families := HostFamilyIpv6;
    end;
  if Parser.OperandCount = 0 then
    FailWithUsageHint('missing host operand', []);
  if Parser.OperandCount > 1 then
    FailWithUsageHint('extra operand ''%s''', [ArgumentText(Parser.Operands[1])]);
  HostText := Parser.Operands[0];
end;

{ The one place a host becomes an address (names: Sys.HostLookup). }
procedure ResolveDestination;
var
  Error: LongInt;
  Addresses: TInternetAddressArray;
begin
  if TextToScopedAddress(HostText, Destination, DestinationScope) then
  begin
    if ((Destination.Family = AddressFamilyIPv4) and ((Families and HostFamilyIpv4) = 0)) or
       ((Destination.Family = AddressFamilyIPv6) and ((Families and HostFamilyIpv6) = 0)) then
      Fail(2, '%s: %s', [ArgumentText(HostText), ArgumentText('Address family for hostname not supported')]);
  end
  else
  begin
    Error := ResolveHost(HostText, Families, Addresses);
    if (Error = ErrorNone) and (Length(Addresses) = 0) then
      Error := ErrorNotFound;
    if Error <> ErrorNone then
      Fail(2, '%s: %s', [ArgumentText(HostText), ArgumentText(HostLookupErrorMessage(Error))]);
    Destination := Addresses[0];
  end;
  DestinationText := AddressToText(Destination);
end;

function DestinationAddress: TAbiSocketAddress;
begin
  Result := MakeSocketAddress(Destination, 0);
  Result.ScopeId := DestinationScope;
end;

function IsIpv6: Boolean;
begin
  Result := Destination.Family = AddressFamilyIPv6;
end;

procedure OpenSocket;
var
  Error: LongInt;
begin
  if IsIpv6 then
    Socket := CreateSocket(AddressFamilyIPv6, SocketKindDatagram, ProtocolIcmpv6)
  else
    Socket := CreateSocket(AddressFamilyIPv4, SocketKindDatagram, ProtocolIcmp);
  if Socket < 0 then
    FailWithError(2, ErrorCodeOf(Socket), 'socket', []);
  if TimeToLive <> 0 then
  begin
    Error := SetSocketOption(Socket, SocketOptionTimeToLive, TimeToLive);
    if Error <> ErrorNone then
      FailWithError(2, Error, 'cannot set the time to live', []);
  end;
  { Broadcasts are answered by no one here, but asking is allowed. }
  if not IsIpv6 then
    SetSocketOption(Socket, SocketOptionBroadcast, 1);
end;

procedure SendRequest(Sequence: LongWord);
var
  Packet: PByte;
  Length: QWord;
  Index: QWord;
  Sent: Int64;
  Stamp: QWord;
begin
  Length := IcmpHeaderBytes + DataBytes;
  Packet := PByte(GetMem(Length));
  FillMemory(Packet, IcmpHeaderBytes, 0);
  if IsIpv6 then
    Packet[0] := Icmpv6EchoRequest
  else
    Packet[0] := Icmpv4EchoRequest;
  Packet[6] := Byte(Sequence shr 8);
  Packet[7] := Byte(Sequence);
  Index := 0;
  while Index < DataBytes do
  begin
    Packet[IcmpHeaderBytes + Index] := Byte(Index + $10);
    Inc(Index);
  end;
  if DataBytes >= TimestampBytes then
  begin
    Stamp := NowNanoseconds;
    CopyMemory(Packet + IcmpHeaderBytes, @Stamp, TimestampBytes);
  end;
  Sent := SendSocketTo(Socket, Packet, Length, 0, DestinationAddress);
  FreeMem(Packet);
  Inc(Statistics.Sent);
  if Sent < 0 then
  begin
    ReportError(ErrorCodeOf(Sent), 'sendmsg', []);
    Inc(Statistics.Errors);
  end;
end;

function SequenceOf(Message: PByte): LongWord;
begin
  Result := (LongWord(Message[6]) shl 8) or LongWord(Message[7]);
end;

function MarkAnswered(Sequence: LongWord): Boolean;
var
  Bit: Byte;
begin
  Bit := 1 shl (Sequence mod 8);
  Result := (Answered[Sequence div 8] and Bit) <> 0;
  Answered[Sequence div 8] := Answered[Sequence div 8] or Bit;
end;

procedure WriteMilliseconds(Microseconds: QWord);
begin
  WriteFormatted(StandardOutput, '%u.%03u', [ArgumentUnsigned(Microseconds div 1000),
    ArgumentUnsigned(Microseconds mod 1000)]);
end;

procedure NoteRoundTrip(Microseconds: QWord);
begin
  if (Statistics.TimedReplies = 0) or (Microseconds < Statistics.MinimumMicroseconds) then
    Statistics.MinimumMicroseconds := Microseconds;
  if Microseconds > Statistics.MaximumMicroseconds then
    Statistics.MaximumMicroseconds := Microseconds;
  Inc(Statistics.TimedReplies);
  Statistics.SumMicroseconds := Statistics.SumMicroseconds + Microseconds;
  Statistics.SumOfSquares := Statistics.SumOfSquares + Microseconds * Microseconds;
end;

procedure HandleReply(Message: PByte; Length: QWord; From: PChar);
var
  Sequence: LongWord;
  IsDuplicate: Boolean;
  Stamp: QWord;
  Microseconds: QWord;
  HasTime: Boolean;
  ReceivedTimeToLive: Int64;
begin
  Sequence := SequenceOf(Message);
  IsDuplicate := MarkAnswered(Sequence);
  if IsDuplicate then
    Inc(Statistics.Duplicates)
  else
    Inc(Statistics.Received);
  HasTime := Length >= IcmpHeaderBytes + TimestampBytes;
  Microseconds := 0;
  if HasTime then
  begin
    CopyMemory(@Stamp, Message + IcmpHeaderBytes, TimestampBytes);
    Microseconds := (NowNanoseconds - Stamp) div NanosecondsPerMicrosecond;
    if not IsDuplicate then
      NoteRoundTrip(Microseconds);
  end;
  if Quiet then
    Exit;
  GetSocketOption(Socket, SocketOptionReceivedTimeToLive, ReceivedTimeToLive);
  WriteFormatted(StandardOutput, '%u bytes from %s: icmp_seq=%u ttl=%d', [ArgumentUnsigned(Length),
    ArgumentText(From), ArgumentUnsigned(Sequence), ArgumentNumber(ReceivedTimeToLive)]);
  if HasTime then
  begin
    WriteText(StandardOutput, ' time=');
    WriteMilliseconds(Microseconds);
    WriteText(StandardOutput, ' ms');
  end;
  if IsDuplicate then
    WriteText(StandardOutput, ' (DUP!)');
  WriteCharacter(StandardOutput, #10);
  FlushStream(StandardOutput);
end;

function Ipv6ErrorDescription(IcmpType, Code: Byte): PChar;
begin
  case IcmpType of
    Icmpv6PacketTooBig: Exit('Packet too big');
    Icmpv6TimeExceeded: Exit('Time exceeded: Hop limit');
    Icmpv6ParameterProblem: Exit('Parameter problem');
  end;
  case Code of
    0: Result := 'Destination unreachable: No route';
    1: Result := 'Destination unreachable: Administratively prohibited';
    3: Result := 'Destination unreachable: Address unreachable';
    4: Result := 'Destination unreachable: Port unreachable';
  else
    Result := 'Destination unreachable';
  end;
end;

function ErrorDescription(IcmpType, Code: Byte): PChar;
begin
  if IsIpv6 then
    Exit(Ipv6ErrorDescription(IcmpType, Code));
  if IcmpType = Icmpv4TimeExceeded then
    Exit('Time to live exceeded');
  case Code of
    0: Result := 'Destination Net Unreachable';
    1: Result := 'Destination Host Unreachable';
    2: Result := 'Destination Protocol Unreachable';
    3: Result := 'Destination Port Unreachable';
  else
    Result := 'Destination Unreachable';
  end;
end;

procedure HandleError(Message: PByte; Length: QWord; From: PChar);
var
  QuotedHeaderLength: QWord;
  Sequence: LongWord;
begin
  if Length < IcmpHeaderBytes + Ipv4HeaderBytes + IcmpHeaderBytes then
    Exit;
  if IsIpv6 then
    QuotedHeaderLength := Ipv6HeaderBytes
  else
    QuotedHeaderLength := QWord(Message[IcmpHeaderBytes] and $0F) * 4;
  if Length < IcmpHeaderBytes + QuotedHeaderLength + IcmpHeaderBytes then
    Exit;
  Sequence := SequenceOf(Message + IcmpHeaderBytes + QuotedHeaderLength);
  Inc(Statistics.Errors);
  if Quiet then
    Exit;
  WriteFormatted(StandardOutput, 'From %s icmp_seq=%u %s'#10, [ArgumentText(From), ArgumentUnsigned(Sequence),
    ArgumentText(ErrorDescription(Message[0], Message[1]))]);
  FlushStream(StandardOutput);
end;

{ Takes every message waiting on the socket. }
procedure ReceiveMessages;
var
  Buffer: array[0..BufferBytes - 1] of Byte;
  Source: TAbiSocketAddress;
  From: string;
  Length: Int64;
begin
  repeat
    Length := ReceiveSocketFrom(Socket, @Buffer[0], SizeOf(Buffer), SocketFlagDontWait, Source);
    if Length < IcmpHeaderBytes then
      Exit;
    From := SocketHostToText(Source);
    if IsIpv6 then
      case Buffer[0] of
        Icmpv6EchoReply: HandleReply(@Buffer[0], QWord(Length), PChar(From));
        Icmpv6DestinationUnreachable, Icmpv6PacketTooBig, Icmpv6TimeExceeded, Icmpv6ParameterProblem:
          HandleError(@Buffer[0], QWord(Length), PChar(From));
      end
    else
      case Buffer[0] of
        Icmpv4EchoReply: HandleReply(@Buffer[0], QWord(Length), PChar(From));
        Icmpv4DestinationUnreachable, Icmpv4TimeExceeded: HandleError(@Buffer[0], QWord(Length), PChar(From));
      end;
  until False;
end;

{ Ctrl-C (or another request to end) stops the pings; True if it came. }
function TakeEndRequest: Boolean;
var
  Notification: TAbiNotification;
begin
  Result := False;
  while ReceiveNotification(Notification) do
    if Notification.Kind = NotificationEndRequested then
      Result := True;
end;

function AllAnswered: Boolean;
begin
  Result := Statistics.Received + Statistics.Errors >= Statistics.Sent;
end;

{ Integer square root, for the mean deviation. }
function SquareRoot(Value: QWord): QWord;
var
  Bit: QWord;
begin
  Result := 0;
  Bit := QWord(1) shl 62;
  while Bit > Value do
    Bit := Bit shr 2;
  while Bit <> 0 do
  begin
    if Value >= Result + Bit then
    begin
      Value := Value - (Result + Bit);
      Result := (Result shr 1) + Bit;
    end
    else
      Result := Result shr 1;
    Bit := Bit shr 2;
  end;
end;

procedure WriteSummary(ElapsedMilliseconds: QWord);
var
  LossPercent: QWord;
  Average: QWord;
  MeanSquare: QWord;
  Deviation: QWord;
begin
  WriteFormatted(StandardOutput, #10'--- %s ping statistics ---'#10, [ArgumentText(HostText)]);
  LossPercent := 0;
  if Statistics.Sent > 0 then
    LossPercent := QWord(Statistics.Sent - Statistics.Received) * 100 div Statistics.Sent;
  WriteFormatted(StandardOutput, '%u packets transmitted, %u received', [ArgumentUnsigned(Statistics.Sent),
    ArgumentUnsigned(Statistics.Received)]);
  if Statistics.Duplicates > 0 then
    WriteFormatted(StandardOutput, ', +%u duplicates', [ArgumentUnsigned(Statistics.Duplicates)]);
  if Statistics.Errors > 0 then
    WriteFormatted(StandardOutput, ', +%u errors', [ArgumentUnsigned(Statistics.Errors)]);
  WriteFormatted(StandardOutput, ', %u%% packet loss, time %ums'#10, [ArgumentUnsigned(LossPercent),
    ArgumentUnsigned(ElapsedMilliseconds)]);
  if Statistics.TimedReplies = 0 then
    Exit;
  Average := Statistics.SumMicroseconds div Statistics.TimedReplies;
  MeanSquare := Statistics.SumOfSquares div Statistics.TimedReplies;
  Deviation := 0;
  if MeanSquare > Average * Average then
    Deviation := SquareRoot(MeanSquare - Average * Average);
  WriteText(StandardOutput, 'rtt min/avg/max/mdev = ');
  WriteMilliseconds(Statistics.MinimumMicroseconds);
  WriteCharacter(StandardOutput, '/');
  WriteMilliseconds(Average);
  WriteCharacter(StandardOutput, '/');
  WriteMilliseconds(Statistics.MaximumMicroseconds);
  WriteCharacter(StandardOutput, '/');
  WriteMilliseconds(Deviation);
  WriteLine(StandardOutput, ' ms');
end;

procedure RunPings;
var
  Start: QWord;
  NextSend: QWord;
  LastSend: QWord;
  Now: QWord;
  Deadline: QWord;
  WaitMilliseconds: Int64;
  Ready: Int64;
  Sequence: LongWord;
begin
  Start := NowNanoseconds;
  NextSend := Start;
  LastSend := Start;
  Sequence := 1;
  repeat
    Now := NowNanoseconds;
    if ((Count = 0) or (Statistics.Sent < Count)) and (Now >= NextSend) then
    begin
      SendRequest(Sequence);
      Inc(Sequence);
      LastSend := Now;
      NextSend := NextSend + IntervalMilliseconds * NanosecondsPerMillisecond;
      Continue;
    end;
    if (Count <> 0) and (Statistics.Sent >= Count) then
    begin
      if AllAnswered then
        Break;
      Deadline := LastSend + TimeoutMilliseconds * NanosecondsPerMillisecond;
      if Now >= Deadline then
        Break;
    end
    else
      Deadline := NextSend;
    WaitMilliseconds := Int64((Deadline - Now + NanosecondsPerMillisecond - 1) div NanosecondsPerMillisecond);
    Ready := WaitForHandles([Socket, NotificationsHandle], WaitMilliseconds);
    if Ready = 0 then
      ReceiveMessages
    else if (Ready = 1) and TakeEndRequest then
      Break;
  until False;
  WriteSummary((NowNanoseconds - Start) div NanosecondsPerMillisecond);
end;

function IpHeaderBytes: QWord;
begin
  if IsIpv6 then
    Result := Ipv6HeaderBytes
  else
    Result := Ipv4HeaderBytes;
end;

begin
  ParseArguments;
  ResolveDestination;
  OpenSocket;
  TakeNotifications(NotifyEndRequests or NotifyEndInterrupt);
  WriteFormatted(StandardOutput, 'PING %s (%s) %u(%u) bytes of data.'#10, [ArgumentText(HostText),
    ArgumentText(PChar(DestinationText)), ArgumentUnsigned(DataBytes),
    ArgumentUnsigned(DataBytes + IcmpHeaderBytes + IpHeaderBytes)]);
  FlushStream(StandardOutput);
  RunPings;
  CloseSocket(Socket);
  FlushStream(StandardOutput);
  if Statistics.Received > 0 then
    Halt(0);
  if Statistics.Sent > 0 then
    Halt(1);
  Halt(2);
end.
