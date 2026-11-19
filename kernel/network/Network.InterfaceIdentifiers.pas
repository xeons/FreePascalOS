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
  The 64-bit interface identifiers of SLAAC addresses other than the
  modified EUI-64 one (Network.Ipv6Addresses):

  - stable-privacy (RFC 7217): the first 64 bits of
      SHA-256(Prefix | Net_Iface | Network_ID | DAD_Counter | secret_key)
    with the prefix's 64 bits, the interface's Ethernet address as
    Net_Iface, no Network_ID, the DAD counter as one byte and the
    secret. The same on one network for ever, different on each, and
    not derived from the hardware address alone;
  - temporary (RFC 8981 3.3.1): 64 random bits.

  Either way an identifier RFC 5453 reserves (the subnet-router anycast
  0, the IANA Ethernet block 0200:5eff:fe00::/40, the subnet anycast
  fdff:ffff:ffff:ff80 and up) is not used: the stable one is made again
  with the next DAD counter, the temporary one from new random bits.
  Self-contained, so the host tests use it as it is.
}
unit Network.InterfaceIdentifiers;

{$mode objfpc}
{$pointermath on}

interface

const
  InterfaceIdentifierBytes = 8;
  { How often a stable identifier is made again after a duplicate
    (RFC 7217 IDGEN_RETRIES). }
  StableIdentifierRetries = 3;

type
  TInterfaceIdentifier = array[0..InterfaceIdentifierBytes - 1] of Byte;

{ True for an identifier RFC 5453 reserves. }
function IsReservedInterfaceIdentifier(constref Identifier: TInterfaceIdentifier): Boolean;
{ RFC 7217's identifier for the 64-bit Prefix (its first eight bytes),
  the interface (NetworkInterface, NetworkInterfaceLength bytes; the
  Ethernet address), the network (NetworkId, may be nil with length 0)
  and DadCounter, with Secret. Reserved results are skipped by counting
  DadCounter on. }
function MakeStableInterfaceIdentifier(Prefix: PByte; NetworkInterface: PByte; NetworkInterfaceLength: LongWord;
  NetworkId: PByte; NetworkIdLength: LongWord; DadCounter: Byte; Secret: PByte;
  SecretLength: LongWord): TInterfaceIdentifier;
{ A temporary identifier from 64 random bits; False if they make a
  reserved one (the caller draws again). }
function MakeTemporaryInterfaceIdentifier(RandomBits: QWord; out Identifier: TInterfaceIdentifier): Boolean;

implementation

uses
  Network.Sha256;

function IsReservedInterfaceIdentifier(constref Identifier: TInterfaceIdentifier): Boolean;
var
  Index: Integer;
  AllZero: Boolean;
  SubnetAnycast: Boolean;
begin
  AllZero := True;
  for Index := 0 to InterfaceIdentifierBytes - 1 do
    if Identifier[Index] <> 0 then
      AllZero := False;
  if AllZero then
    Exit(True);
  if (Identifier[0] = $02) and (Identifier[1] = $00) and (Identifier[2] = $5E) and (Identifier[3] = $FF) and
     (Identifier[4] = $FE) then
    Exit(True);
  SubnetAnycast := (Identifier[0] = $FD) and (Identifier[7] >= $80);
  for Index := 1 to 6 do
    if Identifier[Index] <> $FF then
      SubnetAnycast := False;
  Result := SubnetAnycast;
end;

function HashIdentifier(Prefix: PByte; NetworkInterface: PByte; NetworkInterfaceLength: LongWord;
  NetworkId: PByte; NetworkIdLength: LongWord; DadCounter: Byte; Secret: PByte;
  SecretLength: LongWord): TInterfaceIdentifier;
var
  Context: TSha256Context;
  Digest: TSha256Digest;
  Index: Integer;
begin
  BeginSha256(Context);
  AddToSha256(Context, Prefix, InterfaceIdentifierBytes);
  if NetworkInterfaceLength > 0 then
    AddToSha256(Context, NetworkInterface, NetworkInterfaceLength);
  if NetworkIdLength > 0 then
    AddToSha256(Context, NetworkId, NetworkIdLength);
  AddToSha256(Context, @DadCounter, 1);
  if SecretLength > 0 then
    AddToSha256(Context, Secret, SecretLength);
  FinishSha256(Context, Digest);
  for Index := 0 to InterfaceIdentifierBytes - 1 do
    Result[Index] := Digest[Index];
end;

function MakeStableInterfaceIdentifier(Prefix: PByte; NetworkInterface: PByte; NetworkInterfaceLength: LongWord;
  NetworkId: PByte; NetworkIdLength: LongWord; DadCounter: Byte; Secret: PByte;
  SecretLength: LongWord): TInterfaceIdentifier;
var
  Counter: Byte;
begin
  Counter := DadCounter;
  repeat
    Result := HashIdentifier(Prefix, NetworkInterface, NetworkInterfaceLength, NetworkId, NetworkIdLength, Counter,
      Secret, SecretLength);
    Counter := Byte(Counter + 1);
  until not IsReservedInterfaceIdentifier(Result) or (Counter = DadCounter);
end;

function MakeTemporaryInterfaceIdentifier(RandomBits: QWord; out Identifier: TInterfaceIdentifier): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to InterfaceIdentifierBytes - 1 do
    Identifier[Index] := Byte(RandomBits shr (Index * 8));
  Result := not IsReservedInterfaceIdentifier(Identifier);
end;

end.
