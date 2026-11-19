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
  The IPv6 addresses of the interfaces: adding and removing them,
  finding which interface has an address, the multicast groups an
  interface listens to, and choosing the source address of a datagram.

  A new address is tentative until duplicate address detection
  (Network.Ipv6Interfaces) found nobody else using it; a tentative
  address is not used and does not make datagrams for it ours, but its
  solicited-node group is listened to. A link-local or manual address
  brings the route to its prefix (on the link) with it.

  The source of a datagram (RFC 6724, simply): an address of the
  interface it leaves by, of the destination's scope (link-local for a
  link-local or link-scope multicast destination, else a global one),
  preferred before deprecated, then the one sharing the longest prefix
  with the destination. A global destination is never sent from a
  link-local address; with no global address on the interface, one of
  another interface is taken (the weak host model). Under the network
  lock.
}
unit Network.Ipv6AddressList;

{$mode objfpc}

interface

uses
  Network.Ipv6Addresses,
  Network.Ipv6Types,
  Network.Interfaces;

{ Adds an address to the interface, tentative (lo: at once preferred).
  An address the interface has already gets the new lifetimes (if it is
  an automatic one; ErrorExists otherwise). ErrorAddressInUse if another
  interface has it, ErrorNoSpace when the list is full. }
function AddIpv6Address(NetworkInterface: PNetworkInterface; constref Address: TIpv6Address;
  PrefixLength: LongWord; Origin: TIpv6AddressOrigin; ValidUntil, PreferredUntil: QWord): LongInt;
{ Removes an address (Why goes to the kernel log). }
procedure RemoveIpv6AddressEntry(NetworkInterface: PNetworkInterface; Entry: PIpv6InterfaceAddress; Why: PChar);
{ ErrorNotFound if the interface does not have Address. }
function RemoveIpv6Address(NetworkInterface: PNetworkInterface; constref Address: TIpv6Address): LongInt;
{ Removes the addresses of the given origins. }
procedure RemoveIpv6AddressesOf(NetworkInterface: PNetworkInterface; Origins: TIpv6AddressOrigins);
function FindIpv6Address(NetworkInterface: PNetworkInterface; constref Address: TIpv6Address): PIpv6InterfaceAddress;
{ The interface that has Address (a tentative one too if
  AcceptTentative); nil if none has. }
function FindInterfaceWithIpv6Address(constref Address: TIpv6Address; AcceptTentative: Boolean): PNetworkInterface;
{ ::1, or an address (not tentative) of any interface. }
function IsLocalIpv6Address(constref Address: TIpv6Address): Boolean;
{ True if the interface listens to the multicast Group: all-nodes, and
  the solicited-node group of each of its addresses. }
