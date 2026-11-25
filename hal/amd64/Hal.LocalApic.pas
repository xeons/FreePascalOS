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
  Local APIC driver.

  Each processor has a local APIC that receives interrupts, provides a
  per-processor timer and sends inter-processor interrupts. It is used in
  one of two modes:

    xAPIC   Registers are memory mapped (normally at 0xFEE00000).
    x2APIC  Registers are model specific registers starting at 0x800.

  The firmware may hand over in either mode, so register access goes
  through ReadApicRegister/WriteApicRegister which handle both.
}
unit Hal.LocalApic;

{$mode objfpc}

interface

procedure InitializeLocalApic(SpuriousVector: Byte);

function LocalApicId: LongWord;
function LocalApicUsesX2ApicMode: Boolean;

procedure LocalApicEndOfInterrupt;
{ The vector being serviced now (the highest in service), -1 if none. }
function LocalApicVectorInService: LongInt;
procedure LocalApicSendSelfInterrupt(Vector: Byte);

{ Inter-processor interrupts, addressed by local APIC id. }
procedure LocalApicSendInterrupt(DestinationId: LongWord; Vector: Byte);
procedure LocalApicSendInit(DestinationId: LongWord);
{ STARTUP: the processor starts in real mode at page StartupPage
  (physical address StartupPage * 4096, below 1 MiB). }
procedure LocalApicSendStartup(DestinationId: LongWord; StartupPage: Byte);
{ A non-maskable interrupt to every processor but this one. }
procedure LocalApicSendNmiToOthers;

{ Measuring the timer's speed: StartLocalApicTimerCountdown starts it
  counting down (masked, at the divider the clock uses), and
  StopLocalApicTimerCountdown stops it and returns how many ticks it
  counted meanwhile. }
procedure StartLocalApicTimerCountdown;
function StopLocalApicTimerCountdown: LongWord;

{ Puts the timer in one-shot mode on Vector, with its first interrupt
  right away; SetLocalApicTimerCount then sets when the next one comes
  (after Count timer ticks, counted again from now). }
procedure StartLocalApicOneShotTimer(Vector: Byte);
procedure SetLocalApicTimerCount(Count: LongWord);
procedure StopLocalApicTimer;

implementation

uses
  Memory.Layout,
  Kernel.Arch.Cpu;

const
  MsrApicBase = $1B;
  ApicBaseGlobalEnable = QWord(1) shl 11;
  ApicBaseX2ApicEnable = QWord(1) shl 10;
  ApicBaseAddressMask = QWord($000FFFFFFFFFF000);

  X2ApicMsrBase = $800;

  { Register offsets in the xAPIC memory mapped layout. }
  RegisterId = $020;
  RegisterTaskPriority = $080;
  RegisterEndOfInterrupt = $0B0;
  RegisterInServiceBase = $100;
  RegisterSpuriousVector = $0F0;
  RegisterInterruptCommandLow = $300;
  RegisterInterruptCommandHigh = $310;
  RegisterLvtTimer = $320;
  RegisterLvtLint0 = $350;
  RegisterLvtLint1 = $360;
  RegisterLvtError = $370;
  RegisterTimerInitialCount = $380;
  RegisterTimerCurrentCount = $390;
  RegisterTimerDivide = $3E0;

  SpuriousVectorApicEnable = $100;
  LvtMasked = LongWord(1) shl 16;
  TimerDivideBy16 = $3;
  CountdownStart = High(LongWord);

  InterruptCommandDeliveryPending = LongWord(1) shl 12;
  InterruptCommandShorthandSelf = LongWord(1) shl 18;
  InterruptCommandShorthandOthers = LongWord(3) shl 18;
  InterruptCommandModeNmi = LongWord(4) shl 8;
  InterruptCommandModeInit = LongWord(5) shl 8;
  InterruptCommandModeStartup = LongWord(6) shl 8;
  InterruptCommandLevelAssert = LongWord(1) shl 14;

var
  RegisterBase: PtrUInt;
  UsesX2ApicMode: Boolean;

function LocalApicUsesX2ApicMode: Boolean;
begin
  Result := UsesX2ApicMode;
end;

function ReadApicRegister(Offset: LongWord): LongWord;
begin
  if UsesX2ApicMode then
    Result := LongWord(ReadModelSpecificRegister(X2ApicMsrBase + (Offset shr 4)))
  else
    Result := PLongWord(RegisterBase + Offset)^;
end;

procedure WriteApicRegister(Offset: LongWord; Value: LongWord);
begin
  if UsesX2ApicMode then
    WriteModelSpecificRegister(X2ApicMsrBase + (Offset shr 4), Value)
  else
    PLongWord(RegisterBase + Offset)^ := Value;
end;

procedure InitializeLocalApic(SpuriousVector: Byte);
var
  ApicBase: QWord;
begin
  ApicBase := ReadModelSpecificRegister(MsrApicBase);
  UsesX2ApicMode := (ApicBase and ApicBaseX2ApicEnable) <> 0;
  RegisterBase := PtrUInt(PhysicalToVirtual(ApicBase and ApicBaseAddressMask));

  if (ApicBase and ApicBaseGlobalEnable) = 0 then
    WriteModelSpecificRegister(MsrApicBase, ApicBase or ApicBaseGlobalEnable);

  { Priority filtering is done through CR8, which aliases this register. }
  WriteApicRegister(RegisterTaskPriority, 0);

  WriteApicRegister(RegisterLvtTimer, LvtMasked);
  WriteApicRegister(RegisterLvtLint0, LvtMasked);
  WriteApicRegister(RegisterLvtLint1, LvtMasked);
  WriteApicRegister(RegisterLvtError, LvtMasked);

  WriteApicRegister(RegisterSpuriousVector, SpuriousVectorApicEnable or SpuriousVector);

  { Clear anything left in service by the firmware. }
  WriteApicRegister(RegisterEndOfInterrupt, 0);
