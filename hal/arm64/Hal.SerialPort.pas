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
  The serial console on AArch64: the UART the firmware's ACPI SPCR table
  names, at the address it gives (the loader mapped its registers into
  the physical memory window, so it works before anything else).

  Two kinds are driven:

  - The ARM PL011 (SPCR interface types 03h, and 0Eh/0Dh, the SBSA
    generic UART, a PL011 subset): QEMU's virt machine, and the Raspberry
    Pi 4's UART0 when its firmware is set to use it.
  - A 16550-compatible UART with 32-bit registers (type 10h, the
    BCM2835 mini UART the Pi 4's firmware uses by default; type 12h, a
    16550 with a given access width): registers 4 bytes apart.

  The firmware set the line up (speed, format); the kernel leaves it as
  it is, since the UART's clock is not known here.
}
unit Hal.SerialPort;

{$mode objfpc}

interface

procedure InitializeSerialPort;
procedure WriteSerialCharacter(Character: Char);
function SerialPortIsPresent: Boolean;
{ Returns True and the next received character if one is waiting. }
function TryReadSerialCharacter(out Character: Char): Boolean;
{ Makes the port raise its interrupt when data arrives. }
procedure EnableSerialReceiveInterrupt;

type
  { The line the port interrupts on. }
  TSerialInterrupt = record
    { An ISA IRQ (ConnectIsaInterrupt), else a global system interrupt. }
    IsIsaIrq: Boolean;
    LevelTriggered: Boolean;
    ActiveLow: Boolean;
    Number: LongWord;
  end;

{ The global system interrupt the SPCR gives (level triggered). }
function SerialPortInterrupt: TSerialInterrupt;

implementation

uses
  Firmware.Acpi,
  Memory.Layout,
  Hal.FirmwareTables;

type
  TSerialPortTable = packed record
    Header: TAcpiTableHeader;
    InterfaceType: Byte;
    Reserved: array[0..2] of Byte;
    AddressSpace: Byte;
    RegisterBitWidth: Byte;
    RegisterBitOffset: Byte;
    AccessSize: Byte;
    Address: QWord;
    InterruptType: Byte;
    Irq: Byte;
    GlobalSystemInterrupt: LongWord;
  end;
  PSerialPortTable = ^TSerialPortTable;

  TUartKind = (UartNone, UartPl011, UartWide16550);

const
  InterfaceFull16550 = $00;
  InterfacePl011 = $03;
  InterfaceSbsa32Bit = $0D;
  InterfaceSbsaGeneric = $0E;
  InterfaceBcm2835 = $10;
  InterfaceSized16550 = $12;
  AddressSpaceSystemMemory = 0;

  { PL011 registers (byte offsets) and bits. }
  Pl011Data = $00;
  Pl011Flags = $18;
  Pl011InterruptMask = $38;
  Pl011InterruptClear = $44;
  Pl011FlagReceiveEmpty = $10;
  Pl011FlagTransmitFull = $20;
  Pl011ReceiveInterrupts = $50;     { RXIM and RTIM }

  { 16550 registers (indices; 4 bytes apart here) and bits. }
  Uart16550Data = 0;
  Uart16550InterruptEnable = 1;
  Uart16550LineStatus = 5;
  LineStatusDataReady = $01;
  LineStatusTransmitterEmpty = $20;
  InterruptEnableDataAvailable = $01;
  RegisterStride = 4;

  MaximumTransmitWaitIterations = 100000;

var
  Kind: TUartKind = UartNone;
  Registers: PByte = nil;
  InterruptNumber: LongWord = 0;

function ReadRegister(Offset: LongWord): LongWord;
begin
  Result := PLongWord(Registers + Offset)^;
end;

procedure WriteRegister(Offset: LongWord; Value: LongWord);
begin
  PLongWord(Registers + Offset)^ := Value;
end;

function SerialPortIsPresent: Boolean;
begin
  Result := Kind <> UartNone;
end;

procedure InitializeSerialPort;
var
  Table: PSerialPortTable;
begin
  Kind := UartNone;
  Table := PSerialPortTable(FindFirmwareTable('SPCR', 0));
  if (Table = nil) or (Table^.AddressSpace <> AddressSpaceSystemMemory) or (Table^.Address = 0) then
    Exit;
  case Table^.InterfaceType of
    InterfacePl011, InterfaceSbsa32Bit, InterfaceSbsaGeneric:
      Kind := UartPl011;
    InterfaceBcm2835, InterfaceFull16550, InterfaceSized16550:
      Kind := UartWide16550;
  else
    Exit;
  end;
  Registers := PByte(PhysicalToVirtual(Table^.Address));
  InterruptNumber := Table^.GlobalSystemInterrupt;
end;

procedure WriteSerialCharacter(Character: Char);
var
  Iteration: LongWord;
begin
  Iteration := 0;
  case Kind of
    UartPl011:
      begin
        while ((ReadRegister(Pl011Flags) and Pl011FlagTransmitFull) <> 0) and
              (Iteration < MaximumTransmitWaitIterations) do
          Inc(Iteration);
        WriteRegister(Pl011Data, Ord(Character));
      end;
    UartWide16550:
      begin
        while ((ReadRegister(Uart16550LineStatus * RegisterStride) and LineStatusTransmitterEmpty) = 0) and
              (Iteration < MaximumTransmitWaitIterations) do
          Inc(Iteration);
        WriteRegister(Uart16550Data * RegisterStride, Ord(Character));
      end;
  end;
end;

function TryReadSerialCharacter(out Character: Char): Boolean;
begin
  Character := #0;
  Result := False;
  case Kind of
    UartPl011:
      if (ReadRegister(Pl011Flags) and Pl011FlagReceiveEmpty) = 0 then
      begin
        Character := Char(ReadRegister(Pl011Data) and $FF);
        Result := True;
      end;
    UartWide16550:
      if (ReadRegister(Uart16550LineStatus * RegisterStride) and LineStatusDataReady) <> 0 then
      begin
        Character := Char(ReadRegister(Uart16550Data * RegisterStride) and $FF);
        Result := True;
      end;
  end;
end;

procedure EnableSerialReceiveInterrupt;
begin
  case Kind of
    UartPl011:
      begin
        WriteRegister(Pl011InterruptClear, $7FF);
        WriteRegister(Pl011InterruptMask, Pl011ReceiveInterrupts);
      end;
    UartWide16550:
      WriteRegister(Uart16550InterruptEnable * RegisterStride, InterruptEnableDataAvailable);
  end;
end;

function SerialPortInterrupt: TSerialInterrupt;
begin
  Result.IsIsaIrq := False;
  Result.LevelTriggered := True;
  Result.ActiveLow := False;
  Result.Number := InterruptNumber;
end;

end.
