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
  IPv6 on an interface over its life: started when the interface is up
  with its link and its mode is not off, stopped when either goes.

  Starting makes the link-local address (fe80:: and the interface's
  identifier, stable-privacy or EUI-64: Network.Ipv6Identifiers; lo
  gets ::1), runs duplicate
  address detection on it and on the manual addresses (RFC 4862 5.4:
  one solicitation from ::, then a second's wait; an answer, or another
  host testing the same address, removes it as a duplicate), reports
  the groups by MLD, and in Ipv6ModeAutomatic solicits routers once the
  link-local address is ready. Stopping drops the link-local and
  automatic addresses, what routers gave (routes, DNS servers, hop
  limit, MTU) and the neighbour cache; manual addresses stay and are
  tested again at the next start.

  The timers, on the network thread, move detection on and end
  addresses whose lifetimes ran out (preferred: deprecated; valid:
  removed), make temporary addresses' successors, and send router
  solicitations and MLD reports when due.

  A stable-privacy address another host has is made again with the next
  DAD counter (RFC 7217 6, three times at most); a temporary one is
  replaced by a new random one. Changing the identifiers (the option,
  or the secret) starts IPv6 on the interface again.
}
unit Network.Ipv6Interfaces;

{$mode objfpc}

interface

uses
  Network.Ipv6Types,
  Network.Interfaces;

{ Sets an interface's IPv6 state up when it is made (lo: link-local
  mode, Ethernet: automatic). }
procedure InitializeIpv6Interface(NetworkInterface: PNetworkInterface);
{ The interface went up or down, or its link came or went: IPv6 is
  started or stopped to match. }
procedure Ipv6InterfaceChanged(NetworkInterface: PNetworkInterface);
{ Ipv6ModeOff, Ipv6ModeLinkLocal or Ipv6ModeAutomatic;
  ErrorInvalidArgument for another value. }
function SetIpv6Mode(NetworkInterface: PNetworkInterface; Mode: LongWord): LongInt;
{ Another host uses the address Entry is testing: it goes. }
procedure Ipv6DuplicateAddress(NetworkInterface: PNetworkInterface; Entry: PIpv6InterfaceAddress);
{ Ipv6Option* (ErrorInvalidArgument for unknown bits, or options on lo). }
function SetIpv6Options(NetworkInterface: PNetworkInterface; Options: LongWord): LongInt;
{ A new secret for stable-privacy identifiers (StableSecretBytes): the
  interfaces that use them start IPv6 again if it changed. }
