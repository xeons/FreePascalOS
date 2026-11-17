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
  System calls and error handling of the FreePascalOS System unit.

  Every kernel call returns a value of zero or more on success and minus
  an Abi error code on failure. The Abi error codes are the POSIX errno
  numbers, so they map onto InOutRes the way Unix ones do. The last error
  of the calling thread is kept for GetLastOSError (SysUtils).
}

{$include Abi.SystemCalls.inc}

{ SystemCall, the thread control block and processor exception details. }
{$ifdef CPUAARCH64}
{$include syscpu_aarch64.inc}
{$else}
{$include syscpu_x86_64.inc}
{$endif}

threadvar
  LastSystemError: LongInt;

function GetLastSystemError: LongInt;
begin
  GetLastSystemError := LastSystemError;
end;

procedure SetLastSystemError(Error: LongInt);
begin
  LastSystemError := Error;
end;

{ The InOutRes value for an Abi error code. }
function ErrorToInOutRes(Error: LongInt): Word;
begin
  case Error of
    ErrorTooManyHandles: ErrorToInOutRes := 4;
    ErrorNotFound: ErrorToInOutRes := 2;
    ErrorBadHandle: ErrorToInOutRes := 6;
    ErrorOutOfMemory, ErrorBadAddress: ErrorToInOutRes := 217;
    ErrorInvalidArgument: ErrorToInOutRes := 218;
    ErrorBrokenPipe, ErrorInterrupted, ErrorIo, ErrorNoSpace: ErrorToInOutRes := 101;
    ErrorNameTooLong: ErrorToInOutRes := 3;
    ErrorReadOnly, ErrorExists, ErrorDirectoryNotEmpty, ErrorAccessDenied, ErrorNotPermitted,
    ErrorBusy, ErrorNotDirectory, ErrorIsDirectory: ErrorToInOutRes := 5;
  else
    ErrorToInOutRes := Word(Error);
  end;
end;

{ For the low level file routines: a negative call result becomes the
  thread's last error and InOutRes. Returns True if Result is an error. }
function FailedCall(CallResult: Int64): Boolean;
begin
  FailedCall := CallResult < 0;
  if FailedCall then
  begin
    LastSystemError := LongInt(-CallResult);
    InOutRes := ErrorToInOutRes(LastSystemError);
  end;
end;

function Do_IsDevice(Handle: THandle): Boolean;
begin
  Do_IsDevice := SystemCall(CallGetHandleKind, QWord(Int64(Handle)), 0, 0, 0, 0, 0) = HandleKindConsole;
end;
