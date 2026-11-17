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
  Entering user mode on AArch64 (EL0, through ERET; the code is in
  ExceptionVectors.s).
}
unit Kernel.Arch.UserMode;

{$mode objfpc}

interface

uses
  Kernel.Arch.TrapFrame;

{ Starts executing user code at EntryPoint with the given stack. Argument
  is passed in the first argument register (X0); all other general
  purpose registers start out zero. Never returns. }
procedure ArchEnterUserMode(EntryPoint: QWord; StackPointer: QWord; Argument: QWord);

function ArchFrameIsFromUserMode(Frame: PTrapFrame): Boolean;

implementation

uses
  Kernel.Processors;

const
  { SPSR.M[3:0]: the exception level and stack the frame returns to;
    0 is EL0. }
  SavedModeMask = $F;

procedure ArchEnterUserModeAt(EntryPoint, StackPointer, Argument, KernelStackTop: QWord);
  external name 'ArchEnterUserModeAt';

procedure ArchEnterUserMode(EntryPoint: QWord; StackPointer: QWord; Argument: QWord);
begin
  ArchEnterUserModeAt(EntryPoint, StackPointer, Argument, CurrentProcessor^.SystemCallStack);
end;

function ArchFrameIsFromUserMode(Frame: PTrapFrame): Boolean;
begin
  Result := (Frame^.Spsr and SavedModeMask) = 0;
end;

end.
