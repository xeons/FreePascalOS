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
  A DHCP client for one interface (RFC 2131, section 4.4): its state
  machine, its socket and its timers.

    Init ---DISCOVER---> Selecting ---OFFER, REQUEST---> Requesting
    Requesting ---ACK---> Probing ---no answer---> Bound
                                  ---answer, DECLINE---> Declined -> Init
    Requesting ---NAK, or no answer---> Init
    InitReboot (a previous lease) ---REQUEST---> Rebooting
    Rebooting ---ACK---> Probing; ---NAK, or no answer---> Init
    Bound ---T1---> Renewing (REQUEST to the server, unicast)
    Renewing ---T2---> Rebinding (REQUEST to everyone, broadcast)
    Renewing, Rebinding ---ACK---> Bound; ---NAK, or the lease ran out---> Init
    any ---link lost---> Paused ---link back---> InitReboot (or Init)

  Retransmissions wait 4 seconds, then 8, 16, 32 and 64 at most, each
  moved by up to a second either way at random (4.1); while renewing
  and rebinding, half the time left (to T2, or to the end), at least a
  minute (4.4.5). Requesting gives up after four requests, rebooting
  after three. A client that has no lease a minute after it started
  says so (Failed: the state file's "failed") and goes on trying.

  The client owns its UDP socket (port 68, bound to the interface,
  broadcasts allowed), which its owner waits on and hands over when it
  is readable (HandleReadable), and asks for a call at NextDeadline
  (HandleDeadline). What the lease means for the interface - the
  address, the default route, the DNS servers - is the owner's: it is
  told through OnLeaseObtained and OnLeaseLost, and of every change of
  state through OnStateChanged.
}
unit NetworkService.DhcpClient;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Sys.InternetAddresses,
  NetworkService.DhcpMessages,
  NetworkService.DhcpLeases;

type
  TDhcpState = (DhcpStopped, DhcpPaused, DhcpInit, DhcpSelecting, DhcpRequesting, DhcpProbing, DhcpDeclined,
    DhcpInitReboot, DhcpRebooting, DhcpBound, DhcpRenewing, DhcpRebinding);

  TDhcpClient = class;
  TDhcpClientEvent = procedure(Client: TDhcpClient) of object;

  TDhcpClient = class
  private
    FInterfaceName: string;
    FInterfaceIndex: LongWord;
    FHardwareAddress: TEthernetAddress;
    FSocket: Int64;
    FState: TDhcpState;
    FDeadline: QWord;
    FTransactionId: LongWord;
    { When this round of messages began (the "secs" field). }
    FRoundStarted: QWord;
    FRetransmitInterval: QWord;
    FTransmissions: Integer;
    { When the client began looking for a lease without having one. }
    FSearchStarted: QWord;
    FHasLease: Boolean;
    FLease: TDhcpLease;
    { The offer being requested, and the acknowledged lease being probed. }
    FOffer: TDhcpReply;
    FCandidate: TDhcpLease;
    { The address to ask for again (INIT-REBOOT). }
    FHasPreviousAddress: Boolean;
    FPreviousAddress: TInternetAddress;
    FOnLeaseObtained: TDhcpClientEvent;
    FOnLeaseLost: TDhcpClientEvent;
    FOnStateChanged: TDhcpClientEvent;
    procedure ChangeState(NewState: TDhcpState);
    function OpenSocket: Boolean;
    procedure CloseClientSocket;
    function BaseParameters(Kind: Byte): TDhcpRequestParameters;
    procedure Send(constref Parameters: TDhcpRequestParameters; constref Destination: TInternetAddress);
    procedure SendDiscover;
    procedure SendSelectingRequest;
    procedure SendRebootRequest;
    procedure SendRenewalRequest(Broadcast: Boolean);
    procedure SendDecline;
    procedure BeginRound;
    procedure ScheduleRetransmission;
    procedure ScheduleLeaseRetransmission(Limit: QWord);
    procedure EnterInit(Delay: QWord);
    procedure EnterInitReboot;
    procedure BeginProbe(constref Reply: TDhcpReply);
    procedure Bind(constref Lease: TDhcpLease);
    procedure LoseLease(const Why: string);
    procedure HandleReply(constref Reply: TDhcpReply);
    procedure Say(const Text: string);
  public
    constructor Create(const InterfaceName: string; InterfaceIndex: LongWord;
      constref HardwareAddress: TEthernetAddress);
    destructor Destroy; override;
    { Begins (the link is up): asks for PreviousAddress again if given. }
    procedure Start(HasPreviousAddress: Boolean; constref PreviousAddress: TInternetAddress);
    { The link went (False) or came back (True). }
    procedure LinkChanged(LinkIsUp: Boolean);
    { Gives the lease back (DHCPRELEASE) and stops. }
    procedure Release;
    procedure HandleReadable;
    procedure HandleDeadline(Now: QWord);
    { Uptime milliseconds of the next call wanted (NoDeadline: none). }
    function NextDeadline: QWord;
    { "configuring", "configured", "no-link", "failed" or "down". }
    function StateName: string;
    property Socket: Int64 read FSocket;
    property State: TDhcpState read FState;
    property HasLease: Boolean read FHasLease;
    property Lease: TDhcpLease read FLease;
    property InterfaceName: string read FInterfaceName;
    property OnLeaseObtained: TDhcpClientEvent read FOnLeaseObtained write FOnLeaseObtained;
    property OnLeaseLost: TDhcpClientEvent read FOnLeaseLost write FOnLeaseLost;
    property OnStateChanged: TDhcpClientEvent read FOnStateChanged write FOnStateChanged;
  end;

