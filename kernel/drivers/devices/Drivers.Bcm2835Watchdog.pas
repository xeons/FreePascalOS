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
  The Raspberry Pi's watchdog: the power manager (PM) block of the
  BCM2835 family (BCM2837 on the Pi 3, BCM2711 on the Pi 4), at
  peripheral base + 100000h (FE100000h on the Pi 4).

    1Ch  PM_RSTC  reset control: bits 4-5 the reset kind (20h: full
                  reset when the watchdog runs out), 102h stops it
    20h  PM_RSTS  reset status (the boot partition)
    24h  PM_WDOG  the count, in 1/65536 s, 20 bits: at most 15 s

  Every write carries the password 5Ah in the top byte. Arming or petting
  writes the count and then the reset kind; resetting at once is a count
  of 10 ticks.

  The community UEFI firmware's ACPI tables have no device for it, so it
  is found from the VideoCore mailbox (ACPI BCM2849), which sits at
  peripheral base + B880h on the same chips: the board is a Raspberry Pi,
  and the revision word (Drivers.RaspberryPiBoard) names a BCM2837 or a
  BCM2711. On those it is armed by default (Io.Watchdog), for 15 s.

  After a native boot the device tree names the block itself: the
  Raspberry Pi 5's "brcm,bcm2712-pm" (at 10_7D20_0000), or a Pi 3 or 4
  tree's "brcm,bcm2835-pm"/"brcm,bcm2835-pm-wdt"; the same registers,
  armed by default too.
}
unit Drivers.Bcm2835Watchdog;

{$mode objfpc}

interface

{ Registers the watchdog if this is a Raspberry Pi 3, 4 or 5. }
function InitializeBcm2835Watchdog: Boolean;

implementation

uses
  Runtime.Atomic,
  Kernel.Arch.Cpu,
  Hal.Platform,
  Memory.DeviceMapping,
  Io.PlatformDevices,
  Drivers.VideoCoreMailbox,
  Io.Watchdog,
  Debug.Output;

const
  MailboxOffset = $B880;
  PowerManagerOffset = $100000;
  RegisterSpan = $1000;

  ResetControl = $1C;
  ResetStatus = $20;
  WatchdogCount = $24;

  Password = LongWord($5A000000);
  CountMask = LongWord($000FFFFF);
  ResetKindClear = LongWord($FFFFFFCF);
  ResetKindFullReset = LongWord($00000020);
  ResetStop = LongWord($00000102);
  TicksPerSecond = 65536;
  ImmediateTicks = 10;
  MaximumSeconds = CountMask div TicksPerSecond;

  NewStyleRevision = LongWord(1) shl 23;
  ProcessorBcm2837 = 2;
  ProcessorBcm2711 = 3;

var
  Registers: PByte;
  { The count each pet starts again from. }
  ArmedTicks: LongWord;

function ReadRegister(Offset: LongWord): LongWord;
begin
  Result := PLongWord(Registers + Offset)^;
  FullMemoryBarrier;
end;

procedure WriteRegister(Offset: LongWord; Value: LongWord);
begin
  FullMemoryBarrier;
  PLongWord(Registers + Offset)^ := Value;
end;

procedure ArmForTicks(Ticks: LongWord);
var
  Control: LongWord;
begin
  WriteRegister(WatchdogCount, Password or (Ticks and CountMask));
  Control := ReadRegister(ResetControl);
  WriteRegister(ResetControl, Password or (Control and ResetKindClear) or ResetKindFullReset);
end;

procedure StartWatchdog(Context: Pointer; Seconds: LongWord);
begin
  ArmedTicks := Seconds * TicksPerSecond;
  ArmForTicks(ArmedTicks);
end;

procedure PetWatchdog(Context: Pointer);
begin
  ArmForTicks(ArmedTicks);
end;

procedure StopWatchdog(Context: Pointer);
begin
  WriteRegister(ResetControl, Password or ResetStop);
end;

