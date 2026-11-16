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
  logname - print user's login name

  The console session belongs to the real user of the process.
}
program logname;

{$mode objfpc}{$H+}

uses
  Util.Accounts,
  Util.CommandLine,
  Util.Output;

const
  Usage = 'Usage: logname'#10 +
    'Print the user''s login name.'#10;

var
  CommandLine: TCommandLine;
  Name: string;
begin
  CommandLine := TCommandLine.Create([], Usage);
  CommandLine.ReadOperandsOnly;
  if not FindUserName(CurrentRealUserId, Name) then
    Name := 'root';
  PrintStringLine(Name);
  CommandLine.Free;
end.
