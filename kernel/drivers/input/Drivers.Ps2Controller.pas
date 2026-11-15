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
  The PS/2 controller (8042): what the keyboard and mouse drivers share.

  Two ports behind one data port (60h) and one status and command port
  (64h): the first for the keyboard, the second (auxiliary) for the
  mouse. The controller's configuration byte enables each port's
  interrupt (IRQ 1 and IRQ 12) and clock. A byte for the mouse is sent
  by writing D4h to the command port first; bytes from the mouse are
  marked in the status.
}
unit Drivers.Ps2Controller;

{$mode objfpc}

interface

const
  Ps2DataPort = $60;
  Ps2StatusPort = $64;

  Ps2StatusOutputFull = $01;
  Ps2StatusInputFull = $02;
  { The byte in the output buffer came from the mouse port. }
  Ps2StatusFromAuxiliary = $20;

  Ps2CommandReadConfiguration = $20;
  Ps2CommandWriteConfiguration = $60;
  Ps2CommandDisableSecondPort = $A7;
  Ps2CommandEnableSecondPort = $A8;
  Ps2CommandDisableFirstPort = $AD;
  Ps2CommandEnableFirstPort = $AE;
  Ps2CommandWriteSecondPort = $D4;

  Ps2ConfigurationFirstPortInterrupt = $01;
  Ps2ConfigurationSecondPortInterrupt = $02;
  Ps2ConfigurationSecondPortClockOff = $20;
  Ps2ConfigurationTranslation = $40;

function Ps2ControllerIsPresent: Boolean;
function Ps2WaitUntilWritable: Boolean;
function Ps2WaitUntilReadable: Boolean;
procedure Ps2SendCommand(Command: Byte);
procedure Ps2WriteData(Value: Byte);
{ Reads what is waiting (a byte at a time, a few at most). }
procedure Ps2FlushOutputBuffer;
function Ps2ReadConfiguration(out Configuration: Byte): Boolean;
procedure Ps2WriteConfiguration(Configuration: Byte);
{ Sends Value to the mouse and waits for its answer; True if it
  acknowledged. Polled: for setting the mouse up, before its interrupt
  is enabled. }
function Ps2SendToMouse(Value: Byte): Boolean;
{ The next byte the mouse sends (polled); False if none came. }
function Ps2ReadFromMouse(out Value: Byte): Boolean;

implementation

uses
  Hal.PortIo;

const
  MaximumWaitIterations = 100000;
  MaximumFlushBytes = 32;
  MouseAcknowledge = $FA;
  { Waits for a mouse answer: the mouse may take a while (a reset takes
    hundreds of milliseconds). }
  MouseAnswerIterations = 2000000;

function Ps2ControllerIsPresent: Boolean;
begin
  { No controller: the status port floats high. }
  Result := ReadPortByte(Ps2StatusPort) <> $FF;
end;

function Ps2WaitUntilWritable: Boolean;
var
  Iteration: LongWord;
begin
  for Iteration := 1 to MaximumWaitIterations do
    if (ReadPortByte(Ps2StatusPort) and Ps2StatusInputFull) = 0 then
      Exit(True);
  Result := False;
end;

function Ps2WaitUntilReadable: Boolean;
var
  Iteration: LongWord;
begin
  for Iteration := 1 to MaximumWaitIterations do
    if (ReadPortByte(Ps2StatusPort) and Ps2StatusOutputFull) <> 0 then
      Exit(True);
  Result := False;
end;

procedure Ps2SendCommand(Command: Byte);
begin
  Ps2WaitUntilWritable;
  WritePortByte(Ps2StatusPort, Command);
end;

procedure Ps2WriteData(Value: Byte);
begin
  Ps2WaitUntilWritable;
  WritePortByte(Ps2DataPort, Value);
end;

procedure Ps2FlushOutputBuffer;
var
  Count: Integer;
begin
  Count := 0;
  while ((ReadPortByte(Ps2StatusPort) and Ps2StatusOutputFull) <> 0) and (Count < MaximumFlushBytes) do
  begin
    ReadPortByte(Ps2DataPort);
    Inc(Count);
  end;
end;

function Ps2ReadConfiguration(out Configuration: Byte): Boolean;
begin
  Configuration := 0;
  Ps2SendCommand(Ps2CommandReadConfiguration);
  Result := Ps2WaitUntilReadable;
  if Result then
    Configuration := ReadPortByte(Ps2DataPort);
end;

procedure Ps2WriteConfiguration(Configuration: Byte);
begin
  Ps2SendCommand(Ps2CommandWriteConfiguration);
  Ps2WriteData(Configuration);
end;

function Ps2ReadFromMouse(out Value: Byte): Boolean;
var
  Iteration: LongWord;
  Status: Byte;
begin
  Value := 0;
  for Iteration := 1 to MouseAnswerIterations do
  begin
    Status := ReadPortByte(Ps2StatusPort);
    if (Status and Ps2StatusOutputFull) <> 0 then
    begin
      Value := ReadPortByte(Ps2DataPort);
      { A keyboard byte meanwhile is dropped: the mouse is being set up. }
      if (Status and Ps2StatusFromAuxiliary) <> 0 then
        Exit(True);
    end;
  end;
  Result := False;
end;

function Ps2SendToMouse(Value: Byte): Boolean;
var
  Answer: Byte;
begin
  Ps2SendCommand(Ps2CommandWriteSecondPort);
  Ps2WriteData(Value);
  Result := Ps2ReadFromMouse(Answer) and (Answer = MouseAcknowledge);
end;

end.
