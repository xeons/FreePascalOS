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

interface

uses
  Sys.InternetAddresses,
  Sys.DnsNames;

const
  { Families of LookUpHostAddresses. }
  HostFamilyIpv4 = 1;
  HostFamilyIpv6 = 2;
  HostFamilyAny = HostFamilyIpv4 or HostFamilyIpv6;
  MaximumHostAddresses = 16;
  MaximumAliasSteps = 8;

type
  THostAddresses = record
    Count: Integer;
    { IPv4 addresses before IPv6 ones. }
    Addresses: array[0..MaximumHostAddresses - 1] of TInternetAddress;
    { The name the addresses belong to once aliases were followed. }
    CanonicalName: TDnsName;
  end;

{ ErrorNone with the (first IPv4) address of Host. }
function LookUpHost(Host: PChar; out Address: TInternetAddress): LongInt;
{ Every address of Host of the families asked for. }
function LookUpHostAddresses(Host: PChar; Families: LongWord; out Found: THostAddresses): LongInt;
{ The name of Address (reverse lookup): /etc/hosts, then a PTR record.
  Name is written without the final dot. }
function LookUpAddressName(constref Address: TInternetAddress; Name: PChar; Capacity: PtrUInt): LongInt;
{ A message for the errors above ("Name or service not known"). }
function HostLookupErrorMessage(Error: LongInt): PChar;

implementation

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Text,
  Sys.HostsFile,
  Sys.DnsMessages,
  Sys.DnsQueries;

procedure AddAddress(var Found: THostAddresses; constref Address: TInternetAddress);
var
  Index: Integer;
begin
  for Index := 0 to Found.Count - 1 do
    if AddressesAreEqual(Found.Addresses[Index], Address) then
      Exit;
  if Found.Count < MaximumHostAddresses then
  begin
    Found.Addresses[Found.Count] := Address;
    Inc(Found.Count);
  end;
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

{ Follows the CNAME records of the answer from Name; Name becomes the
  end of the chain. False if the chain is too long. }
function FollowAliases(constref Message: TDnsMessage; var Name: TDnsName): Boolean;
var
  Steps: Integer;
  Index: Integer;
  Moved: Boolean;
begin
  Steps := 0;
  repeat
    Moved := False;
    for Index := 0 to Message.RecordCount - 1 do
      if (Message.Records[Index].Section = DnsSectionAnswer) and
         (Message.Records[Index].RecordType = DnsTypeCname) and
         DnsNamesAreEqual(@Message.Records[Index].Name[0], @Name[0]) then
      begin
        CopyText(@Name[0], @Message.Records[Index].Target[0], DnsNameCapacity);
        Moved := True;
        Inc(Steps);
        Break;
      end;
    if Steps > MaximumAliasSteps then
      Exit(False);
  until not Moved;
  Result := True;
end;

