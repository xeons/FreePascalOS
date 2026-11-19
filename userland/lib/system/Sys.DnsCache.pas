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
  A small cache of DNS answers (a process's own; Sys.DnsQueries keeps
  one for the lookups of Sys.HostNames).

  An answer is kept under its question (the name without case or a
  final dot, and the type) for as long as its records may be:
    - an answer with records for the question (aliases included) for
      the shortest time to live of the answer section's records;
    - a negative answer (RFC 2308) - NXDOMAIN, or NOERROR with no record
      of the type ("no data") - for the SOA record of the authority
      section: the smaller of its time to live and its MINIMUM field. A
      negative answer without an SOA is not kept (section 5);
    - nothing else (server failures, refusals, truncated answers).
  Times are capped (a day for answers, three hours for negative ones,
  section 5) and a time of 0 keeps nothing. An answer taken out of the
  cache has its records' times to live lowered by the seconds it was
  kept, as a server's cache would.

  The cache holds MaximumCachedAnswers answers; a new one pushes out the
  answers that ran out, else the one that runs out soonest. The clock
  is the caller's (milliseconds that only go forward), so the cache can
  be tested without waiting. It is not thread-safe: its owner locks.
}
unit Sys.DnsCache;

{$mode objfpc}
{$H+}

interface

uses
  Sys.DnsMessages;

const
  MaximumCachedAnswers = 64;
  MaximumPositiveCacheSeconds = 86400;
  MaximumNegativeCacheSeconds = 3 * 3600;

