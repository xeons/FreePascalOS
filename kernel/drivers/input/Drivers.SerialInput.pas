{
  Serial port input by interrupt.

  COM1 raises IRQ 4 when received data is waiting. The handler empties the
  receive buffer into the console's input, and the console stops polling
  the port.
}
unit Drivers.SerialInput;

{$mode objfpc}

interface

{ Returns False if the port or interrupt routing is missing (the console
  then keeps polling). }
function InitializeSerialInput: Boolean;

implementation

uses
  Kernel.Arch.TrapFrame,
  Hal.SerialPort,
  Io.InterruptRouting,
  Io.Console;

const
  SerialIrq = 4;
  { Bounds the work of one interrupt if data keeps arriving. }
  MaximumCharactersPerInterrupt = 64;

procedure HandleSerialInterrupt(Frame: PTrapFrame; Context: Pointer);
var
  Character: Char;
  Count: Integer;
begin
  Count := 0;
  while (Count < MaximumCharactersPerInterrupt) and TryReadSerialCharacter(Character) do
  begin
    DeliverConsoleInput(Character);
    Inc(Count);
  end;
end;

function InitializeSerialInput: Boolean;
begin
  Result := False;
  if not SerialPortIsPresent then
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