implementation

uses
  Abi.SystemCalls,
  Sys.Kernel,
  Sys.Sockets,
  Sys.Information,
  Sys.RandomNumbers,
  Sys.AddressText,
  NetworkService.Log,
  NetworkService.AddressProbe;

const
  FirstRetransmitMilliseconds = 4000;
  LastRetransmitMilliseconds = 64000;
  RetransmitJitterMilliseconds = 1000;
  MinimumLeaseRetransmitMilliseconds = 60000;
  RequestTransmissions = 4;
  RebootTransmissions = 3;
  DeclineWaitMilliseconds = 10000;
  NakWaitMilliseconds = 1000;
  StartJitterMilliseconds = 500;
  FailedAfterMilliseconds = 60000;
  SocketRetryMilliseconds = 5000;
  ReceiveBufferBytes = 2048;

function NowMilliseconds: QWord;
begin
  Result := QWord(KernelGetTime(TimeUptimeMilliseconds));
end;

function WallClockNow: Int64;
begin
  Result := KernelGetTime(TimeWallClock);
end;

{ Value moved by up to Jitter milliseconds either way. }
function Jittered(Value, Jitter: QWord): QWord;
begin
  Result := Value - Jitter + RandomBelow(LongWord(2 * Jitter + 1));
end;

constructor TDhcpClient.Create(const InterfaceName: string; InterfaceIndex: LongWord;
  constref HardwareAddress: TEthernetAddress);
begin
  inherited Create;
  FInterfaceName := InterfaceName;
  FInterfaceIndex := InterfaceIndex;
  FHardwareAddress := HardwareAddress;
  FSocket := -1;
  FState := DhcpStopped;
  FDeadline := NoDeadline;
  FHasLease := False;
end;

destructor TDhcpClient.Destroy;
begin
  CloseClientSocket;
  inherited Destroy;
end;

procedure TDhcpClient.Say(const Text: string);
begin
  NetworkService.Log.Say(FInterfaceName + ': ' + Text);
end;

procedure TDhcpClient.ChangeState(NewState: TDhcpState);
var
  OldName: string;
begin
  OldName := StateName;
  FState := NewState;
  if (StateName <> OldName) and Assigned(FOnStateChanged) then
    FOnStateChanged(Self);
end;

function TDhcpClient.OpenSocket: Boolean;
var
  Error: LongInt;
begin
  if FSocket >= 0 then
    Exit(True);
  FSocket := CreateSocket(AddressFamilyIPv4, SocketKindDatagram or SocketKindNonBlocking, ProtocolUdp);
  if FSocket < 0 then
  begin
    Say('cannot make a socket: ' + ErrorText(LongInt(-FSocket)));
    FSocket := -1;
    Exit(False);
  end;
  Error := SetSocketOption(FSocket, SocketOptionInterface, FInterfaceIndex);
  if Error = ErrorNone then
    Error := SetSocketOption(FSocket, SocketOptionBroadcast, 1);
  if Error = ErrorNone then
    Error := BindSocket(FSocket, MakeSocketAddress(AnyIpv4Address, DhcpClientPort));
  if Error <> ErrorNone then
  begin
    Say('cannot take port 68: ' + ErrorText(Error));
    CloseClientSocket;
    Exit(False);
  end;
  Result := True;
