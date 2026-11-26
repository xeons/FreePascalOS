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
  The high precision event timer (HPET): its main counter and its
  comparators.

  The ACPI HPET table (Hal.HpetTable) says where the 1 KiB register
  block is; it is mapped uncached (Memory.DeviceMapping). The general
  capabilities register gives the counter's period in femtoseconds
  (Hal.HpetMath), the number of comparators, whether the counter is 64
  bits wide and whether legacy replacement is possible. The counter is
  enabled at start (general configuration bit 0) with every comparator's
  interrupt off and legacy replacement off, and from then on runs on,
  whatever the processors do: in deep idle states, at any clock rate.

  The counter is read with 32-bit accesses: a 64-bit counter as high,
  low, high again until the two highs agree (some chipsets split a
  64-bit read into two anyway), a 32-bit one as its low half, extended
  to 64 bits by counting its wraps (Hal.HpetMath, the last value kept
  with a compare-and-exchange so that any processor may read it).

  A comparator is always used in 32-bit mode (Tn_32MODE_CNF where it is
  64 bits wide, as Linux does): it matches the counter's low half, which
  bounds a wait to 2^31 ticks (21 s at 100 MHz; the kernel asks for 4 s
  at most). Its interrupt goes where Hal.HpetInterrupts routes it: an
  I/O APIC input its route capability allows, a message (FSB delivery),
  or with legacy replacement comparator 0 to IRQ 0 and comparator 1 to
  IRQ 8.

  Suspend to RAM turns the chipset off, which forgets the general
  configuration and every comparator: SaveHpetState keeps them before
  and RestoreHpetState writes them back after waking (the counter starts
  again from where it is; the clocks continue on their own, see
  Hal.HpetClock).
}
unit Hal.Hpet;

{$mode objfpc}

interface

uses
  Hal.HpetTable;

const
  { Comparator configuration bits. }
  ComparatorLevelTriggered = LongWord(1) shl 1;
  ComparatorInterruptEnable = LongWord(1) shl 2;
  ComparatorPeriodic = LongWord(1) shl 3;
  ComparatorPeriodicCapable = LongWord(1) shl 4;
  Comparator64BitCapable = LongWord(1) shl 5;
  ComparatorValueSet = LongWord(1) shl 6;
  Comparator32BitMode = LongWord(1) shl 8;
  ComparatorRouteShift = 9;
  ComparatorRouteMask = LongWord($1F) shl ComparatorRouteShift;
  ComparatorMessageEnable = LongWord(1) shl 14;
  ComparatorMessageCapable = LongWord(1) shl 15;

  MaximumHpetComparators = 32;

{ Finds the HPET in the ACPI tables, maps it and starts its counter.
  False if there is none or it does not work (kernel option hpet=off
  ignores it). }
function InitializeHpet: Boolean;
function HpetIsPresent: Boolean;
{ What the table said. }
procedure GetHpetTableInformation(out Information: THpetTableInformation);

function HpetPeriodFemtoseconds: LongWord;
function HpetFrequencyHertz: QWord;
function HpetComparatorTotal: LongWord;
function HpetCounterIs64Bit: Boolean;
function HpetIsLegacyCapable: Boolean;

{ The counter, extended to 64 bits. Any processor. }
function ReadHpetCounter: QWord;
{ Its low half, as a 32-bit comparator sees it. }
function ReadHpetCounterLow: LongWord;
{ Busy-waits Nanoseconds by the counter. }
procedure HpetBusyWait(Nanoseconds: QWord);
{ After waking (or a pause): the 32-bit extension starts again from
  what the counter reads now. }
procedure ResetHpetCounterExtension;

{ A comparator's configuration and capabilities register: low half
  (configuration, and the capability bits above) and the I/O APIC
  inputs it may be routed to (bit n: input n). }
