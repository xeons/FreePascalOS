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

  Both ports share the one output byte, so whichever interrupt comes
  takes every byte waiting (Ps2ServiceController) and hands each to the
  keyboard's or the mouse's routine by the status bit: an interrupt for
  one device that finds the other's byte first does not leave it for an
  interrupt that may never come (the line can stay raised, and the two
  interrupts can run on two processors at once; a lock keeps them in
  turn).

  Setting the controller and the mouse up is done by polling: a command
  is written and its answer read from the same output byte. The
  controller's own answers (the configuration byte) come marked as the
  keyboard's, and raise the keyboard interrupt if it is on, as it is
  after a reset and while the mouse is set up. So while a driver polls
  (Ps2BeginPolling .. Ps2EndPolling), the interrupts leave every byte
  alone: otherwise one running on another processor could take the
  answer first, and the setup would fail (the mouse would stay off after
  waking from suspend to RAM, say).
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

type
  TPs2ByteRoutine = procedure(Value: Byte);

{ Where the keyboard's and the mouse's bytes go (nil: dropped). }
procedure SetPs2KeyboardRoutine(Routine: TPs2ByteRoutine);
procedure SetPs2MouseRoutine(Routine: TPs2ByteRoutine);
{ While a driver sets the controller or the mouse up by polling, the
  interrupts leave every byte to it. Begin waits for an interrupt
  already taking bytes to finish; End hands the bytes that came
  meanwhile to their routines (their interrupt came and went). }
procedure Ps2BeginPolling;
procedure Ps2EndPolling;
{ Takes every waiting byte to its routine: both interrupts call this. }
procedure Ps2ServiceController;

type
  TPs2Routine = procedure;

{ Calls Routine with interrupts off and the bytes' lock held, in turn
  with the keyboard's and the mouse's routines: for a driver starting a
  command from outside its interrupt (the keyboard's repeat settings)
  whose answers its interrupt routine follows. }
procedure Ps2RunInTurnWithInterrupts(Routine: TPs2Routine);

implementation

uses
  Hal.PortIo,
  Kernel.Arch.Cpu,
  Kernel.SpinLock;

const
  MaximumWaitIterations = 100000;
  MaximumFlushBytes = 32;
  MouseAcknowledge = $FA;
  { Waits for a mouse answer: the mouse may take a while (a reset takes
    hundreds of milliseconds). }
  MouseAnswerIterations = 2000000;

var
  KeyboardRoutine: TPs2ByteRoutine;
  MouseRoutine: TPs2ByteRoutine;
  Polling: Boolean;
  ServiceLock: TSpinLock;
  ServiceLockReady: Boolean;

procedure PrepareServiceLock;
begin
  if not ServiceLockReady then
  begin
    InitializeSpinLock(ServiceLock);
    ServiceLockReady := True;
  end;
end;

procedure SetPs2KeyboardRoutine(Routine: TPs2ByteRoutine);
begin
  PrepareServiceLock;
  KeyboardRoutine := Routine;
end;

procedure SetPs2MouseRoutine(Routine: TPs2ByteRoutine);
begin
  MouseRoutine := Routine;
end;

procedure Ps2ServiceController;
var
  Status: Byte;
  Value: Byte;
  Count: Integer;
begin
  AcquireSpinLockAtCurrentLevel(ServiceLock);
  Count := 0;
  repeat
    Status := ReadPortByte(Ps2StatusPort);
    if (Status and Ps2StatusOutputFull) = 0 then
      Break;
    { While a driver polls, every answer is for it. }
    if Polling then
      Break;
    if ((Status and Ps2StatusFromAuxiliary) <> 0) and not Assigned(MouseRoutine) then
      Break;
    Value := ReadPortByte(Ps2DataPort);
    if (Status and Ps2StatusFromAuxiliary) <> 0 then
    begin
      if Assigned(MouseRoutine) then
        MouseRoutine(Value);
    end
    else if Assigned(KeyboardRoutine) then
      KeyboardRoutine(Value);
    Inc(Count);
  until Count >= MaximumFlushBytes;
  ReleaseSpinLockAtCurrentLevel(ServiceLock);
end;

procedure Ps2BeginPolling;
var
  WereEnabled: Boolean;
begin
  PrepareServiceLock;
  Polling := True;
  { An interrupt that took the lock before it saw the flag finishes
    first. Interrupts off: one on this processor must not wait for the
    lock held here. }
  WereEnabled := SaveAndDisableInterrupts;
  AcquireSpinLockAtCurrentLevel(ServiceLock);
  ReleaseSpinLockAtCurrentLevel(ServiceLock);
  RestoreInterrupts(WereEnabled);
end;

procedure Ps2RunInTurnWithInterrupts(Routine: TPs2Routine);
var
  WereEnabled: Boolean;
begin
  PrepareServiceLock;
  WereEnabled := SaveAndDisableInterrupts;
  AcquireSpinLockAtCurrentLevel(ServiceLock);
  Routine();
  ReleaseSpinLockAtCurrentLevel(ServiceLock);
  RestoreInterrupts(WereEnabled);
end;

procedure Ps2EndPolling;
var
  WereEnabled: Boolean;
begin
  Polling := False;
  { A byte that came after the poller's last read raised its interrupt,
    which left it; the interrupt does not come again for it. }
  WereEnabled := SaveAndDisableInterrupts;
  Ps2ServiceController;
  RestoreInterrupts(WereEnabled);
end;

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
