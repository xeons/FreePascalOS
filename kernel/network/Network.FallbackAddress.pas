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
  An address for the kernel's own diagnostics (the network log and the
  network debug shell) when user mode does not give one: normally the
  network service configures the interfaces by DHCP, but that needs user
  mode to come up, which is what is being debugged.

    netaddr=A.B.C.D/PREFIX[,GATEWAY]
                   the first Ethernet interface gets this address (and a
                   default route through GATEWAY) as soon as it is there
    netdhcp=SECONDS
                   if no interface has an address SECONDS after
                   networking started, the kernel asks a DHCP server
                   itself; the default is 30 when netlog or netshell is
                   set and netaddr is not, 0 turns it off

  The kernel's DHCP client is minimal: DISCOVER, OFFER, REQUEST, ACK on
  the first Ethernet interface whose link is up, broadcast replies, the
  address, mask and router; the lease is not renewed (a diagnostic
  address, which the network service replaces with its own lease when it
  starts: setting an interface's address drops the routes through it). If
  port 68 is taken, the network service's DHCP client is running, and
  the kernel leaves it to it. Tries are repeated every minute until some
  interface has an address. Each reason for waiting is said once, not at
  every try: with no network card at all ("no network card"), or no link,
  the thread waits quietly for one to come (a USB adapter, a cable) and
  says so again only when the reason changes.
}
unit Network.FallbackAddress;

{$mode objfpc}
{$pointermath on}

interface

{ Starts what the netaddr and netdhcp options ask for. AlsoWanted: the
  network log or shell is on (netdhcp then defaults to 30). }
procedure StartFallbackAddressing(AlsoWanted: Boolean);

implementation

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Runtime.Text,
  Kernel.Options,
  Kernel.Scheduler,
  Kernel.Threads,
  Hal.Platform,
  Processes.Thread,
  Objects.Manager,
  Io.NetworkAdapters,
  Network.Addresses,
  Network.ByteOrder,
  Network.Core,
  Network.Interfaces,
  Network.InterfaceConfiguration,
  Network.Routing,
  Network.ChangeWatchers,
  Network.Sockets,
  Network.SocketOperations,
  Network.OptionText,
  Debug.Output;

const
  DefaultDhcpDelaySeconds = 30;
  RetryMilliseconds = 60 * 1000;
  InterfaceWaitMilliseconds = 1000;
  AnswerTimeoutMilliseconds = 4000;
  ThreadPriority = DefaultThreadPriority + 1;

  DhcpServerPort = 67;
  DhcpClientPort = 68;
  { The fixed part of a message, the magic cookie and room for options. }
  DhcpFixedBytes = 236;
  DhcpMagicCookie = LongWord($63825363);
  DhcpMessageCapacity = 576;
  BootRequest = 1;
  BootReply = 2;
  FlagBroadcast = $8000;

  OptionPad = 0;
  OptionSubnetMask = 1;
  OptionRouter = 3;
  OptionRequestedAddress = 50;
  OptionMessageType = 53;
  OptionServerIdentifier = 54;
  OptionParameterList = 55;
  OptionEnd = 255;

  MessageDiscover = 1;
  MessageOffer = 2;
  MessageRequest = 3;
  MessageAcknowledge = 5;
  MessageRefuse = 6;

type
  TDhcpAnswer = record
    Kind: Byte;
    Address: TIpv4Address;
    Mask: TIpv4Address;
    Router: TIpv4Address;
    Server: TIpv4Address;
  end;

var
  StaticAddress: TIpv4Address;
  StaticPrefix: LongWord;
  HasStaticAddress: Boolean;
  StaticGateway: TIpv4Address;
  DhcpDelaySeconds: QWord;
  TransactionId: LongWord;
  { The last reason for waiting that was said, so it is said once. }
  LastSaid: PChar;

procedure Say(What: PChar; NetworkInterface: PNetworkInterface);
begin
  DebugBeginMessage;
  DebugWriteTag('netaddr');
  if NetworkInterface <> nil then
  begin
    DebugWrite(@NetworkInterface^.Name[0]);
    DebugWrite(': ');
  end;
  DebugWriteLine(What);
  DebugEndMessage;
end;

{ Says What unless it was the last thing said. }
procedure SayOnce(What: PChar);
begin
  if What = LastSaid then
    Exit;
  LastSaid := What;
  Say(What, nil);
end;

{ A.B.C.D/PREFIX, then optionally ,GATEWAY. }
function ParseStaticOption(Position: PChar): Boolean;
begin
  Result := False;
  StaticGateway := AnyAddress;
  if not ReadIpv4Text(Position, StaticAddress) or (Position^ <> '/') then
    Exit;
  Inc(Position);
  if not ReadNumberText(Position, 32, StaticPrefix) or (StaticPrefix = 0) then
    Exit;
  if Position^ = ',' then
  begin
    Inc(Position);
    if not ReadIpv4Text(Position, StaticGateway) then
      Exit;
  end;
  Result := Position^ = #0;
