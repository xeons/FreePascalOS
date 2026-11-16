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
  host - look names up in the DNS

  host [-v] [-T] [-t TYPE] [-W SECONDS] [-R ATTEMPTS] NAME [SERVER]

  Asks the system's DNS servers (or SERVER, a name or an address) about
  NAME, as BIND's host does: its addresses (A, AAAA) and mail servers
  (MX) without -t, the records of TYPE with it (A, AAAA, CNAME, MX, NS,
  TXT, PTR, SOA, ANY, or TYPEnn); an address is looked up backwards (its
  PTR record). A name without a dot is tried in the search domain first.
  -v shows each whole answer as dig does, -T asks over TCP, -W is how
  long to wait for each server (2.5 seconds), -R how many rounds over
  the servers (2). /etc/hosts is not read: host asks the DNS.

  Exit status: 0 if NAME was found, 1 if not, 2 on wrong arguments.
}
program host;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Streams,
  Sys.Text,
  Sys.InternetAddresses,
  Sys.AddressText,
  Sys.DnsNames,
  Sys.DnsMessages,
  Sys.DnsQueries,
  Sys.HostNames,
  Util.CommandLine,
  Util.Messages,
  Util.Numbers,
  Util.Output;

const
  Usage = 'Usage: host [OPTION]... NAME [SERVER]'#10 +
    'Look NAME up in the DNS (an address: its name).'#10 +
    #10 +
    '  -t TYPE       the records wanted (A, AAAA, CNAME, MX, NS, TXT, PTR, SOA, ANY)'#10 +
    '  -v            show the whole answers'#10 +
    '  -T            ask over TCP'#10 +
    '  -W SECONDS    how long to wait for each server (2.5)'#10 +
    '  -R ATTEMPTS   rounds over the servers (2)'#10;

  OptionType = 1;
  OptionVerbose = 2;
  OptionTcp = 3;
  OptionWait = 4;
  OptionAttempts = 5;

var
  Options: TDnsQueryOptions;
  Message: TDnsMessage;
  NameText: string;
  ServerText: string = '';
  HasServer: Boolean = False;
  WantedType: Word = 0;
  Verbose: Boolean = False;
  ShownAliases: Boolean = False;

procedure ParseArguments;
var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Number: QWord;
begin
  SystemDnsQueryOptions(Options);
  CommandLine := TCommandLine.Create([
    CommandOption('t', 'type', True, OptionType),
    CommandOption('v', 'verbose', False, OptionVerbose),
    CommandOption('T', 'tcp', False, OptionTcp),
    CommandOption('W', 'wait', True, OptionWait),
    CommandOption('R', 'retry', True, OptionAttempts)], Usage);
  try
    while CommandLine.NextOption(Code, Value) do
      case Code of
        OptionType:
          if not ParseDnsTypeName(Value, WantedType) then
            Fail(2, Format('invalid type: %s', [Value]));
        OptionVerbose: Verbose := True;
        OptionTcp: Options.TcpOnly := True;
        OptionWait:
          if not ParseThousandths(PChar(Value), Number) or (Number = 0) or (Number > 600000) then
            Fail(2, Format('invalid wait: %s', [Value]))
          else
            Options.TimeoutMilliseconds := LongWord(Number);
        OptionAttempts:
          if not ParseUnsignedDecimal(Value, Number) or (Number = 0) or (Number > 10) then
            Fail(2, Format('invalid number of attempts: %s', [Value]))
          else
            Options.Attempts := LongWord(Number);
      end;
    if CommandLine.OperandCount = 0 then
      FailWithUsageHint('missing name operand');
    if CommandLine.OperandCount > 2 then
      FailWithUsageHint(Format('extra operand ''%s''', [CommandLine.Operands[2]]));
    NameText := CommandLine.Operands[0];
    if CommandLine.OperandCount = 2 then
    begin
      ServerText := CommandLine.Operands[1];
      HasServer := True;
    end;
  finally
    CommandLine.Free;
  end;
end;

procedure UseServerOperand;
var
  Address: TInternetAddress;
  Error: LongInt;
begin
  if not HasServer then
    Exit;
  Error := LookUpAnyHostAddress(ServerText, Address);
  if Error <> ErrorNone then
    Fail(1, Format('couldn''t get address for ''%s'': %s', [ServerText, HostLookupErrorMessage(Error)]));
  UseOnlyDnsServer(Options, MakeSocketAddress(Address, DnsServerPort));
  PrintString(Format('Using domain server:'#10'Name: %s'#10'Address: %s#%d'#10'Aliases: '#10#10,
    [ServerText, AddressToText(Address), DnsServerPort]));
