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
  dnstest's DNS server's records: a fixed zone, test.example, answered
  the same way every time, so the resolver can be checked without the
  internet (QEMU's DNS forwards to the host, which may have none).

    www.test.example      A 192.0.2.10, AAAA 2001:db8::10,
                          MX 10 mail.test.example, TXT "hello world"
    alias.test.example    CNAME www (the A records of www come with it)
    far.test.example      CNAME www (alone: the resolver must ask again)
    multi.test.example    A 192.0.2.21 and 192.0.2.22
    mail.test.example     A 192.0.2.25
    test.example          NS ns.test.example, SOA
    big.test.example      TXT of 2000 bytes: truncated over UDP
    loop.test.example     an answer whose name points at itself
    spoof.test.example    A 192.0.2.99, after a reply with a wrong id
    10.2.0.192.in-addr.arpa   PTR www.test.example
  Other names under test.example do not exist (NXDOMAIN, with the SOA);
  names elsewhere are refused.

  BuildAnswer turns a query into the reply (or two, for spoof).
}
unit DnsTest.Zone;

{$mode objfpc}
{$pointermath on}

interface

const
  ZoneName: PChar = 'test.example';
  WwwAddress: array[0..3] of Byte = (192, 0, 2, 10);
  SpoofedAddress: array[0..3] of Byte = (6, 6, 6, 6);
  BigTextStrings = 10;
  BigTextStringBytes = 200;

type
  TAnswer = record
    Data: array[0..8191] of Byte;
    Length: LongWord;
    { spoof: a reply with a wrong id goes first. }
    HasDecoy: Boolean;
    Decoy: array[0..511] of Byte;
    DecoyLength: LongWord;
  end;

{ The reply to Query (Length bytes); Truncate: the way over UDP (512
  bytes at most; more sets TC and leaves the records out). False if the
  query cannot be read (nothing is sent). }
function BuildAnswer(Query: PByte; Length: LongWord; Truncate: Boolean; out Answer: TAnswer): Boolean;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Sys.DnsNames,
  Sys.DnsMessages;

const
  TimeToLive = 300;
  QuestionNamePointer = $C00C;

type
  TBuilder = record
    Data: PByte;
    Capacity: LongWord;
    Length: LongWord;
    AnswerCount: Word;
    AuthorityCount: Word;
    QuestionName: TDnsName;
  end;

procedure PutByte(var Builder: TBuilder; Value: Byte);
begin
  if Builder.Length < Builder.Capacity then
    Builder.Data[Builder.Length] := Value;
  Inc(Builder.Length);
end;

procedure PutWord(var Builder: TBuilder; Value: Word);
begin
  PutByte(Builder, Byte(Value shr 8));
  PutByte(Builder, Byte(Value));
end;

procedure PutLongWord(var Builder: TBuilder; Value: LongWord);
begin
  PutWord(Builder, Word(Value shr 16));
  PutWord(Builder, Word(Value));
end;