procedure SetIpv6StableSecret(Secret: PByte);
{ On the network thread: every interface's IPv6 timers, and the IPv6
  routes' lifetimes. }
procedure RunIpv6InterfaceTimers(Now: QWord);

implementation

uses
  Abi.SystemCalls,
  Network.Core,
  Network.Ipv6Addresses,
  Network.Ipv6AddressList,
  Network.Ipv6Identifiers,
  Network.InterfaceIdentifiers,
  Network.TemporaryAddresses,
  Network.Ipv6Routing,
  Network.Ipv6DestinationCache,
  Network.NeighborCache,
  Network.NeighborMessages,
  Network.RouterDiscovery,
  Network.Mld,
  Network.ChangeWatchers,
  Debug.Output;

const
  DefaultReachableMilliseconds = 30000;
  DefaultRetransmitMilliseconds = 1000;
  DuplicateDetectionProbes = 1;
  NanosecondsPerMillisecond = 1000 * 1000;

procedure ResetRouterInformation(NetworkInterface: PNetworkInterface);
begin
  NetworkInterface^.Ipv6.HopLimit := DefaultIpv6HopLimit;
  NetworkInterface^.Ipv6.Mtu := 0;
  NetworkInterface^.Ipv6.ReachableMilliseconds := DefaultReachableMilliseconds;
  NetworkInterface^.Ipv6.RetransmitMilliseconds := DefaultRetransmitMilliseconds;
  ForgetRouterDnsServers(NetworkInterface);
end;

procedure InitializeIpv6Interface(NetworkInterface: PNetworkInterface);
begin
  if NetworkInterface^.IsLoopback then
  begin
    NetworkInterface^.Ipv6.Mode := Ipv6ModeLinkLocal;
    NetworkInterface^.Ipv6.Options := 0;
  end
  else
  begin
    NetworkInterface^.Ipv6.Mode := Ipv6ModeAutomatic;
    NetworkInterface^.Ipv6.Options := Ipv6OptionTemporaryAddresses;
  end;
  ResetRouterInformation(NetworkInterface);
end;

procedure WriteModeChange(NetworkInterface: PNetworkInterface);
begin
  DebugBeginMessage;
  DebugWriteTag('network');
  DebugWrite(@NetworkInterface^.Name[0]);
  case NetworkInterface^.Ipv6.Mode of
    Ipv6ModeOff: DebugWriteLine(': IPv6 off');
    Ipv6ModeLinkLocal: DebugWriteLine(': IPv6 link-local only');
  else
    DebugWriteLine(': IPv6 automatic');
  end;
  DebugEndMessage;
end;

{ Every manual address is tested again. }
procedure RetestManualAddresses(NetworkInterface: PNetworkInterface);
var
  Index: Integer;
  Entry: PIpv6InterfaceAddress;
begin
  for Index := 0 to MaximumIpv6InterfaceAddresses - 1 do
  begin
    Entry := @NetworkInterface^.Ipv6.Addresses[Index];
    if (Entry^.State = Ipv6AddressFree) or (Entry^.Origin <> Ipv6OriginManual) then
      Continue;
    Entry^.State := Ipv6AddressTentative;
    Entry^.DadProbesSent := 0;
    Entry^.DadDeadline := NetworkNow;
    RequestNetworkWakeAt(Entry^.DadDeadline);
  end;
end;

procedure StartIpv6(NetworkInterface: PNetworkInterface);
begin
  NetworkInterface^.Ipv6.IsStarted := True;
  if NetworkInterface^.IsLoopback then
  begin
    AddIpv6Address(NetworkInterface, LoopbackIpv6Address, LoopbackIpv6PrefixLength, Ipv6OriginLoopback,
      Ipv6Forever, Ipv6Forever);
    Exit;
  end;
  AddIpv6Address(NetworkInterface, LinkLocalAddressOf(NetworkInterface), LinkLocalPrefixLength,
    Ipv6OriginLinkLocal, Ipv6Forever, Ipv6Forever);
  RetestManualAddresses(NetworkInterface);
  ScheduleMldReports(NetworkInterface);
end;

{ Drops what came from routers. }
procedure ForgetRouters(NetworkInterface: PNetworkInterface);
begin
  StopRouterSolicitation(NetworkInterface);
  RemoveIpv6AddressesOf(NetworkInterface, [Ipv6OriginAutomatic, Ipv6OriginTemporary]);
  RemoveIpv6InterfaceRoutes(NetworkInterface, True);
  ResetRouterInformation(NetworkInterface);
end;

procedure StopIpv6(NetworkInterface: PNetworkInterface);
var
  Index: Integer;
  Entry: PIpv6InterfaceAddress;
begin
  NetworkInterface^.Ipv6.IsStarted := False;
  ForgetRouters(NetworkInterface);
  StopMldReports(NetworkInterface);
  RemoveIpv6AddressesOf(NetworkInterface, [Ipv6OriginLinkLocal, Ipv6OriginLoopback]);
  ForgetIpv6Neighbors(NetworkInterface);
  ForgetIpv6Destinations(NetworkInterface);
  for Index := 0 to MaximumIpv6InterfaceAddresses - 1 do
  begin
    Entry := @NetworkInterface^.Ipv6.Addresses[Index];
    if Entry^.State <> Ipv6AddressFree then
      Entry^.State := Ipv6AddressTentative;
  end;
end;

procedure Ipv6InterfaceChanged(NetworkInterface: PNetworkInterface);
var
  ShouldRun: Boolean;
begin
  ShouldRun := InterfaceIsUsable(NetworkInterface) and (NetworkInterface^.Ipv6.Mode <> Ipv6ModeOff);
  if ShouldRun and not NetworkInterface^.Ipv6.IsStarted then
    StartIpv6(NetworkInterface)
  else if not ShouldRun and NetworkInterface^.Ipv6.IsStarted then
    StopIpv6(NetworkInterface);
end;

function SetIpv6Mode(NetworkInterface: PNetworkInterface; Mode: LongWord): LongInt;
var
  Previous: LongWord;
  LinkLocal: TIpv6Address;
begin
  if not (Mode in [Ipv6ModeOff, Ipv6ModeLinkLocal, Ipv6ModeAutomatic]) then
    Exit(ErrorInvalidArgument);
  if NetworkInterface^.IsLoopback and (Mode = Ipv6ModeAutomatic) then
    Exit(ErrorInvalidArgument);
  Result := ErrorNone;
  Previous := NetworkInterface^.Ipv6.Mode;
  if Previous = Mode then
    Exit;
  NetworkInterface^.Ipv6.Mode := Mode;
  WriteModeChange(NetworkInterface);
  if Mode = Ipv6ModeOff then
  begin
    if NetworkInterface^.Ipv6.IsStarted then
      StopIpv6(NetworkInterface);
    RemoveIpv6AddressesOf(NetworkInterface, [Low(TIpv6AddressOrigin)..High(TIpv6AddressOrigin)]);
    RemoveIpv6InterfaceRoutes(NetworkInterface, False);
  end
  else if Previous = Ipv6ModeOff then
    Ipv6InterfaceChanged(NetworkInterface)
  else if Mode = Ipv6ModeLinkLocal then
    ForgetRouters(NetworkInterface)
  else if NetworkInterface^.Ipv6.IsStarted and FindLinkLocalAddress(NetworkInterface, LinkLocal) then
    StartRouterSolicitation(NetworkInterface);
  NoteNetworkChange;
end;

{ A stable-privacy address made again with the next DAD counter, with
  the lifetimes the duplicate had. }
procedure RemakeStableAddress(NetworkInterface: PNetworkInterface; constref Duplicate: TIpv6InterfaceAddress);
begin
  if NetworkInterface^.Ipv6.StableDadCounter >= StableIdentifierRetries then
    Exit;
  Inc(NetworkInterface^.Ipv6.StableDadCounter);
  if Duplicate.Origin = Ipv6OriginLinkLocal then
    AddIpv6Address(NetworkInterface, LinkLocalAddressOf(NetworkInterface), LinkLocalPrefixLength,
      Ipv6OriginLinkLocal, Ipv6Forever, Ipv6Forever)
  else
    AddIpv6Address(NetworkInterface, SlaacAddressOf(NetworkInterface, Duplicate.Address), Duplicate.PrefixLength,
      Ipv6OriginAutomatic, Duplicate.ValidUntil, Duplicate.PreferredUntil);
end;

procedure Ipv6DuplicateAddress(NetworkInterface: PNetworkInterface; Entry: PIpv6InterfaceAddress);
var
  Duplicate: TIpv6InterfaceAddress;
begin
  Duplicate := Entry^;
  RemoveIpv6AddressEntry(NetworkInterface, Entry, 'is used by another host: removed');
  case Duplicate.Origin of
    Ipv6OriginTemporary:
      ReplaceDuplicateTemporaryAddress(NetworkInterface, Duplicate.Address, NetworkNow);
    Ipv6OriginLinkLocal, Ipv6OriginAutomatic:
      if UsesStableIdentifiers(NetworkInterface) then
        RemakeStableAddress(NetworkInterface, Duplicate);
  end;
  ScheduleMldReports(NetworkInterface);
end;

{ IPv6 starts again on the interface (its identifiers changed). }
procedure RestartIpv6(NetworkInterface: PNetworkInterface);
begin
  if not NetworkInterface^.Ipv6.IsStarted then
    Exit;
  StopIpv6(NetworkInterface);
  Ipv6InterfaceChanged(NetworkInterface);
end;

function SetIpv6Options(NetworkInterface: PNetworkInterface; Options: LongWord): LongInt;
const
  KnownOptions = Ipv6OptionTemporaryAddresses or Ipv6OptionEui64Identifiers;
var
  Previous: LongWord;
begin
  if (Options and not KnownOptions) <> 0 then
    Exit(ErrorInvalidArgument);
  if NetworkInterface^.IsLoopback and (Options <> 0) then
    Exit(ErrorInvalidArgument);
  Result := ErrorNone;
  Previous := NetworkInterface^.Ipv6.Options;
  if Previous = Options then
    Exit;
  NetworkInterface^.Ipv6.Options := Options;
  DebugBeginMessage;
  DebugWriteTag('network');
  DebugWrite(@NetworkInterface^.Name[0]);
  if (Options and Ipv6OptionEui64Identifiers) <> 0 then
    DebugWrite(': IPv6 identifiers EUI-64')
  else
    DebugWrite(': IPv6 identifiers stable-privacy');
  if (Options and Ipv6OptionTemporaryAddresses) <> 0 then
    DebugWriteLine(', temporary addresses')
  else
    DebugWriteLine(', no temporary addresses');
  DebugEndMessage;
  if ((Previous xor Options) and Ipv6OptionEui64Identifiers) <> 0 then
    RestartIpv6(NetworkInterface)
  else if (Options and Ipv6OptionTemporaryAddresses) = 0 then
    RemoveIpv6AddressesOf(NetworkInterface, [Ipv6OriginTemporary])
  else
    StartTemporaryAddresses(NetworkInterface, NetworkNow);
  NoteNetworkChange;
end;

procedure SetIpv6StableSecret(Secret: PByte);
var
  Position: Integer;
  NetworkInterface: PNetworkInterface;
begin
  if not ReplaceStableSecret(Secret) then
    Exit;
  for Position := 0 to NetworkInterfaceCount - 1 do
  begin
    NetworkInterface := NetworkInterfaceAt(Position);
    if not NetworkInterface^.IsLoopback and UsesStableIdentifiers(NetworkInterface) then
    begin
      NetworkInterface^.Ipv6.StableDadCounter := 0;
      RestartIpv6(NetworkInterface);
    end;
  end;
end;

{ Detection of Entry's address is over: it is ready. }
procedure FinishDetection(NetworkInterface: PNetworkInterface; Entry: PIpv6InterfaceAddress; Now: QWord);
begin
  if Entry^.PreferredUntil <= Now then
    Entry^.State := Ipv6AddressDeprecated
  else
    Entry^.State := Ipv6AddressPreferred;
  WriteIpv6AddressChange(NetworkInterface, Entry^.Address, Entry^.PrefixLength, 'ready');
  if Entry^.Origin = Ipv6OriginTemporary then
    NetworkInterface^.Ipv6.TemporaryRetries := 0;
  if (Entry^.Origin = Ipv6OriginLinkLocal) and (NetworkInterface^.Ipv6.Mode = Ipv6ModeAutomatic) then
    StartRouterSolicitation(NetworkInterface);
  { MLD reports may now go from the link-local address. }
  if Entry^.Origin = Ipv6OriginLinkLocal then
    ScheduleMldReports(NetworkInterface);
  NoteNetworkChange;
end;

procedure RunDetection(NetworkInterface: PNetworkInterface; Entry: PIpv6InterfaceAddress; Now: QWord);
begin
  if Entry^.DadDeadline > Now then
  begin
    RequestNetworkWakeAt(Entry^.DadDeadline);
    Exit;
  end;
  if Entry^.DadProbesSent >= DuplicateDetectionProbes then
  begin
    FinishDetection(NetworkInterface, Entry, Now);
    Exit;
  end;
  SendNeighborSolicitation(NetworkInterface, Entry^.Address, SolicitedNodeAddress(Entry^.Address), True);
  Inc(Entry^.DadProbesSent);
  Entry^.DadDeadline := Now + QWord(NetworkInterface^.Ipv6.RetransmitMilliseconds) * NanosecondsPerMillisecond;
  RequestNetworkWakeAt(Entry^.DadDeadline);
end;

{ Lifetimes: deprecated, then gone. }
procedure RunLifetimes(NetworkInterface: PNetworkInterface; Entry: PIpv6InterfaceAddress; Now: QWord);
begin
  if Entry^.ValidUntil <= Now then
  begin
    RemoveIpv6AddressEntry(NetworkInterface, Entry, 'expired');
    Exit;
  end;
  if Entry^.ValidUntil <> Ipv6Forever then
    RequestNetworkWakeAt(Entry^.ValidUntil);
  if Entry^.State <> Ipv6AddressPreferred then
    Exit;
  if Entry^.PreferredUntil <= Now then
  begin
    Entry^.State := Ipv6AddressDeprecated;
    WriteIpv6AddressChange(NetworkInterface, Entry^.Address, Entry^.PrefixLength, 'deprecated');
    NoteNetworkChange;
  end
  else if Entry^.PreferredUntil <> Ipv6Forever then
    RequestNetworkWakeAt(Entry^.PreferredUntil);
end;

procedure RunInterfaceTimers(NetworkInterface: PNetworkInterface; Now: QWord);
var
  Index: Integer;
  Entry: PIpv6InterfaceAddress;
begin
  if not NetworkInterface^.Ipv6.IsStarted then
    Exit;
  for Index := 0 to MaximumIpv6InterfaceAddresses - 1 do
  begin
    Entry := @NetworkInterface^.Ipv6.Addresses[Index];
    if Entry^.State = Ipv6AddressFree then
      Continue;
    RunLifetimes(NetworkInterface, Entry, Now);
    if Entry^.State = Ipv6AddressTentative then
      RunDetection(NetworkInterface, Entry, Now)
    else if Entry^.State = Ipv6AddressPreferred then
      RunTemporaryAddressTimer(NetworkInterface, Entry, Now);
  end;
  RunRouterSolicitationTimer(NetworkInterface, Now);
  RunMldTimer(NetworkInterface, Now);
  if ExpireRouterDnsServers(NetworkInterface, Now) then
    NoteNetworkChange;
end;

procedure RunIpv6InterfaceTimers(Now: QWord);
var
  Position: Integer;
begin
  for Position := 0 to NetworkInterfaceCount - 1 do
    RunInterfaceTimers(NetworkInterfaceAt(Position), Now);
  RunIpv6DestinationTimers(Now);
  if RunIpv6RouteTimers(Now) then
    NoteNetworkChange;
end;

end.
