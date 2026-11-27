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
  A DHCPv6 client for one interface (RFC 8415): its state machine, its
  socket and its timers. Its owner picks the mode - stateful (the
  routers' M flag, or Ipv6Method dhcpv6), stateless (the O flag alone)
  or off - and applies what comes of it.

  Stateful (addresses, an IA_NA, and DNS servers and search domains):
    Soliciting ---Advertise (best preference; 255 at once)---> Requesting
    Requesting ---Reply with addresses---> Bound
    Bound ---T1---> Renewing (to the server) ---T2---> Rebinding (to any)
    Renewing, Rebinding ---Reply---> Bound
    Rebinding ---the addresses' valid lifetimes end---> Soliciting
    Requesting ---NoAddrsAvail, NotOnLink, 10 requests unanswered---> Soliciting
    Renewing, Rebinding ---NoBinding---> Requesting; ---NotOnLink---> Soliciting
  Stateless (DNS servers and search domains only):
    Informing ---Reply---> Informed ---information refresh time---> Informing
  Either:
    any ---link lost---> Paused (the kernel drops DHCPv6 addresses with
    the link) ---link back---> Soliciting or Informing

  Advertises are collected during the first retransmission time of a
  Solicit (about a second) and the one with the highest preference is
  requested; after that the first that comes is. An Advertise without
  an address for the IA_NA is ignored. T1 and T2 of 0 are half and four
  fifths of the shortest preferred lifetime. Retransmissions follow
  section 15: IRT, then twice the previous time, each moved by up to a
  tenth at random, at most MRT; Solicit and Information-request wait up
  to a second before their first message (SOL_MAX_DELAY, INF_MAX_DELAY).
  Solicit: IRT 1 s, MRT 3600 s; Request: 1 s, 30 s, 10 tries; Renew and
  Rebind: 10 s, 600 s, until T2 and the end of the valid lifetimes;
  Information-request: 1 s, 3600 s. RELEASE is sent once when the client
  stops (the service ends, the settings change), not retransmitted.

  Messages go from port 546 (the socket bound to the interface) to
  All_DHCP_Relay_Agents_and_Servers, ff02::1:2 port 547, on the link;
  every message carries the machine's DUID (NetworkService.Dhcpv6Duid)
  and the elapsed time, and a reply counts only with the transaction id,
  the client's DUID and a server's DUID.
}
unit NetworkService.Dhcpv6Client;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Sys.InternetAddresses,
  NetworkService.Dhcpv6Messages;

