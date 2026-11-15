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
  PS/2 mice: the PS/2 controller's second port (IRQ 12).

  Setting the mouse up: the port enabled (its clock and interrupt in the
  controller's configuration), the mouse reset and given its defaults,
  then the IntelliMouse knock (sample rates 200, 100, 80): a mouse that
  answers it with id 3 has a wheel and sends four bytes a packet instead
  of three. Then data reporting on.

  A packet: buttons and the signs of the motion in the first byte (bit 3
  always set, which keeps the packets in step), X and Y motion in the
  next two (Y up positive), the wheel in the fourth (four bits, signed,
  positive towards the user). Each becomes input events: motion (right
  and down positive), a button event per change, wheel steps (positive
  away from the user).
}
unit Drivers.Ps2Mouse;

{$mode objfpc}

interface

{ Sets up the mouse on the PS/2 controller's second port, if there is
  one. Call after the keyboard's driver (which configures the
  controller). }
function InitializePs2Mouse: Boolean;

implementation

uses
  Runtime.Memory,
  Abi.SystemCalls,
  Kernel.Arch.TrapFrame,
  Hal.PortIo,
  Io.InterruptRouting,
  Io.InputEvents,
  Io.PowerManagement,
  Debug.Output,
  Drivers.Ps2Controller;

const
  MouseIrq = 12;

  MouseReset = $FF;
  MouseSetDefaults = $F6;
  MouseSetSampleRate = $F3;
  MouseGetId = $F2;
  MouseEnableReporting = $F4;
  MouseSelfTestPassed = $AA;
  MouseIdWithWheel = 3;

  PacketAlwaysSet = $08;
  PacketLeft = $01;
  PacketRight = $02;
  PacketMiddle = $04;
  PacketXNegative = $10;
  PacketYNegative = $20;
  PacketOverflow = $C0;
  MaximumBytesPerInterrupt = 32;

var
  Source: Word;
  PacketSize: Integer;
  Packet: array[0..3] of Byte;
  PacketFill: Integer;
  ButtonsHeld: Byte;
  HasWheel: Boolean;

{ --- Packets -------------------------------------------------------------- }

procedure SendEvent(Kind: Word; Code: LongWord; Value, X, Y: LongInt);
var
  Event: TAbiInputEvent;
begin
  FillMemory(@Event, SizeOf(Event), 0);
  Event.Kind := Kind;
  Event.Source := Source;
  Event.Code := Code;
  Event.Value := Value;
  Event.X := X;
  Event.Y := Y;
  AddInputEvent(Event);
end;

procedure ReportButton(Mask: Byte; Button: LongWord; Held: Byte);
begin
  if ((Held xor ButtonsHeld) and Mask) = 0 then
    Exit;
  if (Held and Mask) <> 0 then
    SendEvent(InputEventButton, Button, 1, 0, 0)
  else
    SendEvent(InputEventButton, Button, 0, 0, 0);
end;

procedure HandlePacket;
var
  DeltaX: LongInt;
  DeltaY: LongInt;
  Wheel: LongInt;
  Held: Byte;
begin
  if (Packet[0] and PacketOverflow) = 0 then
  begin
    DeltaX := Packet[1];
    if (Packet[0] and PacketXNegative) <> 0 then
      DeltaX := DeltaX - 256;
    DeltaY := Packet[2];
    if (Packet[0] and PacketYNegative) <> 0 then
      DeltaY := DeltaY - 256;
    { The mouse counts up as positive; the screen counts down. }
    if (DeltaX <> 0) or (DeltaY <> 0) then
      SendEvent(InputEventMotion, 0, 0, DeltaX, -DeltaY);
  end;
  Held := Packet[0] and (PacketLeft or PacketRight or PacketMiddle);
  ReportButton(PacketLeft, ButtonLeft, Held);
  ReportButton(PacketRight, ButtonRight, Held);
  ReportButton(PacketMiddle, ButtonMiddle, Held);
  ButtonsHeld := Held;
  if HasWheel then
  begin
    Wheel := Packet[3] and $0F;
    if Wheel >= 8 then
      Wheel := Wheel - 16;
    if Wheel <> 0 then
      SendEvent(InputEventWheel, 0, -Wheel, 0, 0);
  end;
