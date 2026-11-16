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
  How each network interface is doing, for people: what the kernel says
  (Sys.NetworkInterfaces: turned on, the link, the Ethernet address,
  the MTU, packets and bytes) beside what the network service says
  (Configuration.NetworkState: configuring, configured, the lease), as
  one record per interface, the loopback interface left out. The
  Control Panel's Network page and the taskbar's network icon both show
  it.

  The condition sums it up: disabled (turned off), no link (no cable),
  not configured, failed (no address could be had), connecting, or
  connected. Without a state file (no network service, or one that
  writes none) an interface with an address counts as connected.

  The service's folder is watched (WatchNetworkState) so a change shows
  at once; the kernel's facts (the link, the counters) are looked at
  whenever the caller lists them again.
}
unit Configuration.NetworkStatus;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Abi.SystemCalls,
  Configuration.NetworkState;

type
  { From the least to the most connected. }
  TNetworkCondition = (ConditionDisabled, ConditionNotConfigured, ConditionNoLink, ConditionFailed,
    ConditionConnecting, ConditionConnected);

  { One of the kernel's IPv6 addresses of an interface. }
  TIpv6AddressStatus = record
    { "fec0::5054:ff:fe12:3456/64". }
    Text: string;
    { InterfaceAddressFlag* (tentative, deprecated, automatic, link-local). }
    Flags: LongWord;
    IsLinkLocal: Boolean;
  end;

  TIpv6AddressStatusList = array of TIpv6AddressStatus;

  TInterfaceStatus = record
    Name: string;
    { The adapter's ("Virtio network adapter"). }
    Description: string;
    { "52:54:00:12:34:56". }
    HardwareAddress: string;
    Up: Boolean;
    LinkUp: Boolean;
    Mtu: LongWord;
    Counters: TAbiInterfaceCounters;
    { The kernel's IPv4 address with its prefix, or empty. }
    KernelAddress: string;
    { Ipv6Mode* as the kernel has it. }
    Ipv6Mode: LongWord;
    { Every IPv6 address the kernel gave it, in the kernel's order. }
    Ipv6Addresses: TIpv6AddressStatusList;
    { The gateway of its IPv6 default route ("fe80::2"), or empty. }
    Ipv6Router: string;
    State: TInterfaceState;
    Condition: TNetworkCondition;
    { The address to show: the service's, else the kernel's. }
    Address: string;
  end;

  TInterfaceStatusList = array of TInterfaceStatus;

{ Every interface but loopback, in the kernel's order. }
function ListInterfaceStatus(out List: TInterfaceStatusList): LongInt;
{ The most connected interface (the first of equals), -1 for none. }
function FindBestInterface(const List: TInterfaceStatusList): LongInt;
{ "connected", "no cable", ... }
function NetworkConditionText(Condition: TNetworkCondition): string;
{ "eth0: 10.0.2.15 - connected" (with an em dash), "eth0: no cable". }
function InterfaceSummary(const Status: TInterfaceStatus): string;
{ The IPv6 addresses worth showing first: neither link-local nor
  tentative ("fec0::5054:ff:fe12:3456/64"). }
function GlobalIpv6Addresses(const Status: TInterfaceStatus): TStringArray;
{ "10.0.2.15/24" -> "10.0.2.15". }
function AddressWithoutPrefix(const Text: string): string;
{ Reads /var/lib/network/NAME.state; False if there is none (or it
  cannot be read). }
function ReadInterfaceStateFile(const Name: string; out State: TInterfaceState): Boolean;

{ A watch on the service's state folder (Sys.FileWatches), or a
  negative error (the folder may not be there yet: try again later). }
function WatchNetworkState: Int64;
{ Takes what waits in Watch. False when the watch has ended (the
  folder went): close it and watch again later. }
function TakeNetworkStateChanges(Watch: Int64): Boolean;

const
  { UTF-8. }
  EmDash = #$E2#$80#$94;

implementation

uses
  Sys.AddressText,
  Sys.Files,
  Sys.FileWatches,
  Sys.InternetAddresses,
  Sys.NetworkInterfaces;

const
  MaximumStateFileSize = 64 * 1024;

function ReadSmallFile(const Path: string; out Text: string): Boolean;
var
  Handle: Int64;
  Buffer: array[0..1023] of Char;
  Count: Int64;
  Chunk: string;
begin
  Text := '';
  Handle := OpenFile(PChar(Path), OpenRead);
  if Handle < 0 then
    Exit(False);
  Result := True;
  repeat
    Count := ReadFile(Handle, @Buffer[0], SizeOf(Buffer));
    if Count < 0 then
      Result := False
    else if Count > 0 then
    begin
      SetString(Chunk, PChar(@Buffer[0]), Count);
      Text := Text + Chunk;
    end;
  until (Count <= 0) or (Length(Text) > MaximumStateFileSize);
  CloseFile(Handle);
end;

function ReadInterfaceStateFile(const Name: string; out State: TInterfaceState): Boolean;
var
  Text: string;
begin
  State := Default(TInterfaceState);
  State.Name := Name;
  Result := ReadSmallFile(InterfaceStatePath(Name), Text) and ParseInterfaceState(Name, Text, State);
end;

function KernelIpv4Address(const Description: TAbiNetworkInterface): string;
var
  Address: TAbiInterfaceAddress;
begin
  if not FindInterfaceIpv4Address(Description, Address) then
    Exit('');
  Result := InterfaceAddressToText(Address);
end;

function KernelIpv6Addresses(const Description: TAbiNetworkInterface): TIpv6AddressStatusList;
var
  Index: LongWord;
  Entry: TIpv6AddressStatus;
begin
  Result := nil;
  Index := 0;
  while (Index < Description.AddressCount) and (Index < MaximumInterfaceAddresses) do
  begin
    if Description.Addresses[Index].Family = AddressFamilyIPv6 then
    begin
      Entry.Text := InterfaceAddressToText(Description.Addresses[Index]);
      Entry.Flags := Description.Addresses[Index].Flags;
      Entry.IsLinkLocal := AddressIsLinkLocal(InterfaceAddressHost(Description.Addresses[Index]));
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Entry;
    end;
    Inc(Index);
  end;
end;

function Ipv6DefaultRouter(const Name: string; const Routes: TRouteList): string;
var
  Index: Integer;
begin
  for Index := 0 to High(Routes) do
    if (Routes[Index].Destination.Family = AddressFamilyIPv6) and (Routes[Index].Destination.PrefixLength = 0) and
       (string(PChar(@Routes[Index].InterfaceName[0])) = Name) then
      Exit(AddressToText(RouteGateway(Routes[Index])));
  Result := '';
end;

function GlobalIpv6Addresses(const Status: TInterfaceStatus): TStringArray;
var
  Index: Integer;
begin
  Result := nil;
  for Index := 0 to High(Status.Ipv6Addresses) do
    if not Status.Ipv6Addresses[Index].IsLinkLocal and
       ((Status.Ipv6Addresses[Index].Flags and InterfaceAddressFlagTentative) = 0) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Status.Ipv6Addresses[Index].Text;
    end;
end;

function ConditionOf(const Status: TInterfaceStatus): TNetworkCondition;
begin
  if not Status.Up then
    Exit(ConditionDisabled);
  if not Status.LinkUp then
    Exit(ConditionNoLink);
  if not Status.State.Known then
  begin
    if Status.KernelAddress <> '' then
      Exit(ConditionConnected);
    Exit(ConditionNotConfigured);
  end;
  case Status.State.Progress of
    ProgressDown: Result := ConditionDisabled;
    ProgressNoLink: Result := ConditionNoLink;
    ProgressConfiguring: Result := ConditionConnecting;
    ProgressConfigured: Result := ConditionConnected;
    ProgressFailed: Result := ConditionFailed;
  else
    Result := ConditionNotConfigured;
  end;
end;

function DescribeInterface(const Description: TAbiNetworkInterface; const Routes: TRouteList): TInterfaceStatus;
var
  Text: array[0..3 * HardwareAddressCapacity] of Char;
begin
  Result := Default(TInterfaceStatus);
  Result.Name := string(PChar(@Description.Name[0]));
  Result.Description := string(PChar(@Description.Description[0]));
  FormatHardwareAddress(@Description.HardwareAddress[0], Description.HardwareAddressLength, @Text[0], SizeOf(Text));
  Result.HardwareAddress := string(PChar(@Text[0]));
  Result.Up := (Description.Flags and InterfaceFlagUp) <> 0;
  Result.LinkUp := (Description.Flags and InterfaceFlagRunning) <> 0;
  Result.Mtu := Description.Mtu;
  Result.Counters := Description.Counters;
  Result.KernelAddress := KernelIpv4Address(Description);
  Result.Ipv6Mode := Description.Ipv6Mode;
  Result.Ipv6Addresses := KernelIpv6Addresses(Description);
  Result.Ipv6Router := Ipv6DefaultRouter(Result.Name, Routes);
  ReadInterfaceStateFile(Result.Name, Result.State);
  Result.Condition := ConditionOf(Result);
  if Result.State.Known and (Result.State.Address <> '') then
    Result.Address := Result.State.Address
  else
    Result.Address := Result.KernelAddress;
end;

function ListInterfaceStatus(out List: TInterfaceStatusList): LongInt;
var
  Interfaces: TNetworkInterfaceList;
  Routes: TRouteList;
  Index: LongInt;
begin
  List := nil;
  Result := ListNetworkInterfaces(Interfaces);
  if Result <> ErrorNone then
    Exit;
  if ListRoutes(Routes) <> ErrorNone then
    Routes := nil;
  for Index := 0 to High(Interfaces) do
  begin
    if (Interfaces[Index].Flags and InterfaceFlagLoopback) <> 0 then
      Continue;
    SetLength(List, Length(List) + 1);
    List[High(List)] := DescribeInterface(Interfaces[Index], Routes);
  end;
end;

function FindBestInterface(const List: TInterfaceStatusList): LongInt;
var
  Index: LongInt;
begin
  Result := -1;
  for Index := 0 to High(List) do
    if (Result < 0) or (List[Index].Condition > List[Result].Condition) then
      Result := Index;
end;

function NetworkConditionText(Condition: TNetworkCondition): string;
begin
  case Condition of
    ConditionDisabled: Result := 'disabled';
    ConditionNotConfigured: Result := 'not configured';
    ConditionNoLink: Result := 'no cable';
    ConditionFailed: Result := 'no address';
    ConditionConnecting: Result := 'connecting';
    ConditionConnected: Result := 'connected';
  else
    Result := '';
  end;
end;

function AddressWithoutPrefix(const Text: string): string;
var
  Slash: SizeInt;
begin
  Slash := Pos('/', Text);
  if Slash > 0 then
    Result := Copy(Text, 1, Slash - 1)
  else
    Result := Text;
end;

function InterfaceSummary(const Status: TInterfaceStatus): string;
begin
  if (Status.Condition = ConditionConnected) and (Status.Address <> '') then
    Result := Status.Name + ': ' + AddressWithoutPrefix(Status.Address) + ' ' + EmDash + ' ' +
      NetworkConditionText(Status.Condition)
  else
    Result := Status.Name + ': ' + NetworkConditionText(Status.Condition);
end;

function WatchNetworkState: Int64;
begin
  Result := WatchPath(NetworkStateFolder, WatchNames or WatchContents);
end;

function TakeNetworkStateChanges(Watch: Int64): Boolean;
var
  Reader: TFileChangeReader;
  Change: TFileChange;
begin
  Result := True;
  while (ReadFileChanges(Reader, Watch) = ErrorNone) and (Reader.Length > 0) do
    while NextFileChange(Reader, Change) do
      if (Change.Kind = FileChangeWatchedItemRemoved) or (Change.Kind = FileChangeWatchedItemMoved) or
         (Change.Kind = FileChangeVolumeGone) then
        Result := False;
end;

end.