type
  TDhcpv6Mode = (Dhcpv6ModeOff, Dhcpv6ModeStateless, Dhcpv6ModeStateful);
  TDhcpv6State = (Dhcpv6Stopped, Dhcpv6Paused, Dhcpv6Soliciting, Dhcpv6Requesting, Dhcpv6Bound, Dhcpv6Renewing,
    Dhcpv6Rebinding, Dhcpv6Informing, Dhcpv6Informed);

  TDhcpv6Client = class;
  TDhcpv6ClientEvent = procedure(Client: TDhcpv6Client) of object;

  TDhcpv6Client = class
  private
    FInterfaceName: string;
    FInterfaceIndex: LongWord;
    FHardwareAddress: array[0..5] of Byte;
    FSocket: Int64;
    FMode: TDhcpv6Mode;
    FLinkIsUp: Boolean;
    FState: TDhcpv6State;
    FDeadline: QWord;
    { The exchange under way: its transaction, timing and limits. }
    FTransactionId: LongWord;
    FExchangeStarted: QWord;
    FRetransmitTime: QWord;
    FInitialRetransmitTime: QWord;
    FMaximumRetransmitTime: QWord;
    FMaximumTransmissions: Integer;
    FExchangeLimit: QWord;
    FTransmissions: Integer;
    { Soliciting: the first retransmission time is over, and the best
      Advertise so far. }
    FFirstRoundOver: Boolean;
    FHasAdvertise: Boolean;
    FAdvertise: TDhcpv6ServerMessage;
    { What a Request asks for: the server and the addresses. }
    FRequestServerId: TBytes;
    FRequestAddresses: TDhcpv6LeasedAddresses;
    FClientId: TBytes;
    FIaId: LongWord;
    { The lease (stateful). }
    FHasLease: Boolean;
    FServerId: TBytes;
    FAddresses: TDhcpv6LeasedAddresses;
    FLeaseObtained: QWord;
    FRenewSeconds: LongWord;
    FRebindSeconds: LongWord;
    { The addresses had before, offered as hints in a Solicit. }
    FHints: TDhcpv6LeasedAddresses;
    { From either mode. }
    FHasInformation: Boolean;
    FDnsServers: TInternetAddressArray;
    FDomains: TStringArray;
    FOnChanged: TDhcpv6ClientEvent;
    FOnStateChanged: TDhcpv6ClientEvent;
    procedure Say(const Text: string);
    procedure ChangeState(NewState: TDhcpv6State);
    procedure Changed;
    function OpenSocket: Boolean;
    procedure CloseClientSocket;
    procedure BeginExchange(NewState: TDhcpv6State; InitialTime, MaximumTime: QWord; MaximumTransmissions: Integer;
      Limit, Delay: QWord);
    procedure StartSoliciting;
    procedure StartRequesting(const ServerId: TBytes; const Addresses: TDhcpv6LeasedAddresses);
    procedure StartRenewing;
    procedure StartRebinding;
    procedure StartInforming;
    procedure StartMode;
    function NextRetransmitTime: QWord;
    function MessageFor(Kind: Byte): TDhcpv6ClientMessage;
    procedure Send(constref Message: TDhcpv6ClientMessage);
    procedure Transmit;
    procedure HandleTimeout(Now: QWord);
    procedure HandleAdvertise(constref Message: TDhcpv6ServerMessage);
    procedure HandleLeaseReply(constref Message: TDhcpv6ServerMessage);
    procedure HandleInformationReply(constref Message: TDhcpv6ServerMessage);
    procedure HandleMessage(constref Message: TDhcpv6ServerMessage);
    procedure TakeInformation(constref Message: TDhcpv6ServerMessage);
    procedure Bind(constref Association: TDhcpv6IdentityAssociation; constref Message: TDhcpv6ServerMessage);
    procedure LoseLease(const Why: string);
    function RenewTime: QWord;
    function RebindTime: QWord;
    function ValidEnd: QWord;
  public
    constructor Create(const InterfaceName: string; InterfaceIndex: LongWord; const HardwareAddress: array of Byte);
    destructor Destroy; override;
    { The mode the owner wants; LinkIsUp: whether the interface can send. }
    procedure SetMode(Mode: TDhcpv6Mode; LinkIsUp: Boolean);
    procedure LinkChanged(LinkIsUp: Boolean);
    { Gives the lease back (RELEASE, once) and stops. }
    procedure Release;
    procedure HandleReadable;
    procedure HandleDeadline(Now: QWord);
    { Uptime milliseconds of the next call wanted (NoDeadline: none). }
    function NextDeadline: QWord;
    { "off", "no-link", "configuring", "configured" or "informed". }
    function StateName: string;
    property Socket: Int64 read FSocket;
    property Mode: TDhcpv6Mode read FMode;
    property State: TDhcpv6State read FState;
    property HasLease: Boolean read FHasLease;
    { As the last Reply gave them (lifetimes from LeaseObtained). }
    property Addresses: TDhcpv6LeasedAddresses read FAddresses;
    property LeaseObtained: QWord read FLeaseObtained;
    property ServerId: TBytes read FServerId;
    property DnsServers: TInternetAddressArray read FDnsServers;
    property Domains: TStringArray read FDomains;
    property InterfaceName: string read FInterfaceName;
    { The addresses or the DNS servers and domains changed. }
    property OnChanged: TDhcpv6ClientEvent read FOnChanged write FOnChanged;
    property OnStateChanged: TDhcpv6ClientEvent read FOnStateChanged write FOnStateChanged;
  end;

const
  Dhcpv6NoDeadline = High(QWord);

implementation

uses
  Abi.SystemCalls,
  Sys.Kernel,
  Sys.Sockets,
  Sys.RandomNumbers,
  Sys.AddressText,
  NetworkService.Log,
  NetworkService.Dhcpv6Duid;

