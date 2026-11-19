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
  The resolver's pieces on the host: EDNS(0)'s OPT record in queries and
  answers (RFC 6891), and the cache of answers (times to live, negative
  answers by RFC 2308, its bound), on a clock of the test's own.
}
unit NetworkProtocolTest.Dns;

{$mode objfpc}
{$H+}

interface

procedure RunDnsChecks;

implementation

uses
  SysUtils,
  TestChecks,
  Sys.InternetAddresses,
  Sys.DnsMessages,
  Sys.DnsCache;

const
  Second = 1000;
  StartTime = 5000;

procedure CheckEdnsQuery;
var
  Buffer: array[0..511] of Byte;
  Length: LongWord;
begin
  Check(BuildDnsQuery($1234, 'example.com', DnsTypeA, True, DefaultEdnsPayloadSize, @Buffer[0], SizeOf(Buffer),
    Length), 'EDNS: a query with an OPT record is built');
  CheckBytes(@Buffer[0], Length,
    '1234 0100 0001 0000 0000 0001' +
    '07 6578616d706c65 03 636f6d 00 0001 0001' +
    '00 0029 04d0 00 00 0000 0000', 'EDNS: OPT owned by the root, class 1232, version 0, no flags, no data');
  Check(BuildDnsQuery($1234, 'example.com', DnsTypeA, True, 0, @Buffer[0], SizeOf(Buffer), Length) and
    (Length = 29) and (Buffer[11] = 0), 'EDNS: payload size 0 builds the plain query');
  Check(not BuildDnsQuery($1234, 'example.com', DnsTypeA, True, DefaultEdnsPayloadSize, @Buffer[0], 30, Length),
    'EDNS: an OPT record that does not fit is refused');
end;

procedure ParseHex(const Hex: string; out Message: TDnsMessage; out Parsed: Boolean);
var
  Bytes: TByteArray;
begin
  Bytes := HexToBytes(Hex);
  Parsed := ParseDnsMessage(@Bytes[0], System.Length(Bytes), Message);
end;

const
  AnswerWithOpt =
    '1234 8180 0001 0001 0000 0001' +
    '07 6578616d706c65 03 636f6d 00 0001 0001' +
    'c00c 0001 0001 0000012c 0004 5db8d822' +
    '00 0029 1000 00 00 8000 0000';

procedure CheckEdnsAnswer;
var
  Message: TDnsMessage;
  Parsed: Boolean;
