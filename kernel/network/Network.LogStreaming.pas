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
  The network log: every line of the kernel log as a UDP datagram to a
  machine that listens (scripts/netlog.py), for boards without a serial
  cable.

    netlog=HOST[:PORT]       to that IPv4 address (port 5140 by default)
    netlog=broadcast[:PORT]  to 255.255.255.255 on the local network

  Each datagram is one line: its sequence number, the uptime when it was
  written in seconds (to the microsecond) and the text,

    "42 3.141592 [network] eth0: configured 192.168.1.50/24"

  with "+" after the number for the rest of a line too long for one
  (Debug.LogRing cuts lines at 112 characters). The numbers start at 1
  each boot, so the listener sees a reboot when they start again, and a
  gap where lines were lost.

  The log is kept in memory from its first line (Debug.LogRing). A system
  thread waits until an interface has an address (from DHCP - the network
  service, or the kernel's own fallback, Network.FallbackAddress - or a
  static one) and a route to the host, sends everything kept, and from
  then on what is new, every 100 ms. Writers never wait for it: lines are
  only put in memory (from any level, inside any lock), and sent from the
  thread.

  After a panic the thread cannot run: FlushNetworkLogAtPanic (the
  panic's flush routine) sends the lines still unsent - at most the last
  200 - straight through the driver (Network.PanicTransmit), on the route
  the thread last used.
}
unit Network.LogStreaming;

{$mode objfpc}
{$pointermath on}

interface

{ Starts the network log if the netlog option asks for it. }
procedure StartNetworkLog;

{ Whether the netlog option is set. }
function NetworkLogIsWanted: Boolean;

implementation

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Runtime.Text,
  Kernel.Options,
  Kernel.Panic,
  Kernel.Scheduler,
  Kernel.Threads,
  Hal.Platform,
  Processes.Thread,
  Objects.Manager,
  Io.NetworkAdapters,
  Network.Addresses,
  Network.Core,
  Network.Interfaces,
  Network.Routing,
  Network.Arp,
  Network.Sockets,
  Network.SocketOperations,
  Network.OptionText,
  Network.PanicTransmit,
  Debug.LogRing,
  Debug.Output;