{ The records of RecordType for Name (aliases followed) into Found;
  Message is the caller's (large) buffer. }
function QueryAddresses(Name: PChar; RecordType: Word; constref Options: TDnsQueryOptions;
  var Message: TDnsMessage; var Found: THostAddresses): LongInt;
var
  Details: TDnsQueryDetails;
  Current: TDnsName;
  Queries: Integer;
  Index: Integer;
  Added: Boolean;
  HadAlias: Boolean;
begin
  Result := QueryDnsSearching(Name, RecordType, Options, Message, Details);
  if Result <> ErrorNone then
    Exit;
  CopyText(@Current[0], @Details.QueriedName[0], DnsNameCapacity);
  Queries := 1;
  repeat
    HadAlias := not DnsNamesAreEqual(@Current[0], @Message.QuestionName[0]);
    if not FollowAliases(Message, Current) then
      Exit(ErrorNotFound);
    HadAlias := HadAlias or not DnsNamesAreEqual(@Current[0], @Message.QuestionName[0]);
    Added := False;
    for Index := 0 to Message.RecordCount - 1 do
      if (Message.Records[Index].Section = DnsSectionAnswer) and
         (Message.Records[Index].RecordType = RecordType) and
         DnsNamesAreEqual(@Message.Records[Index].Name[0], @Current[0]) then
      begin
        AddAddress(Found, Message.Records[Index].Address);
        Added := True;
      end;
    if Added then
    begin
      if Found.CanonicalName[0] = #0 then
        CopyText(@Found.CanonicalName[0], @Current[0], DnsNameCapacity);
      Exit(ErrorNone);
    end;
    { An alias whose target the server did not answer for: ask for it. }
    if not HadAlias or (Message.ResponseCode <> DnsResponseNoError) or (Queries > MaximumAliasSteps) then
      Exit(ResponseError(Message));
    Result := QueryDns(@Current[0], RecordType, Options, Message, Details);
    if Result <> ErrorNone then
      Exit;
    Inc(Queries);
  until False;
end;

function LookUpInDns(Host: PChar; Families: LongWord; var Found: THostAddresses): LongInt;
var
  Options: TDnsQueryOptions;
  Message: PDnsMessage;
  Ipv6Error: LongInt;
begin
  SystemDnsQueryOptions(Options);
  New(Message);
  try
    Result := ErrorNotFound;
    if (Families and HostFamilyIpv4) <> 0 then
      Result := QueryAddresses(Host, DnsTypeA, Options, Message^, Found);
    if (Families and HostFamilyIpv6) <> 0 then
    begin
      Ipv6Error := QueryAddresses(Host, DnsTypeAaaa, Options, Message^, Found);
      if (Families and HostFamilyIpv4) = 0 then
        Result := Ipv6Error;
    end;
  finally
    Dispose(Message);
  end;
  if Found.Count > 0 then
    Result := ErrorNone;
end;

function LookUpHostAddresses(Host: PChar; Families: LongWord; out Found: THostAddresses): LongInt;
var
  Address: TInternetAddress;
  FromFile: THostsFileAddresses;
  Index: Integer;
begin
  Found.Count := 0;
  Found.CanonicalName[0] := #0;
  if (Host = nil) or (Host[0] = #0) then
    Exit(ErrorNotFound);
  if ParseInternetAddress(Host, Address) then
  begin
    CopyText(@Found.CanonicalName[0], Host, DnsNameCapacity);
    if ((Address.Family = AddressFamilyIPv4) and ((Families and HostFamilyIpv4) = 0)) or
       ((Address.Family = AddressFamilyIPv6) and ((Families and HostFamilyIpv6) = 0)) then
      Exit(ErrorNotFound);
    AddAddress(Found, Address);
    Exit(ErrorNone);
  end;
  if LookUpHostsFileName(Host, Families, FromFile) then
  begin
    CopyText(@Found.CanonicalName[0], @FromFile.CanonicalName[0], DnsNameCapacity);
    for Index := 0 to FromFile.Count - 1 do
      if FromFile.Addresses[Index].Family = AddressFamilyIPv4 then
        AddAddress(Found, FromFile.Addresses[Index]);
    for Index := 0 to FromFile.Count - 1 do
      if FromFile.Addresses[Index].Family <> AddressFamilyIPv4 then
        AddAddress(Found, FromFile.Addresses[Index]);
    Exit(ErrorNone);
  end;
  if DnsNamesAreEqual(Host, 'localhost') and ((Families and HostFamilyIpv4) <> 0) then
  begin
    CopyText(@Found.CanonicalName[0], 'localhost', DnsNameCapacity);
    AddAddress(Found, LoopbackIpv4Address);
    Exit(ErrorNone);
  end;
  Result := LookUpInDns(Host, Families, Found);
end;

function LookUpHost(Host: PChar; out Address: TInternetAddress): LongInt;
var
  Found: THostAddresses;
begin
  Address := AnyIpv4Address;
  Result := LookUpHostAddresses(Host, HostFamilyIpv4, Found);
  if (Result = ErrorNone) and (Found.Count > 0) then
    Address := Found.Addresses[0];
end;

function LookUpAddressName(constref Address: TInternetAddress; Name: PChar; Capacity: PtrUInt): LongInt;
var
  FromFile: TDnsName;
  Question: TDnsName;
  Options: TDnsQueryOptions;
  Message: PDnsMessage;
  Details: TDnsQueryDetails;
  Index: Integer;
  Length: PtrUInt;
begin
  if Capacity > 0 then
    Name[0] := #0;
  if LookUpHostsFileAddress(Address, FromFile) then
  begin
    CopyText(Name, @FromFile[0], Capacity);
    Exit(ErrorNone);
  end;
  if not ReverseLookupName(Address, Question) then
    Exit(ErrorAddressFamilyNotSupported);
  SystemDnsQueryOptions(Options);
  New(Message);
  try
    Result := QueryDns(@Question[0], DnsTypePtr, Options, Message^, Details);
    if Result <> ErrorNone then
      Exit;
    if not FollowAliases(Message^, Question) then
      Exit(ErrorNotFound);
    for Index := 0 to Message^.RecordCount - 1 do
      if (Message^.Records[Index].Section = DnsSectionAnswer) and
         (Message^.Records[Index].RecordType = DnsTypePtr) and
         DnsNamesAreEqual(@Message^.Records[Index].Name[0], @Question[0]) then
      begin
        CopyText(Name, @Message^.Records[Index].Target[0], Capacity);
        Length := TextLength(Name);
        if (Length > 1) and (Name[Length - 1] = '.') then
          Name[Length - 1] := #0;
        Exit(ErrorNone);
      end;
    Result := ResponseError(Message^);
  finally
    Dispose(Message);
  end;
end;

function HostLookupErrorMessage(Error: LongInt): PChar;
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
