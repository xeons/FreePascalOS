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
  IGMP (RFC 3376, version 3, and RFC 2236, version 2) as a host: the
  IPv4 multicast groups programs joined (Network.MulticastGroups) are
  reported so that routers and snooping switches send their datagrams
  here.

  Reports are IGMPv3's - to 224.0.0.22, one group record each ("change
  to exclude no sources" on joining, "change to include no sources" on
  leaving, "exclude no sources" answering a query) - unless an IGMPv1
  or v2 query was heard on the interface in the last 260 seconds (the
  Older Version Querier Present Timeout); then IGMPv2's: a membership
  report to the group, a leave to 224.0.0.2. A query is answered at
  once for every group (v3: one report; v2: one per group, or the one
  asked about). Every IGMP message goes with time to live 1 and the
  router alert option. Under the network lock.
}
unit Network.Igmp;

{$mode objfpc}
{$pointermath on}

interface

uses
  Network.Addresses,
  Network.IpDatagrams,
  Network.Interfaces;

const
  IpProtocolIgmp = 2;

procedure IgmpInput(constref Datagram: TIpDatagram; Message: PByte; Length: LongWord);
{ Reports joining (or, IsLeave, leaving) Group on the interface. }
procedure SendIgmpGroupReport(NetworkInterface: PNetworkInterface; Group: TIpv4Address; IsLeave: Boolean);

implementation

uses
  Runtime.Memory,
  Network.ByteOrder,
  Network.Checksums,
  Network.Core,
  Network.Packets,
  Network.Ipv4,
  Network.MulticastGroups;

const
  TypeMembershipQuery = $11;
  TypeVersion2Report = $16;
  TypeVersion2Leave = $17;
  TypeVersion3Report = $22;
  RecordModeIsExclude = 2;
  RecordChangeToInclude = 3;
  RecordChangeToExclude = 4;
  { 224.0.0.2 and 224.0.0.22. }
  AllRoutersGroup = TIpv4Address($E0000002);
  Version3ReportsGroup = TIpv4Address($E0000016);
  OlderQuerierTimeoutSeconds = 260;
  NanosecondsPerSecond = QWord(1000) * 1000 * 1000;
  Version3HeaderBytes = 8;
  GroupRecordBytes = 8;
  MaximumRecordsPerReport = 64;

var
  { Per interface (by index): until when IGMPv2 is spoken. }
  Version2Until: array[0..MaximumNetworkInterfaces] of QWord;

function SpeaksVersion2(NetworkInterface: PNetworkInterface): Boolean;
begin
  Result := (NetworkInterface^.Index <= MaximumNetworkInterfaces) and
    (Version2Until[NetworkInterface^.Index] > NetworkNow);
end;

procedure SendMessage(NetworkInterface: PNetworkInterface; Packet: PPacket; Destination: TIpv4Address);
var
  Message: PByte;
begin
  Message := PacketData(Packet);
  WriteBigEndian16(Message + 2, 0);
  WriteBigEndian16(Message + 2, InternetChecksum(Message, Packet^.Length));
  TransmitIpv4WithRouterAlert(Packet, Destination, IpProtocolIgmp, NetworkInterface);
end;

procedure SendVersion2Message(NetworkInterface: PNetworkInterface; MessageType: Byte; Group,
  Destination: TIpv4Address);
var
  Packet: PPacket;
  Message: PByte;
begin
  Packet := AllocatePacket(PacketHeadroom);
  if Packet = nil then
    Exit;
  Message := AppendToPacket(Packet, 8);
  FillMemory(Message, 8, 0);
  Message[0] := MessageType;
  WriteIpv4Address(Message + 4, Group);
  SendMessage(NetworkInterface, Packet, Destination);
end;

