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
  The dates of cookies' Expires attribute, read as RFC 6265 section
  5.1.1 says: the text is cut into tokens at delimiters, and the first
  token that reads as a time (hh:mm:ss), a day of the month (1 or 2
  digits), a month (its first three letters) or a year (2 to 4 digits)
  gives that part. Two-digit years 70-99 are 19xx, 00-69 20xx. So
  "Sun, 06 Nov 1994 08:49:37 GMT", "Sunday, 06-Nov-94 08:49:37 GMT" and
  "Sun Nov  6 08:49:37 1994" all read alike.

  Plain Pascal (the RTL only), checked on the host by tools/WgetTest.
}
unit Wget.CookieDates;

{$mode objfpc}
{$H+}

interface

{ Seconds since 1970-01-01 00:00:00 UTC; False if Text is not a date. }
function ParseCookieDate(const Text: string; out UnixTime: Int64): Boolean;
{ Days since 1970-01-01 of a date in the proleptic Gregorian calendar. }
function DaysFromCivil(Year, Month, Day: Integer): Int64;

implementation

uses
  SysUtils;

const
  MonthPrefixes: array[1..12] of string = ('jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep',
    'oct', 'nov', 'dec');

function DaysFromCivil(Year, Month, Day: Integer): Int64;
var
  Era, YearOfEra, DayOfYear, DayOfEra: Int64;
  ShiftedYear: Int64;
  ShiftedMonth: Int64;
begin
  ShiftedYear := Year;
  if Month <= 2 then
    Dec(ShiftedYear);
  if ShiftedYear >= 0 then
    Era := ShiftedYear div 400
  else
    Era := (ShiftedYear - 399) div 400;
  YearOfEra := ShiftedYear - Era * 400;
  if Month > 2 then
    ShiftedMonth := Month - 3
  else
    ShiftedMonth := Month + 9;
  DayOfYear := (153 * ShiftedMonth + 2) div 5 + Day - 1;
  DayOfEra := YearOfEra * 365 + YearOfEra div 4 - YearOfEra div 100 + DayOfYear;
  Result := Era * 146097 + DayOfEra - 719468;
end;

{ RFC 6265's delimiters: everything but digits, letters and ":". }
function IsDelimiter(Character: Char): Boolean;
begin
  case Character of
    #9, #32..#47, #59..#64, #91..#96, #123..#126: Result := True;
  else
    Result := False;
  end;
end;

function IsDigit(Character: Char): Boolean;
begin
  Result := Character in ['0'..'9'];
end;

function SplitTokens(const Text: string): TStringArray;
var
  Position, Start: Integer;
begin
  Result := nil;
  Position := 1;
  while Position <= Length(Text) do
  begin
    while (Position <= Length(Text)) and IsDelimiter(Text[Position]) do
      Inc(Position);
    if Position > Length(Text) then
      Break;
    Start := Position;
    while (Position <= Length(Text)) and not IsDelimiter(Text[Position]) do
      Inc(Position);
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Copy(Text, Start, Position - Start);
  end;
end;

{ 1 to MaximumDigits digits at the start of Token (anything may follow
  them only if AllowTrailing). }
function LeadingNumber(const Token: string; MaximumDigits: Integer; AllowTrailing: Boolean;
  out Value: Integer; out Digits: Integer): Boolean;
begin
  Value := 0;
  Digits := 0;
  while (Digits < Length(Token)) and IsDigit(Token[Digits + 1]) do
  begin
    if Digits >= MaximumDigits then
      Exit(False);
    Value := Value * 10 + Ord(Token[Digits + 1]) - Ord('0');
    Inc(Digits);
  end;
  Result := (Digits > 0) and (AllowTrailing or (Digits = Length(Token)));
end;

{ "hh:mm:ss", each part one or two digits. }
function ParseTimeToken(const Token: string; out Hour, Minute, Second: Integer): Boolean;
var
  Parts: TStringArray;
  Digits: Integer;
begin
  Hour := 0;
  Minute := 0;
  Second := 0;
  Parts := Token.Split([':']);
  Result := (Length(Parts) = 3) and LeadingNumber(Parts[0], 2, False, Hour, Digits) and
    LeadingNumber(Parts[1], 2, False, Minute, Digits) and LeadingNumber(Parts[2], 2, True, Second, Digits);
end;

function ParseMonthToken(const Token: string; out Month: Integer): Boolean;
var
  Index: Integer;
begin
  Month := 0;
  if Length(Token) < 3 then
    Exit(False);
  for Index := 1 to 12 do
    if SameText(Copy(Token, 1, 3), MonthPrefixes[Index]) then
    begin
      Month := Index;
      Exit(True);
    end;
  Result := False;
end;

function ParseCookieDate(const Text: string; out UnixTime: Int64): Boolean;
var
  Token: string;
  FoundTime, FoundDay, FoundMonth, FoundYear: Boolean;
  Hour, Minute, Second, Day, Month, Year: Integer;
  Value, Digits: Integer;
  Candidate: Integer;
begin
  UnixTime := 0;
  FoundTime := False;
  FoundDay := False;
  FoundMonth := False;
  FoundYear := False;
  Hour := 0;
  Minute := 0;
  Second := 0;
  Day := 0;
  Month := 0;
  Year := 0;
  for Token in SplitTokens(Text) do
  begin
    if not FoundTime and ParseTimeToken(Token, Hour, Minute, Second) then
      FoundTime := True
    else if not FoundDay and LeadingNumber(Token, 2, True, Value, Digits) then
    begin
      FoundDay := True;
      Day := Value;
    end
    else if not FoundMonth and ParseMonthToken(Token, Candidate) then
    begin
      FoundMonth := True;
      Month := Candidate;
    end
    else if not FoundYear and LeadingNumber(Token, 4, True, Value, Digits) and (Digits >= 2) then
    begin
      FoundYear := True;
      Year := Value;
    end;
  end;
  if (Year >= 70) and (Year <= 99) then
    Inc(Year, 1900)
  else if (Year >= 0) and (Year <= 69) and FoundYear then
    Inc(Year, 2000);
  Result := FoundTime and FoundDay and FoundMonth and FoundYear and (Day >= 1) and (Day <= 31) and
    (Year >= 1601) and (Hour <= 23) and (Minute <= 59) and (Second <= 59);
  if Result then
    UnixTime := DaysFromCivil(Year, Month, Day) * 86400 + Hour * 3600 + Minute * 60 + Second;
end;

end.
