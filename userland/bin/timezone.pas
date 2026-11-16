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
  timezone - show, list or set the system's time zone

  timezone             the system's zone, and its offset and abbreviation
                       now:  Europe/Berlin +0100 CET
  timezone -l          every zone of the database, with its offset now
  timezone ZONE        makes ZONE the system's zone, remembered for the
                       next boot (Time/Zone in the system's settings),
                       through the system settings service: root may,
                       others are asked for an administrator's password

  Zones are named as in the IANA database (Sys.TimeZones has the list
  and their daylight saving rules).
}
program timezone;

{$mode objfpc}

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Format,
  Sys.Streams,
  Sys.Time,
  Sys.TimeZones,
  Sys.LocalTime,
  Sys.SystemSettings,
  Util.Messages,
  Util.Options,
  Util.SystemRequests;

const
  Usage: PChar = 'Usage: timezone [-l] [ZONE]'#10 +
    'Show the system''s time zone, list the zones (-l), or set the system''s zone.'#10;
  OptionList = 1;

procedure WriteZone(Zone: PTimeZone);
var
  Local: TLocalTime;
  OffsetText: array[0..7] of Char;
begin
  DecodeTimeInZone(Zone, CurrentTime, Local);
  FormatUtcOffset(Local.Offset, @OffsetText[0]);
  WriteFormatted(StandardOutput, '%s %s %s'#10, [ArgumentText(Zone^.Name), ArgumentText(@OffsetText[0]),
    ArgumentText(Local.Abbreviation)]);
end;

procedure ListZones;
var
  Index: Integer;
begin
  for Index := 0 to TimeZoneCount - 1 do
    WriteZone(TimeZoneAt(Index));
end;

procedure SetZone(Name: PChar);
var
  Request: TSystemSettingsRequest;
  Error: LongInt;
begin
  if FindTimeZone(Name) = nil then
    Fail(1, 'unknown time zone ''%s'' (timezone -l lists them)', [ArgumentText(Name)]);
  Request := NewSystemSettingsRequest(SystemRequestSetTimeZone);
  SetRequestText(@Request.Text[0], SystemTextCapacity, Name);
  Error := SendSystemRequest(Request, True);
  if Error <> ErrorNone then
    FailWithError(1, Error, 'cannot set the time zone', []);
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  List: Boolean;
begin
  List := False;
  BeginOptions(Parser, [OptionDefinition('l', 'list', False, OptionList)], Usage);
  while NextOption(Parser, Code, Value) do
    if Code = OptionList then
      List := True;
  if Parser.OperandCount > 1 then
    FailWithUsageHint('extra operand ''%s''', [ArgumentText(Parser.Operands[1])]);
  if List then
    ListZones
  else if Parser.OperandCount = 1 then
  begin
    SetZone(Parser.Operands[0]);
    WriteZone(SystemTimeZone);
  end
  else
    WriteZone(SystemTimeZone);
end.
