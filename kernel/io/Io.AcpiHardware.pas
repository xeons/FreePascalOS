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
  ACPI fixed hardware: the registers the FADT describes.

  PM1 event blocks (a and b, read and written together) hold the fixed
  events' status bits (written as one to clear) and their enable bits:
  the power button, the sleep button, waking. PM1 control blocks hold
  SCI_EN (the hardware is in ACPI mode) and the sleep type and sleep
  enable fields. GPE blocks hold a status and an enable bit for each
  general purpose event. All of them raise the SCI, an interrupt line
  named in the FADT.

  Registers are found by their generic address (system I/O or memory)
  where the FADT gives one, else by the older I/O port fields. Moving
  the machine into ACPI mode writes ACPI_ENABLE to the SMI command port
  and waits for SCI_EN. The reset register (where the FADT says it is
  supported) resets the machine.
}
unit Io.AcpiHardware;

{$mode objfpc}
{$pointermath on}

interface

const
  { PM1 status and enable bits. }
  Pm1Timer = $0001;
  Pm1Global = $0020;
  Pm1PowerButton = $0100;
  Pm1SleepButton = $0200;
  Pm1RealTimeClock = $0400;
  Pm1Wake = $8000;
  Pm1StatusBits = $8F31;

type
  TAcpiHardware = record
    Present: Boolean;
    SciInterrupt: Word;
    { The power and sleep buttons are fixed hardware (not devices with
      control methods). }
    FixedPowerButton: Boolean;
    FixedSleepButton: Boolean;
    CanReset: Boolean;
    GpeCount: LongWord;
  end;

{ Reads the FADT. False if there is none, or it is hardware reduced
  (no fixed hardware). }
function InitializeAcpiHardware: Boolean;
function AcpiHardware: TAcpiHardware;
{ Moves the machine from legacy mode into ACPI mode (SCI_EN). }
function EnableAcpiMode: Boolean;

function ReadPm1Status: Word;
procedure ClearPm1Status(Bits: Word);
function ReadPm1Enable: Word;
procedure WritePm1Enable(Bits: Word);
{ Writes the sleep types into the PM1a and PM1b control registers, then
  the same with SLP_EN: the machine enters that state. }
procedure WriteSleepControl(TypeA, TypeB: Byte);

{ GPE Number's status and enable bits (EnableGpe also from interrupt
  handlers). }
function GpeIsSet(Number: LongWord): Boolean;
function GpeIsEnabled(Number: LongWord): Boolean;
procedure ClearGpe(Number: LongWord);
procedure EnableGpe(Number: LongWord; Enabled: Boolean);

{ Writes the reset value into the reset register; returns if it did not
  reset the machine. }
procedure ResetThroughAcpi;

implementation

uses
  Memory.Layout,
  Memory.DeviceMapping,
  Kernel.Arch.Cpu,
  Kernel.Clock,
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  Hal.PortIo,
  Firmware.Acpi;

const
  AddressSpaceMemory = 0;
  AddressSpaceIo = 1;

  OffsetSciInterrupt = 46;
  OffsetSmiCommand = 48;
  OffsetAcpiEnable = 52;
  OffsetPm1aEvent = 56;
  OffsetPm1bEvent = 60;
  OffsetPm1aControl = 64;
  OffsetPm1bControl = 68;
  OffsetGpe0Block = 80;
  OffsetGpe1Block = 84;
  OffsetPm1EventLength = 88;
  OffsetGpe0Length = 92;
  OffsetGpe1Length = 93;
  OffsetGpe1Base = 94;
  OffsetFlags = 112;
  OffsetResetRegister = 116;
  OffsetResetValue = 128;
  OffsetExtendedPm1aEvent = 148;
  OffsetExtendedPm1bEvent = 160;
  OffsetExtendedPm1aControl = 172;
  OffsetExtendedPm1bControl = 184;
  OffsetExtendedGpe0 = 220;
  OffsetExtendedGpe1 = 232;

  FlagControlMethodPowerButton = 1 shl 4;
  FlagControlMethodSleepButton = 1 shl 5;
  FlagResetSupported = 1 shl 10;
  FlagHardwareReduced = 1 shl 20;

  ControlSciEnable = $0001;
  ControlSleepTypeShift = 10;
  ControlSleepTypeMask = $1C00;
  ControlSleepEnable = $2000;