end;

procedure TDhcpClient.CloseClientSocket;
begin
  if FSocket >= 0 then
    CloseSocket(FSocket);
  FSocket := -1;
end;

function TDhcpClient.BaseParameters(Kind: Byte): TDhcpRequestParameters;
var
  NodeName: string;
  Elapsed: QWord;
begin
  Result.Kind := Kind;
  Result.TransactionId := FTransactionId;
  Elapsed := (NowMilliseconds - FRoundStarted) div 1000;
  if Elapsed > High(Word) then
    Elapsed := High(Word);
  Result.SecondsElapsed := Word(Elapsed);
  Result.BroadcastReply := False;
  Result.HardwareAddress := FHardwareAddress;
  Result.ClientAddress := AnyIpv4Address;
  Result.HasRequestedAddress := False;
  Result.RequestedAddress := AnyIpv4Address;
  Result.HasServerIdentifier := False;
  Result.ServerIdentifier := AnyIpv4Address;
  Result.HostName := '';
  if ReadNodeName(NodeName) = ErrorNone then
    Result.HostName := NodeName;
  Result.AskForParameters := (Kind = DhcpDiscover) or (Kind = DhcpRequest);
end;

procedure TDhcpClient.Send(constref Parameters: TDhcpRequestParameters; constref Destination: TInternetAddress);
var
  Buffer: array[0..MaximumDhcpMessage - 1] of Byte;
  Length: LongWord;
  Sent: Int64;
begin
  if not OpenSocket then
    Exit;
  if not BuildDhcpMessage(Parameters, @Buffer[0], SizeOf(Buffer), Length) then
    Exit;
  Sent := SendSocketTo(FSocket, @Buffer[0], Length, SocketFlagDontWait,
    MakeSocketAddress(Destination, DhcpServerPort));
  if Sent < 0 then
    Say(DhcpKindName(Parameters.Kind) + ' not sent: ' + ErrorText(LongInt(-Sent)));
end;

procedure TDhcpClient.SendDiscover;
var
  Parameters: TDhcpRequestParameters;
begin
  Parameters := BaseParameters(DhcpDiscover);
  Parameters.BroadcastReply := True;
  if FHasPreviousAddress then
  begin
    Parameters.HasRequestedAddress := True;
    Parameters.RequestedAddress := FPreviousAddress;
  end;
  Say('DHCPDISCOVER');
  Send(Parameters, BroadcastIpv4Address);
end;

procedure TDhcpClient.SendSelectingRequest;
var
  Parameters: TDhcpRequestParameters;
begin
  Parameters := BaseParameters(DhcpRequest);
  Parameters.BroadcastReply := True;
  Parameters.HasRequestedAddress := True;
  Parameters.RequestedAddress := FOffer.YourAddress;
  Parameters.HasServerIdentifier := FOffer.HasServerIdentifier;
  Parameters.ServerIdentifier := FOffer.ServerIdentifier;
  Say('DHCPREQUEST for ' + AddressToText(FOffer.YourAddress) + ' to ' + AddressToText(FOffer.ServerIdentifier));
  Send(Parameters, BroadcastIpv4Address);
end;

procedure TDhcpClient.SendRebootRequest;
var
  Parameters: TDhcpRequestParameters;
begin
  Parameters := BaseParameters(DhcpRequest);
  Parameters.BroadcastReply := True;
  Parameters.HasRequestedAddress := True;
  Parameters.RequestedAddress := FPreviousAddress;
  Say('DHCPREQUEST for ' + AddressToText(FPreviousAddress) + ' (the previous lease)');
  Send(Parameters, BroadcastIpv4Address);
end;

procedure TDhcpClient.SendRenewalRequest(Broadcast: Boolean);
var
  Parameters: TDhcpRequestParameters;
