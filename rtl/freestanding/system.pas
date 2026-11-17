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

{ Called by code the compiler checks for division by zero itself, where
  the processor does not trap (AArch64). }
procedure fpc_divbyzero; compilerproc;

{ Copies Count bytes (the areas may overlap). The AArch64 code generator
  calls it to copy large records and arrays, which x86-64 does inline. }
procedure Move(const Source; var Dest; Count: SizeInt);

var
  { What fpc_divbyzero does: the kernel installs its panic; without one
    the processor stops here. }
  DivisionByZeroHandler: procedure = nil;

implementation

procedure fpc_initializeunits; [public, alias: 'FPC_INITIALIZEUNITS']; compilerproc;
begin
  { Units in this system are initialized explicitly, never implicitly. }
end;

procedure fpc_do_exit; [public, alias: 'FPC_DO_EXIT']; compilerproc;
begin
  { There is nothing to return to. }
end;

procedure Move(const Source; var Dest; Count: SizeInt); [public, alias: 'FPC_MOVE'];
var
  SourceBytes: PByte;
  DestinationBytes: PByte;
  Index: SizeInt;
begin
  if Count <= 0 then
    Exit;
  SourceBytes := PByte(@Source);
  DestinationBytes := PByte(@Dest);
  if (DestinationBytes < SourceBytes) or (DestinationBytes >= SourceBytes + Count) then
  begin
    Index := 0;
    while Index < Count do
    begin
      DestinationBytes[Index] := SourceBytes[Index];
      Inc(Index);
    end;
  end
  else
  begin
    Index := Count;
    while Index > 0 do
    begin
      Dec(Index);
      DestinationBytes[Index] := SourceBytes[Index];
    end;
  end;
end;

procedure fpc_divbyzero; [public, alias: 'FPC_DIVBYZERO']; compilerproc;
begin
  if Assigned(DivisionByZeroHandler) then
    DivisionByZeroHandler;
  while True do
    ;
end;

end.
