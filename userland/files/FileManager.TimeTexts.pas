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
  Times as the file manager shows them: "2026-11-15 09:42", in
  universal time (the system has no time zones yet).
}
unit FileManager.TimeTexts;

{$mode objfpc}
{$H+}

interface

{ Seconds since 1970 as a date and a time of day. }
function TimeText(Time: Int64): string;

implementation

uses
  SysUtils,
  Sys.Time;

function TimeText(Time: Int64): string;
var
  Moment: Sys.Time.TDateTime;
begin
  DecodeTime(Time, Moment);
  Result := Format('%.4d-%.2d-%.2d %.2d:%.2d', [Moment.Year, Moment.Month, Moment.Day, Moment.Hour, Moment.Minute]);
end;

end.
