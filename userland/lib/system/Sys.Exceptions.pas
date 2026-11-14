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
