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
  Abi.SystemCalls,
  Configuration.NetworkState;

type
  { From the least to the most connected. }
  TNetworkCondition = (ConditionDisabled, ConditionNotConfigured, ConditionNoLink, ConditionFailed,
    ConditionConnecting, ConditionConnected);

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
    { The kernel's first address with its prefix, or empty. }
    KernelAddress: string;
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
  SysUtils,
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

function FirstKernelAddress(const Description: TAbiNetworkInterface): string;
var
  Text: array[0..Ipv4AddressTextCapacity - 1] of Char;
begin
  if Description.AddressCount = 0 then
    Exit('');
  FormatInternetAddress(InterfaceAddressHost(Description.Addresses[0]), @Text[0], SizeOf(Text));
  Result := string(PChar(@Text[0])) + '/' + IntToStr(Description.Addresses[0].PrefixLength);
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

function DescribeInterface(const Description: TAbiNetworkInterface): TInterfaceStatus;
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
  Result.KernelAddress := FirstKernelAddress(Description);
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
  Index: LongInt;
begin
  List := nil;
  Result := ListNetworkInterfaces(Interfaces);
  if Result <> ErrorNone then
    Exit;
  for Index := 0 to High(Interfaces) do
  begin
    if (Interfaces[Index].Flags and InterfaceFlagLoopback) <> 0 then
      Continue;
    SetLength(List, Length(List) + 1);
    List[High(List)] := DescribeInterface(Interfaces[Index]);
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
