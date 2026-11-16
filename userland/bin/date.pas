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
  date - print the system date and time

  date [-u] [-d DATE | -r FILE] [+FORMAT]
  date -s DATE

  The system clock runs in UTC; times are shown in the local time of the
  system's time zone (or the zone TZ names), or in UTC with -u. -s sets
  the system's date and time (DATE as for -d, a local time unless it
  ends in UTC), through the system settings service: root may, others
  are asked for an administrator's password.
  FORMAT conversions:
    %Y year  %y year % 100  %m month  %d day  %e day, space padded
    %H hour  %M minute  %S second  %j day of the year
    %a weekday name  %b month name  %s seconds since 1970
    %F = %Y-%m-%d  %T = %H:%M:%S  %D = %m/%d/%y  %Z time zone  %n %t %%
}
program date;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Runtime.Time,
  Sys.Files,
  Sys.Time,
  Sys.TimeZones,
  Sys.LocalTime,
  Sys.SystemSettings,
  Sys.Environment,
  Util.CommandLine,
  Util.Dates,
  Util.SystemRequests,
  Util.Messages,
  Util.Output;

const
  Usage = 'Usage: date [OPTION]... [+FORMAT]'#10 +
    'Display the current time in the given FORMAT.'#10 +
    #10 +
    '  -d, --date=STRING     display time described by STRING, not ''now'''#10 +
    '  -r, --reference=FILE  display the last modification time of FILE'#10 +
    '  -s, --set=STRING      set time described by STRING'#10 +
    '  -u, --utc, --universal  print or set Coordinated Universal Time'#10 +
    #10 +
    'FORMAT: %Y %y %m %d %e %H %M %S %j %a %b %s %F %T %D %Z %n %t %%'#10;

  DefaultFormat = '%a %b %e %H:%M:%S %Z %Y';

  OptionDate = 1;
  OptionUniversal = 2;
  OptionReference = 3;
  OptionSet = 4;

{ Value in decimal, padded on the left with Padding to Width characters. }
function Padded(Value: Int64; Width: Integer; Padding: Char): string;
begin
  Result := IntToStr(Value);
  if Length(Result) < Width then
    Result := StringOfChar(Padding, Width - Length(Result)) + Result;
end;

function DayOfYear(const DateTime: Sys.Time.TDateTime): Int64;
begin
  Result := DaysSinceUnixEpoch(DateTime.Year, DateTime.Month, DateTime.Day) -
    DaysSinceUnixEpoch(DateTime.Year, 1, 1) + 1;
end;

var
  { -u: UTC rather than the current zone. }
  ShowUniversal: Boolean;

{ Time written as TimeFormat says. }
function FormatTime(const TimeFormat: string; Time: TUnixTime): string;
var
  Local: TLocalTime;
  DateTime: Sys.Time.TDateTime;
  Position: Integer;
  OffsetBuffer: array[0..7] of Char;
  OffsetText: string;
begin
  if ShowUniversal then
    DecodeTimeInZone(UtcTimeZone, Time, Local)
  else
    DecodeLocalTime(Time, Local);
  DateTime := Local.DateTime;
  FormatUtcOffset(Local.Offset, @OffsetBuffer[0]);
  OffsetText := PChar(@OffsetBuffer[0]);
  Result := '';
  Position := 1;
  while Position <= Length(TimeFormat) do
  begin
    if (TimeFormat[Position] <> '%') or (Position = Length(TimeFormat)) then
    begin
      Result := Result + TimeFormat[Position];
      Inc(Position);
      Continue;
    end;
    Inc(Position);
    case TimeFormat[Position] of
      'Y': Result := Result + Padded(DateTime.Year, 4, '0');
      'y': Result := Result + Padded(DateTime.Year mod 100, 2, '0');
      'm': Result := Result + Padded(DateTime.Month, 2, '0');
      'd': Result := Result + Padded(DateTime.Day, 2, '0');
      'e': Result := Result + Padded(DateTime.Day, 2, ' ');
      'H': Result := Result + Padded(DateTime.Hour, 2, '0');
      'M': Result := Result + Padded(DateTime.Minute, 2, '0');
      'S': Result := Result + Padded(DateTime.Second, 2, '0');
      'j': Result := Result + Padded(DayOfYear(DateTime), 3, '0');
      'a': Result := Result + DayName(DateTime.DayOfWeek);
      'b', 'h': Result := Result + MonthName(DateTime.Month);
      's': Result := Result + IntToStr(Time);
      'Z': Result := Result + Local.Abbreviation;
      'z': Result := Result + OffsetText;
      'F': Result := Result + FormatTime('%Y-%m-%d', Time);
      'T': Result := Result + FormatTime('%H:%M:%S', Time);
      'D': Result := Result + FormatTime('%m/%d/%y', Time);
      'R': Result := Result + FormatTime('%H:%M', Time);
      'n': Result := Result + #10;
      't': Result := Result + #9;
      '%': Result := Result + '%';
    else
      Result := Result + '%' + TimeFormat[Position];
    end;
    Inc(Position);
  end;
end;

{ Asks the system settings service to set the clock to Time. }
procedure SetClock(Time: TUnixTime);
var
  Request: TSystemSettingsRequest;
  Error: LongInt;
begin
  Request := NewSystemSettingsRequest(SystemRequestSetClock);
  Request.Time := Time;
  Error := SendSystemRequest(Request, True);
  if Error <> ErrorNone then
    FailWithError(1, Error, 'cannot set date');
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Time: TUnixTime;
  TimeFormat: string;
  Information: TFileInformation;
  HasSetText: Boolean;
  SetText: string;
  HasDateText: Boolean;
  DateText: string;
  Operand: string;
begin
  Time := CurrentTime;
  TimeFormat := DefaultFormat;
  HasSetText := False;
  HasDateText := False;
  ShowUniversal := False;
  CommandLine := TCommandLine.Create([
    CommandOption('d', 'date', True, OptionDate),
    CommandOption('s', 'set', True, OptionSet),
    CommandOption('u', 'utc', False, OptionUniversal),
    CommandOption(#0, 'universal', False, OptionUniversal),
    CommandOption('r', 'reference', True, OptionReference)], Usage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionUniversal:
        begin
          ShowUniversal := True;
          { Dates written for -d and -s are UTC too. }
          SetVariable('TZ', 'UTC');
        end;
      OptionSet:
        begin
          HasSetText := True;
          SetText := Value;
        end;
      OptionDate:
        begin
          HasDateText := True;
          DateText := Value;
        end;
      OptionReference:
        begin
          if GetFileInformation(PChar(Value), Information) <> 0 then
            Fail(1, Value + ': No such file or directory');
          Time := Information.ModificationTime;
        end;
    end;

  if CommandLine.OperandCount > 1 then
    FailWithUsageHint(Format('extra operand ''%s''', [CommandLine.Operands[1]]));
  if CommandLine.OperandCount = 1 then
  begin
    Operand := CommandLine.Operands[0];
    if (Operand = '') or (Operand[1] <> '+') then
      Fail(1, Format('setting the date is not supported; invalid date ''%s''', [Operand]));
    TimeFormat := Copy(Operand, 2, MaxInt);
  end;

  if HasDateText and not ParseDateText(DateText, Time) then
    Fail(1, Format('invalid date ''%s''', [DateText]));
  if HasSetText then
  begin
    if not ParseDateText(SetText, Time) then
      Fail(1, Format('invalid date ''%s''', [SetText]));
    SetClock(Time);
  end;

  PrintString(FormatTime(TimeFormat, Time) + #10);
end.
