{
  Time and date.

  Times are Unix times (seconds since 1970-01-01 UTC). The calendar
  conversions come from Runtime.Time, which this library also contains.
}
unit Sys.Time;

{$mode objfpc}

interface

uses
  Runtime.Time;

type
  TDateTime = record
    Year, Month, Day: LongInt;
    Hour, Minute, Second: LongInt;
    { 0 = Sunday }
    DayOfWeek: LongInt;
  end;

function CurrentTime: TUnixTime;
function UptimeMilliseconds: QWord;
procedure DecodeTime(Time: TUnixTime; out DateTime: TDateTime);
function DayName(DayOfWeek: LongInt): PChar;
function MonthName(Month: LongInt): PChar;

implementation

uses
  Sys.Kernel;

const
  TimeWallClock = 0;
  TimeUptime = 1;

  DayNames: array[0..6] of PChar = ('Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat');
  MonthNames: array[1..12] of PChar = ('Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec');

function CurrentTime: TUnixTime;
begin
  Result := KernelGetTime(TimeWallClock);
end;

function UptimeMilliseconds: QWord;
begin
  Result := QWord(KernelGetTime(TimeUptime));
end;

procedure DecodeTime(Time: TUnixTime; out DateTime: TDateTime);
var
  Days: Int64;
begin
  UnixTimeToCalendar(Time, DateTime.Year, DateTime.Month, DateTime.Day,
    DateTime.Hour, DateTime.Minute, DateTime.Second);
  { 1970-01-01 was a Thursday. }
  Days := Time div 86400;
  if (Time mod 86400) < 0 then
    Dec(Days);
  DateTime.DayOfWeek := LongInt(((Days mod 7) + 7 + 4) mod 7);
end;

function DayName(DayOfWeek: LongInt): PChar;
begin
  if (DayOfWeek < 0) or (DayOfWeek > 6) then
    Exit('???');
  Result := DayNames[DayOfWeek];
end;

function MonthName(Month: LongInt): PChar;
begin
  if (Month < 1) or (Month > 12) then
    Exit('???');
  Result := MonthNames[Month];
end;

end.
