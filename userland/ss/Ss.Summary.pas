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
  ss -s: the sockets counted, as iproute2 shows them.

    Total: 6
    TCP:   3 (estab 1, closed 0, orphaned 0, timewait 0)

    Transport Total     IP        IPv6
    RAW       0         0         0
    UDP       2         1         1
    TCP       3         2         1
    INET      5         3         2
    FRAG      0         0         0

  Orphaned are connections whose socket is gone (no owner left). No
  fragments are kept between reassemblies, so FRAG is 0.
}
unit Ss.Summary;

{$mode objfpc}
{$H+}

interface

uses
  Sys.NetworkInterfaces;

procedure ShowSocketSummary(const Entries: TSocketInformationList);

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Streams,
  Ss.Sockets;

type
  TFamilyCounts = record
    Total, Ipv4, Ipv6: Integer;
  end;

procedure CountEntry(var Counts: TFamilyCounts; constref Entry: TAbiSocketInformation);
begin
  Inc(Counts.Total);
  if Entry.Family = AddressFamilyIPv6 then
    Inc(Counts.Ipv6)
  else
    Inc(Counts.Ipv4);
end;

procedure WriteCounts(const Name: string; constref Counts: TFamilyCounts);
begin
  PrintString(Format('%-9s %-9d %-9d %d'#10, [Name, Counts.Total, Counts.Ipv4, Counts.Ipv6]));
end;

procedure ShowSocketSummary(const Entries: TSocketInformationList);
var
  Counts: array[TNetid] of TFamilyCounts;
  Inet: TFamilyCounts;
  Established, Closed, Orphaned, TimeWait: Integer;
  Index: Integer;
  Netid: TNetid;
begin
  Counts[NetidTcp] := Default(TFamilyCounts);
  Counts[NetidUdp] := Default(TFamilyCounts);
  Counts[NetidRaw] := Default(TFamilyCounts);
  Inet := Default(TFamilyCounts);
  Established := 0;
  Closed := 0;
  Orphaned := 0;
  TimeWait := 0;
  for Index := 0 to High(Entries) do
  begin
    Netid := NetidOf(Entries[Index]);
    CountEntry(Counts[Netid], Entries[Index]);
    CountEntry(Inet, Entries[Index]);
    if Netid <> NetidTcp then
      Continue;
    case Entries[Index].State of
      TcpStateEstablished: Inc(Established);
      TcpStateClosed: Inc(Closed);
      TcpStateTimeWait: Inc(TimeWait);
    end;
    if Entries[Index].OwnerProcessId = 0 then
      Inc(Orphaned);
  end;
  PrintString(Format('Total: %d'#10, [Length(Entries)]));
  PrintString(Format('TCP:   %d (estab %d, closed %d, orphaned %d, timewait %d)'#10#10,
    [Counts[NetidTcp].Total, Established, Closed, Orphaned, TimeWait]));
  PrintStringLine('Transport Total     IP        IPv6');
  WriteCounts('RAW', Counts[NetidRaw]);
  WriteCounts('UDP', Counts[NetidUdp]);
  WriteCounts('TCP', Counts[NetidTcp]);
  WriteCounts('INET', Inet);
  PrintStringLine('FRAG      0         0         0');
end;

end.
