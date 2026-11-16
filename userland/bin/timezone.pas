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
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Time,
  Sys.TimeZones,
  Sys.LocalTime,
  Sys.SystemSettings,
  Util.CommandLine,
  Util.Messages,
  Sys.Streams,
  Util.SystemRequests;

const
  Usage = 'Usage: timezone [-l] [ZONE]'#10 +
    'Show the system''s time zone, list the zones (-l), or set the system''s zone.'#10;
  OptionList = 1;

procedure WriteZone(Zone: PTimeZone);
var
  Local: TLocalTime;
begin
  DecodeTimeInZone(Zone, CurrentTime, Local);
  PrintStringLine(Format('%s %s %s', [Zone^.Name, FormatUtcOffset(Local.Offset), Local.Abbreviation]));
end;

procedure ListZones;
var
  Index: Integer;
begin
  for Index := 0 to TimeZoneCount - 1 do
    WriteZone(TimeZoneAt(Index));
end;

procedure SetZone(const Name: string);
var
  Request: TSystemSettingsRequest;
  Error: LongInt;
begin
  if FindTimeZone(PChar(Name)) = nil then
    Fail(1, Format('unknown time zone ''%s'' (timezone -l lists them)', [Name]));
  Request := NewSystemSettingsRequest(SystemRequestSetTimeZone);
  SetRequestText(Request.Text, Name);
  Error := SendSystemRequest(Request, True);
  if Error <> ErrorNone then
    FailWithError(1, Error, 'cannot set the time zone');
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  List: Boolean;
begin
  List := False;
  CommandLine := TCommandLine.Create([CommandOption('l', 'list', False, OptionList)], Usage);
  while CommandLine.NextOption(Code, Value) do
    if Code = OptionList then
      List := True;
  if CommandLine.OperandCount > 1 then
    FailWithUsageHint(Format('extra operand ''%s''', [CommandLine.Operands[1]]));
  if List then
    ListZones
  else if CommandLine.OperandCount = 1 then
  begin
    SetZone(CommandLine.Operands[0]);
    WriteZone(SystemTimeZone);
  end
  else
    WriteZone(SystemTimeZone);
end.