end;

function ReadStaticOption: Boolean;
var
  Value: array[0..63] of Char;
begin
  Result := False;
  if not GetKernelOptionValue('netaddr', @Value[0], SizeOf(Value)) then
    Exit;
  Result := ParseStaticOption(@Value[0]);
  if not Result then
    Say('cannot read the netaddr option (A.B.C.D/PREFIX[,GATEWAY])', nil);
end;

function AnyInterfaceHasAddress: Boolean;
var
  Position: Integer;
  Candidate: PNetworkInterface;
begin
  Result := False;
  LockNetwork;
  for Position := 0 to NetworkInterfaceCount - 1 do
  begin
    Candidate := NetworkInterfaceAt(Position);
    if not Candidate^.IsLoopback and Candidate^.HasAddress then
      Result := True;
  end;
  UnlockNetwork;
end;

{ Any interface but the loopback, link or not. }
function AnyNetworkCard: Boolean;
var
  Position: Integer;
begin
  Result := False;
  LockNetwork;
  for Position := 0 to NetworkInterfaceCount - 1 do
    if not NetworkInterfaceAt(Position)^.IsLoopback then
      Result := True;
  UnlockNetwork;
end;

{ Under the network lock: the first Ethernet interface (with its link up
  if LinkNeeded). }
function FirstEthernetInterfaceLocked(LinkNeeded: Boolean): PNetworkInterface;
var
  Position: Integer;
  Candidate: PNetworkInterface;
begin
  for Position := 0 to NetworkInterfaceCount - 1 do
  begin
    Candidate := NetworkInterfaceAt(Position);
    if not Candidate^.IsLoopback and (Candidate^.LinkIsUp or not LinkNeeded) then
      Exit(Candidate);
  end;
  Result := nil;
end;

function PrefixOfMask(Mask: TIpv4Address): LongWord;
begin
  Result := 0;
  while (Result < 32) and ((Mask and (LongWord($80000000) shr Result)) <> 0) do
    Inc(Result);
end;

{ Under the network lock: gives the interface the address and the
  default route, and tells the watchers. }
procedure ApplyAddressLocked(NetworkInterface: PNetworkInterface; Address: TIpv4Address;
  PrefixLength: LongWord; Gateway: TIpv4Address);
begin
  SetInterfaceUp(NetworkInterface, True);
  if SetInterfaceAddress(NetworkInterface, Address, PrefixLength) <> ErrorNone then
    Exit;
  if Gateway <> AnyAddress then
    AddRoute(AnyAddress, 0, Gateway, NetworkInterface, 0, 0);
  NoteNetworkChange;
end;

procedure ApplyStaticAddress;
var
  NetworkInterface: PNetworkInterface;
begin
  repeat
    LockNetwork;
    NetworkInterface := FirstEthernetInterfaceLocked(False);
    if NetworkInterface <> nil then
      ApplyAddressLocked(NetworkInterface, StaticAddress, StaticPrefix, StaticGateway);
    UnlockNetwork;
    if NetworkInterface <> nil then
      Exit;
    SleepMilliseconds(InterfaceWaitMilliseconds);
  until False;
end;

{ --- DHCP ---------------------------------------------------------------------- }

procedure AddOption(Message: PByte; var Length: LongWord; Code: Byte; Data: PByte; DataLength: Byte);
begin
  Message[Length] := Code;
  Message[Length + 1] := DataLength;
  CopyMemory(@Message[Length + 2], Data, DataLength);
  Inc(Length, 2 + DataLength);
end;

function BuildMessage(Message: PByte; Kind: Byte; constref Hardware: TEthernetAddress;
  constref Offer: TDhcpAnswer): LongWord;
const
  Parameters: array[0..2] of Byte = (OptionSubnetMask, OptionRouter, OptionServerIdentifier);
var
  Length: LongWord;
  Value: array[0..3] of Byte;
begin
  FillMemory(Message, DhcpMessageCapacity, 0);
  Message[0] := BootRequest;
  Message[1] := 1;
  Message[2] := EthernetAddressLength;
  WriteBigEndian32(@Message[4], TransactionId);
  WriteBigEndian16(@Message[10], FlagBroadcast);
  CopyMemory(@Message[28], @Hardware[0], EthernetAddressLength);
  WriteBigEndian32(@Message[DhcpFixedBytes], DhcpMagicCookie);
  Length := DhcpFixedBytes + 4;
  Value[0] := Kind;
  AddOption(Message, Length, OptionMessageType, @Value[0], 1);
  if Kind = MessageRequest then
  begin
    WriteIpv4Address(@Value[0], Offer.Address);
    AddOption(Message, Length, OptionRequestedAddress, @Value[0], 4);
    WriteIpv4Address(@Value[0], Offer.Server);
    AddOption(Message, Length, OptionServerIdentifier, @Value[0], 4);
  end;
  AddOption(Message, Length, OptionParameterList, @Parameters[0], SizeOf(Parameters));
  Message[Length] := OptionEnd;
  Inc(Length);
  { The smallest BOOTP message is 300 bytes; some servers want it. }
  if Length < 300 then
    Length := 300;
  Result := Length;
