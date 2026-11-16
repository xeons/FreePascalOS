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
  nslookup - ask a DNS server about a name

  nslookup [-type=TYPE] [-timeout=SECONDS] [-vc] NAME [SERVER]

  The non-interactive form of BIND's nslookup: asks the first of the
  system's DNS servers (or SERVER, a name or an address) about NAME and
  prints the server, then the answer - the addresses (A, then AAAA)
  without -type, the records of TYPE with it (A, AAAA, CNAME, MX, NS,
  TXT, PTR, SOA, ANY); an address is looked up backwards (PTR). A name
  without a dot is tried in the search domain first. -query= is the
  same as -type=; -vc asks over TCP.

  Exit status: 0 if the server answered with records, 1 otherwise.
}
program nslookup;

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Errors,
  Sys.Environment,
  Sys.Format,
  Sys.Streams,
  Sys.Text,
  Sys.InternetAddresses,
  Sys.DnsNames,
  Sys.DnsMessages,
  Sys.DnsQueries,
  Sys.HostNames,
  Util.Messages;

var
  Options: TDnsQueryOptions;
  Message: TDnsMessage;
  NameText: PChar = nil;
  ServerText: PChar = nil;
  WantedType: Word = 0;
  WroteAnswerHeading: Boolean = False;

procedure WriteUsage;
begin
  WriteLine(StandardError, 'Usage: nslookup [-type=TYPE] [-timeout=SECONDS] [-vc] NAME [SERVER]');
  FlushStream(StandardError);
  Halt(2);
end;

{ "-type=MX": the text after "=", if Argument starts with Prefix. }
function OptionValue(Argument, Prefix: PChar; out Value: PChar): Boolean;
begin
  Result := TextStartsWith(Argument, Prefix);
  if Result then
    Value := Argument + TextLength(Prefix);
end;

procedure ParseArguments;
var
  Index: Integer;
  Argument: PChar;
  Value: PChar;
  Number: QWord;
begin
  SystemDnsQueryOptions(Options);
  for Index := 1 to ArgumentTotal - 1 do
  begin
    Argument := Sys.Environment.Argument(Index);
    if OptionValue(Argument, '-type=', Value) or OptionValue(Argument, '-query=', Value) or
       OptionValue(Argument, '-q=', Value) or OptionValue(Argument, '-t=', Value) then
    begin
      if not ParseDnsTypeName(Value, WantedType) then
        Fail(1, 'invalid type: %s', [ArgumentText(Value)]);
    end
    else if OptionValue(Argument, '-timeout=', Value) then
    begin
      if not ParseUnsigned(Value, Number) or (Number = 0) or (Number > 600) then
        Fail(1, 'invalid timeout: %s', [ArgumentText(Value)]);
      Options.TimeoutMilliseconds := LongWord(Number * 1000);
    end
    else if TextIsEqual(Argument, '-vc') then
      Options.TcpOnly := True
    else if (Argument[0] = '-') and (Argument[1] <> #0) then
      WriteUsage
    else if NameText = nil then
      NameText := Argument
    else if ServerText = nil then
      ServerText := Argument
    else
      WriteUsage;
  end;
  if NameText = nil then
    WriteUsage;
end;

procedure WriteServer;
var
  Address: TInternetAddress;
  Text: array[0..InternetAddressTextCapacity - 1] of Char;
  Error: LongInt;
begin
  if ServerText <> nil then
  begin
    Error := LookUpHost(ServerText, Address);
    if Error <> ErrorNone then
      Fail(1, 'couldn''t get address for ''%s'': %s', [ArgumentText(ServerText),
        ArgumentText(HostLookupErrorMessage(Error))]);
    UseOnlyDnsServer(Options, MakeSocketAddress(Address, DnsServerPort));
  end
  else if Options.ServerCount = 0 then
    Fail(1, 'no DNS server is configured', [])
  else
    { The first server only, as nslookup asks. }
    Options.ServerCount := 1;
  FormatInternetAddress(SocketAddressHost(Options.Servers[0]), @Text[0], SizeOf(Text));
  WriteFormatted(StandardOutput, 'Server:'#9#9'%s'#10'Address:'#9'%s#%u'#10#10, [ArgumentText(@Text[0]),
    ArgumentText(@Text[0]), ArgumentUnsigned(Options.Servers[0].Port)]);
end;

procedure WriteAnswerHeading;
begin
  if WroteAnswerHeading then
    Exit;
  WroteAnswerHeading := True;
  if (Message.Flags and DnsFlagAuthoritative) = 0 then
    WriteLine(StandardOutput, 'Non-authoritative answer:');
end;

procedure WriteRecord(constref Entry: TDnsRecord);
var
  Text: array[0..InternetAddressTextCapacity - 1] of Char;
  Name: PChar;