begin
  ParseHex(AnswerWithOpt, Message, Parsed);
  Check(Parsed and Message.HasEdns and (Message.EdnsPayloadSize = 4096) and (Message.EdnsVersion = 0) and
    (Message.EdnsFlags = $8000), 'EDNS: an answer''s OPT record is read (udp 4096, DO)');
  Check(Parsed and (Message.RecordCount = 1) and (Message.Records[0].RecordType = DnsTypeA) and
    (Message.AdditionalCount = 1), 'EDNS: the OPT record is not kept among the records');
  Check(Parsed and (Message.Records[0].TimeToLive = 300) and
    AddressesAreEqual(Message.Records[0].Address, Ipv4Address(93, 184, 216, 34)), 'EDNS: the A record beside it');
  { Extended response code 1 with the header's 0: BADVERS (16). }
  ParseHex('1234 8180 0001 0000 0000 0001' + '07 6578616d706c65 03 636f6d 00 0001 0001' +
    '00 0029 04d0 01 00 0000 0000', Message, Parsed);
  Check(Parsed and (Message.ResponseCode = DnsResponseBadVersion) and
    (DnsResponseCodeName(Message.ResponseCode) = 'BADVERS'), 'EDNS: the extended response code (BADVERS)');
  ParseHex('1234 8180 0001 0000 0000 0001' + '07 6578616d706c65 03 636f6d 00 0001 0001' +
    'c00c 0029 04d0 00 00 0000 0000', Message, Parsed);
  Check(not Parsed, 'EDNS: an OPT record not owned by the root is refused');
  ParseHex('1234 8181 0001 0000 0000 0000' + '07 6578616d706c65 03 636f6d 00 0001 0001', Message, Parsed);
  Check(Parsed and not Message.HasEdns and (Message.ResponseCode = DnsResponseFormatError),
    'EDNS: FORMERR without an OPT record (an old server)');
end;

function MakeRecord(Section: TDnsSection; const Name: string; RecordType: Word; TimeToLive: LongWord): TDnsRecord;
begin
  Result := Default(TDnsRecord);
  Result.Section := Section;
  Result.Name := Name;
  Result.RecordType := RecordType;
  Result.RecordClass := DnsClassInternet;
  Result.TimeToLive := TimeToLive;
end;

procedure AddRecord(var Message: TDnsMessage; constref Entry: TDnsRecord);
begin
  SetLength(Message.Records, Message.RecordCount + 1);
  Message.Records[Message.RecordCount] := Entry;
  Inc(Message.RecordCount);
  case Entry.Section of
    DnsSectionAnswer: Inc(Message.AnswerCount);
    DnsSectionAuthority: Inc(Message.AuthorityCount);
  else
    Inc(Message.AdditionalCount);
  end;
end;

function Answer(const Name: string; TimeToLive: LongWord): TDnsMessage;
var
  Entry: TDnsRecord;
begin
  Result := Default(TDnsMessage);
  Result.Flags := DnsFlagResponse;
  Result.QuestionName := Name;
  Result.QuestionType := DnsTypeA;
  Entry := MakeRecord(DnsSectionAnswer, Name, DnsTypeA, TimeToLive);
  Entry.Address := Ipv4Address(192, 0, 2, 1);
  AddRecord(Result, Entry);
end;

function NegativeAnswer(Code: Byte; SoaTimeToLive, Minimum: LongWord; WithSoa: Boolean): TDnsMessage;
var
  Entry: TDnsRecord;
begin
  Result := Default(TDnsMessage);
  Result.Flags := DnsFlagResponse or Code;
  Result.ResponseCode := Code;
  Result.QuestionName := 'nosuch.example.com';
  Result.QuestionType := DnsTypeA;
  if not WithSoa then
    Exit;
  Entry := MakeRecord(DnsSectionAuthority, 'example.com', DnsTypeSoa, SoaTimeToLive);
  Entry.Minimum := Minimum;
  AddRecord(Result, Entry);
end;

procedure CheckPositiveCaching;
var
  Cache: TDnsCache;
  Found: TDnsMessage;
begin
  Cache := TDnsCache.Create;
  try
    Cache.Store('www.example.com', DnsTypeA, Answer('www.example.com', 300), StartTime);
    Check(Cache.Find('www.example.com', DnsTypeA, StartTime, Found) and (Found.Records[0].TimeToLive = 300),
      'cache: an answer is found at once, its time to live whole');
    Check(Cache.Find('www.example.com', DnsTypeA, StartTime + 299 * Second, Found) and
      (Found.Records[0].TimeToLive = 1), 'cache: 299 s later its time to live is 1 s');
    Check(not Cache.Find('www.example.com', DnsTypeA, StartTime + 300 * Second, Found),
      'cache: after its time to live it is gone');
    Check(Cache.Count = 0, 'cache: the answer that ran out was dropped');
    Cache.Store('WWW.Example.COM.', DnsTypeA, Answer('www.example.com', 60), StartTime);
    Check(Cache.Find('www.example.com', DnsTypeA, StartTime + Second, Found),
      'cache: names without case and a final dot');
    Check(not Cache.Find('www.example.com', DnsTypeAaaa, StartTime + Second, Found),
      'cache: kept under the type asked for');
    Cache.Store('zero.example.com', DnsTypeA, Answer('zero.example.com', 0), StartTime);
    Check(not Cache.Find('zero.example.com', DnsTypeA, StartTime, Found), 'cache: a time to live of 0 keeps nothing');
    Check(DnsCacheSeconds(Answer('long.example.com', 1000000), DnsTypeA) = MaximumPositiveCacheSeconds,
      'cache: a long time to live is kept a day at most');
  finally
    Cache.Free;
  end;
end;

procedure CheckNegativeCaching;
var
  Cache: TDnsCache;
  Found: TDnsMessage;
  NoData: TDnsMessage;
  Truncated: TDnsMessage;
begin
  Cache := TDnsCache.Create;
  try
    { RFC 2308 5: the SOA's time to live, at most its MINIMUM. }
    Cache.Store('nosuch.example.com', DnsTypeA, NegativeAnswer(DnsResponseNameError, 3600, 60, True), StartTime);
    Check(Cache.Find('nosuch.example.com', DnsTypeA, StartTime + 59 * Second, Found) and
      (Found.ResponseCode = DnsResponseNameError), 'negative cache: NXDOMAIN kept for the SOA''s MINIMUM (60 s)');
    Check(not Cache.Find('nosuch.example.com', DnsTypeA, StartTime + 60 * Second, Found),
      'negative cache: and gone after it');
    Check(DnsCacheSeconds(NegativeAnswer(DnsResponseNameError, 30, 600, True), DnsTypeA) = 30,
      'negative cache: or the SOA''s time to live when that is shorter');
    Check(DnsCacheSeconds(NegativeAnswer(DnsResponseNameError, 86400, 86400, True), DnsTypeA) =
      MaximumNegativeCacheSeconds, 'negative cache: three hours at most');
    Check(DnsCacheSeconds(NegativeAnswer(DnsResponseNameError, 3600, 60, False), DnsTypeA) = 0,
      'negative cache: NXDOMAIN without an SOA is not kept');
    NoData := NegativeAnswer(DnsResponseNoError, 300, 120, True);
    Check(DnsCacheSeconds(NoData, DnsTypeAaaa) = 120, 'negative cache: no data (NOERROR, no record) kept as well');
    Check(DnsCacheSeconds(NegativeAnswer(DnsResponseServerFailure, 300, 300, True), DnsTypeA) = 0,
      'cache: SERVFAIL is not kept');
    Truncated := Answer('big.example.com', 300);
    Truncated.Flags := Truncated.Flags or DnsFlagTruncated;
    Check(DnsCacheSeconds(Truncated, DnsTypeA) = 0, 'cache: a truncated answer is not kept');
  finally
    Cache.Free;
  end;
end;

procedure CheckCacheBound;
var
  Cache: TDnsCache;
  Found: TDnsMessage;
  Index: Integer;
begin
  Cache := TDnsCache.Create;
  try
    { The first runs out soonest (10 s); the rest later. }
    Cache.Store('host0.example.com', DnsTypeA, Answer('host0.example.com', 10), StartTime);
    for Index := 1 to MaximumCachedAnswers + 5 do
      Cache.Store('host' + IntToStr(Index) + '.example.com', DnsTypeA,
        Answer('host' + IntToStr(Index) + '.example.com', 1000 + Index), StartTime);
    Check(Cache.Count = MaximumCachedAnswers, 'cache: bounded at ' + IntToStr(MaximumCachedAnswers) + ' answers');
    Check(not Cache.Find('host0.example.com', DnsTypeA, StartTime, Found),
      'cache: the answer that runs out soonest made room');
    Check(Cache.Find('host' + IntToStr(MaximumCachedAnswers + 5) + '.example.com', DnsTypeA, StartTime, Found),
      'cache: the newest answer is kept');
    Cache.Clear;
    Check(Cache.Count = 0, 'cache: emptied');
  finally
    Cache.Free;
  end;
end;

procedure RunDnsChecks;
begin
  CheckEdnsQuery;
  CheckEdnsAnswer;
  CheckPositiveCaching;
  CheckNegativeCaching;
  CheckCacheBound;
end;

end.