const
  Second = 1000;
  SolicitMaximumDelay = 1 * Second;
  SolicitInitialTime = 1 * Second;
  SolicitMaximumTime = 3600 * Second;
  RequestInitialTime = 1 * Second;
  RequestMaximumTime = 30 * Second;
  RequestMaximumTransmissions = 10;
  RenewInitialTime = 10 * Second;
  RenewMaximumTime = 600 * Second;
  RebindInitialTime = 10 * Second;
  RebindMaximumTime = 600 * Second;
  InformationMaximumDelay = 1 * Second;
  InformationInitialTime = 1 * Second;
  InformationMaximumTime = 3600 * Second;
  DefaultInformationRefreshSeconds = 86400;
  MinimumInformationRefreshSeconds = 600;
  SocketRetryMilliseconds = 5000;
  ReceiveBufferBytes = 2048;
  HighestPreference = 255;
  NoLimit = High(QWord);

function NowMilliseconds: QWord;
begin
  Result := QWord(KernelGetTime(TimeUptimeMilliseconds));
end;

{ Time moved by up to a tenth either way (RAND of section 15). }
function Jittered(Time: QWord): QWord;
begin
  Result := Time - Time div 10 + (Time * RandomBelow(201)) div 1000;
end;

{ All_DHCP_Relay_Agents_and_Servers, ff02::1:2. }
function ServersAddress: TInternetAddress;
begin
  Result := AnyIpv6Address;
  Result.Bytes[0] := $FF;
  Result.Bytes[1] := $02;
  Result.Bytes[13] := $01;
  Result.Bytes[15] := $02;
end;

{ The end, Seconds after Start (Dhcpv6Infinity: never). }
function TimeAfter(Start: QWord; Seconds: LongWord): QWord;
begin
  if Seconds = Dhcpv6Infinity then
    Result := Dhcpv6NoDeadline
  else
    Result := Start + QWord(Seconds) * Second;
end;

constructor TDhcpv6Client.Create(const InterfaceName: string; InterfaceIndex: LongWord;
  const HardwareAddress: array of Byte);
begin
  inherited Create;
  FInterfaceName := InterfaceName;
  FInterfaceIndex := InterfaceIndex;
  FillChar(FHardwareAddress, SizeOf(FHardwareAddress), 0);
  if Length(HardwareAddress) >= 6 then
    Move(HardwareAddress[0], FHardwareAddress[0], 6);
  { The IAID: the Ethernet address's last four bytes, the same every
    time for this card. }
  FIaId := (LongWord(FHardwareAddress[2]) shl 24) or (LongWord(FHardwareAddress[3]) shl 16) or
    (LongWord(FHardwareAddress[4]) shl 8) or FHardwareAddress[5];
  FSocket := -1;
  FState := Dhcpv6Stopped;
  FMode := Dhcpv6ModeOff;
  FDeadline := Dhcpv6NoDeadline;
end;

destructor TDhcpv6Client.Destroy;
begin
  CloseClientSocket;
  inherited Destroy;
end;

procedure TDhcpv6Client.Say(const Text: string);
begin
  NetworkService.Log.Say(FInterfaceName + ': DHCPv6: ' + Text);
end;

procedure TDhcpv6Client.ChangeState(NewState: TDhcpv6State);
var
  OldName: string;
begin
  OldName := StateName;
  FState := NewState;
  if (StateName <> OldName) and Assigned(FOnStateChanged) then
    FOnStateChanged(Self);
end;

procedure TDhcpv6Client.Changed;
begin
  if Assigned(FOnChanged) then
    FOnChanged(Self);
end;

function TDhcpv6Client.OpenSocket: Boolean;
var
  Error: LongInt;