{ An IGMPv3 report of Count records of RecordType, the groups being
  the interface's joined ones (Single = 0) or Single alone. }
procedure SendVersion3Report(NetworkInterface: PNetworkInterface; RecordType: Byte; Single: TIpv4Address);
var
  Groups: array[0..MaximumRecordsPerReport - 1] of TIpv4Address;
  Count: Integer;
  Group: TIpv4Address;
  Packet: PPacket;
  Message: PByte;
  GroupRecord: PByte;
  Index: Integer;
begin
  Count := 0;
  if Single <> 0 then
  begin
    Groups[0] := Single;
    Count := 1;
  end
  else
    while (Count < MaximumRecordsPerReport) and ReportedIpv4GroupAt(NetworkInterface, Count, Group) do
    begin
      Groups[Count] := Group;
      Inc(Count);
    end;
  if Count = 0 then
    Exit;
  Packet := AllocatePacket(PacketHeadroom);
  if Packet = nil then
    Exit;
  Message := AppendToPacket(Packet, Version3HeaderBytes + LongWord(Count) * GroupRecordBytes);
  FillMemory(Message, Version3HeaderBytes, 0);
  Message[0] := TypeVersion3Report;
  WriteBigEndian16(Message + 6, Word(Count));
  for Index := 0 to Count - 1 do
  begin
    GroupRecord := Message + Version3HeaderBytes + LongWord(Index) * GroupRecordBytes;
    FillMemory(GroupRecord, GroupRecordBytes, 0);
    GroupRecord[0] := RecordType;
    WriteIpv4Address(GroupRecord + 4, Groups[Index]);
  end;
  SendMessage(NetworkInterface, Packet, Version3ReportsGroup);
end;

procedure SendIgmpGroupReport(NetworkInterface: PNetworkInterface; Group: TIpv4Address; IsLeave: Boolean);
begin
  if NetworkInterface^.IsLoopback or not InterfaceIsUsable(NetworkInterface) then
    Exit;
  if SpeaksVersion2(NetworkInterface) then
  begin
    if IsLeave then
      SendVersion2Message(NetworkInterface, TypeVersion2Leave, Group, AllRoutersGroup)
    else
      SendVersion2Message(NetworkInterface, TypeVersion2Report, Group, Group);
  end
  else if IsLeave then
    SendVersion3Report(NetworkInterface, RecordChangeToInclude, Group)
  else
    SendVersion3Report(NetworkInterface, RecordChangeToExclude, Group);
end;

procedure AnswerQuery(NetworkInterface: PNetworkInterface; AskedGroup: TIpv4Address);
var
  Position: Integer;
  Group: TIpv4Address;
begin
  if not SpeaksVersion2(NetworkInterface) then
  begin
    if AskedGroup = 0 then
      SendVersion3Report(NetworkInterface, RecordModeIsExclude, 0)
    else if InterfaceJoinedIpv4Group(NetworkInterface, AskedGroup) and (AskedGroup <> AllHostsGroup) then
      SendVersion3Report(NetworkInterface, RecordModeIsExclude, AskedGroup);
    Exit;
  end;
  Position := 0;
  while ReportedIpv4GroupAt(NetworkInterface, Position, Group) do
  begin
    if (AskedGroup = 0) or (AskedGroup = Group) then
      SendVersion2Message(NetworkInterface, TypeVersion2Report, Group, Group);
    Inc(Position);
  end;
end;

procedure IgmpInput(constref Datagram: TIpDatagram; Message: PByte; Length: LongWord);
var
  NetworkInterface: PNetworkInterface;
begin
  NetworkInterface := Datagram.ArrivalInterface;
  if (Length < 8) or (InternetChecksum(Message, Length) <> 0) or NetworkInterface^.IsLoopback then
    Exit;
  if Message[0] <> TypeMembershipQuery then
    Exit;
  { An IGMPv1 or v2 query is 8 bytes; v3's longer. }
  if (Length < 12) and (NetworkInterface^.Index <= MaximumNetworkInterfaces) then
    Version2Until[NetworkInterface^.Index] := NetworkNow + QWord(OlderQuerierTimeoutSeconds) * NanosecondsPerSecond;
  AnswerQuery(NetworkInterface, ReadIpv4Address(Message + 4));
end;

end.