end;

procedure HandleMouseByte(Value: Byte);
begin
  { The first byte always has bit 3 set: anything else is out of step. }
  if (PacketFill = 0) and ((Value and PacketAlwaysSet) = 0) then
    Exit;
  Packet[PacketFill] := Value;
  Inc(PacketFill);
  if PacketFill = PacketSize then
  begin
    PacketFill := 0;
    HandlePacket;
  end;
end;

procedure HandleMouseInterrupt(Frame: PTrapFrame; Context: Pointer);
var
  Status: Byte;
  Count: Integer;
begin
  Count := 0;
  repeat
    Status := ReadPortByte(Ps2StatusPort);
    if ((Status and Ps2StatusOutputFull) = 0) or ((Status and Ps2StatusFromAuxiliary) = 0) then
      Break;
    HandleMouseByte(ReadPortByte(Ps2DataPort));
    Inc(Count);
  until Count >= MaximumBytesPerInterrupt;
end;

{ --- Setting up ---------------------------------------------------------- }

function SetSampleRate(Rate: Byte): Boolean;
begin
  Result := Ps2SendToMouse(MouseSetSampleRate) and Ps2SendToMouse(Rate);
end;

{ The port on, the mouse reset, the wheel asked for, reporting on. }
function SetUpMouse: Boolean;
var
  Configuration: Byte;
  Answer: Byte;
begin
  Result := False;
  Ps2SendCommand(Ps2CommandEnableSecondPort);
  if not Ps2ReadConfiguration(Configuration) then
    Exit;
  Configuration := (Configuration or Ps2ConfigurationSecondPortInterrupt) and
    not Ps2ConfigurationSecondPortClockOff;
  { Interrupts off while the mouse answers by polling. }
  Ps2WriteConfiguration(Configuration and not Ps2ConfigurationSecondPortInterrupt);
  if not Ps2SendToMouse(MouseReset) then
    Exit;
  { After the reset: the self test result and the id (0). }
  if not Ps2ReadFromMouse(Answer) or (Answer <> MouseSelfTestPassed) then
    Exit;
  Ps2ReadFromMouse(Answer);
  if not Ps2SendToMouse(MouseSetDefaults) then
    Exit;
  HasWheel := SetSampleRate(200) and SetSampleRate(100) and SetSampleRate(80) and Ps2SendToMouse(MouseGetId) and
    Ps2ReadFromMouse(Answer) and (Answer = MouseIdWithWheel);
  PacketSize := 3;
  if HasWheel then
    PacketSize := 4;
  PacketFill := 0;
  ButtonsHeld := 0;
  if not Ps2SendToMouse(MouseEnableReporting) then
    Exit;
  Ps2WriteConfiguration(Configuration);
  Result := True;
end;

{ Waking from suspend to RAM reset the mouse (the keyboard's resume, run
  before, turned the port off again). }
procedure ResumeMouse(Context: Pointer);
begin
  SetUpMouse;
end;

function InitializePs2Mouse: Boolean;
begin
  Result := False;
  if not Ps2ControllerIsPresent or not SetUpMouse then
    Exit;
  Source := NewInputSource;
  if not ConnectIsaInterrupt(MouseIrq, @HandleMouseInterrupt, nil) then
    Exit;
  RegisterPowerHandler('PS/2 mouse', PowerStageDevices, nil, @ResumeMouse, nil);
  DebugBeginMessage;
  DebugWriteTag('input');
  if HasWheel then
    DebugWriteLine('PS/2 mouse on IRQ 12, with a wheel')
  else
    DebugWriteLine('PS/2 mouse on IRQ 12');
  DebugEndMessage;
  Result := True;
end;

end.