end;

function ParseAnswer(Message: PByte; Length: LongWord; constref Hardware: TEthernetAddress;
  out Answer: TDhcpAnswer): Boolean;
var
  Position: LongWord;
  Code: Byte;
  OptionLength: Byte;
begin
  Result := False;
  FillMemory(@Answer, SizeOf(Answer), 0);
  if (Length < DhcpFixedBytes + 4) or (Message[0] <> BootReply) or
     (ReadBigEndian32(@Message[4]) <> TransactionId) or
     not MemoryIsEqual(@Message[28], @Hardware[0], EthernetAddressLength) or
     (ReadBigEndian32(@Message[DhcpFixedBytes]) <> DhcpMagicCookie) then
    Exit;
  Answer.Address := ReadIpv4Address(@Message[16]);
  Position := DhcpFixedBytes + 4;
  while Position < Length do
  begin
    Code := Message[Position];
    if Code = OptionEnd then
      Break;
    if Code = OptionPad then
    begin
      Inc(Position);
      Continue;
    end;
    if Position + 1 >= Length then
      Break;
    OptionLength := Message[Position + 1];
    if Position + 2 + OptionLength > Length then
      Break;
    case Code of
      OptionMessageType:
        if OptionLength >= 1 then
          Answer.Kind := Message[Position + 2];
      OptionSubnetMask:
        if OptionLength >= 4 then
          Answer.Mask := ReadIpv4Address(@Message[Position + 2]);
      OptionRouter:
        if OptionLength >= 4 then
          Answer.Router := ReadIpv4Address(@Message[Position + 2]);
      OptionServerIdentifier:
        if OptionLength >= 4 then
          Answer.Server := ReadIpv4Address(@Message[Position + 2]);
    end;
    Inc(Position, 2 + OptionLength);
  end;
  Result := Answer.Kind <> 0;
end;

function KernelOwner: TSocketOwner;
begin
  Result.UserId := 0;
  Result.ProcessId := 0;
end;

{ Sends Kind and waits for an answer of one of the kinds wanted. }
function Exchange(Socket: PSocket; Kind: Byte; constref Hardware: TEthernetAddress;
  constref Offer: TDhcpAnswer; out Answer: TDhcpAnswer): Boolean;
var
  Message: array[0..DhcpMessageCapacity - 1] of Byte;
  Length: LongWord;
  Server: TNetworkEndpoint;
  Source: TNetworkEndpoint;
  Received: Int64;
  Deadline: QWord;
begin
  Result := False;
  FillMemory(@Answer, SizeOf(Answer), 0);
  Length := BuildMessage(@Message[0], Kind, Hardware, Offer);
  Server := MakeEndpoint(LimitedBroadcastAddress, DhcpServerPort);
  if SendOnSocket(Socket, @Message[0], Length, 0, @Server) < 0 then
    Exit;
  Deadline := HalClockNanoseconds + QWord(AnswerTimeoutMilliseconds) * 1000 * 1000;
  while HalClockNanoseconds < Deadline do
  begin
    Received := ReceiveOnSocket(Socket, @Message[0], DhcpMessageCapacity, 0, Source);
    if Received < 0 then
      Exit;
    if not ParseAnswer(@Message[0], LongWord(Received), Hardware, Answer) then
      Continue;
    if Kind = MessageDiscover then
      Exit(Answer.Kind = MessageOffer);
    if (Answer.Kind = MessageAcknowledge) or (Answer.Kind = MessageRefuse) then
      Exit(Answer.Kind = MessageAcknowledge);
  end;
end;

function OpenDhcpSocket(InterfaceIndex: LongWord; out Socket: PSocket): Boolean;
var
  Error: LongInt;
begin
  Result := False;
  if CreateSocket(AddressFamilyIPv4, SocketKindDatagram, ProtocolDefault, KernelOwner, True, Socket) <> ErrorNone then
  begin
    Socket := nil;
    Exit;
  end;
  SetSocketOption(Socket, SocketOptionInterface, InterfaceIndex, True);
  SetSocketOption(Socket, SocketOptionBroadcast, 1, True);
  SetSocketOption(Socket, SocketOptionReceiveTimeout, AnswerTimeoutMilliseconds, True);
  Error := BindSocket(Socket, MakeEndpoint(AnyAddress, DhcpClientPort), True);
  if Error = ErrorAddressInUse then
    Say('port 68 is in use: the network service''s DHCP client runs, it is left to it', nil);
  Result := Error = ErrorNone;