function InterfaceListensToIpv6Group(NetworkInterface: PNetworkInterface; constref Group: TIpv6Address): Boolean;
{ The interface's link-local address, if it has one that is ready. }
function FindLinkLocalAddress(NetworkInterface: PNetworkInterface; out Address: TIpv6Address): Boolean;
{ The source for a datagram to Destination leaving by NetworkInterface;
  False if there is no suitable address. }
function SelectIpv6Source(NetworkInterface: PNetworkInterface; constref Destination: TIpv6Address;
  out Source: TIpv6Address): Boolean;
{ True if the interface has an address (ready or not). }
function HasIpv6Addresses(NetworkInterface: PNetworkInterface): Boolean;
{ Writes "eth0: IPv6 address fec0::1/64 What" to the kernel log. }
procedure WriteIpv6AddressChange(NetworkInterface: PNetworkInterface; constref Address: TIpv6Address;
  PrefixLength: LongWord; What: PChar);

implementation

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Runtime.Text,
  Network.Core,
  Network.Ipv6Routing,
  Network.ChangeWatchers,
  Debug.Output;

const
  { Route metric of interface routes: before the default route. }
  InterfaceRouteMetric = 0;

procedure WriteIpv6AddressChange(NetworkInterface: PNetworkInterface; constref Address: TIpv6Address;
  PrefixLength: LongWord; What: PChar);
var
  Text: array[0..Ipv6AddressTextCapacity - 1] of Char;
begin
  FormatIpv6Address(Address, @Text[0]);
  DebugBeginMessage;
  DebugWriteTag('network');
  DebugWrite(@NetworkInterface^.Name[0]);
  DebugWrite(': IPv6 address ');
  DebugWrite(@Text[0]);
  DebugWrite('/');
  DebugWriteDecimal(PrefixLength);
  DebugWrite(' ');
  DebugWriteLine(What);
  DebugEndMessage;
end;

function FindIpv6Address(NetworkInterface: PNetworkInterface; constref Address: TIpv6Address): PIpv6InterfaceAddress;
var
  Index: Integer;
begin
  for Index := 0 to MaximumIpv6InterfaceAddresses - 1 do
  begin
    Result := @NetworkInterface^.Ipv6.Addresses[Index];
    if (Result^.State <> Ipv6AddressFree) and Ipv6AddressesEqual(Result^.Address, Address) then
      Exit;
  end;
  Result := nil;
end;

function FindInterfaceWithIpv6Address(constref Address: TIpv6Address; AcceptTentative: Boolean): PNetworkInterface;
var
  Position: Integer;
  Entry: PIpv6InterfaceAddress;
begin
  for Position := 0 to NetworkInterfaceCount - 1 do
  begin
    Result := NetworkInterfaceAt(Position);
    Entry := FindIpv6Address(Result, Address);
    if (Entry <> nil) and (AcceptTentative or (Entry^.State <> Ipv6AddressTentative)) then
      Exit;
  end;
  Result := nil;
end;

function IsLocalIpv6Address(constref Address: TIpv6Address): Boolean;
begin
  Result := IsLoopbackIpv6Address(Address) or (FindInterfaceWithIpv6Address(Address, False) <> nil);
end;

{ True if Origin's addresses bring the route to their prefix. }
function OriginBringsRoute(Origin: TIpv6AddressOrigin; PrefixLength: LongWord): Boolean;
begin
  Result := (Origin in [Ipv6OriginLinkLocal, Ipv6OriginManual]) and (PrefixLength < 128);
end;

{ True if another address of the interface (not Excluded) has the same
  prefix and brings its route. }
function PrefixRouteStillWanted(NetworkInterface: PNetworkInterface; Excluded: PIpv6InterfaceAddress): Boolean;
var
  Index: Integer;
  Other: PIpv6InterfaceAddress;
begin
  for Index := 0 to MaximumIpv6InterfaceAddresses - 1 do
  begin
    Other := @NetworkInterface^.Ipv6.Addresses[Index];
    if (Other <> Excluded) and (Other^.State <> Ipv6AddressFree) and
       OriginBringsRoute(Other^.Origin, Other^.PrefixLength) and (Other^.PrefixLength = Excluded^.PrefixLength) and
       SameIpv6Prefix(Other^.Address, Excluded^.Address, Excluded^.PrefixLength) then
      Exit(True);
  end;
  Result := False;
end;

function AddIpv6Address(NetworkInterface: PNetworkInterface; constref Address: TIpv6Address;
  PrefixLength: LongWord; Origin: TIpv6AddressOrigin; ValidUntil, PreferredUntil: QWord): LongInt;
var
  Entry: PIpv6InterfaceAddress;
  Owner: PNetworkInterface;
  Index: Integer;
begin
  if (PrefixLength > 128) or IsUnspecifiedIpv6Address(Address) or IsMulticastIpv6Address(Address) then
    Exit(ErrorInvalidArgument);
  if IsLoopbackIpv6Address(Address) and not NetworkInterface^.IsLoopback then
    Exit(ErrorInvalidArgument);
  Entry := FindIpv6Address(NetworkInterface, Address);
  if Entry <> nil then
  begin
    if Entry^.Origin <> Ipv6OriginAutomatic then
      Exit(ErrorExists);
    Entry^.ValidUntil := ValidUntil;
    Entry^.PreferredUntil := PreferredUntil;
    if (Entry^.State = Ipv6AddressDeprecated) and (PreferredUntil > NetworkNow) then
      Entry^.State := Ipv6AddressPreferred;
    if ValidUntil <> Ipv6Forever then
      RequestNetworkWakeAt(ValidUntil);
    Exit(ErrorNone);
  end;
  Owner := FindInterfaceWithIpv6Address(Address, True);
  if (Owner <> nil) and (Owner <> NetworkInterface) then
    Exit(ErrorAddressInUse);
  Entry := nil;
  for Index := 0 to MaximumIpv6InterfaceAddresses - 1 do
    if NetworkInterface^.Ipv6.Addresses[Index].State = Ipv6AddressFree then
    begin
      Entry := @NetworkInterface^.Ipv6.Addresses[Index];
      Break;
    end;
  if Entry = nil then
    Exit(ErrorNoSpace);
  FillMemory(Entry, SizeOf(TIpv6InterfaceAddress), 0);
  Entry^.Origin := Origin;
  Entry^.Address := Address;
  Entry^.PrefixLength := PrefixLength;
  Entry^.ValidUntil := ValidUntil;
  Entry^.PreferredUntil := PreferredUntil;
  Entry^.CreatedAt := NetworkNow;
  if NetworkInterface^.IsLoopback then
    Entry^.State := Ipv6AddressPreferred
  else
  begin
    { Detection begins on the next round of the timers. }
    Entry^.State := Ipv6AddressTentative;
    Entry^.DadDeadline := NetworkNow;
    RequestNetworkWakeAt(Entry^.DadDeadline);
  end;
  if ValidUntil <> Ipv6Forever then
    RequestNetworkWakeAt(ValidUntil);
  if OriginBringsRoute(Origin, PrefixLength) then
    AddIpv6Route(Address, PrefixLength, UnspecifiedIpv6Address, NetworkInterface, RouteFlagInterface,
      InterfaceRouteMetric, Ipv6Forever);
  if Entry^.State = Ipv6AddressTentative then
    WriteIpv6AddressChange(NetworkInterface, Address, PrefixLength, 'added (tentative)')
  else
    WriteIpv6AddressChange(NetworkInterface, Address, PrefixLength, 'added');
  NoteNetworkChange;
  Result := ErrorNone;
end;

procedure RemoveIpv6AddressEntry(NetworkInterface: PNetworkInterface; Entry: PIpv6InterfaceAddress; Why: PChar);
begin
  if OriginBringsRoute(Entry^.Origin, Entry^.PrefixLength) and not PrefixRouteStillWanted(NetworkInterface, Entry) then
    RemoveIpv6Route(Entry^.Address, Entry^.PrefixLength, UnspecifiedIpv6Address, NetworkInterface);
  WriteIpv6AddressChange(NetworkInterface, Entry^.Address, Entry^.PrefixLength, Why);
  Entry^.State := Ipv6AddressFree;
  NoteNetworkChange;
end;

function RemoveIpv6Address(NetworkInterface: PNetworkInterface; constref Address: TIpv6Address): LongInt;
var
  Entry: PIpv6InterfaceAddress;
begin
  Entry := FindIpv6Address(NetworkInterface, Address);
  if Entry = nil then
    Exit(ErrorNotFound);
  RemoveIpv6AddressEntry(NetworkInterface, Entry, 'removed');
  Result := ErrorNone;
end;

procedure RemoveIpv6AddressesOf(NetworkInterface: PNetworkInterface; Origins: TIpv6AddressOrigins);
var
  Index: Integer;
  Entry: PIpv6InterfaceAddress;
begin
  for Index := 0 to MaximumIpv6InterfaceAddresses - 1 do
  begin
    Entry := @NetworkInterface^.Ipv6.Addresses[Index];
    if (Entry^.State <> Ipv6AddressFree) and (Entry^.Origin in Origins) then
      RemoveIpv6AddressEntry(NetworkInterface, Entry, 'removed');
  end;
end;

function InterfaceListensToIpv6Group(NetworkInterface: PNetworkInterface; constref Group: TIpv6Address): Boolean;
var
  Index: Integer;
  Entry: PIpv6InterfaceAddress;
  Solicited: TIpv6Address;
begin
  if NetworkInterface^.Ipv6.Mode = Ipv6ModeOff then
    Exit(False);
  if Ipv6AddressesEqual(Group, AllNodesIpv6Address) then
    Exit(True);
  for Index := 0 to MaximumIpv6InterfaceAddresses - 1 do
  begin
    Entry := @NetworkInterface^.Ipv6.Addresses[Index];
    if Entry^.State = Ipv6AddressFree then
      Continue;
    Solicited := SolicitedNodeAddress(Entry^.Address);
    if Ipv6AddressesEqual(Group, Solicited) then
      Exit(True);
  end;
  Result := False;
end;

function FindLinkLocalAddress(NetworkInterface: PNetworkInterface; out Address: TIpv6Address): Boolean;
var
  Index: Integer;
  Entry: PIpv6InterfaceAddress;
begin
  Address := UnspecifiedIpv6Address;
  for Index := 0 to MaximumIpv6InterfaceAddresses - 1 do
  begin
    Entry := @NetworkInterface^.Ipv6.Addresses[Index];
    if (Entry^.State in [Ipv6AddressPreferred, Ipv6AddressDeprecated]) and
       IsLinkLocalIpv6Address(Entry^.Address) then
    begin
      Address := Entry^.Address;
      Exit(True);
    end;
  end;
  Result := False;
end;

{ True if Destination is reached within the link: link-local, or a
  multicast group of link (or smaller) scope. }
function HasLinkScope(constref Destination: TIpv6Address): Boolean;
begin
  Result := IsLinkLocalIpv6Address(Destination) or
    (IsMulticastIpv6Address(Destination) and ((Destination[1] and $0F) <= 2));
end;

{ How well Entry fits as the source for Destination; negative if it
  may not be used. }
function SourceScore(Entry: PIpv6InterfaceAddress; constref Destination: TIpv6Address): LongInt;
var
  DestinationIsLinkScope: Boolean;
begin
  if not (Entry^.State in [Ipv6AddressPreferred, Ipv6AddressDeprecated]) then
    Exit(-1);
  if Ipv6AddressesEqual(Entry^.Address, Destination) then
    Exit(100000);
  DestinationIsLinkScope := HasLinkScope(Destination);
  if not DestinationIsLinkScope and IsLinkLocalIpv6Address(Entry^.Address) then
    Exit(-1);
  Result := 0;
  if IsLinkLocalIpv6Address(Entry^.Address) = DestinationIsLinkScope then
    Result := Result + 1000;
  if Entry^.State = Ipv6AddressPreferred then
    Result := Result + 500;
  Result := Result + LongInt(CommonIpv6PrefixLength(Entry^.Address, Destination));
end;

{ The best address of one interface; False if it has none that fits. }
function BestSourceOn(NetworkInterface: PNetworkInterface; constref Destination: TIpv6Address;
  out Source: TIpv6Address; out Score: LongInt): Boolean;
var
  Index: Integer;
  Entry: PIpv6InterfaceAddress;
  EntryScore: LongInt;
begin
  Score := -1;
  Source := UnspecifiedIpv6Address;
  for Index := 0 to MaximumIpv6InterfaceAddresses - 1 do
  begin
    Entry := @NetworkInterface^.Ipv6.Addresses[Index];
    EntryScore := SourceScore(Entry, Destination);
    if EntryScore > Score then
    begin
      Score := EntryScore;
      Source := Entry^.Address;
    end;
  end;
  Result := Score >= 0;
end;

function SelectIpv6Source(NetworkInterface: PNetworkInterface; constref Destination: TIpv6Address;
  out Source: TIpv6Address): Boolean;
var
  Position: Integer;
  Candidate: PNetworkInterface;
  Score: LongInt;
begin
  if (NetworkInterface <> nil) and BestSourceOn(NetworkInterface, Destination, Source, Score) then
    Exit(True);
  if HasLinkScope(Destination) then
    Exit(False);
  for Position := 0 to NetworkInterfaceCount - 1 do
  begin
    Candidate := NetworkInterfaceAt(Position);
    if (Candidate <> NetworkInterface) and not Candidate^.IsLoopback and
       BestSourceOn(Candidate, Destination, Source, Score) then
      Exit(True);
  end;
  Result := False;
end;

function HasIpv6Addresses(NetworkInterface: PNetworkInterface): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to MaximumIpv6InterfaceAddresses - 1 do
    if NetworkInterface^.Ipv6.Addresses[Index].State <> Ipv6AddressFree then
      Exit(True);
  Result := False;
end;

end.
