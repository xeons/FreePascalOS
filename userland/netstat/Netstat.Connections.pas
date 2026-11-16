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

interface

uses
  Netstat.Selection;

procedure ShowConnections(constref Selection: TNetstatSelection);

implementation

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Errors,
  Sys.Format,
  Sys.NetworkInterfaces,
  Sys.ProcessList,
  Sys.Sockets,
  Sys.Streams,
  Sys.Text,
  Util.Messages,
  Netstat.Names;

const
  OwnerTextCapacity = 64;

function IsServer(constref Entry: TAbiSocketInformation): Boolean;
begin
  if Entry.Protocol = ProtocolTcp then
    Result := Entry.State = TcpStateListen
  else
    Result := Entry.PeerAddress.Port = 0;
end;

function ProtocolIsSelected(Protocol: Word; constref Selection: TNetstatSelection): Boolean;
begin
  case Protocol of
    ProtocolTcp: Result := Selection.ShowTcp;
    ProtocolUdp: Result := Selection.ShowUdp;
    ProtocolIcmp: Result := Selection.ShowRaw;
  else
    Result := False;
  end;
end;

{ A TCP socket made but neither bound nor connected is nowhere yet. }
function IsUnplaced(constref Entry: TAbiSocketInformation): Boolean;
begin
  Result := (Entry.Protocol = ProtocolTcp) and (Entry.State = TcpStateClosed) and
    (Entry.LocalAddress.Port = 0);
end;

function EntryIsShown(constref Entry: TAbiSocketInformation; constref Selection: TNetstatSelection): Boolean;
begin
  if not ProtocolIsSelected(Entry.Protocol, Selection) or IsUnplaced(Entry) then
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
function StateText(constref Entry: TAbiSocketInformation): PChar;
begin
  if Entry.Protocol = ProtocolTcp then
    Result := TcpStateName(Entry.State)
  else if Entry.PeerAddress.Port <> 0 then
    Result := 'ESTABLISHED'
  else
    Result := '';
end;

{ "412/nc", or "-" when the socket has no owner or it is gone. }
function FormatOwner(constref Entry: TAbiSocketInformation; const Processes: TProcessSnapshot;
  Buffer: PChar; Capacity: PtrUInt): PChar;
var
  Details: PProcessDetails;
  Builder: TTextBuilder;
begin
  Result := Buffer;
  if Entry.OwnerProcessId = 0 then
  begin
    CopyText(Buffer, '-', Capacity);
    Exit;
  end;
  BeginText(Builder);
  AppendDecimal(Builder, Int64(Entry.OwnerProcessId));
  Details := FindProcessInSnapshot(Processes, Entry.OwnerProcessId);
  AppendCharacter(Builder, '/');
  if Details <> nil then
    AppendText(Builder, @Details^.Name[0])
  else
    AppendCharacter(Builder, '-');
  CopyText(Buffer, Builder.Text, Capacity);
  DiscardText(Builder);
end;

procedure WriteTitle(constref Selection: TNetstatSelection);
begin
  if Selection.ListeningOnly then
    WriteLine(StandardOutput, 'Active Internet connections (only servers)')
  else if Selection.All then
    WriteLine(StandardOutput, 'Active Internet connections (servers and established)')
  else
    WriteLine(StandardOutput, 'Active Internet connections (w/o servers)');
  WriteText(StandardOutput, 'Proto Recv-Q Send-Q Local Address           Foreign Address         ');
  if Selection.ShowOwners then
    WriteLine(StandardOutput, 'State       PID/Program name')
  else
    WriteLine(StandardOutput, 'State');
end;

procedure WriteEntry(constref Entry: TAbiSocketInformation; constref Selection: TNetstatSelection;
  const Processes: TProcessSnapshot);
var
  LocalText: array[0..EndpointTextCapacity - 1] of Char;
  ForeignText: array[0..EndpointTextCapacity - 1] of Char;
  OwnerText: array[0..OwnerTextCapacity - 1] of Char;
begin
  FormatEndpoint(Entry.LocalAddress, Selection.Numeric, @LocalText[0], SizeOf(LocalText));
  FormatEndpoint(Entry.PeerAddress, Selection.Numeric, @ForeignText[0], SizeOf(ForeignText));
  WriteFormatted(StandardOutput, '%-4s  %6u %6u %-23s ', [ArgumentText(ProtocolName(Entry.Protocol)),
    ArgumentUnsigned(Entry.ReceiveQueued), ArgumentUnsigned(Entry.SendQueued), ArgumentText(@LocalText[0])]);
  if Selection.ShowOwners then
  begin
    FormatOwner(Entry, Processes, @OwnerText[0], SizeOf(OwnerText));
    WriteFormatted(StandardOutput, '%-23s %-11s %s'#10, [ArgumentText(@ForeignText[0]),
      ArgumentText(StateText(Entry)), ArgumentText(@OwnerText[0])]);
  end
  else if StateText(Entry)[0] = #0 then
    { No state: no padding at the end of the line. }
    WriteLine(StandardOutput, @ForeignText[0])
  else
    WriteFormatted(StandardOutput, '%-23s %s'#10, [ArgumentText(@ForeignText[0]), ArgumentText(StateText(Entry))]);
end;

procedure WriteEntriesOf(Protocol: Word; const Entries: TSocketInformationList;
  constref Selection: TNetstatSelection; const Processes: TProcessSnapshot);
var
  Index: Integer;
begin
  for Index := 0 to High(Entries) do
    if (Entries[Index].Protocol = Protocol) and EntryIsShown(Entries[Index], Selection) then
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
    FailWithError(1, Error, 'cannot read the list of sockets', []);
  InitializeProcessSnapshot(Processes);
  if Selection.ShowOwners then
  begin
    Error := TakeProcessSnapshot(Processes);
    if Error <> ErrorNone then
      ReportError(Error, 'cannot read the list of processes', []);
  end;
  WriteTitle(Selection);
  WriteEntriesOf(ProtocolTcp, Entries, Selection, Processes);
  WriteEntriesOf(ProtocolUdp, Entries, Selection, Processes);
  WriteEntriesOf(ProtocolIcmp, Entries, Selection, Processes);
  FreeProcessSnapshot(Processes);
end;

end.