begin
  Parameters := BaseParameters(DhcpRequest);
  Parameters.ClientAddress := FLease.Address;
  if Broadcast then
  begin
    Say('DHCPREQUEST for ' + AddressToText(FLease.Address) + ' to everyone (rebinding)');
    Send(Parameters, BroadcastIpv4Address);
  end
  else
  begin
    Say('DHCPREQUEST for ' + AddressToText(FLease.Address) + ' to ' + AddressToText(FLease.Server) + ' (renewing)');
    Send(Parameters, FLease.Server);
  end;
end;

procedure TDhcpClient.SendDecline;
var
  Parameters: TDhcpRequestParameters;
begin
  Parameters := BaseParameters(DhcpDecline);
  Parameters.HasRequestedAddress := True;
  Parameters.RequestedAddress := FCandidate.Address;
  Parameters.HasServerIdentifier := True;
  Parameters.ServerIdentifier := FCandidate.Server;
  Say('DHCPDECLINE of ' + AddressToText(FCandidate.Address) + ': another host has it');
  Send(Parameters, BroadcastIpv4Address);
end;

procedure TDhcpClient.BeginRound;
begin
  FTransactionId := RandomLongWord;
  FRoundStarted := NowMilliseconds;
  FRetransmitInterval := FirstRetransmitMilliseconds;
  FTransmissions := 1;
end;

procedure TDhcpClient.ScheduleRetransmission;
begin
  FDeadline := NowMilliseconds + Jittered(FRetransmitInterval, RetransmitJitterMilliseconds);
  FRetransmitInterval := FRetransmitInterval * 2;
  if FRetransmitInterval > LastRetransmitMilliseconds then
    FRetransmitInterval := LastRetransmitMilliseconds;
end;

{ Renewing and rebinding: half the time left until Limit, at least a
  minute, never past Limit. }
procedure TDhcpClient.ScheduleLeaseRetransmission(Limit: QWord);
var
  Now: QWord;
  Wait: QWord;
begin
  Now := NowMilliseconds;
  if Limit = NoDeadline then
  begin
    FDeadline := Now + MinimumLeaseRetransmitMilliseconds;
    Exit;
  end;
  if Limit <= Now then
  begin
    FDeadline := Now;
    Exit;
  end;
  Wait := (Limit - Now) div 2;
  if Wait < MinimumLeaseRetransmitMilliseconds then
    Wait := MinimumLeaseRetransmitMilliseconds;
  FDeadline := Now + Wait;
  if FDeadline > Limit then
    FDeadline := Limit;
end;

procedure TDhcpClient.EnterInit(Delay: QWord);
begin
  if not FHasLease and (FSearchStarted = 0) then
    FSearchStarted := NowMilliseconds;
  FDeadline := NowMilliseconds + Delay;
  ChangeState(DhcpInit);
end;

procedure TDhcpClient.EnterInitReboot;
begin
  if not FHasLease and (FSearchStarted = 0) then
    FSearchStarted := NowMilliseconds;
  FDeadline := NowMilliseconds + RandomBelow(StartJitterMilliseconds);
  ChangeState(DhcpInitReboot);
end;

procedure TDhcpClient.Start(HasPreviousAddress: Boolean; constref PreviousAddress: TInternetAddress);
begin
  FHasPreviousAddress := HasPreviousAddress;
  FPreviousAddress := PreviousAddress;
  FSearchStarted := NowMilliseconds;
  OpenSocket;
  if FHasPreviousAddress then
    EnterInitReboot
  else
    EnterInit(RandomBelow(StartJitterMilliseconds));
end;

procedure TDhcpClient.LinkChanged(LinkIsUp: Boolean);
begin
  if FState = DhcpStopped then
    Exit;
  if not LinkIsUp then
  begin
    if FState = DhcpPaused then
      Exit;
    Say('link lost: waiting for it');
    { The lease is kept until it runs out. }
    if FHasLease then
      FDeadline := ExpiryTime(FLease)
    else
      FDeadline := NoDeadline;
    ChangeState(DhcpPaused);
    Exit;
  end;
  if FState <> DhcpPaused then
    Exit;
  Say('link back');
  FSearchStarted := 0;
  if FHasLease then
  begin
    { Confirm the lease on what may be another network (RFC 2131 3.2). }
    FHasPreviousAddress := True;
    FPreviousAddress := FLease.Address;
  end;
  if FHasPreviousAddress then
    EnterInitReboot
  else
    EnterInit(RandomBelow(StartJitterMilliseconds));
