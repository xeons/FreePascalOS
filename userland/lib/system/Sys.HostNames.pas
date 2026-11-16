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
  Turning a host as the user writes it into addresses, and an address
  back into a name: the one place programs (ping, ...) ask, so every
  program takes names the same way.

  A host is looked up as
    1. a numeric address (10.0.2.15, or an IPv6 address);
    2. a name in /etc/hosts (Sys.HostsFile);
    3. a name asked of the DNS servers (Sys.DnsQueries), in the search
       domain first if it is a single label: A records (and AAAA ones
       when asked for), following CNAME records - in the same answer,
       or by asking again for where they point - up to
       MaximumAliasSteps;
  and "localhost" is 127.0.0.1 even without /etc/hosts. An address is
  named by /etc/hosts, then by a PTR record.

  Errors: ErrorNotFound when the name does not exist or has no address
  (or there is no DNS server to ask), ErrorTimedOut when no server
  answered, ErrorWouldBlock ("try again") when the servers failed.
}
unit Sys.HostNames;

{$mode objfpc}
{$H+}

interface

uses
  Sys.InternetAddresses;

const
  { Families of LookUpHostAddresses. }
  HostFamilyIpv4 = 1;
  HostFamilyIpv6 = 2;
  HostFamilyAny = HostFamilyIpv4 or HostFamilyIpv6;
  MaximumAliasSteps = 8;

type
  THostAddresses = record
    { IPv4 addresses before IPv6 ones, each once. }
    Addresses: TInternetAddressArray;
    { The name the addresses belong to once aliases were followed. }
    CanonicalName: string;
  end;

{ ErrorNone with the (first IPv4) address of Host. }
function LookUpHost(const Host: string; out Address: TInternetAddress): LongInt;
{ ErrorNone with the first address of Host of either family (an IPv4
  one if it has one): for naming a server, such as a DNS server. To
  connect, Sys.HostLookup orders the addresses better. }
function LookUpAnyHostAddress(const Host: string; out Address: TInternetAddress): LongInt;
{ Every address of Host of the families asked for. }
function LookUpHostAddresses(const Host: string; Families: LongWord; out Found: THostAddresses): LongInt;
{ The name of Address (reverse lookup): /etc/hosts, then a PTR record.
  Name is without the final dot. }
function LookUpAddressName(constref Address: TInternetAddress; out Name: string): LongInt;
{ A message for the errors above ("Name or service not known"). }
function HostLookupErrorMessage(Error: LongInt): string;

implementation

uses
  Abi.SystemCalls,
  Sys.DnsNames,
  Sys.HostsFile,
  Sys.DnsMessages,
  Sys.DnsQueries;

procedure AddAddress(var Found: THostAddresses; constref Address: TInternetAddress);
var
  Existing: TInternetAddress;
begin
  for Existing in Found.Addresses do
    if AddressesAreEqual(Existing, Address) then
      Exit;
  SetLength(Found.Addresses, Length(Found.Addresses) + 1);
  Found.Addresses[High(Found.Addresses)] := Address;
end;

{ The error a response stands for when it brought nothing. }
function ResponseError(constref Message: TDnsMessage): LongInt;
begin
  case Message.ResponseCode of
    DnsResponseNoError, DnsResponseNameError: Result := ErrorNotFound;
  else
    Result := ErrorWouldBlock;
  end;
end;

function IsAnswerFor(constref Entry: TDnsRecord; RecordType: Word; const Name: string): Boolean;
begin
  Result := (Entry.Section = DnsSectionAnswer) and (Entry.RecordType = RecordType) and
    DnsNamesAreEqual(Entry.Name, Name);
end;

{ Follows the CNAME records of the answer from Name; Name becomes the
  end of the chain. False if the chain is too long. }
function FollowAliases(constref Message: TDnsMessage; var Name: string): Boolean;
var
  Steps: Integer;
  Index: Integer;
  Moved: Boolean;
begin
  Steps := 0;
  repeat
    Moved := False;
    for Index := 0 to Message.RecordCount - 1 do
      if IsAnswerFor(Message.Records[Index], DnsTypeCname, Name) then
      begin
        Name := Message.Records[Index].Target;
        Moved := True;
        Inc(Steps);
        Break;
      end;
    if Steps > MaximumAliasSteps then
      Exit(False);
  until not Moved;
  Result := True;
end;

{ The records of RecordType for Name (aliases followed) into Found. }
function QueryAddresses(const Name: string; RecordType: Word; constref Options: TDnsQueryOptions;
  var Found: THostAddresses): LongInt;
var
  Message: TDnsMessage;
  Details: TDnsQueryDetails;
  Current: string;
  Queries: Integer;
  Index: Integer;
  Added: Boolean;
  HadAlias: Boolean;
begin
  Result := QueryDnsSearching(Name, RecordType, Options, Message, Details);
  if Result <> ErrorNone then
    Exit;
  Current := Details.QueriedName;
  Queries := 1;
  repeat
    HadAlias := not DnsNamesAreEqual(Current, Message.QuestionName);
    if not FollowAliases(Message, Current) then
      Exit(ErrorNotFound);
    HadAlias := HadAlias or not DnsNamesAreEqual(Current, Message.QuestionName);
    Added := False;
    for Index := 0 to Message.RecordCount - 1 do
      if IsAnswerFor(Message.Records[Index], RecordType, Current) then
      begin
        AddAddress(Found, Message.Records[Index].Address);
        Added := True;
      end;
    if Added then
    begin
      if Found.CanonicalName = '' then
        Found.CanonicalName := Current;
      Exit(ErrorNone);
    end;
    { An alias whose target the server did not answer for: ask for it. }
    if not HadAlias or (Message.ResponseCode <> DnsResponseNoError) or (Queries > MaximumAliasSteps) then
      Exit(ResponseError(Message));
    Result := QueryDns(Current, RecordType, Options, Message, Details);
    if Result <> ErrorNone then
      Exit;
    Inc(Queries);
  until False;
