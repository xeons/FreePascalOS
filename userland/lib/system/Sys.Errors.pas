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
  Error codes and their messages.

  System calls report failure as a negative result; the error code is
  the negated value. These messages follow the wording Unix users know.
}
unit Sys.Errors;

{$mode objfpc}

interface

{ Turns a negative system call result into its error code (0 if the
  result is not an error). }
function ErrorCodeOf(CallResult: Int64): LongInt;

function ErrorMessage(Code: LongInt): PChar;

implementation

uses
  Abi.SystemCalls;

function ErrorCodeOf(CallResult: Int64): LongInt;
begin
  if CallResult < 0 then
    Result := LongInt(-CallResult)
  else
    Result := 0;
end;

{$include Abi.ErrorMessages.inc}

function ErrorMessage(Code: LongInt): PChar;
begin
  Result := AbiErrorMessage(Code);
end;

end.