end;

procedure TDhcpClient.Release;
var
  Parameters: TDhcpRequestParameters;
begin
  if FHasLease then
  begin
    FTransactionId := RandomLongWord;
    FRoundStarted := NowMilliseconds;
    Parameters := BaseParameters(DhcpRelease);
    Parameters.ClientAddress := FLease.Address;
    Parameters.HasServerIdentifier := True;
    Parameters.ServerIdentifier := FLease.Server;
    Say('DHCPRELEASE of ' + AddressToText(FLease.Address) + ' to ' + AddressToText(FLease.Server));
    Send(Parameters, FLease.Server);
    LoseLease('released');
  end;
  CloseClientSocket;
  FDeadline := NoDeadline;
  ChangeState(DhcpStopped);
end;

procedure TDhcpClient.BeginProbe(constref Reply: TDhcpReply);
begin
  FCandidate := LeaseFromReply(Reply, NowMilliseconds, WallClockNow);
  { The address we have already needs no check. }
  if FHasLease and AddressesAreEqual(FLease.Address, FCandidate.Address) then
  begin
    Bind(FCandidate);
    Exit;
  end;
  SendAddressProbe(FSocket, FCandidate.Address);
  FDeadline := NowMilliseconds + ProbeWaitMilliseconds;
  ChangeState(DhcpProbing);
end;

procedure TDhcpClient.Bind(constref Lease: TDhcpLease);
var
  Previous: TDhcpLease;
  HadLease: Boolean;
begin
  HadLease := FHasLease;
  Previous := FLease;
  FLease := Lease;
  FHasLease := True;
  FHasPreviousAddress := True;
  FPreviousAddress := Lease.Address;
  FSearchStarted := 0;
  if Lease.LeaseSeconds = InfiniteLease then
    Say('bound to ' + LeaseAddressText(Lease) + ' by ' + AddressToText(Lease.Server) + ', for ever')
  else
    Say('bound to ' + LeaseAddressText(Lease) + ' by ' + AddressToText(Lease.Server) + ', lease ' +
      IntToStr(Lease.LeaseSeconds) + ' s');
  FDeadline := RenewalTime(FLease);
  { The owner applies the lease before anyone can read "configured" in
    the state file. Every acknowledgment is passed on (a renewal changes
    when the lease was obtained); the owner changes only what differs. }
  if Assigned(FOnLeaseObtained) then
    FOnLeaseObtained(Self);
  ChangeState(DhcpBound);
  if HadLease and not SameLeaseConfiguration(Previous, Lease) then
    Say('the lease changed');
end;

procedure TDhcpClient.LoseLease(const Why: string);
begin
  if not FHasLease then
    Exit;
  Say('lease of ' + AddressToText(FLease.Address) + ' ' + Why);
  FHasLease := False;
  if Assigned(FOnLeaseLost) then
    FOnLeaseLost(Self);
end;

procedure TDhcpClient.HandleReply(constref Reply: TDhcpReply);
begin
  if Reply.TransactionId <> FTransactionId then
    Exit;
  case FState of
    DhcpSelecting:
      if (Reply.Kind = DhcpOffer) and not AddressIsUnspecified(Reply.YourAddress) then
      begin
        Say('DHCPOFFER of ' + AddressToText(Reply.YourAddress) + ' from ' + AddressToText(Reply.ServerIdentifier));
        FOffer := Reply;
        FRetransmitInterval := FirstRetransmitMilliseconds;
        FTransmissions := 1;
        SendSelectingRequest;
        ScheduleRetransmission;
        ChangeState(DhcpRequesting);
      end;
    DhcpRequesting, DhcpRebooting, DhcpRenewing, DhcpRebinding:
      if Reply.Kind = DhcpAcknowledge then
      begin
        Say('DHCPACK of ' + AddressToText(Reply.YourAddress) + ' from ' + AddressToText(Reply.ServerIdentifier));
        if AddressIsUnspecified(Reply.YourAddress) then
          Exit;
        BeginProbe(Reply);
      end
      else if Reply.Kind = DhcpNegativeAcknowledge then
      begin
        Say('DHCPNAK from ' + AddressToText(Reply.ServerIdentifier));
        LoseLease('refused by the server');
        FHasPreviousAddress := False;
        EnterInit(NakWaitMilliseconds);
      end;
  end;
