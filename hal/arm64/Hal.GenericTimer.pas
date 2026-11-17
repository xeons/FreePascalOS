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
  The ARM generic timer: the system counter, the same on every processor
  and running at the frequency CNTFRQ_EL0 gives (54 MHz on a Raspberry
  Pi 4, 62.5 MHz or 1 GHz under QEMU), and each processor's virtual timer,
  which interrupts once the counter reaches its compare value - a
  one-shot clock interrupt, as the local APIC timer is on x86-64.

  The virtual timer's interrupt (a PPI) is the one the ACPI GTDT names
  (27 on QEMU's virt machine and the Pi 4).
}
unit Hal.GenericTimer;

{$mode objfpc}

interface

{ Reads the GTDT and the counter frequency. }
procedure InitializeGenericTimer;

function CounterFrequency: QWord;
{ The timer's interrupt (INTID) and whether it is level triggered. }
function TimerInterrupt: LongWord;
function TimerInterruptIsLevelTriggered: Boolean;

{ Nanoseconds since the counter started, less the time paused. }
function GenericTimerNanoseconds: QWord;

{ Sets this processor's timer to interrupt in Ticks counter ticks (0:
  right away) and enables it. }
procedure SetTimerInterruptIn(Ticks: QWord);
procedure StopTimer;

{ Before sleeping and after waking: the time continues where it was. }
procedure PauseGenericTimer;
procedure ContinueGenericTimer;

implementation

uses
  Firmware.Acpi,
  Kernel.Arch.Cpu,
  Hal.FirmwareTables;

type
  TGenericTimerTable = packed record
    Header: TAcpiTableHeader;
    CounterControlAddress: QWord;
    Reserved: LongWord;
    SecurePhysicalInterrupt: LongWord;
    SecurePhysicalFlags: LongWord;
    PhysicalInterrupt: LongWord;
    PhysicalFlags: LongWord;
    VirtualInterrupt: LongWord;
    VirtualFlags: LongWord;
    HypervisorInterrupt: LongWord;
    HypervisorFlags: LongWord;
  end;
  PGenericTimerTable = ^TGenericTimerTable;

const
  NanosecondsPerSecond = 1000000000;
  { The virtual timer's PPI where the GTDT is missing (the architecture
    recommends it). }
  DefaultVirtualTimerInterrupt = 27;
  TimerFlagEdgeTriggered = 1;
  TimerControlEnable = 1;
  TimerControlMask = 2;

var
  Frequency: QWord = 0;
  Interrupt: LongWord = DefaultVirtualTimerInterrupt;
  LevelTriggered: Boolean = True;
  { Counter value that is time zero, and the time a pause began. }
  CounterOrigin: QWord = 0;
  PausedNanoseconds: QWord = 0;

procedure ArchWriteTimerCompare(Value: QWord); external name 'ArchWriteTimerCompare';
procedure ArchWriteTimerControl(Value: QWord); external name 'ArchWriteTimerControl';

procedure InitializeGenericTimer;
var
  Table: PGenericTimerTable;
begin
  Frequency := ReadCounterFrequency;
  CounterOrigin := ReadTimeStampCounter;
  Table := PGenericTimerTable(FindFirmwareTable('GTDT', 0));
  if (Table <> nil) and (Table^.VirtualInterrupt <> 0) then
  begin
    Interrupt := Table^.VirtualInterrupt;
    LevelTriggered := (Table^.VirtualFlags and TimerFlagEdgeTriggered) = 0;
  end;
end;

function CounterFrequency: QWord;
begin
  Result := Frequency;
end;

function TimerInterrupt: LongWord;
begin
  Result := Interrupt;
end;

function TimerInterruptIsLevelTriggered: Boolean;
begin
  Result := LevelTriggered;
end;

function GenericTimerNanoseconds: QWord;
var
  Ticks: QWord;
begin
  if Frequency = 0 then
    Exit(0);
  Ticks := ReadTimeStampCounter - CounterOrigin;
  { In two parts, so the product cannot overflow. }
  Result := (Ticks div Frequency) * NanosecondsPerSecond +
    ((Ticks mod Frequency) * NanosecondsPerSecond) div Frequency;
end;

procedure SetTimerInterruptIn(Ticks: QWord);
begin
  ArchWriteTimerCompare(ReadTimeStampCounter + Ticks);
  ArchWriteTimerControl(TimerControlEnable);
end;

procedure StopTimer;
begin
  ArchWriteTimerControl(TimerControlMask);
end;

procedure PauseGenericTimer;
begin
  PausedNanoseconds := GenericTimerNanoseconds;
end;

procedure ContinueGenericTimer;
var
  TicksPassed: QWord;
begin
  { The counter value that makes the time PausedNanoseconds now. }
  TicksPassed := (PausedNanoseconds div NanosecondsPerSecond) * Frequency +
    ((PausedNanoseconds mod NanosecondsPerSecond) * Frequency) div NanosecondsPerSecond;
  CounterOrigin := ReadTimeStampCounter - TicksPassed;
end;

end.