procedure ResetNow(Context: Pointer);
const
  WaitNanoseconds = 100 * 1000 * 1000;
var
  Deadline: QWord;
begin
  ArmForTicks(ImmediateTicks);
  { 10 ticks are 150 microseconds. }
  Deadline := HalClockNanoseconds + WaitNanoseconds;
  while HalClockNanoseconds < Deadline do
    CpuRelax;
end;

function IsSupportedBoard: Boolean;
var
  Revision: LongWord;
  Processor: LongWord;
begin
  Result := False;
  if not QueryFirmwareWord(FirmwareTagBoardRevision, Revision) or ((Revision and NewStyleRevision) = 0) then
    Exit;
  Processor := (Revision shr 12) and $F;
  Result := (Processor = ProcessorBcm2837) or (Processor = ProcessorBcm2711);
end;

procedure RegisterDevice(Physical: QWord; Name: PChar; Source: PChar);
var
  Device: TWatchdogDevice;
begin
  Device.Routines.Start := @StartWatchdog;
  Device.Routines.Pet := @PetWatchdog;
  Device.Routines.Stop := @StopWatchdog;
  Device.Routines.ResetNow := @ResetNow;
  Device.Context := nil;
  Device.Name := Name;
  Device.MaximumSeconds := MaximumSeconds;
  Device.ArmByDefault := True;
  Device.DefaultSeconds := MaximumSeconds;
  RegisterWatchdog(Device);

  DebugBeginMessage;
  DebugWriteTag('watchdog');
  DebugWrite(Name);
  DebugWrite(' at ');
  DebugWriteHex(Physical, 8);
  DebugWrite(' (');
  DebugWrite(Source);
  DebugWrite('), up to ');
  DebugWriteDecimal(MaximumSeconds);
  DebugWrite(' s; reset status ');
  DebugWriteHex(ReadRegister(ResetStatus), 8);
  DebugWriteLine('');
  DebugEndMessage;
end;

{ The device tree's power manager block, if there is one. }
function InitializeFromDeviceTree: Boolean;
const
  Ids: array[0..2] of PChar = ('brcm,bcm2712-pm', 'brcm,bcm2835-pm', 'brcm,bcm2835-pm-wdt');
var
  IdIndex: Integer;
  Index: Integer;
  Device: PPlatformDevice;
  Physical: QWord;
  Length: QWord;
begin
  Result := False;
  for IdIndex := 0 to High(Ids) do
  begin
    Index := FindPlatformDevice(Ids[IdIndex], 0);
    if Index < 0 then
      Continue;
    Device := PlatformDeviceAt(Index);
    if not PlatformMemoryRange(Device, 0, Physical, Length) or (Length < WatchdogCount + 4) then
      Continue;
    Registers := PByte(MapDeviceMemory(Physical, RegisterSpan));
    if Registers = nil then
      Continue;
    Device^.DriverName := 'watchdog';
    if IdIndex = 0 then
      RegisterDevice(Physical, 'BCM2712 PM watchdog', Ids[IdIndex])
    else
      RegisterDevice(Physical, 'BCM2835 PM watchdog', Ids[IdIndex]);
    Exit(True);
  end;
end;

function InitializeBcm2835Watchdog: Boolean;
var
  MailboxAddress: QWord;
  PeripheralBase: QWord;
begin
  Result := InitializeFromDeviceTree;
  if Result then
    Exit;
  MailboxAddress := VideoCoreMailboxPhysicalAddress;
  if (MailboxAddress = 0) or ((MailboxAddress and $FFFF) <> MailboxOffset) or not IsSupportedBoard then
    Exit;
  PeripheralBase := MailboxAddress - MailboxOffset;
  Registers := PByte(MapDeviceMemory(PeripheralBase + PowerManagerOffset, RegisterSpan));
  if Registers = nil then
    Exit;
  RegisterDevice(PeripheralBase + PowerManagerOffset, 'BCM2835 PM watchdog', 'from the mailbox');
  Result := True;
end;

end.