end;

function LocalApicId: LongWord;
begin
  if UsesX2ApicMode then
    Result := ReadApicRegister(RegisterId)
  else
    Result := ReadApicRegister(RegisterId) shr 24;
end;

function LocalApicVectorInService: LongInt;
var
  Word_: Integer;
  Bits: LongWord;
  Bit: Integer;
begin
  for Word_ := 7 downto 0 do
  begin
    Bits := ReadApicRegister(RegisterInServiceBase + LongWord(Word_) * $10);
    if Bits <> 0 then
    begin
      for Bit := 31 downto 0 do
        if (Bits and (LongWord(1) shl Bit)) <> 0 then
          Exit(Word_ * 32 + Bit);
    end;
  end;
  Result := -1;
end;

procedure LocalApicEndOfInterrupt;
begin
  WriteApicRegister(RegisterEndOfInterrupt, 0);
end;

procedure LocalApicSendSelfInterrupt(Vector: Byte);
var
  WereEnabled: Boolean;
begin
  if UsesX2ApicMode then
  begin
    { In x2APIC mode the command register is a single 64-bit MSR. }
    WriteModelSpecificRegister(X2ApicMsrBase + (RegisterInterruptCommandLow shr 4),
      InterruptCommandShorthandSelf or Vector);
    Exit;
  end;

  { Interrupts off for the same reason as in SendInterruptCommand. }
  WereEnabled := SaveAndDisableInterrupts;
  while (ReadApicRegister(RegisterInterruptCommandLow) and InterruptCommandDeliveryPending) <> 0 do
    CpuRelax;
  WriteApicRegister(RegisterInterruptCommandHigh, 0);
  WriteApicRegister(RegisterInterruptCommandLow, InterruptCommandShorthandSelf or Vector);
  RestoreInterrupts(WereEnabled);
end;

{ Writes the interrupt command register: Command in the low half and
  the destination in the high half.

  In xAPIC mode these are two registers, and writing the low one sends
  the interrupt to whatever destination the high one holds at that
  moment. An interrupt arriving between the two writes may send an
  interrupt of its own (the clock interrupt asks for a dispatch
  interrupt on this processor, a woken thread for one on another), which
  rewrites the high register: the interrupted send then goes to the
  wrong processor. A TLB shootdown request sent that way never reaches
  its processor - and merges with the one already pending at the
  processor it does reach - so its sender waits for an acknowledgement
  forever, and every processor that then wants to shoot down spins
  behind it. So the wait for the previous command and both writes
  happen with interrupts disabled. In x2APIC mode the register is one
  MSR, written by one instruction. }
procedure SendInterruptCommand(DestinationId: LongWord; Command: LongWord);
var
  WereEnabled: Boolean;
begin
  if UsesX2ApicMode then
  begin
    WriteModelSpecificRegister(X2ApicMsrBase + (RegisterInterruptCommandLow shr 4),
      (QWord(DestinationId) shl 32) or Command);
    Exit;
  end;
  WereEnabled := SaveAndDisableInterrupts;
  while (ReadApicRegister(RegisterInterruptCommandLow) and InterruptCommandDeliveryPending) <> 0 do
    CpuRelax;
  WriteApicRegister(RegisterInterruptCommandHigh, DestinationId shl 24);
  WriteApicRegister(RegisterInterruptCommandLow, Command);
  RestoreInterrupts(WereEnabled);
end;

procedure LocalApicSendInterrupt(DestinationId: LongWord; Vector: Byte);
begin
  SendInterruptCommand(DestinationId, Vector);
end;

procedure LocalApicSendInit(DestinationId: LongWord);
begin
  SendInterruptCommand(DestinationId, InterruptCommandModeInit or InterruptCommandLevelAssert);
end;

procedure LocalApicSendStartup(DestinationId: LongWord; StartupPage: Byte);
begin
  SendInterruptCommand(DestinationId, InterruptCommandModeStartup or
    InterruptCommandLevelAssert or StartupPage);
end;

procedure LocalApicSendNmiToOthers;
begin
  SendInterruptCommand(0, InterruptCommandShorthandOthers or InterruptCommandModeNmi or
    InterruptCommandLevelAssert);
end;

procedure StartLocalApicTimerCountdown;
begin
  WriteApicRegister(RegisterTimerDivide, TimerDivideBy16);
  WriteApicRegister(RegisterLvtTimer, LvtMasked);
  WriteApicRegister(RegisterTimerInitialCount, CountdownStart);
end;

function StopLocalApicTimerCountdown: LongWord;
begin
  Result := CountdownStart - ReadApicRegister(RegisterTimerCurrentCount);
  WriteApicRegister(RegisterTimerInitialCount, 0);
end;

procedure StartLocalApicOneShotTimer(Vector: Byte);
begin
  WriteApicRegister(RegisterTimerDivide, TimerDivideBy16);
  { One-shot is the timer mode 0, so the entry is only the vector. }
  WriteApicRegister(RegisterLvtTimer, Vector);
  WriteApicRegister(RegisterTimerInitialCount, 1);
end;

procedure SetLocalApicTimerCount(Count: LongWord);
begin
  { Writing the initial count starts the countdown again; 0 would stop
    the timer instead. }
  if Count = 0 then
    Count := 1;
  WriteApicRegister(RegisterTimerInitialCount, Count);
end;

procedure StopLocalApicTimer;
begin
  WriteApicRegister(RegisterLvtTimer, LvtMasked);
  WriteApicRegister(RegisterTimerInitialCount, 0);
end;

end.