end;

procedure TDhcpClient.HandleReadable;
var
  Buffer: array[0..ReceiveBufferBytes - 1] of Byte;
  Received: Int64;
  Reply: TDhcpReply;
begin
  if FSocket < 0 then
    Exit;
  repeat
    Received := ReceiveOnSocket(FSocket, @Buffer[0], SizeOf(Buffer), SocketFlagDontWait);
    if Received <= 0 then
      Exit;
    if (FState <> DhcpStopped) and (FState <> DhcpPaused) and
       ParseDhcpReply(@Buffer[0], LongWord(Received), FHardwareAddress, Reply) then
      HandleReply(Reply);
  until FSocket < 0;
end;

procedure TDhcpClient.HandleDeadline(Now: QWord);
begin
  if Now < FDeadline then
    Exit;
  case FState of
    DhcpStopped:
      FDeadline := NoDeadline;
    DhcpPaused:
      begin
        LoseLease('ran out while the link was down');
        FDeadline := NoDeadline;
      end;
    DhcpInit, DhcpDeclined:
      begin
        if not OpenSocket then
        begin
          FDeadline := Now + SocketRetryMilliseconds;
          Exit;
        end;
        BeginRound;
        SendDiscover;
        ScheduleRetransmission;
        ChangeState(DhcpSelecting);
      end;
    DhcpSelecting:
      begin
        Inc(FTransmissions);
        SendDiscover;
        ScheduleRetransmission;
      end;
    DhcpRequesting:
      if FTransmissions >= RequestTransmissions then
      begin
        Say('no answer to DHCPREQUEST: starting again');
        EnterInit(0);
      end
      else
      begin
        Inc(FTransmissions);
        SendSelectingRequest;
        ScheduleRetransmission;
      end;
    DhcpInitReboot:
      begin
        if not OpenSocket then
        begin
          FDeadline := Now + SocketRetryMilliseconds;
          Exit;
        end;
        BeginRound;
        SendRebootRequest;
        ScheduleRetransmission;
        ChangeState(DhcpRebooting);
      end;
    DhcpRebooting:
      if FTransmissions >= RebootTransmissions then
      begin
        Say('no answer about the previous lease: asking for a new one');
        LoseLease('not confirmed');
        EnterInit(0);
      end
      else
      begin
        Inc(FTransmissions);
        SendRebootRequest;
        ScheduleRetransmission;
      end;
    DhcpProbing:
      if AddressAnswered(FInterfaceName, FCandidate.Address) then
      begin
        SendDecline;
        LoseLease('declined');
        FHasPreviousAddress := False;
        FDeadline := Now + DeclineWaitMilliseconds;
        ChangeState(DhcpDeclined);
      end
      else
        Bind(FCandidate);
    DhcpBound:
      begin
        BeginRound;
        SendRenewalRequest(False);
        ScheduleLeaseRetransmission(RebindingTime(FLease));
        ChangeState(DhcpRenewing);
      end;
    DhcpRenewing:
      if Now >= RebindingTime(FLease) then
      begin
        SendRenewalRequest(True);
        ScheduleLeaseRetransmission(ExpiryTime(FLease));
        ChangeState(DhcpRebinding);
      end
      else
      begin
        SendRenewalRequest(False);
        ScheduleLeaseRetransmission(RebindingTime(FLease));
      end;
    DhcpRebinding:
      if Now >= ExpiryTime(FLease) then
      begin
        LoseLease('ran out');
        FHasPreviousAddress := False;
        EnterInit(0);
      end
      else
      begin
        SendRenewalRequest(True);
        ScheduleLeaseRetransmission(ExpiryTime(FLease));
      end;
  end;
end;

function TDhcpClient.NextDeadline: QWord;
begin
  Result := FDeadline;
end;

function TDhcpClient.StateName: string;
begin
  case FState of
    DhcpStopped: Result := 'down';
    DhcpPaused: Result := 'no-link';
    DhcpBound, DhcpRenewing, DhcpRebinding: Result := 'configured';
  else
    if FHasLease then
      Result := 'configured'
    else if (FSearchStarted <> 0) and (NowMilliseconds - FSearchStarted >= FailedAfterMilliseconds) then
      Result := 'failed'
    else
      Result := 'configuring';
  end;
end;

end.
