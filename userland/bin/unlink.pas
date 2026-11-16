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
  unlink - remove a name (a file, never a directory)

  unlink FILE
}
program unlink;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Files,
  Util.CommandLine,
  Util.Messages;

const
  Usage = 'Usage: unlink FILE'#10 +
    'Call the unlink function to remove the specified FILE.'#10;

var
  CommandLine: TCommandLine;
  Path: string;
  Information: TFileInformation;
  Error: LongInt;
begin
  CommandLine := TCommandLine.Create([], Usage);
  CommandLine.ReadOperandsOnly;
  if CommandLine.OperandCount < 1 then
    FailWithUsageHint('missing operand');
  if CommandLine.OperandCount > 1 then
    FailWithUsageHint(Format('extra operand ''%s''', [CommandLine.Operands[1]]));
  Path := CommandLine.Operands[0];
  Error := GetLinkInformation(PChar(Path), Information);
  if (Error = ErrorNone) and (Information.Kind = KindDirectory) then
    Error := ErrorIsDirectory;
  if Error = ErrorNone then
    Error := RemovePath(PChar(Path));
  if Error <> ErrorNone then
    FailWithError(1, Error, Format('cannot unlink ''%s''', [Path]));
end.
