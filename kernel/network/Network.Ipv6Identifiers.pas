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
  The addresses an interface makes for itself: the link-local one and
  one for each 64-bit prefix routers advertise (SLAAC), with a
  stable-privacy identifier (RFC 7217, Network.InterfaceIdentifiers) or,
  with Ipv6OptionEui64Identifiers, the modified EUI-64 one; and
  temporary addresses (RFC 8981) with random identifiers.

  The secret of the stable identifiers is the network service's: it
  keeps one in a file and hands it over at start
  (InterfaceChangeStableSecret), so an interface has the same addresses
  on the same network after every restart. Until then a random one made
  at the first use stands in. Under the network lock.
}
unit Network.Ipv6Identifiers;

{$mode objfpc}

interface

uses
  Abi.SystemCalls,
  Network.Ipv6Addresses,
  Network.Interfaces;

{ fe80::/64 with the interface's identifier. }
function LinkLocalAddressOf(NetworkInterface: PNetworkInterface): TIpv6Address;
{ The prefix (its first 64 bits) with the interface's identifier. }
function SlaacAddressOf(NetworkInterface: PNetworkInterface; constref Prefix: TIpv6Address): TIpv6Address;
{ The prefix with a new random identifier. }
function TemporaryAddressFor(constref Prefix: TIpv6Address): TIpv6Address;
{ The interface makes stable-privacy identifiers (not EUI-64 ones). }
function UsesStableIdentifiers(NetworkInterface: PNetworkInterface): Boolean;
{ Takes a new secret (StableSecretBytes at Secret); True if it differs
  from the one in use. }
function ReplaceStableSecret(Secret: PByte): Boolean;

implementation

uses
  Runtime.Memory,
  Io.NetworkAdapters,
  Network.InterfaceIdentifiers,
  Kernel.Random;

var
  StableSecret: array[0..StableSecretBytes - 1] of Byte;
  StableSecretIsReady: Boolean;

procedure EnsureStableSecret;
begin
  if StableSecretIsReady then
    Exit;
  FillRandom(@StableSecret[0], StableSecretBytes);
  StableSecretIsReady := True;
end;

function ReplaceStableSecret(Secret: PByte): Boolean;
begin
  EnsureStableSecret;
  Result := not MemoryIsEqual(@StableSecret[0], Secret, StableSecretBytes);
  CopyMemory(@StableSecret[0], Secret, StableSecretBytes);
end;

function UsesStableIdentifiers(NetworkInterface: PNetworkInterface): Boolean;
begin
  Result := (NetworkInterface^.Ipv6.Options and Ipv6OptionEui64Identifiers) = 0;
end;

procedure PutIdentifier(var Address: TIpv6Address; constref Identifier: TInterfaceIdentifier);
var
  Index: Integer;
begin
  for Index := 0 to InterfaceIdentifierBytes - 1 do
    Address[8 + Index] := Identifier[Index];
end;

function SlaacAddressOf(NetworkInterface: PNetworkInterface; constref Prefix: TIpv6Address): TIpv6Address;
var
  Identifier: TInterfaceIdentifier;
begin
  if not UsesStableIdentifiers(NetworkInterface) then
    Exit(AddressFromInterfaceIdentifier(Prefix, NetworkInterface^.HardwareAddress));
  EnsureStableSecret;
  Result := Ipv6PrefixOf(Prefix, 64);
  Identifier := MakeStableInterfaceIdentifier(@Result[0], @NetworkInterface^.HardwareAddress[0],
    EthernetAddressLength, nil, 0, NetworkInterface^.Ipv6.StableDadCounter, @StableSecret[0], StableSecretBytes);
  PutIdentifier(Result, Identifier);
end;

function LinkLocalAddressOf(NetworkInterface: PNetworkInterface): TIpv6Address;
var
  Prefix: TIpv6Address;
begin
  Prefix := UnspecifiedIpv6Address;
  Prefix[0] := $FE;
  Prefix[1] := $80;
  Result := SlaacAddressOf(NetworkInterface, Prefix);
end;

function TemporaryAddressFor(constref Prefix: TIpv6Address): TIpv6Address;
var
  Identifier: TInterfaceIdentifier;
  IsUsable: Boolean;
begin
  Result := Ipv6PrefixOf(Prefix, 64);
  repeat
    IsUsable := MakeTemporaryInterfaceIdentifier(RandomQWord, Identifier);
  until IsUsable;
  PutIdentifier(Result, Identifier);
end;

end.
