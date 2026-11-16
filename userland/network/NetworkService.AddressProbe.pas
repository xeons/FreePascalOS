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
  Checking that an address a DHCP server offered is not in use already
  (RFC 2131 4.4.1, "the client SHOULD perform a check on the suggested
  address"; RFC 5227's probe).

  The kernel has the machinery: a datagram sent out of an interface to
  a neighbour it does not know makes it ask by ARP, and while the
  interface has no address yet that request carries 0.0.0.0 as its
  sender - exactly RFC 5227's probe, which disturbs no other host's
  cache. So the probe is an empty datagram to the discard port (9) of
  the address, sent on the DHCP client's socket (bound to the
  interface), and a second later the ARP cache tells whether anyone
  answered for the address. Nobody answering costs nothing more: the
  datagram is dropped after the kernel's three tries, and the error the
  kernel reports for it goes nowhere, as its sender is 0.0.0.0.
}
unit NetworkService.AddressProbe;

{$mode objfpc}
{$H+}

interface

uses
  Sys.InternetAddresses;

const
  ProbeWaitMilliseconds = 1000;

{ Sends the probe for Address out of Socket (bound to the interface). }
procedure SendAddressProbe(Socket: Int64; constref Address: TInternetAddress);
{ After ProbeWaitMilliseconds: True if a host on InterfaceName answered
  for Address. }
function AddressAnswered(const InterfaceName: string; constref Address: TInternetAddress): Boolean;

implementation

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Runtime.Text,
  Sys.Sockets,
  Sys.NetworkInterfaces;

const
  DiscardPort = 9;

procedure SendAddressProbe(Socket: Int64; constref Address: TInternetAddress);
var
  Nothing: Byte;
begin
  Nothing := 0;
  SendSocketTo(Socket, @Nothing, 0, SocketFlagDontWait, MakeSocketAddress(Address, DiscardPort));
end;

function AddressAnswered(const InterfaceName: string; constref Address: TInternetAddress): Boolean;
var
  Entries: TArpEntryList;
  Index: Integer;
begin
  Result := False;
  if ListArpEntries(Entries) <> ErrorNone then
    Exit;
  for Index := 0 to High(Entries) do
    if (Entries[Index].State = ArpStateReachable) and MemoryIsEqual(@Entries[Index].Address[0], @Address.Bytes[0], 4) and
       TextIsEqual(@Entries[Index].InterfaceName[0], PChar(InterfaceName)) then
      Exit(True);
end;

end.