const
  OptionNetworkLog = 'netlog';
  DefaultPort = 5140;
  PollMilliseconds = 100;
  NoRouteRetryMilliseconds = 500;
  { Lines sent before the thread lets others run for a moment, so a long
    replay does not overrun the driver's ring and the interface queue. }
  BurstLength = 16;
  { How long to wait for the next hop's Ethernet address before sending
    the replay anyway. }
  NeighbourWaitNanoseconds = QWord(3) * 1000 * 1000 * 1000;
  PanicBacklogLimit = 200;
  { "4294967295+ 18446744073.709551 " and the text. }
  DatagramCapacity = 40 + LogLineCapacity;
  NanosecondsPerSecond = QWord(1000) * 1000 * 1000;
  NanosecondsPerMicrosecond = 1000;
  NetworkLogThreadPriority = DefaultThreadPriority + 2;
  AllOnesHardware: TEthernetAddress = ($FF, $FF, $FF, $FF, $FF, $FF);

var
  Destination: TIpv4Address;
  DestinationPort: Word;
  ToBroadcast: Boolean;
  LogSocket: PSocket;
  LocalPort: Word;
  { The next line to send. }
  NextToSend: LongWord = 1;
  IsStreaming: Boolean;
  NeighbourWaitStart: QWord;
  NeighbourIsKnown: Boolean;
  NeighbourWasKnown: Boolean;
  PanicRoute: TPanicRoute;

function NetworkLogIsWanted: Boolean;
var
  Value: array[0..63] of Char;
begin
  Result := GetKernelOptionValue(OptionNetworkLog, @Value[0], SizeOf(Value)) and (Value[0] <> #0);
end;

procedure SayProblem(What: PChar; Value: PChar);
begin
  DebugBeginMessage;
  DebugWriteTag('netlog');
  DebugWrite(What);
  if Value <> nil then
    DebugWrite(Value);
  DebugWriteLine('');
  DebugEndMessage;
end;

function ReadDestinationOption: Boolean;
var
  Value: array[0..63] of Char;
  Position: PChar;
  Port: LongWord;
begin
  Result := False;
  if not GetKernelOptionValue(OptionNetworkLog, @Value[0], SizeOf(Value)) or (Value[0] = #0) then
    Exit;
  Position := @Value[0];
  DestinationPort := DefaultPort;
  if (TextLength(Position) >= 9) and MemoryIsEqual(Position, PChar('broadcast'), 9) then
  begin
    ToBroadcast := True;
    Destination := LimitedBroadcastAddress;
    Inc(Position, 9);
  end
  else if not ReadIpv4Text(Position, Destination) then
  begin
    SayProblem('not an IPv4 address or "broadcast": ', @Value[0]);
    Exit;
  end;
  if Position^ = ':' then
  begin
    Inc(Position);
    if not ReadNumberText(Position, $FFFF, Port) or (Port = 0) then
    begin
      SayProblem('not a port number: ', @Value[0]);
      Exit;
    end;
    DestinationPort := Port;
  end;
  if Position^ <> #0 then
  begin
    SayProblem('cannot read the option: ', @Value[0]);
    Exit;
  end;
  Result := True;
end;

function KernelOwner: TSocketOwner;
begin
  Result.UserId := 0;
  Result.ProcessId := 0;
end;

function OpenLogSocket: Boolean;
var
  Local: TNetworkEndpoint;
begin
  Result := False;
  if CreateSocket(AddressFamilyIPv4, SocketKindDatagram, ProtocolDefault, KernelOwner, True,
       LogSocket) <> ErrorNone then
  begin
    LogSocket := nil;
    Exit;
  end;
  if ToBroadcast then
    SetSocketOption(LogSocket, SocketOptionBroadcast, 1, True);
  { A port of its own now, so the panic path knows it. }
  if (BindSocket(LogSocket, MakeEndpoint(AnyAddress, 0), True) <> ErrorNone) or
     (GetSocketEndpoint(LogSocket, SocketAddressLocal, Local) <> ErrorNone) then
    Exit;
  LocalPort := Local.Port;
  Result := True;
end;

{ The first usable interface with an address (for broadcasts). }
function FirstAddressedInterface: PNetworkInterface;
var
  Position: Integer;
  Candidate: PNetworkInterface;
begin
  for Position := 0 to NetworkInterfaceCount - 1 do
  begin
    Candidate := NetworkInterfaceAt(Position);
    if not Candidate^.IsLoopback and Candidate^.HasAddress and InterfaceIsUsable(Candidate) then
      Exit(Candidate);
  end;
  Result := nil;
end;

{ Under the network lock: whether the host can be reached now, and the
  route the panic path would take. }
function RefreshRouteLocked: Boolean;
var
  NetworkInterface: PNetworkInterface;
  NextHop: TIpv4Address;
  Route: TPanicRoute;
begin
  Result := False;
  FillMemory(@Route, SizeOf(Route), 0);
  if ToBroadcast then
  begin
    NetworkInterface := FirstAddressedInterface;
    if NetworkInterface = nil then
      Exit;
    Route.DestinationHardware := AllOnesHardware;
    NeighbourIsKnown := True;
  end
  else
  begin
    if not LookupRoute(Destination, NetworkInterface, NextHop) or NetworkInterface^.IsLoopback or
       not NetworkInterface^.HasAddress or not InterfaceIsUsable(NetworkInterface) then
      Exit;
    NeighbourIsKnown := FindNeighbourAddress(NetworkInterface, NextHop, Route.DestinationHardware);
    { Forgotten (expired, or the address changed): asked again, so wait
      for the answer before sending a burst. }
    if NeighbourWasKnown and not NeighbourIsKnown then
      NeighbourWaitStart := HalClockNanoseconds;
    NeighbourWasKnown := NeighbourIsKnown;
    if not NeighbourIsKnown then
      { Better than nothing: hosts take an IP datagram for them in a
        broadcast frame. }
      Route.DestinationHardware := AllOnesHardware;
  end;
  Route.Adapter := NetworkInterface^.Adapter;
  Route.SourceHardware := NetworkInterface^.HardwareAddress;
  Route.SourceAddress := NetworkInterface^.Address;
  Route.DestinationAddress := Destination;
  Route.SourcePort := LocalPort;
  Route.DestinationPort := DestinationPort;
  Route.Valid := True;
  { Whole, with the flag last, for a panic that comes in between. }
  PanicRoute.Valid := False;
  PanicRoute := Route;
  Result := True;
end;

function RefreshRoute: Boolean;
begin
  LockNetwork;
  Result := RefreshRouteLocked;
  UnlockNetwork;
end;

{ Writes the datagram of Line into Text; returns its length. }
function FormatDatagram(constref Line: TLogLine; Text: PChar): LongWord;
var
  Number: TNumberText;
  Length: LongWord;

  procedure Append(Part: PChar);
  begin
    while Part^ <> #0 do
    begin
      Text[Length] := Part^;
      Inc(Length);
      Inc(Part);
    end;
  end;

begin
  Length := 0;
  Append(FormatDecimal(Line.Sequence, Number));
  if Line.Continued then
    Append('+');
  Append(' ');
  Append(FormatDecimal(Line.UptimeNanoseconds div NanosecondsPerSecond, Number));
  Append('.');
  Append(FormatUnsigned((Line.UptimeNanoseconds mod NanosecondsPerSecond) div NanosecondsPerMicrosecond,
    10, 6, Number));
  Append(' ');
  CopyMemory(@Text[Length], @Line.Text[0], Line.Length);
  Inc(Length, Line.Length);
  Result := Length;
end;

{ Sends one line; False if it could not go now (to be tried again). }
function SendLine(constref Line: TLogLine): Boolean;
var
  Datagram: array[0..DatagramCapacity - 1] of Char;
  Length: LongWord;
  Target: TNetworkEndpoint;
  Sent: Int64;
begin
  Length := FormatDatagram(Line, @Datagram[0]);
  Target := MakeEndpoint(Destination, DestinationPort);
  Sent := SendOnSocket(LogSocket, PByte(@Datagram[0]), Length, 0, @Target);
  { A datagram that can never go is skipped, not retried for ever. }
  Result := (Sent >= 0) or (Sent = -ErrorMessageTooLong) or (Sent = -ErrorInvalidArgument);
end;

procedure AnnounceStart;
var
  Text: array[0..15] of Char;
  Number: TNumberText;
begin
  FormatIpv4Text(Destination, @Text[0]);
  DebugBeginMessage;
  DebugWriteTag('netlog');
  DebugWrite('sending the kernel log to ');
  DebugWrite(@Text[0]);
  DebugWrite(':');
  DebugWrite(FormatDecimal(DestinationPort, Number));
  DebugWrite(' from line ');
  DebugWriteDecimal(NextToSend);
  DebugWriteLine('');
  DebugEndMessage;
end;

{ Sends what waits; while the next hop's address is still being asked
  for, only one line at a time (the ARP entry holds a few). }
procedure SendWaitingLines;
var
  Line: TLogLine;
  SentInBurst: LongWord;
  OneOnly: Boolean;
begin
  OneOnly := not NeighbourIsKnown and (HalClockNanoseconds - NeighbourWaitStart < NeighbourWaitNanoseconds);
  SentInBurst := 0;
  while ReadLogLine(NextToSend, Line) do
  begin
    if not SendLine(Line) then
      Exit;
    NextToSend := Line.Sequence + 1;
    if OneOnly then
      Exit;
    Inc(SentInBurst);
    if SentInBurst >= BurstLength then
    begin
      SleepMilliseconds(1);
      SentInBurst := 0;
    end;
  end;
end;

procedure RunNetworkLog(Context: Pointer);
begin
  while not OpenLogSocket do
  begin
    if LogSocket <> nil then
    begin
      DereferenceObject(LogSocket);
      LogSocket := nil;
    end;
    SleepMilliseconds(NoRouteRetryMilliseconds);
  end;
  repeat
    if not RefreshRoute then
    begin
      SleepMilliseconds(NoRouteRetryMilliseconds);
      Continue;
    end;
    if not IsStreaming then
    begin
      IsStreaming := True;
      NeighbourWaitStart := HalClockNanoseconds;
      AnnounceStart;
    end;
    SendWaitingLines;
    SleepMilliseconds(PollMilliseconds);
  until False;
end;

procedure FlushNetworkLogAtPanic;
var
  Line: TLogLine;
  Sequence: LongWord;
  Newest: LongWord;
  Datagram: array[0..DatagramCapacity - 1] of Char;
  Length: LongWord;
begin
  if not PanicRoute.Valid then
    Exit;
  Sequence := NextToSend;
  Newest := NextLogSequence;
  if (Newest > Sequence) and (Newest - Sequence > PanicBacklogLimit) then
    Sequence := Newest - PanicBacklogLimit;
  while ReadLogLine(Sequence, Line) do
  begin
    Length := FormatDatagram(Line, @Datagram[0]);
    if not SendPanicDatagram(PanicRoute, PByte(@Datagram[0]), Length) then
      Exit;
    Sequence := Line.Sequence + 1;
  end;
  NextToSend := Sequence;
end;

procedure StartNetworkLog;
begin
  if not ReadDestinationOption then
    Exit;
  SetPanicFlushRoutine(@FlushNetworkLogAtPanic);
  if CreateSystemThread(@RunNetworkLog, nil, NetworkLogThreadPriority, 'NetworkLog', False) = nil then
    SayProblem('could not start the network log thread', nil);
end;

end.
