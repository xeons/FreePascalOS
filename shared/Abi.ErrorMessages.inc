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
  The messages of the Abi error codes, in the wording Unix users know.

  Included by Sys.Errors and by the runtime's SysUtils
  (SysErrorMessage), after Abi.SystemCalls.
}

function AbiErrorMessage(Code: LongInt): PChar;
begin
  case Code of
    ErrorNone: AbiErrorMessage := 'Success';
    ErrorNotPermitted: AbiErrorMessage := 'Operation not permitted';
    ErrorAccessDenied: AbiErrorMessage := 'Permission denied';
    ErrorNotFound: AbiErrorMessage := 'No such file or directory';
    ErrorNoSuchProcess: AbiErrorMessage := 'No such process';
    ErrorInterrupted: AbiErrorMessage := 'Interrupted system call';
    ErrorTimedOut: AbiErrorMessage := 'Connection timed out';
    ErrorIo: AbiErrorMessage := 'Input/output error';
    ErrorBadExecutable: AbiErrorMessage := 'Exec format error';
    ErrorBadHandle: AbiErrorMessage := 'Bad file descriptor';
    ErrorNoChildProcess: AbiErrorMessage := 'No child processes';
    ErrorOutOfMemory: AbiErrorMessage := 'Cannot allocate memory';
    ErrorBadAddress: AbiErrorMessage := 'Bad address';
    ErrorBusy: AbiErrorMessage := 'Device or resource busy';
    ErrorExists: AbiErrorMessage := 'File exists';
    ErrorCrossVolume: AbiErrorMessage := 'Invalid cross-device link';
    ErrorNotDirectory: AbiErrorMessage := 'Not a directory';
    ErrorIsDirectory: AbiErrorMessage := 'Is a directory';
    ErrorInvalidArgument: AbiErrorMessage := 'Invalid argument';
    ErrorTooManyHandles: AbiErrorMessage := 'Too many open files';
    ErrorNoSpace: AbiErrorMessage := 'No space left on device';
    ErrorIllegalSeek: AbiErrorMessage := 'Illegal seek';
    ErrorReadOnly: AbiErrorMessage := 'Read-only file system';
    ErrorBrokenPipe: AbiErrorMessage := 'Broken pipe';
    ErrorNameTooLong: AbiErrorMessage := 'File name too long';
    ErrorNotImplemented: AbiErrorMessage := 'Function not implemented';
    ErrorDirectoryNotEmpty: AbiErrorMessage := 'Directory not empty';
    ErrorTooManyLinks: AbiErrorMessage := 'Too many levels of symbolic links';
    ErrorUnsupported: AbiErrorMessage := 'Operation not supported';
    ErrorWouldBlock: AbiErrorMessage := 'Resource temporarily unavailable';
    ErrorMessageTooLong: AbiErrorMessage := 'Message too long';
    ErrorNoDevice: AbiErrorMessage := 'No such device';
    ErrorCorrupted: AbiErrorMessage := 'Structure needs cleaning';
  else
    AbiErrorMessage := 'Unknown error';
  end;
end;
