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
  The multicast groups programs joined, per interface, for both IP
  versions: each with a count of the sockets that joined it there.

  The first join of a group on an interface reports it - IPv6 by MLDv2
  (Network.Mld: the interface's whole state, twice), IPv4 by IGMP
  (Network.Igmp: a report for the group, twice a second apart) - and
  the last leave reports that it is gone (MLDv2's "change to include no
  sources", IGMP's leave, twice). Groups of interface-local scope
  (ff01::/16) and the all-nodes and all-hosts groups are never
  reported. IPv6 and IPv4 take datagrams for the groups joined on the
  arrival interface (lo takes every group).

  The Ethernet addresses of the interface's groups (IPv6's 33:33 ones,
  its own solicited-node and all-nodes groups included, and IPv4's
  01:00:5e ones) are handed to the driver's multicast filter when it
  has one (TNetworkDriverRoutines.SetMulticastFilter); a driver without
  one takes all multicast, and Ethernet input lets every IP multicast
  frame through to IP, which filters by group. Under the network lock.
}
unit Network.MulticastGroups;

{$mode objfpc}

interface

uses
  Io.NetworkAdapters,
  Network.Addresses,
  Network.Ipv6Addresses,
  Network.Interfaces;

const
  MaximumJoinedGroups = 64;
  MulticastReportRepeats = 2;
  { 224.0.0.1, all hosts. }
  AllHostsGroup = TIpv4Address($E0000001);

{ Family AddressFamilyIPv6 with Group6, or AddressFamilyIPv4 with
  Group4. ErrorNoSpace when the table is full. }
function JoinMulticastGroup(NetworkInterface: PNetworkInterface; Family: Word; constref Group6: TIpv6Address;
  Group4: TIpv4Address): LongInt;
procedure LeaveMulticastGroup(NetworkInterface: PNetworkInterface; Family: Word; constref Group6: TIpv6Address;
  Group4: TIpv4Address);
function InterfaceJoinedIpv6Group(NetworkInterface: PNetworkInterface; constref Group: TIpv6Address): Boolean;
function InterfaceJoinedIpv4Group(NetworkInterface: PNetworkInterface; Group: TIpv4Address): Boolean;
{ The Position-th (from 0) IPv6 group joined on the interface that MLD
  reports; False past the last. }
function ReportedIpv6GroupAt(NetworkInterface: PNetworkInterface; Position: Integer; out Group: TIpv6Address): Boolean;
{ Likewise for IPv4 and IGMP. }
function ReportedIpv4GroupAt(NetworkInterface: PNetworkInterface; Position: Integer; out Group: TIpv4Address): Boolean;
{ IPv4 multicast groups go to Ethernet addresses 01:00:5e and the low
  23 bits. }
