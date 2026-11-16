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
  netstat's table of sockets, in net-tools' columns:

    Active Internet connections (only servers)
    Proto Recv-Q Send-Q Local Address           Foreign Address         State
    tcp        0      0 0.0.0.0:7000            0.0.0.0:*               LISTEN

  TCP first, then UDP, then ICMP (-w), each in the kernel's order. A
  server is a listening TCP socket or an unconnected UDP or ICMP one;
  TCP sockets that are neither bound nor connected are not shown, as
  they are nowhere yet. With -p each line ends with the owner's process
  id and name ("412/nc"), "-" for a connection whose socket is gone.
}
unit Netstat.Connections;

{$mode objfpc}
{$H+}

interface

uses
  Netstat.Selection;

procedure ShowConnections(constref Selection: TNetstatSelection);

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.NetworkInterfaces,
  Sys.ProcessList,
  Sys.Sockets,
  Util.Messages,
  Sys.Streams,
  Netstat.Names;

function IsServer(constref Entry: TAbiSocketInformation): Boolean;
begin
  if Entry.Protocol = ProtocolTcp then
    Result := Entry.State = TcpStateListen
  else
    Result := Entry.PeerAddress.Port = 0;
end;

function ProtocolIsSelected(constref Entry: TAbiSocketInformation; constref Selection: TNetstatSelection): Boolean;
begin
  if (Entry.Family = AddressFamilyIPv6) and not Selection.ShowIpv6 then
    Exit(False);
  if (Entry.Family = AddressFamilyIPv4) and not Selection.ShowIpv4 then
    Exit(False);
  case Entry.Protocol of
    ProtocolTcp: Result := Selection.ShowTcp;
    ProtocolUdp: Result := Selection.ShowUdp;
    ProtocolIcmp, ProtocolIcmpv6: Result := Selection.ShowRaw;
  else
    Result := False;
  end;
end;

{ "tcp", "tcp6", "udp", "udp6", "icmp", "icmp6". }
function EntryProtocolName(constref Entry: TAbiSocketInformation): string;
begin
  if Entry.Protocol = ProtocolIcmpv6 then
    Exit('icmp6');
  Result := ProtocolName(Entry.Protocol);
  if Entry.Family = AddressFamilyIPv6 then
    Result := Result + '6';
end;

{ A TCP socket made but neither bound nor connected is nowhere yet. }
function IsUnplaced(constref Entry: TAbiSocketInformation): Boolean;
begin
  Result := (Entry.Protocol = ProtocolTcp) and (Entry.State = TcpStateClosed) and
    (Entry.LocalAddress.Port = 0);
end;

function EntryIsShown(constref Entry: TAbiSocketInformation; constref Selection: TNetstatSelection): Boolean;
begin
  if not ProtocolIsSelected(Entry, Selection) or IsUnplaced(Entry) then
    Exit(False);
  if Selection.ListeningOnly then
    Result := IsServer(Entry)
  else if Selection.All then
    Result := True
  else
    Result := not IsServer(Entry);
end;

{ "ESTABLISHED", "LISTEN"...; a connected UDP socket is ESTABLISHED, an
  unconnected one has no state. }
function StateText(constref Entry: TAbiSocketInformation): string;
begin
  if Entry.Protocol = ProtocolTcp then
    Result := TcpStateName(Entry.State)
  else if Entry.PeerAddress.Port <> 0 then
    Result := 'ESTABLISHED'
  else
    Result := '';
end;

{ "412/nc", or "-" when the socket has no owner or it is gone. }
function OwnerText(constref Entry: TAbiSocketInformation; const Processes: TProcessSnapshot): string;
var
  Details: PProcessDetails;
begin
  if Entry.OwnerProcessId = 0 then
    Exit('-');
  Result := IntToStr(Int64(Entry.OwnerProcessId)) + '/';
  Details := FindProcessInSnapshot(Processes, Entry.OwnerProcessId);
  if Details <> nil then
    Result := Result + StrPas(PChar(@Details^.Name[0]))
  else
    Result := Result + '-';
end;

procedure WriteTitle(constref Selection: TNetstatSelection);
begin
  if Selection.ListeningOnly then
    PrintStringLine('Active Internet connections (only servers)')
  else if Selection.All then
    PrintStringLine('Active Internet connections (servers and established)')
  else
    PrintStringLine('Active Internet connections (w/o servers)');
  PrintString('Proto Recv-Q Send-Q Local Address           Foreign Address         ');
  if Selection.ShowOwners then
    PrintStringLine('State       PID/Program name')
  else
    PrintStringLine('State');
end;

procedure WriteEntry(constref Entry: TAbiSocketInformation; constref Selection: TNetstatSelection;
  const Processes: TProcessSnapshot);
var
  ForeignText: string;
  State: string;
begin
  ForeignText := EndpointText(Entry.PeerAddress, Selection.Numeric);
  State := StateText(Entry);
  PrintString(Format('%-5s %6u %6u %-23s ', [EntryProtocolName(Entry), QWord(Entry.ReceiveQueued),
    QWord(Entry.SendQueued), EndpointText(Entry.LocalAddress, Selection.Numeric)]));
  if Selection.ShowOwners then
    PrintString(Format('%-23s %-11s %s'#10, [ForeignText, State, OwnerText(Entry, Processes)]))
  else if State = '' then
    { No state: no padding at the end of the line. }
    PrintStringLine(ForeignText)
  else
    PrintString(Format('%-23s %s'#10, [ForeignText, State]));
end;

procedure WriteEntriesOf(Family, Protocol: Word; const Entries: TSocketInformationList;
  constref Selection: TNetstatSelection; const Processes: TProcessSnapshot);
var
  Index: Integer;
begin
  for Index := 0 to High(Entries) do
    if (Entries[Index].Family = Family) and (Entries[Index].Protocol = Protocol) and
       EntryIsShown(Entries[Index], Selection) then
      WriteEntry(Entries[Index], Selection, Processes);
end;

procedure ShowConnections(constref Selection: TNetstatSelection);
var
  Entries: TSocketInformationList;
  Processes: TProcessSnapshot;
  Error: LongInt;
begin
  Error := ListSockets(Entries);
  if Error <> ErrorNone then
    FailWithError(1, Error, 'cannot read the list of sockets');
  InitializeProcessSnapshot(Processes);
  try
    if Selection.ShowOwners then
    begin
      Error := TakeProcessSnapshot(Processes);
      if Error <> ErrorNone then
        ReportError(Error, 'cannot read the list of processes');
    end;
    WriteTitle(Selection);
    WriteEntriesOf(AddressFamilyIPv4, ProtocolTcp, Entries, Selection, Processes);
    WriteEntriesOf(AddressFamilyIPv6, ProtocolTcp, Entries, Selection, Processes);
    WriteEntriesOf(AddressFamilyIPv4, ProtocolUdp, Entries, Selection, Processes);
    WriteEntriesOf(AddressFamilyIPv6, ProtocolUdp, Entries, Selection, Processes);
    WriteEntriesOf(AddressFamilyIPv4, ProtocolIcmp, Entries, Selection, Processes);
    WriteEntriesOf(AddressFamilyIPv6, ProtocolIcmpv6, Entries, Selection, Processes);
  finally
    FreeProcessSnapshot(Processes);
  end;
end;

end.
