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
  The serial port as an input device: /dev/serial0.

  COM1 raises IRQ 4 when received data is waiting. The handler empties
  the port's receive buffer into the device's input (Io.InputDevice);
  the console keeps the device open and reads it (Io.ConsoleInput).

  Without interrupt routing there is no device, and the console polls
  the port itself. Output to the port is not done through this device:
  the console and the kernel log write to it directly (Hal.SerialPort).
}
unit Drivers.SerialDevice;

{$mode objfpc}

interface

{ Returns False if the port or interrupt routing is missing (the console
  then keeps polling). }
function InitializeSerialDevice: Boolean;

implementation

uses
  Runtime.Memory,
  Kernel.Arch.TrapFrame,
  Hal.SerialPort,
  Io.InterruptRouting,
  Io.Manager,
  Io.InputDevice,
  Io.Console;

const
  SerialIrq = 4;
  { Bounds the work of one interrupt if data keeps arriving. }
  MaximumCharactersPerInterrupt = 64;

var
  SerialInput: PInputDevice;

procedure HandleSerialInterrupt(Frame: PTrapFrame; Context: Pointer);
var
  Character: Char;
  Count: Integer;
begin
  Count := 0;
  while (Count < MaximumCharactersPerInterrupt) and TryReadSerialCharacter(Character) do
  begin
    AddInputByte(SerialInput^, Byte(Character));
    Inc(Count);
  end;
end;

function CreateSerialDevice: Boolean;
const
  OwnerReadWrite = $180; { rw------- }
var
  Dispatch: TDispatchTable;
  Driver: PDriverObject;
  Device: PDeviceObject;
begin
  FillMemory(@Dispatch, SizeOf(Dispatch), 0);
  Dispatch[IoFunctionRead] := @ReadInputDevice;
  Driver := CreateDriver('serial', Dispatch);
  Device := CreateDevice(Driver, 'serial0', DeviceKindCharacter, OwnerReadWrite,
    SizeOf(TInputDevice));
  if Device = nil then
    Exit(False);
  Device^.IsExclusive := True;
  SerialInput := PInputDevice(Device^.Extension);
  InitializeInputDevice(SerialInput^);
  Result := True;
end;

function InitializeSerialDevice: Boolean;
begin
  Result := False;
  if not SerialPortIsPresent then
    Exit;
  if not CreateSerialDevice then
    Exit;
  if not ConnectIsaInterrupt(SerialIrq, @HandleSerialInterrupt, nil) then
    Exit;
  SetSerialInputInterruptDriven;
  EnableSerialReceiveInterrupt;
  { Anything typed before the interrupt was enabled. }
  HandleSerialInterrupt(nil, nil);
  Result := True;
end;

end.
