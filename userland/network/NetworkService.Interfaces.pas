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
  The interfaces the network service looks after: for each adapter
  (every interface but lo) what its settings ask for, what was applied,
  its DHCP client, and its state file.

  Whenever the settings or the kernel's interfaces change, each
  interface is brought in line (Reconcile): if its settings changed,
  what was applied is undone first - a DHCP lease is given back
  (DHCPRELEASE), an address the service set is removed with its routes
  - and the new settings are applied:
    static  the address, the interface turned on (or off), the default
            route through the gateway;
    dhcp    the interface turned on and a DHCP client started (it waits
            for the link); Up = false gives the lease back and turns the
            interface off;
    none    nothing: the interface is left as it is (an address set by
            hand stays); only Up = false turns it off. An address the
            service itself had set (static, or a lease) is removed when
            the method becomes none.
  A link that comes or goes is passed to the DHCP client (which confirms
  its lease when the link comes back); an adapter that appears later is
  taken in like the others.

  The DNS servers given to the kernel are the settings' DnsServers if
  that list is not empty, else those of every DHCP lease (each once);
  the search domain is the settings' SearchDomain, else the first
  lease's domain. They are set only when they change.
}
unit NetworkService.Interfaces;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.InternetAddresses,
  NetworkService.Settings,
  NetworkService.DhcpMessages,
  NetworkService.DhcpLeases,
  NetworkService.DhcpClient;