end;

{ --- Short output (as host prints records) -------------------------------- }

function ShortRecordText(constref Entry: TDnsRecord): string;
begin
  case Entry.RecordType of
    DnsTypeA:
      Result := Format('%s has address %s', [Entry.Name, AddressToText(Entry.Address)]);
    DnsTypeAaaa:
      Result := Format('%s has IPv6 address %s', [Entry.Name, AddressToText(Entry.Address)]);
    DnsTypeCname:
      Result := Format('%s is an alias for %s.', [Entry.Name, Entry.Target]);
    DnsTypeMx:
      Result := Format('%s mail is handled by %d %s.', [Entry.Name, Entry.Preference, Entry.Target]);
    DnsTypeNs:
      Result := Format('%s name server %s.', [Entry.Name, Entry.Target]);
    DnsTypePtr:
      Result := Format('%s domain name pointer %s.', [Entry.Name, Entry.Target]);
    DnsTypeTxt:
      Result := Format('%s descriptive text %s', [Entry.Name, Entry.Text]);
    DnsTypeSoa:
      Result := Format('%s has SOA record %s. %s. %u %u %u %u %u', [Entry.Name, Entry.Target, Entry.Mailbox,
        Entry.Serial, Entry.Refresh, Entry.Retry, Entry.Expire, Entry.Minimum]);
  else
    Result := Format('%s has %s record (%d bytes)', [Entry.Name, DnsTypeName(Entry.RecordType),
      Entry.DataLength]);
  end;
end;

{ The answer's records; aliases only the first time. True if a record of
  the type asked for was among them. }
function WriteShortAnswer(RecordType: Word): Boolean;
var
  Entry: TDnsRecord;
begin
  Result := False;
  for Entry in Message.Records do
  begin
    if Entry.Section <> DnsSectionAnswer then
      Continue;
    if (Entry.RecordType = DnsTypeCname) and (RecordType <> DnsTypeCname) and (RecordType <> DnsTypeAny) then
    begin
      if not ShownAliases then
        PrintStringLine(ShortRecordText(Entry));
      Continue;
    end;
    if (Entry.RecordType = RecordType) or (RecordType = DnsTypeAny) then
      Result := True;
    PrintStringLine(ShortRecordText(Entry));
  end;
  ShownAliases := True;
end;

{ --- Verbose output (as dig prints messages) ------------------------------ }

function RecordDataText(constref Entry: TDnsRecord): string;
begin
  case Entry.RecordType of
    DnsTypeA, DnsTypeAaaa:
      Result := AddressToText(Entry.Address);
    DnsTypeCname, DnsTypeNs, DnsTypePtr:
      Result := Entry.Target + '.';
    DnsTypeMx:
      Result := Format('%d %s.', [Entry.Preference, Entry.Target]);
    DnsTypeTxt:
      Result := Entry.Text;
    DnsTypeSoa:
      Result := Format('%s. %s. %u %u %u %u %u', [Entry.Target, Entry.Mailbox, Entry.Serial, Entry.Refresh,
        Entry.Retry, Entry.Expire, Entry.Minimum]);
  else
    Result := Format('\# %d', [Entry.DataLength]);
  end;
end;

procedure WriteSection(Section: TDnsSection; const Title: string);
var
  Index: Integer;
  Wrote: Boolean;
begin
  Wrote := False;
  for Index := 0 to Message.RecordCount - 1 do
  begin
    if Message.Records[Index].Section <> Section then
      Continue;
    if not Wrote then
      PrintStringLine(Format(';; %s SECTION:', [Title]));
    Wrote := True;
    PrintStringLine(Format('%s.'#9'%u'#9'IN'#9'%s'#9'%s', [Message.Records[Index].Name,
      Message.Records[Index].TimeToLive, DnsTypeName(Message.Records[Index].RecordType),
      RecordDataText(Message.Records[Index])]));
  end;
  if Wrote then
    PrintStringLine('');
end;

procedure WriteFlag(Flag: Word; const Name: string);
begin
  if (Message.Flags and Flag) <> 0 then
    PrintString(' ' + Name);
end;

