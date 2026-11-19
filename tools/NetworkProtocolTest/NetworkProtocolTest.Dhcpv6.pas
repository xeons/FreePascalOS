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
  The DHCPv6 client's messages on the host (RFC 8415): DUIDs (11.2 and
  11.4), a Solicit and a Request byte for byte as sections 8, 21.2,
  21.4, 21.6, 21.7, 21.9 and 21.13 lay them out, an Advertise and
  Replies read back (preference, IA_NA with its address and lifetimes,
  status codes at both levels, DNS servers of RFC 3646, the domain
  search list, the information refresh time of RFC 8415 21.23), damaged
  messages refused, and T1 and T2 worked out when the server leaves them
  to the client (21.4).
}
unit NetworkProtocolTest.Dhcpv6;

{$mode objfpc}
{$H+}

interface

procedure RunDhcpv6Checks;

implementation

uses
  SysUtils,
  TestChecks,
  Sys.InternetAddresses,
  NetworkService.Dhcpv6Messages;

const
  ClientHardware: array[0..5] of Byte = ($00, $11, $22, $33, $44, $55);
  ServerHardware: array[0..5] of Byte = ($AA, $BB, $CC, $DD, $EE, $FF);
  { 2000-01-01 plus $12345678 seconds. }
  DuidTime = Int64(946684800) + $12345678;
  ClientDuidHex = '0001 0001 12345678 001122334455';
  ServerDuidHex = '0003 0001 aabbccddeeff';
  IaId = $33445566;

function HexBytes(const Hex: string): TBytes;
var
  Data: TByteArray;
begin
  Data := HexToBytes(Hex);
  Result := nil;
  SetLength(Result, Length(Data));
  if Length(Data) > 0 then
    Move(Data[0], Result[0], Length(Data));
end;

function Ipv6(const Hex: string): TInternetAddress;
var
  Data: TByteArray;
begin
  Data := HexToBytes(Hex);
  Result := AnyIpv6Address;
  Move(Data[0], Result.Bytes[0], 16);
end;

procedure CheckDuids;
var
  Duid: TBytes;
  Parsed: TBytes;
begin
  Duid := MakeLinkLayerTimeDuid(ClientHardware, DuidTime);
  CheckBytes(@Duid[0], Length(Duid), ClientDuidHex,
    'DUID-LLT: type 1, hardware type 1, seconds since 2000, the Ethernet address');
  Duid := MakeLinkLayerDuid(ServerHardware);
  CheckBytes(@Duid[0], Length(Duid), ServerDuidHex, 'DUID-LL: type 3, hardware type 1, the Ethernet address');
  Check(BytesToColonHex(Duid) = '00:03:00:01:aa:bb:cc:dd:ee:ff', 'DUID: written as colon-separated hex');
  Check(ColonHexToBytes('00:03:00:01:aa:bb:cc:dd:ee:ff', Parsed) and SameBytes(Parsed, Duid),
    'DUID: read back from its text');
  Check(not ColonHexToBytes('00:03:0g', Parsed) and not ColonHexToBytes('', Parsed),
    'DUID: text that is not hex is refused');
  Check(IsUsableClientDuid(MakeLinkLayerTimeDuid(ClientHardware, DuidTime)) and IsUsableClientDuid(Duid) and
    not IsUsableClientDuid(HexBytes('0002 00000009 0102')), 'DUID: LLT and LL kept, an enterprise DUID not');
end;

procedure CheckSolicit;
var
  Message: TDhcpv6ClientMessage;
  Bytes: TBytes;
begin
  Message := Default(TDhcpv6ClientMessage);
  Message.Kind := Dhcpv6Solicit;
  Message.TransactionId := $ABCDEF;
  Message.ClientId := HexBytes(ClientDuidHex);
  Message.HasIdentityAssociation := True;
  Message.IdentityAssociation.IaId := IaId;
  Message.RequestedOptions := [Dhcpv6OptionDnsServers, Dhcpv6OptionDomainList];
  Bytes := BuildDhcpv6Message(Message);
  CheckBytes(@Bytes[0], Length(Bytes),
    '01 abcdef' +
    '0001 000e' + ClientDuidHex +
    '0008 0002 0000' +
    '0006 0004 0017 0018' +
    '0003 000c 33445566 00000000 00000000',
    'Solicit: type, transaction id, client id, elapsed time, option request, IA_NA');
end;

procedure CheckRequest;
var
  Message: TDhcpv6ClientMessage;
  Bytes: TBytes;