type
  TManagedInterface = class
  public
    Name: string;
    Index: LongWord;
    HardwareAddress: TEthernetAddress;
    { As the kernel last said. }
    IsUp: Boolean;
    LinkIsUp: Boolean;
    KernelHasAddress: Boolean;
    KernelAddress: TInternetAddress;
    KernelPrefixLength: LongWord;
    { What the settings ask for, and what was applied. }
    Desired: TInterfaceSettings;
    Applied: TInterfaceSettings;
    HasApplied: Boolean;
    { The service set an address on it (static, or a lease). }
    AddressIsOurs: Boolean;
    { Why applying failed ('' if it did not). }
    Failure: string;
    Dhcp: TDhcpClient;
    { A lease's address to ask for again (an earlier run's, from the
      state file, or this run's). }
    HasPreviousAddress: Boolean;
    PreviousAddress: TInternetAddress;
    destructor Destroy; override;
  end;

  TInterfaceManager = class
  private
    FInterfaces: array of TManagedInterface;
    FSettings: TNetworkSettings;
    FHasAppliedDns: Boolean;
    FAppliedDns: TAbiDnsServers;
    function Find(const Name: string): TManagedInterface;
    procedure Reconcile(Managed: TManagedInterface);
    procedure TearDown(Managed: TManagedInterface);
    procedure SetUp(Managed: TManagedInterface);
    procedure ApplyStatic(Managed: TManagedInterface);
    procedure StartDhcp(Managed: TManagedInterface);
    procedure RemoveOurAddress(Managed: TManagedInterface);
    procedure EnsureDefaultRoute(Managed: TManagedInterface; constref Gateway: TInternetAddress);
    procedure WriteState(Managed: TManagedInterface);
    procedure ApplyNameServers;
    function FindByClient(Client: TDhcpClient): TManagedInterface;
    procedure LeaseObtained(Client: TDhcpClient);
    procedure LeaseLost(Client: TDhcpClient);
    procedure DhcpStateChanged(Client: TDhcpClient);
  public
    destructor Destroy; override;
    { New settings (read again after the file changed). }
    procedure ApplySettings(constref Settings: TNetworkSettings);
    { The kernel's interfaces changed (or might have): adapters that
      appeared, links, on and off. }
    procedure RefreshInterfaces;
    { The DHCP clients' sockets, to wait on. }
    procedure CollectSockets(var Handles: array of Int64; var Count: Integer);
    procedure HandleReadable(Socket: Int64);
    procedure HandleDeadlines;
    { Uptime milliseconds of the earliest deadline (NoDeadline: none). }
    function NextDeadline: QWord;
    { The service stops: leases are given back. }
    procedure StopAll;
  end;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Sys.Kernel,
  Sys.NetworkInterfaces,
  NetworkService.Log,
  NetworkService.StateFiles;

const
  LoopbackIndex = 1;

destructor TManagedInterface.Destroy;
begin
  Dhcp.Free;
  inherited Destroy;
end;

destructor TInterfaceManager.Destroy;
var
  Position: Integer;
begin
  for Position := 0 to High(FInterfaces) do
    FInterfaces[Position].Free;
  inherited Destroy;
end;

function TInterfaceManager.Find(const Name: string): TManagedInterface;
var
  Position: Integer;
begin
  for Position := 0 to High(FInterfaces) do
    if FInterfaces[Position].Name = Name then
      Exit(FInterfaces[Position]);
  Result := nil;
end;

function TInterfaceManager.FindByClient(Client: TDhcpClient): TManagedInterface;
var
  Position: Integer;
begin
  for Position := 0 to High(FInterfaces) do
    if FInterfaces[Position].Dhcp = Client then
      Exit(FInterfaces[Position]);
  Result := nil;
end;

function MetricOf(Managed: TManagedInterface): LongWord;
begin
  { eth0 (index 2) gets 0, the next 1, ... }
  if Managed.Index > LoopbackIndex + 1 then
    Result := Managed.Index - LoopbackIndex - 1
  else
    Result := 0;
end;

procedure TInterfaceManager.RemoveOurAddress(Managed: TManagedInterface);
var
  Error: LongInt;
begin
  if not Managed.AddressIsOurs then
    Exit;
  Managed.AddressIsOurs := False;
  Error := RemoveInterfaceAddress(PChar(Managed.Name));
  if Error <> ErrorNone then
    Say(Managed.Name + ': removing the address: ' + ErrorText(Error))
  else
    Say(Managed.Name + ': address removed');
  Managed.KernelHasAddress := False;
end;

procedure TInterfaceManager.EnsureDefaultRoute(Managed: TManagedInterface; constref Gateway: TInternetAddress);
var
  Routes: TRouteList;
  Position: Integer;
  Error: LongInt;
begin
  if ListRoutes(Routes) = ErrorNone then
    for Position := 0 to High(Routes) do
      if (Routes[Position].Destination.PrefixLength = 0) and
         MemoryIsEqual(@Routes[Position].Gateway[0], @Gateway.Bytes[0], 4) and
         TextIsEqual(@Routes[Position].InterfaceName[0], PChar(Managed.Name)) then
        Exit;
  Error := AddRoute(AnyIpv4Address, 0, Gateway, PChar(Managed.Name), MetricOf(Managed));
  if Error <> ErrorNone then
    Say(Managed.Name + ': default route through ' + AddressText(Gateway) + ': ' + ErrorText(Error))
  else
    Say(Managed.Name + ': default route through ' + AddressText(Gateway));
end;

procedure TInterfaceManager.ApplyStatic(Managed: TManagedInterface);
var
  Error: LongInt;
begin
  if Managed.Desired.HasAddress then
  begin
    Error := SetInterfaceAddress(PChar(Managed.Name), Managed.Desired.Address, Managed.Desired.PrefixLength);
    if Error <> ErrorNone then
    begin
      Managed.Failure := 'address ' + AddressText(Managed.Desired.Address) + ': ' + ErrorText(Error);
      Say(Managed.Name + ': ' + Managed.Failure);
      Exit;
    end;
    Managed.AddressIsOurs := True;
    Say(Managed.Name + ': address ' + AddressText(Managed.Desired.Address) + '/' +
      IntToStr(Managed.Desired.PrefixLength));
  end;
  Error := SetInterfaceUp(PChar(Managed.Name), Managed.Desired.Up);
  if Error <> ErrorNone then
    Say(Managed.Name + ': ' + ErrorText(Error));
  if Managed.Desired.HasGateway then
    EnsureDefaultRoute(Managed, Managed.Desired.Gateway);
end;

procedure TInterfaceManager.StartDhcp(Managed: TManagedInterface);
var
  Error: LongInt;
begin
  Error := SetInterfaceUp(PChar(Managed.Name), True);
  if Error <> ErrorNone then
  begin
    Managed.Failure := ErrorText(Error);
    Say(Managed.Name + ': ' + Managed.Failure);
    Exit;
  end;
  Managed.IsUp := True;
  Managed.Dhcp := TDhcpClient.Create(Managed.Name, Managed.Index, Managed.HardwareAddress);
  Managed.Dhcp.OnLeaseObtained := @LeaseObtained;
  Managed.Dhcp.OnLeaseLost := @LeaseLost;
  Managed.Dhcp.OnStateChanged := @DhcpStateChanged;
  Say(Managed.Name + ': DHCP');
  Managed.Dhcp.Start(Managed.HasPreviousAddress, Managed.PreviousAddress);
  if not Managed.LinkIsUp then
    Managed.Dhcp.LinkChanged(False);
end;

procedure TInterfaceManager.TearDown(Managed: TManagedInterface);
begin
  if not Managed.HasApplied then
    Exit;
  if Managed.Dhcp <> nil then
  begin
    Managed.Dhcp.Release;
    FreeAndNil(Managed.Dhcp);
  end;
  RemoveOurAddress(Managed);
  Managed.Failure := '';
end;

procedure TInterfaceManager.SetUp(Managed: TManagedInterface);
begin
  Managed.Failure := '';
  if Managed.Desired.Problem <> '' then
  begin
    Managed.Failure := Managed.Desired.Problem;
    Say(Managed.Name + ': ' + Managed.Failure + ': not configured');
    Exit;
  end;
  case Managed.Desired.Method of
    MethodStatic: ApplyStatic(Managed);
    MethodDhcp:
      if Managed.Desired.Up then
        StartDhcp(Managed)
      else
        SetInterfaceUp(PChar(Managed.Name), False);
  else
    if not Managed.Desired.Up then
      SetInterfaceUp(PChar(Managed.Name), False)
    else if Managed.HasApplied then
      Say(Managed.Name + ': left alone (Method = none)');
  end;
end;

procedure TInterfaceManager.Reconcile(Managed: TManagedInterface);
begin
  Managed.Desired := InterfaceSettingsOf(FSettings, Managed.Name);
  if not Managed.HasApplied or not SameInterfaceSettings(Managed.Desired, Managed.Applied) then
  begin
    TearDown(Managed);
    SetUp(Managed);
    Managed.Applied := Managed.Desired;
    Managed.HasApplied := True;
    ApplyNameServers;
  end;
  WriteState(Managed);
end;

procedure TInterfaceManager.ApplySettings(constref Settings: TNetworkSettings);
var
  Position: Integer;
begin
  FSettings := Settings;
  for Position := 0 to High(Settings.Problems) do
    Say(Settings.Problems[Position]);
  for Position := 0 to High(FInterfaces) do
    Reconcile(FInterfaces[Position]);
  ApplyNameServers;
end;

{ The address of a state file ("10.0.2.15/24") without its prefix. }
function ParsePreviousAddress(const Text: string; out Address: TInternetAddress): Boolean;
var
  PrefixLength: LongWord;
  HasPrefix: Boolean;
begin
  Result := (Text <> '') and ParseAddressWithPrefix(PChar(Text), Address, PrefixLength, HasPrefix);
end;

procedure TInterfaceManager.RefreshInterfaces;
var
  Interfaces: TNetworkInterfaceList;
  Position: Integer;
  Managed: TManagedInterface;
  Previous: TInterfaceState;
  LinkWasUsable: Boolean;
  LinkIsUsable: Boolean;
  Name: string;
begin
  if ListNetworkInterfaces(Interfaces) <> ErrorNone then
    Exit;
  for Position := 0 to High(Interfaces) do
  begin
    if (Interfaces[Position].Flags and InterfaceFlagLoopback) <> 0 then
      Continue;
    Name := string(PChar(@Interfaces[Position].Name[0]));
    Managed := Find(Name);
    if Managed = nil then
    begin
      Managed := TManagedInterface.Create;
      Managed.Name := Name;
      Managed.Index := Interfaces[Position].Index;
      CopyMemory(@Managed.HardwareAddress[0], @Interfaces[Position].HardwareAddress[0], 6);
      if ReadPreviousInterfaceState(Name, Previous) and (Previous.Method = 'dhcp') then
        Managed.HasPreviousAddress := ParsePreviousAddress(Previous.Address, Managed.PreviousAddress);
      SetLength(FInterfaces, Length(FInterfaces) + 1);
      FInterfaces[High(FInterfaces)] := Managed;
      Say(Name + ': found (' + string(PChar(@Interfaces[Position].Description[0])) + ')');
    end;
    LinkWasUsable := Managed.IsUp and Managed.LinkIsUp;
    Managed.IsUp := (Interfaces[Position].Flags and InterfaceFlagUp) <> 0;
    Managed.LinkIsUp := (Interfaces[Position].Flags and InterfaceFlagRunning) <> 0;
    Managed.KernelHasAddress := Interfaces[Position].AddressCount > 0;
    if Managed.KernelHasAddress then
    begin
      Managed.KernelAddress := InterfaceAddressHost(Interfaces[Position].Addresses[0]);
      Managed.KernelPrefixLength := Interfaces[Position].Addresses[0].PrefixLength;
    end;
    LinkIsUsable := Managed.IsUp and Managed.LinkIsUp;
    if not Managed.HasApplied then
      Reconcile(Managed)
    else
    begin
      if (Managed.Dhcp <> nil) and (LinkIsUsable <> LinkWasUsable) then
        Managed.Dhcp.LinkChanged(LinkIsUsable);
      WriteState(Managed);
    end;
  end;
end;

procedure TInterfaceManager.CollectSockets(var Handles: array of Int64; var Count: Integer);
var
  Position: Integer;
begin
  for Position := 0 to High(FInterfaces) do
    if (FInterfaces[Position].Dhcp <> nil) and (FInterfaces[Position].Dhcp.Socket >= 0) and
       (Count <= High(Handles)) then
    begin
      Handles[Count] := FInterfaces[Position].Dhcp.Socket;
      Inc(Count);
    end;
end;

procedure TInterfaceManager.HandleReadable(Socket: Int64);
var
  Position: Integer;
begin
  for Position := 0 to High(FInterfaces) do
    if (FInterfaces[Position].Dhcp <> nil) and (FInterfaces[Position].Dhcp.Socket = Socket) then
      FInterfaces[Position].Dhcp.HandleReadable;
end;

procedure TInterfaceManager.HandleDeadlines;
var
  Position: Integer;
  Now: QWord;
begin
  Now := QWord(KernelGetTime(TimeUptimeMilliseconds));
  for Position := 0 to High(FInterfaces) do
  begin
    if FInterfaces[Position].Dhcp <> nil then
      FInterfaces[Position].Dhcp.HandleDeadline(Now);
    { "failed" comes with time alone. }
    WriteState(FInterfaces[Position]);
  end;
end;

function TInterfaceManager.NextDeadline: QWord;
var
  Position: Integer;
begin
  Result := NoDeadline;
  for Position := 0 to High(FInterfaces) do
    if (FInterfaces[Position].Dhcp <> nil) and (FInterfaces[Position].Dhcp.NextDeadline < Result) then
      Result := FInterfaces[Position].Dhcp.NextDeadline;
end;

procedure TInterfaceManager.StopAll;
var
  Position: Integer;
  Managed: TManagedInterface;
begin
  for Position := 0 to High(FInterfaces) do
  begin
    Managed := FInterfaces[Position];
    if Managed.Dhcp <> nil then
    begin
      Managed.Dhcp.Release;
      FreeAndNil(Managed.Dhcp);
    end;
    WriteState(Managed);
  end;
  ApplyNameServers;
end;

{ --- Leases -------------------------------------------------------------- }

procedure TInterfaceManager.LeaseObtained(Client: TDhcpClient);
var
  Managed: TManagedInterface;
  Lease: TDhcpLease;
  Error: LongInt;
begin
  Managed := FindByClient(Client);
  if Managed = nil then
    Exit;
  Lease := Client.Lease;
  if not Managed.KernelHasAddress or not AddressesAreEqual(Managed.KernelAddress, Lease.Address) or
     (Managed.KernelPrefixLength <> Lease.PrefixLength) then
  begin
    Error := SetInterfaceAddress(PChar(Managed.Name), Lease.Address, Lease.PrefixLength);
    if Error <> ErrorNone then
    begin
      Managed.Failure := 'address ' + LeaseAddressText(Lease) + ': ' + ErrorText(Error);
      Say(Managed.Name + ': ' + Managed.Failure);
      WriteState(Managed);
      Exit;
    end;
    Managed.KernelHasAddress := True;
    Managed.KernelAddress := Lease.Address;
    Managed.KernelPrefixLength := Lease.PrefixLength;
  end;
  Managed.Failure := '';
  Managed.AddressIsOurs := True;
  Managed.HasPreviousAddress := True;
  Managed.PreviousAddress := Lease.Address;
  if Lease.HasGateway then
    EnsureDefaultRoute(Managed, Lease.Gateway);
  ApplyNameServers;
  WriteState(Managed);
end;

procedure TInterfaceManager.LeaseLost(Client: TDhcpClient);
var
  Managed: TManagedInterface;
begin
  Managed := FindByClient(Client);
  if Managed = nil then
    Exit;
  RemoveOurAddress(Managed);
  ApplyNameServers;
  WriteState(Managed);
end;

procedure TInterfaceManager.DhcpStateChanged(Client: TDhcpClient);
var
  Managed: TManagedInterface;
begin
  Managed := FindByClient(Client);
  if Managed <> nil then
    WriteState(Managed);
end;

{ --- DNS servers and state files ------------------------------------------ }

procedure AddServer(var Servers: TAbiDnsServers; constref Address: TInternetAddress);
var
  Position: LongWord;
begin
  Position := 0;
  while Position < Servers.Count do
  begin
    if MemoryIsEqual(@Servers.Servers[Position].Address[0], @Address.Bytes[0], 4) then
      Exit;
    Inc(Position);
  end;
  if Servers.Count >= MaximumDnsServers then
    Exit;
  Servers.Servers[Servers.Count] := MakeSocketAddress(Address, 53);
  Inc(Servers.Count);
end;

procedure TInterfaceManager.ApplyNameServers;
var
  Servers: TAbiDnsServers;
  Position: Integer;
  ServerIndex: Integer;
  Domain: string;
  Lease: TDhcpLease;
  Error: LongInt;
  Listed: string;
begin
  FillMemory(@Servers, SizeOf(Servers), 0);
  Domain := FSettings.SearchDomain;
  if Length(FSettings.DnsServers) > 0 then
    for Position := 0 to High(FSettings.DnsServers) do
      AddServer(Servers, FSettings.DnsServers[Position]);
  for Position := 0 to High(FInterfaces) do
    if (FInterfaces[Position].Dhcp <> nil) and FInterfaces[Position].Dhcp.HasLease then
    begin
      Lease := FInterfaces[Position].Dhcp.Lease;
      if Length(FSettings.DnsServers) = 0 then
        for ServerIndex := 0 to High(Lease.DnsServers) do
          AddServer(Servers, Lease.DnsServers[ServerIndex]);
      if Domain = '' then
        Domain := Lease.DomainName;
    end;
  if Length(Domain) >= DnsDomainCapacity then
    Domain := Copy(Domain, 1, DnsDomainCapacity - 1);
  if Domain <> '' then
    Move(Domain[1], Servers.SearchDomain[0], Length(Domain));
  if FHasAppliedDns and MemoryIsEqual(@Servers, @FAppliedDns, SizeOf(Servers)) then
    Exit;
  Error := SetDnsServers(Servers);
  if Error <> ErrorNone then
  begin
    Say('DNS servers: ' + ErrorText(Error));
    Exit;
  end;
  FAppliedDns := Servers;
  FHasAppliedDns := True;
  Listed := '';
  for Position := 0 to Integer(Servers.Count) - 1 do
  begin
    if Listed <> '' then
      Listed := Listed + ', ';
    Listed := Listed + AddressText(SocketAddressHost(Servers.Servers[Position]));
  end;
  if Listed = '' then
    Listed := 'none';
  if Domain <> '' then
    Listed := Listed + ' (search domain ' + Domain + ')';
  Say('DNS servers: ' + Listed);
end;

function AddressList(const Addresses: array of TInternetAddress): TStringArray;
var
  Position: Integer;
begin
  Result := nil;
  SetLength(Result, Length(Addresses));
  for Position := 0 to High(Addresses) do
    Result[Position] := AddressText(Addresses[Position]);
end;

procedure TInterfaceManager.WriteState(Managed: TManagedInterface);
var
  State: TInterfaceState;
  Lease: TDhcpLease;
begin
  State := EmptyInterfaceState;
  State.Method := AddressMethodName(Managed.Desired.Method);
  if not Managed.IsUp then
    State.State := 'down'
  else if not Managed.LinkIsUp then
    State.State := 'no-link'
  else if Managed.Failure <> '' then
    State.State := 'failed'
  else
    case Managed.Desired.Method of
      MethodStatic: State.State := 'configured';
      MethodDhcp:
        if Managed.Dhcp <> nil then
          State.State := Managed.Dhcp.StateName
        else
          State.State := 'down';
    else
      if Managed.KernelHasAddress then
        State.State := 'configured'
      else
        State.State := 'down';
    end;
  if (Managed.Failure <> '') and Managed.IsUp then
    State.State := 'failed';
  case Managed.Desired.Method of
    MethodStatic:
      if Managed.Failure = '' then
      begin
        if Managed.Desired.HasAddress then
          State.Address := AddressText(Managed.Desired.Address) + '/' + IntToStr(Managed.Desired.PrefixLength);
        if Managed.Desired.HasGateway then
          State.Gateway := AddressText(Managed.Desired.Gateway);
        State.DnsServers := AddressList(FSettings.DnsServers);
        State.Domain := FSettings.SearchDomain;
      end;
    MethodDhcp:
      if (Managed.Dhcp <> nil) and Managed.Dhcp.HasLease then
      begin
        Lease := Managed.Dhcp.Lease;
        State.Address := LeaseAddressText(Lease);
        if Lease.HasGateway then
          State.Gateway := AddressText(Lease.Gateway);
        State.DnsServers := AddressList(Lease.DnsServers);
        State.Domain := Lease.DomainName;
        if Lease.LeaseSeconds = InfiniteLease then
          State.LeaseSeconds := 0
        else
          State.LeaseSeconds := Lease.LeaseSeconds;
        State.LeaseObtained := Lease.ObtainedWallClock;
        State.DhcpServer := AddressText(Lease.Server);
      end;
  else
    if Managed.KernelHasAddress then
      State.Address := AddressText(Managed.KernelAddress) + '/' + IntToStr(Managed.KernelPrefixLength);
  end;
  WriteInterfaceState(Managed.Name, State);
end;

end.