type
  { Where a register is: a space (I/O or memory) and an address. }
  TRegister = record
    Space: Byte;
    Address: QWord;
    Mapped: PByte;
  end;

var
  Hardware: TAcpiHardware;
  Fadt: PByte;
  Pm1aEvent: TRegister;
  Pm1bEvent: TRegister;
  Pm1aControl: TRegister;
  Pm1bControl: TRegister;
  Gpe0: TRegister;
  Gpe1: TRegister;
  ResetRegister: TRegister;
  Pm1EventLength: Byte;
  Gpe0Length: Byte;
  Gpe1Length: Byte;
  Gpe1Base: Byte;
  { GPE enable bits are changed from the SCI's handler and from threads:
    the lock is taken at the highest device level by both. }
  GpeLock: TSpinLock;

{ --- Registers ---------------------------------------------------------------- }

function FadtLength: LongWord;
begin
  Result := PAcpiTableHeader(Fadt)^.Length;
end;

{ The register at the generic address at ExtendedOffset if the FADT has
  one, else the I/O port at LegacyOffset. }
function FindRegister(ExtendedOffset, LegacyOffset: LongWord): TRegister;
begin
  Result.Space := AddressSpaceIo;
  Result.Address := 0;
  Result.Mapped := nil;
  if (FadtLength >= ExtendedOffset + 12) and (PQWord(Fadt + ExtendedOffset + 4)^ <> 0) and
     (Fadt[ExtendedOffset] in [AddressSpaceMemory, AddressSpaceIo]) then
  begin
    Result.Space := Fadt[ExtendedOffset];
    Result.Address := PQWord(Fadt + ExtendedOffset + 4)^;
  end
  else if LegacyOffset <> 0 then
    Result.Address := PLongWord(Fadt + LegacyOffset)^;
  if (Result.Space = AddressSpaceMemory) and (Result.Address <> 0) then
    Result.Mapped := PByte(MapDeviceMemory(Result.Address and not QWord($FFF), $2000)) +
      (Result.Address and $FFF);
end;

function RegisterPresent(const Register: TRegister): Boolean;
begin
  Result := Register.Address <> 0;
end;

function ReadRegister(const Register: TRegister; Offset: LongWord; Bytes: Byte): LongWord;
begin
  Result := 0;
  if not RegisterPresent(Register) then
    Exit;
  if Register.Space = AddressSpaceIo then
    case Bytes of
      1: Result := ReadPortByte(Word(Register.Address + Offset));
      2: Result := ReadPortWord(Word(Register.Address + Offset));
    else
      Result := ReadPortLongWord(Word(Register.Address + Offset));
    end
  else if Register.Mapped <> nil then
    case Bytes of
      1: Result := Register.Mapped[Offset];
      2: Result := PWord(Register.Mapped + Offset)^;
    else
      Result := PLongWord(Register.Mapped + Offset)^;
    end;
end;

procedure WriteRegister(const Register: TRegister; Offset: LongWord; Bytes: Byte; Value: LongWord);
begin
  if not RegisterPresent(Register) then
    Exit;
  if Register.Space = AddressSpaceIo then
    case Bytes of
      1: WritePortByte(Word(Register.Address + Offset), Byte(Value));
      2: WritePortWord(Word(Register.Address + Offset), Word(Value));
    else
      WritePortLongWord(Word(Register.Address + Offset), Value);
    end
  else if Register.Mapped <> nil then
    case Bytes of
      1: Register.Mapped[Offset] := Byte(Value);
      2: PWord(Register.Mapped + Offset)^ := Word(Value);
    else
      PLongWord(Register.Mapped + Offset)^ := Value;
    end;
end;

{ --- PM1 ------------------------------------------------------------------------ }

function ReadPm1Status: Word;
begin
  Result := Word(ReadRegister(Pm1aEvent, 0, 2) or ReadRegister(Pm1bEvent, 0, 2));
end;

