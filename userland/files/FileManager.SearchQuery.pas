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
  What is typed in the search box, read into a query:

    holiday photos          names holding every word (any case)
    "two words"             a phrase, as one word
    re*rt.txt  file?.md     wildcards: the whole name must match
    name:notes              a word of the name (the same as notes)
    kind:image              pictures (also picture, photo, music, audio,
                            video, document, doc, text, code, webpage,
                            archive, zip, program, folder, other);
                            kind:image,music for either
    ext:pas  ext:.pas       the extension (several: ext:pas,inc)
    size:>1MB  size:<10KB   sizes (B, KB, MB, GB, TB: powers of 1024),
    size:>=4KB  size:1MB..5MB
    size:empty|tiny|small|medium|large|huge|gigantic
                            0, under 16 KB, 16 KB-1 MB, 1-128 MB,
                            128 MB-1 GB, 1-4 GB, over 4 GB
    modified:today          also yesterday, thisweek, lastweek,
                            thismonth, lastmonth, thisyear, lastyear,
                            2026-05-01, >2026-01-01, <2026-01-01,
                            2026-01-01..2026-02-01 (date: is the same)
    content:word            the file's text holds the word (any case)

  A filter that cannot be read is kept as a problem (shown to the user)
  and otherwise left out. Times are Unix seconds; "today" and the like
  are worked out for the local time zone given (its offset from UTC).
  MatchesQuery checks everything but the contents (the searcher reads
  the file for those). Plain text logic, checked on the host (make
  files-test).
}
unit FileManager.SearchQuery;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  FileManager.FileKinds;

type
  TSearchQuery = record
    NameTerms: TStringArray;
    ContentTerms: TStringArray;
    { Empty: any kind. }
    Kinds: TFileKinds;
    Extensions: TStringArray;
    HasMinimumSize: Boolean;
    HasMaximumSize: Boolean;
    { Inclusive both. }
    MinimumSize: QWord;
    MaximumSize: QWord;
    HasModifiedFrom: Boolean;
    HasModifiedBefore: Boolean;
    { From inclusive, Before exclusive. }
    ModifiedFrom: Int64;
    ModifiedBefore: Int64;
    Problems: TStringArray;
  end;

function ParseSearchQuery(const Text: string; NowTime: Int64; LocalOffset: LongInt): TSearchQuery;
{ Whether the query has nothing in it (no words, no filters). }
function IsEmptyQuery(const Query: TSearchQuery): Boolean;
{ Whether an item matches everything but ContentTerms. }
function MatchesQuery(const Query: TSearchQuery; const Name: string; IsFolder: Boolean; Size: QWord;
  ModificationTime: Int64): Boolean;
{ Whether Name matches one name term: a word held in it, or with * and
  ? a pattern the whole name matches (any case). }
function NameMatchesTerm(const Name, Term: string): Boolean;
{ Reads "1MB", "10 KB", "512" (bytes); False if it is not a size. }
function ParseSize(const Text: string; out Size: QWord): Boolean;

implementation

uses
  FileManager.Paths,
  FileManager.CivilDates;

const
  KiB = QWord(1024);
  MiB = KiB * 1024;
  GiB = MiB * 1024;
  TiB = GiB * 1024;

procedure AddText(var List: TStringArray; const Text: string);
begin
  SetLength(List, Length(List) + 1);
  List[High(List)] := Text;
end;

{ Splits Text into words at spaces, a quoted phrase being one word
  (quotes kept out; "key:" before a quote stays with it). }
function SplitWords(const Text: string): TStringArray;
var
  Index: LongInt;
  Word: string;
  Quoted: Boolean;
begin
  Result := nil;
  Word := '';
  Quoted := False;
  for Index := 1 to Length(Text) do
  begin
    if Text[Index] = '"' then
      Quoted := not Quoted
    else if (Text[Index] = ' ') and not Quoted then
    begin
      if Word <> '' then
        AddText(Result, Word);
      Word := '';
    end
    else
      Word := Word + Text[Index];
  end;
  if Word <> '' then
    AddText(Result, Word);
end;

function ParseSize(const Text: string; out Size: QWord): Boolean;
var
  Number: string;
  UnitText: string;
  Index: LongInt;
  Value: Double;
  Multiplier: QWord;
