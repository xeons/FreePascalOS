{
  16550 compatible UART driver for the first serial port (COM1).

  Used as the kernel debug output channel. It works from the very first
  instruction of the kernel, before memory management or interrupts exist.
  Output always polls the hardware; input can raise an interrupt once a
  handler is connected (see Drivers.SerialDevice).
}
unit Hal.SerialPort;

{$mode objfpc}

interface

procedure InitializeSerialPort;
procedure WriteSerialCharacter(Character: Char);
function SerialPortIsPresent: Boolean;

{ Returns True and the next received character if one is waiting. }
function TryReadSerialCharacter(out Character: Char): Boolean;

{ Makes the port raise its interrupt (IRQ 4) when data arrives. }
procedure EnableSerialReceiveInterrupt;

implementation

uses
  Hal.PortIo;

const
  Com1BasePort = $3F8;

  { Register offsets from the base port. }
  RegisterData = 0;
  RegisterInterruptEnable = 1;
  RegisterFifoControl = 2;
  RegisterLineControl = 3;
  RegisterModemControl = 4;
  RegisterLineStatus = 5;
  RegisterScratch = 7;

  { With the divisor latch enabled, offsets 0 and 1 hold the baud divisor. }
  RegisterDivisorLow = 0;
  RegisterDivisorHigh = 1;

  LineControlDivisorLatch = $80;
  LineControlEightBitsNoParityOneStop = $03;

  FifoEnableAndClear = $C7;
  ModemControlDataTerminalReadyAndRequestToSend = $0B;

  InterruptEnableDataAvailable = $01;

  LineStatusTransmitterEmpty = $20;
  LineStatusDataReady = $01;

  { 115200 / 1 = 115200 baud. }
  BaudDivisor = 1;

  ScratchTestValue = $5A;
  MaximumTransmitWaitIterations = 100000;

var
  PortIsPresent: Boolean = False;

function SerialPortIsPresent: Boolean;
begin
  Result := PortIsPresent;
end;

procedure InitializeSerialPort;
begin
  { Detect the port by checking that the scratch register holds a value. }
  WritePortByte(Com1BasePort + RegisterScratch, ScratchTestValue);
  PortIsPresent := ReadPortByte(Com1BasePort + RegisterScratch) = ScratchTestValue;
  if not PortIsPresent then
    Exit;

  WritePortByte(Com1BasePort + RegisterInterruptEnable, 0);

  WritePortByte(Com1BasePort + RegisterLineControl, LineControlDivisorLatch);
  WritePortByte(Com1BasePort + RegisterDivisorLow, BaudDivisor and $FF);
  WritePortByte(Com1BasePort + RegisterDivisorHigh, (BaudDivisor shr 8) and $FF);
  WritePortByte(Com1BasePort + RegisterLineControl, LineControlEightBitsNoParityOneStop);

  WritePortByte(Com1BasePort + RegisterFifoControl, FifoEnableAndClear);
  WritePortByte(Com1BasePort + RegisterModemControl, ModemControlDataTerminalReadyAndRequestToSend);
end;

procedure WaitUntilTransmitterIsEmpty;
var
  Iteration: LongWord;
begin
  for Iteration := 1 to MaximumTransmitWaitIterations do
  begin
    if (ReadPortByte(Com1BasePort + RegisterLineStatus) and LineStatusTransmitterEmpty) <> 0 then
      Exit;
  end;
end;

procedure WriteSerialCharacter(Character: Char);
begin
  if not PortIsPresent then
    Exit;

  if Character = #10 then
  begin
    WaitUntilTransmitterIsEmpty;
    WritePortByte(Com1BasePort + RegisterData, 13);
  end;

  WaitUntilTransmitterIsEmpty;
  WritePortByte(Com1BasePort + RegisterData, Byte(Character));
end;

procedure EnableSerialReceiveInterrupt;
begin
  if PortIsPresent then
    WritePortByte(Com1BasePort + RegisterInterruptEnable, InterruptEnableDataAvailable);
end;

function TryReadSerialCharacter(out Character: Char): Boolean;
begin
  Character := #0;
  Result := PortIsPresent and
    ((ReadPortByte(Com1BasePort + RegisterLineStatus) and LineStatusDataReady) <> 0);
  if Result then
    Character := Char(ReadPortByte(Com1BasePort + RegisterData));
end;

end.