function Ipv4MulticastEthernetAddress(Group: TIpv4Address): TEthernetAddress;
{ The groups of the interface changed (also its addresses): the
  driver's filter is set again. }
procedure UpdateMulticastFilter(NetworkInterface: PNetworkInterface);
{ On the network thread: reports still to repeat. }
procedure RunMulticastTimers(Now: QWord);

implementation

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Network.Core,
  Network.Ipv6Types,
  Network.Mld,
  Network.Igmp;

type
  TJoinedGroup = record
    InUse: Boolean;
    NetworkInterface: PNetworkInterface;
    Family: Word;
    Group6: TIpv6Address;
    Group4: TIpv4Address;
    References: LongWord;
  end;

  { A report still to send again (IGMP joins and leaves, MLD leaves). }
  TPendingReport = record
    InUse: Boolean;
    NetworkInterface: PNetworkInterface;
    Family: Word;
    Group6: TIpv6Address;
    Group4: TIpv4Address;
    IsLeave: Boolean;
    RepeatsLeft: LongWord;
    DueAt: QWord;
  end;

const
  MaximumPendingReports = 32;
  NanosecondsPerSecond = QWord(1000) * 1000 * 1000;
  MaximumFilterAddresses = 64;

var
  Groups: array[0..MaximumJoinedGroups - 1] of TJoinedGroup;
  Pending: array[0..MaximumPendingReports - 1] of TPendingReport;

function Ipv4MulticastEthernetAddress(Group: TIpv4Address): TEthernetAddress;
begin
  Result[0] := $01;
  Result[1] := $00;
  Result[2] := $5E;
  Result[3] := Byte(Group shr 16) and $7F;
  Result[4] := Byte(Group shr 8);
  Result[5] := Byte(Group);
end;

function Matches(constref Entry: TJoinedGroup; NetworkInterface: PNetworkInterface; Family: Word;
  constref Group6: TIpv6Address; Group4: TIpv4Address): Boolean;
begin
  Result := Entry.InUse and (Entry.NetworkInterface = NetworkInterface) and (Entry.Family = Family);
  if not Result then
    Exit;
  if Family = AddressFamilyIPv6 then
    Result := Ipv6AddressesEqual(Entry.Group6, Group6)
  else
    Result := Entry.Group4 = Group4;
end;

function FindGroup(NetworkInterface: PNetworkInterface; Family: Word; constref Group6: TIpv6Address;
  Group4: TIpv4Address): Integer;
var
  Index: Integer;
begin
  for Index := 0 to MaximumJoinedGroups - 1 do
    if Matches(Groups[Index], NetworkInterface, Family, Group6, Group4) then
      Exit(Index);
  Result := -1;
end;

{ Groups that are never reported. }
function IsUnreportedIpv6Group(constref Group: TIpv6Address): Boolean;
begin
  Result := ((Group[1] and $0F) <= 1) or Ipv6AddressesEqual(Group, AllNodesIpv6Address);
end;

function IsUnreportedIpv4Group(Group: TIpv4Address): Boolean;
begin
  Result := Group = AllHostsGroup;
end;

procedure SendGroupReport(constref Report: TPendingReport);
begin
  if Report.NetworkInterface^.IsLoopback then
    Exit;
  if Report.Family = AddressFamilyIPv6 then
    SendMldGroupLeave(Report.NetworkInterface, Report.Group6)
  else
    SendIgmpGroupReport(Report.NetworkInterface, Report.Group4, Report.IsLeave);
end;

{ Sends the report now and keeps it to send again. }
procedure StartReports(NetworkInterface: PNetworkInterface; Family: Word; constref Group6: TIpv6Address;
  Group4: TIpv4Address; IsLeave: Boolean);
var
  Index: Integer;
  Report: TPendingReport;
begin
  Report.InUse := True;
  Report.NetworkInterface := NetworkInterface;
  Report.Family := Family;
  Report.Group6 := Group6;
  Report.Group4 := Group4;
  Report.IsLeave := IsLeave;
  Report.RepeatsLeft := MulticastReportRepeats - 1;
  Report.DueAt := NetworkNow + NanosecondsPerSecond;
  SendGroupReport(Report);
  for Index := 0 to MaximumPendingReports - 1 do
    { A newer report for the same group replaces the older one. }
    if Pending[Index].InUse and (Pending[Index].NetworkInterface = NetworkInterface) and
       (Pending[Index].Family = Family) and Ipv6AddressesEqual(Pending[Index].Group6, Group6) and
       (Pending[Index].Group4 = Group4) then
      Pending[Index].InUse := False;
  for Index := 0 to MaximumPendingReports - 1 do
    if not Pending[Index].InUse then
    begin
      Pending[Index] := Report;
      RequestNetworkWakeAt(Report.DueAt);
      Exit;
    end;
end;

function JoinMulticastGroup(NetworkInterface: PNetworkInterface; Family: Word; constref Group6: TIpv6Address;
  Group4: TIpv4Address): LongInt;
var
  Position: Integer;
  Index: Integer;
begin
  Position := FindGroup(NetworkInterface, Family, Group6, Group4);
  if Position >= 0 then
  begin
    Inc(Groups[Position].References);
    Exit(ErrorNone);
  end;
  for Index := 0 to MaximumJoinedGroups - 1 do
    if not Groups[Index].InUse then
    begin
      Groups[Index].InUse := True;
      Groups[Index].NetworkInterface := NetworkInterface;
      Groups[Index].Family := Family;
      Groups[Index].Group6 := Group6;
      Groups[Index].Group4 := Group4;
      Groups[Index].References := 1;
      if Family = AddressFamilyIPv6 then
      begin
        if not IsUnreportedIpv6Group(Group6) then
          ScheduleMldReports(NetworkInterface);
      end
      else if not IsUnreportedIpv4Group(Group4) then
        StartReports(NetworkInterface, Family, Group6, Group4, False);
      UpdateMulticastFilter(NetworkInterface);
      Exit(ErrorNone);
    end;
  Result := ErrorNoSpace;
end;

procedure LeaveMulticastGroup(NetworkInterface: PNetworkInterface; Family: Word; constref Group6: TIpv6Address;
  Group4: TIpv4Address);
var
  Position: Integer;
  Reported: Boolean;
begin
  Position := FindGroup(NetworkInterface, Family, Group6, Group4);
  if Position < 0 then
    Exit;
  Dec(Groups[Position].References);
  if Groups[Position].References > 0 then
    Exit;
  Groups[Position].InUse := False;
  if Family = AddressFamilyIPv6 then
    Reported := not IsUnreportedIpv6Group(Group6)
  else
    Reported := not IsUnreportedIpv4Group(Group4);
  if Reported then
    StartReports(NetworkInterface, Family, Group6, Group4, True);
  UpdateMulticastFilter(NetworkInterface);
end;

function InterfaceJoinedIpv6Group(NetworkInterface: PNetworkInterface; constref Group: TIpv6Address): Boolean;
begin
  Result := FindGroup(NetworkInterface, AddressFamilyIPv6, Group, 0) >= 0;
end;

function InterfaceJoinedIpv4Group(NetworkInterface: PNetworkInterface; Group: TIpv4Address): Boolean;
begin
  Result := (Group = AllHostsGroup) or
    (FindGroup(NetworkInterface, AddressFamilyIPv4, UnspecifiedIpv6Address, Group) >= 0);
end;

function ReportedIpv6GroupAt(NetworkInterface: PNetworkInterface; Position: Integer; out Group: TIpv6Address): Boolean;
var
  Index: Integer;
  Seen: Integer;
begin
  Group := UnspecifiedIpv6Address;
  Seen := 0;
  for Index := 0 to MaximumJoinedGroups - 1 do
    if Groups[Index].InUse and (Groups[Index].NetworkInterface = NetworkInterface) and
       (Groups[Index].Family = AddressFamilyIPv6) and not IsUnreportedIpv6Group(Groups[Index].Group6) then
    begin
      if Seen = Position then
      begin
        Group := Groups[Index].Group6;
        Exit(True);
      end;
      Inc(Seen);
    end;
  Result := False;
end;

function ReportedIpv4GroupAt(NetworkInterface: PNetworkInterface; Position: Integer; out Group: TIpv4Address): Boolean;
var
  Index: Integer;
  Seen: Integer;
begin
  Group := 0;
  Seen := 0;
  for Index := 0 to MaximumJoinedGroups - 1 do
    if Groups[Index].InUse and (Groups[Index].NetworkInterface = NetworkInterface) and
       (Groups[Index].Family = AddressFamilyIPv4) and not IsUnreportedIpv4Group(Groups[Index].Group4) then
    begin
      if Seen = Position then
      begin
        Group := Groups[Index].Group4;
        Exit(True);
      end;
      Inc(Seen);
    end;
  Result := False;
end;

procedure AddFilterAddress(var Addresses: array of TEthernetAddress; var Count: LongWord;
  constref Address: TEthernetAddress);
var
  Index: LongWord;
begin
  Index := 0;
  while Index < Count do
  begin
    if MemoryIsEqual(@Addresses[Index][0], @Address[0], EthernetAddressLength) then
      Exit;
    Inc(Index);
  end;
  if Count > High(Addresses) then
    Exit;
  Addresses[Count] := Address;
  Inc(Count);
end;

procedure UpdateMulticastFilter(NetworkInterface: PNetworkInterface);
var
  Adapter: PNetworkAdapter;
  Addresses: array[0..MaximumFilterAddresses - 1] of TEthernetAddress;
  Count: LongWord;
  Index: Integer;
  Entry: PIpv6InterfaceAddress;
  AllMulticast: Boolean;
begin
  Adapter := NetworkInterface^.Adapter;
  if NetworkInterface^.IsLoopback or (Adapter = nil) or (Adapter^.Routines.SetMulticastFilter = nil) then
    Exit;
  Count := 0;
  AddFilterAddress(Addresses, Count, MulticastEthernetAddress(AllNodesIpv6Address));
  AddFilterAddress(Addresses, Count, Ipv4MulticastEthernetAddress(AllHostsGroup));
  for Index := 0 to MaximumIpv6InterfaceAddresses - 1 do
  begin
    Entry := @NetworkInterface^.Ipv6.Addresses[Index];
    if Entry^.State <> Ipv6AddressFree then
      AddFilterAddress(Addresses, Count, MulticastEthernetAddress(SolicitedNodeAddress(Entry^.Address)));
  end;
  for Index := 0 to MaximumJoinedGroups - 1 do
    if Groups[Index].InUse and (Groups[Index].NetworkInterface = NetworkInterface) then
      if Groups[Index].Family = AddressFamilyIPv6 then
        AddFilterAddress(Addresses, Count, MulticastEthernetAddress(Groups[Index].Group6))
      else
        AddFilterAddress(Addresses, Count, Ipv4MulticastEthernetAddress(Groups[Index].Group4));
  { More than the list holds: everything. }
  AllMulticast := Count >= MaximumFilterAddresses;
  Adapter^.Routines.SetMulticastFilter(Adapter^.Context, @Addresses[0], Count, AllMulticast);
end;

procedure RunMulticastTimers(Now: QWord);
var
  Index: Integer;
begin
  for Index := 0 to MaximumPendingReports - 1 do
  begin
    if not Pending[Index].InUse then
      Continue;
    if Pending[Index].DueAt > Now then
    begin
      RequestNetworkWakeAt(Pending[Index].DueAt);
      Continue;
    end;
    SendGroupReport(Pending[Index]);
    Dec(Pending[Index].RepeatsLeft);
    if Pending[Index].RepeatsLeft = 0 then
      Pending[Index].InUse := False
    else
    begin
      Pending[Index].DueAt := Now + NanosecondsPerSecond;
      RequestNetworkWakeAt(Pending[Index].DueAt);
    end;
  end;
end;

end.