begin
  Size := 0;
  Index := 1;
  while (Index <= Length(Text)) and (Text[Index] in ['0'..'9', '.']) do
    Inc(Index);
  Number := Copy(Text, 1, Index - 1);
  UnitText := UpperCase(Trim(Copy(Text, Index, Length(Text))));
  if (Number = '') or not TryStrToFloat(Number, Value, DefaultFormatSettings) then
    Exit(False);
  if (UnitText = '') or (UnitText = 'B') then
    Multiplier := 1
  else if (UnitText = 'K') or (UnitText = 'KB') or (UnitText = 'KIB') then
    Multiplier := KiB
  else if (UnitText = 'M') or (UnitText = 'MB') or (UnitText = 'MIB') then
    Multiplier := MiB
  else if (UnitText = 'G') or (UnitText = 'GB') or (UnitText = 'GIB') then
    Multiplier := GiB
  else if (UnitText = 'T') or (UnitText = 'TB') or (UnitText = 'TIB') then
    Multiplier := TiB
  else
    Exit(False);
  Size := QWord(Round(Value * Multiplier));
  Result := True;
end;

procedure SetSizeRange(var Query: TSearchQuery; Minimum, Maximum: QWord; HasMaximum: Boolean);
begin
  Query.HasMinimumSize := True;
  Query.MinimumSize := Minimum;
  Query.HasMaximumSize := HasMaximum;
  Query.MaximumSize := Maximum;
end;

function ReadSizeFilter(var Query: TSearchQuery; const Value: string): Boolean;
var
  Lowered: string;
  Size: QWord;
  Second: QWord;
  Range: LongInt;
begin
  Result := True;
  Lowered := LowerCase(Value);
  if Lowered = 'empty' then
    SetSizeRange(Query, 0, 0, True)
  else if Lowered = 'tiny' then
    SetSizeRange(Query, 1, 16 * KiB - 1, True)
  else if Lowered = 'small' then
    SetSizeRange(Query, 16 * KiB, MiB - 1, True)
  else if Lowered = 'medium' then
    SetSizeRange(Query, MiB, 128 * MiB - 1, True)
  else if Lowered = 'large' then
    SetSizeRange(Query, 128 * MiB, GiB - 1, True)
  else if Lowered = 'huge' then
    SetSizeRange(Query, GiB, 4 * GiB - 1, True)
  else if Lowered = 'gigantic' then
    SetSizeRange(Query, 4 * GiB, 0, False)
  else if (Copy(Lowered, 1, 2) = '>=') and ParseSize(Copy(Lowered, 3, Length(Lowered)), Size) then
    SetSizeRange(Query, Size, 0, False)
  else if (Copy(Lowered, 1, 2) = '<=') and ParseSize(Copy(Lowered, 3, Length(Lowered)), Size) then
  begin
    Query.HasMaximumSize := True;
    Query.MaximumSize := Size;
  end
  else if (Copy(Lowered, 1, 1) = '>') and ParseSize(Copy(Lowered, 2, Length(Lowered)), Size) then
    SetSizeRange(Query, Size + 1, 0, False)
  else if (Copy(Lowered, 1, 1) = '<') and ParseSize(Copy(Lowered, 2, Length(Lowered)), Size) then
  begin
    if Size = 0 then
      Exit(False);
    Query.HasMaximumSize := True;
    Query.MaximumSize := Size - 1;
  end
  else
  begin
    Range := Pos('..', Lowered);
    if (Range > 0) and ParseSize(Copy(Lowered, 1, Range - 1), Size) and
       ParseSize(Copy(Lowered, Range + 2, Length(Lowered)), Second) and (Size <= Second) then
      SetSizeRange(Query, Size, Second, True)
    else if (Range = 0) and ParseSize(Lowered, Size) then
      SetSizeRange(Query, Size, Size, True)
    else
      Result := False;
  end;
end;

procedure SetDateRange(var Query: TSearchQuery; FromTime, BeforeTime: Int64; HasFrom, HasBefore: Boolean);
begin
  Query.HasModifiedFrom := HasFrom;
  Query.ModifiedFrom := FromTime;
  Query.HasModifiedBefore := HasBefore;
  Query.ModifiedBefore := BeforeTime;
end;

{ The local day of an ISO date; False if Text is not one. }
function DayOfText(const Text: string; out Days: Int64): Boolean;
var
  Date: TCivilDate;
begin
  Result := ParseIsoDate(Text, Date);
  if Result then
    Days := DaysFromCivil(Date.Year, Date.Month, Date.Day)
  else
    Days := 0;
end;

function ReadDateFilter(var Query: TSearchQuery; const Value: string; NowTime: Int64; LocalOffset: LongInt): Boolean;
var
  Lowered: string;
  Today: Int64;
  Weekday: LongInt;
  Date: TCivilDate;
  FirstDay: Int64;
  SecondDay: Int64;
  Range: LongInt;
  MonthStart: Int64;
