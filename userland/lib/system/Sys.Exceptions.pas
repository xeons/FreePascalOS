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
  Dealing with processor exceptions before they become Pascal exceptions.

  A processor exception (an access violation, a division by zero, ...)
  normally becomes a runtime error, and with SysUtils an exception such
  as EAccessViolation. An exception filter sees it first, with the
  exception record: what happened, where, and every register. If the
  filter can deal with it - skip the instruction, fix a register, map a
  page - it changes the context in the record and returns True, and the
  thread continues there (the kernel's CallContinue, like NtContinue).
  ContinueWithContext does the same for any context.

  The filter is process wide and runs in the thread that raised the
  exception, on its stack; it must not raise exceptions itself.
}
unit Sys.Exceptions;

{$mode objfpc}

interface

uses
  Abi.SystemCalls;

type
  TExceptionFilterRoutine = function(var ExceptionRecord: TAbiExceptionRecord): Boolean;

{ Installs Filter (nil removes it). }
procedure SetExceptionFilter(Filter: TExceptionFilterRoutine);

{ Continues the calling thread with the registers of Context. }
procedure ContinueWithContext(const Context: TAbiContext); noreturn;

implementation

var
  InstalledFilter: TExceptionFilterRoutine = nil;

function CallInstalledFilter(ExceptionRecord: Pointer): Boolean;
begin
  Result := Assigned(InstalledFilter) and InstalledFilter(PAbiExceptionRecord(ExceptionRecord)^);
end;

procedure SetExceptionFilter(Filter: TExceptionFilterRoutine);
begin
  InstalledFilter := Filter;
  if Assigned(Filter) then
    ExceptionFilter := @CallInstalledFilter
  else
    ExceptionFilter := nil;
end;

procedure ContinueWithContext(const Context: TAbiContext);
begin
  ContinueAtContext(@Context);
end;

end.