{ A name: a pointer to the question's if it is that one. }
procedure PutName(var Builder: TBuilder; Name: PChar);
var
  Position: LongWord;
begin
  if DnsNamesAreEqual(Name, @Builder.QuestionName[0]) then
  begin
    PutWord(Builder, QuestionNamePointer);
    Exit;
  end;
  Position := Builder.Length;
  if EncodeDnsName(Name, Builder.Data, Builder.Capacity, Position) then
    Builder.Length := Position;
end;

{ The owner, type, class and time to live; returns where the data's
  length goes. }
function BeginRecord(var Builder: TBuilder; Owner: PChar; RecordType: Word): LongWord;
begin
  PutName(Builder, Owner);
  PutWord(Builder, RecordType);
  PutWord(Builder, DnsClassInternet);
  PutLongWord(Builder, TimeToLive);
  Result := Builder.Length;
  PutWord(Builder, 0);
end;

procedure EndRecord(var Builder: TBuilder; LengthPosition: LongWord);
var
  DataLength: LongWord;
begin
  DataLength := Builder.Length - LengthPosition - 2;
  Builder.Data[LengthPosition] := Byte(DataLength shr 8);
  Builder.Data[LengthPosition + 1] := Byte(DataLength);
end;

procedure PutAddressRecord(var Builder: TBuilder; Owner: PChar; A, B, C, D: Byte);
var
  Mark: LongWord;
begin
  Mark := BeginRecord(Builder, Owner, DnsTypeA);
  PutByte(Builder, A);
  PutByte(Builder, B);
  PutByte(Builder, C);
  PutByte(Builder, D);
  EndRecord(Builder, Mark);
  Inc(Builder.AnswerCount);
end;

procedure PutNameRecord(var Builder: TBuilder; Owner: PChar; RecordType: Word; Target: PChar);
var
  Mark: LongWord;
begin
  Mark := BeginRecord(Builder, Owner, RecordType);
  PutName(Builder, Target);
  EndRecord(Builder, Mark);
  Inc(Builder.AnswerCount);
end;

procedure PutWwwRecords(var Builder: TBuilder; Owner: PChar; RecordType: Word);
const
  Ipv6: array[0..15] of Byte = ($20, $01, $0D, $B8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, $10);
var
  Mark: LongWord;
  Index: Integer;
  Text: PChar;
begin
  case RecordType of
    DnsTypeA: PutAddressRecord(Builder, Owner, WwwAddress[0], WwwAddress[1], WwwAddress[2], WwwAddress[3]);
    DnsTypeAaaa:
      begin
        Mark := BeginRecord(Builder, Owner, DnsTypeAaaa);
        for Index := 0 to 15 do
          PutByte(Builder, Ipv6[Index]);
        EndRecord(Builder, Mark);
        Inc(Builder.AnswerCount);
      end;
    DnsTypeMx:
      begin
        Mark := BeginRecord(Builder, Owner, DnsTypeMx);
        PutWord(Builder, 10);
        PutName(Builder, 'mail.test.example');
        EndRecord(Builder, Mark);
        Inc(Builder.AnswerCount);
      end;
    DnsTypeTxt:
      begin
        Text := 'hello world';
        Mark := BeginRecord(Builder, Owner, DnsTypeTxt);
        PutByte(Builder, Byte(TextLength(Text)));
        for Index := 0 to Integer(TextLength(Text)) - 1 do
          PutByte(Builder, Byte(Text[Index]));
        EndRecord(Builder, Mark);
        Inc(Builder.AnswerCount);
      end;
  end;
end;

procedure PutSoaRecord(var Builder: TBuilder; IsAuthority: Boolean);
var
  Mark: LongWord;
begin
  Mark := BeginRecord(Builder, ZoneName, DnsTypeSoa);
  PutName(Builder, 'ns.test.example');
  PutName(Builder, 'hostmaster.test.example');
  PutLongWord(Builder, 2026111601);
  PutLongWord(Builder, 3600);
  PutLongWord(Builder, 600);
  PutLongWord(Builder, 86400);
  PutLongWord(Builder, 300);
  EndRecord(Builder, Mark);
  if IsAuthority then
    Inc(Builder.AuthorityCount)
  else
    Inc(Builder.AnswerCount);
end;

procedure PutBigText(var Builder: TBuilder; Owner: PChar);
var
  Mark: LongWord;
  StringIndex: Integer;
  Index: Integer;
begin
  Mark := BeginRecord(Builder, Owner, DnsTypeTxt);
  for StringIndex := 0 to BigTextStrings - 1 do
  begin
    PutByte(Builder, BigTextStringBytes);
    for Index := 0 to BigTextStringBytes - 1 do
      PutByte(Builder, Byte(Ord('a') + StringIndex));
  end;
  EndRecord(Builder, Mark);
  Inc(Builder.AnswerCount);
end;

{ An A record whose owner is a pointer to itself. }
procedure PutLoopingRecord(var Builder: TBuilder);
var
  Start: LongWord;
begin
  Start := Builder.Length;
  PutWord(Builder, $C000 or Start);
  PutWord(Builder, DnsTypeA);
  PutWord(Builder, DnsClassInternet);
  PutLongWord(Builder, TimeToLive);
  PutWord(Builder, 4);
  PutLongWord(Builder, $01020304);
  Inc(Builder.AnswerCount);
end;

function IsName(Name, Wanted: PChar): Boolean;
begin
  Result := DnsNamesAreEqual(Name, Wanted);
end;

function IsInZone(Name: PChar): Boolean;
var
  NameLength: PtrUInt;
  ZoneLength: PtrUInt;
begin
  NameLength := TextLength(Name);
  ZoneLength := TextLength(ZoneName);
  Result := IsName(Name, ZoneName) or ((NameLength > ZoneLength + 1) and
    DnsNamesAreEqual(Name + NameLength - ZoneLength, ZoneName) and (Name[NameLength - ZoneLength - 1] = '.'));
end;

{ The records; the response code. }
function AddRecords(var Builder: TBuilder; Name: PChar; RecordType: Word): Byte;
begin
  Result := 0;
  if IsName(Name, 'www.test.example') then
    PutWwwRecords(Builder, Name, RecordType)
  else if IsName(Name, 'alias.test.example') or IsName(Name, 'far.test.example') then
  begin
    PutNameRecord(Builder, Name, DnsTypeCname, 'www.test.example');
    if IsName(Name, 'alias.test.example') then
      PutWwwRecords(Builder, 'www.test.example', RecordType);
  end
  else if IsName(Name, 'multi.test.example') then
  begin
    if RecordType = DnsTypeA then
    begin
      PutAddressRecord(Builder, Name, 192, 0, 2, 21);
      PutAddressRecord(Builder, Name, 192, 0, 2, 22);
    end;
  end
  else if IsName(Name, 'mail.test.example') then
  begin
    if RecordType = DnsTypeA then
      PutAddressRecord(Builder, Name, 192, 0, 2, 25);
  end
  else if IsName(Name, ZoneName) then
  begin
    if RecordType = DnsTypeNs then
      PutNameRecord(Builder, Name, DnsTypeNs, 'ns.test.example')
    else if RecordType = DnsTypeSoa then
      PutSoaRecord(Builder, False);
  end
  else if IsName(Name, 'big.test.example') then
  begin
    if RecordType = DnsTypeTxt then
      PutBigText(Builder, Name);
  end
  else if IsName(Name, 'loop.test.example') then
    PutLoopingRecord(Builder)
  else if IsName(Name, 'spoof.test.example') then
  begin
    if RecordType = DnsTypeA then
      PutAddressRecord(Builder, Name, 192, 0, 2, 99);
  end
  else if IsName(Name, '10.2.0.192.in-addr.arpa') then
  begin
    if RecordType = DnsTypePtr then
      PutNameRecord(Builder, Name, DnsTypePtr, 'www.test.example');
  end
  else if IsInZone(Name) then
    Result := DnsResponseNameError
  else
    Result := DnsResponseRefused;
  if (Result = DnsResponseNameError) or ((Result = 0) and (Builder.AnswerCount = 0) and IsInZone(Name)) then
    PutSoaRecord(Builder, True);
end;

procedure WriteHeader(var Builder: TBuilder; Id, Flags: Word; QuestionLength: LongWord; Query: PByte);
begin
  Builder.Length := 0;
  PutWord(Builder, Id);
  PutWord(Builder, Flags);
  PutWord(Builder, 1);
  PutWord(Builder, 0);
  PutWord(Builder, 0);
  PutWord(Builder, 0);
  CopyMemory(Builder.Data + DnsHeaderBytes, Query + DnsHeaderBytes, QuestionLength);
  Builder.Length := DnsHeaderBytes + QuestionLength;
end;

procedure SetCounts(var Builder: TBuilder);
begin
  Builder.Data[6] := Byte(Builder.AnswerCount shr 8);
  Builder.Data[7] := Byte(Builder.AnswerCount);
  Builder.Data[8] := Byte(Builder.AuthorityCount shr 8);
  Builder.Data[9] := Byte(Builder.AuthorityCount);
end;

function BuildAnswer(Query: PByte; Length: LongWord; Truncate: Boolean; out Answer: TAnswer): Boolean;
var
  Builder: TBuilder;
  Id: Word;
  QueryFlags: Word;
  QuestionType: Word;
  QuestionClass: Word;
  QuestionEnd: LongWord;
  Flags: Word;
  Code: Byte;
begin
  Answer.Length := 0;
  Answer.HasDecoy := False;
  Answer.DecoyLength := 0;
  Builder.Data := @Answer.Data[0];
  Builder.Capacity := SizeOf(Answer.Data);
  Builder.AnswerCount := 0;
  Builder.AuthorityCount := 0;
  if not ParseDnsHeader(Query, Length, Id, QueryFlags, Builder.QuestionName, QuestionType, QuestionClass) or
     ((QueryFlags and DnsFlagResponse) <> 0) or (Builder.QuestionName[0] = #0) then
    Exit(False);
  QuestionEnd := DnsHeaderBytes;
  if not SkipDnsName(Query, Length, QuestionEnd) then
    Exit(False);
  QuestionEnd := QuestionEnd + 4;
  Flags := DnsFlagResponse or DnsFlagAuthoritative or DnsFlagRecursionAvailable or
    (QueryFlags and DnsFlagRecursionDesired);
  WriteHeader(Builder, Id, Flags, QuestionEnd - DnsHeaderBytes, Query);
  Code := AddRecords(Builder, @Builder.QuestionName[0], QuestionType);
  if Truncate and (Builder.Length > MaximumUdpDnsMessage) then
  begin
    Builder.AnswerCount := 0;
    Builder.AuthorityCount := 0;
    WriteHeader(Builder, Id, Flags or DnsFlagTruncated, QuestionEnd - DnsHeaderBytes, Query);
  end;
  Builder.Data[3] := Builder.Data[3] or Code;
  SetCounts(Builder);
  Answer.Length := Builder.Length;
  if IsName(@Builder.QuestionName[0], 'spoof.test.example') and (QuestionType = DnsTypeA) and
     (Builder.Length <= SizeOf(Answer.Decoy)) then
  begin
    { The same reply with another id and another address. }
    CopyMemory(@Answer.Decoy[0], @Answer.Data[0], Builder.Length);
    Answer.Decoy[0] := Answer.Decoy[0] xor $5A;
    CopyMemory(@Answer.Decoy[Builder.Length - 4], @SpoofedAddress[0], 4);
    Answer.DecoyLength := Builder.Length;
    Answer.HasDecoy := True;
  end;
  Result := True;
end;

end.