begin
  Result := True;
  Lowered := LowerCase(Value);
  Today := LocalDayOf(NowTime, LocalOffset);
  Weekday := WeekdayOfDays(Today);
  Date := CivilFromDays(Today);
  if Lowered = 'today' then
    SetDateRange(Query, StartOfLocalDay(Today, LocalOffset), StartOfLocalDay(Today + 1, LocalOffset), True, True)
  else if Lowered = 'yesterday' then
    SetDateRange(Query, StartOfLocalDay(Today - 1, LocalOffset), StartOfLocalDay(Today, LocalOffset), True, True)
  else if Lowered = 'thisweek' then
    SetDateRange(Query, StartOfLocalDay(Today - Weekday, LocalOffset), StartOfLocalDay(Today - Weekday + 7,
      LocalOffset), True, True)
  else if Lowered = 'lastweek' then
    SetDateRange(Query, StartOfLocalDay(Today - Weekday - 7, LocalOffset), StartOfLocalDay(Today - Weekday,
      LocalOffset), True, True)
  else if Lowered = 'thismonth' then
  begin
    MonthStart := DaysFromCivil(Date.Year, Date.Month, 1);
    if Date.Month = 12 then
      SecondDay := DaysFromCivil(Date.Year + 1, 1, 1)
    else
      SecondDay := DaysFromCivil(Date.Year, Date.Month + 1, 1);
    SetDateRange(Query, StartOfLocalDay(MonthStart, LocalOffset), StartOfLocalDay(SecondDay, LocalOffset), True, True);
  end
  else if Lowered = 'lastmonth' then
  begin
    MonthStart := DaysFromCivil(Date.Year, Date.Month, 1);
    if Date.Month = 1 then
      FirstDay := DaysFromCivil(Date.Year - 1, 12, 1)
    else
      FirstDay := DaysFromCivil(Date.Year, Date.Month - 1, 1);
    SetDateRange(Query, StartOfLocalDay(FirstDay, LocalOffset), StartOfLocalDay(MonthStart, LocalOffset), True, True);
  end
  else if Lowered = 'thisyear' then
    SetDateRange(Query, StartOfLocalDay(DaysFromCivil(Date.Year, 1, 1), LocalOffset),
      StartOfLocalDay(DaysFromCivil(Date.Year + 1, 1, 1), LocalOffset), True, True)
  else if Lowered = 'lastyear' then
    SetDateRange(Query, StartOfLocalDay(DaysFromCivil(Date.Year - 1, 1, 1), LocalOffset),
      StartOfLocalDay(DaysFromCivil(Date.Year, 1, 1), LocalOffset), True, True)
  else if (Copy(Lowered, 1, 1) = '>') and DayOfText(Copy(Lowered, 2, Length(Lowered)), FirstDay) then
    SetDateRange(Query, StartOfLocalDay(FirstDay + 1, LocalOffset), 0, True, False)
  else if (Copy(Lowered, 1, 1) = '<') and DayOfText(Copy(Lowered, 2, Length(Lowered)), FirstDay) then
    SetDateRange(Query, 0, StartOfLocalDay(FirstDay, LocalOffset), False, True)
  else
  begin
    Range := Pos('..', Lowered);
    if (Range > 0) and DayOfText(Copy(Lowered, 1, Range - 1), FirstDay) and
       DayOfText(Copy(Lowered, Range + 2, Length(Lowered)), SecondDay) and (FirstDay <= SecondDay) then
      { Both days included. }
      SetDateRange(Query, StartOfLocalDay(FirstDay, LocalOffset), StartOfLocalDay(SecondDay + 1, LocalOffset), True,
        True)
    else if (Range = 0) and DayOfText(Lowered, FirstDay) then
      SetDateRange(Query, StartOfLocalDay(FirstDay, LocalOffset), StartOfLocalDay(FirstDay + 1, LocalOffset), True,
        True)
    else
      Result := False;
  end;
end;

function ReadKindFilter(var Query: TSearchQuery; const Value: string): Boolean;
var
  Words: TStringArray;
  Word: string;
  Kind: TFileKind;
begin
  Result := Value <> '';
  Words := Value.Split([',', ';']);
  for Word in Words do
    if FileKindNamed(Trim(Word), Kind) then
      Include(Query.Kinds, Kind)
    else
      Result := False;
end;

procedure ReadExtensionFilter(var Query: TSearchQuery; const Value: string);
var
  Words: TStringArray;
  Word: string;
  Extension: string;
begin
  Words := Value.Split([',', ';']);
  for Word in Words do
  begin
    Extension := LowerCase(Trim(Word));
    if Copy(Extension, 1, 2) = '*.' then
      Delete(Extension, 1, 2);
    if Copy(Extension, 1, 1) = '.' then
      Delete(Extension, 1, 1);
    if Extension <> '' then
      AddText(Query.Extensions, Extension);
  end;
end;

function ParseSearchQuery(const Text: string; NowTime: Int64; LocalOffset: LongInt): TSearchQuery;
var
  Words: TStringArray;
  Word: string;
  Colon: LongInt;
  Key: string;
  Value: string;
  Understood: Boolean;
