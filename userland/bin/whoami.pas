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
  whoami - print effective user name
}
program whoami;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Util.Accounts,
  Util.CommandLine,
  Util.Messages,
  Sys.Streams;

const
  Usage = 'Usage: whoami'#10 +
    'Print the user name associated with the current effective user ID.'#10;

var
  CommandLine: TCommandLine;
  Name: string;
begin
  CommandLine := TCommandLine.Create([], Usage);
  CommandLine.ReadOperandsOnly;
  if CommandLine.OperandCount > 0 then
    FailWithUsageHint('extra operand');
  if not FindUserName(CurrentUserId, Name) then
    Fail(1, Format('cannot find name for user ID %u', [CurrentUserId]));
  PrintStringLine(Name);
end.
