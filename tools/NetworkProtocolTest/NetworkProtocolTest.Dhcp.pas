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
  The DHCPv4 client's messages on the host: replies whose options go on
  in the file and server name fields (option overload, RFC 2131 4.1 and
  RFC 2132 9.3), and the choice among several offers.
}
unit NetworkProtocolTest.Dhcp;

{$mode objfpc}
{$H+}

interface

procedure RunDhcpChecks;

implementation

uses
  SysUtils,
  TestChecks,
  Sys.InternetAddresses,
  NetworkService.DhcpMessages,
  NetworkService.DhcpOffers;

const
  ClientHardware: TEthernetAddress = ($52, $54, $00, $12, $34, $56);
  ServerNameOffset = 44;
  FileOffset = 108;
  OptionsOffset = 240;

type
  TReplyBytes = array[0..575] of Byte;

{ A BOOTREPLY for ClientHardware offering 192.168.1.50, transaction
  $11223344, with the magic cookie; the options are the caller's. }
procedure BeginReply(out Bytes: TReplyBytes);
const
  Cookie: array[0..3] of Byte = (99, 130, 83, 99);
begin
  FillChar(Bytes, SizeOf(Bytes), 0);
  Bytes[0] := 2;
  Bytes[1] := 1;
  Bytes[2] := 6;
  Bytes[4] := $11;
  Bytes[5] := $22;
  Bytes[6] := $33;
  Bytes[7] := $44;
  Bytes[16] := 192;
  Bytes[17] := 168;
  Bytes[18] := 1;
  Bytes[19] := 50;
  Move(ClientHardware[0], Bytes[28], 6);
  Move(Cookie[0], Bytes[236], 4);
end;

procedure PutHex(var Bytes: TReplyBytes; Offset: Integer; const Hex: string);
var
  Data: TByteArray;
begin
  Data := HexToBytes(Hex);
  Move(Data[0], Bytes[Offset], Length(Data));
end;

procedure CheckPlainReply;
var
  Bytes: TReplyBytes;
  Reply: TDhcpReply;
begin
  BeginReply(Bytes);
  { The server name field holds a name, which looks like options. }
  PutHex(Bytes, ServerNameOffset, '01 04 0a 0a 0a 0a 06 04 01 02 03 04 ff');
  PutHex(Bytes, OptionsOffset, '35 01 02 01 04 ffffff00 03 04 c0a80101 33 04 00000e10 36 04 c0a80101 ff');
  Check(ParseDhcpReply(@Bytes[0], 300, ClientHardware, Reply) and (Reply.Kind = DhcpOffer) and
    (Reply.TransactionId = $11223344) and AddressesAreEqual(Reply.YourAddress, Ipv4Address(192, 168, 1, 50)),
    'DHCP: an offer is read');
  Check((Reply.Overload = 0) and Reply.HasSubnetMask and (Reply.PrefixLength = 24) and
    (Length(Reply.DnsServers) = 0), 'DHCP: without option 52 the server name field is not read as options');
  Check(Reply.HasLeaseTime and (Reply.LeaseSeconds = 3600) and Reply.HasServerIdentifier and
    (Length(Reply.Routers) = 1), 'DHCP: lease, server and router');
end;

procedure CheckOverloadBoth;
var
  Bytes: TReplyBytes;
  Reply: TDhcpReply;
begin
  BeginReply(Bytes);
  { Options field: the type and the overload (3: both fields). }
  PutHex(Bytes, OptionsOffset, '35 01 05 34 01 03 ff');
  { The file field first: mask, router, domain name. }
  PutHex(Bytes, FileOffset, '01 04 ffff0000 03 04 c0a80101 0f 0b 6578616d706c652e6f7267 ff');
  { Then the server name field: DNS servers, lease, server id. }
  PutHex(Bytes, ServerNameOffset, '06 08 08080808 08080404 33 04 00015180 36 04 c0a80102 ff');
  Check(ParseDhcpReply(@Bytes[0], 300, ClientHardware, Reply) and (Reply.Kind = DhcpAcknowledge) and
    (Reply.Overload = 3), 'overload: option 52 with both fields');
  Check(Reply.HasSubnetMask and (Reply.PrefixLength = 16) and (Length(Reply.Routers) = 1) and
    AddressesAreEqual(Reply.Routers[0], Ipv4Address(192, 168, 1, 1)), 'overload: mask and router from the file field');
  Check(Reply.DomainName = 'example.org', 'overload: the domain name from the file field');
  Check((Length(Reply.DnsServers) = 2) and AddressesAreEqual(Reply.DnsServers[1], Ipv4Address(8, 8, 4, 4)) and
    Reply.HasLeaseTime and (Reply.LeaseSeconds = 86400) and Reply.HasServerIdentifier and
    AddressesAreEqual(Reply.ServerIdentifier, Ipv4Address(192, 168, 1, 2)),
    'overload: DNS servers, lease and server from the server name field');
end;

procedure CheckOverloadOne;
var
  Bytes: TReplyBytes;
  Reply: TDhcpReply;
begin
  BeginReply(Bytes);
  { 1: the file field only; a 52 inside it means nothing. }
  PutHex(Bytes, OptionsOffset, '35 01 02 34 01 01 ff');
  PutHex(Bytes, FileOffset, '34 01 02 33 04 00000258 ff');
  PutHex(Bytes, ServerNameOffset, '33 04 00000001 ff');
  Check(ParseDhcpReply(@Bytes[0], 300, ClientHardware, Reply) and (Reply.Overload = 1) and
    Reply.HasLeaseTime and (Reply.LeaseSeconds = 600),
    'overload: 1 reads the file field only, and ignores option 52 inside it');
  BeginReply(Bytes);
  PutHex(Bytes, OptionsOffset, '35 01 02 34 01 02 ff');
  PutHex(Bytes, FileOffset, '33 04 00000258 ff');
  PutHex(Bytes, ServerNameOffset, '33 04 0000012c ff');
  Check(ParseDhcpReply(@Bytes[0], 300, ClientHardware, Reply) and (Reply.Overload = 2) and
    (Reply.LeaseSeconds = 300), 'overload: 2 reads the server name field only');
  BeginReply(Bytes);
  PutHex(Bytes, OptionsOffset, '35 01 02 34 01 02 ff');
  { An option running past the end of the 64-byte field. }
  PutHex(Bytes, ServerNameOffset + 60, '0f 10 41414141');
  Check(not ParseDhcpReply(@Bytes[0], 300, ClientHardware, Reply),
    'overload: an option running past its field is refused');
end;

function OfferOf(A, B, C, D: Byte; ServerLast: Byte): TDhcpReply;
begin
  Result := Default(TDhcpReply);
  Result.Kind := DhcpOffer;
  Result.YourAddress := Ipv4Address(A, B, C, D);
  Result.HasServerIdentifier := True;
  Result.ServerIdentifier := Ipv4Address(10, 0, 0, ServerLast);
end;

procedure CheckOfferChoice;
var
  Choice: TDhcpOfferChoice;
begin
  BeginOfferChoice(Choice, False, AnyIpv4Address);
  ConsiderOffer(Choice, OfferOf(10, 0, 0, 20, 1));
  ConsiderOffer(Choice, OfferOf(10, 0, 0, 30, 2));
  Check(Choice.HasOffer and (Choice.Offers = 2) and AddressesAreEqual(Choice.Offer.YourAddress,
    Ipv4Address(10, 0, 0, 20)) and not OfferChoiceIsSettled(Choice), 'offers: without an address before, the first');
  BeginOfferChoice(Choice, True, Ipv4Address(10, 0, 0, 30));
  ConsiderOffer(Choice, OfferOf(10, 0, 0, 20, 1));
  Check(not OfferChoiceIsSettled(Choice), 'offers: another address leaves the choice open');
  ConsiderOffer(Choice, OfferOf(10, 0, 0, 30, 2));
  Check(OfferChoiceIsSettled(Choice) and AddressesAreEqual(Choice.Offer.ServerIdentifier, Ipv4Address(10, 0, 0, 2)),
    'offers: the offer of the address had before wins, and settles the choice');
  ConsiderOffer(Choice, OfferOf(10, 0, 0, 30, 3));
  Check(AddressesAreEqual(Choice.Offer.ServerIdentifier, Ipv4Address(10, 0, 0, 2)),
    'offers: a later offer of the same address does not replace it');
  ConsiderOffer(Choice, OfferOf(0, 0, 0, 0, 4));
  Check(Choice.Offers = 3, 'offers: an offer without an address is not counted');
end;

procedure RunDhcpChecks;
begin
  CheckPlainReply;
  CheckOverloadBoth;
  CheckOverloadOne;
  CheckOfferChoice;
end;

end.