end;

procedure WriteLease(NetworkInterface: PNetworkInterface; constref Answer: TDhcpAnswer);
var
  Text: array[0..15] of Char;
begin
  DebugBeginMessage;
  DebugWriteTag('netaddr');
  DebugWrite(@NetworkInterface^.Name[0]);
  DebugWrite(': kernel DHCP lease ');
  FormatIpv4Text(Answer.Address, @Text[0]);
  DebugWrite(@Text[0]);
  DebugWrite('/');
  DebugWriteDecimal(PrefixOfMask(Answer.Mask));
  if Answer.Router <> AnyAddress then
  begin
    DebugWrite(' via ');
    FormatIpv4Text(Answer.Router, @Text[0]);
    DebugWrite(@Text[0]);
  end;
  DebugWrite(' from ');
  FormatIpv4Text(Answer.Server, @Text[0]);
  DebugWriteLine(@Text[0]);
  DebugEndMessage;
end;

{ One try on the first Ethernet interface with a link. }
procedure TryDhcp;
var
  NetworkInterface: PNetworkInterface;
  Hardware: TEthernetAddress;
  Socket: PSocket;
  Offer: TDhcpAnswer;
  Answer: TDhcpAnswer;
  Prefix: LongWord;
begin
  LockNetwork;
  NetworkInterface := FirstEthernetInterfaceLocked(True);
  if NetworkInterface <> nil then
  begin
    { DHCP goes out of an interface that is on. }
    SetInterfaceUp(NetworkInterface, True);
    Hardware := NetworkInterface^.HardwareAddress;
  end;
  UnlockNetwork;
  if NetworkInterface = nil then
  begin
    SayOnce('no Ethernet interface has a link; DHCP waits');
    Exit;
  end;
  if not OpenDhcpSocket(NetworkInterface^.Index, Socket) then
  begin
    if Socket <> nil then
      DereferenceObject(Socket);
    Exit;
  end;
  TransactionId := LongWord(HalClockNanoseconds) xor (LongWord(Hardware[4]) shl 8) xor Hardware[5];
  FillMemory(@Offer, SizeOf(Offer), 0);
  if Exchange(Socket, MessageDiscover, Hardware, Offer, Offer) and
     Exchange(Socket, MessageRequest, Hardware, Offer, Answer) then
  begin
    if Answer.Mask = AnyAddress then
      Answer.Mask := Offer.Mask;
    if Answer.Router = AnyAddress then
      Answer.Router := Offer.Router;
    if Answer.Server = AnyAddress then
      Answer.Server := Offer.Server;
    Prefix := PrefixOfMask(Answer.Mask);
    if Prefix = 0 then
      Prefix := 24;
    LockNetwork;
    ApplyAddressLocked(NetworkInterface, Answer.Address, Prefix, Answer.Router);
    UnlockNetwork;
    WriteLease(NetworkInterface, Answer);
  end
  else
    Say('no answer from a DHCP server', NetworkInterface);
  DereferenceObject(Socket);
end;

procedure RunFallbackAddressing(Context: Pointer);
begin
  if HasStaticAddress then
  begin
    ApplyStaticAddress;
    Exit;
  end;
  SleepMilliseconds(DhcpDelaySeconds * 1000);
  while not AnyInterfaceHasAddress do
  begin
    if not AnyNetworkCard then
    begin
      { Said once; a card may still come (USB). }
      SayOnce('no network card: no kernel DHCP (netlog, netshell) until one appears');
      SleepMilliseconds(InterfaceWaitMilliseconds * 5);
      Continue;
    end;
    SayOnce('no interface has an address; asking for one by DHCP');
    TryDhcp;
    if AnyInterfaceHasAddress then
      Break;
    SleepMilliseconds(RetryMilliseconds);
  end;
end;

procedure StartFallbackAddressing(AlsoWanted: Boolean);
begin
  HasStaticAddress := ReadStaticOption;
  if not HasStaticAddress then
  begin
    if not GetKernelOptionNumber('netdhcp', DhcpDelaySeconds) then
    begin
      if not AlsoWanted then
        Exit;
      DhcpDelaySeconds := DefaultDhcpDelaySeconds;
    end;
    if DhcpDelaySeconds = 0 then
      Exit;
  end;
  if CreateSystemThread(@RunFallbackAddressing, nil, ThreadPriority, 'NetworkAddress', False) = nil then
    Say('could not start the address thread', nil);
end;

end.
