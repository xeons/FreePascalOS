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
  The watchdog of the Intel 6300ESB I/O controller hub (PCI 8086:25AB),
  which QEMU emulates (-device i6300esb): a way to test the watchdog
  mechanism (Io.Watchdog) on any machine.

  Configuration space:
    60h (16 bits)  configuration: bits 0-1 the interrupt of the first
                   stage (3: none), bit 2 the clock (0: about 1 kHz),
                   bit 5 the reset output (0: on)
    68h (8 bits)   lock: bit 1 enable, bit 0 lock until reset
  Memory (BAR 0):
    00h  the first stage's count     04h  the second stage's count
    0Ch  (16 bits) reload: bit 8 starts the counts again, bit 9 says the
         watchdog ran out (written 1 to clear)
  The counts and the reload register can only be written right after the
  unlock sequence 80h, 86h to the reload register. The two stages run one
  after the other, at about 1 kHz; each gets half the timeout (count =
  seconds x 512), and the end of the second resets the machine. Not armed
  by default.
}
unit Drivers.I6300EsbWatchdog;

{$mode objfpc}

interface

function InitializeI6300EsbWatchdog: Boolean;

implementation

uses
  Runtime.Atomic,
  Kernel.Arch.Cpu,
  Hal.Platform,
  Memory.DeviceMapping,
  Io.Pci,
  Io.Watchdog,
  Debug.Output;

const
  VendorIntel = $8086;
  DeviceI6300EsbWatchdog = $25AB;

  ConfigurationRegister = $60;
  LockRegister = $68;
  ConfigurationNoInterruptResetOn = $0003;
  LockEnable = $02;

  FirstStageCount = $00;
  SecondStageCount = $04;
  ReloadRegister = $0C;
  ReloadStart = $0100;
  ReloadTimedOut = $0200;
  UnlockFirst = $80;
  UnlockSecond = $86;

  CountsPerSecondPerStage = 512;
  CountMask = $FFFFF;
  MaximumSeconds = CountMask div CountsPerSecondPerStage;

var
  Pci: PPciDevice;
  Registers: PByte;
  WasTimedOutAtStart: Boolean;

procedure Unlock;
begin
  FullMemoryBarrier;
  PWord(Registers + ReloadRegister)^ := UnlockFirst;
  PWord(Registers + ReloadRegister)^ := UnlockSecond;
end;

procedure WriteCount(Offset: LongWord; Value: LongWord);
begin
  Unlock;
  PLongWord(Registers + Offset)^ := Value;
end;

procedure Reload;
begin
  Unlock;
  PWord(Registers + ReloadRegister)^ := ReloadStart;
  FullMemoryBarrier;
end;

procedure StartWatchdog(Context: Pointer; Seconds: LongWord);
var
  Count: LongWord;
begin
  Count := (Seconds * CountsPerSecondPerStage) and CountMask;
  WriteCount(FirstStageCount, Count);
  WriteCount(SecondStageCount, Count);
  Reload;
  PciWrite8(Pci, LockRegister, LockEnable);
end;

procedure PetWatchdog(Context: Pointer);
begin
  Reload;
end;

procedure StopWatchdog(Context: Pointer);
begin
  Reload;
  PciWrite8(Pci, LockRegister, 0);
end;

procedure ResetNow(Context: Pointer);
const
  WaitNanoseconds = QWord(3) * 1000 * 1000 * 1000;
var
  Deadline: QWord;
begin
  { The shortest timeout (both stages about half a second). }
  StartWatchdog(Context, 1);
  Deadline := HalClockNanoseconds + WaitNanoseconds;
  while HalClockNanoseconds < Deadline do
    CpuRelax;
end;

function FindWatchdogFunction: PPciDevice;
var
  Index: Integer;
  Candidate: PPciDevice;
begin
  for Index := 0 to PciDeviceCount - 1 do
  begin
    Candidate := PciDeviceAt(Index);
    if (Candidate^.VendorId = VendorIntel) and (Candidate^.DeviceId = DeviceI6300EsbWatchdog) then
      Exit(Candidate);
  end;
  Result := nil;
end;

function InitializeI6300EsbWatchdog: Boolean;
var
  Bar: TPciBar;
  Device: TWatchdogDevice;
begin
  Result := False;
  Pci := FindWatchdogFunction;
  if (Pci = nil) or not PciReadBar(Pci, 0, Bar) or Bar.IsIoPort or (Bar.PhysicalAddress = 0) then
    Exit;
  PciEnableDevice(Pci, False);
  Registers := PByte(MapDeviceMemory(Bar.PhysicalAddress, Bar.SizeInBytes));
  if Registers = nil then
    Exit;

  { As Linux does: no first stage interrupt, the reset output on, the
    timer stopped; then the "ran out" flag cleared. }
  PciWrite16(Pci, ConfigurationRegister, ConfigurationNoInterruptResetOn);
  PciWrite8(Pci, LockRegister, 0);
  Unlock;
  WasTimedOutAtStart := (PWord(Registers + ReloadRegister)^ and ReloadTimedOut) <> 0;
  Unlock;
  PWord(Registers + ReloadRegister)^ := ReloadTimedOut or ReloadStart;

  Device.Routines.Start := @StartWatchdog;
  Device.Routines.Pet := @PetWatchdog;
  Device.Routines.Stop := @StopWatchdog;
  Device.Routines.ResetNow := @ResetNow;
  Device.Context := nil;
  Device.Name := 'Intel 6300ESB watchdog';
  Device.MaximumSeconds := MaximumSeconds;
  Device.ArmByDefault := False;
  Device.DefaultSeconds := 30;
  RegisterWatchdog(Device);

  DebugBeginMessage;
  DebugWriteTag('watchdog');
  DebugWrite('Intel 6300ESB watchdog at ');
  DebugWriteHex(Bar.PhysicalAddress, 8);
  if WasTimedOutAtStart then
    DebugWrite('; it reset the machine last time');
  DebugWriteLine('');
  DebugEndMessage;
  Result := True;
end;

end.
