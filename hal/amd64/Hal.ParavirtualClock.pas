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
  KVM's paravirtual clock (kvmclock): the clock a KVM host keeps for its
  guest, used where the time stamp counter is not said to be invariant
  (KVM does not say so unless asked, though it keeps the counters of a
  guest's processors together).

  The host fills a small record in guest memory, whose address the
  guest writes to MSR 4B564D01h: a version (odd while it changes), the
  counter value and the nanoseconds at the host's last update, and the
  scale from counter cycles to nanoseconds (a 32.32 fixed point factor
  after a shift). The time is those nanoseconds plus the cycles since,
  scaled. With the "stable" flag (CPUID 4000_0001h EAX bit 24, and bit 0
  of the record's flags) one record serves every processor, so only the
  boot processor's is set up; without it the clock is not used.

  Like the counter clock, it starts at zero, pauses before suspend to
  RAM and continues from there after waking (the record's address is
  written again: the processor was reset).

  The host may clear the stable flag later (after a suspend its
  processors' counters may no longer have been matched). The record is
  then still read from every processor, so each read is also kept from
  going below the latest time any processor read (LatestNanoseconds, a
  compare-and-exchange), as Linux does: the uptime never goes back.
}
unit Hal.ParavirtualClock;

{$mode objfpc}

interface

{ True if KVM offers a stable paravirtual clock; it is then started. }
function StartParavirtualClock: Boolean;
function ParavirtualClockIsRunning: Boolean;
{ Nanoseconds since the clock started, less the time paused. }
function ParavirtualClockNanoseconds: QWord;
procedure PauseParavirtualClock;
procedure ContinueParavirtualClock;

implementation

uses
  Runtime.Atomic,
  Kernel.Arch.Cpu,
  Memory.PhysicalPages,
  Memory.Layout;

type
  TParavirtualTimeRecord = packed record
    Version: LongWord;
    Padding0: LongWord;
    CounterTimestamp: QWord;
    SystemTime: QWord;
    CounterToSystemMultiplier: LongWord;
    CounterShift: ShortInt;
    Flags: Byte;
    Padding1: array[0..1] of Byte;
  end;
  PParavirtualTimeRecord = ^TParavirtualTimeRecord;

const
  HypervisorLeaf = $40000000;
  HypervisorFeaturesLeaf = $40000001;
  FeatureClockSource2 = LongWord(1) shl 3;
  FeatureStableClock = LongWord(1) shl 24;
  SystemTimeRegister = $4B564D01;
  SystemTimeEnable = 1;
  FlagCounterStable = 1;

var
  TimeRecord: PParavirtualTimeRecord = nil;
  RecordPhysical: QWord = 0;
  Running: Boolean = False;
  { The host's nanoseconds that are time zero here, and the time a pause
    began. }
  Origin: QWord = 0;
  PausedNanoseconds: QWord = 0;
  { The latest time read, kept only while the record is not stable. }
  LatestNanoseconds: PtrUInt = 0;

function HostIsKvm: Boolean;
var
  Registers: TCpuidResult;
begin
  ExecuteCpuid(1, 0, Registers);
  if (Registers.Ecx and (LongWord(1) shl 31)) = 0 then
    Exit(False);
  ExecuteCpuid(HypervisorLeaf, 0, Registers);
  { "KVMKVMKVM" }
  Result := (Registers.Ebx = $4B4D564B) and (Registers.Ecx = $564B4D56) and (Registers.Edx = $4D);
end;

{ Cycles times the record's factor: the high 64 bits of a 64 x 32 bit
  product shifted by 32. }
function ScaleCycles(Cycles: QWord; Multiplier: LongWord; Shift: ShortInt): QWord;
begin
  if Shift < 0 then
    Cycles := Cycles shr (-Shift)
  else
    Cycles := Cycles shl Shift;
  Result := (Cycles shr 32) * Multiplier + (((Cycles and $FFFFFFFF) * Multiplier) shr 32);
end;

function HostNanoseconds(out Stable: Boolean): QWord;
var
  Version: LongWord;
  Timestamp: QWord;
  SystemTime: QWord;
  Multiplier: LongWord;
  Shift: ShortInt;
  Counter: QWord;
begin
  repeat
    Version := PLongWord(@TimeRecord^.Version)^;
    FullMemoryBarrier;
    Timestamp := TimeRecord^.CounterTimestamp;
    SystemTime := TimeRecord^.SystemTime;
    Multiplier := TimeRecord^.CounterToSystemMultiplier;
    Shift := TimeRecord^.CounterShift;
    Stable := (TimeRecord^.Flags and FlagCounterStable) <> 0;
    Counter := ReadTimeStampCounter;
    FullMemoryBarrier;
  until ((Version and 1) = 0) and (PLongWord(@TimeRecord^.Version)^ = Version);
  if Counter > Timestamp then
    Result := SystemTime + ScaleCycles(Counter - Timestamp, Multiplier, Shift)
  else
    Result := SystemTime;
end;

procedure RegisterRecord;
begin
  WriteModelSpecificRegister(SystemTimeRegister, RecordPhysical or SystemTimeEnable);
end;

function StartParavirtualClock: Boolean;
var
  Registers: TCpuidResult;
  Stable: Boolean;
begin
  Result := False;
  if not HostIsKvm then
    Exit;
  ExecuteCpuid(HypervisorFeaturesLeaf, 0, Registers);
  if (Registers.Eax and FeatureClockSource2) = 0 then
    Exit;
  if (Registers.Eax and FeatureStableClock) = 0 then
    Exit;
  RecordPhysical := AllocateZeroedPhysicalPage(PageUsageGeneral);
  if RecordPhysical = 0 then
    Exit;
  TimeRecord := PParavirtualTimeRecord(PhysicalToVirtual(RecordPhysical));
  RegisterRecord;
  { The host fills the record before the next entry into the guest. }
  if (TimeRecord^.Flags and FlagCounterStable) = 0 then
  begin
    WriteModelSpecificRegister(SystemTimeRegister, 0);
    Exit;
  end;
  Origin := HostNanoseconds(Stable);
  Running := True;
  Result := True;
end;

function ParavirtualClockIsRunning: Boolean;
begin
  Result := Running;
end;

{ Candidate, or the latest time any processor read if that is later. }
function NotBelowLatest(Candidate: QWord): QWord;
var
  Latest: PtrUInt;
begin
  repeat
    Latest := AtomicLoad(LatestNanoseconds);
    if Candidate <= Latest then
      Exit(Latest);
  until AtomicCompareExchange(LatestNanoseconds, Candidate, Latest) = Latest;
  Result := Candidate;
end;

function ParavirtualClockNanoseconds: QWord;
var
  Now: QWord;
  Stable: Boolean;
begin
  Now := HostNanoseconds(Stable);
  if Now <= Origin then
    Result := PausedNanoseconds
  else
    Result := Now - Origin;
  if not Stable then
    Result := NotBelowLatest(Result);
end;

procedure PauseParavirtualClock;
begin
  PausedNanoseconds := ParavirtualClockNanoseconds;
end;

procedure ContinueParavirtualClock;
var
  Stable: Boolean;
begin
  RegisterRecord;
  Origin := HostNanoseconds(Stable) - PausedNanoseconds;
end;

end.