begin
  if FSocket >= 0 then
    Exit(True);
  FSocket := CreateSocket(AddressFamilyIPv6, SocketKindDatagram or SocketKindNonBlocking, ProtocolUdp);
  if FSocket < 0 then
  begin
    Say('cannot make a socket: ' + ErrorText(LongInt(-FSocket)));
    FSocket := -1;
    Exit(False);
  end;
  Error := SetSocketOption(FSocket, SocketOptionInterface, FInterfaceIndex);
  if Error = ErrorNone then
    Error := BindSocket(FSocket, MakeSocketAddress(AnyIpv6Address, Dhcpv6ClientPort));
  if Error <> ErrorNone then
  begin
    Say('cannot take port 546: ' + ErrorText(Error));
    CloseClientSocket;
    Exit(False);
  end;
  Result := True;
end;

procedure TDhcpv6Client.CloseClientSocket;
begin
  if FSocket >= 0 then
    CloseSocket(FSocket);
  FSocket := -1;
end;

function TDhcpv6Client.RenewTime: QWord;
begin
  Result := TimeAfter(FLeaseObtained, FRenewSeconds);
end;

function TDhcpv6Client.RebindTime: QWord;
begin
  Result := TimeAfter(FLeaseObtained, FRebindSeconds);
end;

{ When the last address's valid lifetime ends. }
function TDhcpv6Client.ValidEnd: QWord;
var
  Index: Integer;
  Candidate: QWord;
begin
  Result := FLeaseObtained;
  for Index := 0 to High(FAddresses) do
  begin
    Candidate := TimeAfter(FLeaseObtained, FAddresses[Index].ValidSeconds);
    if Candidate > Result then
      Result := Candidate;
  end;
end;

{ --- Exchanges ---------------------------------------------------------------- }

procedure TDhcpv6Client.BeginExchange(NewState: TDhcpv6State; InitialTime, MaximumTime: QWord;
  MaximumTransmissions: Integer; Limit, Delay: QWord);
begin
  FTransactionId := RandomLongWord and $FFFFFF;
  FTransmissions := 0;
  FExchangeStarted := 0;
  FInitialRetransmitTime := InitialTime;
  FMaximumRetransmitTime := MaximumTime;
  FMaximumTransmissions := MaximumTransmissions;
  FExchangeLimit := Limit;
  FRetransmitTime := 0;
  FDeadline := NowMilliseconds + Delay;
  ChangeState(NewState);
end;

procedure TDhcpv6Client.StartSoliciting;
begin
  FFirstRoundOver := False;
  FHasAdvertise := False;
  BeginExchange(Dhcpv6Soliciting, SolicitInitialTime, SolicitMaximumTime, 0, NoLimit,
    RandomBelow(SolicitMaximumDelay));
end;

procedure TDhcpv6Client.StartRequesting(const ServerId: TBytes; const Addresses: TDhcpv6LeasedAddresses);
begin
  FRequestServerId := Copy(ServerId);
  FRequestAddresses := Copy(Addresses);
  BeginExchange(Dhcpv6Requesting, RequestInitialTime, RequestMaximumTime, RequestMaximumTransmissions, NoLimit, 0);
end;

procedure TDhcpv6Client.StartRenewing;
begin
  BeginExchange(Dhcpv6Renewing, RenewInitialTime, RenewMaximumTime, 0, RebindTime, 0);
end;

procedure TDhcpv6Client.StartRebinding;
begin
  BeginExchange(Dhcpv6Rebinding, RebindInitialTime, RebindMaximumTime, 0, ValidEnd, 0);
end;

procedure TDhcpv6Client.StartInforming;
begin
  BeginExchange(Dhcpv6Informing, InformationInitialTime, InformationMaximumTime, 0, NoLimit,
    RandomBelow(InformationMaximumDelay));
end;

procedure TDhcpv6Client.StartMode;
begin
  if not OpenSocket then
  begin
    FDeadline := NowMilliseconds + SocketRetryMilliseconds;
    Exit;
  end;
  case FMode of
    Dhcpv6ModeStateful: StartSoliciting;
    Dhcpv6ModeStateless: StartInforming;
  end;
end;

procedure TDhcpv6Client.SetMode(Mode: TDhcpv6Mode; LinkIsUp: Boolean);
begin
  if Mode = FMode then
  begin
    LinkChanged(LinkIsUp);
    Exit;
  end;
  FLinkIsUp := LinkIsUp;
  if Mode = Dhcpv6ModeOff then
  begin
    Release;
    Exit;
  end;
  if FHasLease then
  begin
    { Stateful to stateless: the addresses are given back. }
    Release;
  end;
  FMode := Mode;
  if Mode = Dhcpv6ModeStateful then
    Say('asking for an address (stateful)')
  else
    Say('asking for DNS servers (stateless)');
  if not LinkIsUp then
  begin
    FDeadline := Dhcpv6NoDeadline;
    ChangeState(Dhcpv6Paused);
    Exit;
  end;
  StartMode;
end;

procedure TDhcpv6Client.LinkChanged(LinkIsUp: Boolean);
begin
  if LinkIsUp = FLinkIsUp then
    Exit;
  FLinkIsUp := LinkIsUp;
  if FMode = Dhcpv6ModeOff then
    Exit;
  if not LinkIsUp then
  begin
    { The kernel drops the DHCPv6 addresses with the link. }
    LoseLease('gone with the link');
    FDeadline := Dhcpv6NoDeadline;
    ChangeState(Dhcpv6Paused);
    Exit;
  end;
  StartMode;
end;

procedure TDhcpv6Client.Release;
begin
  if FHasLease and (FSocket >= 0) then
  begin
    FTransactionId := RandomLongWord and $FFFFFF;
    FExchangeStarted := 0;
    Send(MessageFor(Dhcpv6Release));
    LoseLease('released');
  end
  else
    LoseLease('given up');
  if FHasInformation then
  begin
    FHasInformation := False;
    FDnsServers := nil;
    FDomains := nil;
    Changed;
  end;
  CloseClientSocket;
  FMode := Dhcpv6ModeOff;
  FDeadline := Dhcpv6NoDeadline;
  ChangeState(Dhcpv6Stopped);
end;

{ --- Sending ------------------------------------------------------------------ }

{ The addresses for a client message (lifetimes left to the server). }
function AddressesToAsk(const Addresses: TDhcpv6LeasedAddresses): TDhcpv6LeasedAddresses;
var
  Index: Integer;
begin
  Result := nil;
  SetLength(Result, Length(Addresses));
  for Index := 0 to High(Addresses) do
  begin
    Result[Index] := Default(TDhcpv6LeasedAddress);
    Result[Index].Address := Addresses[Index].Address;
  end;
end;

function TDhcpv6Client.MessageFor(Kind: Byte): TDhcpv6ClientMessage;
var
  Elapsed: QWord;
begin
  Result := Default(TDhcpv6ClientMessage);
  Result.Kind := Kind;
  Result.TransactionId := FTransactionId;
  if Length(FClientId) = 0 then
    FClientId := MachineDuid(FHardwareAddress);
  Result.ClientId := FClientId;
  if FExchangeStarted = 0 then
    Elapsed := 0
  else
    Elapsed := (NowMilliseconds - FExchangeStarted) div 10;
  if Elapsed > High(Word) then
    Elapsed := High(Word);
  Result.ElapsedHundredths := Word(Elapsed);
  Result.IdentityAssociation.IaId := FIaId;
  case Kind of
    Dhcpv6Solicit:
      begin
        Result.HasIdentityAssociation := True;
        Result.IdentityAssociation.Addresses := AddressesToAsk(FHints);
      end;
    Dhcpv6Request:
      begin
        Result.ServerId := FRequestServerId;
        Result.HasIdentityAssociation := True;
        Result.IdentityAssociation.Addresses := AddressesToAsk(FRequestAddresses);
      end;
    Dhcpv6Renew, Dhcpv6Release:
      begin
        Result.ServerId := FServerId;
        Result.HasIdentityAssociation := True;
        Result.IdentityAssociation.Addresses := AddressesToAsk(FAddresses);
      end;
    Dhcpv6Rebind:
      begin
        Result.HasIdentityAssociation := True;
        Result.IdentityAssociation.Addresses := AddressesToAsk(FAddresses);
      end;
  end;
  if Kind = Dhcpv6InformationRequest then
    Result.RequestedOptions := [Dhcpv6OptionDnsServers, Dhcpv6OptionDomainList,
      Dhcpv6OptionInformationRefreshTime]
  else if Kind <> Dhcpv6Release then
    Result.RequestedOptions := [Dhcpv6OptionDnsServers, Dhcpv6OptionDomainList];
end;

procedure TDhcpv6Client.Send(constref Message: TDhcpv6ClientMessage);
var
  Bytes: TBytes;
  Destination: TAbiSocketAddress;
  Sent: Int64;
begin
  if not OpenSocket then
    Exit;
  Bytes := BuildDhcpv6Message(Message);
  Destination := MakeSocketAddress(ServersAddress, Dhcpv6ServerPort);
  Destination.ScopeId := FInterfaceIndex;
  Sent := SendSocketTo(FSocket, @Bytes[0], Length(Bytes), SocketFlagDontWait, Destination);
  if Sent < 0 then
    Say(Dhcpv6KindName(Message.Kind) + ' not sent: ' + ErrorText(LongInt(-Sent)))
  else
    Say(Dhcpv6KindName(Message.Kind));
end;

function TDhcpv6Client.NextRetransmitTime: QWord;
begin
  if FRetransmitTime = 0 then
  begin
    { The first: a Solicit's must be longer than IRT (RAND above 0). }
    if FState = Dhcpv6Soliciting then
      Result := FInitialRetransmitTime + (FInitialRetransmitTime * (1 + RandomBelow(100))) div 1000
    else
      Result := Jittered(FInitialRetransmitTime);
  end
  else
    Result := Jittered(2 * FRetransmitTime);
  if (FMaximumRetransmitTime <> 0) and (Result > FMaximumRetransmitTime) then
    Result := Jittered(FMaximumRetransmitTime);
end;

procedure TDhcpv6Client.Transmit;
var
  Now: QWord;
begin
  Now := NowMilliseconds;
  case FState of
    Dhcpv6Soliciting: Send(MessageFor(Dhcpv6Solicit));
    Dhcpv6Requesting: Send(MessageFor(Dhcpv6Request));
    Dhcpv6Renewing: Send(MessageFor(Dhcpv6Renew));
    Dhcpv6Rebinding: Send(MessageFor(Dhcpv6Rebind));
    Dhcpv6Informing: Send(MessageFor(Dhcpv6InformationRequest));
  else
    Exit;
  end;
  if FExchangeStarted = 0 then
    FExchangeStarted := Now;
  Inc(FTransmissions);
  FRetransmitTime := NextRetransmitTime;
  FDeadline := Now + FRetransmitTime;
  if FDeadline > FExchangeLimit then
    FDeadline := FExchangeLimit;
end;

{ --- Timers ------------------------------------------------------------------- }

procedure TDhcpv6Client.HandleTimeout(Now: QWord);
begin
  case FState of
    Dhcpv6Soliciting:
      if (FTransmissions = 1) and not FFirstRoundOver then
      begin
        FFirstRoundOver := True;
        if FHasAdvertise then
          StartRequesting(FAdvertise.ServerId, FRequestAddresses)
        else
          Transmit;
      end
      else
        Transmit;
    Dhcpv6Requesting:
      if FTransmissions >= FMaximumTransmissions then
      begin
        Say('no reply to REQUEST: soliciting again');
        StartSoliciting;
      end
      else
        Transmit;
    Dhcpv6Renewing:
      if Now >= RebindTime then
        StartRebinding
      else
        Transmit;
    Dhcpv6Rebinding:
      if Now >= ValidEnd then
      begin
        LoseLease('ran out');
        StartSoliciting;
      end
      else
        Transmit;
    Dhcpv6Informing:
      Transmit;
  end;
end;

procedure TDhcpv6Client.HandleDeadline(Now: QWord);
begin
  if Now < FDeadline then
    Exit;
  case FState of
    Dhcpv6Stopped, Dhcpv6Paused:
      FDeadline := Dhcpv6NoDeadline;
    Dhcpv6Bound:
      if Now >= RenewTime then
        StartRenewing
      else
        FDeadline := RenewTime;
    Dhcpv6Informed:
      StartInforming;
  else
    if FSocket < 0 then
      StartMode
    else if FTransmissions = 0 then
      Transmit
    else
      HandleTimeout(Now);
  end;
end;

function TDhcpv6Client.NextDeadline: QWord;
begin
  Result := FDeadline;
end;

{ --- Replies ------------------------------------------------------------------ }

{ The addresses of an IA_NA worth keeping: valid, preferred no longer
  than valid, without a failure status. }
function UsableAddresses(constref Association: TDhcpv6IdentityAssociation): TDhcpv6LeasedAddresses;
var
  Index: Integer;
  Candidate: TDhcpv6LeasedAddress;
begin
  Result := nil;
  for Index := 0 to High(Association.Addresses) do
  begin
    Candidate := Association.Addresses[Index];
    if (Candidate.ValidSeconds = 0) or (Candidate.PreferredSeconds > Candidate.ValidSeconds) or
       (Candidate.StatusCode <> Dhcpv6StatusSuccess) or (Candidate.Address.Family <> AddressFamilyIPv6) then
      Continue;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Candidate;
  end;
end;

procedure TDhcpv6Client.HandleAdvertise(constref Message: TDhcpv6ServerMessage);
var
  Association: TDhcpv6IdentityAssociation;
  Offered: TDhcpv6LeasedAddresses;
begin
  if not FindIdentityAssociation(Message, FIaId, Association) then
    Exit;
  Offered := UsableAddresses(Association);
  if (Length(Offered) = 0) or (Association.HasStatus and (Association.StatusCode <> Dhcpv6StatusSuccess)) then
    Exit;
  Say('ADVERTISE of ' + AddressToText(Offered[0].Address) + ' (preference ' + IntToStr(Message.Preference) + ')');
  if not FHasAdvertise or (Message.Preference > FAdvertise.Preference) then
  begin
    FAdvertise := Message;
    FRequestAddresses := Offered;
    FHasAdvertise := True;
  end;
  if (Message.Preference = HighestPreference) or FFirstRoundOver then
    StartRequesting(FAdvertise.ServerId, FRequestAddresses);
end;

procedure TDhcpv6Client.TakeInformation(constref Message: TDhcpv6ServerMessage);
begin
  FDnsServers := Copy(Message.DnsServers);
  FDomains := Copy(Message.Domains);
  FHasInformation := True;
end;

procedure TDhcpv6Client.Bind(constref Association: TDhcpv6IdentityAssociation;
  constref Message: TDhcpv6ServerMessage);
var
  Usable: TDhcpv6LeasedAddresses;
begin
  Usable := UsableAddresses(Association);
  if Length(Usable) = 0 then
  begin
    if FState = Dhcpv6Requesting then
    begin
      Say('REPLY without an address: soliciting again');
      StartSoliciting;
    end;
    Exit;
  end;
  FServerId := Copy(Message.ServerId);
  FAddresses := Usable;
  FHints := Copy(Usable);
  FLeaseObtained := NowMilliseconds;
  Dhcpv6RenewalTimes(Association, Usable, FRenewSeconds, FRebindSeconds);
  TakeInformation(Message);
  FHasLease := True;
  Say('bound to ' + AddressToText(Usable[0].Address) + ', preferred ' + IntToStr(Usable[0].PreferredSeconds) +
    ' s, valid ' + IntToStr(Usable[0].ValidSeconds) + ' s, by ' + BytesToColonHex(FServerId));
  FDeadline := RenewTime;
  { The owner applies the addresses before the state says configured. }
  Changed;
  ChangeState(Dhcpv6Bound);
end;

procedure TDhcpv6Client.LoseLease(const Why: string);
begin
  if not FHasLease then
    Exit;
  Say('lease of ' + AddressToText(FAddresses[0].Address) + ' ' + Why);
  FHasLease := False;
  FAddresses := nil;
  FServerId := nil;
  FHasInformation := False;
  FDnsServers := nil;
  FDomains := nil;
  Changed;
end;

procedure TDhcpv6Client.HandleLeaseReply(constref Message: TDhcpv6ServerMessage);
var
  Association: TDhcpv6IdentityAssociation;
begin
  if Message.HasStatus and (Message.StatusCode <> Dhcpv6StatusSuccess) then
  begin
    Say('REPLY: ' + Dhcpv6StatusName(Message.StatusCode) + ' ' + Message.StatusMessage);
    if Message.StatusCode = Dhcpv6StatusNotOnLink then
    begin
      LoseLease('not on this link');
      StartSoliciting;
    end;
    Exit;
  end;
  if not FindIdentityAssociation(Message, FIaId, Association) then
    Exit;
  if Association.HasStatus and (Association.StatusCode <> Dhcpv6StatusSuccess) then
  begin
    Say('REPLY: ' + Dhcpv6StatusName(Association.StatusCode) + ' ' + Association.StatusMessage);
    case Association.StatusCode of
      Dhcpv6StatusNoBinding:
        if FState = Dhcpv6Requesting then
          StartSoliciting
        else
          StartRequesting(Message.ServerId, FAddresses);
      Dhcpv6StatusNotOnLink:
        begin
          LoseLease('not on this link');
          StartSoliciting;
        end;
      Dhcpv6StatusNoAddressesAvailable:
        if FState = Dhcpv6Requesting then
          StartSoliciting;
    end;
    Exit;
  end;
  Bind(Association, Message);
end;

procedure TDhcpv6Client.HandleInformationReply(constref Message: TDhcpv6ServerMessage);
var
  Refresh: LongWord;
begin
  if Message.HasStatus and (Message.StatusCode <> Dhcpv6StatusSuccess) then
    Exit;
  TakeInformation(Message);
  Refresh := DefaultInformationRefreshSeconds;
  if Message.HasInformationRefreshTime then
  begin
    Refresh := Message.InformationRefreshSeconds;
    if Refresh < MinimumInformationRefreshSeconds then
      Refresh := MinimumInformationRefreshSeconds;
  end;
  Say('information: ' + IntToStr(Length(FDnsServers)) + ' DNS servers, ' + IntToStr(Length(FDomains)) +
    ' domains, again in ' + IntToStr(Refresh) + ' s');
  FDeadline := TimeAfter(NowMilliseconds, Refresh);
  Changed;
  ChangeState(Dhcpv6Informed);
end;

procedure TDhcpv6Client.HandleMessage(constref Message: TDhcpv6ServerMessage);
begin
  if (Message.TransactionId <> FTransactionId) or (Length(Message.ServerId) = 0) then
    Exit;
  { A reply to an information-request may leave the client's DUID out. }
  if not SameBytes(Message.ClientId, FClientId) and
     not ((FState = Dhcpv6Informing) and (Length(Message.ClientId) = 0)) then
    Exit;
  case FState of
    Dhcpv6Soliciting:
      if Message.Kind = Dhcpv6Advertise then
        HandleAdvertise(Message);
    Dhcpv6Requesting, Dhcpv6Renewing, Dhcpv6Rebinding:
      if Message.Kind = Dhcpv6Reply then
        HandleLeaseReply(Message);
    Dhcpv6Informing:
      if Message.Kind = Dhcpv6Reply then
        HandleInformationReply(Message);
  end;
end;

procedure TDhcpv6Client.HandleReadable;
var
  Buffer: array[0..ReceiveBufferBytes - 1] of Byte;
  Received: Int64;
  Message: TDhcpv6ServerMessage;
begin
  if FSocket < 0 then
    Exit;
  repeat
    Received := ReceiveOnSocket(FSocket, @Buffer[0], SizeOf(Buffer), SocketFlagDontWait);
    if Received <= 0 then
      Exit;
    if ParseDhcpv6Message(@Buffer[0], LongWord(Received), Message) then
      HandleMessage(Message);
  until FSocket < 0;
end;

function TDhcpv6Client.StateName: string;
begin
  case FState of
    Dhcpv6Stopped: Result := 'off';
    Dhcpv6Paused: Result := 'no-link';
    Dhcpv6Bound, Dhcpv6Renewing, Dhcpv6Rebinding: Result := 'configured';
    Dhcpv6Informed: Result := 'informed';
  else
    if FHasLease then
      Result := 'configured'
    else if FHasInformation then
      Result := 'informed'
    else
      Result := 'configuring';
  end;
end;

end.
