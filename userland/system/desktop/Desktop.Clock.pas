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
  The taskbar clock's time: hours and minutes in the local time of the
  system's time zone (Sys.LocalTime), as date shows it - HH:MM, or
  H:MM AM/PM when ClockFormat says twelve hours (the user's setting
  Desktop/ClockFormat, Desktop.Settings). The zone is asked for every
  time, so a new one shows within a second.
}
unit Desktop.Clock;

{$mode objfpc}
{$H+}

interface

type
  TClockFormat = (ClockTwentyFourHours, ClockTwelveHours);

var
  ClockFormat: TClockFormat = ClockTwentyFourHours;

{ The time now, as the clock shows it. }
function ClockText: string;
{ The widest text the clock shows in its format, for its room. }
function WidestClockText: string;

implementation

uses
  SysUtils,
  Sys.Time,
  Sys.LocalTime;

function ClockText: string;
var
  Local: TLocalTime;
  Hour: LongInt;
begin
  DecodeLocalTime(CurrentTime, Local);
  if ClockFormat = ClockTwentyFourHours then
    Exit(Format('%.2d:%.2d', [Local.DateTime.Hour, Local.DateTime.Minute]));
  Hour := Local.DateTime.Hour mod 12;
  if Hour = 0 then
    Hour := 12;
  if Local.DateTime.Hour < 12 then
    Result := Format('%d:%.2d AM', [Hour, Local.DateTime.Minute])
  else
    Result := Format('%d:%.2d PM', [Hour, Local.DateTime.Minute]);
end;

function WidestClockText: string;
begin
  if ClockFormat = ClockTwentyFourHours then
    Result := '00:00'
  else
    Result := '00:00 PM';
end;

end.