procedure WriteVerboseAnswer(constref Details: TDnsQueryDetails);
begin
  PrintStringLine(Format(';; ->>HEADER<<- opcode: QUERY, status: %s, id: %d',
    [DnsResponseCodeName(Message.ResponseCode), Message.Id]));
  PrintString(';; flags:');
  WriteFlag(DnsFlagResponse, 'qr');
  WriteFlag(DnsFlagAuthoritative, 'aa');
  WriteFlag(DnsFlagTruncated, 'tc');
  WriteFlag(DnsFlagRecursionDesired, 'rd');
  WriteFlag(DnsFlagRecursionAvailable, 'ra');
  PrintString(Format('; QUERY: %d, ANSWER: %d, AUTHORITY: %d, ADDITIONAL: %d'#10#10,
    [Message.QuestionCount, Message.AnswerCount, Message.AuthorityCount, Message.AdditionalCount]));
  PrintString(Format(';; QUESTION SECTION:'#10';%s.'#9#9#9'IN'#9'%s'#10#10,
    [Message.QuestionName, DnsTypeName(Message.QuestionType)]));
  WriteSection(DnsSectionAnswer, 'ANSWER');
  WriteSection(DnsSectionAuthority, 'AUTHORITY');
  WriteSection(DnsSectionAdditional, 'ADDITIONAL');
  PrintStringLine(Format('Received %u bytes from %s#%d in %d ms', [Message.Length,
    AddressToText(SocketAddressHost(Details.Server)), Details.Server.Port, Details.ElapsedMilliseconds]));
  if Details.UsedTcp then
    PrintStringLine(';; (over TCP)');
  PrintStringLine('');
end;

{ --- Lookups ----------------------------------------------------------------- }

procedure FailToReach;
begin
  PrintStringLine(';; connection timed out; no servers could be reached');
  FlushStream(StandardOutput);
  Halt(1);
end;

{ Asks for one type; True if records of it came. A name that does not
  exist ends the program. }
function LookUp(const Name: string; RecordType: Word; Searching, ShowMissing: Boolean): Boolean;
var
  Details: TDnsQueryDetails;
  Error: LongInt;
begin
  if Verbose then
    PrintStringLine(Format('Trying "%s"', [Name]));
  if Searching then
    Error := QueryDnsSearching(Name, RecordType, Options, Message, Details)
  else
    Error := QueryDns(Name, RecordType, Options, Message, Details);
  if (Error = ErrorTimedOut) or (Error = ErrorConnectionRefused) or (Error = ErrorNetworkUnreachable) then
    FailToReach;
  if Error = ErrorNotFound then
    Fail(1, 'no DNS server is configured');
  if Error <> ErrorNone then
    Fail(1, Format('%s: %s', [Name, ErrorText(Error)]));
  if Verbose then
    WriteVerboseAnswer(Details);
  if Message.ResponseCode <> DnsResponseNoError then
  begin
    PrintStringLine(Format('Host %s not found: %d(%s)', [Name, Message.ResponseCode,
      DnsResponseCodeName(Message.ResponseCode)]));
    FlushStream(StandardOutput);
    Halt(1);
  end;
  if Verbose then
    Result := Message.AnswerCount > 0
  else
    Result := WriteShortAnswer(RecordType);
  if not Result and ShowMissing then
    PrintStringLine(Format('%s has no %s record', [Details.QueriedName, DnsTypeName(RecordType)]));
end;

procedure LookUpAddress(constref Address: TInternetAddress);
var
  Question: string;
begin
  if not ReverseLookupName(Address, Question) then
    Fail(1, Format('%s: address family not supported', [NameText]));
  if not LookUp(Question, DnsTypePtr, False, True) then
    Halt(1);
end;

procedure LookUpName;
var
  FoundAny: Boolean;
begin
  if WantedType <> 0 then
  begin
    if not LookUp(NameText, WantedType, True, True) then
      Halt(1);
    Exit;
  end;
  FoundAny := LookUp(NameText, DnsTypeA, True, False);
  if LookUp(NameText, DnsTypeAaaa, True, False) then
    FoundAny := True;
  if LookUp(NameText, DnsTypeMx, True, False) then
    FoundAny := True;
  if not FoundAny then
    Halt(1);
end;

var
  Address: TInternetAddress;
begin
  ParseArguments;
  UseServerOperand;
  if TextToAddress(NameText, Address) and ((WantedType = 0) or (WantedType = DnsTypePtr)) then
    LookUpAddress(Address)
  else
    LookUpName;
  FlushStream(StandardOutput);
end.
