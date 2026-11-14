{
  date - print the system date and time

  date [-u] [-d DATE | -r FILE] [+FORMAT]

  The system clock runs in UTC, so times are always shown in UTC.
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
  Runtime.Text,
  Runtime.Time,
  Sys.Format,
  Sys.Streams,
  Sys.Text,
  Sys.Files,
  Sys.Time,
  Util.Dates,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: date [OPTION]... [+FORMAT]'#10 +
    'Display the current time in the given FORMAT.'#10 +
    #10 +
    '  -d, --date=STRING     display time described by STRING, not ''now'''#10 +
    '  -r, --reference=FILE  display the last modification time of FILE'#10 +
    '  -u, --utc, --universal  print Coordinated Universal Time (the default)'#10 +
    #10 +
    'FORMAT: %Y %y %m %d %e %H %M %S %j %a %b %s %F %T %D %Z %n %t %%'#10;

  DefaultFormat = '%a %b %e %H:%M:%S %Z %Y';

  OptionDate = 1;
  OptionUniversal = 2;
  OptionReference = 3;

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

procedure WriteTime(Format: PChar; Time: TUnixTime);
var
  DateTime: TDateTime;
  Position: Integer;
begin
  DecodeTime(Time, DateTime);
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
      'Z': WriteText(StandardOutput, 'UTC');
      'z': WriteText(StandardOutput, '+0000');
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

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Time: TUnixTime;
  Format: PChar;
  Information: TFileInformation;
begin
  Time := CurrentTime;
  Format := DefaultFormat;
  BeginOptions(Parser, [
    OptionDefinition('d', 'date', True, OptionDate),
    OptionDefinition('u', 'utc', False, OptionUniversal),
    OptionDefinition(#0, 'universal', False, OptionUniversal),
    OptionDefinition('r', 'reference', True, OptionReference)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionDate:
        if not ParseDateText(Value, Time) then
          Fail(1, 'invalid date ''%s''', [ArgumentText(Value)]);
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

  WriteTime(Format, Time);
  WriteCharacter(StandardOutput, #10);
end.
