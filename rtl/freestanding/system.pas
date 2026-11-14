{
  Minimal freestanding System unit.

  The Free Pascal compiler implicitly uses a unit named "System" in every
  module. The stock one depends on an operating system, so both the UEFI
  loader and the kernel are built against this replacement instead.

  It deliberately contains only what the compiler insists on, plus the few
  basic type aliases everything else expects. Higher level helpers live in
  the kernel runtime units, not here.
}
unit System;

interface

{$mode fpc}

{$include system.types.inc}

{ Called by the compiler at the start of a "program" main block. }
procedure fpc_initializeunits; compilerproc;

{ Called by the compiler at the end of a "program" main block. }
procedure fpc_do_exit; compilerproc;

implementation

procedure fpc_initializeunits; [public, alias: 'FPC_INITIALIZEUNITS']; compilerproc;
begin
  { Units in this system are initialized explicitly, never implicitly. }
end;

procedure fpc_do_exit; [public, alias: 'FPC_DO_EXIT']; compilerproc;
begin
  { There is nothing to return to. }
end;

end.
