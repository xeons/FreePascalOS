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

uses
  Abi.SystemCalls,
  Sys.Files,
  Sys.Format,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: unlink FILE'#10 +
    'Call the unlink function to remove the specified FILE.'#10;

var
  Parser: TOptionParser;
  Information: TFileInformation;
  Error: LongInt;
begin
  ParseOperandsOnly(Parser, Usage);
  if Parser.OperandCount < 1 then
    FailWithUsageHint('missing operand', []);
  if Parser.OperandCount > 1 then
    FailWithUsageHint('extra operand ''%s''', [ArgumentText(Parser.Operands[1])]);
  Error := GetLinkInformation(Parser.Operands[0], Information);
  if (Error = ErrorNone) and (Information.Kind = KindDirectory) then
    Error := ErrorIsDirectory;
  if Error = ErrorNone then
    Error := RemovePath(Parser.Operands[0]);
  if Error <> ErrorNone then
    FailWithError(1, Error, 'cannot unlink ''%s''', [ArgumentText(Parser.Operands[0])]);
end.
