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
  The taskbar clock's time: hours and minutes, HH:MM.

  The system clock runs in UTC and the system has no time zone setting
  yet (that comes with the configuration library), so the time shown is
  UTC, as date shows it.
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
  Sys.Time;

function ClockText: string;
var
  Now: TDateTime;
begin
  DecodeTime(CurrentTime, Now);
  Result := Format('%.2d:%.2d', [Now.Hour, Now.Minute]);
end;

end.
