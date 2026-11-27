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

{$mode objfpc}{$H+}

uses
  SysUtils,
  StrUtils,
  Abi.SystemCalls,
  Sys.Streams,
  Sys.InternetAddresses,
  Sys.AddressText,
  Sys.DnsNames,
  Sys.DnsMessages,
  Sys.DnsQueries,
  Sys.HostNames,
  Util.CommandLine,
  Util.Messages,
  Util.Numbers;

var
  Options: TDnsQueryOptions;
  Message: TDnsMessage;
  NameText: string = '';
  HasName: Boolean = False;
  ServerText: string = '';
  HasServer: Boolean = False;
  WantedType: Word = 0;
  WroteAnswerHeading: Boolean = False;

procedure WriteUsage;
begin
  PrintErrorStringLine('Usage: nslookup [-type=TYPE] [-timeout=SECONDS] [-vc] NAME [SERVER]');
  FlushStream(StandardError);
  Halt(2);
end;

{ "-type=MX": the text after "=", if Argument starts with Prefix. }
function OptionValue(const Argument, Prefix: string; out Value: string): Boolean;
begin
  Result := StartsStr(Prefix, Argument);
  if Result then
    Value := Copy(Argument, Length(Prefix) + 1, MaxInt);
end;

procedure ParseArguments;
var
  Argument: string;
  Value: string;
  Number: QWord;
begin
  SystemDnsQueryOptions(Options);
  for Argument in ProgramArguments do
  begin
    if OptionValue(Argument, '-type=', Value) or OptionValue(Argument, '-query=', Value) or
       OptionValue(Argument, '-q=', Value) or OptionValue(Argument, '-t=', Value) then
    begin
      if not ParseDnsTypeName(Value, WantedType) then
        Fail(1, Format('invalid type: %s', [Value]));
    end
    else if OptionValue(Argument, '-timeout=', Value) then
    begin
      if not ParseUnsignedDecimal(Value, Number) or (Number = 0) or (Number > 600) then
        Fail(1, Format('invalid timeout: %s', [Value]));
      Options.TimeoutMilliseconds := LongWord(Number * 1000);
    end
    else if Argument = '-vc' then
      Options.TcpOnly := True
    else if (Length(Argument) > 1) and (Argument[1] = '-') then
      WriteUsage
    else if not HasName then
    begin
      NameText := Argument;
      HasName := True;
    end
    else if not HasServer then
    begin
      ServerText := Argument;
      HasServer := True;
    end
    else
      WriteUsage;
  end;
  if not HasName then
    WriteUsage;
end;

procedure WriteServer;
var
  Address: TInternetAddress;
  Text: string;
  Error: LongInt;
begin
  if HasServer then
  begin
    Error := LookUpAnyHostAddress(ServerText, Address);
    if Error <> ErrorNone then
      Fail(1, Format('couldn''t get address for ''%s'': %s', [ServerText, HostLookupErrorMessage(Error)]));
    UseOnlyDnsServer(Options, MakeSocketAddress(Address, DnsServerPort));
  end
  else if Length(Options.Servers) = 0 then
    Fail(1, 'no DNS server is configured')
  else
    { The first server only, as nslookup asks. }
    SetLength(Options.Servers, 1);
  Text := AddressToText(SocketAddressHost(Options.Servers[0]));
  PrintString(Format('Server:'#9#9'%s'#10'Address:'#9'%s#%d'#10#10, [Text, Text, Options.Servers[0].Port]));
end;

procedure WriteAnswerHeading;
begin
  if WroteAnswerHeading then
    Exit;
  WroteAnswerHeading := True;
  if (Message.Flags and DnsFlagAuthoritative) = 0 then
    PrintStringLine('Non-authoritative answer:');
end;

function RecordText(constref Entry: TDnsRecord): string;
begin
  case Entry.RecordType of
    DnsTypeA, DnsTypeAaaa:
      Result := Format('Name:'#9'%s'#10'Address: %s', [Entry.Name, AddressToText(Entry.Address)]);
    DnsTypeCname:
      Result := Format('%s'#9'canonical name = %s.', [Entry.Name, Entry.Target]);
    DnsTypeMx:
      Result := Format('%s'#9'mail exchanger = %d %s.', [Entry.Name, Entry.Preference, Entry.Target]);
    DnsTypeNs:
      Result := Format('%s'#9'nameserver = %s.', [Entry.Name, Entry.Target]);
    DnsTypePtr:
      Result := Format('%s'#9'name = %s.', [Entry.Name, Entry.Target]);
    DnsTypeTxt:
      Result := Format('%s'#9'text = %s', [Entry.Name, Entry.Text]);
    DnsTypeSoa:
      Result := Format('%s'#10#9'origin = %s'#10#9'mail addr = %s'#10#9'serial = %u'#10 +
        #9'refresh = %u'#10#9'retry = %u'#10#9'expire = %u'#10#9'minimum = %u', [Entry.Name,
        Entry.Target, Entry.Mailbox, Entry.Serial, Entry.Refresh, Entry.Retry, Entry.Expire, Entry.Minimum]);
  else
    Result := Format('%s'#9'rdata_%d = (%d bytes)', [Entry.Name, Entry.RecordType, Entry.DataLength]);
  end;
end;

{ Asks for one type and prints its answer; True if records came. }
function LookUp(const Name: string; RecordType: Word; Searching, AliasesToo: Boolean): Boolean;
var
  Details: TDnsQueryDetails;
  Error: LongInt;
  Entry: TDnsRecord;
begin
  if Searching then
    Error := QueryDnsSearching(Name, RecordType, Options, Message, Details)
  else
    Error := QueryDns(Name, RecordType, Options, Message, Details);
  if Error <> ErrorNone then
  begin
    if (Error = ErrorTimedOut) or (Error = ErrorConnectionRefused) or (Error = ErrorNetworkUnreachable) then
      PrintStringLine(';; connection timed out; no servers could be reached')
    else
      PrintStringLine(Format('** %s: %s', [Name, ErrorText(Error)]));
    FlushStream(StandardOutput);
    Halt(1);
  end;
  if Message.ResponseCode <> DnsResponseNoError then
  begin
    PrintString(Format('** server can''t find %s: %s'#10#10, [Name, DnsResponseCodeName(Message.ResponseCode)]));
    FlushStream(StandardOutput);
    Halt(1);
  end;
  Result := False;
  for Entry in Message.Records do
  begin
    if Entry.Section <> DnsSectionAnswer then
      Continue;
    if (Entry.RecordType = DnsTypeCname) and (RecordType <> DnsTypeCname) and not AliasesToo then
      Continue;
    WriteAnswerHeading;
    PrintStringLine(RecordText(Entry));
    Result := True;
  end;
end;

procedure LookUpEverything;
var
  Address: TInternetAddress;
  Question: string;
  Found: Boolean;
begin
  if TextToAddress(NameText, Address) and ((WantedType = 0) or (WantedType = DnsTypePtr)) then
  begin
    ReverseLookupName(Address, Question);
    Found := LookUp(Question, DnsTypePtr, False, True);
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
    PrintStringLine(Format('*** Can''t find %s: No answer', [NameText]));
  PrintStringLine('');
  FlushStream(StandardOutput);
  if not Found then
    Halt(1);
end;

begin
  ParseArguments;
  WriteServer;
  LookUpEverything;
end.