end;

function LookUpInDns(const Host: string; Families: LongWord; var Found: THostAddresses): LongInt;
var
  Options: TDnsQueryOptions;
  Ipv6Error: LongInt;
begin
  SystemDnsQueryOptions(Options);
  Result := ErrorNotFound;
  if (Families and HostFamilyIpv4) <> 0 then
    Result := QueryAddresses(Host, DnsTypeA, Options, Found);
  if (Families and HostFamilyIpv6) <> 0 then
  begin
    Ipv6Error := QueryAddresses(Host, DnsTypeAaaa, Options, Found);
    if (Families and HostFamilyIpv4) = 0 then
      Result := Ipv6Error;
  end;
  if Length(Found.Addresses) > 0 then
    Result := ErrorNone;
end;

function FamilyIsWanted(constref Address: TInternetAddress; Families: LongWord): Boolean;
begin
  Result := ((Address.Family = AddressFamilyIPv4) and ((Families and HostFamilyIpv4) <> 0)) or
    ((Address.Family = AddressFamilyIPv6) and ((Families and HostFamilyIpv6) <> 0));
end;

function LookUpHostAddresses(const Host: string; Families: LongWord; out Found: THostAddresses): LongInt;
var
  Address: TInternetAddress;
  FromFile: THostsFileAddresses;
begin
  Found := Default(THostAddresses);
  if Host = '' then
    Exit(ErrorNotFound);
  if TextToAddress(Host, Address) then
  begin
    Found.CanonicalName := Host;
    if not FamilyIsWanted(Address, Families) then
      Exit(ErrorNotFound);
    AddAddress(Found, Address);
    Exit(ErrorNone);
  end;
  if LookUpHostsFileName(Host, Families, FromFile) then
  begin
    Found.CanonicalName := FromFile.CanonicalName;
    for Address in FromFile.Addresses do
      if Address.Family = AddressFamilyIPv4 then
        AddAddress(Found, Address);
    for Address in FromFile.Addresses do
      if Address.Family <> AddressFamilyIPv4 then
        AddAddress(Found, Address);
    Exit(ErrorNone);
  end;
  if DnsNamesAreEqual(Host, 'localhost') then
  begin
    Found.CanonicalName := 'localhost';
    if (Families and HostFamilyIpv4) <> 0 then
      AddAddress(Found, LoopbackIpv4Address);
    if (Families and HostFamilyIpv6) <> 0 then
      AddAddress(Found, LoopbackIpv6Address);
    Exit(ErrorNone);
  end;
  Result := LookUpInDns(Host, Families, Found);
end;

{ The first address of Host of Families. }
function LookUpFirstAddress(const Host: string; Families: LongWord; out Address: TInternetAddress): LongInt;
var
  Found: THostAddresses;
begin
  Address := AnyIpv4Address;
  Result := LookUpHostAddresses(Host, Families, Found);
  if (Result = ErrorNone) and (Length(Found.Addresses) > 0) then
    Address := Found.Addresses[0];
end;

function LookUpHost(const Host: string; out Address: TInternetAddress): LongInt;
begin
  Result := LookUpFirstAddress(Host, HostFamilyIpv4, Address);
end;

function LookUpAnyHostAddress(const Host: string; out Address: TInternetAddress): LongInt;
begin
  Result := LookUpFirstAddress(Host, HostFamilyAny, Address);
end;

function WithoutFinalDot(const Name: string): string;
begin
  if (Length(Name) > 1) and (Name[Length(Name)] = '.') then
    Result := Copy(Name, 1, Length(Name) - 1)
  else
    Result := Name;
end;

function LookUpAddressName(constref Address: TInternetAddress; out Name: string): LongInt;
var
  Question: string;
  Options: TDnsQueryOptions;
  Message: TDnsMessage;
  Details: TDnsQueryDetails;
  Index: Integer;
begin
  if LookUpHostsFileAddress(Address, Name) then
    Exit(ErrorNone);
  Name := '';
  if not ReverseLookupName(Address, Question) then
    Exit(ErrorAddressFamilyNotSupported);
  SystemDnsQueryOptions(Options);
  Result := QueryDns(Question, DnsTypePtr, Options, Message, Details);
  if Result <> ErrorNone then
    Exit;
  if not FollowAliases(Message, Question) then
    Exit(ErrorNotFound);
  for Index := 0 to Message.RecordCount - 1 do
    if IsAnswerFor(Message.Records[Index], DnsTypePtr, Question) then
    begin
      Name := WithoutFinalDot(Message.Records[Index].Target);
      Exit(ErrorNone);
    end;
  Result := ResponseError(Message);
end;

function HostLookupErrorMessage(Error: LongInt): string;
begin
  case Error of
    ErrorNone: Result := 'Success';
    ErrorNotFound: Result := 'Name or service not known';
    ErrorTimedOut, ErrorWouldBlock: Result := 'Temporary failure in name resolution';
    ErrorAddressFamilyNotSupported: Result := 'Address family not supported';
  else
    Result := 'Name resolution failed';
  end;
end;

end.