type
  TDnsCacheEntry = record
    Key: string;
    Message: TDnsMessage;
    StoredAt: QWord;
    ExpiresAt: QWord;
  end;

  TDnsCache = class
  private
    FEntries: array of TDnsCacheEntry;
    FCount: Integer;
    function IndexOf(const Key: string): Integer;
    procedure RemoveAt(Index: Integer);
    procedure RemoveExpired(Now: QWord);
  public
    constructor Create;
    { Keeps Message (the answer to Name's records of RecordType) if it
      may be kept, at Now (milliseconds). }
    procedure Store(const Name: string; RecordType: Word; constref Message: TDnsMessage; Now: QWord);
    { True with the kept answer (times to live lowered) if there is one
      that has not run out at Now. }
    function Find(const Name: string; RecordType: Word; Now: QWord; out Message: TDnsMessage): Boolean;
    procedure Clear;
    property Count: Integer read FCount;
  end;

{ The seconds an answer to RecordType may be kept (0: not at all). }
function DnsCacheSeconds(constref Message: TDnsMessage; RecordType: Word): LongWord;
{ The key an answer is kept under: "www.example.com/1". }
function DnsCacheKey(const Name: string; RecordType: Word): string;

implementation

uses
  SysUtils;

const
  MillisecondsPerSecond = 1000;

function DnsCacheKey(const Name: string; RecordType: Word): string;
var
  Text: string;
begin
  Text := LowerCase(Name);
  if (Length(Text) > 1) and (Text[Length(Text)] = '.') then
    SetLength(Text, Length(Text) - 1);
  Result := Text + '/' + IntToStr(RecordType);
end;

function Smaller(First, Second: LongWord): LongWord;
begin
  if First < Second then
    Result := First
  else
    Result := Second;
end;

{ The shortest time to live of the answer section, and whether it has
  a record of RecordType (or an alias). }
function AnswerSeconds(constref Message: TDnsMessage; RecordType: Word; out HasAnswer: Boolean): LongWord;
var
  Index: Integer;
  Entry: TDnsRecord;
begin
  Result := High(LongWord);
  HasAnswer := False;
  for Index := 0 to Message.RecordCount - 1 do
  begin
    Entry := Message.Records[Index];
    if Entry.Section <> DnsSectionAnswer then
      Continue;
    Result := Smaller(Result, Entry.TimeToLive);
    if (Entry.RecordType = RecordType) or (Entry.RecordType = DnsTypeCname) then
      HasAnswer := True;
  end;
end;

{ RFC 2308 section 5: the SOA's time to live, at most its MINIMUM. }
function NegativeSeconds(constref Message: TDnsMessage): LongWord;
var
  Index: Integer;
  Entry: TDnsRecord;
begin
  Result := 0;
  for Index := 0 to Message.RecordCount - 1 do
  begin
    Entry := Message.Records[Index];
    if (Entry.Section = DnsSectionAuthority) and (Entry.RecordType = DnsTypeSoa) then
      Exit(Smaller(Smaller(Entry.TimeToLive, Entry.Minimum), MaximumNegativeCacheSeconds));
  end;
end;

function DnsCacheSeconds(constref Message: TDnsMessage; RecordType: Word): LongWord;
var
  HasAnswer: Boolean;
  Seconds: LongWord;
begin
  Result := 0;
  if (Message.Flags and DnsFlagTruncated) <> 0 then
    Exit;
  if Message.SkippedRecords > 0 then
    Exit;
  case Message.ResponseCode of
    DnsResponseNameError:
      Result := NegativeSeconds(Message);
    DnsResponseNoError:
      begin
        Seconds := AnswerSeconds(Message, RecordType, HasAnswer);
        if HasAnswer then
          Result := Smaller(Seconds, MaximumPositiveCacheSeconds)
        else
          Result := NegativeSeconds(Message);
      end;
  end;
end;

constructor TDnsCache.Create;
begin
  inherited Create;
  SetLength(FEntries, MaximumCachedAnswers);
  FCount := 0;
end;

function TDnsCache.IndexOf(const Key: string): Integer;
var
  Index: Integer;
begin
  for Index := 0 to FCount - 1 do
    if FEntries[Index].Key = Key then
      Exit(Index);
  Result := -1;
end;

procedure TDnsCache.RemoveAt(Index: Integer);
begin
  FEntries[Index] := FEntries[FCount - 1];
  FEntries[FCount - 1] := Default(TDnsCacheEntry);
  Dec(FCount);
end;

procedure TDnsCache.RemoveExpired(Now: QWord);
var
  Index: Integer;
begin
  Index := 0;
  while Index < FCount do
    if FEntries[Index].ExpiresAt <= Now then
      RemoveAt(Index)
    else
      Inc(Index);
end;

procedure TDnsCache.Store(const Name: string; RecordType: Word; constref Message: TDnsMessage; Now: QWord);
var
  Seconds: LongWord;
  Key: string;
  Index: Integer;
  Soonest: Integer;
begin
  Seconds := DnsCacheSeconds(Message, RecordType);
  if Seconds = 0 then
    Exit;
  Key := DnsCacheKey(Name, RecordType);
  Index := IndexOf(Key);
  if Index < 0 then
  begin
    if FCount >= MaximumCachedAnswers then
      RemoveExpired(Now);
    if FCount >= MaximumCachedAnswers then
    begin
      Soonest := 0;
      for Index := 1 to FCount - 1 do
        if FEntries[Index].ExpiresAt < FEntries[Soonest].ExpiresAt then
          Soonest := Index;
      RemoveAt(Soonest);
    end;
    Index := FCount;
    Inc(FCount);
  end;
  FEntries[Index].Key := Key;
  FEntries[Index].Message := Message;
  FEntries[Index].StoredAt := Now;
  FEntries[Index].ExpiresAt := Now + QWord(Seconds) * MillisecondsPerSecond;
end;

function TDnsCache.Find(const Name: string; RecordType: Word; Now: QWord; out Message: TDnsMessage): Boolean;
var
  Index: Integer;
  RecordIndex: Integer;
  Elapsed: QWord;
begin
  Message := Default(TDnsMessage);
  Index := IndexOf(DnsCacheKey(Name, RecordType));
  if Index < 0 then
    Exit(False);
  if FEntries[Index].ExpiresAt <= Now then
  begin
    RemoveAt(Index);
    Exit(False);
  end;
  Message := FEntries[Index].Message;
  Message.Records := Copy(FEntries[Index].Message.Records);
  Elapsed := (Now - FEntries[Index].StoredAt) div MillisecondsPerSecond;
  for RecordIndex := 0 to Message.RecordCount - 1 do
    if Message.Records[RecordIndex].TimeToLive > Elapsed then
      Message.Records[RecordIndex].TimeToLive := LongWord(Message.Records[RecordIndex].TimeToLive - Elapsed)
    else
      Message.Records[RecordIndex].TimeToLive := 0;
  Result := True;
end;

procedure TDnsCache.Clear;
var
  Index: Integer;
begin
  for Index := 0 to FCount - 1 do
    FEntries[Index] := Default(TDnsCacheEntry);
  FCount := 0;
end;

end.
