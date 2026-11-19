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
  Multicast Listener Discovery, version 2 (RFC 3810), as a listener:
  switches that snoop MLD forward a group's frames only to ports that
  reported it, so the solicited-node groups of our addresses must be
  reported or neighbour solicitations stop reaching us.

  A report lists every group the interface listens to but all-nodes
  (which is never reported) - the solicited-node groups of its addresses
  and the groups programs joined (Network.MulticastGroups) - each as
  "exclude no sources". A group the last program left is reported as
  "change to include no sources". Two
  unsolicited reports go when the addresses change (the second a second
  later); a query is answered with a report at once. Reports go to
  ff02::16 with hop limit 1 and a hop-by-hop router alert, from the
  link-local address, or from :: while it is still tentative (RFC 3590).
}
unit Network.Mld;

{$mode objfpc}
{$pointermath on}

interface

uses
  Network.Ipv6Addresses,
  Network.IpDatagrams,
  Network.Interfaces;

const
  UnsolicitedMldReports = 2;
  UnsolicitedReportIntervalSeconds = 1;

{ The interface's groups changed: reports are sent. }
procedure ScheduleMldReports(NetworkInterface: PNetworkInterface);
procedure StopMldReports(NetworkInterface: PNetworkInterface);
{ Reports that the interface no longer listens to Group. }
procedure SendMldGroupLeave(NetworkInterface: PNetworkInterface; constref Group: TIpv6Address);
procedure HandleMulticastListenerQuery(constref Datagram: TIpDatagram; Message: PByte; Length: LongWord);
{ On the network thread: sends what is due. }
procedure RunMldTimer(NetworkInterface: PNetworkInterface; Now: QWord);

implementation

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Network.ByteOrder,
  Network.Core,
  Network.Packets,
  Network.Ipv6Types,
  Network.MulticastGroups,
  Network.Ipv6,
  Network.Ipv6AddressList,
  Network.Icmpv6;

const
  ReportHeaderBytes = 8;
  GroupRecordBytes = 20;
  RecordModeIsExclude = 2;
  RecordChangeToInclude = 3;
  RecordChangeToExclude = 4;
  HopByHopBytes = 8;
  MaximumGroups = MaximumIpv6InterfaceAddresses + MaximumJoinedGroups;
  NanosecondsPerSecond = QWord(1000) * 1000 * 1000;

type
  TGroupList = record
    Count: Integer;
    Groups: array[0..MaximumGroups - 1] of TIpv6Address;
  end;

procedure AddGroup(var List: TGroupList; constref Group: TIpv6Address);
var
  Index: Integer;
begin
  for Index := 0 to List.Count - 1 do
    if Ipv6AddressesEqual(List.Groups[Index], Group) then
      Exit;
  if List.Count >= MaximumGroups then
    Exit;
  List.Groups[List.Count] := Group;
  Inc(List.Count);
end;

{ The groups to report: the solicited-node group of each address. }
procedure CollectGroups(NetworkInterface: PNetworkInterface; out List: TGroupList);
var
  Index: Integer;
  Entry: PIpv6InterfaceAddress;
  Joined: TIpv6Address;
begin
  List.Count := 0;
  for Index := 0 to MaximumIpv6InterfaceAddresses - 1 do
  begin
    Entry := @NetworkInterface^.Ipv6.Addresses[Index];
    if Entry^.State <> Ipv6AddressFree then
      AddGroup(List, SolicitedNodeAddress(Entry^.Address));
  end;
  Index := 0;
  while ReportedIpv6GroupAt(NetworkInterface, Index, Joined) do
  begin
    AddGroup(List, Joined);
    Inc(Index);
  end;
end;

procedure SendGroupList(NetworkInterface: PNetworkInterface; RecordType: Byte; constref List: TGroupList);
var
  Packet: PPacket;
  Message: PByte;
  HopByHop: PByte;
  Index: Integer;
  GroupRecord: PByte;
  Source: TIpv6Address;
begin
  if List.Count = 0 then
    Exit;
  Packet := AllocatePacket(PacketHeadroom);
  if Packet = nil then
    Exit;
  Message := AppendToPacket(Packet, ReportHeaderBytes + LongWord(List.Count) * GroupRecordBytes);
  FillMemory(Message, ReportHeaderBytes, 0);
  Message[0] := Icmpv6TypeMulticastListenerReportV2;
  WriteBigEndian16(Message + 6, Word(List.Count));
  for Index := 0 to List.Count - 1 do
  begin
    GroupRecord := Message + ReportHeaderBytes + LongWord(Index) * GroupRecordBytes;
    FillMemory(GroupRecord, 4, 0);
    GroupRecord[0] := RecordType;
    CopyMemory(GroupRecord + 4, @List.Groups[Index][0], Ipv6AddressLength);
  end;
  if not FindLinkLocalAddress(NetworkInterface, Source) then
    Source := UnspecifiedIpv6Address;
  WriteIcmpv6Checksum(Packet, Source, AllMldRoutersIpv6Address);
  { The router alert in a hop-by-hop header, padded to 8 bytes. }
  HopByHop := PrependToPacket(Packet, HopByHopBytes);
  if HopByHop = nil then
  begin
    FreePacket(Packet);
    Exit;
  end;
  HopByHop[0] := NextHeaderIcmpv6;
  HopByHop[1] := 0;
  HopByHop[2] := 5;
  HopByHop[3] := 2;
  HopByHop[4] := 0;
  HopByHop[5] := 0;
  HopByHop[6] := 1;
  HopByHop[7] := 0;
  TransmitIpv6(Packet, Source, AllMldRoutersIpv6Address, NextHeaderHopByHop, 1, NetworkInterface,
    AllMldRoutersIpv6Address);
end;

procedure SendReport(NetworkInterface: PNetworkInterface; RecordType: Byte);
var
  List: TGroupList;
begin
  CollectGroups(NetworkInterface, List);
  SendGroupList(NetworkInterface, RecordType, List);
end;

procedure SendMldGroupLeave(NetworkInterface: PNetworkInterface; constref Group: TIpv6Address);
var
  List: TGroupList;
begin
  if not NetworkInterface^.Ipv6.IsStarted then
    Exit;
  List.Count := 1;
  List.Groups[0] := Group;
  SendGroupList(NetworkInterface, RecordChangeToInclude, List);
end;

procedure ScheduleMldReports(NetworkInterface: PNetworkInterface);
begin
  UpdateMulticastFilter(NetworkInterface);
  if NetworkInterface^.IsLoopback then
    Exit;
  NetworkInterface^.Ipv6.MldReportsLeft := UnsolicitedMldReports;
  NetworkInterface^.Ipv6.NextMldReport := NetworkNow;
  RequestNetworkWakeAt(NetworkInterface^.Ipv6.NextMldReport);
end;

procedure StopMldReports(NetworkInterface: PNetworkInterface);
begin
  NetworkInterface^.Ipv6.MldReportsLeft := 0;
  NetworkInterface^.Ipv6.NextMldReport := 0;
end;

procedure HandleMulticastListenerQuery(constref Datagram: TIpDatagram; Message: PByte; Length: LongWord);
begin
  if (Datagram.TimeToLive <> 1) or not IsLinkLocalIpv6Address(Datagram.Source6) or
     not Datagram.ArrivalInterface^.Ipv6.IsStarted then
    Exit;
  SendReport(Datagram.ArrivalInterface, RecordModeIsExclude);
end;

procedure RunMldTimer(NetworkInterface: PNetworkInterface; Now: QWord);
var
  State: ^TIpv6InterfaceState;
begin
  State := @NetworkInterface^.Ipv6;
  if State^.NextMldReport = 0 then
    Exit;
  if State^.NextMldReport > Now then
  begin
    RequestNetworkWakeAt(State^.NextMldReport);
    Exit;
  end;
  SendReport(NetworkInterface, RecordChangeToExclude);
  if State^.MldReportsLeft > 0 then
    Dec(State^.MldReportsLeft);
  if State^.MldReportsLeft = 0 then
  begin
    State^.NextMldReport := 0;
    Exit;
  end;
  State^.NextMldReport := Now + UnsolicitedReportIntervalSeconds * NanosecondsPerSecond;
  RequestNetworkWakeAt(State^.NextMldReport);
end;

end.
