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
  Why something failed, in words for the people using the file manager
  rather than the system's terse messages: "You do not have permission"
  rather than "Permission denied", "The disk is full", "The volume is no
  longer there" for a disk unplugged mid-copy. Errors without words of
  their own get the system's message.
}
unit FileManager.ErrorTexts;

{$mode objfpc}
{$H+}

interface

function ReasonText(Error: LongInt): string;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Errors;

function ReasonText(Error: LongInt): string;
begin
  case Error of
    ErrorAccessDenied, ErrorNotPermitted: Result := 'You do not have permission.';
    ErrorNoSpace: Result := 'The disk is full.';
    ErrorNoDevice: Result := 'The volume is no longer there (its disk was removed).';
    ErrorReadOnly: Result := 'The volume can only be read.';
    ErrorNotFound: Result := 'It is not there any more.';
    ErrorExists: Result := 'Something with that name is there already.';
    ErrorDirectoryNotEmpty: Result := 'The folder is not empty.';
    ErrorNameTooLong: Result := 'The name is too long.';
    ErrorBusy: Result := 'It is in use.';
    ErrorIo: Result := 'The disk could not be read or written.';
    ErrorInvalidArgument: Result := 'That cannot be done to it.';
    ErrorUnsupported: Result := 'The file system cannot do that.';
  else
    Result := StrPas(ErrorMessage(Error)) + '.';
  end;
end;

end.