procedure ClearPm1Status(Bits: Word);
begin
  WriteRegister(Pm1aEvent, 0, 2, Bits);
  WriteRegister(Pm1bEvent, 0, 2, Bits);
end;

function ReadPm1Enable: Word;
begin
  Result := Word(ReadRegister(Pm1aEvent, Pm1EventLength div 2, 2) or
    ReadRegister(Pm1bEvent, Pm1EventLength div 2, 2));
end;

procedure WritePm1Enable(Bits: Word);
begin
  WriteRegister(Pm1aEvent, Pm1EventLength div 2, 2, Bits);
  WriteRegister(Pm1bEvent, Pm1EventLength div 2, 2, Bits);
end;

function ReadPm1Control: Word;
begin
  Result := Word(ReadRegister(Pm1aControl, 0, 2) or ReadRegister(Pm1bControl, 0, 2));
end;

procedure WriteSleepControl(TypeA, TypeB: Byte);
var
  ControlA: Word;
  ControlB: Word;
begin
  ControlA := Word(ReadRegister(Pm1aControl, 0, 2)) and not (ControlSleepTypeMask or ControlSleepEnable);
  ControlB := Word(ReadRegister(Pm1bControl, 0, 2)) and not (ControlSleepTypeMask or ControlSleepEnable);
  ControlA := ControlA or (Word(TypeA) shl ControlSleepTypeShift);
  ControlB := ControlB or (Word(TypeB) shl ControlSleepTypeShift);
  { The type first, then with the enable bit (as the specification
    asks). }
  WriteRegister(Pm1aControl, 0, 2, ControlA);
  WriteRegister(Pm1bControl, 0, 2, ControlB);
  WriteRegister(Pm1aControl, 0, 2, ControlA or ControlSleepEnable);
  WriteRegister(Pm1bControl, 0, 2, ControlB or ControlSleepEnable);
end;

{ --- GPEs ------------------------------------------------------------------------ }

{ The block, and byte and bit in its status half, of GPE Number. }
function LocateGpe(Number: LongWord; out Register: TRegister; out ByteIndex: LongWord; out HalfLength: LongWord;
  out Bit: Byte): Boolean;
begin
  Result := True;
  Bit := Number mod 8;
  if Number < LongWord(Gpe0Length div 2) * 8 then
  begin
    Register := Gpe0;
    ByteIndex := Number div 8;
    HalfLength := Gpe0Length div 2;
  end
  else if (Number >= Gpe1Base) and (Number < Gpe1Base + LongWord(Gpe1Length div 2) * 8) then
  begin
    Register := Gpe1;
    ByteIndex := (Number - Gpe1Base) div 8;
    HalfLength := Gpe1Length div 2;
  end
  else
    Result := False;
end;

function GpeIsSet(Number: LongWord): Boolean;
var
  Register: TRegister;
  ByteIndex: LongWord;
  HalfLength: LongWord;
  Bit: Byte;
begin
  Result := LocateGpe(Number, Register, ByteIndex, HalfLength, Bit) and
    ((ReadRegister(Register, ByteIndex, 1) and (1 shl Bit)) <> 0);
end;

function GpeIsEnabled(Number: LongWord): Boolean;
var
  Register: TRegister;
  ByteIndex: LongWord;
  HalfLength: LongWord;
  Bit: Byte;
begin
  Result := LocateGpe(Number, Register, ByteIndex, HalfLength, Bit) and
    ((ReadRegister(Register, HalfLength + ByteIndex, 1) and (1 shl Bit)) <> 0);
end;

procedure ClearGpe(Number: LongWord);
var
  Register: TRegister;
  ByteIndex: LongWord;
  HalfLength: LongWord;
  Bit: Byte;
begin
  if LocateGpe(Number, Register, ByteIndex, HalfLength, Bit) then
    WriteRegister(Register, ByteIndex, 1, 1 shl Bit);
end;

procedure EnableGpe(Number: LongWord; Enabled: Boolean);
var
  Register: TRegister;
  ByteIndex: LongWord;
  HalfLength: LongWord;
  Bit: Byte;
  Value: LongWord;
  PreviousLevel: TPriorityLevel;
