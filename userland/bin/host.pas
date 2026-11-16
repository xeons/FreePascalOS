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

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Errors,
  Sys.Format,
  Sys.Streams,
  Sys.Text,
  Sys.InternetAddresses,
  Sys.DnsNames,
  Sys.DnsMessages,
  Sys.DnsQueries,
  Sys.HostNames,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: host [OPTION]... NAME [SERVER]'#10 +
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
  NameText: PChar;
  ServerText: PChar = nil;
  WantedType: Word = 0;
  Verbose: Boolean = False;
  ShownAliases: Boolean = False;

procedure ParseArguments;
var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Number: QWord;
begin
  SystemDnsQueryOptions(Options);
  BeginOptions(Parser, [
    OptionDefinition('t', 'type', True, OptionType),
    OptionDefinition('v', 'verbose', False, OptionVerbose),
    OptionDefinition('T', 'tcp', False, OptionTcp),
    OptionDefinition('W', 'wait', True, OptionWait),
    OptionDefinition('R', 'retry', True, OptionAttempts)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionType:
        if not ParseDnsTypeName(Value, WantedType) then
          Fail(2, 'invalid type: %s', [ArgumentText(Value)]);
      OptionVerbose: Verbose := True;
      OptionTcp: Options.TcpOnly := True;
      OptionWait:
        if not ParseThousandths(Value, Number) or (Number = 0) or (Number > 600000) then
          Fail(2, 'invalid wait: %s', [ArgumentText(Value)])
        else
          Options.TimeoutMilliseconds := LongWord(Number);
      OptionAttempts:
        if not ParseUnsigned(Value, Number) or (Number = 0) or (Number > 10) then
          Fail(2, 'invalid number of attempts: %s', [ArgumentText(Value)])
        else
          Options.Attempts := LongWord(Number);
    end;
  if Parser.OperandCount = 0 then
    FailWithUsageHint('missing name operand', []);
  if Parser.OperandCount > 2 then
    FailWithUsageHint('extra operand ''%s''', [ArgumentText(Parser.Operands[2])]);
  NameText := Parser.Operands[0];
  if Parser.OperandCount = 2 then
    ServerText := Parser.Operands[1];
end;

procedure UseServerOperand;
var
  Address: TInternetAddress;
  Text: array[0..InternetAddressTextCapacity - 1] of Char;
  Error: LongInt;
begin
  if ServerText = nil then
    Exit;
  Error := LookUpHost(ServerText, Address);
  if Error <> ErrorNone then
    Fail(1, 'couldn''t get address for ''%s'': %s', [ArgumentText(ServerText),
      ArgumentText(HostLookupErrorMessage(Error))]);
  UseOnlyDnsServer(Options, MakeSocketAddress(Address, DnsServerPort));
  FormatInternetAddress(Address, @Text[0], SizeOf(Text));
  WriteFormatted(StandardOutput, 'Using domain server:'#10'Name: %s'#10'Address: %s#%u'#10'Aliases: '#10#10,
    [ArgumentText(ServerText), ArgumentText(@Text[0]), ArgumentUnsigned(DnsServerPort)]);
end;

var
  TypeTextBuffer: array[0..15] of Char;

{ The type's name; valid until the next call. }
function TypeText(RecordType: Word): PChar;
begin
  Result := DnsTypeName(RecordType, @TypeTextBuffer[0], SizeOf(TypeTextBuffer));
end;

{ --- Short output (as host prints records) -------------------------------- }

procedure WriteShortRecord(constref Entry: TDnsRecord);
var
  Text: array[0..InternetAddressTextCapacity - 1] of Char;
  Name: PChar;
begin
  Name := @Entry.Name[0];
  case Entry.RecordType of
    DnsTypeA:
      WriteFormatted(StandardOutput, '%s has address %s'#10, [ArgumentText(Name),
        ArgumentText(FormatInternetAddress(Entry.Address, @Text[0], SizeOf(Text)))]);
    DnsTypeAaaa:
      WriteFormatted(StandardOutput, '%s has IPv6 address %s'#10, [ArgumentText(Name),
        ArgumentText(FormatInternetAddress(Entry.Address, @Text[0], SizeOf(Text)))]);
    DnsTypeCname:
      WriteFormatted(StandardOutput, '%s is an alias for %s.'#10, [ArgumentText(Name),
        ArgumentText(@Entry.Target[0])]);
    DnsTypeMx:
      WriteFormatted(StandardOutput, '%s mail is handled by %u %s.'#10, [ArgumentText(Name),
        ArgumentUnsigned(Entry.Preference), ArgumentText(@Entry.Target[0])]);
    DnsTypeNs:
      WriteFormatted(StandardOutput, '%s name server %s.'#10, [ArgumentText(Name), ArgumentText(@Entry.Target[0])]);
    DnsTypePtr:
      WriteFormatted(StandardOutput, '%s domain name pointer %s.'#10, [ArgumentText(Name),
        ArgumentText(@Entry.Target[0])]);
    DnsTypeTxt:
      WriteFormatted(StandardOutput, '%s descriptive text %s'#10, [ArgumentText(Name), ArgumentText(@Entry.Text[0])]);
    DnsTypeSoa:
      WriteFormatted(StandardOutput, '%s has SOA record %s. %s. %u %u %u %u %u'#10, [ArgumentText(Name),
        ArgumentText(@Entry.Target[0]), ArgumentText(@Entry.Mailbox[0]), ArgumentUnsigned(Entry.Serial),
        ArgumentUnsigned(Entry.Refresh), ArgumentUnsigned(Entry.Retry), ArgumentUnsigned(Entry.Expire),
        ArgumentUnsigned(Entry.Minimum)]);
  else
    WriteFormatted(StandardOutput, '%s has %s record (%u bytes)'#10, [ArgumentText(Name),
      ArgumentText(TypeText(Entry.RecordType)), ArgumentUnsigned(Entry.DataLength)]);
  end;
