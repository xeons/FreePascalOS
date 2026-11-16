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

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Text,
  Runtime.Time,
  Sys.Format,
  Sys.Streams,
  Sys.Text,
  Sys.Files,
  Sys.Time,
  Sys.TimeZones,
  Sys.LocalTime,
  Sys.SystemSettings,
  Sys.Environment,
  Util.Dates,
  Util.SystemRequests,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: date [OPTION]... [+FORMAT]'#10 +
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

procedure WritePadded(Value: Int64; Width: Integer; Padding: Char);
var
  NumberText: TNumberText;
  Digits: PChar;
  Count: Integer;
begin
  Digits := FormatSignedDecimal(Value, NumberText);
  Count := Integer(TextLength(Digits));
  while Count < Width do
  begin
    WriteCharacter(StandardOutput, Padding);
    Inc(Count);
  end;
  WriteText(StandardOutput, Digits);
end;

function DayOfYear(const DateTime: TDateTime): Int64;
begin
  Result := DaysSinceUnixEpoch(DateTime.Year, DateTime.Month, DateTime.Day) -
    DaysSinceUnixEpoch(DateTime.Year, 1, 1) + 1;
end;

var
  { -u: UTC rather than the current zone. }
  ShowUniversal: Boolean;

procedure WriteTime(Format: PChar; Time: TUnixTime);
var
  Local: TLocalTime;
  DateTime: TDateTime;
  Position: Integer;
  OffsetText: array[0..7] of Char;
begin
  if ShowUniversal then
    DecodeTimeInZone(UtcTimeZone, Time, Local)
  else
    DecodeLocalTime(Time, Local);
  DateTime := Local.DateTime;
  FormatUtcOffset(Local.Offset, @OffsetText[0]);
  Position := 0;
  while Format[Position] <> #0 do
  begin
    if (Format[Position] <> '%') or (Format[Position + 1] = #0) then
    begin
      WriteCharacter(StandardOutput, Format[Position]);
      Inc(Position);
      Continue;
    end;
    Inc(Position);
    case Format[Position] of
      'Y': WritePadded(DateTime.Year, 4, '0');
      'y': WritePadded(DateTime.Year mod 100, 2, '0');
      'm': WritePadded(DateTime.Month, 2, '0');
      'd': WritePadded(DateTime.Day, 2, '0');
      'e': WritePadded(DateTime.Day, 2, ' ');
      'H': WritePadded(DateTime.Hour, 2, '0');
      'M': WritePadded(DateTime.Minute, 2, '0');
      'S': WritePadded(DateTime.Second, 2, '0');
      'j': WritePadded(DayOfYear(DateTime), 3, '0');
      'a': WriteText(StandardOutput, DayName(DateTime.DayOfWeek));
      'b', 'h': WriteText(StandardOutput, MonthName(DateTime.Month));
      's': WriteDecimal(StandardOutput, Time);
      'Z': WriteText(StandardOutput, Local.Abbreviation);
      'z': WriteText(StandardOutput, @OffsetText[0]);
      'F': WriteTime('%Y-%m-%d', Time);
      'T': WriteTime('%H:%M:%S', Time);
      'D': WriteTime('%m/%d/%y', Time);
      'R': WriteTime('%H:%M', Time);
      'n': WriteCharacter(StandardOutput, #10);
      't': WriteCharacter(StandardOutput, #9);
      '%': WriteCharacter(StandardOutput, '%');
    else
      begin
        WriteCharacter(StandardOutput, '%');
        WriteCharacter(StandardOutput, Format[Position]);
      end;
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
    FailWithError(1, Error, 'cannot set date', []);
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Time: TUnixTime;
  Format: PChar;
  Information: TFileInformation;
  SetText: PChar;
  DateText: PChar;
begin
  Time := CurrentTime;
  Format := DefaultFormat;
  SetText := nil;
  DateText := nil;
  ShowUniversal := False;
  BeginOptions(Parser, [
    OptionDefinition('d', 'date', True, OptionDate),
    OptionDefinition('s', 'set', True, OptionSet),
    OptionDefinition('u', 'utc', False, OptionUniversal),
    OptionDefinition(#0, 'universal', False, OptionUniversal),
    OptionDefinition('r', 'reference', True, OptionReference)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionUniversal:
        begin
          ShowUniversal := True;
          { Dates written for -d and -s are UTC too. }
          SetVariable('TZ', 'UTC');
        end;
      OptionSet:
        SetText := Value;
      OptionDate:
        DateText := Value;
      OptionReference:
        begin
          if GetFileInformation(Value, Information) <> 0 then
            Fail(1, '%s: No such file or directory', [ArgumentText(Value)]);
          Time := Information.ModificationTime;
        end;
    end;

  if Parser.OperandCount > 1 then
    FailWithUsageHint('extra operand ''%s''', [ArgumentText(Parser.Operands[1])]);
  if Parser.OperandCount = 1 then
  begin
    if Parser.Operands[0][0] <> '+' then
      Fail(1, 'setting the date is not supported; invalid date ''%s''', [ArgumentText(Parser.Operands[0])]);
    Format := Parser.Operands[0] + 1;
  end;

  if (DateText <> nil) and not ParseDateText(DateText, Time) then
    Fail(1, 'invalid date ''%s''', [ArgumentText(DateText)]);
  if SetText <> nil then
  begin
    if not ParseDateText(SetText, Time) then
      Fail(1, 'invalid date ''%s''', [ArgumentText(SetText)]);
    SetClock(Time);
  end;

  WriteTime(Format, Time);
  WriteCharacter(StandardOutput, #10);
end.