begin
  Message := Default(TDhcpv6ClientMessage);
  Message.Kind := Dhcpv6Request;
  Message.TransactionId := $123456;
  Message.ClientId := HexBytes(ClientDuidHex);
  Message.ServerId := HexBytes(ServerDuidHex);
  Message.ElapsedHundredths := 100;
  Message.HasIdentityAssociation := True;
  Message.IdentityAssociation.IaId := IaId;
  SetLength(Message.IdentityAssociation.Addresses, 1);
  Message.IdentityAssociation.Addresses[0] := Default(TDhcpv6LeasedAddress);
  Message.IdentityAssociation.Addresses[0].Address := Ipv6('20010db8000000000000000000000100');
  Message.RequestedOptions := [Dhcpv6OptionDnsServers];
  Bytes := BuildDhcpv6Message(Message);
  CheckBytes(@Bytes[0], Length(Bytes),
    '03 123456' +
    '0001 000e' + ClientDuidHex +
    '0002 000a' + ServerDuidHex +
    '0008 0002 0064' +
    '0006 0002 0017' +
    '0003 0028 33445566 00000000 00000000' +
    '0005 0018 20010db8000000000000000000000100 00000000 00000000',
    'Request: the server id, an elapsed second, the IA_NA with the address asked for');
end;

const
  AdvertiseHex =
    '02 abcdef' +
    '0001 000e' + ClientDuidHex +
    '0002 000a' + ServerDuidHex +
    '0007 0001 0a' +
    '0003 0028 33445566 00000e10 00001518' +
    '0005 0018 20010db8000000000000000000000100 00001c20 00002a30' +
    '0017 0010 20010db8000000000000000000000053' +
    '0018 000d 07 6578616d706c65 03 6f7267 00';

procedure ParseHex(const Hex: string; out Message: TDhcpv6ServerMessage; out Parsed: Boolean);
var
  Data: TByteArray;
begin
  Data := HexToBytes(Hex);
  Parsed := ParseDhcpv6Message(@Data[0], Length(Data), Message);
end;

procedure CheckAdvertise;
var
  Message: TDhcpv6ServerMessage;
  Parsed: Boolean;
  Association: TDhcpv6IdentityAssociation;
begin
  ParseHex(AdvertiseHex, Message, Parsed);
  Check(Parsed and (Message.Kind = Dhcpv6Advertise) and (Message.TransactionId = $ABCDEF),
    'Advertise: type and transaction id');
  Check(SameBytes(Message.ClientId, HexBytes(ClientDuidHex)) and SameBytes(Message.ServerId, HexBytes(ServerDuidHex)),
    'Advertise: client and server DUIDs');
  Check(Message.Preference = 10, 'Advertise: preference 10');
  Check(FindIdentityAssociation(Message, IaId, Association) and (Association.T1 = 3600) and
    (Association.T2 = 5400) and not Association.HasStatus, 'Advertise: the IA_NA with T1 3600 and T2 5400');
  Check((Length(Association.Addresses) = 1) and
    AddressesAreEqual(Association.Addresses[0].Address, Ipv6('20010db8000000000000000000000100')) and
    (Association.Addresses[0].PreferredSeconds = 7200) and (Association.Addresses[0].ValidSeconds = 10800),
    'Advertise: 2001:db8::100, preferred 7200 s, valid 10800 s');
  Check((Length(Message.DnsServers) = 1) and
    AddressesAreEqual(Message.DnsServers[0], Ipv6('20010db8000000000000000000000053')),
    'Advertise: the DNS server (option 23)');
  Check((Length(Message.Domains) = 1) and (Message.Domains[0] = 'example.org'),
    'Advertise: the domain search list (option 24)');
  Check(not FindIdentityAssociation(Message, IaId + 1, Association), 'Advertise: another IAID is not found');
end;

procedure CheckReplies;
var
  Message: TDhcpv6ServerMessage;
  Parsed: Boolean;
  Association: TDhcpv6IdentityAssociation;
begin
  ParseHex('07 123456' + '0001 000e' + ClientDuidHex + '0002 000a' + ServerDuidHex +
    '0003 0016 33445566 00000000 00000000 000d 0006 0002 6e6f6e65', Message, Parsed);
  Check(Parsed and (Message.Kind = Dhcpv6Reply) and FindIdentityAssociation(Message, IaId, Association) and
    Association.HasStatus and (Association.StatusCode = Dhcpv6StatusNoAddressesAvailable) and
    (Association.StatusMessage = 'none') and (Length(Association.Addresses) = 0),
    'Reply: NoAddrsAvail inside the IA_NA, with its message');
  ParseHex('07 123456' + '0001 000e' + ClientDuidHex + '0002 000a' + ServerDuidHex + '000d 0002 0005',
    Message, Parsed);
  Check(Parsed and Message.HasStatus and (Message.StatusCode = Dhcpv6StatusUseMulticast) and
    (Dhcpv6StatusName(Message.StatusCode) = 'UseMulticast'), 'Reply: a status for the whole message');
  ParseHex('07 000001' + '0002 000a' + ServerDuidHex +
    '0017 0020 20010db8000000000000000000000053 20010db8000000000000000000000054' +
    '0018 001a 07 6578616d706c65 03 6f7267 00 03 6c6162 07 6578616d706c65 00' +
    '0020 0004 00000258', Message, Parsed);
  Check(Parsed and (Length(Message.ClientId) = 0) and (Length(Message.DnsServers) = 2) and
    (Length(Message.Domains) = 2) and (Message.Domains[1] = 'lab.example') and Message.HasInformationRefreshTime and
    (Message.InformationRefreshSeconds = 600), 'Reply to an information-request: DNS servers, domains, refresh time');
  ParseHex('07 123456' + '0003 0028 33445566 00000000 00000000' +
    '0005 0018 20010db8000000000000000000000100 00000000 00000000', Message, Parsed);
  Check(Parsed and FindIdentityAssociation(Message, IaId, Association) and
    (Association.Addresses[0].ValidSeconds = 0), 'Reply: an address with valid lifetime 0 is read (to be dropped)');
