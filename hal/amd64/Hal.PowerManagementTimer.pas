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
  The ACPI power management timer: a free running counter at
  3.579545 MHz in the chipset, read from the I/O port the FADT names
  (PM_TMR_BLK at offset 76, or X_PM_TMR_BLK at offset 208 when that is
  in I/O space), 24 bits wide or 32 with the FADT's TMR_VAL_EXT flag.

  A calibration reference (Hal.ClockCalibration) where the HPET is off
  or missing: every ACPI PC but hardware-reduced ones has it, also those
  that gate the PIT off. Only read here, never its interrupt.
}
unit Hal.PowerManagementTimer;

{$mode objfpc}

interface

const
  PowerManagementTimerFrequency = 3579545;

{ Finds the timer in the FADT and checks that it counts (kernel option
  pmtimer=off ignores it). }
function InitializePowerManagementTimer: Boolean;
function PowerManagementTimerIsPresent: Boolean;
{ Ticks elapsed since Start (a ReadPowerManagementTimer value), the
  wrap taken into account (once). }
function ReadPowerManagementTimer: LongWord;
function PowerManagementTicksSince(Start: LongWord): LongWord;

implementation

uses
  Runtime.Text,
  Firmware.Acpi,
  Kernel.Options,
  Hal.PortIo;

const
  OffsetTimerBlock = 76;
  OffsetTimerLength = 91;
  OffsetFlags = 112;
  OffsetExtendedTimerBlock = 208;
  FlagExtendedTimer = LongWord(1) shl 8;
  AddressSpaceSystemIo = 1;
  MoveReads = 100000;

var
  Port: Word = 0;
  Present: Boolean = False;
  CounterMask: LongWord = $FFFFFF;

function OptionTurnsOff: Boolean;
var
  Value: array[0..7] of Char;
begin
  Result := GetKernelOptionValue('pmtimer', @Value[0], SizeOf(Value)) and TextIsEqual(@Value[0], 'off');
end;

function FindPort(Fadt: PByte; Length: LongWord): Word;
var
  Address: QWord;
begin
  Result := 0;
  if (Length >= OffsetExtendedTimerBlock + 12) and (Fadt[OffsetExtendedTimerBlock] = AddressSpaceSystemIo) then
  begin
    Address := PQWord(Fadt + OffsetExtendedTimerBlock + 4)^;
    if (Address <> 0) and (Address <= $FFFF) then
      Exit(Word(Address));
  end;
  if (Length >= OffsetTimerLength + 1) and (Fadt[OffsetTimerLength] = 4) and
     (PLongWord(Fadt + OffsetTimerBlock)^ <= $FFFF) then
    Result := Word(PLongWord(Fadt + OffsetTimerBlock)^);
end;

function CounterMoves: Boolean;
var
  First: LongWord;
  Reads: LongWord;
begin
  First := ReadPowerManagementTimer;
  Reads := 0;
  while Reads < MoveReads do
  begin
    if ReadPowerManagementTimer <> First then
      Exit(True);
    Inc(Reads);
  end;
  Result := False;
end;

function InitializePowerManagementTimer: Boolean;
var
  Table: PAcpiTableHeader;
begin
  Result := False;
  Present := False;
  if OptionTurnsOff then
    Exit;
  Table := FindAcpiTable('FACP', 0);
  if Table = nil then
    Exit;
  Port := FindPort(PByte(Table), Table^.Length);
  if Port = 0 then
    Exit;
  if (Table^.Length >= OffsetFlags + 4) and ((PLongWord(PByte(Table) + OffsetFlags)^ and FlagExtendedTimer) <> 0) then
    CounterMask := $FFFFFFFF
  else
    CounterMask := $FFFFFF;
  { All ones from a port nobody answers is not a count. }
  if ReadPortLongWord(Port) = $FFFFFFFF then
    Exit;
  Present := CounterMoves;
  Result := Present;
end;

function PowerManagementTimerIsPresent: Boolean;
begin
  Result := Present;
end;

function ReadPowerManagementTimer: LongWord;
begin
  Result := ReadPortLongWord(Port) and CounterMask;
end;

function PowerManagementTicksSince(Start: LongWord): LongWord;
begin
  Result := LongWord((QWord(ReadPowerManagementTimer) + QWord(CounterMask) + 1 - Start) and CounterMask);
end;

end.