begin
  if not LocateGpe(Number, Register, ByteIndex, HalfLength, Bit) then
    Exit;
  PreviousLevel := AcquireSpinLockAtLevel(GpeLock, DeviceLevelHighest);
  Value := ReadRegister(Register, HalfLength + ByteIndex, 1);
  if Enabled then
    Value := Value or (LongWord(1) shl Bit)
  else
    Value := Value and not (LongWord(1) shl Bit);
  WriteRegister(Register, HalfLength + ByteIndex, 1, Value);
  ReleaseSpinLock(GpeLock, PreviousLevel);
end;

{ --- Setting up ------------------------------------------------------------------- }

function InitializeAcpiHardware: Boolean;
var
  Flags: LongWord;
begin
  Result := False;
  Fadt := PByte(FindAcpiTable('FACP', 0));
  if (Fadt = nil) or (FadtLength < OffsetFlags + 4) then
    Exit;
  Flags := PLongWord(Fadt + OffsetFlags)^;
  if (Flags and FlagHardwareReduced) <> 0 then
    Exit;
  InitializeSpinLock(GpeLock);
  Hardware.SciInterrupt := PWord(Fadt + OffsetSciInterrupt)^;
  Hardware.FixedPowerButton := (Flags and FlagControlMethodPowerButton) = 0;
  Hardware.FixedSleepButton := (Flags and FlagControlMethodSleepButton) = 0;
  Pm1aEvent := FindRegister(OffsetExtendedPm1aEvent, OffsetPm1aEvent);
  Pm1bEvent := FindRegister(OffsetExtendedPm1bEvent, OffsetPm1bEvent);
  Pm1aControl := FindRegister(OffsetExtendedPm1aControl, OffsetPm1aControl);
  Pm1bControl := FindRegister(OffsetExtendedPm1bControl, OffsetPm1bControl);
  Gpe0 := FindRegister(OffsetExtendedGpe0, OffsetGpe0Block);
  Gpe1 := FindRegister(OffsetExtendedGpe1, OffsetGpe1Block);
  Pm1EventLength := Fadt[OffsetPm1EventLength];
  Gpe0Length := Fadt[OffsetGpe0Length];
  Gpe1Length := Fadt[OffsetGpe1Length];
  Gpe1Base := Fadt[OffsetGpe1Base];
  if not RegisterPresent(Gpe0) then
    Gpe0Length := 0;
  if not RegisterPresent(Gpe1) then
    Gpe1Length := 0;
  Hardware.GpeCount := LongWord(Gpe0Length div 2) * 8;
  if Gpe1Length > 0 then
    Hardware.GpeCount := Gpe1Base + LongWord(Gpe1Length div 2) * 8;
  if ((Flags and FlagResetSupported) <> 0) and (FadtLength > OffsetResetValue) then
  begin
    ResetRegister := FindRegister(OffsetResetRegister, 0);
    Hardware.CanReset := RegisterPresent(ResetRegister);
  end;
  Hardware.Present := RegisterPresent(Pm1aEvent) and RegisterPresent(Pm1aControl);
  Result := Hardware.Present;
end;

function AcpiHardware: TAcpiHardware;
begin
  Result := Hardware;
end;

function EnableAcpiMode: Boolean;
var
  SmiCommand: LongWord;
  EnableValue: Byte;
  Deadline: QWord;
begin
  if (ReadPm1Control and ControlSciEnable) <> 0 then
    Exit(True);
  SmiCommand := PLongWord(Fadt + OffsetSmiCommand)^;
  EnableValue := Fadt[OffsetAcpiEnable];
  if (SmiCommand = 0) or (EnableValue = 0) then
    Exit(False);
  WritePortByte(Word(SmiCommand), EnableValue);
  Deadline := ClockTickCount + MillisecondsToTicks(3000);
  while (ReadPm1Control and ControlSciEnable) = 0 do
  begin
    if ClockTickCount > Deadline then
      Exit(False);
    CpuRelax;
  end;
  Result := True;
end;

procedure ResetThroughAcpi;
begin
  if not Hardware.CanReset then
    Exit;
  WriteRegister(ResetRegister, 0, 1, Fadt[OffsetResetValue]);
end;

end.
