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
  DHCPv6 messages (RFC 8415): building what a client sends and reading
  what a server answers.

  A message is a type byte, a three-byte transaction id and options,
  each a two-byte code, a two-byte length and its data; some options
  hold options of their own (an IA_NA holds its addresses, IAADDR, and
  a status code; an address may hold a status code too). The client
  sends its DUID (client identifier, 1), the server's (2) when it
  answers one, the elapsed time (8, in hundredths of a second), an
  identity association for non-temporary addresses (IA_NA, 3: its IAID,
  T1, T2 and the addresses it has or would like) and the options it
  wants (option request, 6: DNS servers, 23, and the domain search
  list, 24; the information refresh time, 32, with an
  information-request). Read from replies: the type, the transaction
  id, both DUIDs, the preference (7), the status (13), the IA_NAs with
  their addresses and lifetimes, the DNS servers, the domain search list
  (names as DNS writes them, without compression) and the information
  refresh time.

  Everything read is checked against the lengths that hold it; a
  damaged option makes the whole message refused.

  A client's DUID (RFC 8415 11) is made here too: DUID-LLT (type 1:
  hardware type 1, the seconds since 2000-01-01 00:00 UTC modulo 2^32,
  the Ethernet address), kept for good by the network service, or
  DUID-LL (type 3: hardware type, Ethernet address) when it cannot be
  kept, since that one is the same every time anyway.
}
unit NetworkService.Dhcpv6Messages;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Sys.InternetAddresses;

const
  Dhcpv6ClientPort = 546;
  Dhcpv6ServerPort = 547;
  { What a message takes at most here (an Ethernet frame's UDP payload
    over IPv6). }
  MaximumDhcpv6Message = 1452;

  Dhcpv6Solicit = 1;
  Dhcpv6Advertise = 2;
  Dhcpv6Request = 3;
  Dhcpv6Confirm = 4;
  Dhcpv6Renew = 5;
  Dhcpv6Rebind = 6;
  Dhcpv6Reply = 7;
  Dhcpv6Release = 8;
  Dhcpv6Decline = 9;
  Dhcpv6Reconfigure = 10;
  Dhcpv6InformationRequest = 11;

  Dhcpv6OptionClientId = 1;
  Dhcpv6OptionServerId = 2;
  Dhcpv6OptionIaNa = 3;
  Dhcpv6OptionIaAddress = 5;
  Dhcpv6OptionRequest = 6;
  Dhcpv6OptionPreference = 7;
  Dhcpv6OptionElapsedTime = 8;
  Dhcpv6OptionStatusCode = 13;
  Dhcpv6OptionRapidCommit = 14;
  Dhcpv6OptionDnsServers = 23;
  Dhcpv6OptionDomainList = 24;
  Dhcpv6OptionInformationRefreshTime = 32;

  Dhcpv6StatusSuccess = 0;
  Dhcpv6StatusUnspecifiedFailure = 1;
  Dhcpv6StatusNoAddressesAvailable = 2;
  Dhcpv6StatusNoBinding = 3;
  Dhcpv6StatusNotOnLink = 4;
  Dhcpv6StatusUseMulticast = 5;

  { "For ever", in lifetimes and T1/T2. }
  Dhcpv6Infinity = $FFFFFFFF;
  MaximumDhcpv6DnsServers = 4;
  MaximumDhcpv6Domains = 6;
  MaximumDhcpv6Addresses = 4;