begin
  Result := Default(TSearchQuery);
  Words := SplitWords(Text);
  for Word in Words do
  begin
    Colon := Pos(':', Word);
    if Colon <= 1 then
    begin
      AddText(Result.NameTerms, Word);
      Continue;
    end;
    Key := LowerCase(Copy(Word, 1, Colon - 1));
    Value := Copy(Word, Colon + 1, Length(Word));
    Understood := True;
    if (Key = 'kind') or (Key = 'type') then
      Understood := ReadKindFilter(Result, Value)
    else if (Key = 'ext') or (Key = 'extension') then
      ReadExtensionFilter(Result, Value)
    else if Key = 'size' then
      Understood := ReadSizeFilter(Result, Value)
    else if (Key = 'modified') or (Key = 'date') or (Key = 'datemodified') then
      Understood := ReadDateFilter(Result, Value, NowTime, LocalOffset)
    else if (Key = 'content') or (Key = 'contents') then
    begin
      if Value <> '' then
        AddText(Result.ContentTerms, Value);
    end
    else if Key = 'name' then
    begin
      if Value <> '' then
        AddText(Result.NameTerms, Value);
    end
    else
      { Not a filter: a word with a colon in it. }
      AddText(Result.NameTerms, Word);
    if not Understood then
      AddText(Result.Problems, 'Not understood: ' + Word);
  end;
end;

function IsEmptyQuery(const Query: TSearchQuery): Boolean;
begin
  Result := (Length(Query.NameTerms) = 0) and (Length(Query.ContentTerms) = 0) and (Query.Kinds = []) and
    (Length(Query.Extensions) = 0) and not Query.HasMinimumSize and not Query.HasMaximumSize and
    not Query.HasModifiedFrom and not Query.HasModifiedBefore;
end;

{ Whether Name (from NameIndex) matches Pattern (from PatternIndex): *
  any run, ? any one byte; both already in small letters. }
function WildcardMatches(const Name, Pattern: string; NameIndex, PatternIndex: LongInt): Boolean;
begin
  while PatternIndex <= Length(Pattern) do
  begin
    if Pattern[PatternIndex] = '*' then
    begin
      while (PatternIndex <= Length(Pattern)) and (Pattern[PatternIndex] = '*') do
        Inc(PatternIndex);
      if PatternIndex > Length(Pattern) then
        Exit(True);
      while NameIndex <= Length(Name) do
      begin
        if WildcardMatches(Name, Pattern, NameIndex, PatternIndex) then
          Exit(True);
        Inc(NameIndex);
      end;
      Exit(False);
    end;
    if NameIndex > Length(Name) then
      Exit(False);
    if (Pattern[PatternIndex] <> '?') and (Pattern[PatternIndex] <> Name[NameIndex]) then
      Exit(False);
    Inc(PatternIndex);
    Inc(NameIndex);
  end;
  Result := NameIndex > Length(Name);
end;

function NameMatchesTerm(const Name, Term: string): Boolean;
var
  LoweredName: string;
  LoweredTerm: string;
begin
  LoweredName := LowerCase(Name);
  LoweredTerm := LowerCase(Term);
  if (Pos('*', LoweredTerm) > 0) or (Pos('?', LoweredTerm) > 0) then
    Result := WildcardMatches(LoweredName, LoweredTerm, 1, 1)
  else
    Result := Pos(LoweredTerm, LoweredName) > 0;
end;

function MatchesQuery(const Query: TSearchQuery; const Name: string; IsFolder: Boolean; Size: QWord;
  ModificationTime: Int64): Boolean;
var
  Term: string;
  Kind: TFileKind;
  Extension: string;
  Found: Boolean;
begin
  for Term in Query.NameTerms do
    if not NameMatchesTerm(Name, Term) then
      Exit(False);
  if Query.Kinds <> [] then
  begin
    if IsFolder then
      Kind := FileKindFolder
    else
      Kind := FileKindOfName(Name);
    if not (Kind in Query.Kinds) then
      Exit(False);
  end;
  if Length(Query.Extensions) > 0 then
  begin
    if IsFolder then
      Exit(False);
    Found := False;
    for Extension in Query.Extensions do
      if ExtensionOf(Name) = Extension then
        Found := True;
    if not Found then
      Exit(False);
  end;
  if (Query.HasMinimumSize or Query.HasMaximumSize) and IsFolder then
    Exit(False);
  if Query.HasMinimumSize and (Size < Query.MinimumSize) then
    Exit(False);
  if Query.HasMaximumSize and (Size > Query.MaximumSize) then
    Exit(False);
  if Query.HasModifiedFrom and (ModificationTime < Query.ModifiedFrom) then
    Exit(False);
  if Query.HasModifiedBefore and (ModificationTime >= Query.ModifiedBefore) then
    Exit(False);
  Result := True;
end;

end.