end;

procedure CheckDamaged;
var
  Message: TDhcpv6ServerMessage;
  Parsed: Boolean;
begin
  ParseHex('02 abcdef 0001 00ff 0001', Message, Parsed);
  Check(not Parsed, 'damaged: an option longer than the message');
  ParseHex('02 abcdef 0003 0010 33445566 00000000 00000000 0005 0018 2001', Message, Parsed);
  Check(not Parsed, 'damaged: an address option running out of its IA_NA');
  ParseHex('02 abcdef 0017 000f 20010db800000000000000000000005', Message, Parsed);
  Check(not Parsed, 'damaged: DNS servers not a multiple of 16 bytes');
  ParseHex('02 abcdef 0018 0006 03 6c6162 c00c', Message, Parsed);
  Check(not Parsed, 'damaged: a compressed name in the domain list (RFC 8415 10)');
  ParseHex('02 abcdef 0018 0004 03 6c6162', Message, Parsed);
  Check(not Parsed, 'damaged: a name without its final zero');
  ParseHex('01 abcdef 0001 000e' + ClientDuidHex, Message, Parsed);
  Check(not Parsed, 'a client''s message (Solicit) is not taken as a server''s');
  ParseHex('07 12', Message, Parsed);
  Check(not Parsed, 'damaged: shorter than the header');
  ParseHex('07 123456 0007 0002 0a0a', Message, Parsed);
  Check(not Parsed, 'damaged: a preference of two bytes');
end;

function AddressWithLifetimes(Preferred, Valid: LongWord): TDhcpv6LeasedAddress;
begin
  Result := Default(TDhcpv6LeasedAddress);
  Result.Address := Ipv6('20010db8000000000000000000000100');
  Result.PreferredSeconds := Preferred;
  Result.ValidSeconds := Valid;
end;

procedure CheckRenewalTimes;
var
  Association: TDhcpv6IdentityAssociation;
  Addresses: TDhcpv6LeasedAddresses;
  Renew: LongWord;
  Rebind: LongWord;
begin
  Association := Default(TDhcpv6IdentityAssociation);
  Addresses := nil;
  SetLength(Addresses, 2);
  Addresses[0] := AddressWithLifetimes(7200, 10800);
  Addresses[1] := AddressWithLifetimes(3600, 10800);
  Dhcpv6RenewalTimes(Association, Addresses, Renew, Rebind);
  Check((Renew = 1800) and (Rebind = 2880), 'T1, T2 of 0: half and four fifths of the shortest preferred lifetime');
  Association.T1 := 1000;
  Association.T2 := 2000;
  Dhcpv6RenewalTimes(Association, Addresses, Renew, Rebind);
  Check((Renew = 1000) and (Rebind = 2000), 'T1 and T2 the server gave are kept');
  Association.T1 := 3000;
  Dhcpv6RenewalTimes(Association, Addresses, Renew, Rebind);
  Check((Renew = 1800) and (Rebind = 2880), 'T1 above T2: both worked out instead');
  Association.T1 := 0;
  Association.T2 := 0;
  Addresses[0] := AddressWithLifetimes(Dhcpv6Infinity, Dhcpv6Infinity);
  Addresses[1] := AddressWithLifetimes(Dhcpv6Infinity, Dhcpv6Infinity);
  Dhcpv6RenewalTimes(Association, Addresses, Renew, Rebind);
  Check((Renew = Dhcpv6Infinity) and (Rebind = Dhcpv6Infinity), 'endless addresses: never renewed');
end;

procedure RunDhcpv6Checks;
begin
  CheckDuids;
  CheckSolicit;
  CheckRequest;
  CheckAdvertise;
  CheckReplies;
  CheckDamaged;
  CheckRenewalTimes;
end;

end.
