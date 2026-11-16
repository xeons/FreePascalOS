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
  The system's DNS servers and search domain. The kernel resolves no
  names; it keeps the list for the resolver in libsystem to read, as it
  keeps the time zone's name: one call finds it, and a change (the
  static configuration at start, later a DHCP client) reaches every
  program at once. Under its own spin lock.
}
unit Network.Dns;

{$mode objfpc}

interface

uses
  Abi.SystemCalls;

procedure GetDnsServers(out Servers: TAbiDnsServers);
{ ErrorInvalidArgument for more than MaximumDnsServers or an address of
  a family other than IPv4. }
function SetDnsServers(constref Servers: TAbiDnsServers): LongInt;

implementation

uses
  Runtime.Memory,
  Kernel.SpinLock,
  Kernel.PriorityLevel;

var
  { A zeroed spin lock is free; no servers at first. }
  DnsLock: TSpinLock;
  Current: TAbiDnsServers;

procedure GetDnsServers(out Servers: TAbiDnsServers);
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(DnsLock);
  Servers := Current;
  ReleaseSpinLock(DnsLock, PreviousLevel);
end;

function SetDnsServers(constref Servers: TAbiDnsServers): LongInt;
var
  Copy: TAbiDnsServers;
  Index: LongWord;
  PreviousLevel: TPriorityLevel;
begin
  if Servers.Count > MaximumDnsServers then
    Exit(ErrorInvalidArgument);
  FillMemory(@Copy, SizeOf(Copy), 0);
  Copy.Count := Servers.Count;
  Index := 0;
  while Index < Servers.Count do
  begin
    if (Servers.Servers[Index].Family <> AddressFamilyIPv4) and
       (Servers.Servers[Index].Family <> AddressFamilyIPv6) then
      Exit(ErrorInvalidArgument);
    Copy.Servers[Index] := Servers.Servers[Index];
    Inc(Index);
  end;
  CopyMemory(@Copy.SearchDomain[0], @Servers.SearchDomain[0], DnsDomainCapacity);
  Copy.SearchDomain[DnsDomainCapacity - 1] := #0;
  PreviousLevel := AcquireSpinLock(DnsLock);
  Current := Copy;
  ReleaseSpinLock(DnsLock, PreviousLevel);
  Result := ErrorNone;
end;

end.
