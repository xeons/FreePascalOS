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
  The taskbar clock's time: hours and minutes, HH:MM, in the local time
  of the system's time zone (Sys.LocalTime), as date shows it. The zone
  is asked for every time, so a new one shows within a second.
}
unit Desktop.Clock;

{$mode objfpc}
{$H+}

interface

{ The time now, as the clock shows it. }
function ClockText: string;

implementation

uses
  SysUtils,
  Sys.Time,
  Sys.LocalTime;

function ClockText: string;
var
  Local: TLocalTime;
begin
  DecodeLocalTime(CurrentTime, Local);
  Result := Format('%.2d:%.2d', [Local.DateTime.Hour, Local.DateTime.Minute]);
end;

end.