type
  TDhcpv6LeasedAddress = record
    Address: TInternetAddress;
    PreferredSeconds: LongWord;
    ValidSeconds: LongWord;
    { A status code inside the address option (0: none or success). }
    StatusCode: Word;
  end;

  TDhcpv6LeasedAddresses = array of TDhcpv6LeasedAddress;

  { An IA_NA. }
  TDhcpv6IdentityAssociation = record
    IaId: LongWord;
    T1: LongWord;
    T2: LongWord;
    Addresses: TDhcpv6LeasedAddresses;
    HasStatus: Boolean;
    StatusCode: Word;
    StatusMessage: string;
  end;

  { What the client sends. }
  TDhcpv6ClientMessage = record
    Kind: Byte;
    { 24 bits. }
    TransactionId: LongWord;
    ClientId: TBytes;
    { Empty: no server identifier option. }
    ServerId: TBytes;
    { Hundredths of a second since the exchange began (at most $FFFF). }
    ElapsedHundredths: Word;
    HasIdentityAssociation: Boolean;
    IdentityAssociation: TDhcpv6IdentityAssociation;
    { The option request option's codes (none: no option). }
    RequestedOptions: array of Word;
  end;

  { What a server answers. }
  TDhcpv6ServerMessage = record
    Kind: Byte;
    TransactionId: LongWord;
    ClientId: TBytes;
    ServerId: TBytes;
    { 0 without a preference option. }
    Preference: Byte;
    HasStatus: Boolean;
    StatusCode: Word;
    StatusMessage: string;
    IdentityAssociations: array of TDhcpv6IdentityAssociation;
    DnsServers: TInternetAddressArray;
    Domains: TStringArray;
    HasInformationRefreshTime: Boolean;
    InformationRefreshSeconds: LongWord;
  end;

function BuildDhcpv6Message(constref Message: TDhcpv6ClientMessage): TBytes;
{ Reads a server's message (Advertise, Reply, Reconfigure); False if it
  is damaged or not a server's. }
function ParseDhcpv6Message(Data: PByte; Length: LongWord; out Message: TDhcpv6ServerMessage): Boolean;
{ The IA_NA of IaId in Message; False if it has none. }
function FindIdentityAssociation(constref Message: TDhcpv6ServerMessage; IaId: LongWord;
  out Association: TDhcpv6IdentityAssociation): Boolean;
{ The same bytes. }
function SameBytes(const First, Second: TBytes): Boolean;
{ "00:01:00:01:...". }
function BytesToColonHex(const Bytes: TBytes): string;
function Dhcpv6KindName(Kind: Byte): string;
function Dhcpv6StatusName(Code: Word): string;

{ DUID-LLT of HardwareAddress (6 bytes) made at UnixTime. }
function MakeLinkLayerTimeDuid(const HardwareAddress: array of Byte; UnixTime: Int64): TBytes;
{ DUID-LL of HardwareAddress. }
function MakeLinkLayerDuid(const HardwareAddress: array of Byte): TBytes;
{ "00:01:..." back into bytes; False if it is not that. }
function ColonHexToBytes(const Text: string; out Bytes: TBytes): Boolean;
{ True for a DUID this client could have made (type 1 or 3, Ethernet). }
function IsUsableClientDuid(const Duid: TBytes): Boolean;
{ When to renew (T1) and rebind (T2), in seconds after a Reply, for the
  IA_NA and the Addresses kept of it: its own T1 and T2, or for 0 (or a
  T1 above T2) half and four fifths of the shortest preferred lifetime
  (Dhcpv6Infinity: never). }
procedure Dhcpv6RenewalTimes(constref Association: TDhcpv6IdentityAssociation;
  const Addresses: TDhcpv6LeasedAddresses; out Renew, Rebind: LongWord);

implementation

const
  HeaderBytes = 4;
  OptionHeaderBytes = 4;
  IaNaFixedBytes = 12;
  IaAddressFixedBytes = 24;

{ --- Writing ---------------------------------------------------------------- }

type
  TMessageWriter = record
    Data: TBytes;
    Length: Integer;
  end;

procedure PutByte(var Writer: TMessageWriter; Value: Byte);
begin
  if Writer.Length >= System.Length(Writer.Data) then
    SetLength(Writer.Data, 2 * System.Length(Writer.Data) + 64);
  Writer.Data[Writer.Length] := Value;
  Inc(Writer.Length);
end;

procedure PutWord(var Writer: TMessageWriter; Value: Word);
begin
  PutByte(Writer, Byte(Value shr 8));
  PutByte(Writer, Byte(Value and $FF));
end;

procedure PutLongWord(var Writer: TMessageWriter; Value: LongWord);
begin
  PutWord(Writer, Word(Value shr 16));
  PutWord(Writer, Word(Value and $FFFF));
end;

procedure PutBytes(var Writer: TMessageWriter; const Bytes: TBytes);
var
  Index: Integer;
begin
  for Index := 0 to High(Bytes) do
    PutByte(Writer, Bytes[Index]);
end;

{ Writes an option's code and a length to fill in later; returns where
  the length goes. }
function BeginOption(var Writer: TMessageWriter; Code: Word): Integer;
begin
  PutWord(Writer, Code);
  Result := Writer.Length;
  PutWord(Writer, 0);
end;

procedure EndOption(var Writer: TMessageWriter; LengthPosition: Integer);
var
  OptionLength: Integer;
begin
  OptionLength := Writer.Length - LengthPosition - 2;
  Writer.Data[LengthPosition] := Byte(OptionLength shr 8);
  Writer.Data[LengthPosition + 1] := Byte(OptionLength and $FF);
end;

procedure PutBytesOption(var Writer: TMessageWriter; Code: Word; const Bytes: TBytes);
var
  Mark: Integer;
begin
  Mark := BeginOption(Writer, Code);
  PutBytes(Writer, Bytes);
  EndOption(Writer, Mark);
end;

procedure PutIdentityAssociation(var Writer: TMessageWriter; constref Association: TDhcpv6IdentityAssociation);
var
  Mark: Integer;
  AddressMark: Integer;
  Index: Integer;
  ByteIndex: Integer;
begin
  Mark := BeginOption(Writer, Dhcpv6OptionIaNa);
  PutLongWord(Writer, Association.IaId);
  PutLongWord(Writer, Association.T1);
  PutLongWord(Writer, Association.T2);
  for Index := 0 to High(Association.Addresses) do
  begin
    AddressMark := BeginOption(Writer, Dhcpv6OptionIaAddress);
    for ByteIndex := 0 to 15 do
      PutByte(Writer, Association.Addresses[Index].Address.Bytes[ByteIndex]);
    PutLongWord(Writer, Association.Addresses[Index].PreferredSeconds);
    PutLongWord(Writer, Association.Addresses[Index].ValidSeconds);
    EndOption(Writer, AddressMark);
  end;
  EndOption(Writer, Mark);
end;

function BuildDhcpv6Message(constref Message: TDhcpv6ClientMessage): TBytes;
var
  Writer: TMessageWriter;
  Mark: Integer;
  Index: Integer;
begin
  Writer.Data := nil;
  Writer.Length := 0;
  PutByte(Writer, Message.Kind);
  PutByte(Writer, Byte((Message.TransactionId shr 16) and $FF));
  PutByte(Writer, Byte((Message.TransactionId shr 8) and $FF));
  PutByte(Writer, Byte(Message.TransactionId and $FF));
  PutBytesOption(Writer, Dhcpv6OptionClientId, Message.ClientId);
  if System.Length(Message.ServerId) > 0 then
    PutBytesOption(Writer, Dhcpv6OptionServerId, Message.ServerId);
  Mark := BeginOption(Writer, Dhcpv6OptionElapsedTime);
  PutWord(Writer, Message.ElapsedHundredths);
  EndOption(Writer, Mark);
  if System.Length(Message.RequestedOptions) > 0 then
  begin
    Mark := BeginOption(Writer, Dhcpv6OptionRequest);
    for Index := 0 to High(Message.RequestedOptions) do
      PutWord(Writer, Message.RequestedOptions[Index]);
    EndOption(Writer, Mark);
  end;
  if Message.HasIdentityAssociation then
    PutIdentityAssociation(Writer, Message.IdentityAssociation);
  Result := Copy(Writer.Data, 0, Writer.Length);
end;

{ --- Reading ---------------------------------------------------------------- }

function ReadWord(Data: PByte; Position: LongWord): Word;
begin
  Result := (Word(Data[Position]) shl 8) or Data[Position + 1];
end;

function ReadLongWord(Data: PByte; Position: LongWord): LongWord;
begin
  Result := (LongWord(Data[Position]) shl 24) or (LongWord(Data[Position + 1]) shl 16) or
    (LongWord(Data[Position + 2]) shl 8) or Data[Position + 3];
end;

function BytesAt(Data: PByte; Position, Count: LongWord): TBytes;
begin
  Result := nil;
  SetLength(Result, Count);
  if Count > 0 then
    Move(Data[Position], Result[0], Count);
end;

function Ipv6AddressAt(Data: PByte; Position: LongWord): TInternetAddress;
begin
  Result := AnyIpv6Address;
  Move(Data[Position], Result.Bytes[0], 16);
end;

{ The option at Data[Position] within Finish: its code, where its data
  starts and how long it is. False if it runs past Finish. }
function NextOption(Data: PByte; Position, Finish: LongWord; out Code: Word; out Start, OptionLength: LongWord): Boolean;
begin
  Result := False;
  Code := 0;
  Start := 0;
  OptionLength := 0;
  if Position + OptionHeaderBytes > Finish then
    Exit;
  Code := ReadWord(Data, Position);
  OptionLength := ReadWord(Data, Position + 2);
  Start := Position + OptionHeaderBytes;
  Result := Start + OptionLength <= Finish;
end;

{ A status code option: the code and a UTF-8 message. }
function ReadStatus(Data: PByte; Start, OptionLength: LongWord; out Code: Word; out Text: string): Boolean;
begin
  Code := 0;
  Text := '';
  if OptionLength < 2 then
    Exit(False);
  Code := ReadWord(Data, Start);
  SetString(Text, PChar(Data + Start + 2), OptionLength - 2);
  Result := True;
end;

function ReadIaAddress(Data: PByte; Start, OptionLength: LongWord; out Leased: TDhcpv6LeasedAddress): Boolean;
var
  Position: LongWord;
  Finish: LongWord;
  Code: Word;
  InnerStart: LongWord;
  InnerLength: LongWord;
  Text: string;
begin
  Leased := Default(TDhcpv6LeasedAddress);
  if OptionLength < IaAddressFixedBytes then
    Exit(False);
  Leased.Address := Ipv6AddressAt(Data, Start);
  Leased.PreferredSeconds := ReadLongWord(Data, Start + 16);
  Leased.ValidSeconds := ReadLongWord(Data, Start + 20);
  Finish := Start + OptionLength;
  Position := Start + IaAddressFixedBytes;
  while Position < Finish do
  begin
    if not NextOption(Data, Position, Finish, Code, InnerStart, InnerLength) then
      Exit(False);
    if Code = Dhcpv6OptionStatusCode then
      if not ReadStatus(Data, InnerStart, InnerLength, Leased.StatusCode, Text) then
        Exit(False);
    Position := InnerStart + InnerLength;
  end;
  Result := True;
end;

function ReadIaNa(Data: PByte; Start, OptionLength: LongWord; out Association: TDhcpv6IdentityAssociation): Boolean;
var
  Position: LongWord;
  Finish: LongWord;
  Code: Word;
  InnerStart: LongWord;
  InnerLength: LongWord;
  Leased: TDhcpv6LeasedAddress;
begin
  Association := Default(TDhcpv6IdentityAssociation);
  if OptionLength < IaNaFixedBytes then
    Exit(False);
  Association.IaId := ReadLongWord(Data, Start);
  Association.T1 := ReadLongWord(Data, Start + 4);
  Association.T2 := ReadLongWord(Data, Start + 8);
  Finish := Start + OptionLength;
  Position := Start + IaNaFixedBytes;
  while Position < Finish do
  begin
    if not NextOption(Data, Position, Finish, Code, InnerStart, InnerLength) then
      Exit(False);
    case Code of
      Dhcpv6OptionIaAddress:
        begin
          if not ReadIaAddress(Data, InnerStart, InnerLength, Leased) then
            Exit(False);
          if System.Length(Association.Addresses) < MaximumDhcpv6Addresses then
          begin
            SetLength(Association.Addresses, System.Length(Association.Addresses) + 1);
            Association.Addresses[High(Association.Addresses)] := Leased;
          end;
        end;
      Dhcpv6OptionStatusCode:
        begin
          if not ReadStatus(Data, InnerStart, InnerLength, Association.StatusCode, Association.StatusMessage) then
            Exit(False);
          Association.HasStatus := True;
        end;
    end;
    Position := InnerStart + InnerLength;
  end;
  Result := True;
end;

function ReadDnsServers(Data: PByte; Start, OptionLength: LongWord; var Message: TDhcpv6ServerMessage): Boolean;
var
  Offset: LongWord;
begin
  if (OptionLength mod 16) <> 0 then
    Exit(False);
  Offset := 0;
  while (Offset < OptionLength) and (System.Length(Message.DnsServers) < MaximumDhcpv6DnsServers) do
  begin
    SetLength(Message.DnsServers, System.Length(Message.DnsServers) + 1);
    Message.DnsServers[High(Message.DnsServers)] := Ipv6AddressAt(Data, Start + Offset);
    Offset := Offset + 16;
  end;
  Result := True;
end;

{ Names one after another, each labels (a length byte each) ended by a
  zero byte; RFC 8415 10 forbids compression, so a pointer is refused. }
function ReadDomainList(Data: PByte; Start, OptionLength: LongWord; var Message: TDhcpv6ServerMessage): Boolean;
var
  Position: LongWord;
  Finish: LongWord;
  LabelLength: LongWord;
  Name: string;
  LabelText: string;
begin
  Result := False;
  Finish := Start + OptionLength;
  Position := Start;
  Name := '';
  while Position < Finish do
  begin
    LabelLength := Data[Position];
    Inc(Position);
    if LabelLength = 0 then
    begin
      if (Name <> '') and (System.Length(Message.Domains) < MaximumDhcpv6Domains) then
      begin
        SetLength(Message.Domains, System.Length(Message.Domains) + 1);
        Message.Domains[High(Message.Domains)] := Name;
      end;
      Name := '';
      Continue;
    end;
    if (LabelLength > 63) or (Position + LabelLength > Finish) then
      Exit;
    SetString(LabelText, PChar(Data + Position), LabelLength);
    if Name <> '' then
      Name := Name + '.';
    Name := Name + LabelText;
    if System.Length(Name) > 253 then
      Exit;
    Position := Position + LabelLength;
  end;
  { A name must end with its zero byte. }
  Result := Name = '';
end;

function ReadOption(Data: PByte; Code: Word; Start, OptionLength: LongWord;
  var Message: TDhcpv6ServerMessage): Boolean;
var
  Association: TDhcpv6IdentityAssociation;
begin
  Result := True;
  case Code of
    Dhcpv6OptionClientId: Message.ClientId := BytesAt(Data, Start, OptionLength);
    Dhcpv6OptionServerId: Message.ServerId := BytesAt(Data, Start, OptionLength);
    Dhcpv6OptionPreference:
      begin
        if OptionLength <> 1 then
          Exit(False);
        Message.Preference := Data[Start];
      end;
    Dhcpv6OptionStatusCode:
      begin
        Result := ReadStatus(Data, Start, OptionLength, Message.StatusCode, Message.StatusMessage);
        Message.HasStatus := Result;
      end;
    Dhcpv6OptionIaNa:
      begin
        Result := ReadIaNa(Data, Start, OptionLength, Association);
        if Result then
        begin
          SetLength(Message.IdentityAssociations, System.Length(Message.IdentityAssociations) + 1);
          Message.IdentityAssociations[High(Message.IdentityAssociations)] := Association;
        end;
      end;
    Dhcpv6OptionDnsServers: Result := ReadDnsServers(Data, Start, OptionLength, Message);
    Dhcpv6OptionDomainList: Result := ReadDomainList(Data, Start, OptionLength, Message);
    Dhcpv6OptionInformationRefreshTime:
      begin
        if OptionLength <> 4 then
          Exit(False);
        Message.InformationRefreshSeconds := ReadLongWord(Data, Start);
        Message.HasInformationRefreshTime := True;
      end;
  end;
end;

function ParseDhcpv6Message(Data: PByte; Length: LongWord; out Message: TDhcpv6ServerMessage): Boolean;
var
  Position: LongWord;
  Code: Word;
  Start: LongWord;
  OptionLength: LongWord;
begin
  Message := Default(TDhcpv6ServerMessage);
  Result := False;
  if Length < HeaderBytes then
    Exit;
  Message.Kind := Data[0];
  if not (Message.Kind in [Dhcpv6Advertise, Dhcpv6Reply, Dhcpv6Reconfigure]) then
    Exit;
  Message.TransactionId := (LongWord(Data[1]) shl 16) or (LongWord(Data[2]) shl 8) or Data[3];
  Position := HeaderBytes;
  while Position < Length do
  begin
    if not NextOption(Data, Position, Length, Code, Start, OptionLength) then
      Exit;
    if not ReadOption(Data, Code, Start, OptionLength, Message) then
      Exit;
    Position := Start + OptionLength;
  end;
  Result := True;
end;

function FindIdentityAssociation(constref Message: TDhcpv6ServerMessage; IaId: LongWord;
  out Association: TDhcpv6IdentityAssociation): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Message.IdentityAssociations) do
    if Message.IdentityAssociations[Index].IaId = IaId then
    begin
      Association := Message.IdentityAssociations[Index];
      Exit(True);
    end;
  Association := Default(TDhcpv6IdentityAssociation);
  Result := False;
end;

function SameBytes(const First, Second: TBytes): Boolean;
begin
  Result := (System.Length(First) = System.Length(Second)) and
    ((System.Length(First) = 0) or CompareMem(@First[0], @Second[0], System.Length(First)));
end;

function BytesToColonHex(const Bytes: TBytes): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 0 to High(Bytes) do
  begin
    if Index > 0 then
      Result := Result + ':';
    Result := Result + LowerCase(IntToHex(Bytes[Index], 2));
  end;
end;

const
  DuidLinkLayerTime = 1;
  DuidLinkLayer = 3;
  HardwareTypeEthernet = 1;
  { 2000-01-01 00:00:00 UTC in Unix time. }
  DuidEpoch = 946684800;

function MakeLinkLayerTimeDuid(const HardwareAddress: array of Byte; UnixTime: Int64): TBytes;
var
  Seconds: LongWord;
begin
  Result := nil;
  SetLength(Result, 8 + System.Length(HardwareAddress));
  Seconds := LongWord(QWord(UnixTime - DuidEpoch) and $FFFFFFFF);
  Result[0] := 0;
  Result[1] := DuidLinkLayerTime;
  Result[2] := 0;
  Result[3] := HardwareTypeEthernet;
  Result[4] := Byte(Seconds shr 24);
  Result[5] := Byte((Seconds shr 16) and $FF);
  Result[6] := Byte((Seconds shr 8) and $FF);
  Result[7] := Byte(Seconds and $FF);
  if System.Length(HardwareAddress) > 0 then
    Move(HardwareAddress[0], Result[8], System.Length(HardwareAddress));
end;

function MakeLinkLayerDuid(const HardwareAddress: array of Byte): TBytes;
begin
  Result := nil;
  SetLength(Result, 4 + System.Length(HardwareAddress));
  Result[0] := 0;
  Result[1] := DuidLinkLayer;
  Result[2] := 0;
  Result[3] := HardwareTypeEthernet;
  if System.Length(HardwareAddress) > 0 then
    Move(HardwareAddress[0], Result[4], System.Length(HardwareAddress));
end;

function HexValue(Character: Char): Integer;
begin
  case Character of
    '0'..'9': Result := Ord(Character) - Ord('0');
    'a'..'f': Result := Ord(Character) - Ord('a') + 10;
    'A'..'F': Result := Ord(Character) - Ord('A') + 10;
  else
    Result := -1;
  end;
end;

function ColonHexToBytes(const Text: string; out Bytes: TBytes): Boolean;
var
  Parts: TStringArray;
  Index: Integer;
  High4: Integer;
  Low4: Integer;
begin
  Bytes := nil;
  Result := False;
  if Trim(Text) = '' then
    Exit;
  Parts := Trim(Text).Split([':']);
  SetLength(Bytes, System.Length(Parts));
  for Index := 0 to High(Parts) do
  begin
    if System.Length(Parts[Index]) <> 2 then
      Exit;
    High4 := HexValue(Parts[Index][1]);
    Low4 := HexValue(Parts[Index][2]);
    if (High4 < 0) or (Low4 < 0) then
      Exit;
    Bytes[Index] := Byte(High4 * 16 + Low4);
  end;
  Result := True;
end;

function IsUsableClientDuid(const Duid: TBytes): Boolean;
begin
  Result := False;
  if System.Length(Duid) < 4 then
    Exit;
  if (Duid[0] <> 0) or (Duid[2] <> 0) or (Duid[3] <> HardwareTypeEthernet) then
    Exit;
  case Duid[1] of
    DuidLinkLayerTime: Result := System.Length(Duid) = 14;
    DuidLinkLayer: Result := System.Length(Duid) = 10;
  end;
end;

{ T1 and T2 of 0 (or T1 above T2): half and four fifths of the shortest
  preferred lifetime. }
procedure Dhcpv6RenewalTimes(constref Association: TDhcpv6IdentityAssociation;
  const Addresses: TDhcpv6LeasedAddresses; out Renew, Rebind: LongWord);
var
  Shortest: LongWord;
  Index: Integer;
begin
  Shortest := Dhcpv6Infinity;
  for Index := 0 to High(Addresses) do
    if Addresses[Index].PreferredSeconds < Shortest then
      Shortest := Addresses[Index].PreferredSeconds;
  Renew := Association.T1;
  Rebind := Association.T2;
  if (Renew <> 0) and (Rebind <> 0) and (Renew > Rebind) then
  begin
    Renew := 0;
    Rebind := 0;
  end;
  if Renew = 0 then
  begin
    if Shortest = Dhcpv6Infinity then
      Renew := Dhcpv6Infinity
    else
      Renew := Shortest div 2;
  end;
  if Rebind = 0 then
  begin
    if Shortest = Dhcpv6Infinity then
      Rebind := Dhcpv6Infinity
    else
      Rebind := LongWord((QWord(Shortest) * 4) div 5);
  end;
end;

function Dhcpv6KindName(Kind: Byte): string;
begin
  case Kind of
    Dhcpv6Solicit: Result := 'SOLICIT';
    Dhcpv6Advertise: Result := 'ADVERTISE';
    Dhcpv6Request: Result := 'REQUEST';
    Dhcpv6Confirm: Result := 'CONFIRM';
    Dhcpv6Renew: Result := 'RENEW';
    Dhcpv6Rebind: Result := 'REBIND';
    Dhcpv6Reply: Result := 'REPLY';
    Dhcpv6Release: Result := 'RELEASE';
    Dhcpv6Decline: Result := 'DECLINE';
    Dhcpv6Reconfigure: Result := 'RECONFIGURE';
    Dhcpv6InformationRequest: Result := 'INFORMATION-REQUEST';
  else
    Result := 'DHCPv6 message ' + IntToStr(Kind);
  end;
end;

function Dhcpv6StatusName(Code: Word): string;
begin
  case Code of
    Dhcpv6StatusSuccess: Result := 'Success';
    Dhcpv6StatusUnspecifiedFailure: Result := 'UnspecFail';
    Dhcpv6StatusNoAddressesAvailable: Result := 'NoAddrsAvail';
    Dhcpv6StatusNoBinding: Result := 'NoBinding';
    Dhcpv6StatusNotOnLink: Result := 'NotOnLink';
    Dhcpv6StatusUseMulticast: Result := 'UseMulticast';
  else
    Result := 'status ' + IntToStr(Code);
  end;
end;

end.