end;

{ The answer's records; aliases only the first time. True if a record of
  the type asked for was among them. }
function WriteShortAnswer(RecordType: Word): Boolean;
var
  Index: Integer;
  Entry: PDnsRecord;
begin
  Result := False;
  for Index := 0 to Message.RecordCount - 1 do
  begin
    Entry := @Message.Records[Index];
    if Entry^.Section <> DnsSectionAnswer then
      Continue;
    if (Entry^.RecordType = DnsTypeCname) and (RecordType <> DnsTypeCname) and (RecordType <> DnsTypeAny) then
    begin
      if not ShownAliases then
        WriteShortRecord(Entry^);
      Continue;
    end;
    if (Entry^.RecordType = RecordType) or (RecordType = DnsTypeAny) then
      Result := True;
    WriteShortRecord(Entry^);
  end;
  ShownAliases := True;
end;

{ --- Verbose output (as dig prints messages) ------------------------------ }

procedure WriteRecordData(constref Entry: TDnsRecord);
var
  Text: array[0..InternetAddressTextCapacity - 1] of Char;
begin
  case Entry.RecordType of
    DnsTypeA, DnsTypeAaaa:
      WriteText(StandardOutput, FormatInternetAddress(Entry.Address, @Text[0], SizeOf(Text)));
    DnsTypeCname, DnsTypeNs, DnsTypePtr:
      WriteFormatted(StandardOutput, '%s.', [ArgumentText(@Entry.Target[0])]);
    DnsTypeMx:
      WriteFormatted(StandardOutput, '%u %s.', [ArgumentUnsigned(Entry.Preference), ArgumentText(@Entry.Target[0])]);
    DnsTypeTxt:
      WriteText(StandardOutput, @Entry.Text[0]);
    DnsTypeSoa:
      WriteFormatted(StandardOutput, '%s. %s. %u %u %u %u %u', [ArgumentText(@Entry.Target[0]),
        ArgumentText(@Entry.Mailbox[0]), ArgumentUnsigned(Entry.Serial), ArgumentUnsigned(Entry.Refresh),
        ArgumentUnsigned(Entry.Retry), ArgumentUnsigned(Entry.Expire), ArgumentUnsigned(Entry.Minimum)]);
  else
    WriteFormatted(StandardOutput, '\# %u', [ArgumentUnsigned(Entry.DataLength)]);
  end;
end;

procedure WriteSection(Section: TDnsSection; Title: PChar);
var
  Index: Integer;
  Entry: PDnsRecord;
  Wrote: Boolean;
