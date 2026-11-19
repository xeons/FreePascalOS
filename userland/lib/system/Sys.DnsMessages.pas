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
  DNS messages (RFC 1035, section 4): building a query and reading a
  response into records.

  A message is a 12-byte header (the id, the flags with the response
  code, and the number of entries in each section), the question, and
  three sections of resource records: the answer, the authority and the
  additional records. Each record has an owner name, a type, a class, a
  time to live and its data; the data of the types tools show is read
  into fields (A and AAAA: an address; CNAME, NS, PTR: a name; MX: a
  preference and a name; SOA: two names and five numbers; TXT: its
  strings), of any other type only its length is kept.

  Everything read is checked against the message's length, and names
  go through Sys.DnsNames (pointers only backwards), so a damaged or
  hostile message is refused, never read past its end.

  EDNS(0) (RFC 6891): a query may carry an OPT pseudo-record in its
  additional section - owner the root, type 41, the class the largest
  UDP reply the asker takes, the time to live the extended response
  code, the version (0) and the flags, no data - so a server may answer
  over UDP with more than 512 bytes. A reply's OPT record is not kept
  with the others: it fills the message's Edns fields, and its extended
  response code goes into ResponseCode.
}
unit Sys.DnsMessages;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Sys.InternetAddresses;

const
  DnsHeaderBytes = 12;
  { The largest message over UDP without extensions. }
  MaximumUdpDnsMessage = 512;
  { What queries advertise with EDNS(0): the size that fits in any
    path's MTU without fragments (the DNS flag day 2020 choice). }
  DefaultEdnsPayloadSize = 1232;
  { An OPT record without options: root, type, class, TTL, length. }
  EdnsRecordBytes = 11;
  { Over TCP: a two-byte length in front. }
  MaximumTcpDnsMessage = 65535;
  { The records kept of one message, the sections together; more are
    left out (and counted in SkippedRecords). }
  MaximumDnsRecords = 32;

  DnsTypeA = 1;
  DnsTypeNs = 2;
  DnsTypeCname = 5;
  DnsTypeSoa = 6;
  DnsTypePtr = 12;
  DnsTypeMx = 15;
  DnsTypeTxt = 16;
  DnsTypeAaaa = 28;
  DnsTypeOpt = 41;
  DnsTypeAny = 255;
  DnsClassInternet = 1;

  { Flags (the header's second and third bytes). }
  DnsFlagResponse = $8000;
  DnsFlagAuthoritative = $0400;
  DnsFlagTruncated = $0200;
  DnsFlagRecursionDesired = $0100;
  DnsFlagRecursionAvailable = $0080;
  DnsResponseCodeMask = $000F;

  { Response codes. }
  DnsResponseNoError = 0;
  DnsResponseFormatError = 1;
  DnsResponseServerFailure = 2;
  DnsResponseNameError = 3;
  DnsResponseNotImplemented = 4;
  DnsResponseRefused = 5;
  { Extended (with EDNS): the server does not speak the version asked. }
  DnsResponseBadVersion = 16;

type
  TDnsSection = (DnsSectionAnswer, DnsSectionAuthority, DnsSectionAdditional);

  TDnsRecord = record
    Section: TDnsSection;
    Name: string;
    RecordType: Word;
    RecordClass: Word;
    TimeToLive: LongWord;
    DataLength: Word;
    { A, AAAA. }
    Address: TInternetAddress;
    { MX. }
    Preference: Word;
    { CNAME, NS, PTR, MX; SOA: the primary server. }
    Target: string;
    { SOA: the administrator's mailbox, and its numbers. }
    Mailbox: string;
    Serial: LongWord;
    Refresh: LongWord;
    Retry: LongWord;
    Expire: LongWord;
    Minimum: LongWord;
    { TXT: each string in double quotes, with spaces between them. }
    Text: string;
  end;

  TDnsMessage = record
    Id: Word;
    Flags: Word;
    ResponseCode: Byte;
    { The first question (a response repeats the query's). }
    QuestionCount: Word;
    QuestionName: string;
    QuestionType: Word;
    QuestionClass: Word;
    { The counts of the header. }
    AnswerCount: Word;
    AuthorityCount: Word;
    AdditionalCount: Word;
    { The records kept, the sections in order (RecordCount of them). }
    RecordCount: Integer;
    SkippedRecords: Integer;
    Records: array of TDnsRecord;
    { Bytes the message had. }
    Length: LongWord;
    { The OPT record (EDNS), if it had one: the largest UDP message its
      sender takes, the version and the flags (DO is $8000). }
    HasEdns: Boolean;
    EdnsPayloadSize: Word;
    EdnsVersion: Byte;
    EdnsFlags: Word;
  end;

{ A query for Name's records of RecordType (class IN) into Buffer;
  Length is its size. False if the name is not a valid one. }
function BuildDnsQuery(Id: Word; const Name: string; RecordType: Word; RecursionDesired: Boolean; Buffer: PByte;
  Capacity: LongWord; out Length: LongWord): Boolean;
{ The same with an OPT record advertising EdnsPayloadSize (0: none). }
function BuildDnsQuery(Id: Word; const Name: string; RecordType: Word; RecursionDesired: Boolean;
  EdnsPayloadSize: Word; Buffer: PByte; Capacity: LongWord; out Length: LongWord): Boolean;
{ Appends an OPT record (EDNS version 0, no flags, no options) to the
  message of Length bytes in Buffer and counts it in the header's
  additional records. False if it does not fit. }
function AppendEdnsRecord(Buffer: PByte; Capacity: LongWord; var Length: LongWord; PayloadSize: Word): Boolean;
{ Reads a whole message. False if it is damaged. }
function ParseDnsMessage(Data: PByte; Length: LongWord; out Message: TDnsMessage): Boolean;
{ Reads only the header and the first question (to match a response
  with its query before reading the rest). }
function ParseDnsHeader(Data: PByte; Length: LongWord; out Id, Flags: Word; out QuestionName: string;
  out QuestionType, QuestionClass: Word): Boolean;

{ "A", "MX", ... ("TYPE99" for others). }
function DnsTypeName(RecordType: Word): string;
{ The type a name stands for ("a", "MX", "TYPE99"). }
function ParseDnsTypeName(const Text: string; out RecordType: Word): Boolean;
{ "NOERROR", "NXDOMAIN", ... }
function DnsResponseCodeName(Code: Byte): string;

implementation

uses
  SysUtils,
  StrUtils,
  Abi.SystemCalls,
  Sys.DnsNames;

function ReadWord(Data: PByte; Position: LongWord): Word;
begin
  Result := (Word(Data[Position]) shl 8) or Data[Position + 1];
end;

function ReadLongWord(Data: PByte; Position: LongWord): LongWord;
begin
  Result := (LongWord(Data[Position]) shl 24) or (LongWord(Data[Position + 1]) shl 16) or
    (LongWord(Data[Position + 2]) shl 8) or Data[Position + 3];
end;

procedure WriteWord(Data: PByte; Position: LongWord; Value: Word);
begin
  Data[Position] := Byte(Value shr 8);
  Data[Position + 1] := Byte(Value);
end;

function AppendEdnsRecord(Buffer: PByte; Capacity: LongWord; var Length: LongWord; PayloadSize: Word): Boolean;
var
  Position: LongWord;
begin
  if (Length < DnsHeaderBytes) or (Length + EdnsRecordBytes > Capacity) then
    Exit(False);
  Position := Length;
  { The root, the type, the class (the payload size), the TTL (extended
    response code 0, version 0, flags 0) and no data. }
  Buffer[Position] := 0;
  WriteWord(Buffer, Position + 1, DnsTypeOpt);
  WriteWord(Buffer, Position + 3, PayloadSize);
  FillChar(Buffer[Position + 5], 6, 0);
  Length := Position + EdnsRecordBytes;
  WriteWord(Buffer, 10, ReadWord(Buffer, 10) + 1);
  Result := True;
end;

function BuildDnsQuery(Id: Word; const Name: string; RecordType: Word; RecursionDesired: Boolean;
  EdnsPayloadSize: Word; Buffer: PByte; Capacity: LongWord; out Length: LongWord): Boolean;
begin
  Result := BuildDnsQuery(Id, Name, RecordType, RecursionDesired, Buffer, Capacity, Length);
  if Result and (EdnsPayloadSize <> 0) then
    Result := AppendEdnsRecord(Buffer, Capacity, Length, EdnsPayloadSize);
end;

function BuildDnsQuery(Id: Word; const Name: string; RecordType: Word; RecursionDesired: Boolean; Buffer: PByte;
  Capacity: LongWord; out Length: LongWord): Boolean;
var
  Position: LongWord;
  Flags: Word;
begin
  Length := 0;
  if Capacity < DnsHeaderBytes + 4 then
    Exit(False);
  FillChar(Buffer^, DnsHeaderBytes, 0);
  WriteWord(Buffer, 0, Id);
  Flags := 0;
  if RecursionDesired then
    Flags := Flags or DnsFlagRecursionDesired;
  WriteWord(Buffer, 2, Flags);
  WriteWord(Buffer, 4, 1);
  Position := DnsHeaderBytes;
  if not EncodeDnsName(Name, Buffer, Capacity, Position) then
    Exit(False);
  if Position + 4 > Capacity then
    Exit(False);
  WriteWord(Buffer, Position, RecordType);
  WriteWord(Buffer, Position + 2, DnsClassInternet);
  Length := Position + 4;
  Result := True;
end;

function ParseDnsHeader(Data: PByte; Length: LongWord; out Id, Flags: Word; out QuestionName: string;
  out QuestionType, QuestionClass: Word): Boolean;
var
  Position: LongWord;
begin
  Id := 0;
  Flags := 0;
  QuestionName := '';
  QuestionType := 0;
  QuestionClass := 0;
  if Length < DnsHeaderBytes then
    Exit(False);
  Id := ReadWord(Data, 0);
  Flags := ReadWord(Data, 2);
  if ReadWord(Data, 4) = 0 then
    Exit(True);
  Position := DnsHeaderBytes;
  if not DecodeDnsName(Data, Length, Position, QuestionName) or (Position + 4 > Length) then
    Exit(False);
  QuestionType := ReadWord(Data, Position);
  QuestionClass := ReadWord(Data, Position + 2);
  Result := True;
end;

{ TXT: the strings (a length byte each) as "first" "second". }
function ReadTextStrings(Data: PByte; Start, DataLength: LongWord; var Entry: TDnsRecord): Boolean;
var
  Position: LongWord;
  StringLength: LongWord;
  Index: LongWord;
  Character: Char;
begin
  Entry.Text := '';
  Position := Start;
  while Position < Start + DataLength do
  begin
    StringLength := Data[Position];
    Inc(Position);
    if Position + StringLength > Start + DataLength then
      Exit(False);
    if Entry.Text <> '' then
      Entry.Text := Entry.Text + ' ';
    Entry.Text := Entry.Text + '"';
    for Index := 1 to StringLength do
    begin
      Character := Char(Data[Position + Index - 1]);
      if (Character = '"') or (Character = '\') then
        Entry.Text := Entry.Text + '\';
      Entry.Text := Entry.Text + Character;
    end;
    Entry.Text := Entry.Text + '"';
    Position := Position + StringLength;
  end;
  Result := True;
end;

{ The data of the record, Data[Start] to Data[Start + DataLength - 1]. }
function ReadRecordData(Data: PByte; Length, Start: LongWord; var Entry: TDnsRecord): Boolean;
var
  Position: LongWord;
  Finish: LongWord;
begin
  Finish := Start + Entry.DataLength;
  Position := Start;
  Result := False;
  case Entry.RecordType of
    DnsTypeA:
      begin
        if Entry.DataLength <> 4 then
          Exit;
        Entry.Address := Ipv4Address(Data[Start], Data[Start + 1], Data[Start + 2], Data[Start + 3]);
      end;
    DnsTypeAaaa:
      begin
        if Entry.DataLength <> 16 then
          Exit;
        Entry.Address := Default(TInternetAddress);
        Entry.Address.Family := AddressFamilyIPv6;
        Move(Data[Start], Entry.Address.Bytes[0], 16);
      end;
    DnsTypeCname, DnsTypeNs, DnsTypePtr:
      if not DecodeDnsName(Data, Length, Position, Entry.Target) or (Position > Finish) then
        Exit;
    DnsTypeMx:
      begin
        if Entry.DataLength < 3 then
          Exit;
        Entry.Preference := ReadWord(Data, Start);
        Position := Start + 2;
        if not DecodeDnsName(Data, Length, Position, Entry.Target) or (Position > Finish) then
          Exit;
      end;
    DnsTypeSoa:
      begin
        if not DecodeDnsName(Data, Length, Position, Entry.Target) or
           not DecodeDnsName(Data, Length, Position, Entry.Mailbox) or (Position + 20 > Finish) then
          Exit;
        Entry.Serial := ReadLongWord(Data, Position);
        Entry.Refresh := ReadLongWord(Data, Position + 4);
        Entry.Retry := ReadLongWord(Data, Position + 8);
        Entry.Expire := ReadLongWord(Data, Position + 12);
        Entry.Minimum := ReadLongWord(Data, Position + 16);
      end;
    DnsTypeTxt:
      if not ReadTextStrings(Data, Start, Entry.DataLength, Entry) then
        Exit;
  end;
  Result := True;
end;

{ One record at Data[Position]; Position moves past it. Keep: whether to
  read its data into Entry (else only step over it). }
function ReadRecord(Data: PByte; Length: LongWord; var Position: LongWord; Keep: Boolean;
  var Entry: TDnsRecord): Boolean;
var
  DataStart: LongWord;
begin
  Result := False;
  Entry.Target := '';
  Entry.Mailbox := '';
  Entry.Text := '';
  if not DecodeDnsName(Data, Length, Position, Entry.Name) or (Position + 10 > Length) then
    Exit;
  Entry.RecordType := ReadWord(Data, Position);
  Entry.RecordClass := ReadWord(Data, Position + 2);
  Entry.TimeToLive := ReadLongWord(Data, Position + 4);
  Entry.DataLength := ReadWord(Data, Position + 8);
  DataStart := Position + 10;
  if DataStart + Entry.DataLength > Length then
    Exit;
  if Keep and not ReadRecordData(Data, Length, DataStart, Entry) then
    Exit;
  Position := DataStart + Entry.DataLength;
  Result := True;
end;

function SectionRecordCount(constref Message: TDnsMessage; Section: TDnsSection): Word;
begin
  case Section of
    DnsSectionAnswer: Result := Message.AnswerCount;
    DnsSectionAuthority: Result := Message.AuthorityCount;
  else
    Result := Message.AdditionalCount;
  end;
end;

{ The OPT record Entry (its class and time to live) into Message's
  EDNS fields; only the first one counts. }
procedure TakeEdnsRecord(constref Entry: TDnsRecord; var Message: TDnsMessage);
var
  ExtendedCode: LongWord;
begin
  if Message.HasEdns then
    Exit;
  Message.HasEdns := True;
  Message.EdnsPayloadSize := Entry.RecordClass;
  Message.EdnsVersion := Byte(Entry.TimeToLive shr 16);
  Message.EdnsFlags := Word(Entry.TimeToLive and $FFFF);
  ExtendedCode := ((Entry.TimeToLive shr 24) shl 4) or Message.ResponseCode;
  if ExtendedCode <= High(Byte) then
    Message.ResponseCode := Byte(ExtendedCode);
end;

function ParseDnsMessage(Data: PByte; Length: LongWord; out Message: TDnsMessage): Boolean;
var
  Position: LongWord;
  Index: LongWord;
  Section: TDnsSection;
  Entry: TDnsRecord;
  Keep: Boolean;
  RecordStart: LongWord;
begin
  Result := False;
  Message := Default(TDnsMessage);
  Message.Length := Length;
  if not ParseDnsHeader(Data, Length, Message.Id, Message.Flags, Message.QuestionName, Message.QuestionType,
       Message.QuestionClass) then
    Exit;
  Message.ResponseCode := Message.Flags and DnsResponseCodeMask;
  Message.QuestionCount := ReadWord(Data, 4);
  Message.AnswerCount := ReadWord(Data, 6);
  Message.AuthorityCount := ReadWord(Data, 8);
  Message.AdditionalCount := ReadWord(Data, 10);
  Position := DnsHeaderBytes;
  for Index := 1 to Message.QuestionCount do
  begin
    if not SkipDnsName(Data, Length, Position) or (Position + 4 > Length) then
      Exit;
    Position := Position + 4;
  end;
  for Section := Low(TDnsSection) to High(TDnsSection) do
    for Index := 1 to SectionRecordCount(Message, Section) do
    begin
      Keep := Message.RecordCount < MaximumDnsRecords;
      Entry := Default(TDnsRecord);
      Entry.Section := Section;
      RecordStart := Position;
      if not ReadRecord(Data, Length, Position, Keep, Entry) then
        Exit;
      if (Section = DnsSectionAdditional) and (Entry.RecordType = DnsTypeOpt) then
      begin
        { Owned by the root (a zero byte), else not EDNS's. }
        if Data[RecordStart] <> 0 then
          Exit;
        TakeEdnsRecord(Entry, Message);
        Continue;
      end;
      if Keep then
      begin
        SetLength(Message.Records, Message.RecordCount + 1);
        Message.Records[Message.RecordCount] := Entry;
        Inc(Message.RecordCount);
      end
      else
        Inc(Message.SkippedRecords);
    end;
  Result := True;
end;

const
  DnsTypeNames: array[0..9] of string = ('A', 'NS', 'CNAME', 'SOA', 'PTR', 'MX', 'TXT', 'AAAA', 'OPT', 'ANY');
  DnsTypeValues: array[0..9] of Word = (DnsTypeA, DnsTypeNs, DnsTypeCname, DnsTypeSoa, DnsTypePtr, DnsTypeMx,
    DnsTypeTxt, DnsTypeAaaa, DnsTypeOpt, DnsTypeAny);
  UnknownTypePrefix = 'TYPE';

function DnsTypeName(RecordType: Word): string;
var
  Index: Integer;
begin
  for Index := Low(DnsTypeValues) to High(DnsTypeValues) do
    if DnsTypeValues[Index] = RecordType then
      Exit(DnsTypeNames[Index]);
  Result := UnknownTypePrefix + IntToStr(RecordType);
end;

{ Decimal digits, with an optional '+' and spaces around them. }
function IsDecimalNumber(const Text: string; out Value: QWord): Boolean;
var
  Digits: string;
  Character: Char;
begin
  Value := 0;
  Digits := Trim(Text);
  if (Digits <> '') and (Digits[1] = '+') then
    Delete(Digits, 1, 1);
  if Digits = '' then
    Exit(False);
  for Character in Digits do
    if not (Character in ['0'..'9']) then
      Exit(False);
  Result := TryStrToQWord(Digits, Value);
end;

function ParseDnsTypeName(const Text: string; out RecordType: Word): Boolean;
var
  Index: Integer;
  Value: QWord;
begin
  RecordType := 0;
  for Index := Low(DnsTypeNames) to High(DnsTypeNames) do
    if SameText(Text, DnsTypeNames[Index]) then
    begin
      RecordType := DnsTypeValues[Index];
      Exit(True);
    end;
  Result := False;
  if StartsText(UnknownTypePrefix, Text) and
     IsDecimalNumber(Copy(Text, Length(UnknownTypePrefix) + 1, MaxInt), Value) and (Value > 0) and
     (Value <= 65535) then
  begin
    RecordType := Word(Value);
    Result := True;
  end;
end;

function DnsResponseCodeName(Code: Byte): string;
begin
  case Code of
    DnsResponseNoError: Result := 'NOERROR';
    DnsResponseFormatError: Result := 'FORMERR';
    DnsResponseServerFailure: Result := 'SERVFAIL';
    DnsResponseNameError: Result := 'NXDOMAIN';
    DnsResponseNotImplemented: Result := 'NOTIMP';
    DnsResponseRefused: Result := 'REFUSED';
    DnsResponseBadVersion: Result := 'BADVERS';
  else
    Result := 'RESERVED';
  end;
end;

end.