begin
  Name := @Entry.Name[0];
  case Entry.RecordType of
    DnsTypeA, DnsTypeAaaa:
      WriteFormatted(StandardOutput, 'Name:'#9'%s'#10'Address: %s'#10, [ArgumentText(Name),
        ArgumentText(FormatInternetAddress(Entry.Address, @Text[0], SizeOf(Text)))]);
    DnsTypeCname:
      WriteFormatted(StandardOutput, '%s'#9'canonical name = %s.'#10, [ArgumentText(Name),
        ArgumentText(@Entry.Target[0])]);
    DnsTypeMx:
      WriteFormatted(StandardOutput, '%s'#9'mail exchanger = %u %s.'#10, [ArgumentText(Name),
        ArgumentUnsigned(Entry.Preference), ArgumentText(@Entry.Target[0])]);
    DnsTypeNs:
      WriteFormatted(StandardOutput, '%s'#9'nameserver = %s.'#10, [ArgumentText(Name), ArgumentText(@Entry.Target[0])]);
    DnsTypePtr:
      WriteFormatted(StandardOutput, '%s'#9'name = %s.'#10, [ArgumentText(Name), ArgumentText(@Entry.Target[0])]);
    DnsTypeTxt:
      WriteFormatted(StandardOutput, '%s'#9'text = %s'#10, [ArgumentText(Name), ArgumentText(@Entry.Text[0])]);
    DnsTypeSoa:
      WriteFormatted(StandardOutput, '%s'#10#9'origin = %s'#10#9'mail addr = %s'#10#9'serial = %u'#10 +
        #9'refresh = %u'#10#9'retry = %u'#10#9'expire = %u'#10#9'minimum = %u'#10, [ArgumentText(Name),
        ArgumentText(@Entry.Target[0]), ArgumentText(@Entry.Mailbox[0]), ArgumentUnsigned(Entry.Serial),
        ArgumentUnsigned(Entry.Refresh), ArgumentUnsigned(Entry.Retry), ArgumentUnsigned(Entry.Expire),
        ArgumentUnsigned(Entry.Minimum)]);
  else
    WriteFormatted(StandardOutput, '%s'#9'rdata_%u = (%u bytes)'#10, [ArgumentText(Name),
      ArgumentUnsigned(Entry.RecordType), ArgumentUnsigned(Entry.DataLength)]);
  end;
end;

{ Asks for one type and prints its answer; True if records came. }
function LookUp(Name: PChar; RecordType: Word; Searching, AliasesToo: Boolean): Boolean;
var
  Details: TDnsQueryDetails;
  Error: LongInt;
  Index: Integer;
  Entry: PDnsRecord;
begin
  if Searching then
    Error := QueryDnsSearching(Name, RecordType, Options, Message, Details)
  else
    Error := QueryDns(Name, RecordType, Options, Message, Details);
  if Error <> ErrorNone then
  begin
    if (Error = ErrorTimedOut) or (Error = ErrorConnectionRefused) or (Error = ErrorNetworkUnreachable) then
      WriteLine(StandardOutput, ';; connection timed out; no servers could be reached')
    else
      WriteFormatted(StandardOutput, '** %s: %s'#10, [ArgumentText(Name), ArgumentText(ErrorMessage(Error))]);
    FlushStream(StandardOutput);
    Halt(1);
  end;
  if Message.ResponseCode <> DnsResponseNoError then
  begin
    WriteFormatted(StandardOutput, '** server can''t find %s: %s'#10#10, [ArgumentText(Name),
      ArgumentText(DnsResponseCodeName(Message.ResponseCode))]);
    FlushStream(StandardOutput);
    Halt(1);
  end;
  Result := False;
  for Index := 0 to Message.RecordCount - 1 do
  begin
    Entry := @Message.Records[Index];
    if Entry^.Section <> DnsSectionAnswer then
      Continue;
    if (Entry^.RecordType = DnsTypeCname) and (RecordType <> DnsTypeCname) and not AliasesToo then
      Continue;
    WriteAnswerHeading;
    WriteRecord(Entry^);
    Result := True;
  end;
end;

procedure LookUpEverything;
var
  Address: TInternetAddress;
  Question: TDnsName;
  Found: Boolean;
begin
  if ParseInternetAddress(NameText, Address) and ((WantedType = 0) or (WantedType = DnsTypePtr)) then
  begin
    ReverseLookupName(Address, Question);
    Found := LookUp(@Question[0], DnsTypePtr, False, True);
  end
  else if WantedType <> 0 then
    Found := LookUp(NameText, WantedType, True, True)
  else
  begin
    Found := LookUp(NameText, DnsTypeA, True, True);
    if LookUp(NameText, DnsTypeAaaa, True, False) then
      Found := True;
  end;
  if not Found then
    WriteFormatted(StandardOutput, '*** Can''t find %s: No answer'#10, [ArgumentText(NameText)]);
  WriteCharacter(StandardOutput, #10);
  FlushStream(StandardOutput);
  if not Found then
    Halt(1);
end;

begin
  ParseArguments;
  WriteServer;
  LookUpEverything;
end.