begin
  Wrote := False;
  for Index := 0 to Message.RecordCount - 1 do
  begin
    Entry := @Message.Records[Index];
    if Entry^.Section <> Section then
      Continue;
    if not Wrote then
      WriteFormatted(StandardOutput, ';; %s SECTION:'#10, [ArgumentText(Title)]);
    Wrote := True;
    WriteFormatted(StandardOutput, '%s.'#9'%u'#9'IN'#9'%s'#9, [ArgumentText(@Entry^.Name[0]),
      ArgumentUnsigned(Entry^.TimeToLive), ArgumentText(TypeText(Entry^.RecordType))]);
    WriteRecordData(Entry^);
    WriteCharacter(StandardOutput, #10);
  end;
  if Wrote then
    WriteCharacter(StandardOutput, #10);
end;

procedure WriteFlag(Flag: Word; Name: PChar);
begin
  if (Message.Flags and Flag) <> 0 then
    WriteFormatted(StandardOutput, ' %s', [ArgumentText(Name)]);
end;

procedure WriteVerboseAnswer(constref Details: TDnsQueryDetails);
var
  Server: array[0..SocketAddressTextCapacity - 1] of Char;
begin
  WriteFormatted(StandardOutput, ';; ->>HEADER<<- opcode: QUERY, status: %s, id: %u'#10,
    [ArgumentText(DnsResponseCodeName(Message.ResponseCode)), ArgumentUnsigned(Message.Id)]);
  WriteText(StandardOutput, ';; flags:');
  WriteFlag(DnsFlagResponse, 'qr');
  WriteFlag(DnsFlagAuthoritative, 'aa');
  WriteFlag(DnsFlagTruncated, 'tc');
  WriteFlag(DnsFlagRecursionDesired, 'rd');
  WriteFlag(DnsFlagRecursionAvailable, 'ra');
  WriteFormatted(StandardOutput, '; QUERY: %u, ANSWER: %u, AUTHORITY: %u, ADDITIONAL: %u'#10#10,
    [ArgumentUnsigned(Message.QuestionCount), ArgumentUnsigned(Message.AnswerCount),
    ArgumentUnsigned(Message.AuthorityCount), ArgumentUnsigned(Message.AdditionalCount)]);
  WriteFormatted(StandardOutput, ';; QUESTION SECTION:'#10';%s.'#9#9#9'IN'#9'%s'#10#10,
    [ArgumentText(@Message.QuestionName[0]), ArgumentText(TypeText(Message.QuestionType))]);
  WriteSection(DnsSectionAnswer, 'ANSWER');
  WriteSection(DnsSectionAuthority, 'AUTHORITY');
  WriteSection(DnsSectionAdditional, 'ADDITIONAL');
  FormatInternetAddress(SocketAddressHost(Details.Server), @Server[0], SizeOf(Server));
  WriteFormatted(StandardOutput, 'Received %u bytes from %s#%u in %u ms'#10, [ArgumentUnsigned(Message.Length),
    ArgumentText(@Server[0]), ArgumentUnsigned(Details.Server.Port), ArgumentUnsigned(Details.ElapsedMilliseconds)]);
  if Details.UsedTcp then
    WriteLine(StandardOutput, ';; (over TCP)');
  WriteCharacter(StandardOutput, #10);
end;

{ --- Lookups ----------------------------------------------------------------- }

procedure FailToReach;
begin
  WriteLine(StandardOutput, ';; connection timed out; no servers could be reached');
  FlushStream(StandardOutput);
  Halt(1);
end;

{ Asks for one type; True if records of it came. A name that does not
  exist ends the program. }
function LookUp(Name: PChar; RecordType: Word; Searching, ShowMissing: Boolean): Boolean;
var
  Details: TDnsQueryDetails;
  Error: LongInt;
begin
  if Verbose then
    WriteFormatted(StandardOutput, 'Trying "%s"'#10, [ArgumentText(Name)]);
  if Searching then
    Error := QueryDnsSearching(Name, RecordType, Options, Message, Details)
  else
    Error := QueryDns(Name, RecordType, Options, Message, Details);
  if (Error = ErrorTimedOut) or (Error = ErrorConnectionRefused) or (Error = ErrorNetworkUnreachable) then
    FailToReach;
  if Error = ErrorNotFound then
    Fail(1, 'no DNS server is configured', []);
  if Error <> ErrorNone then
    Fail(1, '%s: %s', [ArgumentText(Name), ArgumentText(ErrorMessage(Error))]);
  if Verbose then
    WriteVerboseAnswer(Details);
  if Message.ResponseCode <> DnsResponseNoError then
  begin
    WriteFormatted(StandardOutput, 'Host %s not found: %u(%s)'#10, [ArgumentText(Name),
      ArgumentUnsigned(Message.ResponseCode), ArgumentText(DnsResponseCodeName(Message.ResponseCode))]);
    FlushStream(StandardOutput);
    Halt(1);
  end;
  if Verbose then
    Result := Message.AnswerCount > 0
  else
    Result := WriteShortAnswer(RecordType);
  if not Result and ShowMissing then
    WriteFormatted(StandardOutput, '%s has no %s record'#10, [ArgumentText(@Details.QueriedName[0]),
      ArgumentText(TypeText(RecordType))]);
end;

procedure LookUpAddress(constref Address: TInternetAddress);
var
  Question: TDnsName;
begin
  if not ReverseLookupName(Address, Question) then
    Fail(1, '%s: address family not supported', [ArgumentText(NameText)]);
  if not LookUp(@Question[0], DnsTypePtr, False, True) then
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
  if ParseInternetAddress(NameText, Address) and ((WantedType = 0) or (WantedType = DnsTypePtr)) then
    LookUpAddress(Address)
  else
    LookUpName;
  FlushStream(StandardOutput);
end.