function HpetComparatorConfiguration(Index: LongWord): LongWord;
function HpetComparatorRouteCapabilities(Index: LongWord): LongWord;
procedure WriteHpetComparatorConfiguration(Index: LongWord; Value: LongWord);
{ Writes the comparator's (low half of the) value register. }
procedure WriteHpetComparator(Index: LongWord; Value: LongWord);
function ReadHpetComparator(Index: LongWord): LongWord;
{ The message a comparator with FSB delivery writes, and where. }
procedure WriteHpetMessageRoute(Index: LongWord; Address: LongWord; Data: LongWord);
{ General configuration bit 1: comparator 0 drives IRQ 0, 1 IRQ 8. }
procedure SetHpetLegacyReplacement(On: Boolean);
function HpetLegacyReplacementIsOn: Boolean;
{ Clears a level triggered comparator's interrupt status. }
procedure ClearHpetInterruptStatus(Index: LongWord);

procedure SaveHpetState;
procedure RestoreHpetState;

implementation

uses
  Runtime.Atomic,
  Runtime.Text,
  Firmware.Acpi,
  Memory.DeviceMapping,
  Kernel.Arch.Cpu,
  Kernel.Options,
  Hal.HpetMath;

const
  RegisterBlockSize = $1000;
  CapabilitiesLow = $000;
  CapabilitiesHigh = $004;
  GeneralConfiguration = $010;
  InterruptStatus = $020;
  MainCounterLow = $0F0;
  MainCounterHigh = $0F4;
  ComparatorBlockBase = $100;
  ComparatorStride = $20;
  ComparatorConfigurationOffset = $00;
  ComparatorCapabilitiesOffset = $04;
  ComparatorValueOffset = $08;
  MessageDataOffset = $10;
  MessageAddressOffset = $14;

  GeneralEnable = LongWord(1) shl 0;
  GeneralLegacyReplacement = LongWord(1) shl 1;

  { Reads of a counter that must have moved by then (any valid period
    advances it within 100 ns; a read takes longer). }
  CounterMoveReads = 100000;

type
  TSavedComparator = record
    Configuration: LongWord;
    Value: LongWord;
    MessageData: LongWord;
    MessageAddress: LongWord;
  end;

var
  Registers: PByte = nil;
  Present: Boolean = False;
  TableInformation: THpetTableInformation;
  Period: LongWord = 0;
  ComparatorCount: LongWord = 0;
  Counter64: Boolean = False;
  LegacyCapable: Boolean = False;
  { The last extended reading of a 32-bit counter. }
  ExtendedCounter: PtrUInt = 0;
  SavedGeneral: LongWord = 0;
  SavedComparators: array[0..MaximumHpetComparators - 1] of TSavedComparator;

function ReadRegister(Offset: LongWord): LongWord;
begin
  Result := PLongWord(Registers + Offset)^;
end;

procedure WriteRegister(Offset: LongWord; Value: LongWord);
begin
  PLongWord(Registers + Offset)^ := Value;
end;

function ComparatorOffset(Index: LongWord; Offset: LongWord): LongWord;
begin
  Result := ComparatorBlockBase + Index * ComparatorStride + Offset;
end;

function OptionTurnsHpetOff: Boolean;
var
  Value: array[0..7] of Char;
begin
  Result := GetKernelOptionValue('hpet', @Value[0], SizeOf(Value)) and TextIsEqual(@Value[0], 'off');
end;

function ReadRawCounter: QWord;
var
  High: LongWord;
  Low: LongWord;
begin
  if not Counter64 then
    Exit(ReadRegister(MainCounterLow));
  repeat
    High := ReadRegister(MainCounterHigh);
    Low := ReadRegister(MainCounterLow);
  until ReadRegister(MainCounterHigh) = High;
  Result := (QWord(High) shl 32) or Low;
end;

function CounterMoves: Boolean;
var
  First: LongWord;
  Reads: LongWord;
begin
  First := ReadRegister(MainCounterLow);
  Reads := 0;
  while Reads < CounterMoveReads do
  begin
    if ReadRegister(MainCounterLow) <> First then
      Exit(True);
    Inc(Reads);
  end;
  Result := False;
end;

{ Every comparator quiet: interrupts off, not periodic, no messages. }
procedure QuietComparators;
var
  Index: LongWord;
  Value: LongWord;
begin
  Index := 0;
  while Index < ComparatorCount do
  begin
    Value := ReadRegister(ComparatorOffset(Index, ComparatorConfigurationOffset));
    Value := Value and not (ComparatorInterruptEnable or ComparatorPeriodic or ComparatorMessageEnable or
      ComparatorLevelTriggered or ComparatorValueSet);
    WriteRegister(ComparatorOffset(Index, ComparatorConfigurationOffset), Value);
    Inc(Index);
  end;
end;

function InitializeHpet: Boolean;
var
  Table: PAcpiTableHeader;
  CapabilityWord: QWord;
  General: LongWord;
begin
  Result := False;
  Present := False;
  if OptionTurnsHpetOff then
    Exit;
  Table := FindAcpiTable('HPET', 0);
  if Table = nil then
    Exit;
  if not ParseHpetTable(PByte(Table), Table^.Length, TableInformation) then
    Exit;
  Registers := PByte(MapDeviceMemory(TableInformation.BaseAddress, RegisterBlockSize));
  if Registers = nil then
    Exit;
  CapabilityWord := ReadRegister(CapabilitiesLow) or (QWord(ReadRegister(CapabilitiesHigh)) shl 32);
  Period := HpetPeriodOf(CapabilityWord);
  { All ones: nothing answers at that address. }
  if (CapabilityWord = High(QWord)) or not HpetPeriodIsValid(Period) then
    Exit;
  ComparatorCount := HpetComparatorCountOf(CapabilityWord);
  if ComparatorCount > MaximumHpetComparators then
    ComparatorCount := MaximumHpetComparators;
  Counter64 := HpetCounterIs64BitOf(CapabilityWord);
  LegacyCapable := HpetLegacyCapableOf(CapabilityWord);
  QuietComparators;
  General := ReadRegister(GeneralConfiguration);
  General := (General and not GeneralLegacyReplacement) or GeneralEnable;
  WriteRegister(GeneralConfiguration, General);
  if not CounterMoves then
    Exit;
  ResetHpetCounterExtension;
  Present := True;
  Result := True;
end;

function HpetIsPresent: Boolean;
begin
  Result := Present;
end;

procedure GetHpetTableInformation(out Information: THpetTableInformation);
begin
  Information := TableInformation;
end;

function HpetPeriodFemtoseconds: LongWord;
begin
  Result := Period;
end;

function HpetFrequencyHertz: QWord;
begin
  Result := HpetFrequencyOf(Period);
end;

function HpetComparatorTotal: LongWord;
begin
  Result := ComparatorCount;
end;

function HpetCounterIs64Bit: Boolean;
begin
  Result := Counter64;
end;

function HpetIsLegacyCapable: Boolean;
begin
  Result := LegacyCapable;
end;

procedure ResetHpetCounterExtension;
begin
  if Counter64 then
    Exit;
  AtomicStore(ExtendedCounter, ReadRegister(MainCounterLow));
end;

function ReadHpetCounter: QWord;
var
  Previous: PtrUInt;
begin
  if not Present then
    Exit(0);
  if Counter64 then
    Exit(ReadRawCounter);
  { The last value is read first, then the counter: the reading is
    never older than the value it extends. }
  Previous := AtomicLoad(ExtendedCounter);
  Result := ExtendCounterReading(Previous, ReadRegister(MainCounterLow));
  if Result > Previous then
    AtomicCompareExchange(ExtendedCounter, PtrUInt(Result), Previous);
end;

function ReadHpetCounterLow: LongWord;
begin
  Result := ReadRegister(MainCounterLow);
end;

procedure HpetBusyWait(Nanoseconds: QWord);
var
  Start: QWord;
  Ticks: QWord;
begin
  if not Present then
    Exit;
  Ticks := HpetNanosecondsToTicks(Nanoseconds, Period);
  Start := ReadHpetCounter;
  while ReadHpetCounter - Start < Ticks do
    CpuRelax;
end;

function HpetComparatorConfiguration(Index: LongWord): LongWord;
begin
  Result := ReadRegister(ComparatorOffset(Index, ComparatorConfigurationOffset));
end;

function HpetComparatorRouteCapabilities(Index: LongWord): LongWord;
begin
  Result := ReadRegister(ComparatorOffset(Index, ComparatorCapabilitiesOffset));
end;

procedure WriteHpetComparatorConfiguration(Index: LongWord; Value: LongWord);
begin
  WriteRegister(ComparatorOffset(Index, ComparatorConfigurationOffset), Value);
end;

procedure WriteHpetComparator(Index: LongWord; Value: LongWord);
begin
  WriteRegister(ComparatorOffset(Index, ComparatorValueOffset), Value);
end;

function ReadHpetComparator(Index: LongWord): LongWord;
begin
  Result := ReadRegister(ComparatorOffset(Index, ComparatorValueOffset));
end;

procedure WriteHpetMessageRoute(Index: LongWord; Address: LongWord; Data: LongWord);
begin
  WriteRegister(ComparatorOffset(Index, MessageAddressOffset), Address);
  WriteRegister(ComparatorOffset(Index, MessageDataOffset), Data);
end;

procedure SetHpetLegacyReplacement(On: Boolean);
var
  General: LongWord;
begin
  General := ReadRegister(GeneralConfiguration);
  if On then
    General := General or GeneralLegacyReplacement
  else
    General := General and not GeneralLegacyReplacement;
  WriteRegister(GeneralConfiguration, General);
end;

function HpetLegacyReplacementIsOn: Boolean;
begin
  Result := Present and ((ReadRegister(GeneralConfiguration) and GeneralLegacyReplacement) <> 0);
end;

procedure ClearHpetInterruptStatus(Index: LongWord);
begin
  WriteRegister(InterruptStatus, LongWord(1) shl Index);
end;

procedure SaveHpetState;
var
  Index: LongWord;
begin
  if not Present then
    Exit;
  SavedGeneral := ReadRegister(GeneralConfiguration);
  Index := 0;
  while Index < ComparatorCount do
  begin
    SavedComparators[Index].Configuration := ReadRegister(ComparatorOffset(Index, ComparatorConfigurationOffset));
    SavedComparators[Index].Value := ReadRegister(ComparatorOffset(Index, ComparatorValueOffset));
    SavedComparators[Index].MessageData := ReadRegister(ComparatorOffset(Index, MessageDataOffset));
    SavedComparators[Index].MessageAddress := ReadRegister(ComparatorOffset(Index, MessageAddressOffset));
    Inc(Index);
  end;
end;

procedure RestoreHpetState;
var
  Index: LongWord;
  Configuration: LongWord;
begin
  if not Present then
    Exit;
  { Halted while the comparators are written, as the specification
    asks for changes to a running timer's mode. }
  WriteRegister(GeneralConfiguration, SavedGeneral and not GeneralEnable);
  Index := 0;
  while Index < ComparatorCount do
  begin
    Configuration := SavedComparators[Index].Configuration and not (ComparatorValueSet or ComparatorPeriodic);
    if (Configuration and ComparatorMessageEnable) <> 0 then
      WriteHpetMessageRoute(Index, SavedComparators[Index].MessageAddress, SavedComparators[Index].MessageData);
    WriteRegister(ComparatorOffset(Index, ComparatorConfigurationOffset), Configuration);
    WriteRegister(ComparatorOffset(Index, ComparatorValueOffset), SavedComparators[Index].Value);
    Inc(Index);
  end;
  WriteRegister(GeneralConfiguration, SavedGeneral or GeneralEnable);
  ResetHpetCounterExtension;
end;

end.
