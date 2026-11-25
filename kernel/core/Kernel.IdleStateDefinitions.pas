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
  What an idle state is: its name, how long the processor takes to come
  out of it, the shortest stay worth going into it for, and what
  entering it takes (Kernel.Arch.IdleStates: an MWAIT hint on x86-64, a
  PSCI power state on AArch64). State 0 of every processor is the plain
  halt (HLT, WFI).
}
unit Kernel.IdleStateDefinitions;

{$mode objfpc}

interface

const
  IdleStateNameCapacity = 16;

  { How a state is entered. }
  IdleMethodHalt = 0;
  IdleMethodMonitorWait = 1;
  IdleMethodFirmwareSuspend = 2;
  { Reading an I/O port enters it (ACPI's older C-states). }
  IdleMethodPortRead = 3;

  { TIdleState.Flags. }
  { The processor's own clock interrupt (local APIC timer, generic
    timer) stops in it: another processor wakes it when it is due
    (Kernel.BroadcastTimer). }
  IdleStateStopsTimer = $01;
  { The processor loses its registers (PSCI power-down): it comes back
    through an entry point and its saved state. }
  IdleStateLosesContext = $02;

type
  TIdleState = record
    Name: array[0..IdleStateNameCapacity - 1] of Char;
    Method: LongWord;
    { The MWAIT hint, the PSCI power state or the port. }
    Parameter: LongWord;
    { IdleState* flags. }
    Flags: LongWord;
    ExitLatencyNanoseconds: QWord;
    { Going into it pays off only for an idle stretch at least this
      long (the time to the processor's next clock interrupt). }
    TargetResidencyNanoseconds: QWord;
  end;
  PIdleState = ^TIdleState;

implementation

end.
