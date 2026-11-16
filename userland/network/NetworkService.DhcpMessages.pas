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
  DHCP messages (RFC 2131, with the options of RFC 2132): building what
  a client sends and reading what a server answers.

  A message is the BOOTP layout - operation, hardware type and length,
  transaction id, seconds, flags, the client's, offered, server's and
  relay's addresses, the client's hardware address, the server name and
  file fields - then the magic cookie 99.130.83.99 and the options, each
  a code, a length and its bytes. The client sends: the message type
  (53), its client identifier (61: type 1 and its Ethernet address), its
  host name (12), the address it asks for (50), the server it answers
  (54), the parameters it wants (55: subnet mask, router, DNS servers,
  domain name, lease time, renewal and rebinding times, server id) and
  the largest message it takes (57). Read from replies: the type, the
  offered address (yiaddr), the subnet mask, routers, DNS servers,
  domain name, lease, renewal (T1) and rebinding (T2) times and the
  server identifier. Option overload (52: options in the file and server
  name fields) is not followed; servers use it only for very long
  replies.
}
unit NetworkService.DhcpMessages;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Sys.InternetAddresses;

const
  DhcpClientPort = 68;
  DhcpServerPort = 67;
  { What a message takes at most here (an Ethernet frame's UDP payload). }
  MaximumDhcpMessage = 1472;
  MinimumDhcpMessage = 240;

  DhcpDiscover = 1;
  DhcpOffer = 2;
  DhcpRequest = 3;
  DhcpDecline = 4;
  DhcpAcknowledge = 5;
  DhcpNegativeAcknowledge = 6;
  DhcpRelease = 7;

  MaximumDhcpAddresses = 4;
  { "No end": a lease that never runs out. }
  InfiniteLease = $FFFFFFFF;

type
  TEthernetAddress = array[0..5] of Byte;

  { What the client sends. }
  TDhcpRequestParameters = record
    Kind: Byte;
    TransactionId: LongWord;
    SecondsElapsed: Word;
    { Ask the server to broadcast its reply (the client has no address
      yet to take a unicast one). }
    BroadcastReply: Boolean;
    HardwareAddress: TEthernetAddress;
    { ciaddr: the address the client has and uses (renewing, rebinding,
      releasing); 0.0.0.0 otherwise. }
    ClientAddress: TInternetAddress;
    HasRequestedAddress: Boolean;
    RequestedAddress: TInternetAddress;
    HasServerIdentifier: Boolean;
    ServerIdentifier: TInternetAddress;
    HostName: string;
    { Option 55 and 57 (not in DECLINE and RELEASE). }
    AskForParameters: Boolean;
  end;

  { What a server answers. }
  TDhcpReply = record
    Kind: Byte;
    TransactionId: LongWord;
    YourAddress: TInternetAddress;
    HasServerIdentifier: Boolean;
    ServerIdentifier: TInternetAddress;
    HasSubnetMask: Boolean;
    PrefixLength: LongWord;
    { Up to MaximumDhcpAddresses of each. }
    Routers: TInternetAddressArray;
    DnsServers: TInternetAddressArray;
    DomainName: string;
    HasLeaseTime: Boolean;
    LeaseSeconds: LongWord;
    HasRenewalTime: Boolean;
    RenewalSeconds: LongWord;
    HasRebindingTime: Boolean;
    RebindingSeconds: LongWord;
  end;

function BuildDhcpMessage(constref Parameters: TDhcpRequestParameters; Buffer: PByte; Capacity: LongWord;
  out Length: LongWord): Boolean;
{ Reads a reply meant for HardwareAddress; False if it is not a server's
  DHCP reply to it, or it is damaged. }
function ParseDhcpReply(Data: PByte; Length: LongWord; constref HardwareAddress: TEthernetAddress;
  out Reply: TDhcpReply): Boolean;
function DhcpKindName(Kind: Byte): string;

implementation

uses
  SysUtils,
  Abi.SystemCalls;

const
  OperationRequest = 1;
  OperationReply = 2;
  HardwareTypeEthernet = 1;
  FlagBroadcast = $8000;
  MagicCookieOffset = 236;
  OptionsOffset = 240;

  OptionPad = 0;
  OptionSubnetMask = 1;
  OptionRouter = 3;
  OptionDnsServers = 6;
  OptionHostName = 12;
  OptionDomainName = 15;
  OptionRequestedAddress = 50;
  OptionLeaseTime = 51;
  OptionMessageType = 53;
  OptionServerIdentifier = 54;
  OptionParameterRequestList = 55;
  OptionMaximumMessageSize = 57;
  OptionRenewalTime = 58;
  OptionRebindingTime = 59;
  OptionClientIdentifier = 61;
  OptionEnd = 255;

  MagicCookie: array[0..3] of Byte = (99, 130, 83, 99);
  RequestedParameters: array[0..7] of Byte = (OptionSubnetMask, OptionRouter, OptionDnsServers,
    OptionDomainName, OptionLeaseTime, OptionRenewalTime, OptionRebindingTime, OptionServerIdentifier);

function DhcpKindName(Kind: Byte): string;
begin
  case Kind of
    DhcpDiscover: Result := 'DHCPDISCOVER';
    DhcpOffer: Result := 'DHCPOFFER';
    DhcpRequest: Result := 'DHCPREQUEST';
    DhcpDecline: Result := 'DHCPDECLINE';
    DhcpAcknowledge: Result := 'DHCPACK';
    DhcpNegativeAcknowledge: Result := 'DHCPNAK';
    DhcpRelease: Result := 'DHCPRELEASE';
  else
    Result := 'DHCP message ' + IntToStr(Kind);
  end;
end;

type
  TMessageWriter = record
    Buffer: PByte;
    Capacity: LongWord;
    Position: LongWord;
    Overflowed: Boolean;
  end;

procedure PutByte(var Writer: TMessageWriter; Value: Byte);
begin
  if Writer.Position >= Writer.Capacity then
  begin
    Writer.Overflowed := True;
    Exit;
  end;
  Writer.Buffer[Writer.Position] := Value;
  Inc(Writer.Position);
end;

procedure PutBytes(var Writer: TMessageWriter; Data: PByte; Count: LongWord);
var
  Index: LongWord;
begin
  Index := 0;
  while Index < Count do
  begin
    PutByte(Writer, Data[Index]);
    Inc(Index);
  end;
end;

procedure PutAddressOption(var Writer: TMessageWriter; Code: Byte; constref Address: TInternetAddress);
begin
  PutByte(Writer, Code);
  PutByte(Writer, 4);
  PutBytes(Writer, @Address.Bytes[0], 4);
end;

procedure PutTextOption(var Writer: TMessageWriter; Code: Byte; const Text: string);
var
  Count: Integer;
begin
  Count := System.Length(Text);
  if Count = 0 then
    Exit;
  if Count > 255 then
    Count := 255;
  PutByte(Writer, Code);
  PutByte(Writer, Byte(Count));
  PutBytes(Writer, @Text[1], Count);
end;

procedure WriteWordAt(Buffer: PByte; Position: LongWord; Value: Word);
begin
  Buffer[Position] := Byte(Value shr 8);
  Buffer[Position + 1] := Byte(Value);
end;

procedure WriteLongWordAt(Buffer: PByte; Position: LongWord; Value: LongWord);
begin
  Buffer[Position] := Byte(Value shr 24);
  Buffer[Position + 1] := Byte(Value shr 16);
  Buffer[Position + 2] := Byte(Value shr 8);
  Buffer[Position + 3] := Byte(Value);
end;

function BuildDhcpMessage(constref Parameters: TDhcpRequestParameters; Buffer: PByte; Capacity: LongWord;
  out Length: LongWord): Boolean;
var
  Writer: TMessageWriter;
begin
  Length := 0;
  if Capacity < OptionsOffset then
    Exit(False);
  FillChar(Buffer^, OptionsOffset, 0);
  Buffer[0] := OperationRequest;
  Buffer[1] := HardwareTypeEthernet;
  Buffer[2] := 6;
  WriteLongWordAt(Buffer, 4, Parameters.TransactionId);
  WriteWordAt(Buffer, 8, Parameters.SecondsElapsed);
  if Parameters.BroadcastReply then
    WriteWordAt(Buffer, 10, FlagBroadcast);
  if Parameters.ClientAddress.Family = AddressFamilyIPv4 then
    Move(Parameters.ClientAddress.Bytes[0], Buffer[12], 4);
  Move(Parameters.HardwareAddress[0], Buffer[28], 6);
  Move(MagicCookie[0], Buffer[MagicCookieOffset], 4);

  Writer.Buffer := Buffer;
  Writer.Capacity := Capacity;
  Writer.Position := OptionsOffset;
  Writer.Overflowed := False;
  PutByte(Writer, OptionMessageType);
  PutByte(Writer, 1);
  PutByte(Writer, Parameters.Kind);
  PutByte(Writer, OptionClientIdentifier);
  PutByte(Writer, 7);
  PutByte(Writer, HardwareTypeEthernet);
  PutBytes(Writer, @Parameters.HardwareAddress[0], 6);
  if Parameters.HasRequestedAddress then
    PutAddressOption(Writer, OptionRequestedAddress, Parameters.RequestedAddress);
  if Parameters.HasServerIdentifier then
    PutAddressOption(Writer, OptionServerIdentifier, Parameters.ServerIdentifier);
  if Parameters.Kind <> DhcpRelease then
    PutTextOption(Writer, OptionHostName, Parameters.HostName);
  if Parameters.AskForParameters then
  begin
    PutByte(Writer, OptionParameterRequestList);
    PutByte(Writer, SizeOf(RequestedParameters));
    PutBytes(Writer, @RequestedParameters[0], SizeOf(RequestedParameters));
    PutByte(Writer, OptionMaximumMessageSize);
    PutByte(Writer, 2);
    PutByte(Writer, Byte(MaximumDhcpMessage shr 8));
    PutByte(Writer, Byte(MaximumDhcpMessage and $FF));
  end;
  PutByte(Writer, OptionEnd);
  { Some relays drop messages shorter than BOOTP's 300 bytes. }
  while (Writer.Position < 300) and not Writer.Overflowed do
    PutByte(Writer, OptionPad);
  if Writer.Overflowed then
    Exit(False);
  Length := Writer.Position;
  Result := True;
end;

function ReadLongWordAt(Data: PByte; Position: LongWord): LongWord;
begin
  Result := (LongWord(Data[Position]) shl 24) or (LongWord(Data[Position + 1]) shl 16) or
    (LongWord(Data[Position + 2]) shl 8) or Data[Position + 3];
end;

function AddressAt(Data: PByte; Position: LongWord): TInternetAddress;
begin
  Result := Ipv4Address(Data[Position], Data[Position + 1], Data[Position + 2], Data[Position + 3]);
end;

{ A netmask's prefix length; False if its ones are not all in front. }
function MaskToPrefix(Data: PByte; Position: LongWord; out PrefixLength: LongWord): Boolean;
var
  Mask: LongWord;
begin
  Mask := ReadLongWordAt(Data, Position);
  PrefixLength := 0;
  while (Mask and $80000000) <> 0 do
  begin
    Inc(PrefixLength);
    Mask := Mask shl 1;
  end;
  Result := Mask = 0;
end;

function ReadAddressList(Data: PByte; Position, OptionLength: LongWord): TInternetAddressArray;
var
  Offset: LongWord;
begin
  Result := nil;
  Offset := 0;
  while (Offset + 4 <= OptionLength) and (System.Length(Result) < MaximumDhcpAddresses) do
  begin
    SetLength(Result, System.Length(Result) + 1);
    Result[High(Result)] := AddressAt(Data, Position + Offset);
    Offset := Offset + 4;
  end;
end;

procedure ReadOption(Data: PByte; Code: Byte; Position, OptionLength: LongWord; var Reply: TDhcpReply);
begin
  case Code of
    OptionMessageType:
      if OptionLength >= 1 then
        Reply.Kind := Data[Position];
    OptionSubnetMask:
      if OptionLength = 4 then
        Reply.HasSubnetMask := MaskToPrefix(Data, Position, Reply.PrefixLength);
    OptionRouter: Reply.Routers := ReadAddressList(Data, Position, OptionLength);
    OptionDnsServers: Reply.DnsServers := ReadAddressList(Data, Position, OptionLength);
    OptionDomainName:
      begin
        SetString(Reply.DomainName, PChar(Data + Position), OptionLength);
        { Some servers count a final #0. }
        while (System.Length(Reply.DomainName) > 0) and (Reply.DomainName[System.Length(Reply.DomainName)] = #0) do
          SetLength(Reply.DomainName, System.Length(Reply.DomainName) - 1);
      end;
    OptionServerIdentifier:
      if OptionLength = 4 then
      begin
        Reply.ServerIdentifier := AddressAt(Data, Position);
        Reply.HasServerIdentifier := True;
      end;
    OptionLeaseTime:
      if OptionLength = 4 then
      begin
        Reply.LeaseSeconds := ReadLongWordAt(Data, Position);
        Reply.HasLeaseTime := True;
      end;
    OptionRenewalTime:
      if OptionLength = 4 then
      begin
        Reply.RenewalSeconds := ReadLongWordAt(Data, Position);
        Reply.HasRenewalTime := True;
      end;
    OptionRebindingTime:
      if OptionLength = 4 then
      begin
        Reply.RebindingSeconds := ReadLongWordAt(Data, Position);
        Reply.HasRebindingTime := True;
      end;
  end;
end;

procedure ClearReply(out Reply: TDhcpReply);
begin
  Reply := Default(TDhcpReply);
  Reply.YourAddress := AnyIpv4Address;
  Reply.ServerIdentifier := AnyIpv4Address;
end;

function ParseDhcpReply(Data: PByte; Length: LongWord; constref HardwareAddress: TEthernetAddress;
  out Reply: TDhcpReply): Boolean;
var
  Position: LongWord;
  Code: Byte;
  OptionLength: LongWord;
begin
  ClearReply(Reply);
  Result := False;
  if (Length < OptionsOffset) or (Data[0] <> OperationReply) or (Data[1] <> HardwareTypeEthernet) or
     (Data[2] <> 6) or not CompareMem(Data + 28, @HardwareAddress[0], 6) or
     not CompareMem(Data + MagicCookieOffset, @MagicCookie[0], 4) then
    Exit;
  Reply.TransactionId := ReadLongWordAt(Data, 4);
  Reply.YourAddress := AddressAt(Data, 16);
  Position := OptionsOffset;
  while Position < Length do
  begin
    Code := Data[Position];
    if Code = OptionEnd then
      Break;
    if Code = OptionPad then
    begin
      Inc(Position);
      Continue;
    end;
    if Position + 2 > Length then
      Exit;
    OptionLength := Data[Position + 1];
    if Position + 2 + OptionLength > Length then
      Exit;
    ReadOption(Data, Code, Position + 2, OptionLength, Reply);
    Position := Position + 2 + OptionLength;
  end;
  Result := Reply.Kind <> 0;
end;

end.
