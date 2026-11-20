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
  HTTP dates (RFC 9110 section 5.6.7): written as IMF-fixdate ("Sun, 06
  Nov 1994 08:49:37 GMT"); read in all three forms the RFC asks
  recipients to take (IMF-fixdate, RFC 850 "Sunday, 06-Nov-94 ...",
  asctime "Sun Nov  6 08:49:37 1994") through the cookie date
  algorithm (Http.CookieDates), which takes all of them. Times are
  seconds since 1970 UTC.

  Plain Pascal (the RTL only), checked on the host by tools/HttpTest.
}
unit Http.Dates;

{$mode objfpc}
{$H+}

interface

function ParseHttpDate(const Text: string; out UnixTime: Int64): Boolean;
function FormatHttpDate(UnixTime: Int64): string;

implementation

uses
  SysUtils,
  Http.CookieDates;

const
  DayNames: array[0..6] of string = ('Thu', 'Fri', 'Sat', 'Sun', 'Mon', 'Tue', 'Wed');
  MonthNames: array[1..12] of string = ('Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct',
    'Nov', 'Dec');

function ParseHttpDate(const Text: string; out UnixTime: Int64): Boolean;
begin
  Result := ParseCookieDate(Text, UnixTime);
end;

{ Days since 1970-01-01 to a civil date (H. Hinnant's algorithm). }
procedure CivilFromDays(Days: Int64; out Year, Month, Day: Integer);
var
  Era, DayOfEra, YearOfEra, DayOfYear, MonthPart: Int64;
begin
  Days := Days + 719468;
  if Days >= 0 then
    Era := Days div 146097
  else
    Era := (Days - 146096) div 146097;
  DayOfEra := Days - Era * 146097;
  YearOfEra := (DayOfEra - DayOfEra div 1460 + DayOfEra div 36524 - DayOfEra div 146096) div 365;
  DayOfYear := DayOfEra - (365 * YearOfEra + YearOfEra div 4 - YearOfEra div 100);
  MonthPart := (5 * DayOfYear + 2) div 153;
  Day := DayOfYear - (153 * MonthPart + 2) div 5 + 1;
  if MonthPart < 10 then
    Month := MonthPart + 3
  else
    Month := MonthPart - 9;
  Year := YearOfEra + Era * 400;
  if Month <= 2 then
    Inc(Year);
end;

function FormatHttpDate(UnixTime: Int64): string;
var
  Days, Seconds: Int64;
  Year, Month, Day: Integer;
begin
  if UnixTime < 0 then
    UnixTime := 0;
  Days := UnixTime div 86400;
  Seconds := UnixTime mod 86400;
  CivilFromDays(Days, Year, Month, Day);
  Result := Format('%s, %.2d %s %.4d %.2d:%.2d:%.2d GMT', [DayNames[Days mod 7], Day, MonthNames[Month], Year,
    Seconds div 3600, (Seconds div 60) mod 60, Seconds mod 60]);
end;

end.
