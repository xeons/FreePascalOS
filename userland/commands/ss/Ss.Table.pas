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
  ss's table of sockets, in iproute2's columns:

    Netid State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
    tcp   LISTEN 0      5      0.0.0.0:ssh        0.0.0.0:*

  Netid is left out when one kind of socket is asked for, State when
  one state is. Each column is as wide as its widest cell. IPv6
  addresses are in brackets ("[::1]:22"); ports are named unless -n,
  hosts only with -r (Netstat.Names). -p fills Process with
  users:(("nc",pid=412)); -e adds the owner's user id ("uid:0").
}
unit Ss.Table;

{$mode objfpc}
{$H+}

interface

uses
  Sys.NetworkInterfaces,
  Ss.Options;

procedure ShowSocketTable(const Entries: TSocketInformationList; constref Options: TSsOptions);

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.InternetAddresses,
  Sys.ProcessList,
  Sys.Streams,
  Util.Messages,
  Netstat.Names,
  Ss.Filters,
  Ss.Sockets;

type
  TColumn = (ColumnNetid, ColumnState, ColumnReceiveQueue, ColumnSendQueue, ColumnLocal, ColumnPeer,
    ColumnProcess);
  TRow = array[TColumn] of string;

const
  Headings: TRow = ('Netid', 'State', 'Recv-Q', 'Send-Q', 'Local Address:Port', 'Peer Address:Port', 'Process');

function CountSelectedNetids(constref Options: TSsOptions): Integer;
begin
  Result := Ord(Options.ShowTcp) + Ord(Options.ShowUdp) + Ord(Options.ShowRaw) + Ord(Options.ShowLocal);
end;

function CountStates(States: TSocketStates): Integer;
var
  State: TSocketState;
begin
  Result := 0;
  for State in States do
    Inc(Result);
end;

function EndpointCell(constref Address: TAbiSocketAddress; Protocol: Word; constref Options: TSsOptions): string;
var
  Host: TInternetAddress;
begin
  Host := SocketAddressHost(Address);
  Result := HostText(Host, not Options.ResolveHosts);
  if (Host.Family = AddressFamilyIPv6) and (Result = AddressToText(Host)) then
    Result := '[' + Result + ']';
  Result := Result + ':' + PortText(Address.Port, Protocol, Options.Numeric);
end;

function ProcessCell(constref Entry: TAbiSocketInformation; constref Options: TSsOptions;
  const Processes: TProcessSnapshot): string;
var
  Details: PProcessDetails;
  Name: string;
begin
  Result := '';
  if Options.ShowProcesses and (Entry.OwnerProcessId <> 0) then
  begin
    Name := '-';
    Details := FindProcessInSnapshot(Processes, Entry.OwnerProcessId);
    if Details <> nil then
      Name := StrPas(PChar(@Details^.Name[0]));
    Result := Format('users:(("%s",pid=%d))', [Name, Int64(Entry.OwnerProcessId)]);
  end;
  if Options.Extended then
  begin
    if Result <> '' then
      Result := Result + ' ';
    Result := Result + 'uid:' + IntToStr(Int64(Entry.OwnerUserId));
  end;
end;

function MakeRow(constref Entry: TAbiSocketInformation; constref Options: TSsOptions;
  const Processes: TProcessSnapshot): TRow;
begin
  Result[ColumnNetid] := NetidName(NetidOf(Entry));
  Result[ColumnState] := SocketStateName(SocketStateOf(Entry));
  Result[ColumnReceiveQueue] := IntToStr(QWord(Entry.ReceiveQueued));
  Result[ColumnSendQueue] := IntToStr(QWord(Entry.SendQueued));
  Result[ColumnLocal] := EndpointCell(Entry.LocalAddress, Entry.Protocol, Options);
  Result[ColumnPeer] := EndpointCell(Entry.PeerAddress, Entry.Protocol, Options);
  Result[ColumnProcess] := ProcessCell(Entry, Options, Processes);
end;

procedure WriteRow(constref Row: TRow; constref Widths: array of Integer; Shown: array of Boolean);
var
  Column, LastShown: TColumn;
  Line: string;
begin
  LastShown := ColumnNetid;
  for Column := Low(TColumn) to High(TColumn) do
    if Shown[Ord(Column)] then
      LastShown := Column;
  Line := '';
  for Column := Low(TColumn) to High(TColumn) do
  begin
    if not Shown[Ord(Column)] then
      Continue;
    if Column = LastShown then
      Line := Line + Row[Column]
    else
      Line := Line + Row[Column] + StringOfChar(' ', Widths[Ord(Column)] - Length(Row[Column]) + 1);
  end;
  PrintStringLine(TrimRight(Line));
end;

procedure ShowSocketTable(const Entries: TSocketInformationList; constref Options: TSsOptions);
var
  Rows: array of TRow;
  Widths: array[0..Ord(High(TColumn))] of Integer;
  Shown: array[0..Ord(High(TColumn))] of Boolean;
  Processes: TProcessSnapshot;
  Column: TColumn;
  Index: Integer;
  Error: LongInt;
begin
  InitializeProcessSnapshot(Processes);
  try
    if Options.ShowProcesses then
    begin
      Error := TakeProcessSnapshot(Processes);
      if Error <> ErrorNone then
        ReportError(Error, 'cannot read the list of processes');
    end;
    SetLength(Rows, Length(Entries));
    for Index := 0 to High(Entries) do
      Rows[Index] := MakeRow(Entries[Index], Options, Processes);
  finally
    FreeProcessSnapshot(Processes);
  end;

  for Column := Low(TColumn) to High(TColumn) do
    Shown[Ord(Column)] := True;
  Shown[Ord(ColumnNetid)] := CountSelectedNetids(Options) > 1;
  Shown[Ord(ColumnState)] := CountStates(ShownStates(Options)) > 1;
  for Column := Low(TColumn) to High(TColumn) do
  begin
    Widths[Ord(Column)] := Length(Headings[Column]);
    for Index := 0 to High(Rows) do
      if Length(Rows[Index][Column]) > Widths[Ord(Column)] then
        Widths[Ord(Column)] := Length(Rows[Index][Column]);
  end;
  if not Options.NoHeader then
    WriteRow(Headings, Widths, Shown);
  for Index := 0 to High(Rows) do
    WriteRow(Rows[Index], Widths, Shown);
end;

end.
